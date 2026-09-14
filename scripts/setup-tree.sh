#!/usr/bin/env bash
# setup-tree.sh -- assemble the kernel build workspace from pinned upstream refs.
#
# Clones (or resets) the kernel and KernelSU sources at the SHAs pinned in
# pins.sh, then applies patches/kernel/ and patches/kernelsu/. Idempotent: safe
# to re-run, and re-running is how you recover a clean tree after an experiment.
#
# The workspace lives OUTSIDE the OrangeFox tree on purpose. Patching
# ~/fox/kernel/lge/sdm845 would put KernelSU/SuSFS code into the tree the
# recovery builds from, and `repo sync` would wipe it anyway.
#
# Usage: ./scripts/setup-tree.sh [--no-patches] [--clean]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

APPLY_PATCHES=1
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --no-patches) APPLY_PATCHES=0 ;;
    --clean)      CLEAN=1 ;;
    *) echo "error: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

mkdir -p "$WORKSPACE" "$THIRD_PARTY"

# ------------------------------------------------------------------ kernel ---
# No --depth: a shallow clone cannot fetch a specific SHA once the branch tip
# advances past it. Same reasoning as the sibling repo's local manifest.
if [ ! -d "$KERNEL_SRC/.git" ]; then
  echo "Cloning kernel source into $KERNEL_SRC (this is ~1 GB, once) ..."
  git clone --branch "$KERNEL_BRANCH" "$KERNEL_URL" "$KERNEL_SRC"
else
  echo "Kernel source already present at $KERNEL_SRC"
fi

if [ "$CLEAN" = "1" ]; then
  echo "Resetting kernel tree to pristine ..."
  git -C "$KERNEL_SRC" reset --hard -q
  # The drivers/kernelsu symlink is untracked; git clean would remove it, which
  # is harmless -- setup_kernelsu re-creates it every run.
  git -C "$KERNEL_SRC" clean -fdq
  # KernelSU is copied into this tree. Its headers and objects are not
  # reliably dependency-tracked across a clean replay, so an old O= tree
  # could link pre-replay objects with post-replay sources.
  rm -rf "$WORKSPACE/build"
fi

if ! git -C "$KERNEL_SRC" cat-file -e "$KERNEL_REF^{commit}" 2>/dev/null; then
  echo "Fetching pinned kernel revision ..."
  git -C "$KERNEL_SRC" fetch --no-tags origin "$KERNEL_BRANCH"
fi

# Only move HEAD when it is not already at the pin, so a re-run does not
# silently throw away applied patches.
CURRENT="$(git -C "$KERNEL_SRC" rev-parse HEAD)"
if [ "$CURRENT" != "$KERNEL_REF" ]; then
  echo "Checking out $KERNEL_REF ..."
  git -C "$KERNEL_SRC" checkout -q --detach "$KERNEL_REF"
fi

# Assert rather than trust. A silently-wrong base makes every downstream
# result meaningless.
ACTUAL="$(git -C "$KERNEL_SRC" rev-parse HEAD)"
if [ "$ACTUAL" != "$KERNEL_REF" ]; then
  echo "error: kernel HEAD is $ACTUAL, expected $KERNEL_REF" >&2
  exit 1
fi
echo "  kernel at $ACTUAL"

KVER="$(make -s -C "$KERNEL_SRC" kernelversion 2>/dev/null || echo unknown)"
if [ "$KVER" != "4.9.337" ]; then
  echo "error: kernel reports version '$KVER', expected 4.9.337." >&2
  echo "       The drop-in property (matching stock, no vendor-blob ABI break)" >&2
  echo "       depends on this. Refusing to continue." >&2
  exit 1
fi
echo "  version $KVER"

# scripts/setlocalversion checks for this file BEFORE it checks git-dirty
# state, and uses its content verbatim as the version suffix. Without it, the
# tree's uncommitted patches make git report dirty, which appends a trailing
# "+" to `uname -r` (see CLAUDE.md) -- a tell that this is not a stock build,
# and re-created here on every setup since --clean's `git clean` removes it.
: > "$KERNEL_SRC/.scmversion"
echo "  wrote empty .scmversion (suppresses the dirty-tree '+' suffix)"

# ----------------------------------------------------------------- patches ---
# Same check / reverse-check / fail contract as the sibling repo's
# apply-fixes.sh, so a partially-patched tree is never mistaken for a clean one.
apply_patch() {
  local patch="$1"
  local name
  name="$(basename "$patch")"
  if git -C "$KERNEL_SRC" apply --check "$patch" 2>/dev/null; then
    git -C "$KERNEL_SRC" apply "$patch"
    echo "  applied $name"
  elif git -C "$KERNEL_SRC" apply --reverse --check "$patch" 2>/dev/null; then
    echo "  $name already applied"
  else
    echo "error: $name does not apply cleanly to $KERNEL_SRC" >&2
    exit 1
  fi
}

apply_ksu_patch() {
  local ksu_dir="$1"
  local patch="$2"
  local name
  name="$(basename "$patch")"
  if git -C "$ksu_dir" apply --check "$patch" 2>/dev/null; then
    git -C "$ksu_dir" apply "$patch"
    echo "  applied $name"
  elif git -C "$ksu_dir" apply --reverse --check "$patch" 2>/dev/null; then
    echo "  $name already applied"
  else
    echo "error: $name does not apply cleanly to $ksu_dir" >&2
    exit 1
  fi
}

# ------------------------------------------------- backslashxx KernelSU ---
# Branch backslashxx-ksu. backslashxx's own kernel/setup.sh resolves its arg as
# a git ref and falls back silently when it does not resolve, and it `git pull`s
# -- both of which defeat pinning. So the wiring it does (symlink + drivers
# Makefile/Kconfig) is reproduced here against the pinned SHA and asserted.
#
# Unlike the KSU-Next integration this replaced, backslashxx needs NO KSU-side
# patches for this tree: syscall-table hooking (CONFIG_KSU_TAMPER_SYSCALL_TABLE,
# set in config/ksu.fragment) means no manual fs/*.c hooks, and its own thin
# selinux_hide / FDE-aware throne_tracker replace the KSU-Next fix stack. The
# SuSFS KSU-side port lands here in phase 2.
setup_kernelsu() {
  local ksu_dir="$THIRD_PARTY/KernelSU"
  local drivers="$KERNEL_SRC/drivers"

  if [ ! -d "$ksu_dir/.git" ]; then
    echo "Cloning backslashxx/KernelSU ..."
    git clone -q --branch "$KSU_BRANCH" "$KSU_URL" "$ksu_dir"
  fi
  # backslashxx FORCE-PUSHES master/staging, so the pinned SHA may have been
  # orphaned since it was recorded. Fetch, then assert the object is actually
  # present -- do not silently build whatever the branch tip is now.
  if ! git -C "$ksu_dir" cat-file -e "$KSU_REF^{commit}" 2>/dev/null; then
    git -C "$ksu_dir" fetch -q --no-tags origin "$KSU_BRANCH" || true
  fi
  if ! git -C "$ksu_dir" cat-file -e "$KSU_REF^{commit}" 2>/dev/null; then
    echo "error: pinned KSU_REF $KSU_REF is not present in $KSU_URL." >&2
    echo "       backslashxx force-pushes its branches; this SHA was likely" >&2
    echo "       orphaned. Re-pin KSU_REF in pins.sh to the current master/tag." >&2
    exit 1
  fi
  if [ "$CLEAN" = "1" ]; then
    git -C "$ksu_dir" reset --hard -q "$KSU_REF"
    git -C "$ksu_dir" clean -fdq
  else
    git -C "$ksu_dir" checkout -q --detach "$KSU_REF"
  fi

  local got
  got="$(git -C "$ksu_dir" rev-parse HEAD)"
  if [ "$got" != "$KSU_REF" ]; then
    echo "error: backslashxx/KernelSU is at $got, expected $KSU_REF" >&2
    exit 1
  fi
  local ksu_ver
  ksu_ver="$(grep -o 'KSU_VERSION=[0-9]*' "$ksu_dir/kernel/Makefile" | head -1 | cut -d= -f2)"
  echo "  backslashxx/KernelSU at $got (KSU_VERSION=${ksu_ver:-?})"
  if [ -n "${KSU_VERSION:-}" ] && [ -n "$ksu_ver" ] && [ "$ksu_ver" != "$KSU_VERSION" ]; then
    echo "error: KernelSU reports version $ksu_ver, pins.sh expects $KSU_VERSION" >&2
    exit 1
  fi

  # KSU-side patches applied ONTO backslashxx (phase 2+). Unlike the KSU-Next
  # era there is no wildcard replay -- each patch is named. bxx-susfs bridges the
  # fork-independent kernel-side SuSFS backport to backslashxx's supercall /
  # selinux / setuid / init.
  local bxx_ksu_patch_names=(
    bxx-susfs-v2.2.0.patch
  )
  local pn
  for pn in "${bxx_ksu_patch_names[@]}"; do
    apply_ksu_patch "$ksu_dir" "$HERE/patches/kernelsu/$pn"
  done

  # drivers/kernelsu -> <ksu>/kernel, relative so the tree stays relocatable.
  ln -sfn "$(realpath --relative-to="$drivers" "$ksu_dir/kernel")" "$drivers/kernelsu"

  grep -q 'kernelsu' "$drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$drivers/Makefile"
  grep -q 'source "drivers/kernelsu/Kconfig"' "$drivers/Kconfig" || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$drivers/Kconfig"
  echo "  wired into drivers/{Makefile,Kconfig}"

  # Sanity: the unity-build entry point must be present, else CONFIG_KSU builds
  # nothing. (backslashxx is obj-$(CONFIG_KSU) := ksu.o.)
  if ! grep -q 'ksu.o' "$ksu_dir/kernel/Makefile"; then
    echo "error: backslashxx kernel/Makefile has no ksu.o target -- unexpected layout." >&2
    exit 1
  fi
  echo "  KernelSU wired (syscall-table hooking; no manual hooks on this tree)"
}

# Release kernel patches, applied in this exact (alphabetical) order. An explicit
# allowlist (not a `patches/kernel/*.patch` glob) keeps a release deterministic:
# every patch is named here and setup errors on any uncategorised file.
#
# BRANCH backslashxx-ksu, PHASE 1: only the fork-independent kernel-tree patches
# are applied. backslashxx supplies its own hooks (syscall-table) and root-stack
# behaviour, so the KSU-Next-specific patches and the whole SuSFS/NoMount stack
# are parked in kernel_bxx_deferred_patch_names below (categorised, not applied)
# and are re-introduced in later phases (SuSFS = phase 2, NoMount = phase 3).
kernel_patch_names=(
  caymanslm-edl-warm-reset.patch
  caymanslm-ksu-path-umount.patch            # path_umount backport (fs/namespace.c); fork-independent, needed for module umount
  caymanslm-overlayfs-uniform-ro-st-dev.patch
  caymanslm-sanitized-ikconfig.patch         # keeps /proc/config.gz for VINTF, redacts CONFIG_KSU*
  caymanslm-selinux-bounds-null-guard.patch  # kernel-tree SELinux hardening, KSU-independent
  # PHASE 2 -- SuSFS kernel-side (fork-independent: fs/susfs.c, fs/*, mm, avc). The
  # KSU-side bridge onto backslashxx is applied separately in setup_kernelsu. These
  # sort after selinux-bounds and before watchdog; boot-fixes and the avc-audit
  # null-guard sort after the backport whose files they extend.
  caymanslm-susfs-v2.2.0-4.9-backport.patch
  caymanslm-susfs-v2.2.0-boot-fixes.patch
  caymanslm-susfs-z2-selinux-avc-audit-null-guard.patch
  caymanslm-watchdog-bark-window.patch
)
# Parked for later migration phases -- categorised so the allowlist check passes,
# but NOT applied on this branch. KSU-Next-specific fixes (manual hooks, initrc,
# nnp-nosuid, sepolicy locking, selinux_hide) are superseded by backslashxx's own
# implementations and may be dropped entirely once the port is validated; the
# SuSFS and NoMount patches return in phases 2 and 3.
kernel_bxx_deferred_patch_names=(
  caymanslm-ksu-manual-hooks.patch
  caymanslm-ksu-newfstat-initrc.patch
  caymanslm-ksu-newfstatat-initrc.patch
  caymanslm-ksu-nnp-nosuid-hook.patch
  caymanslm-ksu-selinux-policy-rwlock.patch
  caymanslm-selinux-policydb-atomic-alloc.patch
  caymanslm-susfs-spoof-proc-version.patch
  caymanslm-susfs-spoof-uts-sysctl.patch
  caymanslm-susfs-v2.2.0-uname-ksu-domain-gate.patch
  caymanslm-zz-nomount-4.9-integration.patch
  caymanslm-zzz-selinux-hide-injected-types.patch
  caymanslm-zzz2-selinux-export-policy-seqno.patch
  caymanslm-zzz3-selinux-hide-dirty-edges.patch
)
# Diagnostic-only kernel patches (none currently) -- NEVER part of a release.
# Opt in per build with EXTRA_KERNEL_PATCHES="<name>" ./scripts/setup-tree.sh
kernel_diag_patch_names=()

if [ "$APPLY_PATCHES" = "1" ]; then
  # Every .patch in patches/kernel/ must be categorised as release or diagnostic,
  # so a newly added patch can neither silently ship nor silently vanish.
  shopt -s nullglob
  for f in "$HERE"/patches/kernel/*.patch; do
    b="$(basename "$f")"
    case " ${kernel_patch_names[*]} ${kernel_diag_patch_names[*]} ${kernel_bxx_deferred_patch_names[*]} " in
      *" $b "*) ;;
      *) echo "error: uncategorised kernel patch '$b' -- add it to kernel_patch_names" >&2
         echo "       (release), kernel_diag_patch_names (diagnostic), or" >&2
         echo "       kernel_bxx_deferred_patch_names (parked for a later phase) in setup-tree.sh" >&2
         exit 1 ;;
    esac
  done
  shopt -u nullglob

  patches=()
  for name in "${kernel_patch_names[@]}"; do
    p="$HERE/patches/kernel/$name"
    [ -f "$p" ] || { echo "error: release kernel patch missing: $name" >&2; exit 1; }
    patches+=("$p")
  done
  # EXTRA_KERNEL_PATCHES: space-separated diagnostic patch basenames, opt-in.
  for name in ${EXTRA_KERNEL_PATCHES:-}; do
    p="$HERE/patches/kernel/$name"
    [ -f "$p" ] || { echo "error: EXTRA_KERNEL_PATCHES entry not found: $name" >&2; exit 1; }
    echo "  DIAGNOSTIC (opt-in): $name"
    patches+=("$p")
  done

  # SKIP_PATCHES=<extended regex> omits matching patch basenames. For bisecting
  # which of our changes is responsible for a defect: root still works when the
  # KernelSU-required patches are kept, so a root-detecting app still runs its
  # full workload and the comparison stays matched. Pair with BISECT=1, which
  # relaxes build.sh's root-stack config assertions.
  if [ -n "${SKIP_PATCHES:-}" ]; then
    kept=()
    for p in "${patches[@]}"; do
      if printf '%s' "$(basename "$p")" | grep -Eq "$SKIP_PATCHES"; then
        echo "  SKIPPING $(basename "$p")  (SKIP_PATCHES)"
      else
        kept+=("$p")
      fi
    done
    patches=("${kept[@]}")
  fi
  if [ ${#patches[@]} -eq 0 ]; then
    echo "No kernel patches to apply."
  else
    echo "Applying kernel patches ..."
    for p in "${patches[@]}"; do apply_patch "$p"; done
  fi
else
  echo "Skipping patches (--no-patches)."
fi

if [ "$APPLY_PATCHES" = "1" ]; then
  echo "Setting up backslashxx/KernelSU ..."
  setup_kernelsu
fi

echo "Workspace ready: $KERNEL_SRC"

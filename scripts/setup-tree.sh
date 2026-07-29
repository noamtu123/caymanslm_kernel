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
  # -e keeps the KernelSU-Next symlink out of harm's way; it is re-made by the
  # KernelSU setup step rather than by git.
  git -C "$KERNEL_SRC" clean -fdq -e KernelSU-Next
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

# ------------------------------------------------------------- KernelSU ---
# Deliberately NOT run through KernelSU-Next's own kernel/setup.sh. That script
# resolves its argument as a git ref and, when the ref does not resolve, falls
# back to the default branch *silently* -- so a typo would quietly build a
# different KernelSU than the one pinned. It also `git pull`s, which defeats
# pinning outright. The three things it actually does are reproduced here
# against a pinned SHA, and asserted.
setup_kernelsu() {
  local ksu_dir="$THIRD_PARTY/KernelSU-Next"
  local drivers="$KERNEL_SRC/drivers"

  if [ ! -d "$ksu_dir/.git" ]; then
    echo "Cloning KernelSU-Next ..."
    git clone -q --branch "$KSU_BRANCH" "$KSU_URL" "$ksu_dir"
  fi
  if ! git -C "$ksu_dir" cat-file -e "$KSU_REF^{commit}" 2>/dev/null; then
    git -C "$ksu_dir" fetch -q --no-tags origin "$KSU_BRANCH"
  fi
  git -C "$ksu_dir" checkout -q --detach "$KSU_REF"

  local got
  got="$(git -C "$ksu_dir" rev-parse HEAD)"
  if [ "$got" != "$KSU_REF" ]; then
    echo "error: KernelSU-Next is at $got, expected $KSU_REF" >&2
    exit 1
  fi
  echo "  KernelSU-Next at $got"

  # Release replay is intentionally explicit.  Historical diagnostics patches
  # are retained beside the integration work for reference, but must never be
  # silently included in a production kernel (and some were tied to temporary
  # debugging layouts).  Add a debug patch deliberately in a dedicated debug
  # replay; do not make the release image depend on wildcard ordering.
  local ksu_patch_names=(
    ksu-legacy-zygote-app-process64.patch
    ksun-v3.2.0-legacy-susfs-v2.2.0.patch
    z-ksu-legacy-susfs-manager-setuid.patch
    zz-ksu-legacy-initial-manager-scan.patch
    zzz-ksu-legacy-verified-manager-scan.patch
    zzzzzzz-ksu-manager-scan-retry-until-crowned.patch
    zzzzzzzz-ksu-manager-synchronous-setuid-discovery.patch
    zzzzzzzzz-ksu-manager-remove-spurious-dentry-lock-gate.patch
    zzzzzzzzzz-ksu-release-remove-sucompat-log-fingerprints.patch
  )
  local ksu_patches=()
  local patch_name
  for patch_name in "${ksu_patch_names[@]}"; do
    ksu_patches+=("$HERE/patches/kernelsu/$patch_name")
  done
  if [ ${#ksu_patches[@]} -gt 0 ]; then
    echo "  applying KernelSU integration patches ..."
    local p
    for p in "${ksu_patches[@]}"; do
      apply_ksu_patch "$ksu_dir" "$p"
    done
  fi

  # drivers/kernelsu -> <ksu>/kernel, relative so the tree stays relocatable.
  ln -sfn "$(realpath --relative-to="$drivers" "$ksu_dir/kernel")" "$drivers/kernelsu"

  grep -q 'kernelsu' "$drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$drivers/Makefile"
  grep -q 'source "drivers/kernelsu/Kconfig"' "$drivers/Kconfig" || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$drivers/Kconfig"
  echo "  wired into drivers/{Makefile,Kconfig}"

  # KernelSU's own Kbuild refuses to build unless the manual hooks are present,
  # which is a useful independent check on our patch actually having landed.
  if ! grep -q 'ksu_handle_sys_reboot' "$KERNEL_SRC/kernel/reboot.c"; then
    echo "error: manual hooks are missing from kernel/reboot.c -- KernelSU will refuse to build." >&2
    exit 1
  fi
  echo "  manual hooks present"
}

if [ "$APPLY_PATCHES" = "1" ]; then
  shopt -s nullglob
  patches=("$HERE"/patches/kernel/*.patch)
  shopt -u nullglob
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
  echo "Setting up KernelSU-Next ..."
  setup_kernelsu
fi

echo "Workspace ready: $KERNEL_SRC"

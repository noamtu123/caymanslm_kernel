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
  # A clean replay must reset KernelSU as well as the kernel tree.  Leaving
  # previously replayed patches in this generated checkout makes subsequent
  # patch applicability depend on build history rather than the pinned source.
  if [ "$CLEAN" = "1" ]; then
    git -C "$ksu_dir" reset --hard -q "$KSU_REF"
    git -C "$ksu_dir" clean -fdq
  else
    git -C "$ksu_dir" checkout -q --detach "$KSU_REF"
  fi

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
    zzzzzzzzz-ksu-manager-remove-spurious-dentry-lock-gate.patch
    # Manager discovery stays fully async -- no synchronous /data/app walk in the
    # setresuid hot path. That pattern, once tried as
    # zzzzzzzz-ksu-manager-synchronous-setuid-discovery.patch, is removed: it
    # scanned on every app-uid spawn during the boot storm and still cannot beat
    # the FBE/ENOKEY wall, since the manager APK is unreadable until CE storage
    # unlocks ~30-55s in. Instead the async throne worker crowns at CE-unlock and
    # these three close the "crowned but the running manager never got its fd"
    # gap that used to force a swipe-from-recents reopen ("not integrated" /
    # "Zygisk required"):
    #   * repair-running-fd: after crown_manager() verifies the signature and
    #     crowns the UID, task_work_add() installs the manager fd into the
    #     already-running manager on its next return to userspace. No identity is
    #     granted -- the UID was already crowned by the certificate check.
    #   * retry-backoff-fbe-window: widen the worker's retry from ~1s (10x100ms)
    #     to a bounded ~60s exponential backoff so it actually spans CE-unlock.
    #   * boot-completed-search-if-uncrowned: on_boot_completed does a full search
    #     when no manager is crowned yet, instead of a prune-only pass that would
    #     cancel discovery.
    # Order matters: repair before retry (both edit throne_tracker.c; retry's
    # hunk sits on post-repair line numbers).
    zzzzzzzz-ksu-manager-repair-running-fd.patch
    zzzzzzz3-ksu-manager-retry-backoff-fbe-window.patch
    zz2-ksu-boot-completed-search-if-uncrowned.patch
    zzzzzz-ksu-newfstatat-initrc-helper.patch
    # Release stealth: drop the four sucompat su-access kernel-log fingerprints
    # (faccessat/stat/execve/execveat). Independent of every other patch here --
    # it only deletes pr_info() lines in kernel/feature/sucompat.c -- so its
    # position in this list does not matter.
    zzzzzzzzzz-ksu-release-remove-sucompat-log-fingerprints.patch
    # zzzzzzzzzz2-ksu-initrc-fbe-late-trigger.patch is deliberately NOT applied
    # any more (dropped 2026-08-02). It added a second
    # `on property:sys.user.0.ce_available=true` trigger firing another
    # `ksud post-fs-data` + `services`, on the premise that /data was
    # unreadable at the real post-fs-data trigger. That premise was wrong: the
    # real trigger was failing on the init->ksu SELinux transition, fixed by
    # patches/kernel/caymanslm-ksu-nnp-nosuid-hook.patch. With that hook in
    # place init's `on post-fs-data` runs ksud successfully at ~9s
    # (`exec … /data/adb/ksud post-fs-data` exits status 0), so the late
    # trigger is now a pure DUPLICATE run and actively breaks modules: it
    # re-executes every module's post-fs-data.sh after boot, and ReZygisk's
    # starts with `rm -rf /data/adb/rezygisk`, unlinking the sockets its
    # already-running daemon is bound to. Symptom: every app logs
    # `zygisk-core64: connection to ReZygiskd failed with 2` and ReZygisk
    # reports "Multiple Zygisks functioning".
    #
    # Must come last: it rewrites the apply_kernelsu_rules() lock region that
    # the earlier sepolicy patches also touch.
    #
    # apply_kernelsu_rules() injected its rules while holding policy_rwlock for
    # WRITE with preempt_enable() and the task pinned to a single CPU, so the
    # rule path's GFP_KERNEL allocations could sleep. policy_rwlock is a
    # spinning lock whose readers include security_compute_av() -- every SELinux
    # permission check on the system -- and they spin with preemption disabled.
    # Once the writer went off-CPU (reclaim or preemption) and any reader landed
    # on the one CPU it had pinned itself to, the writer could never be
    # scheduled again: permanent deadlock, ~1 boot in 5. Measured signature was
    # PID 1 parked in ptrace_stop while ReZygisk's ptrace monitor sat in state R
    # at 80% system time until a hard reset. Pairs with
    # patches/kernel/caymanslm-selinux-policydb-atomic-alloc.patch, which adds
    # the ksu_policydb_gfp knob this switches to GFP_ATOMIC.
    zzzzzzzzzzz-ksu-sepolicy-no-sleep-under-policy-rwlock.patch
    # add_type() bumps p_types.nprim before filling
    # type_val_to_struct_array[value-1] and its failure paths never rolled it
    # back, leaving a NULL slot for an index the policy claims exists. The
    # SELinux readers BUG_ON() that slot under policy_rwlock, so an unprivileged
    # app could hard-panic the phone. Must come after the no-sleep patch above,
    # whose GFP_ATOMIC switch is what makes those failures likely.
    zzzzzzzzzzz2-ksu-add-type-publish-order.patch
    # apply_kernelsu_rules() still held policy_rwlock for WRITE with interrupts
    # ENABLED. Its readers are every SELinux permission check -- and SELinux
    # runs them from softirq context on the network hooks. An interrupt landing
    # on the CPU that holds the write lock makes that CPU spin on read_lock(),
    # in interrupt context with IRQs masked, waiting for a lock it owns itself;
    # every other CPU then piles up behind it. Measured signature: one core
    # powered and executing (it answered an external CoreSight debug halt in
    # 0ms) but masking interrupts, answering no IPIs, never returning to
    # userspace, stalling RCU -- the Duck Detector lockup. Mainline takes the
    # same lock as write_lock_irq() in security_load_policy() for this reason.
    # Must come after the no-sleep patch, whose GFP_ATOMIC switch is what makes
    # the section safe to run with interrupts off.
    #
    # NOTE (2026-08-18): this does NOT fix the Duck Detector lockup. A kernel
    # carrying it was built (#29), verified to contain write_lock_irq at both
    # sites, and tested twice on-device -- Duck still wedged a core and the apps
    # watchdog still bit at ~15s (lge.bootreason=AppsWdogBark). The patch is kept
    # because it is correct on its own terms (mainline takes this lock the same
    # way and the section is already GFP_ATOMIC), not as a fix for that bug.
    zzzzzzzzzzz3-ksu-sepolicy-policy-rwlock-irq-safe.patch
    # Five allocation-failure paths in add_type()'s 4.9 flex_array branch still
    # bypassed the err_unwind above (two bare `return false`, three prealloc
    # gotos that unwind the counter but leak all three new flex_arrays). Routes
    # them through an err_free label. Must come after the publish-order patch,
    # whose err_unwind label it reuses. Independent correctness fix -- NOT a fix
    # for the Duck Detector lockup.
    zzzzzzzzzzz4-ksu-add-type-alloc-failure-unwind.patch
    # selinux_hide's replacement sel_open_handle_status() stored
    # page_address(fake_status) in filp->private_data, where selinuxfs stores
    # and consumes a struct page *. mmap() of /sys/fs/selinux/status then ran
    # page_to_pfn() on a kernel virtual address and remap_pfn_range() mapped
    # the resulting nonsense PFN into userspace, which hard-locks a Gold core
    # with interrupts masked -- no stack, no log, just an apps-watchdog reboot.
    # Any app with TIF_SECCOMP and uid >= 10000 triggers it; Duck Detector's
    # app zygote does it on every launch.
    zzzzzzzzzzz5-ksu-selinux-hide-status-page-type.patch
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

# Release kernel patches, applied in this exact (alphabetical) order. This used
# to be a `patches/kernel/*.patch` glob, but a glob silently applies WHATEVER is
# in the directory -- including diagnostic patches dropped there in passing. That
# is exactly what the KernelSU side already refuses to do (see ksu_patch_names),
# and for the same reason: caymanslm-qc-dload-cookie.patch is a diagnostic that
# rewrites the same msm-poweroff.c regions as the release caymanslm-edl-warm-
# reset.patch, so a glob applied edl-warm-reset first and then aborted the whole
# setup when qc-dload-cookie failed to apply. An explicit allowlist makes a
# release deterministic and lets diagnostics live beside the code without leaking.
kernel_patch_names=(
  caymanslm-edl-warm-reset.patch
  caymanslm-ksu-manual-hooks.patch
  caymanslm-ksu-newfstat-initrc.patch
  caymanslm-ksu-newfstatat-initrc.patch
  caymanslm-ksu-nnp-nosuid-hook.patch
  caymanslm-ksu-path-umount.patch
  caymanslm-ksu-selinux-policy-rwlock.patch
  caymanslm-overlayfs-uniform-ro-st-dev.patch
  caymanslm-sanitized-ikconfig.patch
  caymanslm-selinux-bounds-null-guard.patch
  caymanslm-selinux-policydb-atomic-alloc.patch
  caymanslm-susfs-spoof-proc-version.patch
  caymanslm-susfs-spoof-selinux-status-seqno.patch
  caymanslm-susfs-spoof-uts-sysctl.patch
  caymanslm-susfs-v2.2.0-4.9-backport.patch
  caymanslm-susfs-v2.2.0-boot-fixes.patch
  caymanslm-susfs-v2.2.0-uname-ksu-domain-gate.patch
  caymanslm-susfs-z2-selinux-avc-audit-null-guard.patch
  caymanslm-watchdog-bark-window.patch
  caymanslm-zz-nomount-4.9-integration.patch
  caymanslm-zzz-selinux-hide-injected-types.patch
)
# Diagnostic-only kernel patches -- NEVER part of a release. Their C is gated
# behind CONFIG_CAYMANSLM_* (off unless a diagnostic fragment is merged), but
# they must still be applied to provide that code. Opt in per build with
#   EXTRA_KERNEL_PATCHES="caymanslm-pstore-capture-reason.patch" ./scripts/setup-tree.sh
# (paralleling build.sh's EXTRA_FRAGMENT), applied after the release set.
# NOTE: caymanslm-qc-dload-cookie.patch cannot coexist with the release
# caymanslm-edl-warm-reset.patch (both rewrite the same msm-poweroff.c regions);
# build the edldump diagnostic against a tree with edl-warm-reset removed.
kernel_diag_patch_names=(
  caymanslm-pstore-capture-reason.patch
  caymanslm-qc-dload-cookie.patch
)

if [ "$APPLY_PATCHES" = "1" ]; then
  # Every .patch in patches/kernel/ must be categorised as release or diagnostic,
  # so a newly added patch can neither silently ship nor silently vanish.
  shopt -s nullglob
  for f in "$HERE"/patches/kernel/*.patch; do
    b="$(basename "$f")"
    case " ${kernel_patch_names[*]} ${kernel_diag_patch_names[*]} " in
      *" $b "*) ;;
      *) echo "error: uncategorised kernel patch '$b' -- add it to kernel_patch_names" >&2
         echo "       (release) or kernel_diag_patch_names (diagnostic) in setup-tree.sh" >&2
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
  echo "Setting up KernelSU-Next ..."
  setup_kernelsu
fi

echo "Workspace ready: $KERNEL_SRC"

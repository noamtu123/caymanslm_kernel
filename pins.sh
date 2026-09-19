#!/usr/bin/env bash
# pins.sh -- every upstream ref this project depends on, in one place.
#
# Sourced by scripts/*.sh. Bump deliberately, never float: each upstream is
# checked out by SHA and the setup script asserts what it actually got. This
# matters more than usual for KernelSU-Next, whose setup.sh silently falls back
# to the default branch when a ref does not resolve.
#
# Usage: . "$(dirname "$0")/../pins.sh"

# --------------------------------------------------------------- kernel ---
# LineageOS android_kernel_lge_sdm845, branch lineage-22.2. Same source the
# OrangeFox recovery pins (orangefox_caymanslm/manifests/caymanslm.xml), so the
# recovery kernel and this one stay ABI-comparable. 4.9.337, non-GKI.
KERNEL_URL="https://github.com/LineageOS/android_kernel_lge_sdm845"
KERNEL_REF="efa8458f79dffeb380d43b38b9403407f87d9f05"
KERNEL_BRANCH="lineage-22.2"          # branch containing KERNEL_REF, for fetch
KERNEL_DEFCONFIG="lineageos_caymanslm_defconfig"

# ---------------------------------------------------------- KernelSU Next ---
# The kernel is non-GKI, pre-4.14 and has no CONFIG_KPROBES, so the `legacy`
# line -- the one maintained for old non-GKI kernels -- is the only viable one,
# and manual hooks are mandatory.
#
# Pinned at the legacy branch head. Operator preference is latest-on-both, and
# legacy HEAD is also the right structural match for maintained SuSFS: it
# carries the restructured layout (kernel/core, kernel/feature, kernel/hook,
# kernel/policy, kernel/supercall) that susfs4ksu's current KernelSU-side patch
# targets -- 28 of the 29 files that patch touches exist here.
#
# NOT used: v3.1.0-legacy-susfs. It ships SUSFS in-tree, which looked like a
# shortcut, but it expects a v2.x kernel side and is an older release. See
# CLAUDE.md for the measurements.
KSU_URL="https://github.com/KernelSU-Next/KernelSU-Next"
KSU_BRANCH="legacy"
KSU_REF="a54e4fa46c6cc25bcaa055cf14d790194beffed8"   # legacy HEAD 2026-07-29 (latest KSU-Next that supports 4.x; dev/stable require KPROBES, pruned 4.x Jan 2026)

# ----------------------------------------------------------------- SuSFS ---
# Kernel-side only: userspace policy/tooling remains a separately installed
# module. This is ShirkNeko's maintained v2.3.0 source, backported from its
# Android 12 / Linux 5.10 patch to this device's Linux 4.9.337 tree.
SUSFS_URL="https://github.com/ShirkNeko/susfs4ksu"
SUSFS_BRANCH="gki-android12-5.10"
SUSFS_REF="f3b5aecf53ff8b3296603071b91383f6be6c7cbb"
SUSFS_VERSION="v2.3.0"
SUSFS_KERNEL_PATCH="caymanslm-susfs-v2.3.0-4.9-backport.patch"

# ----------------------------------------------------------- AnyKernel3 ---
ANYKERNEL_URL="https://github.com/osm0sis/AnyKernel3"
ANYKERNEL_REF="1c9a500dd4aa8081952523126e97eb155aed941b"

# ------------------------------------------------------------- toolchain ---
# clang r487747c, identified from /proc/version on the running device. Borrowed
# read-only from the OrangeFox build tree -- nothing is ever written into it.
# Repoint at a standalone copy to make this project fully self-contained; the
# default just avoids re-downloading ~1.5 GB.
FOX_TREE="${FOX_TREE:-$HOME/fox}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$FOX_TREE/prebuilts/clang/host/linux-x86/clang-r487747c}"
BUILD_TOOLS_DIR="${BUILD_TOOLS_DIR:-$FOX_TREE/prebuilts/build-tools/linux-x86}"
LINEAGE_TOOLS_DIR="${LINEAGE_TOOLS_DIR:-$FOX_TREE/prebuilts/tools-lineage/linux-x86}"
PERL5LIB_DIR="${PERL5LIB_DIR:-$FOX_TREE/prebuilts/tools-lineage/common/perl-base}"

# Reference .config from the known-good OrangeFox build. Phase 1's gate is that
# our standalone build reproduces this byte for byte.
REFERENCE_CONFIG="${REFERENCE_CONFIG:-$FOX_TREE/out/target/product/caymanslm/obj/KERNEL_OBJ/.config}"

# ------------------------------------------------------- boot repacking ---
# AOSP's mkbootimg/unpack_bootimg. Read-only use, like the toolchain above.
MKBOOTIMG_DIR="${MKBOOTIMG_DIR:-$FOX_TREE/system/tools/mkbootimg}"

# Donor for the ramdisk + header of a `fastboot boot` trial image. mkboot.sh
# swaps ONLY our kernel/dtb into this donor and preserves everything else.
#
# HARD RULE (see the ramboot-lineage-donor memory): the donor must be a LIVE
# LineageOS boot pulled from the ACTIVE slot, never a stock/backup image -- a
# mismatched ramdisk soft-bricked the phone once. So the default is a persistent
# live donor saved under artifacts/, pulled ONCE and reused across every build.
# Re-pull only after a ROM OTA; until then a stale ramdisk merely lands the
# (non-destructive) RAM-boot in recovery, which is the signal to refresh it.
#   Refresh:  adb reboot recovery  (OrangeFox = root)
#             adb shell "dd if=/dev/block/bootdevice/by-name/boot_$(active slot)" \
#                 > artifacts/boot-live-donor.img
# The old stock donor remains only as a last-resort fallback when no live donor
# has ever been saved (header v2, separate dtb, os_version 11.0.0).
_PINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_DONOR="${LIVE_DONOR:-$_PINS_DIR/artifacts/boot-live-donor.img}"
SIBLING_REPO="${SIBLING_REPO:-/mnt/e/orangefox_caymanslm}"
if [ -n "${STOCK_BOOT_IMG:-}" ]; then
  :                                   # explicit override wins
elif [ -f "$LIVE_DONOR" ]; then
  STOCK_BOOT_IMG="$LIVE_DONOR"        # persistent live donor -- preferred
else
  STOCK_BOOT_IMG="$SIBLING_REPO/artifacts/edl-backup/boot_b-stock.img"
fi

# ------------------------------------------------------------ workspace ---
# Deliberately OUTSIDE the OrangeFox tree: patching ~/fox/kernel/lge/sdm845
# would put KSU/SuSFS code into the tree the recovery builds from, and
# `repo sync` would wipe it.
# The active, reproducible SuSFS v2.2 replay tree.  Keeping this explicit
# avoids silently building the older /home/.../caymanslm-kernel tree, whose
# KernelSU/SuSFS integration is not the one being tested on the device.
WORKSPACE="${WORKSPACE:-$HOME/caymanslm-kernel/susfs-v2-replay}"
KERNEL_SRC="$WORKSPACE/src"
KERNEL_OUT="$WORKSPACE/build"
THIRD_PARTY="$WORKSPACE/third_party"

# --------------------------------------------------------------- device ---
# Refuse to touch anything that is not this phone, the way the sibling repo's
# EDL script does. Not the 5G Velvet (caymanlm / SDM765G).
DEVICE="caymanslm"

# Build identity, so `uname -a` proves which build is actually running. The
# recovery project lost many cycles to a flash that silently did not take.
#
# This is compiled into `(LINUX_COMPILE_BY@LINUX_COMPILE_HOST)` in
# init/version.c and shows up verbatim in /proc/version, which is
# world-readable -- CONFIG_KSU_SUSFS_SPOOF_UNAME does NOT cover it (it only
# rewrites the newuname() syscall's utsname, not the compile-time banner). A
# release build must not identify the operator, so this is generic rather than
# stock-mimicking impersonation. Dev builds are unaffected: `uname -a` is still
# how a flash is confirmed to have taken, it just proves "our build" via the
# release string set in scripts/build.sh (--release-string) instead of a name.
KBUILD_USER="build"
KBUILD_HOST="localhost"

# Present only in an EDL-capable kernel. Asserted on every built artifact --
# the same marker patch-android-edl-boot.ps1 uses. If this string is missing,
# `adb reboot edl` is dead and so is the last-resort recovery path.
EDL_MARKER="Failed to set secure EDLOAD mode"

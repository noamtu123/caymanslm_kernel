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

# ------------------------------------------------------ backslashxx KernelSU ---
# BRANCH backslashxx-ksu: the root stack is switched from KernelSU-Next to
# backslashxx/KernelSU -- a manual-hook / wide-kernel fork (its docs: "k3.0 ~
# mainline, manual hooking supported and kept forever", min GCC 4.9/Clang 10).
# It self-adapts to this 4.9.337 non-GKI tree via compile-time compat detection
# and, crucially, offers CONFIG_KSU_TAMPER_SYSCALL_TABLE (syscall-table hijack,
# "Recommended 3.0~4.14") so NO manual fs/*.c hook patch is needed here -- unlike
# KSU-Next legacy. Base build proven on this tree 2026-09-14.
#
# "Latest" == master HEAD, which is also tag `32630` and reports KSU_VERSION=32630
# (hardcoded in kernel/Makefile, NOT git-count-derived). backslashxx FORCE-PUSHES
# master/staging, so a pinned SHA can be orphaned and become unfetchable -- setup
# asserts the SHA is present and fails loudly if a force-push has removed it,
# rather than silently drifting. Re-pin on update.
KSU_URL="https://github.com/backslashxx/KernelSU"
KSU_BRANCH="master"
KSU_REF="73f2732829c1187dc2188dbec854cf45782a964e"   # master == tag 32630 (v3.3.0+), 2026-09-14
KSU_VERSION="32630"

# ----------------------------------------------------------------- SuSFS ---
# Kernel-side only: userspace policy/tooling remains a separately installed
# module. This is ShirkNeko's maintained v2.2.0 source, backported from its
# Android 12 / Linux 5.10 patch to this device's Linux 4.9.337 tree.
SUSFS_URL="https://github.com/ShirkNeko/susfs4ksu"
SUSFS_BRANCH="gki-android12-5.10"
SUSFS_REF="c5723cc09c79b57a25f24212b8bfe6e255ea3eef"
SUSFS_VERSION="v2.2.0"
SUSFS_KERNEL_PATCH="caymanslm-susfs-v2.2.0-4.9-backport.patch"

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

# A STOCK boot image, used only as a donor for the ramdisk and header when
# building a `fastboot boot` trial image. boot_b is the untouched slot (boot_a
# currently carries the EDL kernel swap); its ramdisk is stock either way.
#
# Header is v2 with a SEPARATE dtb section, os_version 11.0.0,
# os_patch_level 2022-06. All of that is preserved verbatim -- see mkboot.sh.
SIBLING_REPO="${SIBLING_REPO:-/mnt/e/orangefox_caymanslm}"
STOCK_BOOT_IMG="${STOCK_BOOT_IMG:-$SIBLING_REPO/artifacts/edl-backup/boot_b-stock.img}"

# ------------------------------------------------------------ workspace ---
# Deliberately OUTSIDE the OrangeFox tree: patching ~/fox/kernel/lge/sdm845
# would put KSU/SuSFS code into the tree the recovery builds from, and
# `repo sync` would wipe it.
# The active, reproducible SuSFS v2.2 replay tree.  Keeping this explicit
# avoids silently building the older /home/.../caymanslm-kernel tree, whose
# KernelSU/SuSFS integration is not the one being tested on the device.
# Branch backslashxx-ksu builds in its OWN workspace so the known-good KSU-Next
# v1.1 tree (susfs-v2-replay) the device runs is never clobbered by this
# experiment. Set WORKSPACE explicitly to override.
WORKSPACE="${WORKSPACE:-$HOME/caymanslm-kernel/backslashxx}"
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

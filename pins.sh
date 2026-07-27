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
KSU_REF="53791c92bff13d62338f29cc9da035a37652ca91"   # 2026-07-20

# ----------------------------------------------------------------- SuSFS ---
# Kernel-side only, by decision: this repo produces a SuSFS-capable kernel; the
# ksu_susfs tool and ksu_module_susfs hiding module are installed separately.
#
# LATEST, not the 4.9 branch. `kernel-4.9` is frozen at 2025-02-23 / v1.5.5 and
# is a dead end -- see CLAUDE.md. The gki-* branches are actively maintained
# (v2.2.0), and susfs.h carries a NON-GKI variant, so the codebase itself still
# supports non-GKI kernels. The cost is that its kernel-side patch is written
# against 5.10 and must be backported to 4.9.
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_BRANCH="gki-android12-5.10"
SUSFS_VERSION="v2.2.0"                # asserted in dmesg after flashing
SUSFS_KERNEL_PATCH="50_add_susfs_in_gki-android12-5.10.patch"   # needs 4.9 backport

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
WORKSPACE="${WORKSPACE:-$HOME/caymanslm-kernel}"
KERNEL_SRC="$WORKSPACE/src"
KERNEL_OUT="$WORKSPACE/build"
THIRD_PARTY="$WORKSPACE/third_party"

# --------------------------------------------------------------- device ---
# Refuse to touch anything that is not this phone, the way the sibling repo's
# EDL script does. Not the 5G Velvet (caymanlm / SDM765G).
DEVICE="caymanslm"

# Build identity, so `uname -a` proves which build is actually running. The
# recovery project lost many cycles to a flash that silently did not take.
KBUILD_USER="noamtu123"
KBUILD_HOST="caymanslm-kernel"

# Present only in an EDL-capable kernel. Asserted on every built artifact --
# the same marker patch-android-edl-boot.ps1 uses. If this string is missing,
# `adb reboot edl` is dead and so is the last-resort recovery path.
EDL_MARKER="Failed to set secure EDLOAD mode"

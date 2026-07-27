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
# Two pins, used at different phases:
#   KSU_REF        Phase 4: KernelSU Next alone. Latest legacy release.
#   KSU_SUSFS_REF  Phase 5 candidate: a legacy release that already carries
#                  SUSFS in-tree (its kernel/Kconfig defines the full
#                  KSU_SUSFS_* menu alongside KSU_MANUAL_HOOK). If it works it
#                  removes the 18-file hand-merge of susfs4ksu's
#                  10_enable_susfs_for_ksu.patch entirely.
#                  UNVERIFIED: it may expect a newer SUSFS than the frozen
#                  kernel-4.9 branch's v1.5.5 -- it advertises SUS_MAP and
#                  HIDE_KSU_SUSFS_SYMBOLS, which v1.5.5 does not have. Confirm
#                  the kernel-side/KSU-side versions agree before relying on it.
KSU_URL="https://github.com/KernelSU-Next/KernelSU-Next"
KSU_TAG="v3.2.0-legacy"
KSU_REF="9b08e88862000d5c50fb2e43a5b75123cf472e54"
KSU_SUSFS_TAG="v3.1.0-legacy-susfs"
KSU_SUSFS_REF="ba4422f0556e10f40dda1887631d87a18ede4ec5"

# ----------------------------------------------------------------- SuSFS ---
# Kernel-side only, by decision: this repo produces a SuSFS-capable kernel; the
# ksu_susfs tool and ksu_module_susfs hiding module are installed separately.
# The kernel-4.9 branch is FROZEN at 2025-02-23 / SUSFS_VERSION v1.5.5 while
# every gki-* branch moved on to a v2.0.0-era codebase.
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_BRANCH="kernel-4.9"
SUSFS_REF="41ba0b533b8524a0ba95a5952506a75f17355450"
SUSFS_VERSION="v1.5.5"                # asserted in dmesg after flashing

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

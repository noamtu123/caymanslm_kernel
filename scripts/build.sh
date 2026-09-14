#!/usr/bin/env bash
# build.sh -- standalone kernel build, outside any AOSP tree.
#
# The OrangeFox tree builds this kernel through TWRP's
# vendor/twrp/build/tasks/kernel.mk, which iterating via `mka recoveryimage` is
# far too slow to develop against. This reproduces that toolchain invocation
# directly. Verified 2026-07-27 against the live tree:
#
#   - LLVM=1 LLVM_IAS=1 (NOT AndroidKernel.mk's REAL_CC scheme -- that file is
#     dead code on this path)
#   - no GCC cross-toolchain is present or needed
#   - but CROSS_COMPILE is NOT inert: on 4.9 it supplies clang's target triple
#     (Makefile:531 `CLANG_TRIPLE ?= $(CROSS_COMPILE)`). Leave it unset and
#     clang silently builds for the x86_64 host, which fails in asm-offsets.c
#     with "register 'sp' unsuitable" and "out of range for constraint 'I'".
#   - CROSS_COMPILE_ARM32 must be set to something NON-EMPTY, see below
#
# Usage: ./scripts/build.sh [--clean] [--check-config] [--profile baseline|release|debug]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

CLEAN=0
CHECK_CONFIG=0
PROFILE="baseline"
for arg in "$@"; do
  case "$arg" in
    --clean)        CLEAN=1 ;;
    --check-config) CHECK_CONFIG=1 ;;
    --profile=baseline) PROFILE="baseline" ;;
    --profile=release)  PROFILE="release" ;;
    --profile=debug)    PROFILE="debug" ;;
    *) echo "error: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

[ -d "$KERNEL_SRC" ] || { echo "error: no kernel source at $KERNEL_SRC -- run scripts/setup-tree.sh first" >&2; exit 1; }
[ -x "$TOOLCHAIN_DIR/bin/clang" ] || { echo "error: no clang at $TOOLCHAIN_DIR/bin/clang. Set TOOLCHAIN_DIR." >&2; exit 1; }

# Prefer the AOSP prebuilt make/flex/bison when available -- that is what built
# the known-good reference .config -- but do not hard-require the whole
# OrangeFox tree just to compile a kernel.
MAKE_BIN="make"
[ -x "$BUILD_TOOLS_DIR/bin/make" ] && MAKE_BIN="$BUILD_TOOLS_DIR/bin/make"

export PATH="$TOOLCHAIN_DIR/bin:${BUILD_TOOLS_DIR}/bin:${LINEAGE_TOOLS_DIR}/bin:$PATH"
[ -d "$PERL5LIB_DIR" ] && export PERL5LIB="$PERL5LIB_DIR"

if [ "$CLEAN" = "1" ]; then
  echo "Removing $KERNEL_OUT ..."
  rm -rf "$KERNEL_OUT"
fi
mkdir -p "$KERNEL_OUT"

# KBUILD_BUILD_USER/HOST are load-bearing, not cosmetic: they are how `uname -a`
# proves the phone is running THIS build. Flashing here has silently left an old
# image running before.
KMAKE=(
  "$MAKE_BIN" -C "$KERNEL_SRC" O="$KERNEL_OUT"
  -j"$(nproc)"
  ARCH=arm64
  LLVM=1 LLVM_IAS=1
  # Supplies clang's --target. No aarch64-linux-gnu-* binary needs to exist:
  # LLVM=1 provides the assembler and binutils, and the GCC_TOOLCHAIN_DIR
  # lookup at Makefile:536 simply resolves empty. A *-linux-android- prefix is
  # deliberately avoided -- Makefile:534 hard-errors on an Android triple
  # unless CLANG_TRIPLE overrides it.
  CROSS_COMPILE=aarch64-linux-gnu-
  CLANG_TRIPLE=aarch64-linux-gnu-
  HOSTCC=clang HOSTCXX=clang++
  LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
  KBUILD_BUILD_USER="$KBUILD_USER"
  KBUILD_BUILD_HOST="$KBUILD_HOST"
  # CONFIG_COMPAT_VDSO=y, and arch/arm64/Makefile hard-errors on an empty
  # CROSS_COMPILE_ARM32. Only non-emptiness is checked: under clang the compat
  # vDSO is compiled by CC_ARM32 = clang --target=arm-linux-gnueabi, and the
  # prefix is used solely to locate a GCC toolchain via `which $(..)ld`. That
  # lookup fails here, leaving --gcc-toolchain/--prefix empty -- which is
  # exactly what the known-good OrangeFox build does, since the path IT passes
  # ($FOX/prebuilts/gcc/linux-x86/arm/...) does not exist in the tree either.
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)
[ -x "$LINEAGE_TOOLS_DIR/bin/lz4c" ] && KMAKE+=(LZ4="$LINEAGE_TOOLS_DIR/bin/lz4c")

echo "Configuring ($KERNEL_DEFCONFIG) ..."
"${KMAKE[@]}" "$KERNEL_DEFCONFIG"

# Config fragments are merged after the defconfig so a feature can be added
# without forking the defconfig itself.  The default baseline is deliberately
# limited to the proved KSU/SUSFS fragment; release/debug changes require an
# explicit profile and can never silently alter a recovery build.
fragments=("$HERE/config/ksu.fragment" "$HERE/config/nomount.fragment" "$HERE/config/diag.fragment")
if [ "$PROFILE" != "baseline" ]; then
  profile_fragment="$HERE/config/profiles/$PROFILE.fragment"
  [ -f "$profile_fragment" ] || { echo "error: unknown build profile '$PROFILE'" >&2; exit 1; }
  fragments+=("$profile_fragment")
fi
# EXTRA_FRAGMENT goes LAST so it wins: later lines override earlier ones in a
# concatenated .config. It is the explicit, opt-in, per-invocation fragment, so a
# profile default must not silently defeat it -- release.fragment carries
# `# CONFIG_FUNCTION_TRACER is not set` for stealth, which used to cancel a
# diagnostic fragment asking for the tracer and left the build quietly missing
# the instrument it was made for.
[ -n "${EXTRA_FRAGMENT:-}" ] && fragments+=("$HERE/config/$EXTRA_FRAGMENT")
if [ ${#fragments[@]} -gt 0 ]; then
  echo "Merging config fragments (profile: $PROFILE) ..."
  for f in "${fragments[@]}"; do
    echo "  $(basename "$f")"
    cat "$f" >> "$KERNEL_OUT/.config"
  done
  "${KMAKE[@]}" olddefconfig
fi

# Branch backslashxx-ksu: backslashxx + syscall-table hooking + SuSFS (phase 2)
# + NoMount (phase 3).
required_root_config=(
  CONFIG_KSU
  CONFIG_KSU_TAMPER_SYSCALL_TABLE
  CONFIG_KSU_SUSFS
  CONFIG_KSU_SUSFS_SUS_PATH
  CONFIG_KSU_SUSFS_SUS_MOUNT
  CONFIG_KSU_SUSFS_SUS_KSTAT
  CONFIG_KSU_SUSFS_SUS_MAP
  CONFIG_KSU_SUSFS_OPEN_REDIRECT
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  CONFIG_KSU_SUSFS_SPOOF_UNAME
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
  CONFIG_KSU_SUSFS_ENABLE_LOG
  CONFIG_SECURITY_DMESG_RESTRICT
  CONFIG_NOMOUNT
  CONFIG_LOCKUP_DETECTOR
  CONFIG_DETECT_HUNG_TASK
)
# BISECT=1 relaxes the root-stack assertions so a deliberately crippled kernel can
# be built to bisect a bug (e.g. "does the crash survive with SuSFS off?").  Such a
# build is a diagnostic only and must never be shipped -- hence the loud banner and
# the fact that it cannot be reached from a plain ./scripts/build.sh invocation.
if [ "${BISECT:-0}" = "1" ]; then
  echo "############################################################" >&2
  echo "## BISECT=1: root-stack config assertions are DISABLED.    ##" >&2
  echo "## This build is a diagnostic. DO NOT SHIP IT.             ##" >&2
  echo "############################################################" >&2
fi

for symbol in "${required_root_config[@]}"; do
  if ! grep -qx "$symbol=y" "$KERNEL_OUT/.config"; then
    if [ "${BISECT:-0}" = "1" ]; then
      echo "  bisect: $symbol is NOT enabled (assertion skipped)" >&2
      continue
    fi
    echo "error: required root-stack option $symbol is not enabled" >&2
    exit 1
  fi
done
if ! grep -qx 'CONFIG_IKCONFIG_PROC=y' "$KERNEL_OUT/.config"; then
  echo "error: /proc/config.gz is required for Android VINTF compatibility" >&2
  exit 1
fi

if [ "$PROFILE" = "release" ]; then
  required_release_config=(
    'CONFIG_KALLSYMS=y'
    'CONFIG_KALLSYMS_BASE_RELATIVE=y'
    'CONFIG_SECURITY_DMESG_RESTRICT=y'
    'CONFIG_PSTORE=y'
    'CONFIG_PSTORE_RAM=y'
    # Fail closed: a corrupted kernel must stop, not run with half-broken
    # root-hiding that exposes root to a detector. --profile=debug flips it off.
    'CONFIG_PANIC_ON_OOPS=y'
  )
  for expected in "${required_release_config[@]}"; do
    if ! grep -qx "$expected" "$KERNEL_OUT/.config"; then
      echo "error: release profile requires $expected" >&2
      exit 1
    fi
  done
  forbidden_release_config=(
    'CONFIG_KALLSYMS_ALL=y'
    'CONFIG_KPROBES=y'
    'CONFIG_FUNCTION_TRACER=y'
    'CONFIG_DYNAMIC_DEBUG=y'
    'CONFIG_PROC_KCORE=y'
    'CONFIG_DEVMEM=y'
    'CONFIG_DEVKMEM=y'
    'CONFIG_DEBUG_INFO=y'
  )
  for forbidden in "${forbidden_release_config[@]}"; do
    if grep -qx "$forbidden" "$KERNEL_OUT/.config"; then
      if [ "${BISECT:-0}" = "1" ]; then
        echo "  bisect: release profile has $forbidden (DIAGNOSTIC, forbidden check skipped)" >&2
      else
        echo "error: release profile must not enable $forbidden" >&2
        exit 1
      fi
    fi
  done
fi

# The Phase 1 correctness gate. If our standalone .config differs from the one
# the known-good OrangeFox build produced, the recipe is wrong and every result
# downstream of it is untrustworthy. Only meaningful with no fragments merged.
if [ "$CHECK_CONFIG" = "1" ]; then
  if [ ! -f "$REFERENCE_CONFIG" ]; then
    echo "error: reference config not found at $REFERENCE_CONFIG" >&2
    exit 1
  fi
  echo "Comparing against the known-good reference .config ..."
  if diff -u "$REFERENCE_CONFIG" "$KERNEL_OUT/.config" > "$WORKSPACE/config.diff"; then
    echo "  identical to $REFERENCE_CONFIG"
  else
    echo "error: .config differs from the reference. See $WORKSPACE/config.diff" >&2
    head -40 "$WORKSPACE/config.diff" >&2
    exit 1
  fi
fi

echo "Building Image.gz-dtb ..."
"${KMAKE[@]}" Image.gz-dtb

IMAGE="$KERNEL_OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$IMAGE" ] || { echo "error: build finished but $IMAGE is missing" >&2; exit 1; }

echo ""
echo "Built: $IMAGE ($(stat -c%s "$IMAGE") bytes)"
"$HERE/scripts/verify-image.sh" "$IMAGE"

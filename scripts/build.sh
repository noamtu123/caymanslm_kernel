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
# Usage: ./scripts/build.sh [--clean] [--check-config]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

CLEAN=0
CHECK_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --clean)        CLEAN=1 ;;
    --check-config) CHECK_CONFIG=1 ;;
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
# without forking the defconfig itself. Empty until Phase 4.
shopt -s nullglob
fragments=("$HERE"/config/*.fragment)
shopt -u nullglob
if [ ${#fragments[@]} -gt 0 ]; then
  echo "Merging config fragments ..."
  for f in "${fragments[@]}"; do
    echo "  $(basename "$f")"
    cat "$f" >> "$KERNEL_OUT/.config"
  done
  "${KMAKE[@]}" olddefconfig
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

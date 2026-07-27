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
#   - no GCC cross-toolchain is present or needed; LLVM=1 makes CROSS_COMPILE
#     inert, and this tree's compat-vdso Makefile has no CROSS_COMPILE_ARM32
#     reference so CONFIG_COMPAT_VDSO=y builds with clang alone
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
  HOSTCC=clang HOSTCXX=clang++
  LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
  KBUILD_BUILD_USER="$KBUILD_USER"
  KBUILD_BUILD_HOST="$KBUILD_HOST"
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

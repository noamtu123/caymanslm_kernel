#!/usr/bin/env bash
# package.sh -- produce the two deliverables for a built kernel.
#
#   artifacts/caymanslm-kernel-<date>-<rev>.zip   AnyKernel3, flashed in OrangeFox
#   artifacts/boot-trial.img                      throwaway, for `fastboot boot`
#
# Always RAM-boot the trial image first. Only install the zip once that proves
# the kernel is alive.
#
# Usage: ./scripts/package.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

IMAGE_GZ="$KERNEL_OUT/arch/arm64/boot/Image.gz"
IMAGE_GZ_DTB="$KERNEL_OUT/arch/arm64/boot/Image.gz-dtb"
for f in "$IMAGE_GZ" "$IMAGE_GZ_DTB"; do
  [ -f "$f" ] || { echo "error: $f missing -- run scripts/build.sh first" >&2; exit 1; }
done

# Never package a kernel that has not passed the assertions.
"$HERE/scripts/verify-image.sh" "$IMAGE_GZ_DTB"

ARTIFACTS="$WORKSPACE/artifacts"
AK3="$THIRD_PARTY/AnyKernel3"
mkdir -p "$ARTIFACTS" "$THIRD_PARTY"

# ------------------------------------------------------------ AnyKernel3 ---
if [ ! -d "$AK3/.git" ]; then
  echo "Cloning AnyKernel3 ..."
  git clone -q "$ANYKERNEL_URL" "$AK3"
fi
git -C "$AK3" fetch -q --no-tags origin || true
git -C "$AK3" checkout -q --detach "$ANYKERNEL_REF"
ACTUAL="$(git -C "$AK3" rev-parse HEAD)"
[ "$ACTUAL" = "$ANYKERNEL_REF" ] || { echo "error: AnyKernel3 at $ACTUAL, expected $ANYKERNEL_REF" >&2; exit 1; }

# Start from a pristine checkout each time so a previous run's kernel can never
# be shipped by accident.
git -C "$AK3" clean -fdq
git -C "$AK3" checkout -q -- .

cp "$HERE/anykernel/anykernel.sh" "$AK3/anykernel.sh"

# --- the kernel/dtb split ----------------------------------------------------
# See anykernel/anykernel.sh: the boot image has a separate dtb section, so ship
# Image.gz as the kernel and the appended DTB as a standalone dtb. Shipping
# Image.gz-dtb alone would leave the stock A11 dtb in place next to our kernel.
GZ_SIZE=$(stat -c%s "$IMAGE_GZ")
DTB_SIZE=$(( $(stat -c%s "$IMAGE_GZ_DTB") - GZ_SIZE ))
[ "$DTB_SIZE" -gt 0 ] || { echo "error: no appended DTB found in Image.gz-dtb" >&2; exit 1; }

cp "$IMAGE_GZ" "$AK3/Image.gz"
tail -c "$DTB_SIZE" "$IMAGE_GZ_DTB" > "$AK3/dtb"

MAGIC="$(head -c4 "$AK3/dtb" | od -An -tx1 | tr -d ' \n')"
[ "$MAGIC" = "d00dfeed" ] || { echo "error: dtb magic is '$MAGIC', expected d00dfeed" >&2; exit 1; }

# dtbo must never be shipped -- LG's overlays in dtbo_a have to keep applying.
rm -f "$AK3/dtbo" "$AK3/dtbo.img"

# ------------------------------------------------------------------- zip ---
REV="$(git -C "$KERNEL_SRC" rev-parse --short HEAD)"

# Tag the filename with what is actually IN the kernel, read back from the
# built .config rather than from what we think we enabled. The kernel SHA and
# date alone are not distinguishing: a stock and a KernelSU build of the same
# source on the same day would otherwise be given identical names, which is a
# good way to flash the wrong one.
TAGS=""
grep -q '^CONFIG_KSU=y' "$KERNEL_OUT/.config" 2>/dev/null && TAGS="${TAGS}-ksu"
grep -q '^CONFIG_KSU_SUSFS=y' "$KERNEL_OUT/.config" 2>/dev/null && TAGS="${TAGS}-susfs"
[ -n "$TAGS" ] || TAGS="-stock"

NAME="caymanslm-kernel-$(date +%Y%m%d)-${REV}${TAGS}.zip"
ZIP="$ARTIFACTS/$NAME"
rm -f "$ZIP"
( cd "$AK3" && zip -qr9 "$ZIP" . -x '.git/*' '.github/*' 'README.md' )
[ -f "$ZIP" ] || { echo "error: zip was not produced" >&2; exit 1; }

# The install variables must be spelled the way the BUNDLED ak3-core.sh reads
# them. This base reads BLOCK/IS_SLOT_DEVICE; older ones read block/is_slot_device
# and nothing maps between the two. A mismatch is silent at package time and only
# shows up on the phone as "Unable to determine  partition" -- the doubled space
# being an empty $BLOCK. Assert the spelling the shipped core actually consumes.
for var in BLOCK IS_SLOT_DEVICE; do
  if ! grep -qE "^${var}=" "$AK3/anykernel.sh"; then
    echo "error: anykernel.sh does not set $var (lowercase spelling is not read" >&2
    echo "       by the bundled tools/ak3-core.sh and installs will abort)" >&2
    exit 1
  fi
  grep -q "\$$var" "$AK3/tools/ak3-core.sh" || {
    echo "error: bundled ak3-core.sh never reads \$$var -- AnyKernel base changed" >&2
    echo "       its variable convention; re-check anykernel.sh against it" >&2
    exit 1
  }
done

# ---------------------------------------------------------- trial image ---
"$HERE/scripts/mkboot.sh" "$ARTIFACTS/boot-trial.img"

cat <<EOF

Packaged:
  $ZIP
  $ARTIFACTS/boot-trial.img

Order of operations:
  1. fastboot boot $ARTIFACTS/boot-trial.img
  2. adb shell uname -a          # must show $KBUILD_HOST -- otherwise it is a stale image
  3. only then: adb push "$ZIP" /tmp/  and install it from OrangeFox (one slot)
EOF

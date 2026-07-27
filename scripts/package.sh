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
NAME="caymanslm-kernel-$(date +%Y%m%d)-${REV}.zip"
ZIP="$ARTIFACTS/$NAME"
rm -f "$ZIP"
( cd "$AK3" && zip -qr9 "$ZIP" . -x '.git/*' '.github/*' 'README.md' )
[ -f "$ZIP" ] || { echo "error: zip was not produced" >&2; exit 1; }

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

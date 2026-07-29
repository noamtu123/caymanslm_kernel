#!/usr/bin/env bash
# mkboot.sh -- build a throwaway boot.img for `fastboot boot`.
#
# This is the trial path: RAM-boot a new kernel and prove it works before
# anything is written to flash. `fastboot boot <img>` is the only method that
# reliably ran fresh code on this device -- flashing a partition and rebooting
# has silently left an OLD image running.
#
# It reproduces exactly the arrangement already proven on the phone by
# orangefox_caymanslm/edl-boot-script/patch-android-edl-boot.ps1: take a stock
# boot image, replace its kernel and dtb with ours, and leave the header and
# ramdisk completely alone.
#
# Note the split. The stock boot image is header v2 with a SEPARATE dtb
# section, while our build emits Image.gz-dtb (dtb appended to the kernel). So
# the kernel section gets Image.gz and the dtb section gets the appended tail --
# which is what magiskboot's kernel/kernel_dtb split does in that script.
#
# Usage: ./scripts/mkboot.sh [output.img]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

OUT_IMG="${1:-$WORKSPACE/artifacts/boot-trial.img}"
UNPACK="$MKBOOTIMG_DIR/unpack_bootimg.py"
MKBOOT="$MKBOOTIMG_DIR/mkbootimg.py"

[ -f "$UNPACK" ] && [ -f "$MKBOOT" ] || { echo "error: mkbootimg tools not found in $MKBOOTIMG_DIR. Set MKBOOTIMG_DIR." >&2; exit 1; }
[ -f "$STOCK_BOOT_IMG" ] || { echo "error: stock donor boot image not found: $STOCK_BOOT_IMG" >&2; exit 1; }

IMAGE_GZ="$KERNEL_OUT/arch/arm64/boot/Image.gz"
IMAGE_GZ_DTB="$KERNEL_OUT/arch/arm64/boot/Image.gz-dtb"
for f in "$IMAGE_GZ" "$IMAGE_GZ_DTB"; do
  [ -f "$f" ] || { echo "error: $f missing -- run scripts/build.sh first" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- take the stock ramdisk and the exact header ----------------------------
# --format=mkbootimg emits the precise argument list needed to rebuild this
# image, so nothing about the header is guessed. os_version / os_patch_level in
# particular must be preserved verbatim: vold rewrites the on-disk FBE keyblobs
# during decrypt, and a HIGHER os_version upgrades them past what the ROM can
# present, permanently breaking /data decryption.
echo "Unpacking stock donor: $STOCK_BOOT_IMG"
mapfile -t ARGS < <(python3 "$UNPACK" --boot_img "$STOCK_BOOT_IMG" --out "$WORK/stock" --format=mkbootimg | xargs -n1 printf '%s\n')
[ ${#ARGS[@]} -gt 0 ] || { echo "error: could not read the stock boot header" >&2; exit 1; }
[ -f "$WORK/stock/ramdisk" ] || { echo "error: stock image yielded no ramdisk" >&2; exit 1; }

# --- split our appended-dtb kernel ------------------------------------------
GZ_SIZE=$(stat -c%s "$IMAGE_GZ")
DTB_SIZE=$(( $(stat -c%s "$IMAGE_GZ_DTB") - GZ_SIZE ))
if [ "$DTB_SIZE" -le 0 ]; then
  echo "error: Image.gz-dtb is not larger than Image.gz -- no appended DTB found" >&2
  exit 1
fi
cp "$IMAGE_GZ" "$WORK/our-kernel"
tail -c "$DTB_SIZE" "$IMAGE_GZ_DTB" > "$WORK/our-dtb"
echo "  kernel $(stat -c%s "$WORK/our-kernel") bytes, appended dtb $DTB_SIZE bytes"

# Sanity: a real appended DTB starts with the device-tree magic 0xd00dfeed.
MAGIC="$(head -c4 "$WORK/our-dtb" | od -An -tx1 | tr -d ' \n')"
[ "$MAGIC" = "d00dfeed" ] || { echo "error: appended DTB has magic '$MAGIC', expected d00dfeed" >&2; exit 1; }

# --- repack, substituting only kernel and dtb -------------------------------
# Rewrite just the --kernel and --dtb paths in the stock argument list; every
# other field (ramdisk, cmdline, offsets, pagesize, os_version) passes through
# untouched. That is the whole change.
FINAL=()
skip=0
for i in "${!ARGS[@]}"; do
  if [ "$skip" = "1" ]; then skip=0; continue; fi
  case "${ARGS[$i]}" in
    --kernel)  FINAL+=(--kernel "$WORK/our-kernel");        skip=1 ;;
    --dtb)     FINAL+=(--dtb "$WORK/our-dtb");              skip=1 ;;
    --ramdisk) FINAL+=(--ramdisk "$WORK/stock/ramdisk");    skip=1 ;;
    *)         FINAL+=("${ARGS[$i]}") ;;
  esac
done

mkdir -p "$(dirname "$OUT_IMG")"
python3 "$MKBOOT" "${FINAL[@]}" --output "$OUT_IMG"

# Verify the image we will hand to fastboot, rather than trusting mkbootimg's
# successful exit.  This catches a section-order or argument-rewrite error
# before a RAM-boot trial: only our kernel and DTB may differ from the donor.
VERIFY="$WORK/repacked"
python3 "$UNPACK" --boot_img "$OUT_IMG" --out "$VERIFY" >/dev/null
cmp -s "$WORK/our-kernel" "$VERIFY/kernel" || {
  echo "error: repacked kernel does not match the built Image.gz" >&2
  exit 1
}
cmp -s "$WORK/our-dtb" "$VERIFY/dtb" || {
  echo "error: repacked DTB does not match the built Image.gz-dtb tail" >&2
  exit 1
}
cmp -s "$WORK/stock/ramdisk" "$VERIFY/ramdisk" || {
  echo "error: repacking changed the stock ramdisk" >&2
  exit 1
}
echo "  verified repack: built kernel/DTB + untouched stock ramdisk"

echo ""
echo "Trial image: $OUT_IMG ($(stat -c%s "$OUT_IMG") bytes)"
echo ""
echo "RAM-boot it (writes NOTHING to flash):"
echo "    fastboot boot $OUT_IMG"
echo ""
echo "Then confirm the phone is actually running it, not a stale image:"
echo "    adb shell uname -a      # expect $KBUILD_HOST"

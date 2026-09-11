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
# Two donor shapes exist and both are handled:
#
#   * SEPARATE-DTB donor (the LG stock boot image, header v2). Our build emits
#     Image.gz-dtb (dtb appended to the kernel), so the kernel section gets
#     Image.gz and the dtb section gets the appended tail -- what magiskboot's
#     kernel/kernel_dtb split does in that script.
#
#   * APPENDED-DTB donor (a LIVE boot_a/boot_b pulled off the phone after an
#     AnyKernel3 flash). AnyKernel3 writes Image.gz-dtb straight into the kernel
#     section and leaves no dtb section at all, so there is no --dtb to
#     substitute; the whole Image.gz-dtb replaces the kernel section instead.
#     Pulling a LIVE donor matters: a stale donor's ramdisk no longer matches the
#     installed ROM and the RAM-boot lands in recovery.
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
# KERNEL_IMAGE override: point at any prebuilt Image.gz-dtb instead of the one in
# KERNEL_OUT. Lets a SHIPPED artifact (e.g. a release AnyKernel3 zip's kernel) be
# RAM-booted against a live donor, which is how you re-verify a release baseline.
IMAGE_GZ_DTB="${KERNEL_IMAGE:-$IMAGE_GZ_DTB}"
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

# --- does this donor carry a separate dtb section? --------------------------
DONOR_HAS_DTB=0
for a in "${ARGS[@]}"; do [ "$a" = "--dtb" ] && DONOR_HAS_DTB=1; done

# --- split our appended-dtb kernel, ONLY if the donor needs a dtb section ----
# The split assumes IMAGE_GZ and IMAGE_GZ_DTB come from the SAME build. With a
# KERNEL_IMAGE override (a shipped artifact) they do not, and an appended-dtb
# donor needs no split at all -- so only do it where it is actually used.
if [ "$DONOR_HAS_DTB" = "1" ]; then
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
fi

# --- repack, substituting only kernel and dtb -------------------------------
# Rewrite just the --kernel and --dtb paths in the stock argument list; every
# other field (ramdisk, cmdline, offsets, pagesize, os_version) passes through
# untouched. That is the whole change.
# With a separate-dtb donor the kernel section takes Image.gz and the dtb
# section takes the appended tail. With an appended-dtb donor there is no dtb
# section, so the kernel section takes the whole Image.gz-dtb.
if [ "$DONOR_HAS_DTB" = "1" ]; then
  KERNEL_SECTION="$WORK/our-kernel"
  echo "  donor has a separate dtb section: kernel=Image.gz + dtb=appended tail"
else
  KERNEL_SECTION="$IMAGE_GZ_DTB"
  echo "  donor has NO dtb section (AnyKernel3-style): kernel=Image.gz-dtb"
fi

FINAL=()
skip=0
for i in "${!ARGS[@]}"; do
  if [ "$skip" = "1" ]; then skip=0; continue; fi
  case "${ARGS[$i]}" in
    --kernel)  FINAL+=(--kernel "$KERNEL_SECTION");         skip=1 ;;
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
cmp -s "$KERNEL_SECTION" "$VERIFY/kernel" || {
  echo "error: repacked kernel does not match what we handed mkbootimg" >&2
  exit 1
}
if [ "$DONOR_HAS_DTB" = "1" ]; then
  cmp -s "$WORK/our-dtb" "$VERIFY/dtb" || {
    echo "error: repacked DTB does not match the built Image.gz-dtb tail" >&2
    exit 1
  }
fi
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

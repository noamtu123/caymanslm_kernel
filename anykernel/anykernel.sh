# AnyKernel3 configuration -- LG Velvet 4G (caymanslm / LM-G910EMW)
#
# Replaces the kernel while preserving the existing ramdisk, which is what lets
# one zip serve both stock Android 12 and LineageOS later.
#
# TWO files are installed, not one. The boot image on this device is header v2
# with a SEPARATE dtb section, but the kernel builds as Image.gz-dtb (dtb
# appended). So package.sh splits it and ships Image.gz as the kernel plus a
# standalone dtb. Shipping Image.gz-dtb alone would pair our kernel with the
# stock A11 dtb still sitting in the boot image. This split is the arrangement
# already proven on the phone by the EDL boot-swap script.
#
# dtbo is deliberately NOT shipped. LG's device-tree overlays in dtbo_a must
# keep applying untouched -- that is one of the two properties that makes a
# Lineage-sourced kernel boot LG stock at all.

properties() { '
kernel.string=caymanslm_Wraith_v1.1-KernelSU-Next-SUSFS
do.devicecheck=1
do.initd=0
do.kernel=1
do.modules=0
do.systemless=0
do.cleanup=1
device.name1=caymanslm
device.name2=LM-G910EMW
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# shell variables
#
# UPPERCASE, and that is not cosmetic. This AnyKernel base (AK_BASE_VERSION
# 20260704) reads BLOCK / IS_SLOT_DEVICE / RAMDISK_COMPRESSION /
# PATCH_VBMETA_FLAG directly; nothing maps the older lowercase spellings onto
# them. With lowercase names every one of these is empty at install time, and
# the flash dies as "Unable to determine  partition" -- note the doubled space
# where the empty $BLOCK expanded. Check tools/ak3-core.sh before renaming.
#
# Bare partition NAME, not a full path: ak3-core.sh's fallback branch walks
# /dev/block/by-name, /dev/block/bootdevice/by-name and both
# /dev/block/platform/*/by-name layouts, trying boot$SLOT before boot. A full
# path would instead probe one hardcoded location, and /dev/block/bootdevice is
# populated by Android's ueventd -- not reliably present in recovery, which is
# where this zip is actually flashed. This device has no bare `boot` node
# either, only boot_a -> sde11 and boot_b -> sde32.
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import the AnyKernel install methods
. tools/ak3-core.sh;

# Refuse to touch anything that is not this phone. do.devicecheck above matches
# on ro.product.device; this is the same belt-and-braces guard the sibling
# repo's EDL script uses, because a foreign kernel written into someone's boot
# is not a recoverable mistake for them.
#
# The model line is a fixed label, not a build.prop read: do.devicecheck has
# already refused any non-caymanslm device by this point, and file_getprop
# returns empty in recovery (/system is not mounted here) -- that is why the old
# line rendered a bare "Device:".
#
# The banner is the standard figlet "Wraith" inside a frame. It is fed through a
# single-quoted here-doc and printed line-by-line with `read -r`, so the ` \ ' |
# characters it contains are emitted verbatim -- putting them straight into
# ui_print "..." would let the shell treat the backtick as a command substitution.
#
# The frame is not decoration, it is load-bearing. The lower rows of a slanted
# figlet W need leading indentation, but flashers strip leading whitespace and do
# it inconsistently: OrangeFox strips ASCII 0x20 yet keeps U+00A0, while the KSUN
# in-app flasher strips U+00A0 too. Any *invisible* indent therefore fails in one
# of them. Starting every line with a visible '|' or '+' (never stripped, both
# flashers are monospace) makes the indent internal, so the slant renders the same
# everywhere. Targets the English/LTR reader; a Hebrew (RTL) system language still
# right-aligns/mirrors it -- a local-locale limitation the owner accepts.
ui_print " ";
while IFS= read -r _wl; do ui_print "$_wl"; done <<'WRAITH_ART'
+------------------------------------------+
| __        __              _  _    _      |
| \ \      / / _ __   __ _ (_)| |_ | |__   |
|  \ \ /\ / / | '__| / _` || || __|| '_ \  |
|   \ V  V /  | |   | (_| || || |_ | | | | |
|    \_/\_/   |_|    \__,_||_| \__||_| |_| |
|                                          |
| the wraith kernel   v1.1                 |
| KernelSU Next  +  SuSFS                  |
|                                          |
| Device: LM-G910EMW                       |
+------------------------------------------+
WRAITH_ART
ui_print " ";

dump_boot;

write_boot;

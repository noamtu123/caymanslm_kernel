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
kernel.string=caymanslm custom kernel (KernelSU Next + SuSFS) by noamtu123
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
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

# import the AnyKernel install methods
. tools/ak3-core.sh;

# Refuse to touch anything that is not this phone. do.devicecheck above matches
# on ro.product.device; this is the same belt-and-braces guard the sibling
# repo's EDL script uses, because a foreign kernel written into someone's boot
# is not a recoverable mistake for them.
ui_print " ";
ui_print "Device: $(file_getprop /system/build.prop ro.product.device)";

dump_boot;

write_boot;

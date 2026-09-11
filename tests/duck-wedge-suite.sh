#!/bin/bash
# Run N wedge trials against one kernel image, RAM-booting it before each trial.
#
#   usage: tests/duck-wedge-suite.sh <boot.img> <label> [runs] [max_seconds]
#
# The re-boot per trial is not optional: a wedge reboots the phone back to the
# FLASHED kernel, so trial 2 onwards would silently test a different kernel.
set -u
ADB=${ADB:-/c/adb/adb}
FB=${FB:-/c/adb/fastboot}
IMG=${1:?boot image}
LABEL=${2:?label}
RUNS=${3:-3}
SECS=${4:-200}
HERE=$(dirname "$0")

# What `uname -v` must report once this image is RAM-booted. A fastboot boot
# that silently fails leaves the previously FLASHED kernel running and the
# trial then measures the wrong kernel -- that has already produced one void
# result, so it is an assertion, not a log line.
WANT_KERNEL=$(python3 "$HERE/boot-img-version.py" "$IMG") || {
  echo "ABORT: cannot read kernel version out of $IMG"; exit 2; }
echo "image under test reports: $WANT_KERNEL"

for n in $(seq 1 "$RUNS"); do
  echo "--- $LABEL run $n: RAM-booting $(basename "$IMG") ---"
  "$ADB" wait-for-device >/dev/null 2>&1
  i=0; until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] || [ $i -ge 60 ]; do i=$((i+1)); sleep 3; done
  "$ADB" reboot bootloader >/dev/null 2>&1
  i=0; until "$FB" devices 2>/dev/null | grep -qi fastboot || [ $i -ge 40 ]; do i=$((i+1)); sleep 2; done
  # LG's bootloader reports the SoC, not the device codename -- getvar product
  # is "sdm845" here, which the 5G caymanlm would NOT match (SDM765G). Pair it
  # with the serial so the guard still names exactly one device.
  FB_PRODUCT=$("$FB" getvar product 2>&1 | sed -n 's/^product: *//p' | tr -d '\r')
  FB_SERIAL=$("$FB" devices 2>/dev/null | awk 'NR==1{print $1}')
  case "$FB_PRODUCT:$FB_SERIAL" in
    sdm845:LMG910EMW*) : ;;
    *) echo "ABORT: not the caymanslm in fastboot (product=$FB_PRODUCT serial=$FB_SERIAL)"; exit 2 ;;
  esac
  "$FB" boot "$IMG" >/dev/null 2>&1
  EXPECT_KERNEL="$WANT_KERNEL" "$HERE/duck-wedge-trial.sh" "${LABEL}_$n" "$SECS"
done

#!/bin/bash
# One Duck Detector wedge trial against whatever kernel is currently running.
#
#   usage: tests/duck-wedge-trial.sh <label> [max_seconds]
#   env:   EXPECT_APP  versionName fragment the installed APK must contain
#          OUTDIR      where the events log is written
#
# Preconditions are asserted, not assumed. A trial run against the wrong app
# build or the wrong kernel produces a plausible-looking result that means
# nothing, which has already invalidated one whole bisect.
set -u
ADB=${ADB:-/c/adb/adb}
LABEL=${1:?label}
MAX=${2:-240}
OUTDIR=${OUTDIR:-$(dirname "$0")/wedge-runs}
EXPECT_APP=${EXPECT_APP:-e5501bd712da}
PKG=com.eltavine.duckdetector
mkdir -p "$OUTDIR"

wait_boot () {
  "$ADB" wait-for-device
  local i=0
  until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] || [ $i -ge 60 ]; do
    i=$((i+1)); sleep 3
  done
}
boot_id () { "$ADB" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r'; }

wait_boot
[ "$("$ADB" shell getprop ro.product.device 2>/dev/null | tr -d '\r')" = caymanslm ] || {
  echo "ABORT: not caymanslm"; exit 2; }

# boot_completed can be set before the package manager answers queries; an empty
# reply here used to abort the run, so poll briefly for a real answer.
GOT_APP=""
for _ in $(seq 1 20); do
  GOT_APP=$("$ADB" shell "dumpsys package $PKG | grep versionName" 2>/dev/null | tr -d '\r' | head -1)
  [ -n "$GOT_APP" ] && break
  sleep 3
done
case "$GOT_APP" in
  *"$EXPECT_APP"*) : ;;
  *) echo "ABORT: wrong app build -- want *$EXPECT_APP*, got [$GOT_APP]"; exit 2 ;;
esac
KERNEL=$("$ADB" shell uname -v 2>/dev/null | tr -d '\r')
if [ -n "${EXPECT_KERNEL:-}" ] && [ "$KERNEL" != "$EXPECT_KERNEL" ]; then
  echo "ABORT: RAM-boot did not take -- want [$EXPECT_KERNEL], got [$KERNEL]"
  exit 2
fi
# PRE_TRIAL: a root shell command run on the device after boot, before the
# workload. Used to change device state a probe depends on (e.g. pinning the
# Gold cluster online so core_ctl cannot isolate it).
if [ -n "${PRE_TRIAL:-}" ]; then
  "$ADB" shell "su -c '$PRE_TRIAL'" >/dev/null 2>&1
  sleep 3
fi
GOLD_ISO=$("$ADB" shell "for c in 4 5 6 7; do printf '%s' \$(cat /sys/devices/system/cpu/cpu\$c/isolate 2>/dev/null); done" 2>/dev/null | tr -d '\r')

"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
"$ADB" shell input swipe 540 2000 540 700 200 >/dev/null 2>&1
"$ADB" shell am force-stop "$PKG" >/dev/null 2>&1
"$ADB" shell logcat -b all -c >/dev/null 2>&1
"$ADB" shell logcat -b events -v time > "$OUTDIR/$LABEL.events.log" 2>&1 &
EPID=$!

BOOTID_START=$(boot_id)
start=$(date +%s)
# test/deterministic clears every first-run gate, so a bare start is the whole
# workload: AppReadyShell creates all detector ViewModels eagerly.
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1

res=SURVIVED
for _ in $(seq 1 "$MAX"); do
  [ "$("$ADB" get-state 2>/dev/null)" = device ] || { res=LOST; break; }
  sleep 1
done
end=$(date +%s)
kill $EPID 2>/dev/null

# A real wedge REBOOTS the box. adb vanishing alone is not proof -- USB drops
# happen -- so decide on boot_id, and check it even when adb never dropped.
wait_boot
BOOTID_END=$(boot_id)
if [ -z "$BOOTID_START" ] || [ -z "$BOOTID_END" ]; then
  res="INDETERMINATE(no boot_id)"
elif [ "$BOOTID_END" != "$BOOTID_START" ]; then
  res=WEDGED
elif [ "$res" = LOST ]; then
  res="SURVIVED(adb-drop-no-reboot)"
fi

# POSITIVE CONTROL. A survival only means something if the trigger actually
# fired. The carrier is spawned by SelinuxViewModel some tens of seconds into
# the run, not at launch, so "no wedge" with no carrier spawn is an unfinished
# run, not a clean one -- report it as INCONCLUSIVE. Reporting such runs as
# SURVIVED is exactly what invalidated the first bisect.
LOG="$OUTDIR/$LABEL.events.log"
CARRIER=$(grep -ac SelinuxContextValidityCarrierService "$LOG" 2>/dev/null)
LAUNCHED=$(grep -ac "am_proc_start.*com.eltavine.duckdetector," "$LOG" 2>/dev/null)
case "$res" in
  SURVIVED*)
    [ "${LAUNCHED:-0}" -gt 0 ] || res="INCONCLUSIVE(app never started)"
    [ "${CARRIER:-0}" -gt 0 ] || res="INCONCLUSIVE(carrier never spawned)"
    ;;
esac
echo "RESULT=$res LABEL=$LABEL SECONDS=$((end-start)) carrier_spawns=$CARRIER launched=$LAUNCHED app=$EXPECT_APP gold_iso=$GOLD_ISO kernel=[$KERNEL]"

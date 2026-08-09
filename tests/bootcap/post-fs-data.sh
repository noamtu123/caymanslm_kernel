#!/system/bin/sh
# bootcap: armed bootloop watchdog — comprehensive, self-contained per-boot
# forensics. Runs as root under KSU at post-fs-data (~9s), before the
# ~9.8-12.5s zygote-injection failure window. One failed boot => everything.
# NOTE: the wall clock is NOT yet NTP-synced this early (reads ~2017), so we must
# never filter by absolute time. Order boots with a monotonic counter; pick crash
# artifacts by newest-mtime rank instead.
ROOT=/data/local/tmp/bootcap
mkdir -p "$ROOT"
SEQ=$(cat "$ROOT/.seq" 2>/dev/null || echo 0); SEQ=$((SEQ+1)); echo "$SEQ" > "$ROOT/.seq"
TS=$(date +%Y%m%d-%H%M%S)
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '-')
DIR="$ROOT/$(printf %04d "$SEQ")_${TS}_${BID}"
mkdir -p "$DIR" "$DIR/prev"
echo "$DIR" > "$ROOT/.current"

# Copy the newest N files by mtime (clock-independent). The dead boot's fresh
# crashes sort to the top; on a clean boot this just grabs the newest stale ones.
copy_newest() { # $1=srcdir $2=dstdir $3=count
  mkdir -p "$2"
  ls -1t "$1" 2>/dev/null | head -n "$3" | while read n; do
    [ -f "$1/$n" ] && cp -a "$1/$n" "$2/" 2>/dev/null
  done
}

# ---- 1. Previous boot's death evidence (survives the reboot) ----
cp -a /sys/fs/pstore/. "$DIR/prev/pstore/" 2>/dev/null   # panic/oops only here
cat /proc/last_kmsg > "$DIR/prev/last_kmsg.txt" 2>/dev/null
getprop > "$DIR/prev/getprop.txt" 2>/dev/null            # reboot reason survives
ls -lat /data/tombstones/ > "$DIR/prev/tombstones.ls" 2>/dev/null
ls -lat /data/system/dropbox/ > "$DIR/prev/dropbox.ls" 2>/dev/null
copy_newest /data/tombstones "$DIR/prev/tombstones" 12
copy_newest /data/system/dropbox "$DIR/prev/dropbox" 40
cp -a /data/adb/rezygisk/state.json "$DIR/prev/rezygisk_state.json" 2>/dev/null

# ---- 2. This boot's environment snapshot ----
cat /proc/uptime > "$DIR/uptime_at_pfsd.txt" 2>/dev/null
mount > "$DIR/mount.txt" 2>/dev/null
cat /proc/mounts > "$DIR/proc_mounts.txt" 2>/dev/null
ps -A > "$DIR/ps.txt" 2>/dev/null || ps > "$DIR/ps.txt" 2>/dev/null

# ---- 3. This boot's live logs ----
# Enlarge the running logd buffers NOW so nothing rotates out from here through
# the failure window and beyond. persist.logd.size won't stick from this SELinux
# context, but the runtime resize needs no persistence and covers what matters
# (capture starts ~9s; the failure window is ~9.8-12.5s, i.e. all ahead of here).
logcat -b all -G 8M 2>/dev/null
setprop persist.logd.size 8M 2>/dev/null   # best-effort for future boots
logcat -b all -v threadtime -f "$DIR/logcat.live" &
LPID=$!
(n=0; while [ $n -lt 400 ]; do dmesg > "$DIR/kernel.tmp" 2>/dev/null && mv -f "$DIR/kernel.tmp" "$DIR/kernel.log"; n=$((n+1)); sleep 0.5; done) &
KLOOP=$!
(n=0; while [ $n -lt 50 ]; do logcat -d -b all -v threadtime > "$DIR/logcat.snap.tmp" 2>/dev/null && mv -f "$DIR/logcat.snap.tmp" "$DIR/logcat.snap"; n=$((n+1)); sleep 4; done) &
SLOOP=$!
(sleep 200; kill "$LPID" "$KLOOP" "$SLOOP" 2>/dev/null) &
(i=0; while [ $i -lt 80 ]; do sync; sleep 0.5; i=$((i+1)); done) &

echo "post-fs-data uptime=$(cat /proc/uptime) seq=$SEQ" > "$DIR/stage_pfsd"

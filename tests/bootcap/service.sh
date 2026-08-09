#!/system/bin/sh
# Runs ~12.5s, AFTER the failure window. Marker presence => this boot survived
# the window. A boot dir with stage_pfsd but NO stage_svc is a failed loop.
ROOT=/data/local/tmp/bootcap
DIR=$(cat "$ROOT/.current" 2>/dev/null)
[ -n "$DIR" ] && echo "service uptime=$(cat /proc/uptime)" > "$DIR/stage_svc"
# Prune: keep only the newest 6 boot dirs to bound storage.
ls -1dt "$ROOT"/*_*/ 2>/dev/null | tail -n +7 | while read d; do rm -rf "$d"; done

#!/usr/bin/env bash
# Build the non-root KSU descriptor-exposure probe for the target device.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

OUT="${1:-$HERE/artifacts/ksu-fd-probe}"
SRC="$HERE/tests/ksu-fd-probe.S"

"$TOOLCHAIN_DIR/bin/clang" --target=aarch64-linux-gnu -fuse-ld=lld \
  -nostdlib -static -Wl,-e,_start -o "$OUT" "$SRC"

echo "Built: $OUT"
echo "Run without su: adb push $OUT /data/local/tmp/ksu-fd-probe && adb shell 'chmod 0755 /data/local/tmp/ksu-fd-probe; /data/local/tmp/ksu-fd-probe; echo \$?'"

#!/usr/bin/env bash
# verify-image.sh -- assert properties of a built kernel by INSPECTING IT.
#
# The rule this encodes: verify what a build actually produced by unpacking the
# artifact, never by reading the makefiles that were supposed to produce it. In
# the sibling recovery repo, reasoning from Android.mk/Android.bp produced a
# confidently wrong conclusion and shipped a broken keystore2.rc.
#
# Usage: ./scripts/verify-image.sh <Image.gz-dtb|Image> [--allow-no-edl]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.sh"

IMAGE="${1:-}"
ALLOW_NO_EDL=0
[ "${2:-}" = "--allow-no-edl" ] && ALLOW_NO_EDL=1

[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || { echo "usage: $0 <Image.gz-dtb|Image> [--allow-no-edl]" >&2; exit 1; }

# Work on the uncompressed kernel. Image.gz-dtb is a gzip stream with the DTB
# appended, so gunzip decompresses the kernel and then reports trailing
# garbage -- expected, and not an error here.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/vmlinux.raw"

case "$IMAGE" in
  *.gz|*.gz-dtb) gzip -dc "$IMAGE" > "$RAW" 2>/dev/null || true ;;
  *)             cp "$IMAGE" "$RAW" ;;
esac
[ -s "$RAW" ] || { echo "error: could not extract a kernel image from $IMAGE" >&2; exit 1; }

# Extract once to a file and grep THAT. Piping `strings` into `grep -q` or
# `grep -m1` makes grep exit on the first match, which SIGPIPEs strings; under
# `set -o pipefail` that reads as a failed pipeline and silently inverts every
# check. It cost a false "EDL marker absent" on a kernel that had it.
SYMS="$TMP/strings.txt"
strings -a "$RAW" > "$SYMS"

fail=0
note() { printf '  %-6s %s\n' "$1" "$2"; }

# --- version -----------------------------------------------------------------
VERSION="$(grep -m1 '^Linux version ' "$SYMS" || true)"
if [ -z "$VERSION" ]; then
  note FAIL "no 'Linux version' string found"
  fail=1
else
  note ok "$VERSION"
  case "$VERSION" in
    *"4.9.337-perf"*) ;;
    *) note FAIL "expected 4.9.337-perf -- the drop-in property depends on matching stock"; fail=1 ;;
  esac
  # Proves which build is running once flashed. Without it a stale image on the
  # phone is indistinguishable from a fresh one.
  case "$VERSION" in
    *"$KBUILD_HOST"*) ;;
    *) note FAIL "build host is not '$KBUILD_HOST'; flashed builds will not be identifiable"; fail=1 ;;
  esac
fi

# --- EDL ---------------------------------------------------------------------
# Same marker patch-android-edl-boot.ps1 greps for. Its absence means
# `adb reboot edl` is dead, and with it the last-resort recovery path.
if grep -qF "$EDL_MARKER" "$SYMS"; then
  note ok "EDL marker present"
elif [ "$ALLOW_NO_EDL" = "1" ]; then
  note warn "EDL marker absent (allowed explicitly -- do NOT ship this build)"
else
  note FAIL "EDL marker absent: 'adb reboot edl' would stop working"
  fail=1
fi

# --- SuSFS (informational until Phase 5) -------------------------------------
SUS="$(grep -m1 -oE 'SUSFS[ _-]?v?[0-9]+\.[0-9]+\.[0-9]+' "$SYMS" || true)"
[ -n "$SUS" ] && note ok "$SUS"
grep -qi 'KernelSU' "$SYMS" && note ok "KernelSU present"

if [ "$fail" != "0" ]; then
  echo "verify-image: FAILED" >&2
  exit 1
fi
echo "verify-image: OK"

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

# Detect compression from the bytes, not the filename. Release artifacts often
# carry descriptive suffixes after "Image.gz-dtb", and those are still gzip
# streams followed by a DTB.
GZIP_MAGIC="$(od -An -tx1 -N2 "$IMAGE" | tr -d ' \n')"
if [ "$GZIP_MAGIC" = "1f8b" ]; then
  gzip -dc "$IMAGE" > "$RAW" 2>/dev/null || true
else
  cp "$IMAGE" "$RAW"
fi
[ -s "$RAW" ] || { echo "error: could not extract a kernel image from $IMAGE" >&2; exit 1; }

# Extract once to a file and grep THAT. Piping `strings` into `grep -q` or
# `grep -m1` makes grep exit on the first match, which SIGPIPEs strings; under
# `set -o pipefail` that reads as a failed pipeline and silently inverts every
# check. It cost a false "EDL marker absent" on a kernel that had it.
SYMS="$TMP/strings.txt"
strings -a "$RAW" > "$SYMS"

CONFIG_TEXT="$SYMS"
PUBLIC_CONFIG=0
EXTRACT_IKCONFIG="$KERNEL_SRC/scripts/extract-ikconfig"
if [ -x "$EXTRACT_IKCONFIG" ]; then
  EXTRACTED_CONFIG="$TMP/config.txt"
  if "$EXTRACT_IKCONFIG" "$RAW" > "$EXTRACTED_CONFIG" &&
     [ -s "$EXTRACTED_CONFIG" ]; then
    CONFIG_TEXT="$EXTRACTED_CONFIG"
    PUBLIC_CONFIG=1
  fi
fi

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

# --- root stack --------------------------------------------------------------
# BISECT=1 builds deliberately drop parts of the root stack to isolate a bug (see
# config/bisect-*.fragment). The SuSFS assertions below are then expected to fail,
# so downgrade them to warnings -- everything else (version string, EDL marker,
# public config redaction) is still enforced, because a diagnostic image still gets
# RAM-booted or flashed on the real phone.
if [ "${BISECT:-0}" = "1" ]; then
  note WARN "BISECT=1: SuSFS assertions downgraded to warnings -- DIAGNOSTIC IMAGE, DO NOT SHIP"
fi

if grep -qF "$SUSFS_VERSION" "$SYMS"; then
  note ok "SuSFS $SUSFS_VERSION present"
elif [ "${BISECT:-0}" = "1" ]; then
  note WARN "SuSFS $SUSFS_VERSION marker absent (expected under BISECT)"
else
  note FAIL "SuSFS $SUSFS_VERSION marker absent"
  fail=1
fi

if [ "$PUBLIC_CONFIG" = "1" ]; then
  if ! grep -qx 'CONFIG_IKCONFIG_PROC=y' "$CONFIG_TEXT"; then
    note FAIL "public /proc/config.gz view is absent"
    fail=1
  fi
  if grep -qE '^(# )?CONFIG_KSU' "$CONFIG_TEXT"; then
    note FAIL "public /proc/config.gz view exposes KSU/SuSFS options"
    fail=1
  fi
  note ok "public /proc/config.gz view is present and KSU/SuSFS config is redacted"
else
  note FAIL "could not extract the public /proc/config.gz view"
  fail=1
fi
if ! grep -qx 'CONFIG_SECURITY_DMESG_RESTRICT=y' "$CONFIG_TEXT"; then
  note FAIL "public config does not show unprivileged dmesg restriction"
  fail=1
fi

if grep -qi 'KernelSU' "$SYMS"; then
  note ok "KernelSU present"
elif [ "${BISECT:-0}" = "1" ]; then
  note WARN "KernelSU marker absent (expected under BISECT)"
else
  note FAIL "KernelSU marker absent"
  fail=1
fi

# NoMount has no standalone version banner, so assert the option from the
# IKCONFIG payload embedded in the artifact. This proves nomount.o was selected
# by the final resolved configuration rather than merely present in the tree.
if grep -qx 'CONFIG_NOMOUNT=y' "$CONFIG_TEXT"; then
  note ok "NoMount present"
elif [ "${BISECT:-0}" = "1" ]; then
  note WARN "CONFIG_NOMOUNT absent (expected under BISECT)"
else
  note FAIL "CONFIG_NOMOUNT is absent from the built image"
  fail=1
fi

# Version strings alone can pass when the bridge was compiled without the
# capabilities promised by the release profile. The public IKCONFIG view is
# deliberately redacted, so verify the bridge's compiled feature strings in
# the kernel image instead.
required_susfs_config=(
  CONFIG_KSU_SUSFS_SUS_PATH
  CONFIG_KSU_SUSFS_SUS_MOUNT
  CONFIG_KSU_SUSFS_SUS_KSTAT
  CONFIG_KSU_SUSFS_SPOOF_UNAME
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
  CONFIG_KSU_SUSFS_OPEN_REDIRECT
  CONFIG_KSU_SUSFS_SUS_MAP
)
for symbol in "${required_susfs_config[@]}"; do
  if grep -qF "$symbol" "$SYMS"; then
    note ok "$symbol bridge present"
  elif [ "${BISECT:-0}" = "1" ]; then
    note WARN "$symbol bridge marker absent (expected under BISECT)"
  else
    note FAIL "$symbol bridge marker absent"
    fail=1
  fi
done

if [ "$fail" != "0" ]; then
  echo "verify-image: FAILED" >&2
  exit 1
fi
echo "verify-image: OK"

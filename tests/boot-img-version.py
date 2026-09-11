#!/usr/bin/env python3
"""Print the `uname -v` string a boot image will report.

The suite uses this to ASSERT that `fastboot boot` actually took. A RAM-boot
that silently fails leaves the previously FLASHED kernel running, and the trial
then measures the wrong kernel while looking perfectly healthy -- that happened
and produced a void result before this check existed.

The kernel section is gzip with an appended DTB, so the trailing bytes are
expected garbage; decompress what we can and read the banner out of it.
"""
import re
import sys
import zlib

data = open(sys.argv[1], "rb").read()
for m in re.finditer(b"\x1f\x8b\x08", data):
    try:
        raw = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(data[m.start():])
    except zlib.error:
        continue
    b = re.search(rb"Linux version [^\x00]{10,400}", raw)
    if b:
        # "Linux version 4.9.337-perf+ (user@host) (clang ...) #19 SMP PREEMPT <date>"
        v = re.search(rb"(#\d+ .*)$", b.group(0))
        if v:
            print(v.group(1).decode("utf-8", "replace").strip())
            sys.exit(0)
print("", end="")
sys.exit(1)

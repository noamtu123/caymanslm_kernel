# bootcap — bootloop capture companion

A throwaway KernelSU module that records a **complete, self-contained forensic
snapshot of every boot**, so a single failed boot yields everything needed to
diagnose it and nothing else has to be collected after the fact. Built to chase
the intermittent 2-bootloop seen on the first boot after flashing a new
kernel + ReZygisk (a ptrace zygote-injection race that stretches with the heavy
first-boot; see the project notes).

This is a **testing aid, not a shipping module** — do not bundle it into a
release. It captures ~20 MB/boot and runs background log followers.

## Install

Copy the three scripts into a module dir on the device (they run as root under
KSU) and reboot:

```sh
adb push tests/bootcap /data/local/tmp/bootcap-mod
adb shell 'su -c "M=/data/adb/modules/bootcap; mkdir -p \$M; \
  cp /data/local/tmp/bootcap-mod/module.prop  \$M/; \
  cp /data/local/tmp/bootcap-mod/post-fs-data.sh \$M/; \
  cp /data/local/tmp/bootcap-mod/service.sh    \$M/; \
  chmod 0755 \$M/post-fs-data.sh \$M/service.sh; rm -f \$M/disable \$M/remove"'
adb reboot
```

From Git-Bash, prefix `adb push` with `MSYS_NO_PATHCONV=1` or MSYS rewrites the
`/data/...` remote path. Avoid a literal `(` inside an inline `su -c "..."` echo
— it is a shell syntax error.

The module survives a kernel reflash (it lives in `/data`, which AnyKernel3 never
touches), so once installed it stays armed across test builds.

## What it captures

Into `/data/local/tmp/bootcap/NNNN_<ts>_<bootid>/`, one dir per boot. `NNNN` is a
monotonic counter from `.seq` — **use it for boot order, not `<ts>`**: at
post-fs-data the wall clock is not NTP-synced yet and reads ~2017, so absolute
time is meaningless (which is also why crash artifacts are picked by newest-mtime
*rank*, never by a time cutoff).

This boot:

- `logcat.live` — all logcat buffers, followed; the ring backlog reaches ~`t=0`.
- `logcat.snap` — full `logcat -d` re-dump every 4 s (backup vs follow truncation).
- `kernel.log` — the whole kernel ring, snapshotted every 0.5 s (BusyBox `dmesg`
  has no `-w`, and `logcat -b kernel -f` follows nothing here). Spans `[0.000000]`
  onward, so it holds the init reboot reason on a failed boot.
- `mount.txt`, `proc_mounts.txt`, `ps.txt`, `uptime_at_pfsd.txt`.
- `stage_pfsd` — written at post-fs-data (~9 s), before the failure window.
- `stage_svc` — written by `service.sh` (~12.5 s), *after* the window.

`prev/` — the boot that just **died**, whose evidence survives the reboot:

- `getprop.txt` — the reboot reason survives here (`ro.boot.*bootreason*`,
  `sys.boot.reason`, last_reboot_reason).
- `pstore/` — kernel panic/oops log; on this device only a true panic populates
  it, so it is empty after a clean init/watchdog reboot.
- `tombstones/` — newest 12 native-crash tombstones (by `ls -t` rank).
- `dropbox/` — newest 40 dropbox entries (system_server WTFs, etc.).
- `rezygisk_state.json`, `last_kmsg.txt`.

Bounded to ~200 s of capture per boot, pruned to the newest 6 boot dirs.

## Reading a failed boot

**A failed loop is the boot dir with `stage_pfsd` present but `stage_svc`
ABSENT.** Pull it and start with the reboot reason:

```sh
adb pull /data/local/tmp/bootcap
```

Then read `<dir>/kernel.log` (tail — the init `reboot: Restarting system …`
line) and `<dir>/prev/getprop.txt` for the reason, and `<dir>/logcat.live` for
the ReZygisk/zygote injection sequence leading up to the reset.

## Uninstall

```sh
adb shell 'su -c "rm -rf /data/adb/modules/bootcap /data/local/tmp/bootcap"'
adb reboot
```

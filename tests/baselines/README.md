# Detector baselines — what a *stock, unrooted* caymanslm already reports

Detector apps flag plenty of things that have nothing to do with this project.
Chasing those wastes build cycles, so every detector finding must be diffed
against a baseline captured on the **stock kernel with no root active** before it
is treated as something we caused.

## How a baseline is captured

RAM-boot the stock kernel (writes nothing to flash), then run the detector and
export its report:

```
adb reboot bootloader
fastboot boot <sibling-repo>/artifacts/edl-backup/boot_b-stock.img
adb shell 'uname -a'    # MUST show the stock 4.9.227-perf build, not ours
```

Note `su` is absent under the stock kernel, so this is a genuine unrooted view.
`/data` is untouched, so anything *installed* (manager APK, module files) is still
present and will still be seen — that is a property of the baseline, not a bug.

## Duck Detector — captured twice, on two different stock kernels

Duck Detector (`com.eltavine.duckdetector`) 2026.08.08-3c137eccab46 (498),
Enforcing, no `su` in both runs:

- `duck-detector-stock-lineage-2026-08-10.txt` — `4.9.227-perf #1 Mon Jun 27
  22:05:23 IST 2022`, the Lineage-sourced stock image from the recovery repo
  (`boot_b-stock.img`).
- `duck-detector-stock-lg-edl-2026-08-10.txt` — `4.9.227-perf #1 Thu Sep 8
  22:37:48 IST 2022`, the **true LG stock kernel** dumped over EDL.

The two agree completely: same 8 cards, same verdicts, same counts. The only
differences are run-to-run noise (timing jitter, Java object hashes, 271 vs 272
services listed, preload Fresh/Stale). Treat the table below as confirmed.

**Caveat that matters:** both runs were taken with our modules already installed
under `/data` (they were flashed from our kernel earlier, and `/data` is untouched
by a kernel swap). That is why the manager APK still shows up with no root running
— it is an *installed-file* signal, not a running-root signal.

Overall on a stock unrooted phone: **Danger 4 · Warning 4 · Ready 15.**

| Card | Stock verdict | What actually drives it |
| --- | --- | --- |
| Bootloader | **DANGER** | `ro.boot.flash.locked=0`, `verifiedbootstate=orange`, `vbmeta.device_state=unlocked`, key attestation unavailable. Real, and **unfixable** — the bootloader is unlocked. |
| Mount | **DANGER** | One signal only: `/product` resolves to **overlayfs**, which is how LG ships it. Every other mount probe (mounts, mountinfo, maps, magisk paths, shell-tmp) is Clean. |
| System Properties | **DANGER** | 3 critical / 5 review, incl. `persist.sys.usb.config=mtp,adb` (expects `mtp`). Stock LG property set + adb enabled. |
| TEE | **DANGER** | Attestation chain fails (len 0, trust root Unknown, CRL offline) — a downstream consequence of the unlocked bootloader. |
| Custom ROM | **WARNING** | Exactly one signal: `ro.boot.flash.locked=0`. Build fields, packages, services, resource maps all Clean. |
| Dangerous Apps | **WARNING** | The **installed manager APK** `com.rifsxd.ksunext` (and LSPosed Manager as a target). Package-visibility only. |
| Native Root | **WARNING** | Verdict is *"KernelSU manager package detected"* — again just the installed APK. **Kernel: Clean.** All real probes Clean/Normal: supercall blocked by seccomp, prctl 0xDEADBEEF, devpts labels, susfs side-channel, isolated-mount drift. Also flags `/data/local/tmp` inode 103934 > 10000 (deletion/recreation history). |
| SELinux | **WARNING** | *"Enforcing with dirty sepolicy rule"* driven by ONE allowed edge: `fsck_untrusted -> fsck_untrusted:capability sys_admin` — an **LG stock policy** quirk. Every root-related edge is correctly Denied on stock (magisk binder, `ksu_file` read, `lsposed_file` read, shell→su transition, adbd→adbroot). |

### Consequences for this project

- **Do not chase** Bootloader, TEE, Custom ROM, Mount(`/product` overlayfs),
  System Properties, or the `fsck_untrusted sys_admin` "dirty sepolicy" line.
  They are all present with **zero** root running.
- The only findings that are ours to act on are the ones that **appear on our
  kernel but not here**, plus the two package-visibility hits, which are fixed in
  userspace by **repackaging/hiding the manager** (`com.rifsxd.ksunext`) and
  LSPosed Manager — not by any kernel change.
- `Native Root → Kernel: Clean` on stock is the row to watch: if that ever says
  anything else on our kernel, it is a real kernel-side leak.

### Also established during this session

Duck Detector **hard-crashes our kernel but not stock** (stock survives the same
scan), so the crash is ours, not an LG/Qualcomm defect. See the session notes on
the SELinux enforcing-only panic; `setenforce 0` avoids it.

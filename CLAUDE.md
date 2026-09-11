# caymanslm_kernel — custom kernel for the LG Velvet 4G

Custom Android kernel for the **LG Velvet 4G, LM-G910EMW** (`caymanslm`,
Snapdragon 845), from LineageOS source, carrying **KernelSU Next** + **SuSFS**.
Later: voltage / clock / thermal tuning.

Target ROMs, priority order:

1. **LineageOS 22.2** — main target (not installed yet).
2. **Stock Android 12**, firmware `G91030a` (`SKQ1.211103.001`) — on the device now.

## Device

`LM-G910EMW` **only** — not the 5G Velvet (`caymanlm` / SDM765G, a different SoC
and device). Any script touching the phone must refuse unless
`ro.product.device` / `fastboot getvar product` is `caymanslm`, like the sibling
repo's EDL script.

- A/B device. Bootloader unlocked. Active slot `_a`.
- Stock Android 12 (`G91030a`), **unrooted** — no Magisk, no `su`.
- OrangeFox recovery working, including FBE `/data` decryption.

## The key fact — a Lineage-sourced kernel already boots stock A12

Verified over adb: `Linux version 4.9.337-perf+ (noamtu123@DESKTOP-0N0FHOO)`,
clang r487747c. That is this project's OrangeFox recovery kernel placed into
`boot_a` by
[`edl-boot-script/patch-android-edl-boot.ps1`](../orangefox_caymanslm/edl-boot-script/patch-android-edl-boot.ps1),
which swaps kernel+DTB into the Android boot image and leaves header+ramdisk alone.

Two properties make it work — **preserve both:**

- **Drop-in** — same `4.9.337` as stock, so no vendor-blob ABI break.
- `dtbo_a` is **untouched**, so LG's device-tree overlays still apply.

"Will a Lineage kernel boot LG stock" is **answered — don't re-litigate.** But
booting ≠ every subsystem healthy; post-flash subsystem verification is still required.

## Kernel source

- LineageOS `android_kernel_lge_sdm845`, branch `lineage-22.2`
- Pinned at `efa8458f79dffeb380d43b38b9403407f87d9f05`
- Version **4.9.337** — non-GKI, older than 4.14
- Defconfig `arch/arm64/configs/lineageos_caymanslm_defconfig`:
  - `CONFIG_LOCALVERSION="-perf"` — why it reports `-perf`; trailing `+` is a
    dirty git tree, not a different config.
  - `CONFIG_OVERLAY_FS=y`, `CONFIG_KALLSYMS_ALL=y` already set. **No `CONFIG_KPROBES`.**
- Image `Image.gz-dtb` (appended DTB). `BOARD_KERNEL_SEPARATED_DTBO := true`.

## Root stack — current implementation

The 5.10→4.9 SuSFS backport is **implemented, reproducibly packaged, and boots**
(verified on-device 2026-07-30; modules activate at boot as of the newfstat hook,
2026-07-31). It supersedes the earlier "use ShirkNeko 4.9 v1.5.9" plan.

- **SuSFS `v2.2.0`**, backported from ShirkNeko `gki-android12-5.10` at
  `c5723cc09c79b57a25f24212b8bfe6e255ea3eef`. Full v2.2.0 feature parity.
- **KernelSU Next `v3.2.0-legacy`** at pin `53791c92`, with a native bridge for
  the v2.2 command API. Official KSUN manager (`com.rifsxd.ksunext`) accepted.
- Enabled: `SUS_PATH`, `SUS_MOUNT`, `SUS_KSTAT`, `SUS_MAP`, open redirect,
  cmdline spoof, uname spoof, AVC-log spoofing, kallsyms filtering.
- Kernel logging compiled out. `/proc/config.gz` is kept **enabled but redacted**
  — Android VINTF requires the endpoint, so `caymanslm-sanitized-ikconfig.patch`
  serves a filtered view instead of disabling it: the raw build `.config` would
  disclose `CONFIG_KSU*` / `CONFIG_KSU_SUSFS*` (and `CONFIG_NOMOUNT` /
  `CONFIG_CAYMANSLM_*`) to unprivileged detectors, so those namespaces are
  stripped at build time. Unprivileged `dmesg` restricted; root can still collect
  logs.
- The backport adapts the 5.10 namei, mount-ID/IDA, stat/getattr, fsnotify,
  procfs, compat-getdents, remote-memory, and SELinux AVC interfaces to 4.9.
- Reproducibility gate = clean patch replay + build. On-device detector testing
  is a separate gate; no root stack guarantees zero detection.

### Fork choice — settled 2026-07-28, don't re-open

**KernelSU Next `legacy` is correct** for this device (non-GKI 4.9, no KPROBES).
It is the only live fork with a `KSU_MANUAL_HOOK` Kconfig *and* a build-time gate
that fails if hooks are missing. SukiSU-Ultra has no manual-hook Kconfig (its
non-GKI path fights the no-forks rule); rsuntk has fewer features, no hook gate,
and deprecated its SuSFS branches; upstream `tiann/KernelSU` ended non-GKI support.
**No fork ships SuSFS for non-GKI** — the SuSFS integration is hand-merged here
regardless of fork, so switching forks buys nothing.

### KernelSU integration (`scripts/setup-tree.sh` + `patches/kernel/`)

- **Do not use KernelSU's `kernel/setup.sh`** — it `git pull`s and silently
  falls back to the default branch when its ref doesn't resolve, quietly building
  a different KernelSU. Its three real actions (symlink `<ksu>/kernel` →
  `drivers/kernelsu`; append `obj-$(CONFIG_KSU) += kernelsu/` to
  `drivers/Makefile`; insert `source "drivers/kernelsu/Kconfig"` before `endmenu`
  in `drivers/Kconfig`) are reproduced in `setup-tree.sh` against a pinned SHA
  and asserted.
- `legacy`'s Kconfig offers `KSU_MANUAL_HOOK` (defaults on when KPROBES absent)
  and `KSU_KPROBES_HOOK` (needs ≥5.10). Upstream docs write
  `CONFIG_KSU_KPROBE_HOOKS`, which matches nothing — **trust the Kconfig.**
- **Seven** hook sites (not five — `drivers/input/input.c` is needed for
  volume-down safe mode): `ksu_handle_execveat` (`fs/exec.c` `do_execveat_common`),
  `ksu_handle_faccessat` (`fs/open.c`), `ksu_handle_stat` (`fs/stat.c`
  `newfstatat`), `ksu_handle_vfs_read` (`fs/read_write.c`),
  `ksu_handle_sys_reboot` (`kernel/reboot.c`),
  `ksu_handle_input_handle_event` (`drivers/input/input.c`), and
  `is_ksu_transition` (`security/selinux/hooks.c` `check_nnp_nosuid`).
- **The SELinux hook is the one that is easy to miss, and missing it is fatal
  at boot** (found 2026-08-02, `caymanslm-ksu-nnp-nosuid-hook.patch`). `/data`
  is mounted `nosuid`, so init's injected
  `exec u:r:ksu:s0 root -- /data/adb/ksud …` goes through `check_nnp_nosuid()`,
  which demands a *bounded* transition. `ksu` is created at runtime by
  `add_type()`, whose `kzalloc`'d `type_datum` leaves `->bounds == 0`, so
  `security_bounded_transition()` can never succeed and every ksud exec fails
  with `-EACCES`. KernelSU ships `is_ksu_transition()` for exactly this (it is
  `#if LINUX_VERSION_CODE <= KERNEL_VERSION(4, 19, 0)`, i.e. written for old
  non-GKI trees) but declares it nowhere and calls it nowhere — the integrator
  must wire it in. Unlike the other six, **the Kbuild hook gate does not catch
  this one**: the build succeeds and root works, but no module ever mounts.
  Symptom to recognise: `type=1401 … op=security_bounded_transition
  seresult=denied oldcontext=u:r:init:s0 newcontext=u:r:ksu:s0`.
- The reboot hook must sit **before** the `CAP_SYS_BOOT` check — KSU uses its
  own `magic1` and replies via `*arg` to a non-root manager.
- `input.c` must **split** the `disposition` declaration rather than put a call
  in front of it — builds with `-Wdeclaration-after-statement`.
- KernelSU's Kbuild gates on the hooks (`$(error … No hooks were defined)`), so
  a botched hook patch fails the build instead of silently going rootless.

**`path_umount` — the trap.** Pre-5.10 needs it, and KernelSU's Kbuild injects it
(plus `can_umount`, an `fs/internal.h` decl, a seccomp `filter_count` field) —
but via `sed` while descending into `drivers/`, after `fs/namespace.o` is already
compiled from unpatched source. A clean build then dies at link with
`undefined symbol: path_umount` and only succeeds on a *second* run. Carried as
`patches/kernel/caymanslm-ksu-path-umount.patch` so it lands first; KernelSU's
guards detect it and skip re-injecting.

**Manager APK:** the build hardcodes an expected signature (hash
`79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7`, size `0x3e6`).
Only the official KernelSU Next manager is granted root; a mismatched APK installs
fine but is never granted, presenting as "KSU is broken".

**Manager discovery on legacy FBE.** The manager APK lives in credential-encrypted
storage that stays locked until `/data` unlocks (~30–55 s post cold-boot), so the
signature check that crowns the manager physically cannot run before then — no
kernel change removes that window. What the kernel does own is the *stuck* state
after unlock: discovery is async, so the manager can be crowned a beat after it
already launched, and nothing installed its driver fd into the running process —
the old "open fast → not integrated until you swipe-from-recents and reopen." Three
patches harden discovery across that window without any synchronous I/O in the
setuid hot path (the rejected
`synchronous-setuid-discovery` approach — a `/data/app` walk on every uncrowned
app spawn — is **not** used): `zzzzzzzz-ksu-manager-repair-running-fd` pushes the fd
into the already-running manager via `task_work_add` right after `crown_manager()`
verifies the signature; `zzzzzzz3-...-retry-backoff-fbe-window` widens the throne
worker's retry from ~1 s to a bounded ~60 s so it spans CE-unlock;
`zz2-...-boot-completed-search-if-uncrowned` makes `on_boot_completed` do a full
search when uncrowned instead of a discovery-cancelling prune.
**These do not by themselves remove the fast-open reopen.** Per on-device logs
([[manager-crowning-race]]) the official manager runs its integration check once at
startup and **never re-probes a failed instance**, so a manager opened *before*
CE-unlock caches "not integrated" and the late fd we install is not read until the
app re-checks. Removing the reopen for that first instance needs the manager to
re-probe (userspace) or a **persisted optimistic crown** from a DE-early
`/data/adb` hint (Option B in [[manager-crowning-race]]; a real feature with a
sub-second trust window, gated so GRANT_ROOT waits on APK re-verify) — not
implemented. `"Zygisk required"` on modules waits on ReZygisk's daemons, not the
kernel.

**SuSFS is kernel-side only here.** This repo produces a SuSFS-capable kernel; the
`ksu_susfs` tool and `ksu_module_susfs` hiding module install separately from
upstream. Consequence: **the kernel alone hides nothing** — SuSFS does almost
nothing until that userspace module drives it, so "SuSFS works" is only verifiable
with the module installed. Hiding applies to KSU-umounted apps, not `adb shell`.

## NoMount — the userspace module version must match

The kernel half is **NoMount v2.0.0** (`patches/kernel/caymanslm-zz-nomount-4.9-integration.patch`),
a keyring `key_type "nomount"` driven by `add_key(2)`, ABI `NOMOUNT_VERSION "20"`,
magic `0x4E4F4D4F554E54` ("NOMOUNT"). **The Generic Netlink family of v1.1.x is
gone** — v2.0.0 rewrote the channel. The kernel side is the self-contained
`fs/nomount/` subdir and intercepts by hijacking `i_op`/`i_fop`/`s_op` vectors
when `nm` adds a rule, so it patches **no** core VFS files (v1.1.0 patched six).
The upstream source lands verbatim on this 4.9 tree — the author's compat macros
already cover `<5.2`, and this LineageOS tree carries the `rb_root_cached`
backport (see the patch header for the full 4.9 portability notes).

**Install the v2.0.0 metamodule — a v1.1.x Netlink `nm` cannot talk to this
kernel at all** (no genl family), and a v2.0.0 `nm` cannot talk to a v1.1.x
kernel. As always, `metamount.sh`'s only gate is `if ! nm v`, so a version/ABI
mismatch surfaces as *"[FATAL] NoMount Netlink interface missing/unresponsive"* /
*"Kernel not patched"* — a userspace-mismatch lie, not a kernel fault.

Diagnose kernel-side NoMount by what the kernel says, never by the module or by
`/proc/config.gz`:

```
adb shell su -c 'dmesg | grep -i nomount'      # want: NoMount: Loaded successfully
adb shell su -c 'grep -c nomount /proc/kallsyms'
```

`/proc/config.gz` will NOT show `CONFIG_NOMOUNT` even when it is enabled --
`caymanslm-sanitized-ikconfig.patch` deliberately strips `CONFIG_NOMOUNT`,
`CONFIG_KSU*`, `SUSFS` and `CONFIG_CAYMANSLM*` from that endpoint. Grepping
config.gz to check for these is always a false negative.

## Status

- **Phases 0–5 built and booting on-device.**
  - Standalone build reproduces the OrangeFox reference `.config` byte for byte.
  - AnyKernel3 + `fastboot boot` trial pipeline works; `boot_b-stock.img` is the
    ramdisk/header donor, stock header preserved verbatim.
  - KSU version **33192** (matching manager release v3.3.0 / 33214); manager
    reports a compatible kernel and runs.
  - Subsystems verified on the KSU kernel: FBE `/data`, Wi-Fi, audio (121
    `/dev/snd` nodes), 29 sensors, modem, 8 CPUs, battery. No Oops/BUG.
  - SuSFS backport boots; modules activate at boot (newfstat init.rc hook).
- `su` isn't available to `adb shell` until shell is granted in the manager —
  KSU allowlists nothing by default. A denial there is not a fault.

## Decisions (2026-07-27)

- **First flashable build targets stock A12** — the firmware on the phone, where
  kernel-swap, OrangeFox and EDL are all proven. LineageOS 22.2 stays the eventual
  priority target.
- **Delivery is an AnyKernel3 zip flashed from OrangeFox.** OrangeFox backs up
  `boot` first; AnyKernel3 replaces the kernel while preserving the existing
  ramdisk (the drop-in property). `dtbo` is never touched. Being ramdisk-agnostic
  is what lets one zip serve both stock A12 and LineageOS later.

## Build environment

Builds in **WSL** (Windows host, Linux tree). **No CI.**

- AOSP/OrangeFox tree `~/fox`; kernel at `~/fox/kernel/lge/sdm845` (~987 MB).
- Reference `.config`:
  `~/fox/out/target/product/caymanslm/obj/KERNEL_OBJ/.config`.
- Toolchain `~/fox/prebuilts/clang/host/linux-x86/clang-r487747c`.

### How the kernel is actually built (verified 2026-07-27)

- **Not `AndroidKernel.mk`'s `REAL_CC` scheme** (that file is dead code on this
  path). Built by TWRP's `vendor/twrp/build/tasks/kernel.mk` +
  `vendor/twrp/config/BoardConfigKernel.mk`, which pass
  **`LLVM=1 LLVM_IAS=1 LD=ld.lld AR=llvm-ar HOSTCC=clang`**.
- **No GCC cross-toolchain exists, and none is needed.**
  `~/fox/prebuilts/gcc/linux-x86/` has only `host/`; the `aarch64-…-4.9` /
  `arm-…-4.9` paths `BoardConfigKernel.mk` references are absent. `LLVM=1`
  supplies the assembler and binutils, so no GCC binary is invoked.
- **`CROSS_COMPILE` is still required.** On 4.9 it gives clang its target triple
  (`Makefile:531`, `CLANG_TRIPLE ?= $(CROSS_COMPILE)`). Unset → clang compiles
  arm64 for the x86_64 host and fails in `asm-offsets.c` (`register 'sp'
  unsuitable…`, `value '65536' out of range…`). Pass
  `CROSS_COMPILE=aarch64-linux-gnu-` (+ matching `CLANG_TRIPLE`); the
  `GCC_TOOLCHAIN_DIR` lookup at `Makefile:536` resolves empty. Avoid a
  `*-linux-android-` prefix — `Makefile:534` hard-errors on an Android triple.
- **`CROSS_COMPILE_ARM32` must be a non-empty string.** `CONFIG_COMPAT_VDSO=y`
  and `arch/arm64/Makefile` hard-errors on empty (only non-emptiness is checked).
  Under clang the compat vDSO is built by `clang --target=arm-linux-gnueabi`; the
  prefix is used only to locate a GCC toolchain (`which $(CROSS_COMPILE_ARM32)ld`),
  which fails here and leaves `--gcc-toolchain`/`--prefix` empty — exactly what
  the known-good OrangeFox build does. `build.sh` passes `arm-linux-gnueabi-`.
- **Set `KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST`** so `uname -a` identifies our
  builds (the AOSP tree's `compile.h` says `#2 nobody@android-build`; the phone
  reports `#7 noamtu123@DESKTOP-0N0FHOO`).

Standalone recipe (`scripts/build.sh`): clang on `PATH`, `ARCH=arm64 LLVM=1
LLVM_IAS=1 HOSTCC=clang HOSTCXX=clang++ LD=ld.lld AR=llvm-ar`, `O=` out of tree.
Correctness gate: generated `.config` **identical** to the reference above.
`mka recoveryimage` is far too slow to develop against.

## Sibling repo — a hard dependency

`E:\orangefox_caymanslm` (`noamtu123/orangefox_caymanslm`) — OrangeFox recovery.
This project depends on three things in it:

- the same pinned kernel source (`manifests/caymanslm.xml`)
- `kernel-patches/caymanslm-edl-warm-reset.patch` — the EDL kernel patch
- `edl-boot-script/patch-android-edl-boot.ps1` — the boot-image kernel swap

Read that repo for device specifics; `device/lge/caymanslm/BoardConfig.mk` has the
validated board values and `OVERLAY.md` explains every upstream change.

## Flashing

**This phone is a spare test device.** Data loss, factory resets and ROM
reinstalls are cheap — don't hedge or warn about them.

**A bad kernel cannot strand it** — `recovery_a`/`recovery_b` are separate from
`boot_a`/`boot_b`, so OrangeFox always comes up and `boot` can be rewritten.

Genuinely irreversible — unchanged:

- **LG's firmware servers are gone** — no KDZ to restore from.
- The fuse-anchored bootloader chain `xbl`/`abl`/`tz` bricks past any recovery.
  **Never touch it.**
- **Never touch** userdata / metadata / persist / PINs / FBE keys / IMEI.
- **Keep the EDL kernel patch in every build**, or `adb reboot edl` (last-resort
  path) stops working. `scripts/verify-image.sh` asserts it.

### Procedure

- **`fastboot boot <img>` works** — RAM-boot every kernel from a throwaway
  `boot.img` (our `Image.gz-dtb` + stock ramdisk) *before* writing flash.
- LG's bootloader **rejects `fastboot flash recovery`** even unlocked. `boot`
  flashes fine.
- **The agent pushes; the operator flashes.** `adb push` the artifact, operator
  installs from OrangeFox. No `dd` to block devices; don't rely on `adb reboot`.
- **Never trust that a flash took** — it has silently left an *old* image running,
  wasting test cycles. Verify from the version string (`uname -a` →
  `caymanslm-kernel` + expected build number) before believing any result.
- **Verify by unpacking the artifact, not by reading makefiles** — reading
  `Android.mk`/`Android.bp` once shipped a broken `keystore2.rc`.
- A/B: **flash one slot at a time**, keep the other bootable. Eventual layout:
  slot A stock A12, slot B LineageOS.

### Don't touch fscrypt or crypto config

**Legacy-fscrypt only** — fscrypt v1 policy with Qualcomm PFK/ICE; the v2
`FS_IOC_ADD_ENCRYPTION_KEY` ioctl returns `ENOTTY`. OrangeFox's FBE `/data`
decryption depends on this. Changing crypto config breaks decryption in both
recovery and ROM.

## Conventions — from the recovery repo, keep them

- **No forks.** Every change to upstream (kernel, KernelSU Next, SuSFS) lives in
  this repo as a patch/overlay, re-applied by a script after a fresh clone/sync.
- **LF only, always.** A Windows checkout feeds a Linux build; editors write CRLF
  and shell doesn't strip a trailing CR (this silently broke `= "1"` flag tests
  and put a literal CR in a filename in the sibling repo). After every edit run
  `sed -i 's/\r$//' <file>`, confirm `git ls-files --eol | grep w/crlf` is empty
  before committing, and pin LF in `.gitattributes`.
- **Commits** authored **and** committed as
  `noamtu123 <noamtu123@users.noreply.github.com>`, with **no** `Co-Authored-By`
  trailer.
- **Atomic commits.** One logical change per commit; never bundle unrelated work.
  A past 32k-line mega-commit (`fcfb8f3`) folded four kernel patches, script
  rewrites and test dumps together and made that history impossible to review or
  bisect — don't repeat it.
- **Branches.** `main` is the stable release line: every patch in its
  `setup-tree.sh` allowlist is believed to boot. `develop` carries experimental /
  work-in-progress patches (currently the SELinux-hardening set — the
  status-page-seqno and hide-injected-types patches — whose boot safety is still
  under investigation). Promote develop → main only after on-device confirmation.
  Before any history rewrite, tag a backup (`backup/pre-cleanup-<date>`).

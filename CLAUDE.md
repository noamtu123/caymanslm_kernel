# caymanslm_kernel — custom kernel for the LG Velvet 4G

## Current implementation update (2026-07-28)

The later v1.5.9 recommendation in this file is superseded. The requested
Linux 5.10 → 4.9 backport is implemented and reproducibly packaged:

- SuSFS `v2.2.0`, ShirkNeko `gki-android12-5.10` at
  `c5723cc09c79b57a25f24212b8bfe6e255ea3eef`.
- KernelSU Next `v3.2.0-legacy` at the existing pin `53791c92`, with a native
  bridge for the v2.2 command API. The official KSUN manager remains accepted.
- Enabled: `SUS_PATH`, `SUS_MOUNT`, `SUS_KSTAT`, `SUS_MAP`, open redirect,
  cmdline spoof, uname spoof, AVC-log spoofing, and kallsyms filtering.
- Kernel logging is deliberately compiled out.
- `/proc/config.gz` is disabled because it would directly disclose all
  `CONFIG_KSU*` and `CONFIG_KSU_SUSFS*` options to unprivileged detectors.
- Unprivileged `dmesg` access is restricted; root remains able to collect logs
  for bring-up and debugging.
- The backport adapts the 5.10 namei, mount-ID/IDA, stat/getattr, fsnotify,
  procfs, compat-getdents, remote-memory, and SELinux AVC interfaces to 4.9.
- A clean patch replay and build are the reproducibility gate. On-device
  behavior and detector testing remain separate gates; no root stack can
  honestly guarantee zero detection.

Custom Android kernel for the **LG Velvet 4G, LM-G910EMW** (`caymanslm`,
Snapdragon 845), built from LineageOS kernel source, carrying **KernelSU Next**
and **SuSFS**. Later: voltage / clock / thermal tuning and other additions.

Target ROMs, in priority order:

1. **LineageOS 22.2** — the main target.
2. **Stock Android 12**, firmware `G91030a` (`SKQ1.211103.001`) — what the
   device runs today.

## Device

`LM-G910EMW` **only**. Not the 5G Velvet (`caymanlm` / SDM765G) — different SoC,
different device. Any script that touches the phone must refuse to run on
anything whose `ro.product.device` / `fastboot getvar product` is not
`caymanslm`, the way the sibling repo's EDL script does.

- A/B device. Bootloader unlocked. Active slot `_a`.
- Currently stock Android 12 (`G91030a`), **unrooted** — no Magisk, no `su`.
- OrangeFox recovery installed and working, including FBE `/data` decryption.

## The key fact — a Lineage-sourced kernel already boots stock A12

Not a hypothesis. Verified over adb on the device:

```
Linux version 4.9.337-perf+ (noamtu123@DESKTOP-0N0FHOO)
clang version 17.0.2 (based on r487747c)  #7 SMP PREEMPT Thu Jul 23 2026
```

That is this project's own OrangeFox recovery kernel, placed into `boot_a` by
[`edl-boot-script/patch-android-edl-boot.ps1`](../orangefox_caymanslm/edl-boot-script/patch-android-edl-boot.ps1),
which swaps the kernel and DTB into the Android boot image and leaves the header
and ramdisk alone.

Two properties make it work. **Preserve both:**

- It is a **drop-in** — same `4.9.337` as stock, so no vendor-blob ABI break.
- `dtbo_a` is **untouched**, so LG's device-tree overlays still apply.

"Will a Lineage-sourced kernel boot LG stock" is **answered — do not
re-litigate it.** But booting is not the same as every subsystem being healthy;
post-flash subsystem verification is still required.

## Kernel source

- Repo: LineageOS `android_kernel_lge_sdm845`, branch `lineage-22.2`
- Pinned at `efa8458f79dffeb380d43b38b9403407f87d9f05`
- Version **4.9.337** — non-GKI, older than 4.14
- Defconfig: `arch/arm64/configs/lineageos_caymanslm_defconfig`
  - `CONFIG_LOCALVERSION="-perf"` — why the running kernel reports `-perf`. The
    trailing `+` is a dirty git tree, not a different config.
  - `CONFIG_OVERLAY_FS=y` and `CONFIG_KALLSYMS_ALL=y` already set
  - **No `CONFIG_KPROBES`**
- Image: `Image.gz-dtb` (appended DTB). `BOARD_KERNEL_SEPARATED_DTBO := true`.

## Root-stack constraints

### KernelSU Next

Non-GKI, pre-4.14, no `CONFIG_KPROBES` ⇒ kprobe-based hooking is **not
available**; **manual hooks are required**. KSU Next supports 4.4–6.6, so this
is a documented path.

As integrated, 2026-07-27 (`scripts/setup-tree.sh` + `patches/kernel/`):

- **Do not use KernelSU's `kernel/setup.sh`.** It `git pull`s, and it **falls
  back to the default branch silently** when its ref argument does not resolve —
  either one quietly builds a different KernelSU than the pinned one. The three
  things it actually does (symlink `<ksu>/kernel` → `drivers/kernelsu`, append
  `obj-$(CONFIG_KSU) += kernelsu/` to `drivers/Makefile`, insert
  `source "drivers/kernelsu/Kconfig"` before `endmenu` in `drivers/Kconfig`) are
  reproduced in `setup-tree.sh` against a pinned SHA, and asserted.
- `legacy`'s `kernel/Kconfig` offers `KSU_MANUAL_HOOK` (defaults on when KPROBES
  is absent) and `KSU_KPROBES_HOOK` (needs ≥5.10). The upstream docs page writes
  `CONFIG_KSU_KPROBE_HOOKS`, which matches nothing — **trust the Kconfig.**
- **Six** hook sites, not five — `drivers/input/input.c` is needed too, for
  volume-down safe mode. Exact symbols: `ksu_handle_execveat` (`fs/exec.c`
  `do_execveat_common`), `ksu_handle_faccessat` (`fs/open.c`),
  `ksu_handle_stat` (`fs/stat.c` `newfstatat`), `ksu_handle_vfs_read`
  (`fs/read_write.c`), `ksu_handle_sys_reboot` (`kernel/reboot.c`),
  `ksu_handle_input_handle_event` (`drivers/input/input.c`).
- The reboot hook must sit **before** the `CAP_SYS_BOOT` check: KSU uses its own
  `magic1` and replies through `*arg` to a manager that is not root.
- `input.c` must **split** the `disposition` declaration rather than take a call
  in front of it — this kernel builds with `-Wdeclaration-after-statement`.
- KernelSU's Kbuild independently gates on the hooks
  (`$(error ... No hooks were defined)` if `kernel/reboot.c` lacks
  `ksu_handle_sys_reboot`), so a botched hook patch fails the build rather than
  silently producing a rootless kernel.

**`path_umount` — the trap.** Pre-5.10 kernels need it, and KernelSU's Kbuild
*does* inject it (plus `can_umount`, an `fs/internal.h` declaration and a
seccomp `filter_count` field). But it injects with `sed` while make is
descending into `drivers/`, by which point `fs/namespace.o` is already compiled
from unpatched source — so a clean build dies at link with
`undefined symbol: path_umount` and only succeeds on a *second* run. Carried
here as `patches/kernel/caymanslm-ksu-path-umount.patch` so it lands first;
KernelSU's guards then detect it and skip re-injecting.

**Manager APK:** the build hardcodes an expected signature (hash
`79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7`, size
`0x3e6`). Only the official KernelSU Next manager is accepted; a mismatched APK
installs fine but is never granted root, which presents as "KSU is broken".

### SuSFS

Upstream: <https://gitlab.com/simonpunk/susfs4ksu>.

Verified 2026-07-27 — **this is where the project is most likely to stall:**

- Branch `kernel-4.9` exists, `SUSFS_VERSION "v1.5.5"` (above the v1.5.2 floor
  for effective hiding). Last commit **2025-02-23** — frozen.
- Every `gki-*` branch is actively maintained (commits dated 2026-07-27) and
  has moved to a v2.0.0-era codebase. The 4.9/4.14/4.19/5.4 branches did not
  follow.
- `kernel-4.9` ships `kernel_patches/50_add_susfs_in_kernel-4.9.patch`,
  `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`, the `fs/susfs.c` +
  `fs/sus_su.c` sources and headers, the `ksu_susfs` userspace tool, and
  `ksu_module_susfs` (the flashable hiding module).
- `10_enable_susfs_for_ksu.patch` touches **18 KernelSU files** and was written
  against a 2025-era upstream KernelSU — not KSU Next, and not KSU Next
  `legacy`. **Expect to hand-merge it.** Upstream KSU Next has no SUSFS support
  of its own.
### Which kernel-root solution — settled 2026-07-28, don't re-open

All three live forks were measured against this device's constraints (non-GKI
4.9, **no `CONFIG_KPROBES`**). **KernelSU Next `legacy` is the right choice**;
the original assumption held.

| | KSU Next `legacy` | rsuntk `main` | SukiSU-Ultra `main` |
|---|---|---|---|
| `KSU_MANUAL_HOOK` config | **yes** | yes | **no** |
| Build fails if hooks missing | **yes** | no | no |
| Hiding sources | `selinux_hide`, `kernel_umount` | `kernel_umount` | `selinux_hide`, `kernel_umount`, `uts_spoof` |
| KPM (inline hooks) | no | no | yes |
| Last commit | 2026-07-20 | 2026-05-29 | 2026-07-25 |

- **SukiSU-Ultra has no manual-hook Kconfig.** Its documented non-GKI path is to
  rewrite `#ifdef CONFIG_KPROBES` → `#if defined(CONFIG_KPROBES) && 0` inside
  its own sources — which fights the no-forks convention and is fragile. On a
  kernel with no KPROBES at all that is a real cost. It is otherwise the most
  featureful (KPM, `uts_spoof`); revisit only if those become necessary.
- **rsuntk** is the non-GKI specialist and does have `KSU_MANUAL_HOOK`, but
  fewer features, no build-time hook gate, older HEAD, and it **deprecated its
  own SuSFS branches** (`deprecated/susfs-*`).
- Upstream `tiann/KernelSU` has **ended non-GKI support** — not a candidate.
- **No fork ships SuSFS for non-GKI.** Every fork's `kernel/Kconfig` has zero
  `SUSFS` entries. Switching forks buys nothing on that front.

### SuSFS integration — measured 2026-07-27/28. Read before attempting Phase 5.

**Decision: latest on both sides** — KSU Next `legacy` branch head, susfs4ksu
`gki-android12-5.10` (v2.2.0). The frozen `kernel-4.9` branch is abandoned as a
dead end. Measurements behind that:

**The 4.9 branch is unusable with any current KSU Next.** v1.5.5's
`10_enable_susfs_for_ksu.patch` was written against 2025-era *upstream*
KernelSU. `git apply --reject` scores 42 problems against every legacy tag
(`v3.0.1`, `v3.1.0`, `v3.2.0`), and `v3.2.0-legacy` no longer even has
`kernel/sucompat.c` or `kernel/throne_tracker.{c,h}` — KSU Next restructured
into `kernel/core`, `kernel/feature`, `kernel/hook`, `kernel/policy`,
`kernel/supercall`.

**`v3.1.0-legacy-susfs` is not the shortcut it looks like.** It does ship a full
`KSU_SUSFS_*` menu beside `KSU_MANUAL_HOOK`, but it expects a v2.x kernel side:
of the 33 `susfs_*` symbols it calls, **22 are absent from v1.5.5**, including
`susfs_show_version`, `susfs_get_enabled_features` and the whole SID/domain
family. It also is not the latest release. Its `kernel/Kbuild` reads
`SUSFS_VERSION` from `$(srctree)/include/linux/susfs.h`, so it adapts its
*reporting* to any kernel side but not its *API expectations*.

**Why latest-on-both is nonetheless the right base.** The maintained branch is
alive (v2.2.0, commits dated 2026-07-27) and `susfs.h` still defines a
`NON-GKI` variant, so the codebase has not dropped non-GKI kernels. Its current
KernelSU-side patch targets exactly the restructured layout KSU Next `legacy`
now has — **28 of the 29 files it touches exist at legacy HEAD** (only
`kernel/hook/syscall_event_bridge.c` is missing). That is drift within one
architecture, not a structural mismatch.

**The plan changed on 2026-07-28. Use ShirkNeko's 4.9 branch, v1.5.9.** Backing
out of the 5.10→4.9 backport, because a 4.9-native patch exists and is far
cheaper:

| route | kernel-side effort |
|---|---|
| simonpunk `gki-android12-5.10` v2.2.0 | backport 2653 lines, 8 `LINUX_VERSION_CODE` guards, `fs/susfs.c` 1200→1468 |
| **ShirkNeko `kernel-4.9` v1.5.9** | **1992-line native 4.9 patch, ~30 problem lines of context drift** |
| simonpunk `kernel-4.9` v1.5.5 | native but frozen Feb 2025, 32 vs 38 symbols |

**Remaining Phase 5 work, quantified:**

1. **Kernel side** — apply ShirkNeko's `50_add_susfs_in_kernel-4.9.patch`
   (1992 lines) plus the `fs/susfs.c`, `fs/sus_su.c` and three header drops.
   It touches 16 files (`fs/namei.c`, `fs/dcache.c`, `fs/namespace.c`,
   `fs/proc/*`, `fs/stat.c`, `kernel/kallsyms.c`, `kernel/sys.c`, …).
   ~30 problem lines, almost all `#include <linux/susfs.h>` insertions failing
   on LineageOS/LG context rather than anything structural.
2. **KernelSU side** — hand-merge its 1645-line `10_enable_susfs_for_ksu.patch`
   onto KSU Next `legacy`: **~23 problem lines.**

**Why hand-merging is unavoidable, on any fork.** Every ready-made 4.9 SuSFS
patch targets the pre-2026 **flat** KernelSU layout (`kernel/core_hook.c`,
`kernel/sucompat.c`, `kernel/ksud.c`, `kernel/throne_tracker.c`), and every
maintained fork has restructured into `kernel/core`, `kernel/feature`, … The
score is essentially identical whichever you pick — KSU Next `legacy` 23,
rsuntk `main` 22, SukiSU `main` 24 — so this is not a reason to change forks.

Feature set at v1.5.9: `SUS_PATH`, `SUS_MOUNT`, `SUS_KSTAT`, `TRY_UMOUNT`,
`SPOOF_UNAME`, `SPOOF_CMDLINE_OR_BOOTCONFIG`, `OPEN_REDIRECT`, `ENABLE_LOG`,
`SUS_SU`. Only `SUS_MAP` and `HIDE_KSU_SUSFS_SYMBOLS` are v2.x-only — revisit
the backport if those turn out to matter.

## Status

- **Phases 0–4 complete and verified on-device (2026-07-27).**
  - Standalone build reproduces the OrangeFox reference `.config` byte for byte.
  - AnyKernel3 + `fastboot boot` trial pipeline works; `boot_b-stock.img` is the
    ramdisk/header donor and the stock header is preserved verbatim.
  - KernelSU Next `legacy` @ `53791c92` builds with manual hooks and **runs**:
    the `com.rifsxd.ksunext` manager reports a compatible kernel. KSU version
    **33192**; the matching manager release is v3.3.0 (33214).
  - Subsystems re-verified on the KSU kernel: FBE `/data`, Wi-Fi, audio
    (121 `/dev/snd` nodes), 29 sensors, modem, 8 CPUs, battery. No Oops/BUG.
- **Phase 5 (SuSFS) not started.** See the measured plan above.
- `su` is not available to `adb shell` until shell is granted in the manager —
  KSU allowlists nothing by default. A denial there is not a fault.

## Decisions (2026-07-27)

- **LineageOS 22.2 is not installed yet.** It stays the eventual priority
  target, but everything is built and verified against stock A12 first.
- **First flashable build targets stock A12** — the firmware currently on the
  phone, where the kernel-swap path, OrangeFox and EDL are all already proven.
- **Delivery is an AnyKernel3 zip flashed from OrangeFox.** There is no
  `fastboot boot` trial path for a kernel, OrangeFox can back up `boot` first,
  and AnyKernel3 replaces the kernel while preserving the existing ramdisk —
  the same drop-in property that already works. `dtbo` is never touched.
  AnyKernel3 being ramdisk-agnostic is also what lets one zip serve both stock
  A12 and LineageOS later.
- **SuSFS scope is kernel-side only.** This repo produces a SuSFS-capable
  kernel; the `ksu_susfs` tool and `ksu_module_susfs` hiding module are
  installed separately from upstream. Note the consequence: **the kernel alone
  hides nothing** — SuSFS does almost nothing until that userspace module drives
  it, so "SuSFS works" can only be verified with the module installed.

## Build environment

Everything builds in **WSL**. Windows host, Linux build tree. **There is no CI.**

- AOSP/OrangeFox tree: `~/fox`; kernel at `~/fox/kernel/lge/sdm845` (~987 MB)
- Known-good reference `.config`:
  `~/fox/out/target/product/caymanslm/obj/KERNEL_OBJ/.config`
- Toolchain: `~/fox/prebuilts/clang/host/linux-x86/clang-r487747c`
  (identified from `/proc/version` on the running device)

### How the kernel is actually built — verified 2026-07-27

Three things in the original brief were wrong. Corrected here:

- **It is not `AndroidKernel.mk`'s `REAL_CC` scheme.** That file exists in the
  kernel tree but is dead code on this path. The kernel is built by TWRP's
  `vendor/twrp/build/tasks/kernel.mk` + `vendor/twrp/config/BoardConfigKernel.mk`,
  which pass **`LLVM=1 LLVM_IAS=1 LD=ld.lld AR=llvm-ar HOSTCC=clang`** — the
  opposite of "not `LLVM=1`".
- **No GCC cross-toolchain exists, and none is needed.**
  `~/fox/prebuilts/gcc/linux-x86/` contains only `host/`; the
  `aarch64/aarch64-linux-android-4.9` and `arm/arm-linux-androideabi-4.9` paths
  `BoardConfigKernel.mk` references are absent. `LLVM=1` supplies the
  assembler and all binutils, so no GCC binary is ever invoked.
- **`CROSS_COMPILE` is nonetheless required — it is not inert.** On 4.9 it is
  what gives clang its target triple (`Makefile:531`,
  `CLANG_TRIPLE ?= $(CROSS_COMPILE)`). Leave it unset and clang silently
  compiles arm64 sources for the **x86_64 host**, failing in `asm-offsets.c`
  with `register 'sp' unsuitable for global register variables` and
  `value '65536' out of range for constraint 'I'`. Pass
  `CROSS_COMPILE=aarch64-linux-gnu-` (plus a matching `CLANG_TRIPLE`); the
  `GCC_TOOLCHAIN_DIR` lookup at `Makefile:536` just resolves empty. Avoid a
  `*-linux-android-` prefix — `Makefile:534` hard-errors on an Android triple.
- **`CROSS_COMPILE_ARM32` must also be set to a non-empty string.**
  `CONFIG_COMPAT_VDSO=y`, and `arch/arm64/Makefile` hard-errors on an empty
  value (`CROSS_COMPILE_ARM32 not defined or empty`). Only non-emptiness is
  checked. Under clang the compat vDSO is built by
  `CC_ARM32 = clang --target=arm-linux-gnueabi`; the prefix is used *only* to
  locate a GCC toolchain via `which $(CROSS_COMPILE_ARM32)ld`, which fails
  here and leaves `--gcc-toolchain`/`--prefix` empty. That is precisely what
  the known-good OrangeFox build does too, since the ARM path it passes does
  not exist either. `build.sh` passes `arm-linux-gnueabi-`.
- **The running kernel is not the AOSP tree's output.**
  `KERNEL_OBJ/include/generated/compile.h` says `#2 nobody@android-build`; the
  phone reports `#7 noamtu123@DESKTOP-0N0FHOO`. Always set
  `KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST` so `uname -a` identifies our builds.

Standalone recipe (`scripts/build.sh`): clang on `PATH`, `ARCH=arm64 LLVM=1
LLVM_IAS=1 HOSTCC=clang HOSTCXX=clang++ LD=ld.lld AR=llvm-ar`, `O=` out of tree.
The correctness gate is that the generated `.config` is **identical** to the
known-good reference above. Iterating through `mka recoveryimage` is far too
slow to develop against.

## Sibling repo — a hard dependency

`E:\orangefox_caymanslm` (GitHub: `noamtu123/orangefox_caymanslm`) — OrangeFox
recovery for this device. This project depends on three things in it:

- the same pinned kernel source (`manifests/caymanslm.xml`)
- `kernel-patches/caymanslm-edl-warm-reset.patch` — the EDL kernel patch
- `edl-boot-script/patch-android-edl-boot.ps1` — the boot-image kernel swap

Read that repo for device specifics; `device/lge/caymanslm/BoardConfig.mk` has
the validated board values and `OVERLAY.md` explains every upstream change.

## Flashing — what actually matters here

Calibrate caution correctly. **This phone is a spare test device, not a daily
driver.** Data loss, factory resets and ROM reinstalls are cheap; don't hedge
about them or warn about them, it just slows the work down.

**A bad kernel cannot strand this device.** `recovery_a`/`recovery_b` are
separate partitions from `boot_a`/`boot_b`, so OrangeFox always comes up and
`boot` can be rewritten from there.

What *is* genuinely irreversible, and unchanged:

- **LG's firmware servers are gone.** There is no KDZ to restore from.
- The fuse-anchored bootloader chain — `xbl` / `abl` / `tz`. Patching these
  bricks past any recovery. **Never touch them.**
- **Never touch** userdata / metadata / persist / PINs / FBE keys / IMEI.
- **Keep the EDL kernel patch in every build**, or `adb reboot edl` — a genuine
  last-resort path — stops working. `scripts/verify-image.sh` asserts it.

### Procedure

- **`fastboot boot <img>` works and is the proven way to run a fresh build.**
  Every kernel gets RAM-booted from a throwaway `boot.img` (our `Image.gz-dtb` +
  the stock ramdisk) *before* anything is written to flash. This contradicts the
  original brief's "there is no `fastboot boot` trial path" — there is one.
- LG's bootloader **rejects `fastboot flash recovery`** even when unlocked.
  `boot` flashes fine.
- **The agent pushes; the operator flashes.** `adb push` the artifact, then the
  operator installs it from OrangeFox. No `dd` to block devices, and don't rely
  on `adb reboot`.
- **Never trust that a flash took.** Flashing a partition and rebooting has
  silently left an *old* image running here, wasting many test cycles. Verify
  the running build from its version string (`uname -a` → `caymanslm-kernel`
  plus the expected build number) before believing any result.
- **Verify by unpacking the artifact, not by reading makefiles.** In the sibling
  repo, reading `Android.mk`/`Android.bp` produced a confidently wrong
  conclusion and shipped a broken `keystore2.rc`.
- A/B device: **flash one slot at a time**, keep the other bootable. The
  practical eventual layout is slot A stock A12, slot B LineageOS.

### Don't touch fscrypt or crypto config

This kernel is **legacy-fscrypt only** — fscrypt v1 policy with Qualcomm
PFK/ICE; the v2 `FS_IOC_ADD_ENCRYPTION_KEY` ioctl returns `ENOTTY`. OrangeFox's
entire FBE `/data` decryption fix is built on that assumption. Changing crypto
config would break decryption in both the recovery and the ROM.

## Conventions — carried over from the recovery repo, keep them

### No forks

Every change to upstream (kernel, KernelSU Next, SuSFS) lives **in this repo**
as a patch or an overlay file, re-applied by a script after a fresh clone or
sync. No per-repo forks.

### LF only, always

A Windows checkout feeds a Linux build. Editing tools here write CRLF, and
shell — unlike `make` and XML — does **not** strip a trailing CR. In the sibling
repo this silently broke `= "1"` flag tests and even put a literal CR inside a
filename.

After every edit:

```bash
sed -i 's/\r$//' <file>
```

and confirm `git ls-files --eol | grep w/crlf` is empty before committing. Pin
LF in `.gitattributes`.

### Commits

Authored **and** committed as
`noamtu123 <noamtu123@users.noreply.github.com>`, with **no** `Co-Authored-By`
trailer.

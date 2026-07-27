# caymanslm_kernel — custom kernel for the LG Velvet 4G

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

Verified 2026-07-27:

- Integration is `setup.sh` with an explicit ref:
  `curl -LSs .../KernelSU-Next/next/kernel/setup.sh | bash -s legacy`.
  The argument is a git ref — `legacy` is the branch maintained for old non-GKI
  kernels, and the script **silently falls back to the default branch** if the
  ref does not resolve. Pin a tag/SHA and assert what was checked out.
- `legacy`'s `kernel/Kconfig` offers `KSU_MANUAL_HOOK` (defaults on when
  KPROBES is absent) and `KSU_KPROBES_HOOK` (needs ≥5.10). Note the upstream
  docs page writes `CONFIG_KSU_KPROBE_HOOKS`, which does not match the Kconfig —
  trust the Kconfig.
- Manual hooks go into five call sites: `do_execve` (`fs/exec.c`),
  `SYSCALL_DEFINE3` (`fs/open.c`), `vfs_read` (`fs/read_write.c`),
  `SYSCALL_DEFINE4` (`fs/stat.c`), `SYSCALL_DEFINE4` (`kernel/reboot.c`).
- Pre-5.10 kernels need `path_umount()` backported into `fs/namespace.c`.

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
### SuSFS integration — measured, 2026-07-27. Read before attempting Phase 5.

Two candidate routes were tested against the real trees. **Both are blocked**;
neither is a clean merge. Don't rediscover this.

**Route A — use KSU Next's pre-integrated SuSFS tag: RULED OUT.**
`v3.1.0-legacy-susfs` (`ba4422f0…`) does carry a full `KSU_SUSFS_*` menu next to
`KSU_MANUAL_HOOK`, which looked like it would remove the merge entirely. But it
targets a **v2.0.0-era kernel side**. Its `kernel/` calls **24 `susfs_*`
symbols that v1.5.5 does not define** — including non-optional ones like
`susfs_show_version`, `susfs_get_enabled_features`, `susfs_set_sid` and the
whole SID/domain family (`susfs_is_current_zygote_domain`,
`susfs_set_current_proc_umounted`, …), plus `susfs_add_sus_map` and
`susfs_reorder_mnt_id`. Its `kernel/Kbuild` reads `SUSFS_VERSION` straight from
`$(srctree)/include/linux/susfs.h`, so it adapts its *reporting* to whatever
kernel side is present but not its *API expectations*. Pairing it with the
frozen 4.9 branch will not link.

**Route B — hand-merge v1.5.5's `10_enable_susfs_for_ksu.patch`: not clean on
any legacy tag.** `git apply --reject` counts (rejected hunks + missing files):

| KSU Next tag | problems |
|---|---|
| `v3.0.1-legacy` | 42 |
| `v3.1.0-legacy` | 42 |
| `v3.2.0-legacy` | 42, and it has **deleted** `kernel/sucompat.c`, `kernel/throne_tracker.c`, `kernel/throne_tracker.h` — files the patch edits |

The patch was written against 2025-era *upstream KernelSU*; KSU Next forked and
diverged, so no legacy tag matches it. Rejects concentrate in
`kernel/selinux/selinux.c` (7), `rules.c` (3), `Makefile` (2), `Kconfig` (1).

**Therefore Phase 5 is a porting job, not a merge**, and the two honest options
are: (a) port the v2.0.0-era kernel side from a maintained `gki-*` branch back
to 4.9, then use `v3.1.0-legacy-susfs` as-is; or (b) re-derive v1.5.5's KSU-side
integration by hand against a chosen legacy tag. Decide by inspecting the actual
diffs — and note (a) at least targets a *maintained* codebase.

- 4.9 branch feature set: `SUS_PATH`, `SUS_MOUNT`, `AUTO_ADD_SUS_BIND_MOUNT`,
  `AUTO_ADD_SUS_KSU_DEFAULT_MOUNT`, `SUS_KSTAT`, `TRY_UMOUNT`,
  `AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT`, `SPOOF_UNAME`, `ENABLE_LOG`,
  `SPOOF_CMDLINE_OR_BOOTCONFIG`, `OPEN_REDIRECT`, `SUS_SU`.

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

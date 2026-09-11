# caymanslm_kernel — custom kernel for the LG Velvet 4G

Custom Android kernel for the **LG Velvet 4G, LM-G910EMW** (`caymanslm`,
Snapdragon 845), built from LineageOS 4.9.337 source and carrying
**KernelSU Next** and **SuSFS**.

> **LM-G910EMW only.** Not the 5G Velvet (`caymanlm` / SDM765G) — different SoC,
> different device. Every script here refuses to run on anything else.

Target ROMs, in priority order:

1. **LineageOS 22.2** — the main target.
2. **Stock Android 12**, firmware `G91030a` — what the device runs today, and
   what the first builds are verified against.

## Status

KernelSU Next `v3.2.0-legacy` and the Linux 4.9 backport of SuSFS `v2.2.0`
build successfully. The SuSFS bridge retains compatibility with the official
KernelSU Next manager. See [`CLAUDE.md`](CLAUDE.md) for implementation details,
device constraints, and on-device verification still required.

## Manager discovery after a cold boot

The kernel recognizes the KernelSU Next manager by reading its APK and verifying
the signature. On this device that APK sits in credential-encrypted storage that
stays locked until Android unlocks `/data` — roughly **30–55 s after a cold
boot** — so nothing can crown the manager before then. That window is inherent to
legacy FBE and cannot be closed in the kernel.

These changes make discovery across that window reliable and hand the driver fd to
a manager that is already running:

- the async discovery worker retries with a bounded ~60 s backoff, so it spans the
  whole unlock window instead of giving up after ~1 s;
- once it crowns the verified UID, it installs the fd into the running manager via
  a task-work callback (no identity is granted — the UID was already crowned by the
  certificate check);
- `on_boot_completed` runs a full search when no manager is crowned yet, instead
  of a prune-only pass that would cancel discovery.

**What this does and does not remove.** Open the manager *after* `/data` unlocks
(the normal case) and it is crowned at spawn and reads "working" on the first try.
Open it *before* unlock and its APK is unreadable, so the manager's one-time
startup check caches "not integrated." The official manager does not re-probe a
failed instance on its own (verified on-device), so that first instance can still
need a reopen — the fd we install lands in the running process, but the UI only
reflects it if the app re-checks. Removing the reopen entirely needs either a
manager that re-probes (a userspace change) or a persisted optimistic crown from a
prior boot (a kernel feature with a small trust tradeoff — not implemented here).
**"Zygisk required"** on modules is a separate, downstream wait on ReZygisk's
daemons finishing startup, which the kernel can't accelerate.

## How it is delivered

An **AnyKernel3 zip**, flashed from OrangeFox. AnyKernel3 replaces the kernel
while preserving the existing ramdisk, which is what lets one zip serve both
stock Android 12 and LineageOS. `dtbo` is never touched — LG's device-tree
overlays must keep applying.

Every build also produces a throwaway `boot.img` for `fastboot boot`, so a new
kernel can be RAM-booted and proven before anything is written to flash.

## Building

Everything builds in WSL. There is no CI.

```sh
./scripts/setup-tree.sh                 # clone kernel + KernelSU Next + SuSFS at pinned refs
./scripts/build.sh --profile=release    # -> Image.gz-dtb (hardened; use this for a deliverable)
./scripts/package.sh                    # -> artifacts/*.zip and a trial boot.img
```

`--profile=release` strips the broad symbol/debug disclosure (`KALLSYMS_ALL`,
`DEBUG_INFO`, kprobes, kcore, devmem, …). The bare `./scripts/build.sh` builds
the `baseline` profile, which keeps them — fine for development and for the
byte-for-byte reference-config check, but **not** what you want in a shipped
kernel. `package.sh` warns if you package a baseline build.

After booting a built image, run `./scripts/verify-root-stack.ps1` from
PowerShell. It checks that the current boot executed KernelSU post-fs-data,
that SuSFS exposes the complete configured feature set, and that activation
markers are not stale. ReZygisk state is reported separately because its
userspace module is not part of this repository.

Note that KernelSU modules record a feature profile when they are **flashed**,
not at boot, so every module must be reinstalled after a new kernel is
installed or they will silently keep an older profile.

All upstream revisions live in [`pins.sh`](pins.sh). They are pinned by SHA and
asserted after checkout — nothing floats.

## Repo layout

| Path | Contents |
|---|---|
| `pins.sh` | every upstream ref, the toolchain paths, and the workspace location |
| `scripts/` | setup, build, packaging and the unpack-and-assert verifier |
| `patches/kernel/` | changes to the kernel tree (EDL, `path_umount`, KSU hooks, SuSFS) |
| `patches/kernelsu/` | SuSFS bridge changes to pinned KernelSU Next |
| `config/` | defconfig fragments for KernelSU and SuSFS |
| `anykernel/` | AnyKernel3 device configuration |

There are **no forks** — upstream is cloned at a pinned ref and every change
lives here as a patch, re-applied by `setup-tree.sh`. Same convention as the
sibling recovery repo.

## Sibling repo

[`orangefox_caymanslm`](https://github.com/noamtu123/orangefox_caymanslm) —
OrangeFox recovery for this device. This project depends on it for the pinned
kernel source, the EDL kernel patch, and the boot-image kernel-swap script.

## Licence

GPL-2.0, matching the kernel it patches. Patches under `patches/kernel/` are
derivative works of the Linux kernel and carry its terms; KernelSU Next and
SuSFS keep their own.

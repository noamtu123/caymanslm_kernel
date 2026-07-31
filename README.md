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
./scripts/setup-tree.sh    # clone kernel + KernelSU Next + SuSFS at pinned refs
./scripts/build.sh         # -> Image.gz-dtb
./scripts/package.sh       # -> artifacts/*.zip and a trial boot.img
```

After booting a built image, run `./scripts/verify-root-stack.ps1` from
PowerShell. It checks that the current boot executed KernelSU post-fs-data,
that SuSFS exposes the complete configured feature set, and that activation
markers are not stale. ReZygisk state is reported separately because its
userspace module is not part of this repository.

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

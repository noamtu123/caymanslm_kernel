# caymanslm_kernel — custom kernel for the LG Velvet 4G

Custom Android kernel for the **LG Velvet 4G, LM-G910EMW** (`caymanslm`,
Snapdragon 845), built from LineageOS 4.9.337 source, carrying
**KernelSU Next**, **SuSFS**, and **NoMount**.

> **LM-G910EMW only.** Not the 5G Velvet (`caymanlm` / SDM765G) — different SoC,
> different device. Every script here refuses to run on anything else.

## Status

**`main` (v1.2 line):** KernelSU Next `legacy` + SuSFS `v2.3.0` (4.9 backport) +
NoMount `v2.0.0`. The kernel's own identity is branded: `uname -r` reads
`4.9.337-Wraith-v1.2-ksun` to a root/`su` shell and stock `4.9.337-perf` to
unprivileged apps — baked into the kernel, no userspace helper required. Verified
booting on LineageOS 22.2; a Duck Detector scan (2026‑09‑18 build) reports **0
danger** — kernel, mount, SELinux, SU, TEE, Zygisk and bootloader checks all
clear (remaining warnings are the ROM itself being LineageOS, not the kernel).

**v1.2 ships two KSU variants** (see below). Previous tag:
[v1.1](https://github.com/noamtu123/caymanslm_kernel/releases/tag/v1.1) —
KernelSU Next `legacy` + SuSFS `v2.2.0` + NoMount `v2.0.0`, tested on both stock
Android 12 (`G91030a`) and LineageOS 22.2.

### KernelSU variants

The root stack is tracked per KSU fork; the active fork is baked into the `uname`
brand (`…-ksun` vs `…-xxksu`). **v1.2 releases both** — pick one AnyKernel zip:

| Branch | Fork | Notes |
|---|---|---|
| `main` | [KernelSU‑Next](https://github.com/KernelSU-Next/KernelSU-Next) `legacy` | non‑GKI 4.9, manual hooks; the only KSU‑Next line that still supports pre‑4.14 (dev/stable dropped 4.x and require KPROBES). SuSFS `v2.3.0`. Duck **0 danger**. |
| `xxksu` | [backslashxx/KernelSU](https://github.com/backslashxx/KernelSU) `v3.3.0‑39` | syscall‑table hooking — no manual `fs/*.c` hooks needed on this tree. SuSFS `v2.3.0` + NoMount. Booted on LineageOS 22.2; Duck **0 danger** (its injected sepolicy edges are hidden from app queries). |

Both are the same kernel base and SuSFS backport; they differ only in the KSU
fork and its hooking method. See [`CLAUDE.md`](CLAUDE.md) for implementation
details.

## How it is delivered

An **AnyKernel3 zip**, flashed from OrangeFox. AnyKernel3 replaces the kernel
while preserving the existing ramdisk, so one zip serves both stock Android 12
and LineageOS. `dtbo` is never touched — LG's device-tree overlays must keep
applying. Every build also produces a throwaway `boot.img` for `fastboot boot`,
so a kernel can be RAM-booted and proven before anything is written to flash.

## Building

Everything builds in WSL. There is no CI.

```sh
./scripts/setup-tree.sh                 # clone kernel + KernelSU Next + SuSFS at pinned refs
./scripts/build.sh --profile=release    # -> Image.gz-dtb (hardened; use for a deliverable)
./scripts/package.sh                    # -> artifacts/*.zip and a trial boot.img
```

`--profile=release` strips the broad symbol/debug disclosure (`KALLSYMS_ALL`,
`DEBUG_INFO`, kprobes, kcore, devmem, …). Bare `./scripts/build.sh` builds the
`baseline` profile, which keeps them — fine for development and the byte-for-byte
reference-config check, not for a shipped kernel; `package.sh` warns if you
package a baseline build.

All upstream revisions live in [`pins.sh`](pins.sh), pinned by SHA and asserted
after checkout — nothing floats.

## Manager discovery after a cold boot

The manager APK sits in credential-encrypted storage that stays locked until
`/data` unlocks (~30–55 s after a cold boot), so nothing can crown the manager
before then — a legacy-FBE window the kernel can't close. Discovery is made
reliable across it (bounded ~60 s retry backoff spanning unlock, driver fd
handed to the already-running manager via task-work, full search on
`boot_completed` when uncrowned). Opening the manager **after** unlock: crowned
at spawn, reads "working" immediately. Opening it **before**: its one-time
startup check caches "not integrated" and the first instance may need a reopen
(the official manager doesn't re-probe on its own). `"Zygisk required"` on
modules is a separate wait on ReZygisk's daemons, not the kernel.

## Repo layout

| Path | Contents |
|---|---|
| `pins.sh` | every upstream ref, toolchain paths, workspace location |
| `scripts/` | setup, build, packaging, and the unpack-and-assert verifier |
| `patches/kernel/` | kernel-tree changes (EDL, `path_umount`, KSU hooks, SuSFS, NoMount, SELinux hiding) |
| `patches/kernelsu/` | changes to pinned KernelSU Next |
| `config/` | defconfig fragments and build profiles |
| `anykernel/` | AnyKernel3 device configuration |

**No forks** — upstream is cloned at a pinned ref and every change lives here as
a patch, re-applied by `setup-tree.sh`.

## Sibling repo

[`orangefox_caymanslm`](https://github.com/noamtu123/orangefox_caymanslm) —
OrangeFox recovery for this device. This project depends on it for the pinned
kernel source, the EDL kernel patch, and the boot-image kernel-swap script.

## Licence

GPL-2.0, matching the kernel it patches. KernelSU Next, SuSFS, and NoMount keep
their own terms.

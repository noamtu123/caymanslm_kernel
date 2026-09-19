# caymanslm_kernel — the Wraith kernel for the LG Velvet 4G

A rooted, hardened Android kernel for the **LG Velvet 4G (LM‑G910EMW**,
`caymanslm`, Snapdragon 845), built from LineageOS 4.9.337 source with
**KernelSU**, **SuSFS**, and **NoMount**. "Wraith" is the goal: fully rooted to
you, invisible to apps that look for root.

> **LM‑G910EMW only.** Not the 5G Velvet (`caymanlm` / SDM765G) — different SoC,
> different device. Every script here refuses to run on anything else.

## Download & install

Grab the latest [**release**](https://github.com/noamtu123/caymanslm_kernel/releases/latest)
and flash the AnyKernel3 zip with any flasher — a custom recovery, the KernelSU
manager, or a kernel flasher app. It swaps only the kernel and keeps your
ramdisk, so one zip works on both stock Android 12 and LineageOS; `dtbo` is never
touched.

Two variants — **same kernel base and SuSFS backport, different KSU fork:**

| Variant | KSU fork | Choose it if… |
|---|---|---|
| **ksun** | [KernelSU‑Next](https://github.com/KernelSU-Next/KernelSU-Next) `legacy` | you want the established, battle‑tested line (v1.0/v1.1 lineage) |
| **xxksu** | [backslashxx/KernelSU](https://github.com/backslashxx/KernelSU) `v3.3.0‑39` | you want the newer fork with syscall‑table hooking |

Both report **0 danger** on Duck Detector — kernel, mount, SELinux, SU, TEE,
Zygisk and bootloader all clear (remaining warnings are the ROM simply being
LineageOS, not the kernel).

## What's inside

- **KernelSU** — kernel‑level root with a per‑app manager.
- **SuSFS `v2.3.0`** — mount / path / kstat / uname / cmdline hiding (4.9 backport).
- **NoMount `v2.0.0`** — mountless module engine, so there are no overlay mounts to detect.
- **Wraith stealth** — the `uname` brand is baked into the kernel: a root/`su`
  shell sees `4.9.337-Wraith-v1.2-<variant>`, every app sees stock
  `4.9.337-perf`, with no userspace helper. Plus redacted `/proc/config.gz`,
  SELinux injected‑type and dirty‑edge hiding, and no su‑access kernel logs.

## Branches

| Branch | Variant |
|---|---|
| `ksun` *(default)* | KernelSU‑Next `legacy` |
| `xxksu` | backslashxx/KernelSU `v3.3.0‑39` |

**This branch is `ksun`.** Both branches share the kernel base and SuSFS
backport; they differ only in the KSU fork and its hooking method. See
[`CLAUDE.md`](CLAUDE.md) for implementation details.

## Changelog

- **v1.2** — SuSFS `v2.2.0 → v2.3.0`; added the **xxksu** variant and hid its
  injected SELinux edges from apps; baked the Wraith `uname` into the kernel.
- **[v1.1](https://github.com/noamtu123/caymanslm_kernel/releases/tag/v1.1)** —
  perfected SELinux hiding, NoMount `v2.0.0`; tested on stock Android 12 and LineageOS 22.2.
- **v1.0** — first release: KernelSU‑Next + SuSFS + NoMount.

## Building

Everything builds in WSL; there is no CI.

```sh
./scripts/setup-tree.sh              # clone kernel + KernelSU + SuSFS at pinned refs
./scripts/build.sh --profile=release # -> Image.gz-dtb (hardened; use for a deliverable)
./scripts/package.sh                 # -> artifacts/*.zip (AnyKernel3, flash with any flasher)
```

`--profile=release` strips the broad symbol/debug disclosure (`KALLSYMS_ALL`,
`DEBUG_INFO`, kprobes, kcore, devmem, …). Bare `./scripts/build.sh` builds the
`baseline` profile, which keeps them — fine for development, not for a shipped
kernel (`package.sh` warns if you package a baseline build). All upstream
revisions live in [`pins.sh`](pins.sh), pinned by SHA and asserted after
checkout — nothing floats.

## Manager discovery after a cold boot

The manager APK lives in credential‑encrypted storage that stays locked until
`/data` unlocks (~30–55 s after a cold boot), so nothing can crown the manager
before then. Discovery is made reliable across that window (bounded retry
backoff, driver fd handed to the running manager, full search on
`boot_completed`). Open the manager **after** unlock and it reads "working"
immediately; open it **before** and its one‑time check may cache "not
integrated" until you reopen it. `"Zygisk required"` on modules is a separate
wait on ReZygisk's daemons, not the kernel.

## Repo layout

| Path | Contents |
|---|---|
| `pins.sh` | every upstream ref, toolchain paths, workspace location |
| `scripts/` | setup, build, packaging, and the unpack‑and‑assert verifier |
| `patches/kernel/` | kernel‑tree changes (EDL, `path_umount`, KSU hooks, SuSFS, NoMount, SELinux hiding) |
| `patches/kernelsu/` | changes to the pinned KernelSU fork |
| `config/` | defconfig fragments and build profiles |
| `anykernel/` | AnyKernel3 device configuration |

**No forks** — upstream is cloned at a pinned ref and every change lives here as
a patch, re‑applied by `setup-tree.sh`.

## Sibling repo

[`orangefox_caymanslm`](https://github.com/noamtu123/orangefox_caymanslm) —
OrangeFox recovery for this device, and the source of the pinned kernel tree, the
EDL kernel patch, and the boot‑image kernel‑swap script.

## Licence

GPL‑2.0, matching the kernel it patches. KernelSU, SuSFS, and NoMount keep their
own terms.

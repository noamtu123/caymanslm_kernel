# caymanslm_kernel — the Wraith kernel for the LG Velvet 4G

A rooted, stealthy Android kernel for the **LG Velvet 4G** (LM‑G910EMW,
`caymanslm`, Snapdragon 845), with **KernelSU**, **SuSFS**, and **NoMount** —
fully rooted to you, invisible to apps that check for root.

> **LM‑G910EMW only.** Not the 5G Velvet (`caymanlm` / SDM765G) — different SoC.
> Every script here refuses to run on anything else.

## Install

Download the latest [**release**](https://github.com/noamtu123/caymanslm_kernel/releases/latest)
and flash the AnyKernel3 zip.

Two variants — same kernel and SuSFS, different KernelSU fork:

| Variant | Fork | What it is |
|---|---|---|
| **ksun** *(default)* | [KernelSU‑Next](https://github.com/KernelSU-Next/KernelSU-Next) | polished, well‑organized KSU with a built‑in kernel flasher |
| **xxksu** | [backslashxx/KernelSU](https://github.com/backslashxx/KernelSU) | modern KSU fork built for older kernels |

*This branch is `ksun`; the other variant lives on the `xxksu` branch.*

## What's inside

- **KernelSU** — kernel‑level root with a manager app.
- **SuSFS `v2.3.0`** — hides mounts, paths, and kernel identity.
- **NoMount `v2.0.0`** — mountless modules, so there are no overlay mounts to detect.
- **Wraith stealth** — root sees `uname` `4.9.337-Wraith`, apps see stock
  `4.9.337-perf`; `/proc/config.gz` is redacted and SELinux traces are hidden.
  Passes Duck Detector with **0 danger**.

## Building

WSL, no CI:

```sh
./scripts/setup-tree.sh              # clone kernel + KernelSU + SuSFS at pinned refs
./scripts/build.sh --profile=release # -> Image.gz-dtb
./scripts/package.sh                 # -> artifacts/*.zip (AnyKernel3)
```

Every upstream ref is pinned by SHA in [`pins.sh`](pins.sh); see
[`CLAUDE.md`](CLAUDE.md) for internals.

## Repo layout

| Path | Contents |
|---|---|
| `pins.sh` | every upstream ref, toolchain paths, workspace location |
| `scripts/` | setup, build, packaging, and the unpack‑and‑assert verifier |
| `patches/kernel/` | kernel‑tree changes (EDL, `path_umount`, KSU hooks, SuSFS, NoMount, SELinux hiding) |
| `patches/kernelsu/` | changes to the pinned KernelSU fork |
| `config/` | defconfig fragments and build profiles |
| `anykernel/` | AnyKernel3 device configuration |

## Sibling repo

[`orangefox_caymanslm`](https://github.com/noamtu123/orangefox_caymanslm) —
OrangeFox recovery for this device, and the source of the pinned kernel tree.

## Licence

GPL‑2.0, matching the kernel it patches. KernelSU, SuSFS, and NoMount keep their
own terms.

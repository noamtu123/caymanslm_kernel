# Handoff — LG Velvet caymanslm kernel / KSU Next + SuSFS

**Date:** 2026-07-28  
**Workspace:** `E:\\caymanslm_kernel` (Windows host; build in WSL)  
**Device:** LG Velvet 4G LM-G910EMW (`caymanslm`), Snapdragon 845, stock Android 12 with Android 11 vendor.  
**Do not treat the Android 11 vendor / Android 12 system combination as a fault:** LG ships it this way.

## Update — 2026-07-29: hardened candidate built, awaiting RAM-boot test

- New artifact: `E:\\caymanslm_kernel\\artifacts\\boot-trial-susfs-v2.2.0-hardened-ikconfig.img`
- SHA-256: `E6117092C91A4E8B87C6A81C6D4DCDEA232D8C89C7CB2872BF9FB47E5C561B66`
- Exact command:
  ```powershell
  fastboot boot "E:\\caymanslm_kernel\\artifacts\\boot-trial-susfs-v2.2.0-hardened-ikconfig.img"
  ```
- It was built from a fresh local replay of all pinned sources and release patches. Static verification passed:
  - actual build config: KSU + SuSFS enabled, `CONFIG_IKCONFIG_PROC=y`, `CONFIG_SECURITY_DMESG_RESTRICT=y`;
  - embedded `/proc/config.gz` payload: `IKCONFIG_PROC` and dmesg restriction present, **zero `CONFIG_KSU*` lines**;
  - EDL marker, SuSFS v2.2.0 marker, and KernelSU marker present.
- Still required on device: two clean KSUN launches/root grants, no VINTF warning, ordinary `adb shell dmesg` denied, approved `su -c dmesg -T` succeeds.
- Reproducibility fixes made during this work: `pins.sh` now defaults to the active `susfs-v2-replay` WSL workspace; the Android 12 app-process patch path was corrected; obsolete diagnostics patches are explicitly excluded from release replay.

> `CLAUDE.md` contains useful historical device/build details but is stale and internally contradictory about the completed SuSFS v2.2 work and `/proc/config.gz`. This handoff is the current state.

## User's objective and constraints

- Keep the device on its existing Linux **4.9.337** base. Do not propose a Linux-version port unless separately requested.
- Kernel-integrated root: KernelSU Next legacy/manual-hook path, controlled by the **KSUN Manager** APK (`com.rifsxd.ksunext`).
- Latest SuSFS targeted: **v2.2.0**.
- User wants the strongest practical root-hiding configuration, but expects honest limits: do not promise zero detection.
- Every new artifact must be RAM-booted before any flash. Give the exact command in this form:
  ```powershell
  fastboot boot "E:\\caymanslm_kernel\\artifacts\\<filename>.img"
  ```
- Do not flash the device unless the user explicitly asks after a stable RAM-boot test.
- The user strongly prefers real fixes over retries/workarounds; explain the evidence behind a diagnosis.

## Current source and build layout

- WSL source: `/home/noamtu123/caymanslm-kernel/susfs-v2-replay/src`
- WSL output: `/home/noamtu123/caymanslm-kernel/susfs-v2-replay/build`
- KSU checkout: `/home/noamtu123/caymanslm-kernel/susfs-v2-replay/third_party/KernelSU-Next`
- KSU driver is symlinked to `src/drivers/kernelsu`.
- KSU pin: legacy branch, commit `53791c92bff13d62338f29cc9da035a37652ca91`.
- Its compiled identity is **v3.2.0-legacy / 33192**.
- Installed KSUN Manager: `com.rifsxd.ksunext`, v3.3.0, versionCode **33214**. Its expected APK signature is built into the kernel and matches:
  - size `0x3e6`
  - SHA-256 `79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7`
- `33214` is the manager APK version, not necessarily the in-kernel KSU core revision. Do not conflate them.
- SuSFS code identifies itself in `include/linux/susfs.h` as `SUSFS_VERSION "v2.2.0"`.

## Completed implementation

The 5.10-to-4.9 SuSFS v2.2 backport is complete and boots. KSU uses manual hooks because this 4.9 kernel has no kprobes.

Enabled Kconfig features in the currently built source:

```text
CONFIG_KSU=y
# CONFIG_KSU_DEBUG is not set
# CONFIG_KSU_DIAGNOSTICS is not set
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
# CONFIG_KSU_SUSFS_ENABLE_LOG is not set
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
# CONFIG_SECURITY_DMESG_RESTRICT is not set
```

The first eight SuSFS-related entries are the desired hiding capability: path/mount/kstat/map handling, uname and cmdline spoofing, open redirect, no SuSFS logging, and KSU/SuSFS symbol hiding.

## Important diagnosis: Android “internal problem” warning

The custom kernel initially showed:

> There's an internal problem with your device. Contact your manufacturer for details.

Android logs showed `Vendor interface is incompatible, error=1`; this was VINTF kernel-config validation, not an Android 11 vendor/Android 12 system mismatch. The issue was reproducibly removed by enabling:

```text
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
```

which exposes `/proc/config.gz` so VINTF can verify required config flags. It was tested twice without the warning.

**Security/hiding tradeoff:** `/proc/config.gz` exposes `CONFIG_KSU*` and `CONFIG_KSU_SUSFS*` to a sufficiently privileged checker. Therefore the present build cannot truthfully be called maximum configuration hiding. A future solution would need to preserve VINTF’s required config view while not exposing the real full config; this is a separate design/verification task, not something to claim solved.

`CONFIG_SECURITY_DMESG_RESTRICT` is currently off as debug spillover. Android SELinux already denied normal `adb shell dmesg`, but final hardening should set it back to `y` once the final manager image is validated.

## KSU manager integration issue and current fix

Earlier images booted but KSUN intermittently said “not integrated.” Logs captured an initial manager-native crash (`SIGSYS` / `SYS_SECCOMP`). The underlying race was manager discovery/crowning: KernelSU had not yet scanned/verified the manager APK/package when the manager’s first root request arrived.

Current patches added to the reproducible patch sequence:

- `patches/kernelsu/zzzzzzz-ksu-manager-scan-retry-until-crowned.patch`
  - keeps the tracker retrying until a manager is actually crowned.
- `patches/kernelsu/zzzzzzzz-ksu-manager-synchronous-setuid-discovery.patch`
  - makes the setuid hook synchronously discover the manager before checking its UID.
- `patches/kernelsu/zzzzzzzzz-ksu-manager-remove-spurious-dentry-lock-gate.patch`
  - removes an inappropriate dentry-lock gate that could reject discovery.

There was a temporary diagnostic patch which put manager state into `uname -v`; it was **removed** from the source and deleted from the workspace before the current final artifact. Do not re-add it except for tightly-scoped diagnosis.

The diagnostic image booted successfully twice in a row with:

```text
KSU-D uid=10334 found=1 crowned=10334
```

and no manager crash or VINTF warning. This was evidence that synchronous discovery fixed the race. The regular final image was then built with that instrumentation removed, but the user has not yet reported its test result.

## Current artifact awaiting user test

`E:\\caymanslm_kernel\\artifacts\\boot-trial-susfs-v2.2.0-final-manager.img`

SHA-256:

```text
FCCF1439FDE6457DFDFD90D00DC73683754CC15A91030D57B30B586EE8DCB0C0
```

It was pushed to `/data/local/tmp/boot-trial-susfs-v2.2.0-final-manager.img`.

Exact RAM-boot command:

```powershell
fastboot boot "E:\\caymanslm_kernel\\artifacts\\boot-trial-susfs-v2.2.0-final-manager.img"
```

Ask the user to test two clean boots, opening KSUN immediately each time and trying a root grant. Also check whether the Android warning returns. Do not declare the manager issue fixed until that normal, instrumentation-free artifact succeeds repeatedly.

## Required next work after the above test

1. If the final-manager artifact fails integration, collect logs before changing code. Check KSU tracker/crowning state and look specifically for the prior `SIGSYS`/seccomp crash. Avoid blind retry logic.
2. If it succeeds repeatedly, build a final-hardened candidate with `CONFIG_SECURITY_DMESG_RESTRICT=y`; RAM-boot it and verify no regression.
3. Do not claim “best root hiding in every setting” while `CONFIG_IKCONFIG_PROC=y`. Explain the VINTF/config-exposure tradeoff accurately.
4. SuSFS feature presence must be tested separately from compilation. It needs appropriate userspace rules/module configuration; a SuSFS-capable kernel alone does not hide arbitrary apps or artifacts.
5. Any detector test should compare repeated reports over time, but never claim that an absence of detections proves universal undetectability.

## Relevant historical artifacts

- Earlier verified working (KSU root grant + KSUN):
  `E:\\caymanslm_kernel\\artifacts\\boot-trial-susfs-v2.2.0-ksu-verified-scan.img`
- Current normal manager-fix candidate:
  `E:\\caymanslm_kernel\\artifacts\\boot-trial-susfs-v2.2.0-final-manager.img`

## Editing/build discipline

- Use `apply_patch` for workspace edits.
- Preserve unrelated dirty worktree changes; no reset/checkout destructive commands.
- `scripts/setup-tree.sh` applies patches alphabetically from the KSU repository root. New patch paths must be correct for that replay.
- Validate a clean patch replay/build before trusting a candidate.
- Do not install a SuSFS module merely to prove compilation. First identify the exact module/rules and test effects deliberately.

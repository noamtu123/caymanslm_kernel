# Unprivileged app reliably panics the kernel with KernelSU-Next (non-GKI 4.9, enforcing only)

**Status: unresolved. This is a write-up for upstream KernelSU-Next, not a fix.**

## Summary

With KernelSU-Next compiled in, the unprivileged app **Duck Detector**
(`com.eltavine.duckdetector`, a root-detection app) hard-crashes the kernel within
seconds of being opened. The device freezes completely and cold-resets. It needs no
root, no granted permission and no module — just launching the app.

Without KernelSU the same app runs fine. In SELinux **permissive** mode it also runs
fine. Both facts are reproducible and were re-validated on a clean configuration.

## Device / build

| | |
|---|---|
| Device | LG Velvet 4G (`LM-G910EMW`, `caymanslm`), SDM845 |
| Kernel | LineageOS `android_kernel_lge_sdm845`, 4.9.337, **non-GKI**, no `CONFIG_KPROBES` |
| Hooks | `CONFIG_KSU_MANUAL_HOOK=y` (manual hooks; kprobes unavailable on 4.9) |
| KernelSU-Next | `legacy` branch @ `53791c92` |
| SuSFS | v2.2.0 backported to 4.9 (**not** required to reproduce) |
| ROM | Stock LG Android 12 (`G91030a`), SELinux enforcing |

## Reproduction

1. Boot a kernel with `CONFIG_KSU=y`. SELinux **enforcing**.
2. Open Duck Detector. Within ~2–30 s the device freezes hard and resets.
3. `setenforce 0` → no crash. `setenforce 1` → crashes again.

## What the crash is

- LG's panic notifier fires: next boot carries `lge.bootreason=KernelCrash`,
  `bootreasoncode=0x6D630100`, `PSTORE-BACKUP: PstoreBootReasonStr : KernelCrash`.
  So **`panic()` genuinely runs** — this is not a pure hardware reset.
- `CONFIG_PANIC_ON_OOPS=0` does **not** prevent it → it is an explicit `BUG()`/`panic()`,
  not a recoverable oops.
- `CONFIG_LOCKUP_DETECTOR` + `CONFIG_HARDLOCKUP_DETECTOR_OTHER_CPU`, both in
  **warn-only** mode, **never fire** → it is not a soft or hard lockup.
- The freeze kills all CPUs at once: a `dmesg`→`/data` follower running at 200 ms
  intervals captured nothing; the last entries are normal `pet_watchdog` messages.

## Why no backtrace is attached (every capture avenue is closed on this device)

| Method | Result |
|---|---|
| ramoops / pstore | Region registers (`ramoops: attached 0x280000@0xb0000000`) but the LG bootloader **wipes that RAM on every reset** — `/sys/fs/pstore` is empty even after a clean reboot |
| LG crash handler | `lge.crash_handler=off`, `lge.hiddenreset=1` are **bootloader** parameters (zero kernel references); `CMDLINE_EXTEND` places our args first, so the stock values win |
| netconsole | 4.9 netpoll requires `ndo_poll_controller`; neither `wlan0` nor the `u_ether` USB gadget implements it → `netconsole: wlan0 doesn't support polling, aborting` |
| `PANIC_ON_OOPS=0` | Doesn't apply — it's a `BUG()`/`panic()` |
| Live dmesg follower | Nothing — all CPUs die simultaneously |
| Soft/hard lockup detector (warn-only) | Never fires |

## Bisection (each line is a separate build, flashed and tested)

| Configuration | Result |
|---|---|
| `CONFIG_KSU=n`, NoMount off, SuSFS off | **no crash** |
| KSU on, NoMount on, SuSFS **off** | crashes |
| KSU on, NoMount **off**, SuSFS off | crashes |
| All 10 userspace modules disabled (ReZygisk, LSPosed, tricky_store, susfs4ksu, …) | crashes |
| root/ksud broken (manager could not grant) | crashes |
| `ksu_handle_setresuid` compiled out entirely | crashes |
| All 4 sucompat hooks (`execve`/`execveat`/`faccessat`/`newfstatat`) compiled out | crashes |
| `disable_seccomp()` neutered (its `pr_info_once` **did** print, so the path is reached) | crashes |

**Conclusion: KernelSU *kernel* code is required, but no individual hook is.** The crash
survives with root broken and every hook removed, which points at the runtime sepolicy
work KSU performs at init rather than at any syscall hook.

## Ruled out by direct measurement

- **Policydb integrity.** Added a validator that walks every type index after
  `apply_kernelsu_rules()`. On-device:
  `ksu_validate_policydb: nprim=3356 null_type_datum=0 null_type_name=0 null_attr_map=0`
  — no holes in `type_val_to_struct_array`, `sym_val_to_name[SYM_TYPES]` or
  `type_attr_map_array`.
- **Every app-reachable `BUG()`/`BUG_ON()` in SELinux**, hardened to fail closed and
  log: `context_struct_compute_av`, `services_compute_xperms_decision`,
  `security_bounded_transition`, `type_attribute_bounds_av`, all of
  `constraint_expr_eval`, `avc_dump_query`, `avc_dump_av`, `avc_has_perm*`,
  the three `ebitmap.h` accessors and the `sidtab` cache index.
  **None ever fired, and the crash persisted.**
- Two sub-theories checked and disproved: the `sizeof(xperms)` in
  `add_xperm_rule_raw()` is correct (stack struct), and `get_avtab_node()` storing
  `&xperms` is safe because `avtab_insert_node()` deep-copies into `avtab_xperms_cachep`.

## Real defects found along the way (fixed locally, worth upstreaming)

1. **`add_type()` leaks `p_types.nprim` on failure.** It does
   `u32 value = ++db->p_types.nprim;` *before* filling
   `type_val_to_struct_array[value - 1]`, and every failure path in between returns
   without rolling the counter back — leaving a NULL slot for an index the policy
   claims exists. Now reachable in practice because the no-sleep fix runs this path
   with `GFP_ATOMIC`. (Not the cause of this crash, but a real latent bug.)
2. **Prototype mismatch on `disable_seccomp()`**: defined `void disable_seccomp(void)`
   in `app_profile.c`, declared `extern void disable_seccomp(struct task_struct *tsk)`
   in `setuid_hook.c` and called with an argument. Benign on the arm64 ABI, still wrong.

## The question for upstream

Given the above — KSU required, no individual hook required, SELinux enforcing
required, policydb structurally intact, no SELinux assertion involved, and a genuine
`panic()` — **what in KernelSU's runtime sepolicy work can panic the kernel when an
unprivileged app generates a large volume of AVC denials on a non-GKI 4.9 tree?**

Any suggestion for capturing a backtrace on a device whose bootloader clears the
ramoops region would also be very welcome.

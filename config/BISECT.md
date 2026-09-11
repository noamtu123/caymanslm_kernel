# Root-stack bisect — Duck Detector Gold-core wedge

Opening Duck Detector wedges a Gold core (cpu4/cpu5) until the apps watchdog
bites and the phone reboots. This file is the single record of the bisect; the
`bisect-*.fragment` files carry no results, only their config delta.

## Trigger

`android:useAppZygote="true"` on Duck's `SelinuxContextValidityCarrierService`.
Android forks the isolated child from a dedicated app zygote, with `CLONE_NEWNS`.

Established from crashes (a crash is proof; a single survival is not — the wedge
is probabilistic with a long tail):

| Experiment | Result | Conclusion |
| --- | --- | --- |
| Duck branch `test/zygote-noop` (carrier payload stubbed, app-zygote kept) | WEDGED 23 s | the SELinux scanning work is not the cause |
| Duck branch `test/no-appzygote` (`useAppZygote` dropped, work kept) | survived 151 s | consistent with the fork path being the trigger |
| `setenforce 0` | WEDGED 24 s | not enforcement-dependent |
| all 8 KSU modules unmounted | WEDGED 25 s | not the modules |
| component bisect, carrier disabled | survived 140 s | — |
| component bisect, carrier re-enabled | WEDGED 22 s | the carrier is the trigger |

## Method

Run with `tests/duck-wedge-suite.sh`, which RAM-boots the image under test
before **every** trial — a wedge reboots the phone back to the *flashed* kernel,
so without that later trials silently test the wrong kernel.

Both hard preconditions are asserted per trial and printed in the result line:

- the installed app is the expected build (`EXPECT_APP`),
- the running kernel is recorded (`uname -v`).

Duck branch `test/deterministic` (`DiagAutopilot`) removes the agreement
countdown/captcha, the startup policy prompts and the alpha overlay, so a launch
runs all eighteen detectors with no human in the loop and no run-to-run
variation.

## Stages

| Stage | Fragment | Stack |
| --- | --- | --- |
| control | `bisect-noksu.fragment` | no root stack |
| A | `bisect-ksuonly.fragment` | KSU only |
| B | `bisect-nosusfs.fragment` | KSU + NoMount |
| C | `bisect-nonomount.fragment` | KSU + SuSFS |
| D | `bisect-nosusmount.fragment` | full stack, `SUS_MOUNT` off |
| ref | *(none)* | full stack |

Stop at the first stage that wedges: the cause is in what that stage added.

## Results

Measured 2026-09-04 with Duck `test/deterministic` (`e5501bd712da`) installed and
asserted on every trial, three trials per kernel, 240 s window, RAM-booted fresh
before each trial.

| Kernel | Result | Trigger fired |
| --- | --- | --- |
| control, no root stack | SURVIVED 3/3 (259 s) | yes -- carrier spawned 4x per run |
| stage A, KSU only | **WEDGED 3/3** (24 s, 25 s, 25 s) | wedges before the carrier spawns |
| stage B, KSU + NoMount | not run -- moot | |
| stage C, KSU + SuSFS | not run -- moot | |

**KernelSU alone is sufficient to cause the wedge.** Stage A carries neither
SuSFS nor NoMount and still wedges 3/3, and the same kernel with KSU removed
survives 3/3 while running the whole workload.

That is NOT the same as "SuSFS and NoMount are innocent", and an earlier version
of this file wrongly said so. A staged bisect that stops at the first stage to
fail identifies a *sufficient* cause, not every cause -- there may be more than
one independent way to wedge this box, and fixing KSU could simply uncover the
next one. Testability differs between the two:

- `CONFIG_NOMOUNT` has no dependency on KSU (`fs/Kconfig`), so NoMount CAN be
  built and tested on its own. That is probe B1.
- `CONFIG_KSU_SUSFS depends on KSU`, so SuSFS cannot be tested without KSU. While
  KSU alone wedges, SuSFS's independent contribution is unmeasurable; it can only
  be assessed after the KSU cause is fixed, by re-testing with SuSFS on.

  **Resolved.** With the root cause fixed, the full stack (KSU + SuSFS +
  SUS_MOUNT + NoMount) survives 5/5. SuSFS shows no independent contribution,
  and NoMount was already cleared standalone. There was one cause, not several.

This also retires the earlier "SUS_MOUNT / CL_COPY_MNT_NS is the cause" theory.
That theory came from the discarded pass described below and was never true.

Reference points, both confirmed with the correct app installed:

- release `#1 SMP PREEMPT Wed Aug 5 13:27:49 IDT 2026` -- WEDGED 2 of 3 (179 s, 181 s)
- current tree `#8` -- WEDGED (172 s), so nothing already committed fixes it

The release takes ~180 s to wedge where these stages take ~25 s only because
`test/deterministic` runs all eighteen detectors at once instead of waiting for
a human to clear the gates.

### Narrowing inside KernelSU

Same method, same app, three trials each, KSU-only base unless noted.

| Probe | What it removes | Result |
| --- | --- | --- |
| A1 | `feature/kernel_umount.c` defaulted off (module unmount on isolated spawn) | WEDGED 3/3 (25, 25, 23 s) |
| A2 | `ksu_su_compat_enabled` defaulted off (execve / faccessat / newfstatat / vfs_read hooks) | WEDGED 3/3 (25 s each) |
| A3 | `CONFIG_KSU_DISABLE_POLICY` (in-place policydb edit, `policy_rwlock` write path) | WEDGED 2/3 (24, 24 s; 1 inconclusive) |
| A4 | `CONFIG_KSU_DISABLE_MANAGER` (throne tracker) | **unusable -- does not boot**, hangs at the boot animation with zygote up and system_server never completing |
| A5 | intended to cut `selinux_hide` -- **INVALID, it did not**: `ksu_selinux_hide_init()` has 4 call sites and A5 skipped only one | WEDGED 2/3 (24, 25 s) |
| A6 | the LSM `task_fix_setuid` path (`track_throne`, manager-fd install, seccomp relaxation, module umount) | WEDGED 2/3 (23, 23 s) |
| A7 | all eight KSU modules disabled (KSU's own per-module `disable` marker) | WEDGED 2/2 (28, 28 s) |
| A8 | core_ctl isolation: Gold cluster pinned online, `core_ctl/enable=0` | WEDGED 3/3 (21, 20, 21 s) |

A5 is weaker than it looks and must not be read as "the hooks are cleared":
`ksu_sucompat_init()`, `ksu_setuid_hook_init()` and `ksu_avc_spoof_init()` only
call `ksu_register_feature_handler()`. The handlers themselves are invoked
directly from our manual hook call-sites, so skipping init left every hot path
live. A5 legitimately clears only `selinux_hide`, which is the one that does
real work in its init (the kthread that patches the selinuxfs fops table).

A8 was first run once and survived 150 s, and that single survival was wrong --
three proper trials all wedged. One survival proves nothing here; only a crash
is evidence.

## The lockup itself

Captured live 2026-09-04 on stage A, streaming `dmesg` over adb with
`softlockup_all_cpu_backtrace=1` and `watchdog_thresh=5`:

```
NMI watchdog: BUG: soft lockup - CPU#0 stuck for 11s! [kworker/u16:15:2048]
CPU: 0 PID: 2048 Comm: kworker/u16:15
Workqueue: devfreq_wq devfreq_monitor
PC is at smp_call_function_single+0xe0/0x1a8
  x22: 0000000000000005                     <- target cpu
msm_watchdog: Watchdog bark! ... cpu alive mask from last pet 0f
Causing a watchdog bite!
Watchdog detected hard LOCKUP on cpu 5
```

CPU 0 is a victim, not the culprit: it blocks forever in
`smp_call_function_single()` on a cross-call to CPU 5. **CPU 5, a Gold core, has
stopped taking interrupts** -- a hard lockup with IRQs disabled. That is why the
soft-lockup detector never fires for the actual culprit (it needs the timer
interrupt) and why this has always presented as a silent reboot: no CPU can
print the guilty stack, and `AppsWdogBark` follows once the watchdog's pet work
stops running.

The ring buffer carries no KernelSU lines -- release builds strip KSU's
`pr_info` -- so KSU's own activity is invisible in this capture.


Eliminated by reading rather than by build: the whole kprobes half of
`hook/hook_manager.c` sits under `#ifdef KSU_KPROBES_HOOK`, which a
`KSU_MANUAL_HOOK` build never compiles -- including the `tasklist_lock` walk in
`ksu_mark_running_process_locked()`. `ksu_handle_slow_avc_audit()` in
`extras.c` is an `atomic_read` plus an integer compare.

### What the wedge looks like

With all detectors running the freeze lands ~25 s in, immediately after Duck
execs `mount` as `untrusted_app`. By then the app has spawned a chain of
**isolated processes** -- the WebView sandbox (uid 99001) and
`VirtualizationIsolatedProbeService` (uid 99002) -- and the SELinux carrier has
not started yet. So the isolated-process spawn path is implicated generally,
not the SELinux carrier specifically.

### Locating the failure (probes A9-A12)

Elimination stalled at eight probes, so the kernel was made to report what the
wedged core was doing. The core answers no IPI, so an all-CPU backtrace cannot
reach it; instead a still-live CPU reads its runqueue and a per-CPU ftrace ring.

| Probe | Mechanism | Result |
| --- | --- | --- |
| A9 | `ksu_dbg_cpu_curr()` (a `cpu_rq()->curr` helper in `kernel/sched/core.c`) printed from the hardlockup detector | names the task, 3/3 identical |
| A10 | lockup detector disabled at runtime (it ships via `diag.fragment` in every profile, and registers perf events) | WEDGED 3/3 -- not the cause |
| A11 | 16-deep per-CPU ftrace ring of function entries, dumped for the wedged cpu | gives the last 16 calls |
| A12 | `thread_info->flags`, `preempt_count`, `seccomp.mode` of the wedged task | 2/2 identical |

What they show, reproducibly:

```
PROBE-A9 : cpu4 was running comm=detector_zygote pid=5035 state=0
PROBE-A12: cpu4 tif_flags=0x00000802 preempt=0x00000000 seccomp_mode=2
PROBE-A11: cpu4 last 16 function entries, newest first:
  [01] syscall_trace_exit      <- and nothing after this, ever
  [02] fput
  [03] locks_remove_posix
  [04] dnotify_flush
  [05] filp_close
  [06] _raw_spin_unlock
  [07] _raw_spin_lock
  [08] __close_fd
  [09] SyS_close
  [10..12] __bpf_prog_run x3
  [13] __seccomp_filter
  [14] __secure_computing
  [15] syscall_trace_enter
  [16] syscall_trace_exit
```

Read oldest to newest: Duck's app-zygote process runs an ordinary `close()`,
its seccomp filter passes, the syscall completes, the task enters
`syscall_trace_exit` -- and no further traceable function ever runs on that core.

`tif_flags=0x802` is `TIF_NEED_RESCHED` (bit 1) plus `TIF_SECCOMP` (bit 11).
`TIF_SECCOMP` is in `_TIF_SYSCALL_WORK`, which is why `syscall_trace_exit` is
called at all; none of `TIF_SYSCALL_TRACE/AUDIT/TRACEPOINT` are set, so the
function itself is a no-op that returns immediately. `TIF_NEED_RESCHED` is
almost certainly a *consequence*: a remote CPU called `resched_curr()` on this
task, set the flag and sent an IPI that never landed.

Two things this rules out:

- **Not a spinlock deadlock.** `preempt_count == 0`, and `spin_lock()` disables
  preemption -- the classic "hard lockup spinning on a raw spinlock" shape does
  not fit.
- **Not a `ret_to_user` work loop.** `do_notify_resume()` and `schedule()` are
  both traceable and neither appears in the ring.

So the core is stuck with IRQs disabled, preemption enabled, in code that ftrace
cannot see: the arm64 exception-return assembly, or below the kernel entirely
(firmware/EL3). Pinning that down needs CoreSight external debug or a TZ
ramdump, neither of which is currently available -- `config/cpudbg.fragment`
references `CONFIG_CAYMANSLM_CPUDBG`, for which no patch and no Kconfig exists
anywhere in the tree, so that fragment is dead and silently does nothing.

## ROOT CAUSE (found and fixed 2026-09-04)

`drivers/kernelsu/feature/selinux_hide.c` replaces selinuxfs's open handler for
`/sys/fs/selinux/status` so unprivileged callers get a fake status page. It
stored the wrong thing in `filp->private_data`.

selinuxfs stores and consumes a `struct page *` (security/selinux/selinuxfs.c):

```c
filp->private_data = status;                     /* struct page * */
...
remap_pfn_range(vma, vma->vm_start, page_to_pfn(status), size, vma->vm_page_prot);
...
simple_read_from_buffer(buf, count, ppos, page_address(status), ...);
```

KSU stored a kernel virtual address instead:

```c
filp->private_data = page_address(data);         /* WRONG */
```

So `mmap()` of that file ran `page_to_pfn()` on a virtual address, produced a
nonsense PFN, and `remap_pfn_range()` mapped it into userspace. Mapping a PFN
that is not valid RAM surfaces on arm64 as an imprecise external abort with
interrupts masked: the core stops taking the timer interrupt and answers no
IPI. That is why nothing could ever print the guilty stack, and why the only
visible symptom was `AppsWdogBark` once the watchdog's pet work starved.

The gate is `TIF_SECCOMP && uid >= 10000`, i.e. any app -- Duck's app zygote
(`detector_zygote`) hits it on every launch, which is why the wedged task was
always that process and never anything else.

Fix: `patches/kernelsu/zzzzzzzzzzz5-ksu-selinux-hide-status-page-type.patch`
stores the `struct page *`. One line. The feature is unaffected -- the fake
page is still handed out, so hiding still works.

| Kernel | Result |
| --- | --- |
| KSU only, unmodified | WEDGED 3/3 (24, 25, 25 s) |
| KSU only, `selinux_hide` disabled at all 4 call sites | SURVIVED 3/3 (259, 258, 258 s) |
| KSU only, the fix, hiding enabled | SURVIVED 3/3 (258, 259, 258 s) |
| **full release stack + fix** (KSU + SuSFS + SUS_MOUNT + NoMount) | **SURVIVED 5/5** (258, 258, 258, 259, 259 s) |

Every survival carries `carrier_spawns=4`, the same as the no-root-stack
control, so the trigger demonstrably fired.

### Why eleven earlier probes all missed it

Probe A5 was believed to clear `selinux_hide` and did not.
`ksu_selinux_hide_init()` has **four** call sites; A5 only skipped the one in
`ksu_syscall_hook_manager_init()`, while `core/init.c` calls it directly twice
more. The feature stayed live for the whole of A5, so the real culprit sat in
the "eliminated" pile while the search moved on. Any probe that disables a
subsystem must assert the subsystem is actually off, not assume one call site
is the only one.

The other reason it resisted elimination: it is not reachable through any
runtime feature flag. Disabling module unmount, sucompat, app profiles, the
LSM hooks, the modules themselves and core_ctl all left it running.

### Discarded pass

An earlier pass through these stages was discarded: it ran with Duck
`test/no-appzygote` installed, i.e. the build with the trigger deliberately
removed, so every "survived" in it was meaningless. Nothing from it is recorded
here. The `carrier_spawns` positive control in `duck-wedge-trial.sh` exists to
make that failure mode impossible to repeat -- a run that does not prove the
trigger fired is reported INCONCLUSIVE, never SURVIVED.

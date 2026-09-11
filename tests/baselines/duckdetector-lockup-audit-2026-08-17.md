# Duck Detector kernel lockup — deep root-cause audit & diagnostic plan
**Date:** 2026-08-17 · **Kernel:** caymanslm 4.9.337 KSU-Next legacy · **Status:** root cause narrowed to KSU-core, exact faulting loop not yet captured.

This supersedes the earlier "all-CPU SELinux deadlock" and "SELinux BUG()/policy-corruption"
write-ups, both disproven. See [[duckdetector-kernel-panic-capture]] history for the dead theories.

---

## 1. Confirmed failure signature (hard on-device evidence)

Captured live via `logcat -b kernel` (survives where `/proc/kmsg`-over-USB gets starved at reset):

| Fact | Evidence |
|---|---|
| **Single-CPU lockup on CPU4**, not an all-core freeze | RCU stall: `rcu_preempt detected stalls … 4-… .D (detected by N)`; userspace (MediaProvider, GC, TEESimulator) keeps logging ~15–23 s through the hang |
| Stuck task = Duck's **`detector_zygote`** (untrusted_app), state **R (running)**, never yields | `Task dump for CPU 4: detector_zygote R running task` |
| **CPU4 has interrupts disabled** | It answers **no** IPI: watchdog ping (`alive mask 0f`), RCU-stall backtrace (only stale `__switch_to → null`), and `sysrq l` (only cpu0/1 dumped) all fail to reach it |
| It is an **infinite loop**, not slow work | Reproduces every time; consistent hang→bark timing; hard reset |
| Terminal event = **watchdog bark → bite → PS_HOLD** cold reset | `msm_watchdog: Watchdog bark! … Causing a watchdog bite!`; PMIC power-off reason = `PS_HOLD` (SW-requested), `PON=HARD_RESET` |
| Amplifier = **`rcupdate.rcu_expedited=1`** (kernel cmdline) | One non-quiescent CPU stalls every system-wide `synchronize_rcu`; unrelated tasks (`put_mnt_ns→drop_collected_mounts→synchronize_rcu`, `pfkey_release→synchronize_rcu`) pile up in D-state behind CPU4 |
| **Enforcing-only** | `setenforce 0` avoids it (long-standing, re-validated) |
| Trigger = Duck's **`service_manager { find }` denial flood** + a raw **`openat2` (syscall 437)** probe that seccomp-kills | avc denials for `untrusted_app` → `lineage*_service` etc.; tombstone `SYS_SECCOMP … system call 437` |

**Not** a panic (PS_HOLD, not KernelCrash magic), **not** policy-struct corruption (see §2),
**not** an all-CPU deadlock (that was a `/proc/kmsg`-starvation artifact).

---

## 2. Definitively ruled out (with evidence)

- **NoMount** — KSU-only build (`CONFIG_NOMOUNT` off) still crashes, identical signature.
- **SuSFS** — same build (`CONFIG_KSU_SUSFS` off) still crashes; `/sys/fs/susfs` absent, uname unspoofed.
- **All 8 modules** (ReZygisk, tricky_store, specter, playintegrityfix, zygisk_vector, treat_wheel,
  susfs4ksu, nomount) — disabled via `*/disable`, no `zygiskd` in log, still crashes.
- **Base LineageOS 4.9.337** — `bisect-noksu` survives (historical).
- **SELinux policydb structural corruption** — live policy dumped from `/sys/fs/selinux/policy`,
  validated with libsepol 3.5: strict parse OK, `primary+attrib == nprim`, 0 out-of-range type
  values, 0 NULL slots. (Caveat: the *serialized* image is validated; some **derived in-kernel**
  structures are not — see §4-B.)
- **Every SELinux `BUG()`** in the compute/denial path — all hardened to fail-closed in the past
  with **zero effect** → it is a *loop*, not an assertion.
- **KSU per-syscall hooks for Duck's context** — audited, all early-out for an untrusted_app:
  - `sucompat` faccessat/stat/execve/execveat → early `return 0` on `!ksu_is_allow_uid_for_current` (Duck not allowed).
  - `ksu_handle_vfs_read` → `is_init_rc()` early-outs on `comm != "init"`.
  - `ksu_handle_umount` → early `return 0` on `!ksu_module_mounted` (no modules mounted in the KSU-only test).
  - `disable_seccomp` / `ksu_seccomp_allow_cache` → only run for manager/allowed uids (and cache is `#if >= 5.10`, dead on 4.9).
  - `hook_manager.c` sys_enter tracepoint path → entire file is `#ifdef KSU_KPROBES_HOOK`, **compiled out** under `CONFIG_KSU_MANUAL_HOOK`.
  - `track_throne(false)` → gated on `!ksu_is_manager_appid_valid()`; first run synchronous but I/O-bound (would be **D**, not R); later runs deferred to a kworker.

**Net:** the difference between KSU-only and base is **not a per-syscall hook** — it is KSU's
**global runtime change to SELinux**: `apply_kernelsu_rules()` mutates the live policydb at boot
(`add_type`/`add_typeattribute`/`ksu_allow` → grows `type_attr_map_array`, `te_avtab`, sidtab),
then `reset_avc_cache()` (`avc_ss_reset`). Duck's denial flood is what then exercises the mutated state.

---

## 3. The constraints the evidence forces

Any correct hypothesis must satisfy **all** of:
1. Runs in **`detector_zygote`** (untrusted_app) context — reached from a normal app syscall/fault.
2. **Interrupts disabled** while spinning → a `spin_lock_irqsave`/`raw_spin_lock_irqsave` spin, or an explicit `local_irq_disable` loop. **Excludes** `read_lock(&policy_rwlock)` in `context_struct_compute_av` (leaves IRQs on).
3. **Infinite** (not slow) → a **cyclic linked structure** (hlist/list/hash chain with a self/loop link) walked under that IRQ-off lock, **or** an unbounded retry.
4. Only in **enforcing** and only after **Duck's denial flood** → the structure is in the SELinux **access-decision / denial** hot path.
5. Present with **bare KSU core** → the structure is one that KSU's `apply_kernelsu_rules()` /
   `avc_ss_reset()` touches or invalidates; **not** caught by libsepol validation of the serialized policy.

The intersection of (2)+(4) is small: the **IRQ-off spinlocked hash structures on the denial path**
are the **AVC cache** and the **sidtab**. That is where the audit points hardest.

---

## 4. Candidate root causes (ranked)

### A. AVC-cache slot hlist cycle — IRQ-off spin  ★ leading
- **Where:** `security/selinux/avc.c` — `avc_insert()` / `avc_update()` / `avc_reclaim_node()` /
  `avc_flush()` all take `spin_lock_irqsave(&avc_cache.slots_lock[h])` and walk
  `hlist_for_each_entry(node, head, list)`. A cyclic slot chain → infinite loop with IRQs off.
- **Fits:** IRQ-off ✔; infinite ✔; denial hot path (every grant/deny inserts/searches) ✔; enforcing ✔.
- **Against:** avc.c is *stock* in the KSU-only build (SuSFS spoof in `avc_dump_query` is `#ifdef`-out);
  stock avc insert/reclaim are serialized, so a cycle needs a trigger — plausibly `avc_ss_reset()` /
  `avc_flush()` racing the denial flood right after KSU's boot-time `reset_avc_cache()`, or an
  `avc_node` reuse bug exposed by the mutated `av_decision` KSU's rules produce.
- **Discriminator:** bounded-iteration guard on the avc hlist walks (see §5-T4) will name it directly.

### B. `type_attr_map_array` / `te_avtab` cycle from `add_type` — compute_av loop
- **Where:** `context_struct_compute_av()` (services.c:705–719): `sattr/tattr =
  flex_array_get(policydb.type_attr_map_array, type-1)`, nested
  `ebitmap_for_each_positive_bit(sattr) × (tattr)` × `avtab_search_node_next()` chain walk.
  KSU's `add_type()` (sepolicy.c) `flex_array_alloc`-grows `type_attr_map_array` and inserts into
  `te_avtab`; a stale/cyclic ebitmap node or avtab chain → infinite loop.
- **Fits:** denial-triggered ✔; KSU-only ✔; **invisible to libsepol** ✔ (`type_attr_map_array` is a
  *derived* runtime structure, not in the serialized image, so §2's validation can't see it).
- **Against:** this path holds `read_lock(&policy_rwlock)` — **IRQs on** — which conflicts with the
  CPU4-IRQ-off evidence, *unless* compute_av is entered from within an already-irqsave section
  (it normally is not). **Demoted below A for that reason**, but not eliminated (the IRQ-off
  inference rests on IPI non-response, which is strong but indirect).

### C. sidtab hash-chain cycle — IRQ-off spin
- **Where:** `sidtab_search`/`sidtab_context_to_sid` under the sidtab spinlock, walked on denials to
  map sid↔context. KSU inserts new SIDs (ksu domain) at boot. A corrupted chain → IRQ-off loop.
- **Fits:** IRQ-off ✔; denial path ✔; KSU touches sidtab ✔. **Against:** less code churn than avc; needs a concrete corruption path.

### D. Non-SELinux: page-fault / mmap retry livelock in `detector_zygote`
- **Where:** the (unreliable) remote unwind showed `do_mmap/mmap_region+0x2ec` after
  `perf_event_mmap`; the openat2-kill tombstone showed `ext4_filemap_fault`.
- **Fits:** R-running task ✔. **Against:** does not explain IRQ-off, enforcing-only, or KSU-only;
  mm/mmap.c is stock and KSU touches no VMA/fault code. Treat the mmap_region frame as a **stale
  snapshot** of a remote running task, not the real PC. **Low.**

### E. KSU `add_type` publish-order / nprim inconsistency (residual)
- A known-fragile area (`zzzzzzzzzzz2-ksu-add-type-publish-order.patch`). If any realloc/grow leaves
  an existing `type_attr_map_array[]` ebitmap pointing at freed/stale nodes, feeds B. Audit the
  flex_array grow path for content preservation across `flex_array_alloc` of the new (n+1)-sized array.

---

## 5. Diagnostic test matrix (ranked by decisiveness × cost)

| # | Test | Distinguishes | Cost | How |
|---|---|---|---|---|
| **T1** | **Bounded-loop instrument + WARN** on the IRQ-off SELinux loops (avc hlist walks, sidtab chain, avtab_search_node_next, ebitmap iteration): after N≫max iterations, `break` + `WARN_ONCE`+`dump_stack()` to the log buffer | **Names the exact loop** AND breaks the infinite loop (diagnostic *and* mitigation). The stuck CPU prints from its own context, so it works even with IRQs off (goes to the ring buffer, read post-reboot or via logcat pre-bite) | 1 build | Add a counter to each suspect `for/while`/`hlist_for_each_entry`; the loop that trips is the culprit. **Highest value — do first.** |
| **T2** | `rcupdate.rcu_expedited=0` boot arg | Whether the reset is the CPU4 hang itself vs the expedited-GP amplification | 1 boot | Append to cmdline; likely still resets (watchdog pet also can't reach CPU4), but cheap and informative |
| **T3** | **EDL / TZ-SDI RAM dump** at the bite | Ground-truth CPU4 PC + full backtrace of every core | high | Enable download-mode-on-crash, Firehose-read DDR, offline parse SDI CPU contexts. Definitive but heavy tooling |
| **T4** | Rebuild with **`CONFIG_STACKTRACE=y`**, then `cat /proc/<detector_zygote_pid>/stack` from a 2nd adb shell during the hang | Real kernel stack of the stuck task (reads task stack memory directly; no IPI needed) | 1 build | Loop `for p in detector*; do cat /proc/$p/stack; done` during the ~20 s window |
| **T5** | **NMI/pseudo-NMI backtrace on watchdog bark** — patch `wdog_bark_handler` to `trigger_cpumask_backtrace()` (or enable arm64 pseudo-NMI) before the bite | CPU4 real stack, if a true NMI can preempt an IRQ-off spin | 1 build | arm64 4.9 "NMI" backtrace is a plain IPI (won't reach an IRQ-off CPU) unless pseudo-NMI (GICv3) is enabled — check `CONFIG_ARM64_PSEUDO_NMI` feasibility |
| **T6** | **Selective bisect of `apply_kernelsu_rules()`** — stub the rule groups one at a time (types only / typeattributes / the broad `ksu_allow(domain, …)` / avtab bulk) | Which mutation introduces the bad state | N builds | Rebuild KSU-only variants; re-run Duck |
| **T7** | **Persistent ftrace** function tracer, filtered to `avc_*`, `sidtab_*`, `avtab_*`, `context_struct_compute_av` | Which function CPU4 repeats | 1 boot | `echo function > current_tracer`; small filter; the last-repeated fn on cpu4 in the trace ring (read pre-bite via `trace_pipe` streamed over adb) |
| **T8** | **Live AVC-cache integrity probe** — walk `avc_cache.slots[*]` with a hop limit from a debugfs/su tool while Duck runs | Confirms/denies an AVC slot cycle directly | 1 build | Add a read-only `/proc/ksu_avc_check` that reports any slot chain exceeding a hop bound |
| **T9** | Re-confirm `setenforce 0` avoids it **on the KSU-only kernel** | Locks the SELinux-enforcing dependency to the minimal config | 0 (runtime) | already strongly indicated; cheap to reconfirm |

---

## 5b. T1 RESULT (2026-08-17) — SELinux decision path EXONERATED

Built the T1 instrumented KSU-only kernel (`tests/baselines/t1-loopguard-DIAGNOSTIC.patch`)
with bounded-iteration `WARN_ONCE`+break guards on **11** loop sites and ran Duck three times
(three build/flash cycles). **No guard ever tripped**, and the crash reproduced identically
(`detector_zygote R running task` on CPU4, RCU-expedited stall, watchdog bite):

- AVC cache: `avc_insert`, `avc_change`, `avc_reclaim_node`, `avc_flush`, `avc_search_node`
- sidtab: `sidtab_search_core`
- avtab: `avtab_search_node_next`
- compute_av: both `ebitmap_for_each_positive_bit` loops (sattr, tattr)
- constraints: `constraint_expr_eval` expr walk, the compute_av constraint list, `bounded_transition` bounds walk

**Conclusion: the infinite loop is NOT in the SELinux access-decision / constraint / bounds
path.** This directly refutes candidates **A, B, C** and the long-standing "spinning in
`context_struct_compute_av` under `policy_rwlock`" hypothesis from the prior investigation.
The instrumentation is kept as defensive hardening (an app-reachable runaway SELinux chain
should fail-closed, not lock the CPU) but it is **not** the fix.

**What this forces:** the IRQ-off spin is either (a) in a NON-SELinux `*_irqsave` path that
Duck reaches (the "enforcing-only" correlation may be Duck's *behaviour* — it likely checks
`getenforce` and only runs the fatal probe when enforcing — not SELinux *code* looping), or
(b) a cross-syscall/fault **retry livelock** (no single guardable loop; e.g. a fault handler
that keeps returning without progress). Guessing loops has reached diminishing returns.

**Next = ground-truth backtrace, not more guards.** The stuck task hard-monopolises CPU4 with
IRQs off, so IPI-based dumps (`sysrq l`, RCU-stall backtrace) and `/proc/pid/stack` (task is
R/running) cannot reach it. The definitive method is **T3 — EDL / TZ-SDI RAM dump** at the
watchdog bite (captures every core's exact register/PC context). Secondary: build with arm64
**pseudo-NMI** (`CONFIG_ARM64_PSEUDO_NMI`, if the 4.9 tree supports it) so the stall/sysrq
backtrace can preempt an IRQ-off CPU. Once the real PC is known, fix that specific site.

## 5c. T1d RESULT (2026-08-17) — mm + perf path EXONERATED too

Followed the `mmap_region`-after-`perf_event_mmap` hint with 5 more guards (patch now 16 sites):
`find_vma_links` rbtree walk, both `vm_unmapped_area` gap-finder `while(true)` loops
(bottomup + topdown — the classic corrupted-augmented-rbtree mmap hang), and the
`perf_iterate_ctx` / `perf_iterate_sb_cpu` event-list walks (`perf_event_mmap`'s callees).
Ran Duck → **no guard tripped**, identical CPU4 stall. So the loop is **not** in the mm
mmap/rbtree/gap path or perf side-band iteration either. **The `mmap_region+0x2ec` frame was a
stale remote-CPU snapshot, confirmed a red herring.**

**Cumulative: 16 guarded loops across SELinux, mm, and perf — none is the culprit.** The cheap
loop-instrumentation approach is now exhausted for the obvious subsystems. The most likely
remaining explanations are (a) an unguarded software loop in a subsystem not yet touched (large
search space), or (b) a **hardware/firmware hang** — e.g. Duck pokes a device (sysfs/ioctl)
whose driver does an MMIO register read that never returns, or an SMC to TZ that hangs; these
present exactly as "R running task, CPU IRQ-off, never yields" and are **un-guardable by loop
counters**. Both require the literal PC.

**Two ways to get the PC:**
- **T7 (software, one rebuild): `CONFIG_FUNCTION_TRACER=y`** (release/ksuonly currently sets it
  OFF). Enable the function tracer, stream `trace_pipe` over adb, reproduce; the last function
  repeatedly recorded on CPU4 before the lockup names the culprit — **works even for a hardware
  hang** (it names the driver function that issued the stuck MMIO/SMC).
- **T3 (definitive): EDL / TZ-SDI RAM dump** at the watchdog bite — every core's exact register
  context. Heaviest, but unambiguous.

## 6. Recommended sequence

1. **T1 (bounded-loop instrument + WARN)** — one build. It both identifies the exact loop and, by
   `break`-ing out, likely stops the reset (turning a hard lockup into a logged warning). This is the
   single highest-value step: diagnosis and candidate fix in one.
2. In parallel/first-boot: **T2** (`rcu_expedited=0`) and **T9** (`setenforce 0` on KSU-only) — free/cheap confirmations.
3. If T1's WARN fires in an **avc/sidtab** loop → hypothesis **A/C** confirmed; the fix is to
   correct the corruption source (most likely KSU's boot-time `avc_ss_reset()` / rule-apply racing
   the first denials) and keep the bound as defence-in-depth.
4. If T1 does **not** fire (loop is elsewhere) → **T4** (`/proc/pid/stack` with `CONFIG_STACKTRACE`)
   or **T3** (EDL ramdump) for the literal PC, then **T6** to bisect `apply_kernelsu_rules()`.

### Capture procedure that works (for any of the above)
- **Flash** the kernel (RAM-boot is one-shot, gone after the reset). Each boot set:
  `echo 6 > /sys/module/rcupdate/parameters/rcu_cpu_stall_timeout`, `panic_on_rcu_stall=0`,
  `kptr_restrict=0`, `printk=8`. Stream **`logcat -b kernel -v threadtime`** (NOT `/proc/kmsg`).
  Launch Duck via `monkey -p com.eltavine.duckdetector -c android.intent.category.LAUNCHER 1`.
- Built vmlinux for symbol resolution: `~/caymanslm-kernel/susfs-v2-replay/build/vmlinux`
  (`llvm-objdump` from clang-r450784e). `mmap_region+0x2ec` = `ldr` after `bl perf_event_mmap` (stale, ignore).

## §7 — 2026-08-17 evening: the ftrace blocker, and what the stuck CPU is NOT

### 7a. The function tracer was never broken; a stale reader was holding it
Every earlier `echo function > current_tracer` failed with `EBUSY`, which was
blamed on LTO. Both halves of that were wrong:

* `CONFIG_LTO_NONE=y` in this build — **LTO was never enabled** (the `+lto` in the
  banner is the *toolchain's* build, not ours).
* `tracing_set_tracer()` returns `-EBUSY` from exactly one place: *"If trace pipe
  files are being read, we can't change the tracer"* (`tr->current_trace->ref`).
  The holder is **Android's `system_server`, which keeps
  `instances/bootreceiver/trace_pipe` open for its kernel-error monitor**. `ref`
  lives on the *global* `nop_trace` struct, so that single fd blocks changing the
  tracer in **every** instance — which is why per-instance workarounds also failed.
  Fix: kill the holder (framework restarts), then set the tracer. Wait for
  `cmd package resolve-activity` to answer again before launching anything.

### 7b. Reading `trace` during the hang is IMPOSSIBLE — use `trace_pipe`
`per_cpu/cpuN/trace` goes through the ring-buffer *iterator*, whose open path
calls `synchronize_sched()`. With one CPU stuck non-quiescent (and
`rcu_expedited=1`) that can never return, so the dump hangs forever. This, not
slow I/O, is what silently defeated every on-device dump attempt. `trace_pipe`
(consuming reader) has no such dependency and keeps working.

### 7c. `trace_pipe` streaming is lossy here — do not trust its tail
Full-rate CPU-only function tracing is ~9 MB/s. A 126 MB capture carried **9179
`LOST EVENTS` markers, the last only 288 lines before EOF** — the reader never
caught up, so the final records are NOT the last thing the CPU did. A tail that
looks like a smoking gun (we saw `mmap_region → sel_mmap_handle_status →
remap_pfn_range`, then `SyS_close`) is unreliable evidence.

### 7d. DECISIVE: the stuck CPU executes no traced function at all
Built with `CONFIG_FUNCTION_PROFILER=y` (per-CPU hit counters; needs no
`synchronize_sched()`, so unlike `trace` it is readable *during* the hang — and
after one `chmod -R 777 /sys/kernel/tracing` it is readable **without `su`**,
which matters because `su` itself is unreliable on the degraded system).
Snapshots of `trace_stat/function4` at t+5s, t+8s and t+11s were **byte-identical**:
the stuck CPU's counters are frozen. Top entry on that CPU was `do_raw_spin_lock`.

=> The spin is a tight loop making **no function calls**, i.e. inside a single
function (or in inlined/`notrace` code).

### 7e. It is NOT a spinlock and NOT an rwlock
4.9 deleted the pre-4.9 bounded-spin diagnostic (`__spin_lock_debug`), leaving a
comment that it "relies on the NMI watchdog" — useless here, since the stuck CPU
has IRQs off and answers no IPI/NMI, and the QCOM watchdog only cold-resets.
Restored it for **all three** paths — `do_raw_spin_lock`, `do_raw_read_lock`,
`do_raw_write_lock` — reporting lock symbol, `.owner`, `.owner_cpu` and
`dump_stack()` **from the spinning CPU itself** after ~1s. Note `spin_dump()`
could not be reused: it calls `msm_trigger_wdog_bite()` *before* `dump_stack()`
when `CONFIG_DEBUG_SPINLOCK_BITE_ON_BUG=y` (default y, and `olddefconfig` keeps
re-enabling it, so it cannot be turned off from a fragment) — it would reset the
device one line short of the backtrace. Printed the same fields directly instead.

Result: Duck reproduced the lockup and **no lock report fired at all**. Combined
with 7d, the spin is in neither a spinlock nor an rwlock acquisition.

### 7f. Refined signature
`rcu_preempt detected stalls`, **one CPU only** (CPU4 or CPU5 — it varies by run,
so earlier "always CPU4" was coincidence), naming `detector_zygote`, with
**`(0 ticks this GP)`** — the stuck CPU takes zero timer interrupts. Not
`stop_machine` (that would stall every CPU). The stuck thread's own syscall trace
ends with a **completed** `close()`; its loop is `openat → mmap(PROT_READ,
MAP_SHARED, 4096) → close`, and it enters no further syscall.

So: single CPU, IRQs off, state R, no syscall, no traced call, no lock spin.
`/proc/<pid>/maps` + fd snapshots through the hang show nothing exotic (ion,
ashmem, properties — all normal Android). The remaining shapes are (a) a tight
loop in one uninstrumented function, or (b) the CPU stalled in the memory system
on a device/PFN mapping, which executes no code and is invisible to every
software probe — only a ramdump can see (b).

### 7g. OPEN: the "it's in KSU code" premise is resting on a stale test
The KSU-dependence claim comes from `bisect-noksu` **surviving Duck** — but that
run predates the current signature (it was done against the old instant-panic
behaviour). It is being re-run now. Caveat either way: with KSU absent Duck finds
no root and may simply not escalate its probe, so "no crash without KSU" would
NOT by itself prove the bug is in KSU code.

## §8 — the first RELIABLE capture, and what it says

### 8a. Survival: `watchdog_v2.skip_cpu_ping=1` buys ~50s instead of ~12s
`ping_other_cpus()` sends a **synchronous** `smp_call_function_single(..., wait=1)`
to every CPU; the wedged CPU never acks, so the watchdog kthread never reaches
`pet_watchdog()` and the SoC bark/bites. Skipping the ping (new module param,
diagnostic only) extends survival from ~12 s to **~50 s** — five RCU stall
reports, 12 s apart, before it finally died anyway. NOT indefinite survival, so
the reset is only *partly* explained by the ping; something else still finishes
the box off. But 50 s is enough to work in.

### 8b. The capture method that finally works
1. `watchdog_v2.skip_cpu_ping=1` for the wider window.
2. Arm `current_tracer=function`, `tracing_cpumask=f0` (big cores; the wedged CPU
   is always one of 4-7 and *varies* between runs), `buffer_size_kb=4096`.
3. Launch Duck; poll the streamed `logcat -b kernel` **host-side** for
   `detected stalls`; on match immediately `echo 0 > tracing_on` — **freeze**.
4. Then drain `per_cpu/cpuN/trace_pipe` (NOT `trace`, which deadlocks in
   `synchronize_sched()`). A frozen buffer drains with no time pressure and no
   loss: **149,083 lines, 1 LOST marker**. Compare §7c's 9179 LOST markers — this
   is the first tail that can be trusted.

### 8c. What the wedged CPU actually last did (reliable)
Duck's loop, thousands of times, is:
```
openat("/sys/fs/selinux/status", O_RDONLY|O_CLOEXEC)
mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0)   -> sel_mmap_handle_status
                                                 ->   remap_pfn_range
close(fd)
```
and the final records are:
```
SyS_mmap_pgoff ... mmap_region -> sel_mmap_handle_status -> remap_pfn_range
  -> vma_link -> ... -> fput -> syscall_trace_exit
syscall_trace_enter -> __secure_computing -> __seccomp_filter -> __bpf_prog_run x3
SyS_close -> __close_fd -> filp_close -> fput -> syscall_trace_exit
<nothing, ever>
```
So it confirms the §7c lead that had to be withdrawn as unreliable — this time on
a clean buffer. Note the thread is on the **seccomp slow syscall path**
(`syscall_trace_enter`/`syscall_trace_exit` on every call), and it stops
immediately after `syscall_trace_exit`, i.e. somewhere in the **untraced arm64
`__sys_trace_return`/`ret_to_user`/`kernel_exit` assembly**, which runs with IRQs
masked. That matches every negative result: no traced function, no lock, no
syscall, 0 ticks, no IPI response.

RCU's `idle=2d7/...` matters: `dynticks_snap & 0xfff = 0x2d7` is **odd**, so RCU
believes the CPU is **in the kernel**, not in userspace. It is not a userspace
spin.

### 8d. Minimal reproducer: NOT yet reproducing (scratchpad/hammer.c)
Freestanding aarch64 binary (raw `svc #0`, no libc, so no sysroot needed):
`clang --target=aarch64-linux-gnu -nostdlib -static`. Replays 8c's loop exactly,
optionally installing a trivial allow-all seccomp filter to force the same slow
syscall path. Results on the full-stack kernel:
* 2000x plain `read()` of the status file, shell user — **survives**
* 400,000x openat+mmap+touch+munmap, shell user — **survives**
* same + seccomp slow path — **survives**

So the loop alone is not sufficient. Remaining deltas vs Duck, in likely order:
its SELinux **domain** (`untrusted_app`, not `shell` — and the bug is
enforcing-only), KSU's per-app umount/hiding work that runs for an untrusted app,
and Duck's concurrent multi-threaded probing. Next step is to run the same loop
**from an app in `untrusted_app`**, not from adb.

(Watch for a trap in the reproducer: a failure test of `addr > -4096L` is true for
every valid mapping and silently rejects success on iteration 1 — compare as
unsigned against `(unsigned long)-4095`.)

## §9 — 2026-08-18: the wedge is LOCALIZED to a single instruction

### 9a. Phase A: KPTI and SSBD eliminated
`kpti=off ssbd=force-off`, verified in the boot log
(`kernel page table isolation forced OFF by command line option`) -> still wedges.
The KPTI trampoline and the SSBD `smc` in the entry/exit path are both out.

### 9b. Breadcrumbs (CONFIG_CAYMANSLM_BREADCRUMB)
Per-CPU stamps at each step of the arm64 return-to-user assembly, read live from
`/proc/caymanslm_bc` while the CPU is wedged (possible only because
`watchdog_v2.skip_cpu_ping=1` keeps the box alive -- it survived **34 minutes**
with a dead CPU4, 144 stall reports, adb serving throughout).

Two traps, both of which would have produced WRONG answers:
* **id 4 is the last stamp before userspace, so every healthy CPU also reads 4.**
  The value therefore carries a **sequence counter** (`seq<<8 | id`); the wedged
  CPU is the one whose seq stops advancing. Without it, cpu1 sitting at id=1 in
  two consecutive samples looked frozen but was simply sampled mid-path.
* **Idle CPUs also freeze.** Every conclusion is cross-referenced against the CPU
  the RCU stall actually names.

### 9c. Result
The RCU-named CPU is always frozen at **id=4 = "about to restore regs + eret"**,
and:
* `elr` = a **valid user address**, `spsr` = EL0t with DAIF clear (IRQs would be
  enabled on return), `sp` = a **valid kernel stack** (`0xfffffff9...`).
  => **pt_regs is NOT corrupted.**
* **BC5 (kernel_entry) never stamps** on the wedged CPU, while healthy CPUs stamp
  it constantly. => it never re-enters the kernel, so it is **not a fault storm**,
  and it is not running in userspace either (a timer tick would have stamped BC5).
* Still wedges with cpufreq pinned to `performance` at max => **not DVFS**.

### 9d. THE FINDING: it is always the same instruction
The wedge `elr` across four independent captures:
`0x791174cdc8`, `0x7e4dfb3dc8`, `0x74fdbb1dc8`, `0x7d039b7dc8` -- all end in
**`dc8`**: the same page offset, differing only by ASLR. Resolved against the live
`/proc/<pid>/maps` -> `/apex/com.android.runtime/lib64/bionic/libc.so + 0x9bdc8`
(r-xp segment, file offset `0x4b000` + `0x9bdc8` = `0xe6dc8`), and `llvm-nm` gives
`__close` at `0xe6dc0`. So the address is **`__close + 0x8`, the instruction
immediately after `svc #0`**.

**The CPU wedges on the `eret` returning from `close()`**, stalling on the
instruction fetch at `__close+8`. This matches the ftrace capture exactly (last
kernel activity `SyS_close -> syscall_trace_exit`). Duck's loop is:
`openat("/sys/fs/selinux/status") -> mmap(PROT_READ,MAP_SHARED,4096)
 -> sel_mmap_handle_status -> remap_pfn_range -> close(fd) -> WEDGE`.

### 9e. Two failed attempts to test the mmap path (both inconclusive)
`remap_pfn_range()` is the only thing on that path that edits the process page
tables, so it was the natural suspect. Both ways of testing it failed:
* returning `-EINVAL` from `sel_mmap_handle_status()` -> **the device does not
  boot**. Something in early userspace hard-depends on that mapping; the earlier
  claim that "libselinux falls back to read() so nothing breaks" is **WRONG**.
* `vm_insert_page()` instead of `remap_pfn_range()` -> boots (kernel #21), but the
  device **reset with zero RCU stalls**, i.e. a different failure (likely a panic
  on that path), so it neither confirms nor clears the hypothesis.
Both are left gated behind `CONFIG_CAYMANSLM_NO_STATUS_MMAP` (default n, disabled
in the fragment). **The mmap path is NOT yet confirmed causal.**

### 9f. Where a fix has to come from next
The stall is an instruction fetch from libc's own r-x page with entirely valid CPU
state, which no longer looks like a software bug in that window. Remaining
avenues, in order: (a) inspect the process page tables / TLB state for that user
address while wedged, (b) test whether the wedge survives if Duck never gets the
status mapping (needs a way to deny it per-domain rather than globally, since a
global deny breaks boot), (c) EDL/TZ-SDI ramdump for the CPU's actual state.

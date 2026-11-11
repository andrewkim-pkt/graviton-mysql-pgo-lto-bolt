# MySQL 8.4.8 perf analysis on AWS Graviton 4: gcc 15.2.0 base vs pgolto, 256 VU

**Summary.** `pgolto` is **+19.4% NOPM** at 256 VU, and the feedback-directed signal is clean and
large: per new order it executes **20.3% fewer instructions**, takes **80.9% fewer iTLB misses** and
**41.4% fewer L1 i-cache misses**. It reaches that with **two fewer optimisation stages than the
other two legs** — there is no AutoFDO and no BOLT arm on this hardware (see the repository README,
and §5 of it for why).

**But this capture also found a measurement trap that invalidates the most obvious cross-architecture
comparison, and it is the main thing to take away from this file.** On arm64, contended lock waits
park the core in **`WFE`**, which *halts the `CPU_CYCLES` counter* while the thread still counts as
running. We calibrated it: at comparable scheduler occupancy, 192 threads on one contended mutex
accumulate **90.6 MHz** of counted cycles per core against **2.691 GHz** for 192 threads doing real
work — a factor of **29.7**. Consequently, on this leg:

* **`cycles` and `IPC` are not comparable to x86 at all.** Graviton's IPC of 0.74 against Intel's
  0.25 is *not* evidence of three times better execution efficiency. It is IPC measured over
  executing cycles only, with spin time deleted from the denominator.
* **Cycle-weighted `perf record` under-samples spin.** The 31–34% lock share in §4 is a **floor**,
  not a measurement, and must not be set against Intel's 73.9% or AMD's 82.2%, which were taken on
  PMUs where a spinning core keeps counting.
* The arithmetic in §3 implies roughly **two thirds of busy time on this box is `WFE`-halted spin**,
  i.e. Graviton is lock-bound like the other two machines, not less so.

The per-new-order **instruction, branch, i-cache, iTLB, dTLB and LLC** counts are unaffected by any
of this — those events count the same way on every architecture — and they are where the real
finding lives.

Raw reports are in [`base/`](base/) and [`pgolto/`](pgolto/). Collector script:
[`../../scripts/server/grv-myperf-srv.sh`](../../scripts/server/grv-myperf-srv.sh).

---

## 1. Setup

* **Server:** AWS **r8g.metal-48xl** — AWS Graviton 4 (ARM Neoverse V2), 192 cores, 2 sockets,
  **1 thread per core**, 2 NUMA nodes, **L2 384 MiB (2 MiB/core), L3 only 72 MiB (36 MiB/socket)**,
  1,508 GB RAM, AL2023 kernel 6.18.56-aarch64.
* **Data and load:** HammerDB 4.7 TPROC-C, 1,536 warehouses, 256 VU, driven from an r7i.24xlarge —
  the same client that drove the Intel and AMD legs.
* **Binaries:** `base` = `-O3 -march=native -mtune=native` (`mysqld` md5 `1012d2f5381c`),
  **`pgolto` = PGO + LTO** (`1f8738b920fd`). Both gcc 15.2.0; `-march=native` →
  `-mcpu=neoverse-v2+crc+sve2-aes+sve2-sha3+nossbs`.
* **Config:** the whole-box ladder config. `mysqld` unpinned over all 192 cores with
  `--innodb-numa-interleave=ON`, 200 G buffer pool, 64 G redo, datadir on tmpfs restored
  interleaved over both nodes.
* **Run order, per arm:** one server lifetime — a **warm-up run** (4 min rampup + 5 min), then the
  **measured run** (4 min rampup + 5 min). The warm-up keeps first-touch faults of a cold buffer
  pool out of the profiles.
* **Collectors:** one at a time, 30 s each, inside the measured window, anchored on HammerDB's
  "Rampup complete" (T0).

| start | collector | Intel/AMD equivalent |
|---|---|---|
| T0+15 s | `perf stat -a`, 13 events | same |
| T0+60 s | `perf record -a --call-graph fp -F 499` | `--call-graph lbr` — **no LBR here** |
| T0+105 s | `perf record -a -e arm_spe//` | VTune hotspots / `ibs_op//` |
| T0+150 s | `perf stat -a`, front-end events | same |
| T0+195 s | — | `perf c2c record -a` — **unavailable here** |

| | base | pgolto |
|---|---:|---:|
| warm-up NOPM | 507,721 | 610,376 (+20.2%) |
| measured NOPM (collectors on) | 511,033 | 610,042 (**+19.4%**) |
| new orders per second | 8,517 | 10,167 |

Three of the five Intel collectors have no counterpart on this part: there is no LBR, no
`perf c2c`, and no VTune for aarch64. §6 lists what that costs.

---

## 2. perf stat, normalised per new order

30 s system-wide. The window contains NOPM/2 new orders, so 255,516 for `base` and 305,021 for
`pgolto`. The last two columns are the published changes from the other two legs, whose optimised
arm is `pgoltob` (PGO+LTO+**BOLT**) rather than `pgolto`.

| per new order | base | pgolto | change | Intel | AMD |
|---|---:|---:|---:|---:|---:|
| instructions | 13.23 M | 10.55 M | **−20.3%** | −23% | −5.8% |
| branches | 2.758 M | 2.174 M | **−21.2%** | — | −5.8% |
| branch misses | 30.5 k | 26.0 k | −15.0% | −34% | −25.8% |
| **L1-icache misses** | **371.2 k** | **217.5 k** | **−41.4%** | −47% | −34.2% |
| **iTLB misses** | **18,528** | **3,535** | **−80.9%** | −72% | −97.0% |
| dTLB misses | 126.6 k | 94.7 k | **−25.2%** | −31% | −0.6% |
| LLC loads | 166.2 k | 128.2 k | −22.9% | — | n/a |
| LLC load misses | 50.3 k | 47.9 k | −4.8% | −15% | n/a |
| context switches | 136.9 | 120.5 | −12.0% | −19% | −3.4% |
| cpu-migrations | 6.16 | 5.23 | −15.1% | — | — |
| page-faults | 0.382 | 0.323 | −15.5% | — | — |
| *cycles (see §3)* | *17.78 M* | *15.23 M* | *−14.4%* | *−18.5%* | *−8.4%* |
| *IPC (see §3)* | *0.74* | *0.69* | — | *0.25 → 0.24* | *0.21 → 0.21* |

`ref-cycles` returns `<not supported>` on this PMU, so there is no constant-rate clock to
cross-check `cycles` against — which is part of why §3 had to be done by calibration instead.

**The layout effect is unambiguous and sits between the other two legs.** i-cache misses −41.4%
(Intel −47%, AMD −34.2%) and iTLB misses −80.9% (Intel −72%, AMD −97.0%). Unlike AMD, Graviton
converts it into throughput: **+19.4% against AMD's +7.9%, and within two points of Intel's +21.7%
despite having no BOLT stage.**

**Instructions per new order fall 20.3%** — close to Intel's 23% and nearly four times AMD's 5.8%.
This is the one headline number on this leg that needs no caveat: the counter semantics are
identical everywhere, and it says the profile genuinely restructured the code.

**The one place Graviton is worse is the LLC.** LLC loads fall 22.9% per transaction but LLC load
*misses* fall only 4.8%, so the **miss rate rises from 30.27% to 37.35%**. With just 36 MiB of L3
per socket — against AMD's 384 MiB and Intel's 480 MiB — the working set does not fit either way,
and `pgolto`'s denser code removes mostly *hits*. This is the opposite of Intel, where LLC misses
fell 15%.

---

## 3. The `WFE` problem: why `cycles` and `IPC` cannot be compared across architectures

The capture's `cycles` imply an effective clock of

```
4,544,398,280,046 / (192 cores x 30.018 s) = 0.788 GHz
```

against a 2.8 GHz nominal part that `/proc/stat` and the idle share in §4 both put at roughly
**85–89% busy**. That gap is a factor of about 2.8 and had to be explained before any cycle-derived
number could be published.

**It is not a broken counter.** Calibrated against a known full load — 192 threads, 8 s:

| 192 threads doing… | `/proc/stat` busy | counted cycles | implied per-core clock |
|---|---:|---:|---:|
| real work (tight loop) | **99.1%** | 4.165e12 | **2.691 GHz** (96% of nominal) |
| hammering **one contended mutex** | **94.3%** | 1.394e11 | **90.6 MHz** |

Same thread count, same box, near-identical scheduler occupancy, and **29.7× fewer counted
cycles.** The counter is accurate; the cores are genuinely not clocking. arm64's spin paths —
`smp_cond_load_relaxed` under `queued_spin_lock_slowpath`, and InnoDB's `ut_delay` — park the core
in **`WFE`**, which suspends `CPU_CYCLES`. On x86 the equivalent `pause` keeps the counter running.

Putting the capture on that scale: 0.788 / 2.691 = **29.3% of cycles unhalted**, at ~85–89%
scheduler-busy. **Roughly two thirds of busy time on this box is `WFE`-halted lock spin.**

What follows, and what does not:

1. **cycles/new-order −14.4% is still a valid within-arm comparison** — both arms were measured
   the same way — but it means "non-halted cycles per transaction", i.e. cycles spent actually
   executing. It is **not** total core time per transaction, and setting it against Intel's −18.5%
   is apples-to-oranges.
2. **IPC must not be compared across architectures on this workload.** 0.74 vs 0.25 and 0.21 is an
   artifact of spin time leaving Graviton's denominator and staying in x86's.
3. **Cycle-weighted sampling under-reports spin** — see §4.
4. **The correct instrument on arm64 is wall-clock sampling**, `perf record -e cpu-clock`, which is
   indifferent to whether the core is clocking. That was not in this capture's event list; it is
   scheduled into the PostgreSQL Graviton capture, which will measure the two-thirds figure
   directly rather than deriving it.

> A smaller version of the same trap: a 5 s calibration run read 1.944 GHz where the 8 s run read
> 2.691 GHz. Launching 192 background processes takes longer than the 2 s settle we allowed, so the
> short run was not yet at full load. The 8 s figure is the one used above.

---

## 4. Hotspots (`perf record --call-graph fp`, 30 s)

**Read this as a floor, for the reason in §3:** the default sampling event is `cycles`, so samples
are cycle-weighted and `WFE`-halted spin is under-represented. It still identifies *which* locks.

| base | % of counted cycles | pgolto | % of counted cycles |
|---|---:|---|---:|
| `ut_delay` (InnoDB spin-wait) | **19.87** | `rw_lock_sx_lock_func` (`ut_delay` inlined by LTO) | **24.28** |
| kernel `queued_spin_lock_slowpath` | **9.71** | kernel `queued_spin_lock_slowpath` | **9.80** |
| `swapper` `finish_task_switch` | 6.28 | `swapper` `finish_task_switch` | 6.52 |
| `swapper` `default_idle_call` | 4.56 | `swapper` `default_idle_call` | 4.70 |
| `__aarch64_ldeor8_acq_rel` | 3.20 | `__aarch64_ldeor8_acq_rel` | 3.52 |
| `__aarch64_cas4_acq_rel` | 2.16 | `__aarch64_ldadd8_acq_rel` | 2.74 |
| `__aarch64_ldadd8_acq_rel` | 2.15 | `Buf_fetch_normal::get` | 1.90 |
| kernel `futex_q_lock` | 1.78 | `mtr_t::Command::execute` | 1.88 |
| `rw_lock_sx_lock_func` | 1.74 | kernel `futex_q_lock` | 1.60 |
| `pthread_mutex_lock` | 1.40 | `pthread_mutex_lock` | 1.54 |

**`ut_delay` + `rw_lock_sx_lock_func` + kernel spinlock: 31.3% base, 34.1% `pgolto`.** `ut_delay`
vanishes as a symbol in `pgolto` because LTO inlines it into its caller — exactly as on the Intel
leg, so the pair must be summed before the arms are compared.

**The convoy is the same one as on Intel and AMD:** an InnoDB SX latch on hot clustered-index pages
on the TPROC-C update path, with waiters parking through `sync_array`/`os_event` onto a pthread
mutex and hence a kernel futex bucket. What differs is only *how much of it the PMU can see*.

Two things on this list have **no x86 counterpart**:

* **`swapper` is 10.8–11.2%** of counted cycles — real idle, consistent with the ladder's 80.7% box
  busy at 256 VU. Both arms the same, so it does not bias the comparison.
* **The out-of-line LSE atomic helpers — `__aarch64_ldeor8_acq_rel`, `__aarch64_cas4/8_acq_rel`,
  `__aarch64_ldadd8_acq_rel` — total ~7.5% in both arms.** gcc defaults to `-moutline-atomics` on
  aarch64, so every atomic is a *call* into a helper that branch-tests for LSE support; x86 emits
  atomics inline and shows nothing here. On a host where `-march=native` already proves LSE is
  present, `-mno-outline-atomics` would inline them and delete both the call overhead and the
  runtime test. **That is a lead, not a result** — it is a flag change we did not measure, and it is
  orthogonal to FDO. It is the most promising aarch64-specific follow-up this capture turned up.

---

## 5. Front-end counters: unreliable on this PMU, not quoted

The T0+150 s pass was meant to be the AMD leg's front-end table. **Its numbers are not
self-consistent and nothing is quoted from them:**

| | base | pgolto |
|---|---:|---:|
| `stalled-cycles-frontend` | 3.623e10 | 3.584e10 |
| `stalled-cycles-backend` | 5.124e10 | 2.481e11 |
| `L1-icache-loads` | 2.865e10 | 4.363e10 |
| `iTLB-loads` | 2.326e10 | 5.492e10 |
| `branch-load-misses` | 4.819e7 | 1.557e8 |

* **`L1-icache-load-misses` (9.486e10 base, §2) exceeds `L1-icache-loads` (2.865e10) by 3.3×.**
  Refills cannot outnumber accesses. The two events do not map to a consistent pair on Neoverse V2.
* `stalled-cycles-backend` differs **4.8×** between arms whose throughput differs by 19%, and perf
  prints `0.00% backend cycles idle` for both.
* `branch-load-misses` differs 3.2× between arms while §2's `branch-misses` differ by 1.5%.

So **this leg has no trustworthy front-end stall breakdown**, and therefore no counterpart to the
"Intel had 16.5% of slots to reclaim, AMD only 3.9%" argument that explained the AMD result. The
i-cache and iTLB *miss counts* in §2 come from the main 13-event pass and are consistent; only this
pass is discarded.

---

## 6. What this leg cannot measure

| | status |
|---|---|
| `perf c2c` / HITM / contended cache lines | **unavailable.** Fails with "memory events not supported" for plain, `-e arm_spe//`, and `arm_spe` with load/store filters. This perf has no `perf mem` support for the `arm_spe` PMU. |
| LBR call graphs | **unavailable.** `--call-graph fp` used instead: frame pointers give call graphs, but not branch-accurate ones. |
| VTune top-down (`front-end bound`, CPI, false sharing) | **no aarch64 VTune.** §5 shows the raw-counter substitute is unusable too. |
| `ref-cycles` | `<not supported>`. |
| ARM SPE as a hotspot substitute | recorded, but **171 GB per 30 s arm** at default rate — `perf report` does not complete on it in reasonable time. Deleted after the `perf record` reports were generated; the 629 MB `perf-record.data` is what §4 uses. |

Net: **there is no cache-line contention data for Graviton**, so the "HITMs per transaction fall
24%" result from Intel has no counterpart here, and the §3 `WFE` finding means the one metric that
*did* survive — cycle share of spin — is a floor rather than a figure.

---

## 7. Conclusions

1. **FDO works well on Graviton 4, and it does not need BOLT to.** `pgolto` is +19.4% with PGO+LTO
   alone, against +21.7% for Intel's PGO+LTO+BOLT and +7.9% for AMD's. Per new order it removes
   **20.3% of instructions, 41.4% of i-cache misses and 80.9% of iTLB misses.**
2. **This box is lock-bound like the other two.** The derivation in §3 puts about two thirds of busy
   time in `WFE`-halted spin on the same InnoDB SX-latch convoy. It only *looks* less lock-bound
   because its PMU stops counting while it waits.
3. **Cross-architecture `cycles`/`IPC` comparisons on spin-heavy workloads are invalid between
   arm64 and x86**, and cycle-weighted profiles are biased on arm64. Use `cpu-clock` sampling and
   instruction-count normalisation. This is a methodology correction that applies to the whole
   campaign, not just this capture.
4. **Graviton's weak spot is its 36 MiB/socket L3,** where `pgolto` pushes the miss rate from 30.3%
   to 37.4% — the only metric in §2 that moves the wrong way.
5. **`-mno-outline-atomics` is the open aarch64 lead:** ~7.5% of counted cycles sit in out-of-line
   atomic helpers that exist only because gcc defaults to a runtime LSE check.

---

## Caveats

* **n = 1 per arm.** Each collector ran in a different 30 s slot of the same measured window.
* **NOPM is with collectors running** in both arms. The collector-free warm-up runs show the same
  ratio (+20.2%), so the overhead is not asymmetric.
* **The compared arm is `pgolto`, not `pgoltob`.** It is two stages short of the Intel and AMD
  optimised arms, by hardware necessity. Where this file sets −20.3% against Intel's −23%, the
  Graviton figure is from a shorter pipeline.
* **The front-end pass (§5) is discarded as unreliable,** so part of the Intel/AMD analysis has no
  counterpart.
* **§3's two-thirds figure is derived,** from a calibration microbench plus the capture's implied
  clock — not measured directly. `cpu-clock` sampling on the PostgreSQL leg will measure it.

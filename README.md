# MySQL 8.4.8 on AWS Graviton 4 — PGO and LTO

Instrumented PGO and LTO applied to MySQL 8.4.8 on an **AWS r8g.metal-48xl (Graviton 4, Neoverse
V2)**, measured with HammerDB TPROC-C.

> ### Read this first: there is no BOLT arm, and no AutoFDO arm
>
> The repository name follows the convention used by the Intel and AMD legs, but **BOLT and
> AutoFDO are absent here because this hardware cannot support them.** Graviton 4 exposes no
> LBR-equivalent, so neither `create_gcov` (AutoFDO) nor `perf2bolt` (BOLT) has an input:
>
> ```
> $ perf record -e cycles:u -j any,u ...
> cycles:u: PMU Hardware or event type doesn't support branch stack sampling
> ```
>
> That is the kernel's own capability check refusing `PERF_SAMPLE_BRANCH_STACK` for this PMU, not
> a tooling gap we could work around. The raw evidence is in
> [`sysinfo/branch-sampling-unsupported.txt`](sysinfo/branch-sampling-unsupported.txt), and §5
> explains it. **Instrumented PGO needs no hardware sampling at all, so it runs normally** — which
> is what this leg measures.

**Headline: `pgolto` (PGO + LTO) is +12.59% NOPM** over a plain `-O3 -march=native` build, rising
to **+17.4% once the box is saturated**. CPU per transaction falls **18.1%**.

Companion legs on the same workload and toolchain:
[`amd-mysql-pgo-lto-bolt`](https://github.com/andrewkim-pkt/amd-mysql-pgo-lto-bolt) and
[`mysql-pgo-lto-bolt`](https://github.com/andrewkim-pkt/mysql-pgo-lto-bolt) (Intel).

---

## 1. System and workload

### 1.1 Server

Raw capture in [`sysinfo/graviton-r8g-metal-48xl.txt`](sysinfo/graviton-r8g-metal-48xl.txt).

| | |
|---|---|
| Instance | AWS **r8g.metal-48xl** |
| CPU | **AWS Graviton 4** (ARM Neoverse V2), aarch64 |
| Topology | **192 cores / 2 sockets / 1 thread per core — no SMT** |
| NUMA | **2 nodes**: node 0 = CPU 0–95, node 1 = CPU 96–191 |
| **L2** | **384 MiB total — 2 MiB per core** |
| **L3** | **72 MiB total — 36 MiB per socket** |
| RAM | 1,508 GB |
| OS / kernel | Amazon Linux 2023, **6.18.56-126.188.amzn2023.aarch64** |
| THP / numa_balancing | `madvise` / 1 |
| ISA features | `sve`, `sve2`, `bf16`, `i8mm`, `rng`, `bti`, `atomics`, `lrcpc`, crypto/sha3 |

The cache hierarchy is the interesting contrast with the x86 legs: **twice the L2 per core as the
AMD box (2 MiB vs 1 MiB), and roughly a tenth of the L3 (72 MiB vs 768 MiB).**

### 1.2 Client

AWS **r7i.24xlarge** — Xeon Platinum 8488C, 96 vCPU, 743 GB, HammerDB 4.7. **The same client
drove all three architectures in this campaign**, which removes the load generator as a variable.

> `cli%` in `results/` is contaminated (~20%) by a CPU-activity guard that keeps the instance from
> being auto-stopped for idleness. **Do not quote `cli%`.** Server-side `box%`, `n0%` and `n1%`
> are clean.

### 1.3 Workload

| | |
|---|---|
| Benchmark | HammerDB 4.7 TPROC-C, `allwarehouse true`, `keyandthink false`, stored procedures on |
| Warehouses | **1,536** |
| Row counts | warehouse 1,536 · district 15,360 · order_line 460,826,344 · customer 46,080,000 |
| Datadir | **197 G on tmpfs** (`/mnt/ramdisk/mysqldata`) — zero storage I/O in the measurement |
| Handling | built once, kept as a RAM golden plus an EBS snapshot, restored before every pass with `numactl --interleave=all cp` |

Dataset row counts match the Intel and AMD legs, so all three architectures ran identical data.

### 1.4 Server configuration

[`scripts/server/my-c.cnf`](scripts/server/my-c.cnf), identical to the other legs:

```ini
innodb_buffer_pool_size         = 200G
innodb_buffer_pool_instances    = 8
innodb_redo_log_capacity        = 64G
innodb_doublewrite              = OFF
innodb_flush_log_at_trx_commit  = 2
innodb_flush_neighbors          = 0
innodb_io_capacity              = 40000
innodb_io_capacity_max          = 80000
max_connections                 = 3000
performance_schema              = OFF
skip-log-bin
```

Started with `--innodb-numa-interleave=ON` and `ulimit -n 65535`; `mysqld` unpinned across all 192
cores for the ladder.

### 1.5 Toolchain

| tool | version |
|---|---|
| gcc / g++ | **15.2.0**, built from source → `/opt/gcc15` |
| MySQL source | **8.4.8** |

`-march=native -mtune=native` on this host resolves to:

```
-mcpu=neoverse-v2+crc+sve2-aes+sve2-sha3+nossbs
```

(`graniterapids` on Intel, `znver5` on AMD.) llvm-bolt and autofdo are **not built here** — see the
notice above.

---

## 2. Build steps

Four binaries; three are measurable arms. All from
[`scripts/server/my-build.sh <arm>`](scripts/server/my-build.sh).

| arm | role | `mysqld` md5 | `.text` |
|---|---|---|---|
| `base` | `-O3 -march=native -mtune=native`, no LTO — **reference** | `1012d2f5381c` | 35,348,748 |
| `pgogen` | instrumented, training only | `9c894f2a929a` | — |
| **`pgo`** | **`-fprofile-use`, no LTO** | **`819ba4ba66b2`** | 40,370,412 |
| **`pgolto`** | **PGO + LTO** | **`1f8738b920fd`** | 36,440,268 |

Note the `.text` ordering: PGO alone *grows* the binary 14% over base (expected with
`-fprofile-partial-training`, which stops untouched functions being optimised for size), and LTO
then claws about 10% of that back.

### 2.1 Flags

```
COMMON  = -O3 -march=native -mtune=native
LTO     = -flto=96 -ffat-lto-objects
```

| arm | `CMAKE_EXTRA` | extra flags |
|---|---|---|
| `base` | — | — |
| `pgogen` | `-DFPROFILE_GENERATE=1 -DWITH_LTO=OFF` | `-fprofile-update=prefer-atomic` (set by MySQL's `fprofile.cmake`) |
| `pgo` | `-DFPROFILE_USE=1 -DWITH_LTO=OFF` | — |
| `pgolto` | `-DFPROFILE_USE=1 -DWITH_LTO=ON` | — |

`FPROFILE_USE` additionally brings `-fprofile-correction -fprofile-partial-training
-Wno-missing-profile`.

**LTO notes, and they are the same three that mattered on x86:**

* **`-ffat-lto-objects` is required.** MySQL's build runs objects through `ar`/`ranlib` *and*
  executes generated tools; fat objects keep both the IR and real machine code in each `.o` so
  neither path breaks.
* **`-flto=96` is held at 96 even though this box has 192 cores.** `-flto=N` sets LTRANS
  parallelism and therefore influences partitioning, so changing it per machine would turn the
  cross-architecture comparison into a flag study.
* **The gcc-15 archivers must be forced** (`GCC_AR_EXECUTABLE`, `GCC_RANLIB_EXECUTABLE`),
  otherwise MySQL's `FIND_PROGRAM` picks up the system gcc 11 `ar`, which loads the wrong LTO
  plugin for gcc 15 IR.

**LTO on aarch64 worked without modification.** That was the open risk going in — `-flto=96
-ffat-lto-objects` on a 192-core ARM box had no precedent in this campaign — and it built clean.

### 2.2 PGO training

| | |
|---|---|
| Binary | `pgogen` (instrumented) |
| Cell | **64 cores on node 1**: `numactl --physcpubind=96-159 --preferred=1` |
| Load | **64 VU**, 3 min rampup + 10 min, 1,536 WH |
| Throughput during training | **76,149 NOPM** |
| Result | **2,083 `.gcda`** |

Two ways to lose the profile silently, both guarded against in the driver:

1. **The build's own tool runs leave `.gcda` in the tree** — they describe the build, not TPROC-C.
   Delete them first.
2. **The server must stop with a clean shutdown.** An immediate/SIGQUIT stop skips the exit
   handlers and gcov never writes; the run is lost with no error anywhere.

A profile collected from a workload that did no work looks identical to a good one by file count.
The tell is CPU time: a healthy 14-minute training run shows ~20 min of user CPU, a dead one ~2 min.
The pipeline therefore gates on **training NOPM > 1,000** as well as `.gcda` count.

---

## 3. Results

3 arms × 6 load points × **6 mirrored passes** (`base pgo pgolto | pgolto pgo base`), one server
lifetime per pass, dataset restored interleaved before each. Rampup scales with VU
(2/2/3/4/6/10 min) then 3 min measured. Raw output in
[`results/wholebox-48xl/`](results/wholebox-48xl/).

**Mean NOPM (mean of the two mirrored passes)**

| VU | box busy | base | pgo | pgolto |
|---|---:|---:|---:|---:|
| 32 | 4.7% | 208,931 | 226,020 | **229,822** |
| 64 | 9.1% | 409,420 | 437,103 | **443,266** |
| 128 | 22.4% | 726,901 | **795,344** | 793,289 |
| 256 | 80.7% | 507,044 | 593,187 | **595,434** |
| 512 | 86.0% | 360,825 | 418,889 | **419,892** |
| 1024 | 91.0% | 351,631 | **408,578** | 402,079 |

**Percent versus base**

| VU | pgo | pgolto |
|---|---:|---:|
| 32 | +8.18% | **+10.00%** |
| 64 | +6.76% | **+8.27%** |
| 128 | **+9.42%** | +9.13% |
| 256 | +16.99% | **+17.43%** |
| 512 | +16.09% | **+16.37%** |
| 1024 | **+16.20%** | +14.35% |
| **6-rung mean** | **+12.27%** | **+12.59%** |
| saturated (256/512/1024) | +16.43% | +16.05% |
| CPU per transaction | — | **−18.1%** |

CPU per transaction by rung for `pgolto`: `32:−25.7% 64:−24.5% 128:−17.8% 256:−15.4% 512:−14.1%
1024:−11.5%`.

**Three observations**

1. **The gain grows with load**, from ~8–10% light to ~16–17% saturated. The same saturation
   dependence seen throughout this campaign — and this box actually reaches saturation (80.7% at
   256 VU, 91% at 1024), so the effect is fully visible rather than truncated.
2. **LTO adds almost nothing over plain PGO here** — +12.59% against +12.27%, and `pgo` wins
   outright at 128 and 1024 VU. Given the pass spreads below, **LTO's contribution on Graviton is
   inside the noise.** That differs from the Intel leg, where PGO→PGO+LTO was worth more.
3. **Data quality is good.** Pass spreads 0.1–5.7%, mostly under 2%; zero error lines on every
   rung; every rung logged its full VU count.

**Per-pass spread (A / B)**

| VU | base | pgo | pgolto |
|---|---:|---:|---:|
| 32 | 4.7% | 0.4% | 0.8% |
| 64 | 4.1% | 0.4% | 0.7% |
| 128 | 1.8% | 0.8% | 1.3% |
| 256 | 0.1% | 2.1% | 1.3% |
| 512 | 3.3% | 1.6% | 0.5% |
| 1024 | 4.1% | 1.7% | 5.7% |

> **Caveat on the generated report.** `scripts/client/report-wb.sh` hardcodes the Intel/AMD arm
> list (`base afdoltob pgolto pgoltob`) and assumes an 8-pass A/B split. Run against this 6-pass,
> 3-arm layout it **omits `pgo` entirely** and mislabels the pass pairs. Its `base` and `pgolto`
> rows are correct; the `pgo` column in §3 was computed from the raw per-rung files in
> `results/wholebox-48xl/`. A 3-arm variant of that script is still needed.

---

## 4. Against Intel and AMD

The only arm present on all three architectures is `pgolto`, so that is the honest comparison:

| | `pgolto` vs base | best available arm |
|---|---:|---|
| Intel r8i.metal-48xl | +15.56% | afdoltob +20.89% (BOLT available) |
| **Graviton 4 r8g.metal-48xl** | **+12.59%** | **pgolto +12.59% (nothing further possible)** |
| AMD r8a.metal-48xl | +1.26% | pgoltob +2.11% (BOLT available) |

**Graviton responds to PGO+LTO far more like Intel than like AMD**, which was not the expected
outcome after the AMD result. It is also the architecture where the *ceiling* is lowest, because
the hardware forecloses the two stages that gave Intel its extra ~5 points.

### 4.1 Hardware-counter capture at 256 VU

A dedicated `base` vs `pgolto` capture at 256 VU / 1,536 WH, matching the Intel and AMD legs,
is in [`results/perfcap-48xl/`](results/perfcap-48xl/) with the full writeup in
[`results/perfcap-48xl/ANALYSIS.md`](results/perfcap-48xl/ANALYSIS.md). Per new order:

| per new order | this leg (`pgolto`) | Intel (`pgoltob`) | AMD (`pgoltob`) |
|---|---:|---:|---:|
| instructions | **−20.3%** | −23% | −5.8% |
| L1-icache misses | **−41.4%** | −47% | −34.2% |
| iTLB misses | **−80.9%** | −72% | −97.0% |
| dTLB misses | −25.2% | −31% | −0.6% |
| NOPM at 256 VU | **+19.4%** | +21.7% | +7.9% |

Graviton gets within two points of Intel's throughput gain **with two fewer optimisation stages**,
and converts the layout win into throughput where AMD does not.

> **A measurement warning that applies campaign-wide.** On arm64, contended lock waits park the
> core in `WFE`, which **halts the `CPU_CYCLES` counter** while the thread still counts as running.
> Calibrated on this box: 192 threads on one contended mutex accumulate **90.6 MHz** of counted
> cycles per core against **2.691 GHz** for 192 threads doing real work, at the same ~95–99%
> scheduler occupancy. So **`cycles` and `IPC` from this box cannot be compared with x86**
> (Graviton's apparent IPC of 0.74 vs Intel's 0.25 is an artifact, not an efficiency result), and
> cycle-weighted `perf record` under-samples spin. The derivation in §3 of the analysis puts about
> **two thirds of busy time in `WFE`-halted spin** — this box is lock-bound like the other two, it
> just cannot see itself waiting. Instruction, branch, cache and TLB counts are unaffected.

---

## 5. Why AutoFDO and BOLT cannot run here

Both stages need LBR-style **from→to branch records**. What each architecture's PMU driver exposes:

| | branch records |
|---|---|
| Intel (Xeon 6975P-C) | LBR, 32-deep, honours `PERF_SAMPLE_BRANCH_STACK` system-wide |
| AMD (EPYC 9R45) | `amd_lbr_v2`, 16-deep; per-process and per-CPU only, **not** system-wide |
| **Graviton 4 (Neoverse V2)** | **none** — `PERF_SAMPLE_BRANCH_STACK` is not implemented |

ARM SPE (`arm_spe_0`) is present and records fine, but it produces **single-address operation
samples** (`branch-miss`, `l1d-access`, `tlb-access`), not from→to pairs — `perf script -F brstack`
comes back empty. Newer LLVM added `perf2bolt --spe` for exactly this case, but that is LLVM 19+,
and this campaign pins **18.1.3** across all three legs so a BOLT delta can't be confused with a
tool-version delta.

Anyone can check a machine in ten seconds:

```bash
perf record -e cycles:u -j any,u -- sleep 1 && echo supported
```

Nothing in this pipeline lives in kernel space. The only kernel-side components are mainline and
already enabled: the `perf_event_open(2)` syscall, the perf subsystem, and one architecture PMU
driver. `/proc/sys/kernel/tainted` is `0` on this box with zero perf modules loaded — captured in
`sysinfo/`. The only kernel-side *settings* touched are `kernel.perf_event_paranoid` and
`kernel.nmi_watchdog`.

---

## 6. Binaries

| arm | `mysqld` md5 | archive | size |
|---|---|---|---|
| `base` | `1012d2f5381c` | `mysql-gcc15-grv-base.tar.xz` | 25,086,696 |
| `pgo` | `819ba4ba66b2` | `mysql-gcc15-grv-pgo.tar.xz` | 27,733,944 |
| **`pgolto`** | **`1f8738b920fd`** | `mysql-gcc15-grv-pgolto.tar.xz` | 26,078,560 |

Trimmed to `bin/{mysqld,mysql,mysqladmin}`, `lib/private`, `lib/plugin`, `share` — the set needed
to run the benchmark. Checksums in `binaries/SHA256SUMS` and `binaries/MD5SUMS`; `.text` sizes in
`binaries/TEXTSIZES`.

**These are `aarch64` builds and will not run on x86.**

`profiles/pgogen-gcda.tgz` holds the 2,083 PGO counters, so `pgo` and `pgolto` can be rebuilt
without repeating the training run. The build directory name must match the generate pass —
`.gcda` filenames encode the mangled absolute object path, so a renamed tree makes
`-fprofile-use` find nothing.

---

## Layout

```
README.md                      this file
sysinfo/                       raw lscpu / numactl / PMU capture, and the branch-sampling evidence
binaries/                      base + pgo + pgolto, trimmed trees, checksums, .text sizes
profiles/                      PGO .gcda tarball
scripts/server/                build, server lifecycle, dataset, CPU sampling
scripts/client/                env, dataset driver, training driver, ladder driver, HammerDB templates
logs/                          gcc and per-arm MySQL build logs
results/wholebox-48xl/         6-pass ladder: per-rung HammerDB output, points, placement, report
results/perfcap-48xl/          256 VU hardware-counter capture: perf stat / record, ANALYSIS.md
```

Scripts are the 2-NUMA-node ports of the Intel originals; the originals are kept beside them as
`*.intel-orig` for diffing. Three changes were needed: the training cell (`96-159`), the golden
copy's node, and the node CPU lists in the report generator.

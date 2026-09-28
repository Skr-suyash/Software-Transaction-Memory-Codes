# Reproduction protocol and ranked experiment sequence

## 1. Environment (pinned)
| item | value |
|---|---|
| GPU | NVIDIA GeForce RTX 4060 Laptop GPU, Ada sm_89, 24 SMs, 8 GB, WDDM driver 616.56 |
| CUDA | 12.8 (nvcc V12.8.61), MSVC 2022 host compiler, flags `-O3 -std=c++17 -arch=sm_89 -lineinfo` |
| OS | Windows 11 (10.0.26200); TDR default (2 s) — long kernels complete via compute preemption |
| Python | 3.14 (driver/analysis scripts), PyMuPDF (literature extraction only) |
| Baseline pins | gpma_demo `080aa6d` (2023-06-19); port = `gpu-stm-dynamic-graphs/baselines/gpma_port` |

Record `nvidia-smi` and `nvcc --version` with every result set (the laptop GPU's clocks vary with power state:
run plugged in, performance mode, nothing else on the GPU).

## 2. Build
```
build.bat test_gtx      # correctness suite          -> bin/test_gtx.exe
build.bat bench         # all transactional systems  -> bin/bench.exe
build.bat repro         # forensic loop              -> bin/repro.exe
baselines\gpma\build_gpma.bat                        -> bin/gpma_port.exe, bin/gpma_upstream.exe
```

## 3. Timing boundaries and statistics
* **GPU operation time**: cudaEvent around the single transactional kernel (`kRun`) with device-resident workload;
  initial-graph loading and history checking are excluded. GPMA+: per-batch `update_gpma` time, summed.
* **Complete request latency** (per transaction): `%globaltimer` from the first attempt's start to commit (includes
  retries and backoff; excludes queueing before a lane picks the transaction up). Reported p50/p95/p99 separately for
  update and read-only transactions.
* **Throughput**: committed transactions/s and **effective** edge changes/s (edges whose presence changed); attempted
  operations are never reported as throughput.
* Repetitions: 1 warm-up (discarded) + 5 measured per (scenario, system), same seed ⇒ identical workload; report median,
  min, max; speedups are ratios of median committed throughput with 95% bootstrap CIs over repetitions.
* Every process runs one (scenario, system) with a 90 s timeout (`scripts/run_matrix.py`); a timeout is recorded as DNF
  and reported as a lower bound, never omitted.
* A result is valid only if its flag column is 0 (no arena exhaustion, no watchdog); flagged runs are reported as such.

## 4. Correctness gate (must pass before any performance number is accepted)
```
bin\test_gtx.exe full          # A: 6 adversarial workloads x {SI,SER} x {coop} x {dst} (48 histories), B: write skew,
                               # C: 3 mutation tests (must FAIL), D: resource exhaustion
python scripts\run_matrix.py check --reps 1     # all transactional systems through the same checker (C1-C5)
```
Checks: C1 read rule (every read/no-op/scan equals S(rts) + own writes), C2 observed-version identity, C3 write-write
exclusion, C4 final state, C5 serialization-graph acyclicity (SER). The write-skew probe must show cycles under SI and
none under SER; mutations (no write-write check, dirty reads, ignored snapshot) must be rejected.

## 5. Workloads (all systems consume the identical generated stream)
Generator `src/workload.hpp` (splitmix64, seed 1). Fixed vertex set V = 2^20; initial graph 4M edges from the same
source distribution; destinations uniform in [0,V), no self loops.
| family | parameters |
|---|---|
| uniform inserts | K ∈ {1,2,4,8,32}, N = 2^20/K transactions |
| shared-source contention | 50% of sources = one hub vertex, different destinations; K ∈ {1,2,4,8,32} |
| identical-edge contention | 50% of operations on a hot set of 64 or 1024 edges; insert/delete churn; K=4 |
| churn / deletion | 50/50 insert/delete (deletes target previously generated edges), uniform / R-MAT / Zipf(1.0); delete-only |
| concurrent readers | 50% or 90% read-only transactions (point reads, 10% adjacency scans) + churn writers |
| serializable read-write | 40% insert / 30% delete / 30% point reads inside update transactions, SER mode |

## 6. Ranked experiment sequence
1. **Correctness** (§4) — exhaustive-style adversarial histories, delete/re-insert, partial visibility, write skew,
   scan phantoms, stalled readers (long per-lane scans under SER), resource exhaustion. *Gate for everything below.*
2. **Baseline reproduction** — GPMA+ upstream (CDP1) and port on the identical insert streams; document port effects.
   Unavailable implementations (Hornet, faimGraph, SlabGraph/Meerkat, LPMA, GTX-CPU) are paper-only comparisons
   (`benchmarks/benchmark_inventory.csv`).
3. **Matched transactional performance** — `run_matrix.py main` (sync baselines on shared storage), `ser`.
4. **Ablations** — `run_matrix.py ablation`: cooperative allocation (M1) and destination-precise conflicts,
   each alone and combined, at hub fractions 0 / 0.5 / 1.0 and K ∈ {1, 8}.
5. Next (specified, not yet run): multiple reservation regions (M2), reclamation by generation (M4), real SNAP graphs,
   batch-size sweep 2^10..2^22 against GPMA+.

## 7. Known threats to validity
* Baselines' hash tables are **pre-sized** from the workload (never grow); GTX-GPU grows blocks at run time.
  This favours the baselines.
* 2PL uses per-thread execution with blocking spinlocks (no warp cooperation) — standard, but a warp-aggregated 2PL
  could be faster on uniform workloads.
* WDDM laptop GPU: clocks throttle; single machine; no multi-GPU.
* GTX-GPU never reclaims aborted/voided deltas; long runs with many aborts consume memory (measured in the tiny-arena test).

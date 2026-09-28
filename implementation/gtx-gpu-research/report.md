# GTX-GPU: results report

**Problem.** Atomic multi-edge transactions (insert/delete edges, point reads, adjacency scans) on a GPU-resident dynamic
graph, with **concurrent snapshot readers**, fixed vertex set, SI and serializable configurations.
**Machine.** RTX 4060 Laptop GPU (Ada sm_89, 24 SMs, 8 GB, WDDM), CUDA 12.8, Windows 11. All numbers are local,
matched measurements (same generated stream and seed for every system; median of 5 repetitions after a warm-up;
speedups = ratio of median *committed-transaction* throughput with 95% bootstrap CIs; `results/speedups.csv`).

## 1. Summary

GTX-GPU adapts GTX's versioned edge deltas, delta chains, descriptors and group commit to the GPU. The GPU-specific
changes: destination-precise conflict detection with validate-then-CAS on one observed head, block generations with
lazy chain sealing, a fused generation+fill reservation word with warp-cooperative reservation, wait-free epoch
registration, and Silo-ordered serializable validation.

* **Correct under a history checker, not just a final-state diff.** Every read, no-op write and scan is checked
  against its snapshot. The checker also verifies write-write exclusion and serialization-graph acyclicity. It passes
  48 adversarial histories, a write-skew probe (SI must show the anomaly, SER must not), and all baselines. It rejects
  3 deliberately broken protocols, two of which pass the earlier prototype's log-vs-final check. It found 5 real
  protocol defects during development; all are fixed (`results/defect_log.md`).
* **Large speedups where synchronization is actually hard** (contention, power-law graphs, concurrent readers, large
  transactions, serializable read-write transactions). The comparison is against conventional GPU synchronization
  (2PL vertex locks, TL2 word-STM) on the *same* storage, and against GPMA+ on the same streams.
* **Honest losses:** slower than 2PL on uniform, low-contention, small transactions (1.3–2.1×); slower than a
  degree-free STM on write-only contention (1.0–1.6×); always slower than non-transactional CAS (no atomicity);
  2.5–20× more memory (no reclamation yet).

## 2. Headline results (GTX-GPU speedup in committed transactions/s; >1 = GTX-GPU faster)

| scenario (V = 2^20, 4M initial edges, ~1M operations) | 2PL vertex locks | TL2 word-STM | TL2 STM, no degree word | GPMA+ |
|---|---:|---:|---:|---:|
| **R-MAT, 90% snapshot readers** (baselines in their best scan mode) | **14.0×** [13.8, 14.7] | **22.7×** [20.3, 26.4] | **16.7×** [15.5, 18.6] | n/a (no readers) |
| **Zipf(1.0), 50% readers** (best mode each) | **>205×** (DNF 90 s) | **8.5×** [8.3, 8.7] | **2.5×** [2.4, 3.4] | n/a |
| **Serializable, 20% readers, Zipf** (checked) | **652×** | **119×** | **20×** | n/a |
| **Serializable, 20% readers, 50% hub** (checked) | **59×** | **23×** | **10×** | n/a |
| **R-MAT churn, K=4** | **525×** [475, 554] | **101×** | 0.96× | — |
| **Zipf churn, K=4** | **>11,903×** (DNF) | **364×** | 0.89× | — |
| **Identical-edge contention, 1,024 hot edges** | **9.3×** | **12.3×** | **10.3×** | — |
| **Identical-edge contention, 64 hot edges** | **4.6×** | **2.5×** | **2.6×** | — |
| **Large transactions, K=32, uniform** | **1.55×** | **77×** | **11.5×** | — |
| **Large transactions, K=32, 50% hub** | **>11,373×** (DNF) | **4,711×** | **4.1×** | — |
| **Shared-source hub (50%) inserts, K=1..8** | **>19,000×** (DNF) | **127–613×** | 0.76–1.21× | **13×** |
| **Uniform inserts / churn, K=1** (same streams as GPMA+) | 0.52–0.53× | 1.0–1.14× | 0.61–0.69× | **8.6–14.6×** (524K batches), **10–20×** (65K) |

Reader latency (R-MAT, 90% readers): read-only p99 **2.4 ms** for GTX-GPU vs 459 ms (2PL), 210 ms (TL2 STM),
83 ms (STM without degree) in per-lane mode, and 57 / 328 / 238 ms with cooperative read-only scans. GTX-GPU readers
never abort and never block writers. Its abort ratio in this scenario is 0.03%, versus 90% for TL2 STM.

DNF = did not finish within the 90 s timeout; the bound assumes the baseline would have committed the whole workload
at the timeout. Full tables: `results/summary.md`; GPMA+ table: `results/gpma_summary.md`.

## 3. Where GTX-GPU loses (reported, not hidden)

| scenario | ratio (GTX-GPU / baseline throughput) | why |
|---|---:|---|
| uniform inserts/churn/deletes, K ≤ 8, vs 2PL | 0.47–0.76 | per-op cost of versioning: 32 B delta + chain head + descriptor/epoch bookkeeping; uncontended vertex locks are cheap. The engine skeleton alone (~3.3 ms per 1M ops) matches 2PL's whole run (profiled; no single hotspot) |
| write-only contention vs TL2 STM *without* a degree word | 0.64–0.98 | hash-slot writes to a hub rarely conflict when no degree is maintained. This STM variant cannot answer degree queries transactionally, and it collapses once snapshot readers with scans arrive (Zipf readers: 2.5× slower than GTX-GPU; R-MAT readers: 16.7× slower) |
| any scenario vs non-transactional CAS | 0.10–0.45 (2.49× faster on R-MAT readers only when the CAS baseline scans per lane) | CAS provides no multi-edge atomicity and no consistent reads; it is a lower bound on synchronization cost |
| Zipf readers with **per-lane** scans | 2,577 ms vs 1,110 ms (STM no-degree, per-lane) | GTX scans read every delta version (32 B) including aborted/voided slots; cooperative (warp) scanning is required. With it: 438 ms |
| memory | 2.5–20× the hash-table baselines (e.g. 1.5 GB vs 77 MB, 64 hot edges) | aborted and voided deltas are never reclaimed (Method M4 specified, not implemented) |

## 4. Correctness evidence
* `bin/test_gtx.exe full`: 6 adversarial workloads × {SI, SER} × {cooperative reservation on/off} ×
  {destination/chain conflicts} = 48 histories, all **PASS** C1–C5. Write-skew probe: SI shows 16,000 dependency-graph
  back edges (the anomaly is allowed and the detector is live); SER shows 0. Resource exhaustion: the committed prefix
  is consistent.
* Mutation tests (`results/mutation_final_state.txt`):

  | mutation | prototype-style "logged set == final set" | new checker |
  |---|---|---|
  | no write-write check | passes (0/0) | 4,386 C3 + 10,984 same-epoch writers, 6,557 cycles |
  | ignore snapshot | passes (0/0) | 9,658 wrong reads + 5,382 wrong scans |
  | dirty reads | detected | 11,411 + 6,972 + 271,175 cycles |
* All baselines (2PL, TL2 STM ± degree) pass the same checker in serializable mode (`run_matrix.py check`), including
  their cooperative read-only variants.
* Defects found by the checker and fixed before benchmarking: registration livelock (D5), epoch-after-validation
  read-only anomaly (D6), read-only commit exposing voided slots (D7), a missing happens-before edge on generation
  growth (D8), and an unsafe watchdog (D9). See `results/defect_log.md` and `audit/prototype_audit.md`.

## 5. Ablations and hypotheses (design/design.md §7)
| method | test | result | status |
|---|---|---|---|
| M1 cooperative (warp-aggregated) delta reservation | `gtx` vs `gtx-dst-only` | +3.4% uniform K=8; +6–11% hub; +0.3% Zipf churn | **falsified** as a primary mechanism (<10% in 3 of 4 hub cells); kept as a small, never-negative win |
| M1b destination-precise conflicts (validate-then-CAS on the same head) | `gtx` vs `gtx-coop-only` / `gtx-cons` | abort ratio 8.5%→0 (K=8), 45%→0 (K=32); ×1.14 (K=8, isolated), ×1.80 (K=32 vs conservative) | **supported** |
| M2 multiple reservation regions | — | not built; M1 shows the reservation RMW is off the critical path | ranked low |
| M3 epoch commit groups | cycle profile, checker | commit 9.6–15.5% of lane cycles; all histories pass | **not falsified** |
| M4 reclamation by generation | — | specified; memory overhead above motivates it | next |
| Padding hot counters to separate cache lines | A/B build | no gain (−1% to +7% time) | **falsified** (reverted) |
| acq_rel vs relaxed reservation RMW | dbg build | no measurable difference | fence is free here |

GTX-faithful port (`gtx-cons`: per-lane reservation + chain-granularity conflicts) vs ours: equal within noise on most
workloads. Ours is faster where transactions are large or chains are shared: ×1.80 (K=32 uniform), ×1.33 (K=32 hub),
×1.28 (K=8 hub).

## 6. Fairness notes
* Baseline hash tables are pre-sized from the workload and never grow; GTX-GPU grows at run time (favors baselines).
* Scans: GTX-GPU scans cooperatively by default. Baselines were run both per-lane and with cooperative read-only scans
  (`-roCoop` labels); every headline comparison uses the **better** of the two for each baseline. GTX with per-lane
  scans is also reported (`-lanescan`).
* 2PL uses sorted blocking vertex locks for update transactions and bounded try-locks for cooperative read-only
  transactions (a blocking lock inside a warp collective can deadlock).
* GPMA+ provides batch atomicity only, no multi-edge transactions or concurrent readers, and loses intra-batch
  operation order: its final state differs from sequential semantics on hub and churn streams (duplicates within a
  batch; INS/DEL of one edge in one batch). Its Windows port and pristine upstream (CDP1) run at the same speed on
  these streams (≤2% apart), so the port does not distort these comparisons.
* Literature numbers (`benchmarks/benchmark_inventory.*`) are reference points only (TITAN V / P100 / 2080 Ti, other
  datasets). Examples: SlabGraph 501–641 MEdge/s insert without transactions; LPMA 6–20× over GPMA+; GTX (CPU) up to 11×
  over LiveGraph/Teseo/Sortledton. No cross-hardware claims are made.

## 7. Limitations and next steps
1. Reclamation / consolidation by generation (M4) to remove the 2.5–20× memory overhead and speed up scans.
2. Close the uncontended gap to 2PL: fewer bytes per version (split hot/cold delta fields) and cheaper per-attempt
   bookkeeping.
3. Real SNAP graphs and batch-size sweeps (2^10–2^22) against GPMA+; build LPMA / Hornet / faimGraph / SlabGraph on this
   machine for matched storage-level comparisons (currently paper-only).
4. Descriptor reuse (generation-tagged ids), vertex insertion/deletion, and durability are out of scope of this prototype.

# gtx-gpu-research — GTX-inspired GPU synchronization for atomic multi-edge transactions

A GPU adaptation of GTX (versioned edge deltas, destination-hashed delta chains, transaction descriptors, epoch group
commit) for **atomic multi-edge transactions with concurrent snapshot readers** on a dynamic graph, with a
history checker that validates every run, matched baselines, and a verified literature package.
Hardware: RTX 4060 Laptop GPU (sm_89), CUDA 12.8, Windows 11.

| path | contents |
|---|---|
| `report.md` | **results and conclusions** (read first) |
| `literature/literature_review.md`, `literature/source_manifest.csv` | verified literature review; every number traced to a page of a downloaded primary PDF (`literature/pdfs`, `literature/text`) |
| `audit/prototype_audit.md` | audit of the earlier prototype (`../gpu-stm-dynamic-graphs`) with concrete counterexample histories; GPMA baseline audit |
| `design/design.md` | data layout, operation semantics, pseudocode, invariants, memory-order requirements, progress assumptions, cost model, hypotheses + falsification criteria for methods M1–M4 |
| `benchmarks/benchmark_inventory.{md,csv}` | literature measurements with provenance (paper/version, figure/table, hardware, dataset, mix, batch, consistency, timing boundary, statistic, exact vs digitized vs reproduced) and the local benchmark matrix |
| `protocol/reproduction_protocol.md` | environment pins, build, timing boundaries, statistics, correctness gate, workloads, ranked experiment sequence, threats to validity |
| `src/gtxg.cuh` | GTX-GPU engine (SI and SER, ablation switches) |
| `src/baselines.cuh` | 2PL, TL2 word-STM (with/without degree word), non-transactional CAS — shared storage layout |
| `src/checker.hpp` | history checker C1–C5 (read rule, observation identity, write-write, final state, serialization graph) |
| `src/test_gtx.cu` | correctness suite (adversarial histories, write-skew probe, mutation tests, exhaustion) |
| `src/bench.cu`, `scripts/run_matrix.py`, `scripts/summarize.py` | benchmark driver, resumable sweep, statistics |
| `baselines/gpma/` | GPMA+ harness on identical streams; Windows port vs pristine upstream (CDP1); `PORT_NOTES.md` |
| `results/` | raw CSV, summaries, speedups with bootstrap CIs, defect log |

Quick start: `build.bat test_gtx && bin\test_gtx.exe full` (correctness gate), then
`build.bat bench && python scripts\run_matrix.py main && python scripts\summarize.py`.

# Benchmark inventory

Two parts: (A) literature measurements — reference points with full provenance (`benchmark_inventory.csv`);
(B) the local matched benchmark matrix — the only source of comparative claims.
Value kinds: **exact** (number quoted from text or table), **digitized** (read off a plot — none used so far),
**reproduced** (measured locally in this package).

## A. Literature measurements (all *exact*, verified in the primary PDF)

| id | system (vs) | location | hardware | batch | consistency | timing boundary | value |
|---|---|---|---|---|---|---|---|
| L1 | GPMA+ (vs GPMA) | arXiv 1709.05061v2 §6.2, Fig. 7 | 3× TITAN X | 1..1M sliding | none | avg batch latency | up to 18.30× |
| L2 | GPMA+ (vs CPU PMA) | same | same | same | none | same | up to 20.42× |
| L4 | LPMA-H (vs GPMA+) | LPMA §7.3, Fig. 13 | Tesla P100 | 10⁴ | none | batch latency | 6–9× |
| L5 | LPMA-H (vs GPMA+) | same | same | 10⁵ | none | same | 10–20× |
| L6 | LPMA-H (vs faimGraph) | same | same | 10⁴ | none | same | 1.4–1.7× (large graphs) |
| L7–L9 | Hornet / faimGraph / SlabGraph insert | SlabGraph Table II | TITAN V | 65,536 | none | excl. transfer | 33.67 / 92.47 / 501.33 MEdge/s |
| L10–L12 | same | same | same | 524,288 | none | excl. transfer | 70.81 / 188.98 / 641.25 MEdge/s |
| L13 | SlabGraph delete | Table III | TITAN V | 65,536 | none | excl. transfer | 640.63 MEdge/s (Hornet 91.73, faimGraph 111.71) |
| L14–L16 | Meerkat (vs Hornet) | arXiv 2305.17813 v1/v2 abstract | RTX 2080 Ti | bulk | none | — | insert 12.94×, delete 6.1×, query 12.6× |
| L17 | Hornet (vs Meerkat) TC | v2 body | RTX 2080 Ti | — | none | — | 31.12× avg (up to 59.34×) |
| L18 | GTX (vs best of LiveGraph/Teseo/Sortledton) | arXiv 2405.01418v2 §1/§10 | Xeon Platinum 8368 | txns | **SI** | txn throughput | up to 11× (timestamp-ordered), 2× (random order) |
| L19 | GTX with concurrent analytics | same | same | txns | SI | update throughput | up to 5.3× write-heavy, 3.7× balanced |

Not verified (PDF not retrieved): Hornet's and faimGraph's own tables; Meerkat IJPP 2024 journal numbers; CSMV and
PR-STM numbers beyond abstracts.

## B. Local matched benchmark matrix (reproduced; `scripts/run_matrix.py`)

Systems on **shared storage** (per-vertex open-addressing hash adjacency + degree word, pre-sized):
`2pl` (strict 2PL, sorted per-vertex RW spinlocks), `stm` (TL2 word-STM), `stm-nodeg` (TL2 without degree
maintenance), `nontx` (lock-free CAS, no atomicity — synchronization lower bound, SlabGraph/faimGraph style).
GTX family (delta storage): `gtx` (ours: cooperative reservation + destination-precise conflicts),
`gtx-cons` (GTX-faithful: per-lane reservation + chain-granularity conflicts), `gtx-coop-only`, `gtx-dst-only`.
Batch baseline: `gpma-upstream` (GPMA+, pristine, CDP1), `gpma-port` (Windows port).

| matrix | scenarios | guarantee compared |
|---|---|---|
| `main` | uniform / hub-50% inserts at K = 1,2,4,8,32; uniform / R-MAT / Zipf churn; delete-only; identical-edge (64, 1024 hot edges); readers 50% (uniform, Zipf) and 90% (R-MAT) | SI for GTX; 2PL and STM are serializable (stronger); nontx none |
| `ser` | 40/30/30 insert/delete/read inside update txns: uniform, Zipf, hub-50% | serializable for all transactional systems |
| `ablation` | hub fraction 0 / 0.5 / 1.0 × K ∈ {1,8}; Zipf churn | GTX variants only |
| `check` | 65K-vertex versions of uniform / hub / Zipf with readers, all systems through the checker | SI / SER verified |
| GPMA+ | same insert/churn streams flattened into batches of 65,536 and 524,288 | batch-atomic only |

Metrics per run: kernel ms, committed txn/s, effective edge changes/s, aborts by cause, give-ups, update and
read-only latency p50/p95/p99, bytes used, checker verdict, validity flag.

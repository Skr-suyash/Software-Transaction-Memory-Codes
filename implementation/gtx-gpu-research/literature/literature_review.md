# Literature review (verified) — GPU dynamic graphs and transactional synchronization

Every number below was checked against the primary PDF (text extracted with PyMuPDF into `literature/text/`,
located by grep, read in context) unless marked **[not verified]**. Provenance per item: `source_manifest.csv`.
Literature numbers are *reference points*: different GPUs, datasets, timing boundaries and guarantees. They are never
used as head-to-head claims; matched local measurements are in `results/`.

## 1. The design space

| system | representation | update synchronization | transactions / consistent readers |
|---|---|---|---|
| GPMA (Sha et al.) | sorted packed memory array (PMA) of `(u,v)` keys, CSR-compatible | lock-based segment updates | none (batch-at-a-time) |
| GPMA+ (same) | same | **lock-free, segment-oriented**, sorted batch, bottom-up rebalancing | none |
| LPMA (Zou et al.) | leveled PMA (no global re-allocation) | GPMA+-style segment updates, bottom-up/top-down | none |
| Hornet (Busato et al.) | per-vertex arrays with power-of-two block allocator | batched, not sorted | none |
| faimGraph (Winter et al.) | per-vertex linked pages, GPU-side memory manager with reclamation | batched, warp-per-list | none |
| SlabGraph (Awad et al.) | per-vertex slab hash tables (SlabHash) | warp-cooperative, lock-free CAS | none |
| Meerkat (Concessao et al.) | SlabGraph + iterators | warp-cooperative | none |
| GPU-STM / PR-STM / CSMV | general word-based GPU STMs | locks / priority rules / client-server multi-version | yes, but graph-agnostic |
| GTX (Zhou et al., CPU) | edge-delta blocks + delta chains | latch-free, delta-chain lock bit, group commit | **SI** transactions + concurrent analytics |

Gap confirmed by every source: **no GPU dynamic-graph structure provides multi-edge transactions or snapshot reads
concurrent with updates**; GPU STMs provide transactions but not graph-aware conflict detection. That gap is what
the GTX-GPU design targets.

## 2. Verified evidence per baseline

### GPMA and GPMA+ (arXiv:1709.05061 v2; PVLDB 11(1) 2017) — mandatory, separate entries
* GPMA+ replaces GPMA's lock-based concurrent updates with "Lock-Free Segment-Oriented Updates" (§5).
* §6.2 / Fig. 7 (average update latency vs sliding batch size from 1 to 1M edges, base 2, log-log; datasets Reddit,
  Pokec, Graph500, Random): "GPMA achieves better performance than GPMA+ for small batches since the concurrent updating
  entries are unlikely to conflict, thread conflicts become serious for larger batches … GPMA+ has speedups of up to
  **20.42× and 18.30× against PMA and GPMA** respectively."
* Hardware: 3× GeForce TITAN X (12 GB), Intel i7-5820k, CUDA 7.5, GCC 4.8.4 (§6.1). Stinger on a 40-core Xeon.
* Consistency: none; readers are not concurrent with an update batch.
* Local artifact: `gpma_demo` (MIT) implements **GPMA+** (see `baselines/gpma/PORT_NOTES.md`).

### LPMA (Zou, Zhang, Lin, Yu; PKU preprint of the TKDE paper)
* §7.3 / Fig. 13: "When edges arrive in 10⁴ batches, LPMA-H has **6–9× speedups over GPMA+**. In 10⁵ batches,
  LPMA-H has **10–20×** speedups over GPMA+." Also: Hornet is faster than LPMA-H, GPMA+ and faimGraph at 10⁴ batches;
  "HashBased [Awad et al.] outperforms LPMA, Hornet and faimGraph significantly" on updates (LPMA wins on sorted queries).
* Hardware: Tesla P100 16 GB, Xeon E5-2640, CUDA 7.5. Artifact `github.com/pkumod/LPMA` reachable (HTTP 200).

### Hornet (HPEC 2018) — third-party measurements only
* Insertion rates from SlabGraph Table II (below) and LPMA Fig. 13. The Hornet paper's own tables (insertion,
  deletion, memory, adjacency query) are **[not verified]** — PDF not retrieved. Artifact reachable.

### faimGraph (SC18) — third-party measurements only
* Autonomous GPU memory management with full reclamation (abstract). Sorted/unsorted variants and memory reuse are
  described in the paper **[not verified numerically]**. SlabGraph: faimGraph page size set to 128 B; supports batches
  < 1M. Artifact `github.com/GPUPeople/faimGraph` reachable.

### SlabGraph (Awad, Ashkiani, Porumbescu, Owens; IPDPS 2020)
Table II, mean edge insertion rate (MEdge/s), TITAN V, **excluding CPU–GPU transfers**, averaged over the datasets of
Table I (road networks, Delaunay, RGG, coAuthorsDBLP, ldoor, soc-LiveJournal1, soc-orkut, hollywood-2009):

| batch | Hornet | faimGraph | SlabGraph |
|---:|---:|---:|---:|
| 2¹⁶ = 65,536 | 33.67 | 92.47 | 501.33 |
| 2¹⁹ = 524,288 | 70.81 | 188.98 | 641.25 |
| 2²² | 110.89 | — | 646.01 |
"Our speedup ranges between 5.8–14.8x compared to Hornet and 3.4–5.4x compared to faimGraph." Deletions (Table III)
at 2¹⁶: Hornet 91.73, faimGraph 111.71, SlabGraph 640.63 MEdge/s. Integration with Gunrock is part of the paper's
analytics section **[not re-verified here]**.

### Meerkat (arXiv:2305.17813 v1 2023-05-28 and v2 2023-06-02; journal version IJPP 2024 recorded separately)
* Both preprint versions: "Compared to … Hornet, Meerkat is **12.6×, 12.94×, and 6.1×** faster, for query, insert,
  and delete operations" (bulk operations); BFS 1.17×, SSSP 1.32×, PageRank 1.74×, WCC 6.08× on average.
* v2 adds: "Hornet performs on an average **31.12× (upto 59.34×) faster** than … Meerkat" on triangle counting.
* Hardware: RTX 2080 Ti. Built on SlabGraph. Journal version numbers **[not verified]**.

### GTX (arXiv:2405.01418 v2, SIGMOD 2025) — CPU reference for semantics
* Isolation: **snapshot isolation only** ("GTX supports Snapshot Isolation (SI) transactions", §5); no read-write
  conflict detection. Write-write detection: a lock bit in each delta-chains index entry, set by CAS; failure ⇒ abort
  (§6.1, "delta-chain granularity locking is a middle ground between vertex and edge locks").
* Global read/write epochs as in LiveGraph; hybrid group commit; lazy timestamp updates; consolidation of edge-delta
  blocks; cooperative GC.
* Results: "up to 2× and 11× higher transaction throughput than the best competitor in random order power-law graph
  edge insertions and in real-world timestamp-ordered power-law graph edge insertions"; with concurrent analytics up to
  5.3× (write-heavy) and 3.7× (balanced) higher update throughput; analytics 0.95×–2× slower than the best system.
  Competitors: LiveGraph, Teseo, Sortledton. Hardware: Xeon Platinum 8368 (38 cores per NUMA node).
* Artifact: `github.com/Jiboxiake/GTX-SIGMOD2025` (HTTP 200). Linux/x86 CPU system — not run here.

### GPU STMs
* GPU-STM (Xu et al., CGO 2014): word/lock-based, addresses false conflicts under lockstep execution.
* PR-STM (Shen et al., Euro-Par 2015): priority-rule contention management **[metadata only]**.
* CSMV (Nunes, Castro, Romano, IPDPS 2022): client-server, multi-versioned; "up to 3 orders of magnitude" speed-ups
  over GPU STMs (abstract) **[abstract only]**. Artifact `github.com/DMRNunes/csmv-gpu-stm`.
* Our STM baseline is TL2-style (global version clock, commit-time sorted locking, read-only transactions without read
  sets) — the canonical word-STM design point, applied to the graph without graph-aware conflict logic.

## 3. Artifact availability vs adoption (recorded independently)
| artifact | status 2026-09-28 | local use |
|---|---|---|
| gpma_demo (GPMA+) | 200 | built: Windows port and upstream-CDP1 (`bin/gpma_*.exe`) |
| LPMA | 200 | not built (Linux/CMake; future work) |
| Hornet | 200 | not built (paper-only comparison) |
| faimGraph | 200 | not built (paper-only comparison) |
| SlabHash / Meerkat | 200 / 200 | local Meerkat clone lacks the SlabHash submodule; not built (paper-only) |
| GTX-SIGMOD2025 | 200 | not built (CPU/Linux; semantics reference) |
| GPU_DGM (survey artifact) | **404** | — |
Adoption (production use) is not evidenced by any source for any of these systems; availability ≠ adoption.

# GTX-GPU: design, invariants, cost model, hypotheses

Scope: **atomic multi-edge transactions with concurrent readers** on a GPU-resident dynamic graph with a fixed vertex
set; edge insertion and deletion; separate **snapshot isolation (SI)** and **serializable (SER)** configurations.
Target: RTX 4060 Laptop GPU (Ada, sm_89, 24 SMs, 8 GB, WDDM), CUDA 12.8. Implementation: `src/gtxg.cuh`.

The architectural foundation is GTX (Zhou et al., arXiv:2405.01418v2): versioned edge deltas with creation /
invalidation timestamps, per-vertex edge-delta blocks, destination-hashed delta chains used for write-write conflict
detection, transaction descriptors resolved lazily by readers, group commit with global read/write epochs, and lazy
post-commit timestamp installation. GTX itself is a CPU system and provides **SI only** (§5 of the paper); the SER
mode below is an extension.

---------------------------------------------------------------------------------------------------------------------

## 1. Data layout

| structure | contents | notes |
|---|---|---|
| `Delta` (32 B) | `dstop` (dst:30, op:2 ∈ {INS, DEL, VOID}), `prev` (chain link), `owner` (txid, 0 = slot unwritten), `cts` (creation epoch once stamped, else 0), `its` (0, `TAG\|txid`, or invalidation epoch) | one arena, bump-allocated per block |
| `Block` (32 B) | `base, cap, nch, chBase, prevGen` | a **generation**; capacity grows `cap << growShift` (8×) |
| chain heads `H[]` | `idx:31 \| SEAL:1` | `nch = cap / chRatio` heads per generation (default one per slot) |
| `vcur[u]` | current generation (readers) | published *before* `vfill` |
| `vfill[u]` (64 bit) | `(generation << 32) \| slots reserved` | writers' reservation word |
| `desc[txid]` (64 bit) | `0 ACTIVE`, `1 ABORTED`, `(e<<2)\|2 COMMITTED at epoch e` | fresh per attempt |
| `E` (64 bit) | `(open epoch << 32) \| writers registered in it` | single word ⇒ wait-free registration |
| `done[2]`, `frontier` | completion counters (parity), published read epoch | advancer is one lane |

## 2. Operation semantics (per transaction T with snapshot `rts`)

A version of edge (u,v) is **visible to T** iff it was created by T, or its creator committed at epoch ≤ `rts`.
The *state* of (u,v) for T is the op of the newest visible version (INS ⇒ present), absent if none.

| op | semantics | result recorded |
|---|---|---|
| `begin` | `rts ← frontier` (acquire); `txid ←` fresh descriptor (ACTIVE) | — |
| `lookup(u,v)` | state for T; read-your-writes; missing edge ⇒ absent | present?, observed delta |
| `insert(u,v)` | if present: **no-op** (acts as a read); else append INS delta | effective? |
| `delete(u,v)` | if absent: **no-op** (acts as a read); else append DEL delta and set `its := TAG(T)` on the superseded INS | effective? |
| repeated ops | later ops see T's own earlier versions (newest own version decides) | — |
| `scan(u)` | all INS deltas of u visible to T and not invalidated by a version visible to T | degree, xor-hash |
| `commit` | SI: register epoch; SER: register epoch, **then** validate reads; publish `COMMITTED(e)`; stamp | cts |
| `abort` | publish `ABORTED`; no rollback (its deltas are invisible forever) | cause |
| resource exhaustion | arena / descriptor exhaustion ⇒ abort with `AB_RESOURCE`, transaction gives up | flag |

A committed deletion followed by a re-insertion is a new INS version (fixes prototype defect D1, `audit/`).

## 3. Algorithms

### 3.1 Write (insert/delete) — validate-then-CAS on the *same observed head*
```
reserveSlot(u) -> (g, slot)                       // §3.2
h0 := H[head(g,v)].load(acquire)
if h0.SEAL: void(slot); retry reservation         // generation g closed for this chain
r := walkGens(g, h0, v, seal=true)                // newest version of v, newest-first over g, g-1, ...
     // for each delta d with dst v:  owner==T -> found;  ABORTED -> skip;
     //   ACTIVE other -> abort(WW_PENDING);  committed > rts -> abort(WW_LATE);  committed <= rts -> found
     // older generations: seal their head for v (fetch_or SEAL) BEFORE walking them
decide effective/no-op from r (§2); no-op or abort => void(slot)
write delta {dstop, prev = h0, owner = T}
loop: if CAS(H[head(g,v)], h0 -> slot) (acq_rel): success
      h1 := observed; if h1.SEAL: void(slot); retry reservation
      walk only the new prefix h1 .. h0 for v: any non-aborted foreign version => void(slot); abort
      prev := h1; h0 := h1
if DEL: its(superseded) := TAG(T)
```
`dstconf=0` (GTX-faithful): additionally, the chain's newest non-aborted delta (any destination) must be visible to T,
else abort (`AB_CHAIN_FALSE` when it belongs to another destination). This is GTX's chain-granularity rule.

### 3.2 Cooperative reservation and block generations (Method 1)
```
key := u (lanes needing a slot); grp := __match_any_sync(FULL, key)
leader: w := vfill[u].fetch_add(popc(grp), acq_rel)     // one RMW per (warp, vertex)
w broadcast; s := low(w) + rank(lane in grp); g := high(w)
if g == NONE and s == 0  -> allocBlock(u, NONE)         // unique creator of the first generation
elif s <  cap(g)         -> slot = base(g) + s
elif s == cap(g)         -> allocBlock(u, g)            // unique grower of g
else                     -> wait (nanosleep), retry
allocBlock(u, old): B[new] := {base, cap<<3, nch, chBase, prevGen=old}; fence;
                    vcur[u] := new (release); vfill[u] := (new<<32)|0 (release)
```
`coop=0` performs one `fetch_add` per lane. Old generations are never copied: their chain heads are sealed lazily by
the first writer of the newer generation that walks them.

### 3.3 Commit with epochs (Method 3, conservative reference)
```
writers := lanes alive with >=1 effective write
SER: e := register(writers)      // leader: e = E.fetch_add(popc, acq_rel) >> 32  -- BEFORE validation
     validate point reads: newest non-aborted foreign version of (u,v) must be the observed one
     validate scans: every foreign, non-aborted delta of u must be visible at rts and not invalidated by a
                     non-aborted foreign txn (phantom / predicate check)
SI:  e := register(writers)      // after the op loop, no validation
read-only (no effective write): commit at cts = rts, descriptor := ABORTED (owns no live delta), no registration
fence; desc[T] := alive ? COMMITTED(e) : ABORTED; __syncwarp; leader: fence; done[e&1] += popc(writers)
stamp: cts(own deltas) := e; its(superseded) := e
advancer (one lane): loop { e := E.hi; reg := E.exchange((e+1)<<32).lo;
                            wait done[e&1] == reg; done[e&1] := 0; frontier := e (release) }
```

### 3.4 Reads
`lookup` walks the chain(s) of v from `vcur[u]` newest-first and returns the first version visible to T.
`scan` visits every slot `[0, min(fill, cap))` of every generation (warp-cooperative: 32 lanes stride one vertex).
Readers never write shared state and never wait.

## 4. Invariants (checked by the history checker, `src/checker.hpp`)

* **I1 single writer per chain position:** for every key, non-aborted versions are totally ordered by chain position,
  and that order equals commit-epoch order. (Install requires the newest non-aborted version to be T's own or
  committed ≤ rts; CAS on the same observed head; prefix re-walk on CAS failure.)
* **I2 generation monotonicity:** if any version of v exists in generation g+1, the head of v's chain in every older
  generation is sealed; hence every install into g precedes every install into g+1 for the same key.
* **I3 frontier safety:** `frontier ≥ e` ⇒ every writer registered in epoch e has published its final descriptor.
  (Registration and the advancer's close are RMWs on one word; the advancer waits for the exact registered count.)
* **I4 no torn visibility:** a transaction's versions become visible to a snapshot all-or-nothing, because
  visibility is decided solely by its descriptor/epoch and snapshots only cover completed epochs.
* **I5 SER ordering (Silo order):** a writer's epoch is fixed before its read validation, so every dependency
  edge (ww, wr, rw) is non-decreasing in commit epoch; a frontier snapshot is therefore a dependency-closed prefix
  and read-only transactions serialize at `rts` without validation.
* **I6 slot publication:** every reserved slot is written exactly once by its reserver (content, then VOID if it
  was not installed); a slot is linked into a chain at most once.

### Memory-order requirements (all confirmed necessary by failures or by the model)
| edge | requirement |
|---|---|
| grower: `B[new]` → `vcur` → `vfill` | release stores; **reservation `fetch_add` must be acq_rel** so a committed writer carries happens-before to the generation link |
| delta contents → chain head | head CAS acq_rel (release sequence covers later readers of the head) |
| delta `owner`/content → scanners | relaxed is sufficient: scanners use a delta only once its creator is visible, and visibility is established through `desc` (acquire) / `frontier` (acquire) |
| txn writes → `desc` → `done` → `frontier` | fence; relaxed desc store; `__syncwarp`; leader fence; `done` RMW; advancer acquire load; frontier release |

## 5. Progress assumptions
* Writers are **lock-free** per operation: CAS failures imply another install succeeded; waits occur only for a
  generation grower (a single bounded `allocBlock`) and are bounded by that lane's progress (Volta+ independent
  thread scheduling).
* Aborts are **no-wait** (first-updater-wins); livelock is possible in principle under identical-edge contention and is
  mitigated by randomized exponential backoff; transactions give up after `maxAttempts` (reported, never silent).
* Commit registration is **wait-free** (one RMW). The first design (read E, increment, re-read, retry) livelocked for
  seconds when the advancer ran at ~1 epoch/µs; it was replaced (see `results/defect_log.md`).
* The advancer waits for registered committers; a committer that registered in SER mode holds the epoch open for the
  duration of its validation (frontier staleness = longest validation).

## 6. Cost model (per effective write, uncontended)

| step | dependent global round trips | atomics |
|---|---|---|
| reservation | 1 RMW on `vfill[u]` (+1 load of `B[g]`) | 1 per (warp, vertex) with coop, 1 per lane without |
| head observe + walk | 1 + chain length (≈ 1 with `chRatio=1`) + 1 per older generation | seal RMW once per (older gen, chain) |
| install | 1 CAS | 1 |
| commit | per warp: 1 RMW on `E`, 1 RMW on `done`; per lane: 1 desc store, stamps | 2 per warp |
Scan cost is Θ(slots in all generations) — including aborted and voided slots until reclamation (Method 4).
Memory: 32 B per delta + 4 B per chain head + 8 B per attempt descriptor; aborted/voided deltas are not reclaimed yet.

## 7. Methods, hypotheses, and falsification experiments

### M1 Cooperative delta allocation
*Hypothesis:* aggregating reservations of lanes that target the same vertex into one RMW reduces allocator contention
when many transactions append to one hub. *Prior art:* warp-aggregated atomics (NVIDIA), SlabHash warp-cooperative
work sharing, Meerkat. *Predicted bottleneck:* the same-address RMW throughput at the L2 slice owning `vfill[hub]`.
*Falsified if* `gtx` vs `gtx-dst-only` (identical except `coop`) shows < 10% throughput gain on the 50% and 100% hub
insert workloads at K ∈ {1, 8}, or a loss on uniform. *Status:* **falsified as a primary mechanism.** Measured gains
(`results/summary.md`, `abl-*`): 50% hub K=1 +8.6%, K=8 +11.0%; 100% hub K=1 +6.0%, K=8 +5.8%; uniform K=8 +3.4%;
Zipf churn +0.3%. Three of four hub cells are below the 10% threshold: same-address RMWs on Ada's L2 are not the hub
bottleneck (consistent with the earlier 61 Gops/s single-counter microbenchmark). Kept as a small, never-negative win.

### M1b Destination-precise conflict detection (added during this work)
*Hypothesis:* GTX's chain-granularity rule (abort if the chain's newest live delta is not visible, whatever its destination)
causes false aborts that grow with transaction size; checking only versions of the same destination, with validate-then-CAS
on the same observed head and prefix re-walk, removes them without weakening SI/SER. *Falsified if* `gtx` vs `gtx-coop-only` shows
< 10% gain at K ≥ 8 or any checker failure. *Status:* **supported** — abort ratio 8.5% → 0 (uniform K=8) and 45.4% → 0 (K=32).
Throughput: uniform K=8 ×1.14 vs `gtx-coop-only` (the isolated effect); uniform K=32 ×1.80 and 50%-hub K=32 ×1.33 vs
`gtx-cons` (coop-only was not run at K=32; cooperative allocation alone contributes ≤ 3.4% on uniform); all checks pass.

### M2 Separating allocation contention from conflict detection (multiple reservation regions)
*Hypothesis:* splitting a hub's reservation counter into R regions removes the single-address RMW hot spot, while
destination-hashed chains keep conflict detection exact. *Prediction:* benefit only if M1's measurement shows the
`vfill` RMW is on the critical path; costs R× scan fragmentation and R× partially-filled blocks.
*Falsified if* R ∈ {2,4,8} gives < 10% gain on 100% hub inserts or > 10% scan slowdown. *Status:* specified, not
implemented. Because M1 showed the reservation RMW is not on the critical path, the predicted gain is small; ranked low.

### M3 GPU commit groups with explicit visibility
Implemented as §3.3. *Hypothesis:* per-warp epoch registration makes commit cost O(1) RMW per warp and lets readers
take snapshots with a single acquire load. *Falsified if* commit exceeds 25% of the in-kernel cycle profile for K=1
inserts, or if any checker run (C1–C5) fails. Serializable validation of intra-group dependencies, absent-edge reads
and adjacency predicates is conservative (§3.3) and verified by C5 on adversarial histories, including a write-skew
probe that must produce cycles under SI and none under SER. *Status:* **not falsified** — commit is 9.6% (4M-edge
initial graph) to 15.5% (empty graph) of the lane-cycle profile for uniform K=1 inserts, and every checked history
passes. Two protocol defects were found and fixed on the way (registration livelock D5, epoch-after-validation D6).

### M4 Consolidation and reclamation by block generation
*Specification:* a generation g becomes *reclaimable* when (a) it is sealed for all chains, (b) every delta in it is
superseded by a version committed at epoch ≤ `minActiveRts` or aborted/voided, and (c) no reader with
`rts < retireEpoch(g)` is active. Protection is aggregated per generation (one retire epoch per block) instead of
per-delta hazard tracking. Consolidation copies the live latest versions of the k newest generations into a fresh
generation under the same reservation/sealing protocol. *Backpressure:* if `minActiveRts` lags the frontier by more
than a bound, new long scans are delayed and writers that would allocate beyond an arena watermark abort with
`AB_RESOURCE`. *Hypothesis:* per-generation protection needs O(#generations) metadata instead of O(#deltas).
*Falsified if* reclamation of churn workloads costs > 20% throughput or any snapshot read changes result.
*Status:* specified, not implemented; the current prototype never reclaims (memory grows with aborted attempts —
visible in the `tiny-arena` test and in SER hub stress runs).

## 8. What is claimed, and what is not
* Claimed only with local, matched measurements on the same workload streams and seeds (`results/`).
* Literature numbers are reference points, never head-to-head claims (different GPUs, datasets, guarantees).
* The prototype does not implement vertex insertion/deletion, reclamation (M4), multiple regions (M2), durability,
  or descriptor reuse (descriptors are fresh per attempt; reuse would require generation-tagged ids).

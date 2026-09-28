# Prototype correctness audit (gpu-stm-dynamic-graphs/, loop iterations 12–31b)

Scope: the transactional GPU prototype recorded in `gpu-stm-dynamic-graphs/loop_log.md` and `solutions.md`, and its
GPMA baseline. Each finding gives the code location, a concrete counterexample history, the consequence, and how
the new implementation (`gtx-gpu-research/src/gtxg.cuh`) and the checker (`src/checker.hpp`) address it.
Notation: `T:INS(u,v)` etc.; `cts=e` commit epoch; `[k]` = step order.

## D1 — Insert treats a committed deletion as an already-present edge (loop_iter31b.cu:136–145)
```cpp
int hd = pool[h[k]].headVer;               // newest version of the edge anchor
... int ost = desc[vpool[hd].txid];
else if (ost == COMMITTED) {
  if (aop[k] == 0) { needInstall = false; break; }  // INSERT on committed head: "idempotent", no write
```
The head's *operation* (`vpool[hd].op`) is never inspected. Counterexample (any interleaving, even sequential):
```
[1] T1: INS(3,7) commits      head = v1{op=INS, T1 COMMITTED}
[2] T2: DEL(3,7) commits      head = v2{op=DEL, T2 COMMITTED}
[3] T3: INS(3,7)              sees head COMMITTED -> needInstall=false -> commits as a no-op
final: (3,7) absent.   Sequential semantics: present.
```
The same line lets `DEL` install a second delete over a committed delete (double delete counted as effective).
iter29's duplicate suppression has the same shape: any COMMITTED slot with the same key aborts the inserter
(`if(st==COMMITTED || ...) dup=true`), so once deletes exist a deleted edge can never be re-inserted.
*New implementation:* the state is the **op of the newest visible version** (§2 of the design); covered by the
`churn-V64-K8` and `identical-edge-8` histories (delete/re-insert inside and across transactions) under check C1.

## D2 — Head validation and installation use different observed heads (loop_iter31b.cu:134 vs 166–169)
```cpp
int hd  = pool[h[k]].headVer;   // (a) validated: owner state, wound decision
...
int cur = pool[h[k]].headVer;   // (b) re-read, NOT validated
vpool[vnew].prev = cur;
if (atomicCAS(&pool[h[k]].headVer, cur, vnew) == cur) break;   // installs over whatever (b) saw
```
Counterexample (lost update between two deletes):
```
[1] T1 reads (a) hd = v1{INS, committed}      -> may install DEL
[2] T2 reads (a) hd = v1                       -> may install DEL
[3] T2 (b) cur = v1, CAS v1 -> v2{DEL,T2}      succeeds; T2 commits
[4] T1 (b) cur = v2, CAS v2 -> v3{DEL,T1}      succeeds (v2 never validated); T1 commits
both deletes report "effective"; with an INS in place of T2 the result is an insert overwritten by a delete that
never observed it (write-write conflict undetected, i.e. lost update under SI).
```
A pending (uncommitted) version can likewise be buried under another writer's version, giving two concurrent
writers of one key. *New implementation:* validate-then-CAS on the **same** observed head `h0`; on CAS failure only
the new prefix `h1..h0` is re-walked and any non-aborted foreign version of the key aborts the writer (design §3.1,
invariant I1); checked by C3 (no two writers of a key with overlapping [rts,cts) or equal cts) and by mutation
test `mut1-no-ww-check`, which the checker must (and does) reject.

## D3 — The descriptor-swap demo lacks a publication and reader-validation argument (loop_iter22.cu)
1. The seqlock is advanced **before** the linearization point: `vcur[i] = txid; ... desc[txid] = COMMITTED`.
   A reader sampling `t0 = vcur` *after* the advance reads B's killer descriptor (PENDING ⇒ B live), then the commit
   happens, then it reads C's descriptor (COMMITTED ⇒ C live) and `t1 == t0`: it accepts the forbidden state (1,1).
   Correct behaviour relies on the window being short, not on the protocol.
2. `homeFill[i]++` is a plain read-modify-write shared with readers' plain loads (data race; readers may skip C).
3. After round 0 of each vertex, B is dead forever, so the assertion `(bLive XOR cLive)` reduces to "some C is
   committed" — 19 of 20 rounds cannot detect a violation. 507,744 clean samples therefore test ~256 swaps.
4. The reader decides B and C from **two different descriptor reads**; atomic visibility requires a single
   visibility decision per transaction (a snapshot epoch).
*New implementation:* no seqlock; visibility is decided by the creator's commit epoch against the reader's snapshot
(`frontier`), and the frontier covers an epoch only after every writer registered in it has published (invariant I3).

## D4 — Final-state agreement cannot establish SI or serializability
Every prototype verification (iters 13, 15, 21, 23, 26, 29, 31b) compares the final edge set with the committed log.
Histories that violate SI can still agree with their own commit log. Measured directly (`src/test_gtx.cu` section C,
output in `results/mutation_final_state.txt`), applying the prototype's check — replay the operations the device
*reported* as effective, in commit order, and compare with the final edge set — to deliberately broken protocols:

| mutation | prototype log-vs-final check | new checker |
|---|---|---|
| `mut1` no write-write check (lost updates) | **0 missing, 0 extra — passes** | C3: 4,386 overlapping writers + 10,984 same-epoch writers; C1: 511 wrong reads; C5: 6,557 back edges |
| `mut3` readers ignore their snapshot | **0 missing, 0 extra — passes** | C1: 9,658 wrong reads + 5,382 wrong scans; C4 (model replay): 1,980 missing |
| `mut2` readers see uncommitted versions | 1,133 missing, 340 extra — detected | C1: 11,411 + 6,972; C5: 271,175 back edges |

A write-skew workload also commits with a log-consistent final state under SI while the serialization graph has
16,000 back edges (C5). Final-state agreement with the log is therefore not evidence of isolation.
*New checker:* C1 read rule per operation against `S(rts)` + own writes (including scans via degree+hash),
C2 point-observation identity, C3 write-write, C4 final state, C5 Adya DSG acyclicity (SER).

## D5 — Commit-epoch registration livelock (found in the new implementation, fixed)
Initial GTX-GPU commit: `e = E; inflight[e&1]++; if (E != e) { inflight[e&1]--; retry; }`. The advancer increments
`E` about once per microsecond, comparable to the three-RMW window, so a committer could lose the race for seconds
(observed: kernels of 1.5 s, 7.6 s and 20 s where 1 ms was expected; watchdog flag = advancer). Fixed by
**wait-free registration** on a single `(epoch, count)` word (design §3.3).

## D6 — Serializable validation before choosing the commit epoch (found, fixed)
With the epoch taken after validation, a writer U that overwrites something T read can register before T, so the
rw edge T→U runs backwards in commit order and a snapshot reader can observe U without T (read-only anomaly).
The checker reported DSG cycles (C5) once read-only transactions were allowed to skip validation. Fixed by fixing the
epoch before validation (Silo order, invariant I5).

## D7 — Read-only commit at cts = rts exposed voided slots (found, fixed)
A transaction with no effective writes may still own reserved-then-voided slots. Publishing COMMITTED(rts) made those
slots "committed in the past" for concurrent scanners that could still read the pre-void opcode. Fixed: a read-only
commit publishes `ABORTED` (it owns no live version); it is recorded as committed at `rts`.

## D8 — Missing happens-before from generation growth to committed writers (found, fixed)
Reservation `fetch_add` on `vfill` was relaxed, so it did not synchronize with the grower's release of the new
generation; a scanner whose snapshot covers a delta could load a stale `vcur` and skip the generation. Fixed with an
acq_rel reservation RMW (design §4, memory-order table).

## D9 — Harness watchdog published the frontier early (found, fixed)
A diagnostic deadline in the advancer broke out of the completion wait and published the frontier; after ~20 s runs,
snapshot reads missed committed writers (checker C1, decision code "ACTIVE" for a writer committed below the reader's
snapshot). Fixed: the deadline only raises a flag; at 2× deadline the run is declared INVALID (flag 16) and stops.

## GPMA baseline audit (see `baselines/gpma/PORT_NOTES.md`)
* The local "GPMA" is **GPMA+** (`update_gpma` = sorted, segment-oriented, lock-free rebalancing).
* The Windows port turns the dynamic-parallelism rebalancing of large segments into a **sequential host loop** with
  per-node D2H copies. Earlier speedups "vs GPMA" (`loop_log.md` iters 25–27) were measured against that port.
  This package measures port and upstream-CDP1 separately.
* Endpoint bounds: `baselines/bench_gpma.cu` generated `v ∈ [1, 100000]` with `V = 8192` rows, and the transactional
  runs used distinct `v = i+1`; the two streams differed (duplicates only on the GPMA side). The new harness uses one
  generator (`src/workload.hpp`) with `u, v ∈ [0, V)` for every system.
* Attempted vs effective updates: the new harness reports both (`txn_per_s` counts committed transactions,
  `eff_per_s` counts edges whose presence actually changed).

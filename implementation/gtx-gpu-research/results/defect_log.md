# Defect log — protocol defects found by the history checker / stress tests during development

Each entry: symptom (how it was detected), root cause, fix, and the evidence that the fix holds. Details and
counterexample histories: `audit/prototype_audit.md` (D5–D9). All were found **before** any benchmark in
`results/summary.md` was recorded; every benchmarked configuration passes the correctness gate afterwards.

| id | detected by | symptom | root cause | fix | evidence after fix |
|---|---|---|---|---|---|
| D5 | multi-rep stress (180 reps) + watchdog flag | 1 in ~30 kernels took 1.5–20 s instead of ~1 ms; flag = advancer | commit read `E`, incremented in-flight, re-read `E` and retried; advancer bumps `E` ~1/µs ⇒ committer starves | wait-free registration: one `fetch_add` on `(epoch<<32 \| count)`; advancer closes an epoch with one `exchange` and waits for exactly that many completions | 180/180 reps in 0.15–1.0 ms, max/median ≤ 1.5 |
| D6 | checker C5 (serialization graph) | 5 SER histories with 1–40,535 DSG back edges once read-only txns skipped validation | epoch fixed *after* read validation ⇒ rw edge T→U can run backwards in commit order ⇒ read-only anomaly | Silo order: register epoch before validation | 0 cycles in all SER histories (suite A, write-skew probe, check matrix) |
| D7 | reasoning during D6 fix (C1 risk) | read-only commit at cts=rts would make its voided slots "committed in the past" | a txn with no effective writes may own reserved-then-voided slots | read-only commit publishes ABORTED descriptor (owns no live delta) | suite A and check matrix PASS |
| D8 | forensic scan instrumentation | (model) stale `vcur` could skip a generation holding a committed delta | reservation `fetch_add` on `vfill` was relaxed: no happens-before with the grower's release of the generation | reservation RMW is acq_rel | memory-order argument (design §4); suite PASS |
| D9 | checker C1 + forensic decision codes | SER per-lane-scan runs: scans missed/added one committed edge; decision code "creator ACTIVE" for a writer committed below the reader's snapshot | harness watchdog broke out of the advancer's completion wait after 20 s and published the frontier early (these runs take ~40 s) | watchdog only flags; at 2× deadline the run is declared INVALID (flag 16) and publishing stops; watchdog also ends retries | 4/4 stress iterations PASS; suite A (48 histories) PASS |

Lesson recorded in the design (§5): a diagnostic mechanism must never trade safety for liveness; the checker found
that one within one iteration because it validates reads operation by operation instead of comparing final states.

# GPMA+ vs transactional systems on identical streams (effective edge changes per second)

GPMA+ applies each batch as one sorted unit (no multi-edge transactions, no concurrent readers, intra-batch INS/DEL order not preserved). Transactional systems commit every operation as its own transaction (K=1). Times are GPU operation time only.

| stream | system | batch | median ms | effective edges/s | final-state verify | GTX-GPU speedup |
|---|---|---:|---:|---:|---|---:|
| hub50-ins-K1 | GPMA+ (Windows port) | 65536 | 69.49 | 8.43 M | FAIL | 16.0x |
| hub50-ins-K1 | GPMA+ (Windows port) | 524288 | 56.05 | 10.45 M | FAIL | 12.9x |
| hub50-ins-K1 | GPMA+ (upstream, CDP1) | 65536 | 70.70 | 8.29 M | FAIL | 16.3x |
| hub50-ins-K1 | GPMA+ (upstream, CDP1) | 524288 | 56.57 | 10.35 M | FAIL | 13.0x |
| hub50-ins-K1 | GTX-GPU (ours) | txn | 4.35 | 134.66 M | - | |
| hub50-ins-K1 | GTX-conservative port | txn | 4.67 | 125.50 M | - | |
| hub50-ins-K1 | TL2 word-STM | txn | 513.00 | 1.03 M | - | |
| hub50-ins-K1 | TL2 word-STM (no degree) | txn | 3.31 | 176.83 M | - | |
| hub50-ins-K1 | non-transactional CAS | txn | 1.97 | 297.78 M | - | |
| rmat-churn-K1 | GPMA+ (Windows port) | 65536 | 66.43 | 15.32 M | FAIL | 9.4x |
| rmat-churn-K1 | GPMA+ (Windows port) | 524288 | 53.45 | 19.04 M | FAIL | 7.6x |
| rmat-churn-K1 | GPMA+ (upstream, CDP1) | 65536 | 66.64 | 15.27 M | FAIL | 9.4x |
| rmat-churn-K1 | GPMA+ (upstream, CDP1) | 524288 | 53.81 | 18.92 M | FAIL | 7.6x |
| rmat-churn-K1 | GTX-GPU (ours) | txn | 7.07 | 143.82 M | - | |
| rmat-churn-K1 | GTX-conservative port | txn | 7.04 | 144.45 M | - | |
| rmat-churn-K1 | 2PL vertex locks | txn | 71.44 | 14.24 M | - | |
| rmat-churn-K1 | TL2 word-STM | txn | 282.93 | 3.56 M | - | |
| rmat-churn-K1 | TL2 word-STM (no degree) | txn | 4.90 | 207.72 M | - | |
| rmat-churn-K1 | non-transactional CAS | txn | 2.04 | 498.63 M | - | |
| uniform-churn-K1 | GPMA+ (Windows port) | 65536 | 66.73 | 15.26 M | FAIL | 10.2x |
| uniform-churn-K1 | GPMA+ (Windows port) | 524288 | 56.65 | 17.98 M | FAIL | 8.7x |
| uniform-churn-K1 | GPMA+ (upstream, CDP1) | 65536 | 66.16 | 15.39 M | FAIL | 10.1x |
| uniform-churn-K1 | GPMA+ (upstream, CDP1) | 524288 | 56.33 | 18.08 M | FAIL | 8.6x |
| uniform-churn-K1 | GTX-GPU (ours) | txn | 6.54 | 155.68 M | - | |
| uniform-churn-K1 | GTX-conservative port | txn | 6.62 | 153.83 M | - | |
| uniform-churn-K1 | 2PL vertex locks | txn | 3.43 | 296.57 M | - | |
| uniform-churn-K1 | TL2 word-STM | txn | 6.63 | 153.43 M | - | |
| uniform-churn-K1 | TL2 word-STM (no degree) | txn | 3.99 | 254.86 M | - | |
| uniform-churn-K1 | non-transactional CAS | txn | 2.42 | 419.84 M | - | |
| uniform-ins-K1 | GPMA+ (Windows port) | 65536 | 116.12 | 9.03 M | PASS | 20.1x |
| uniform-ins-K1 | GPMA+ (Windows port) | 524288 | 83.15 | 12.61 M | PASS | 14.4x |
| uniform-ins-K1 | GPMA+ (upstream, CDP1) | 65536 | 117.28 | 8.94 M | PASS | 20.3x |
| uniform-ins-K1 | GPMA+ (upstream, CDP1) | 524288 | 84.63 | 12.39 M | PASS | 14.6x |
| uniform-ins-K1 | GTX-GPU (ours) | txn | 5.78 | 181.40 M | - | |
| uniform-ins-K1 | GTX-conservative port | txn | 5.99 | 174.98 M | - | |
| uniform-ins-K1 | 2PL vertex locks | txn | 3.05 | 343.28 M | - | |
| uniform-ins-K1 | TL2 word-STM | txn | 6.60 | 158.81 M | - | |
| uniform-ins-K1 | TL2 word-STM (no degree) | txn | 3.96 | 264.60 M | - | |
| uniform-ins-K1 | non-transactional CAS | txn | 2.35 | 446.96 M | - | |

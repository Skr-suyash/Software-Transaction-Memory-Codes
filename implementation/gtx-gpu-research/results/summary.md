# Benchmark summary (RTX 4060 Laptop, CUDA 12.8; medians over repetitions)

Speedup = GTX-GPU committed-transaction throughput / baseline committed-transaction throughput (>1: GTX-GPU faster; medians over repetitions); 95% bootstrap CI in brackets; '>x' = lower bound for runs that did not finish within the timeout.

## SER-hub50-rw-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.879 | 44.59 M | 93.08 M | 0.034 | 0 | 924 | 382 | - | — |
| GTX-conservative port | 5.888 | 44.52 M | 92.93 M | 0.044 | 0 | 939 | 381 | - | 1.00 [0.87, 1.16] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >15309 |
| TL2 word-STM | 1115.195 | 0.14 M | 0.25 M | 1.000 | 105286 | 186281 | 342 | - | 317.03 [274.43, 433.87] |
| TL2 word-STM (no degree) | 5.168 | 50.72 M | 105.76 M | 0.090 | 0 | 1233 | 656 | - | 0.88 [0.76, 0.90] |

## SER-uniform-rw-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.696 | 46.03 M | 126.72 M | 0.013 | 0 | 602 | 372 | - | — |
| GTX-conservative port | 6.277 | 41.76 M | 114.98 M | 0.025 | 0 | 942 | 910 | - | 1.10 [0.98, 1.12] |
| 2PL vertex locks | 3.537 | 74.12 M | 203.97 M | 0.000 | 0 | 742 | 830 | - | 0.62 [0.57, 0.81] |
| TL2 word-STM | 12.860 | 20.38 M | 56.08 M | 0.323 | 0 | 4257 | 1434 | - | 2.26 [2.00, 2.30] |
| TL2 word-STM (no degree) | 6.776 | 38.69 M | 106.47 M | 0.106 | 0 | 1945 | 1155 | - | 1.19 [0.92, 1.21] |

## SER-zipf-rw-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 9.051 | 28.96 M | 78.50 M | 0.016 | 0 | 973 | 870 | - | — |
| GTX-conservative port | 9.179 | 28.56 M | 77.40 M | 0.029 | 0 | 1336 | 934 | - | 1.01 [0.92, 1.08] |
| 2PL vertex locks | 13315.141 | 0.02 M | 0.05 M | 0.000 | 0 | 13190267 | 13219443 | - | 1471.11 [1394.43, 1544.20] |
| TL2 word-STM | 1138.572 | 0.15 M | 0.37 M | 1.000 | 94617 | 337394 | 397 | - | 196.87 [186.61, 262.18] |
| TL2 word-STM (no degree) | 5.834 | 44.94 M | 121.72 M | 0.119 | 0 | 1656 | 873 | - | 0.64 [0.61, 0.75] |

## SI-hub50-rw-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.195 | 50.46 M | 105.17 M | 0.019 | 0 | 841 | 830 | - | — |
| GTX-conservative port | 4.703 | 55.74 M | 116.16 M | 0.027 | 0 | 719 | 315 | - | 0.91 [0.90, 1.01] |

## SI-uniform-rw-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.150 | 50.90 M | 140.10 M | 0.011 | 0 | 374 | 342 | - | — |
| GTX-conservative port | 5.761 | 45.50 M | 125.23 M | 0.021 | 0 | 855 | 820 | - | 1.12 [0.91, 1.19] |

## SI-zipf-rw-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.537 | 34.78 M | 94.22 M | 0.011 | 0 | 826 | 808 | - | — |
| GTX-conservative port | 7.019 | 37.35 M | 101.16 M | 0.022 | 0 | 1060 | 434 | - | 0.93 [0.86, 1.05] |

## abl-hub0-ins-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.315 | 197.30 M | 197.30 M | 0.000 | 0 | 110 | 0 | - | — |
| GTX-conservative port | 5.714 | 183.51 M | 183.51 M | 0.002 | 0 | 449 | 0 | - | 1.08 [0.91, 1.19] |
| GTX coop only | 5.762 | 181.98 M | 181.98 M | 0.002 | 0 | 447 | 0 | - | 1.08 [0.91, 1.19] |
| GTX dst-conflicts only | 5.333 | 196.62 M | 196.62 M | 0.000 | 0 | 110 | 0 | - | 1.00 [0.85, 1.18] |

## abl-hub0-ins-K8

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 6.362 | 20.60 M | 164.82 M | 0.000 | 0 | 1171 | 0 | - | — |
| GTX-conservative port | 7.600 | 17.25 M | 137.97 M | 0.085 | 0 | 2785 | 0 | - | 1.19 [0.96, 1.26] |
| GTX coop only | 7.222 | 18.15 M | 145.19 M | 0.085 | 0 | 2068 | 0 | - | 1.14 [0.97, 1.27] |
| GTX dst-conflicts only | 6.577 | 19.93 M | 159.43 M | 0.000 | 0 | 1338 | 0 | - | 1.03 [0.86, 1.15] |

## abl-hub0.5-ins-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.308 | 243.40 M | 135.97 M | 0.000 | 0 | 92 | 0 | - | — |
| GTX-conservative port | 4.623 | 226.80 M | 126.70 M | 0.001 | 0 | 116 | 0 | - | 1.07 [1.06, 1.29] |
| GTX coop only | 4.276 | 245.21 M | 136.98 M | 0.001 | 0 | 91 | 0 | - | 0.99 [0.98, 1.21] |
| GTX dst-conflicts only | 4.677 | 224.22 M | 125.26 M | 0.000 | 0 | 113 | 0 | - | 1.09 [1.07, 1.17] |

## abl-hub0.5-ins-K8

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.581 | 28.61 M | 127.93 M | 0.027 | 0 | 1357 | 0 | - | — |
| GTX-conservative port | 5.331 | 24.59 M | 109.94 M | 0.065 | 0 | 1610 | 0 | - | 1.16 [0.97, 1.17] |
| GTX coop only | 4.779 | 27.43 M | 122.64 M | 0.064 | 0 | 1435 | 0 | - | 1.04 [0.87, 1.06] |
| GTX dst-conflicts only | 5.083 | 25.79 M | 115.30 M | 0.028 | 0 | 1536 | 0 | - | 1.11 [0.92, 1.14] |

## abl-hub1.0-ins-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 2.506 | 418.47 M | 5.79 M | 0.000 | 0 | 58 | 0 | - | — |
| GTX-conservative port | 2.603 | 402.83 M | 5.57 M | 0.000 | 0 | 68 | 0 | - | 1.04 [0.76, 1.41] |
| GTX coop only | 2.445 | 428.81 M | 5.93 M | 0.000 | 0 | 57 | 0 | - | 0.98 [0.71, 1.35] |
| GTX dst-conflicts only | 2.656 | 394.76 M | 5.46 M | 0.000 | 0 | 72 | 0 | - | 1.06 [0.77, 1.21] |

## abl-hub1.0-ins-K8

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 2.486 | 52.72 M | 5.88 M | 0.014 | 0 | 496 | 0 | - | — |
| GTX-conservative port | 2.592 | 50.57 M | 5.64 M | 0.020 | 0 | 592 | 0 | - | 1.04 [0.77, 1.26] |
| GTX coop only | 2.425 | 54.05 M | 6.02 M | 0.020 | 0 | 546 | 0 | - | 0.98 [0.72, 1.20] |
| GTX dst-conflicts only | 2.631 | 49.82 M | 5.55 M | 0.014 | 0 | 526 | 0 | - | 1.06 [0.78, 1.42] |

## abl-zipf-churn-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.202 | 36.40 M | 139.28 M | 0.024 | 0 | 1106 | 0 | - | — |
| GTX-conservative port | 7.624 | 34.39 M | 131.56 M | 0.044 | 0 | 1170 | 0 | - | 1.06 [0.94, 1.13] |
| GTX coop only | 7.596 | 34.51 M | 132.04 M | 0.044 | 0 | 1154 | 0 | - | 1.05 [0.94, 1.06] |
| GTX dst-conflicts only | 7.226 | 36.28 M | 138.80 M | 0.024 | 0 | 1110 | 0 | - | 1.00 [0.89, 1.08] |

## check-SER-hub50

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 91.785 | 0.71 M | 1.31 M | 0.407 | 0 | 59238 | 45860 | PASS | — |
| GTX-conservative port | 101.807 | 0.64 M | 1.18 M | 0.437 | 0 | 61932 | 44170 | PASS | 1.11 [1.11, 1.11] |
| 2PL vertex locks | 5458.538 | 0.01 M | 0.02 M | 0.000 | 0 | 5442211 | 5381800 | PASS | 59.47 [59.47, 59.47] |
| TL2 word-STM | 1310.946 | 0.03 M | 0.04 M | 1.000 | 25272 | 552014 | 1106111 | PASS | 23.25 [23.25, 23.25] |
| TL2 word-STM (no degree) | 932.439 | 0.07 M | 0.13 M | 0.459 | 0 | 1419 | 652906 | PASS | 10.16 [10.16, 10.16] |

## check-SER-uniform

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 1.450 | 45.20 M | 106.19 M | 0.130 | 0 | 908 | 260 | PASS | — |
| GTX-conservative port | 1.584 | 41.37 M | 96.98 M | 0.192 | 0 | 1086 | 253 | PASS | 1.09 [1.09, 1.09] |
| 2PL vertex locks | 2.941 | 22.28 M | 51.47 M | 0.000 | 0 | 1834 | 1797 | PASS | 2.03 [2.03, 2.03] |
| TL2 word-STM | 7.787 | 8.42 M | 19.34 M | 0.799 | 0 | 7131 | 6049 | PASS | 5.37 [5.37, 5.37] |
| TL2 word-STM (no degree) | 2.000 | 32.77 M | 76.29 M | 0.344 | 0 | 1640 | 1735 | PASS | 1.38 [1.38, 1.38] |

## check-SER-zipf

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 10.975 | 5.97 M | 13.67 M | 0.157 | 0 | 5835 | 5217 | PASS | — |
| GTX-conservative port | 11.774 | 5.57 M | 12.71 M | 0.228 | 0 | 6312 | 5097 | PASS | 1.07 [1.07, 1.07] |
| 2PL vertex locks | 7156.565 | 0.01 M | 0.02 M | 0.000 | 0 | 7148212 | 7066579 | PASS | 652.07 [652.07, 652.07] |
| TL2 word-STM | 904.758 | 0.05 M | 0.09 M | 1.000 | 19965 | 638626 | 802683 | PASS | 118.55 [118.55, 118.55] |
| TL2 word-STM (no degree) | 222.109 | 0.30 M | 0.67 M | 0.429 | 0 | 2903 | 129079 | PASS | 20.24 [20.24, 20.24] |

## check-SI-hub50

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 91.841 | 0.71 M | 1.29 M | 0.366 | 0 | 55938 | 44963 | PASS | — |
| GTX-conservative port | 99.008 | 0.66 M | 1.20 M | 0.385 | 0 | 60097 | 45838 | PASS | 1.08 [1.08, 1.08] |

## check-SI-uniform

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 1.626 | 40.30 M | 94.15 M | 0.100 | 0 | 1053 | 596 | PASS | — |
| GTX-conservative port | 1.377 | 47.58 M | 110.97 M | 0.165 | 0 | 908 | 231 | PASS | 0.85 [0.85, 0.85] |

## check-SI-zipf

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 9.433 | 6.95 M | 15.82 M | 0.139 | 0 | 4975 | 4513 | PASS | — |
| GTX-conservative port | 11.200 | 5.85 M | 13.31 M | 0.216 | 0 | 5534 | 4540 | PASS | 1.19 [1.19, 1.19] |

## hub50-ins-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.350 | 241.05 M | 134.66 M | 0.000 | 0 | 94 | 0 | - | — |
| GTX-conservative port | 4.667 | 224.66 M | 125.50 M | 0.001 | 0 | 117 | 0 | - | 1.07 [0.99, 1.08] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >20690 |
| TL2 word-STM | 512.995 | 1.90 M | 1.03 M | 0.997 | 73615 | 567 | 0 | - | 126.83 [117.23, 132.14] |
| TL2 word-STM (no degree) | 3.313 | 316.54 M | 176.83 M | 0.004 | 0 | 229 | 0 | - | 0.76 [0.71, 0.98] |
| non-transactional CAS | 1.967 | 533.06 M | 297.78 M | 0.000 | 0 | 85 | 0 | - | 0.45 [0.42, 0.46] |

## hub50-ins-K2

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.141 | 126.61 M | 141.55 M | 0.002 | 0 | 163 | 0 | - | — |
| GTX-conservative port | 4.540 | 115.47 M | 129.10 M | 0.005 | 0 | 204 | 0 | - | 1.10 [1.00, 1.11] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >21733 |
| TL2 word-STM | 648.694 | 0.70 M | 0.75 M | 0.998 | 72473 | 840 | 0 | - | 181.77 [161.00, 229.58] |
| TL2 word-STM (no degree) | 4.056 | 129.26 M | 144.51 M | 0.017 | 0 | 839 | 0 | - | 0.98 [0.84, 1.08] |
| non-transactional CAS | 1.776 | 295.27 M | 330.11 M | 0.000 | 0 | 136 | 0 | - | 0.43 [0.39, 0.58] |

## hub50-ins-K32

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.913 | 4.14 M | 73.92 M | 0.259 | 0 | 6523 | 0 | - | — |
| GTX-conservative port | 10.527 | 3.11 M | 55.57 M | 0.425 | 0 | 9012 | 0 | - | 1.33 [1.21, 1.38] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >11373 |
| TL2 word-STM | 4465.589 | 0.00 M | 0.02 M | 1.000 | 28815 | 4442226 | 0 | - | 4711.42 [4297.15, 4827.34] |
| TL2 word-STM (no degree) | 32.372 | 1.01 M | 18.07 M | 0.898 | 0 | 30787 | 0 | - | 4.09 [3.73, 4.14] |
| non-transactional CAS | 1.795 | 18.25 M | 325.88 M | 0.000 | 0 | 1684 | 0 | - | 0.23 [0.21, 0.29] |

## hub50-ins-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.229 | 61.99 M | 138.75 M | 0.007 | 0 | 303 | 0 | - | — |
| GTX-conservative port | 4.743 | 55.27 M | 123.71 M | 0.018 | 0 | 549 | 0 | - | 1.12 [1.12, 1.38] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >21281 |
| TL2 word-STM | 800.400 | 0.24 M | 0.53 M | 0.999 | 67129 | 79569 | 0 | - | 254.41 [205.46, 371.05] |
| TL2 word-STM (no degree) | 3.881 | 67.55 M | 151.20 M | 0.070 | 0 | 1011 | 0 | - | 0.92 [0.91, 1.06] |
| non-transactional CAS | 1.692 | 154.96 M | 346.88 M | 0.000 | 0 | 282 | 0 | - | 0.40 [0.40, 0.54] |

## hub50-ins-K8

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.605 | 28.46 M | 127.27 M | 0.027 | 0 | 1361 | 0 | - | — |
| GTX-conservative port | 5.890 | 22.25 M | 99.50 M | 0.065 | 0 | 2092 | 0 | - | 1.28 [1.15, 1.37] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >19544 |
| TL2 word-STM | 1560.503 | 0.05 M | 0.20 M | 1.000 | 58653 | 524752 | 0 | - | 613.34 [609.28, 680.55] |
| TL2 word-STM (no degree) | 5.557 | 23.59 M | 105.46 M | 0.253 | 0 | 3116 | 0 | - | 1.21 [1.19, 1.34] |
| non-transactional CAS | 1.760 | 74.46 M | 332.95 M | 0.000 | 0 | 702 | 0 | - | 0.38 [0.38, 0.39] |

## identical-edge-1024-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 34.847 | 7.52 M | 19.61 M | 0.665 | 0 | 29988 | 0 | - | — |
| GTX-conservative port | 33.545 | 7.81 M | 20.36 M | 0.665 | 0 | 28871 | 0 | - | 0.96 [0.95, 0.98] |
| 2PL vertex locks | 324.556 | 0.81 M | 2.13 M | 0.000 | 0 | 285103 | 0 | - | 9.31 [8.23, 9.68] |
| TL2 word-STM | 418.839 | 0.61 M | 1.64 M | 0.998 | 5726 | 330329 | 0 | - | 12.29 [11.84, 13.89] |
| TL2 word-STM (no degree) | 352.447 | 0.73 M | 2.07 M | 0.997 | 3410 | 289125 | 0 | - | 10.25 [9.59, 10.95] |
| non-transactional CAS | 8.094 | 32.39 M | 83.90 M | 0.000 | 0 | 2657 | 0 | - | 0.23 [0.22, 0.24] |

## identical-edge-64-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 488.884 | 0.54 M | 1.36 M | 0.920 | 0 | 411060 | 0 | - | — |
| GTX-conservative port | 475.723 | 0.55 M | 1.39 M | 0.919 | 0 | 401154 | 0 | - | 0.97 [0.96, 0.98] |
| 2PL vertex locks | 2234.044 | 0.12 M | 0.31 M | 0.000 | 0 | 2109366 | 0 | - | 4.57 [4.47, 4.66] |
| TL2 word-STM | 836.146 | 0.22 M | 0.55 M | 1.000 | 81281 | 274279 | 0 | - | 2.48 [2.10, 3.73] |
| TL2 word-STM (no degree) | 764.357 | 0.21 M | 0.61 M | 1.000 | 104078 | 188880 | 0 | - | 2.59 [2.07, 3.86] |
| non-transactional CAS | 47.508 | 5.52 M | 13.83 M | 0.000 | 0 | 16105 | 0 | - | 0.10 [0.10, 0.10] |

## rmat-churn-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.075 | 148.21 M | 143.82 M | 0.001 | 0 | 460 | 0 | - | — |
| GTX-conservative port | 7.044 | 148.86 M | 144.45 M | 0.003 | 0 | 461 | 0 | - | 1.00 [0.97, 1.07] |
| 2PL vertex locks | 71.444 | 14.68 M | 14.24 M | 0.000 | 0 | 39152 | 0 | - | 10.10 [9.86, 10.68] |
| TL2 word-STM | 282.932 | 3.67 M | 3.56 M | 0.988 | 9076 | 104691 | 0 | - | 40.34 [38.66, 42.66] |
| TL2 word-STM (no degree) | 4.899 | 214.05 M | 207.72 M | 0.009 | 0 | 641 | 0 | - | 0.69 [0.61, 0.74] |
| non-transactional CAS | 2.041 | 513.80 M | 498.63 M | 0.000 | 0 | 97 | 0 | - | 0.29 [0.28, 0.31] |

## rmat-churn-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.182 | 36.50 M | 141.61 M | 0.023 | 0 | 1069 | 0 | - | — |
| GTX-conservative port | 7.281 | 36.01 M | 139.69 M | 0.045 | 0 | 1111 | 0 | - | 1.01 [1.01, 1.07] |
| 2PL vertex locks | 3768.753 | 0.07 M | 0.27 M | 0.000 | 0 | 3696033 | 0 | - | 524.73 [475.43, 554.03] |
| TL2 word-STM | 684.921 | 0.36 M | 1.39 M | 0.998 | 15359 | 441100 | 0 | - | 101.30 [84.79, 130.29] |
| TL2 word-STM (no degree) | 6.871 | 38.15 M | 148.01 M | 0.169 | 0 | 2239 | 0 | - | 0.96 [0.95, 1.01] |
| non-transactional CAS | 1.981 | 132.30 M | 513.11 M | 0.000 | 0 | 440 | 0 | - | 0.28 [0.27, 0.33] |

## rmat-readers90-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 15.130 | 17.33 M | 6.90 M | 0.000 | 0 | 2416 | 2416 | - | — |
| GTX-conservative port | 15.361 | 17.07 M | 6.79 M | 0.001 | 0 | 2469 | 2426 | - | 1.02 [0.98, 1.05] |
| 2PL vertex locks | 488.458 | 0.54 M | 0.21 M | 0.000 | 0 | 478874 | 458892 | - | 32.28 [23.70, 46.11] |
| TL2 word-STM | 402.303 | 0.65 M | 0.26 M | 0.898 | 0 | 175633 | 209910 | - | 26.59 [24.51, 30.71] |
| TL2 word-STM (no degree) | 269.681 | 0.97 M | 0.39 M | 0.421 | 0 | 4697 | 82758 | - | 17.82 [17.24, 19.55] |
| non-transactional CAS | 37.745 | 6.95 M | 2.76 M | 0.000 | 0 | 9166 | 18762 | - | 2.49 [2.41, 2.60] |

## rmat-readers90-K4-lanescan

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 188.185 | 1.39 M | 0.55 M | 0.000 | 0 | 40607 | 40607 | - | — |
| GTX-conservative port | 188.704 | 1.39 M | 0.55 M | 0.001 | 0 | 39556 | 39297 | - | 1.00 [0.98, 1.03] |

## rmat-readers90-K4-roCoop

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 15.356 | 17.07 M | 6.80 M | 0.000 | 0 | 2498 | 2492 | - | — |
| GTX-conservative port | 15.203 | 17.24 M | 6.87 M | 0.001 | 0 | 2604 | 2523 | - | 0.99 [0.97, 1.05] |
| 2PL vertex locks | 214.439 | 1.22 M | 0.49 M | 0.724 | 0 | 119551 | 57290 | - | 13.96 [13.78, 14.74] |
| TL2 word-STM | 347.884 | 0.75 M | 0.30 M | 0.346 | 0 | 6760 | 328274 | - | 22.65 [20.31, 26.44] |
| TL2 word-STM (no degree) | 256.365 | 1.02 M | 0.41 M | 0.190 | 0 | 1061 | 238261 | - | 16.69 [15.48, 18.64] |
| non-transactional CAS | 6.593 | 39.76 M | 15.83 M | 0.000 | 0 | 80 | 1711 | - | 0.43 [0.40, 0.45] |

## uniform-churn-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 6.540 | 160.33 M | 155.68 M | 0.002 | 0 | 124 | 0 | - | — |
| GTX-conservative port | 6.619 | 158.42 M | 153.83 M | 0.003 | 0 | 467 | 0 | - | 1.01 [0.92, 1.10] |
| 2PL vertex locks | 3.433 | 305.40 M | 296.57 M | 0.000 | 0 | 439 | 0 | - | 0.52 [0.44, 0.56] |
| TL2 word-STM | 6.635 | 158.05 M | 153.43 M | 0.028 | 0 | 518 | 0 | - | 1.01 [0.92, 1.07] |
| TL2 word-STM (no degree) | 3.995 | 262.50 M | 254.86 M | 0.007 | 0 | 214 | 0 | - | 0.61 [0.59, 0.74] |
| non-transactional CAS | 2.425 | 432.43 M | 419.84 M | 0.000 | 0 | 94 | 0 | - | 0.37 [0.36, 0.44] |

## uniform-churn-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.002 | 37.44 M | 145.30 M | 0.024 | 0 | 1059 | 0 | - | — |
| GTX-conservative port | 7.166 | 36.58 M | 141.97 M | 0.042 | 0 | 1086 | 0 | - | 1.02 [0.99, 1.11] |
| 2PL vertex locks | 3.676 | 71.31 M | 276.74 M | 0.000 | 0 | 826 | 0 | - | 0.53 [0.51, 0.62] |
| TL2 word-STM | 16.986 | 15.43 M | 59.86 M | 0.470 | 0 | 6301 | 0 | - | 2.43 [2.36, 2.56] |
| TL2 word-STM (no degree) | 6.321 | 41.47 M | 160.95 M | 0.144 | 0 | 1834 | 0 | - | 0.90 [0.82, 0.99] |
| non-transactional CAS | 2.052 | 127.74 M | 495.62 M | 0.000 | 0 | 333 | 0 | - | 0.29 [0.28, 0.39] |

## uniform-delete-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 8.006 | 32.74 M | 115.24 M | 0.051 | 0 | 1307 | 0 | - | — |
| GTX-conservative port | 8.143 | 32.19 M | 113.30 M | 0.063 | 0 | 1284 | 0 | - | 1.02 [0.97, 1.09] |
| 2PL vertex locks | 3.772 | 69.49 M | 244.55 M | 0.000 | 0 | 1049 | 0 | - | 0.47 [0.43, 0.52] |
| TL2 word-STM | 13.701 | 19.13 M | 67.33 M | 0.465 | 0 | 5157 | 0 | - | 1.71 [1.63, 1.83] |
| TL2 word-STM (no degree) | 5.711 | 45.90 M | 161.54 M | 0.162 | 0 | 1859 | 0 | - | 0.71 [0.66, 0.76] |
| non-transactional CAS | 1.918 | 136.68 M | 481.01 M | 0.000 | 0 | 333 | 0 | - | 0.24 [0.23, 0.33] |

## uniform-ins-K1

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.780 | 181.40 M | 181.40 M | 0.000 | 0 | 453 | 0 | - | — |
| GTX-conservative port | 5.992 | 174.98 M | 174.98 M | 0.002 | 0 | 626 | 0 | - | 1.04 [0.92, 1.12] |
| 2PL vertex locks | 3.055 | 343.28 M | 343.28 M | 0.000 | 0 | 154 | 0 | - | 0.53 [0.48, 0.64] |
| TL2 word-STM | 6.603 | 158.81 M | 158.81 M | 0.036 | 0 | 593 | 0 | - | 1.14 [1.04, 1.25] |
| TL2 word-STM (no degree) | 3.963 | 264.60 M | 264.60 M | 0.008 | 0 | 267 | 0 | - | 0.69 [0.62, 0.79] |
| non-transactional CAS | 2.346 | 446.97 M | 446.96 M | 0.000 | 0 | 102 | 0 | - | 0.41 [0.37, 0.51] |

## uniform-ins-K2

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 6.289 | 83.36 M | 166.72 M | 0.000 | 0 | 716 | 0 | - | — |
| GTX-conservative port | 6.364 | 82.38 M | 164.76 M | 0.006 | 0 | 720 | 0 | - | 1.01 [0.92, 1.19] |
| 2PL vertex locks | 3.142 | 166.88 M | 333.77 M | 0.000 | 0 | 351 | 0 | - | 0.50 [0.49, 0.59] |
| TL2 word-STM | 8.401 | 62.41 M | 124.82 M | 0.151 | 0 | 1422 | 0 | - | 1.34 [1.26, 1.58] |
| TL2 word-STM (no degree) | 5.347 | 98.05 M | 196.09 M | 0.033 | 0 | 972 | 0 | - | 0.85 [0.69, 1.00] |
| non-transactional CAS | 2.097 | 250.00 M | 500.00 M | 0.000 | 0 | 173 | 0 | - | 0.33 [0.33, 0.48] |

## uniform-ins-K32

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.439 | 4.40 M | 140.95 M | 0.000 | 0 | 3873 | 0 | - | — |
| GTX-conservative port | 13.359 | 2.45 M | 78.49 M | 0.454 | 0 | 11383 | 0 | - | 1.80 [1.68, 1.86] |
| 2PL vertex locks | 11.523 | 2.84 M | 91.00 M | 0.000 | 0 | 10364 | 0 | - | 1.55 [1.47, 1.59] |
| TL2 word-STM | 573.943 | 0.06 M | 1.83 M | 0.997 | 0 | 565093 | 0 | - | 77.15 [65.13, 102.83] |
| TL2 word-STM (no degree) | 85.145 | 0.38 M | 12.32 M | 0.960 | 0 | 80183 | 0 | - | 11.45 [10.86, 11.77] |
| non-transactional CAS | 2.196 | 14.93 M | 477.61 M | 0.000 | 0 | 2018 | 0 | - | 0.30 [0.28, 0.39] |

## uniform-ins-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.981 | 43.83 M | 175.31 M | 0.000 | 0 | 746 | 0 | - | — |
| GTX-conservative port | 6.326 | 41.44 M | 165.75 M | 0.025 | 0 | 900 | 0 | - | 1.06 [1.03, 1.15] |
| 2PL vertex locks | 3.827 | 68.50 M | 274.02 M | 0.000 | 0 | 1000 | 0 | - | 0.64 [0.58, 0.69] |
| TL2 word-STM | 15.471 | 16.94 M | 67.78 M | 0.483 | 0 | 5742 | 0 | - | 2.59 [2.51, 2.78] |
| TL2 word-STM (no degree) | 5.840 | 44.89 M | 179.55 M | 0.128 | 0 | 1802 | 0 | - | 0.98 [0.91, 1.09] |
| non-transactional CAS | 2.012 | 130.28 M | 521.12 M | 0.000 | 0 | 338 | 0 | - | 0.34 [0.33, 0.36] |

## uniform-ins-K8

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 6.366 | 20.59 M | 164.71 M | 0.000 | 0 | 1152 | 0 | - | — |
| GTX-conservative port | 7.093 | 18.48 M | 147.83 M | 0.085 | 0 | 2353 | 0 | - | 1.11 [1.08, 1.21] |
| 2PL vertex locks | 4.860 | 26.97 M | 215.76 M | 0.000 | 0 | 2833 | 0 | - | 0.76 [0.70, 0.85] |
| TL2 word-STM | 45.587 | 2.88 M | 23.00 M | 0.879 | 0 | 34126 | 0 | - | 7.16 [6.96, 7.66] |
| TL2 word-STM (no degree) | 9.236 | 14.19 M | 113.53 M | 0.410 | 0 | 5817 | 0 | - | 1.45 [1.41, 1.71] |
| non-transactional CAS | 2.127 | 61.63 M | 493.02 M | 0.000 | 0 | 772 | 0 | - | 0.33 [0.32, 0.44] |

## uniform-readers50-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.453 | 58.86 M | 116.14 M | 0.007 | 0 | 483 | 307 | - | — |
| GTX-conservative port | 5.040 | 52.01 M | 102.61 M | 0.012 | 0 | 834 | 822 | - | 1.13 [0.93, 1.14] |
| 2PL vertex locks | 3.448 | 76.03 M | 150.00 M | 0.000 | 0 | 725 | 688 | - | 0.77 [0.64, 0.86] |
| TL2 word-STM | 11.788 | 22.24 M | 43.85 M | 0.288 | 0 | 5195 | 3114 | - | 2.65 [2.18, 2.66] |
| TL2 word-STM (no degree) | 6.099 | 42.98 M | 84.80 M | 0.095 | 0 | 2049 | 1769 | - | 1.37 [1.10, 1.38] |
| non-transactional CAS | 1.989 | 131.82 M | 260.01 M | 0.000 | 0 | 339 | 387 | - | 0.45 [0.37, 0.59] |

## uniform-readers50-K4-lanescan

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 5.269 | 49.76 M | 98.17 M | 0.007 | 0 | 856 | 850 | - | — |
| GTX-conservative port | 4.727 | 55.46 M | 109.42 M | 0.012 | 0 | 724 | 326 | - | 0.90 [0.84, 1.09] |

## uniform-readers50-K4-roCoop

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 4.460 | 58.77 M | 115.95 M | 0.007 | 0 | 478 | 305 | - | — |
| GTX-conservative port | 4.464 | 58.73 M | 115.86 M | 0.012 | 0 | 685 | 305 | - | 1.00 [0.89, 1.13] |
| 2PL vertex locks | 2.765 | 94.81 M | 187.10 M | 0.000 | 0 | 264 | 347 | - | 0.62 [0.55, 0.63] |
| TL2 word-STM | 9.020 | 29.06 M | 57.34 M | 0.146 | 0 | 1196 | 1204 | - | 2.02 [1.81, 2.05] |
| TL2 word-STM (no degree) | 4.716 | 55.58 M | 109.68 M | 0.057 | 0 | 690 | 773 | - | 1.06 [0.90, 1.11] |
| non-transactional CAS | 1.661 | 157.83 M | 311.39 M | 0.000 | 0 | 152 | 213 | - | 0.37 [0.33, 0.38] |

## zipf-churn-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 7.561 | 34.67 M | 132.65 M | 0.024 | 0 | 1132 | 0 | - | — |
| GTX-conservative port | 7.588 | 34.55 M | 132.19 M | 0.043 | 0 | 1175 | 0 | - | 1.00 [1.00, 1.06] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >11903 |
| TL2 word-STM | 1349.139 | 0.10 M | 0.36 M | 1.000 | 133609 | 311656 | 0 | - | 363.90 [362.23, 445.13] |
| TL2 word-STM (no degree) | 6.749 | 38.84 M | 148.61 M | 0.160 | 0 | 2104 | 0 | - | 0.89 [0.85, 0.94] |
| non-transactional CAS | 1.965 | 133.40 M | 510.32 M | 0.000 | 0 | 351 | 0 | - | 0.26 [0.26, 0.34] |

## zipf-readers50-K4

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 438.105 | 0.60 M | 1.16 M | 0.012 | 0 | 91683 | 90154 | - | — |
| GTX-conservative port | 445.275 | 0.59 M | 1.14 M | 0.018 | 0 | 96080 | 88500 | - | 1.02 [1.00, 1.04] |
| 2PL vertex locks | DNF>90000 | | | | | | | | >205 |
| TL2 word-STM | 2929.648 | 0.07 M | 0.10 M | 0.999 | 56172 | 500606 | 2321401 | - | 8.51 [8.34, 8.69] |
| TL2 word-STM (no degree) | 1110.469 | 0.24 M | 0.46 M | 0.588 | 0 | 1101 | 501351 | - | 2.53 [2.37, 3.43] |
| non-transactional CAS | 392.178 | 0.67 M | 1.30 M | 0.000 | 0 | 4731 | 294939 | - | 0.90 [0.84, 1.00] |

## zipf-readers50-K4-lanescan

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 2576.672 | 0.10 M | 0.20 M | 0.018 | 0 | 484300 | 455244 | - | — |
| GTX-conservative port | 2487.512 | 0.11 M | 0.20 M | 0.050 | 0 | 501076 | 436761 | - | 0.97 [0.90, 1.00] |

## zipf-readers50-K4-roCoop

| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| GTX-GPU (ours) | 442.331 | 0.59 M | 1.15 M | 0.009 | 0 | 94102 | 91498 | - | — |
| GTX-conservative port | 439.024 | 0.60 M | 1.16 M | 0.019 | 0 | 95494 | 88285 | - | 0.99 [0.99, 1.02] |
| 2PL vertex locks | DNF>120000 | | | | | | | | >271 |
| TL2 word-STM | DNF>120000 | | | | | | | | >271 |
| TL2 word-STM (no degree) | DNF>120000 | | | | | | | | >271 |
| non-transactional CAS | 212.250 | 1.24 M | 2.40 M | 0.000 | 0 | 125 | 50072 | - | 0.48 [0.47, 0.51] |


# GPMA+ baseline: variants and portability changes

Upstream: `https://github.com/desert0616/gpma_demo`, commit `080aa6d6b8892d52818d0ba7d477d4d7cf02d415` (2023-06-19),
local clone `gpu-stm-dynamic-graphs/baselines/gpma_demo/` (unmodified).

**Which algorithm is it?** `update_gpma()` sorts the batch, locates leaf segments, and rebalances level by level
with segment-oriented, lock-free merging (`rebalance_batch` → `block_rebalancing_kernel` / `rebalancing_kernel`).
That is **GPMA+** (tech report arXiv:1709.05061 §5, "Lock-Free Segment-Oriented Updates"), not the lock-based GPMA
of §4. Every local number labelled "GPMA" in `gpu-stm-dynamic-graphs/` is therefore GPMA+ (through the port below).

## Variant A — `gpma_port` (pre-existing Windows port, `gpu-stm-dynamic-graphs/baselines/gpma_port/`)
Diff vs upstream (`git diff --no-index`: 31 insertions, 18 deletions in `gpma.cuh`):
1. Five `const` globals → `#define` (device visibility under `-rdc`). *Semantics-neutral.*
2. `cub_sort_key_value`, `compact_kernel` changed `__device__` → `__host__`.
3. **`rebalancing_kernel` changed `__global__` → `__host__`.** Upstream launches it with up to 2048 device threads,
   each rebalancing one large tree node (update width > 1024) with child kernels (CUDA Dynamic Parallelism, CDP1,
   device-side `cudaDeviceSynchronize`). The port runs the same per-node work in a **sequential host loop** with
   D2H copies of the node index arrays and one D2H copy of `compacted_size` per node.
   *Performance-relevant:* large-segment rebalancing loses all inter-node parallelism and gains ~1 host round trip
   per node. Small segments (≤ 1024, `block_rebalancing_kernel`) are unchanged.

## Variant B — `gpma_upstream` (this directory, `upstream_patched/`)
Pristine upstream with one change: the six namespace-scope `const` globals → `constexpr`
(nvcc 12.8 rejects the non-integral `VALUE_NONE` in device code otherwise). CDP code paths are untouched and built
with legacy CDP1 (`-rdc=true -DCUDA_FORCE_CDP1_IF_SUPPORTED -lcudadevrt`, supported on sm_89 by CUDA 12.x,
deprecated). This is the closest runnable form of the published algorithm on this machine.

## Harness (`bench_gpma.cu`)
- Same generator (`src/workload.hpp`) and seeds as the transactional benchmarks; a transaction stream is flattened
  into edge batches (`--batch`), INS → value 1, DEL → `VALUE_NONE` (the demo's lazy-delete convention).
- Timed region: `update_gpma()` per batch with device-resident inputs (no PCIe), cudaEvents; initial graph load untimed.
- Verification: final live key set (excluding row sentinels and `KEY_MAX`) must equal the sequential replay.
- Batch semantics differ from transactions: a batch is sorted, so an INS and a DEL of the same edge inside one batch
  lose their order; there are no multi-edge transactions, no aborts, and no concurrent readers during an update.

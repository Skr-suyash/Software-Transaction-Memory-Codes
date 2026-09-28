// Shared types for the GTX-GPU research harness.
// Workload = list of transactions, each a variable-length list of Ops (CSR layout).
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <utility>
#include <cuda_runtime.h>
#include <cuda/atomic>

typedef unsigned long long u64;
typedef unsigned int u32;

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
  fprintf(stderr, "CUDA error %s at %s:%d\n", cudaGetErrorString(e_), __FILE__, __LINE__); exit(2);} } while (0)

enum OpType : u32 { OP_NOP = 0, OP_INS = 1, OP_DEL = 2, OP_READ = 3, OP_SCAN = 4 };

struct Op { u32 type, u, v; };

// Per-op result recorded for the committed attempt.
//  INS/DEL : r = 1 if the op changed the graph, 0 if it was a no-op (present / absent already)
//  READ    : r = 1 present, 0 absent; obs = delta index of the observed version (NILD if none)
//  SCAN    : r = number of visible neighbours, aux = xor of mix(v) over visible neighbours
struct OpResult { u32 r, aux; u32 obs, pad; };

// Per-transaction record for the committed attempt (used by the history checker).
struct TxRecord { u64 rts, cts; u32 txid, attempts; u64 tBegin, tEnd; };

// Abort causes (index into stats counters).
enum AbortCause : u32 {
  AB_WW_PENDING = 0,   // newest version of the edge is owned by another active txn
  AB_WW_LATE = 1,      // newest version committed after our snapshot (SI first-committer-wins)
  AB_CHAIN_FALSE = 2,  // chain-granularity conflict on a *different* destination (GTX-faithful mode)
  AB_SER_POINT = 3,    // serializable validation failed on a point read / no-op write
  AB_SER_SCAN = 4,     // serializable validation failed on an adjacency scan (phantom / invalidation)
  AB_RESOURCE = 5,     // arena / descriptor exhaustion
  AB_LOCK = 6,         // baselines: lock acquisition failure (STM commit-time lock busy)
  AB_STM_READ = 7,     // baselines: STM read/validation inconsistency
  AB_NCAUSES = 8
};

enum StatIdx : u32 {
  ST_COMMITS = 0, ST_ABORTS = 1, ST_EFFECTIVE = 2, ST_NOOPS = 3, ST_SLOTS = 4, ST_VOIDED = 5,
  ST_GROWTHS = 6, ST_CAS_FAIL = 7, ST_EPOCHS = 8, ST_GIVEUP = 9, ST_RESV_ATOMICS = 10,
  ST_ABORT_BASE = 16, ST_N = 32
};

__host__ __device__ inline u32 mix32(u32 x) {
  x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16; return x;
}

__device__ inline u64 gtimer() { u64 t; asm volatile("mov.u64 %0, %%globaltimer;" : "=l"(t)); return t; }
__device__ inline u32 lanemask_lt() { u32 m; asm("mov.u32 %0, %%lanemask_lt;" : "=r"(m)); return m; }

#define FULLMASK 0xFFFFFFFFu

// Warp-aggregated increment of a global counter for lanes with pred set; returns each lane's base+rank.
__device__ inline u32 warpAggInc(u32* ctr, bool pred) {
  u32 m = __ballot_sync(FULLMASK, pred);
  if (!m) return 0;
  u32 lane = threadIdx.x & 31, leader = __ffs(m) - 1, base = 0;
  if (lane == leader) base = atomicAdd(ctr, (u32)__popc(m));
  base = __shfl_sync(FULLMASK, base, leader);
  return base + __popc(m & lanemask_lt());
}

// Host-side workload container.
struct HostWorkload {
  u32 V = 0;
  std::vector<u32> off;      // size N+1
  std::vector<Op> ops;
  std::vector<std::pair<u32, u32>> initEdges;
  u32 N() const { return (u32)off.size() - 1; }
};

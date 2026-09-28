// Transactional synchronization baselines over a shared storage layout:
// per-vertex open-addressing hash adjacency (pre-sized from the workload -- favours the baselines,
// they never pay growth) + per-vertex degree word.
//
//  2PL   : strict two-phase locking with per-vertex reader-writer spinlocks acquired in sorted
//          vertex order (deadlock-free), exclusive for vertices written, shared for vertices read.
//  STM   : word-based TL2-style GPU STM (global version clock, versioned-lock orecs, lazy write
//          buffering, commit-time locking in sorted orec order, read-set validation; read-only
//          transactions run without a read set).  This is the "general-purpose GPU STM" design point
//          (GPU-STM / PR-STM family) applied to graph updates without graph-aware conflict logic.
//  NONTX : non-transactional lock-free CAS updates (SlabGraph/faimGraph-style synchronization):
//          lower bound on synchronization cost, provides no multi-edge atomicity or snapshots.
#pragma once
#include <algorithm>
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
#include "common.cuh"
namespace cg = cooperative_groups;

namespace bl {

constexpr u32 EMPTY = 0xFFFFFFFFu, TOMB = 0xFFFFFFFEu;
constexpr u32 WBIT = 0x80000000u;
constexpr int MAXOPS = 32, RSMAX = 256, WSMAX = 80;

enum Mode { M_2PL = 0, M_STM = 1, M_NONTX = 2 };

struct Ctx {
  u32 V; const u32* tbase; const u32* tcap; u32* slots; u32* deg; u32 S;
  u32* locks; u32* orecs; u32 orecMask; u32* gclock; int nodeg;
  const u32* off; const Op* ops; u32 N; u32* nextTxn;
  OpResult* res; TxRecord* rec; u32* stats; u32* seq; int record; u32 maxAttempts;
  int coopRO;  // warp-cooperative scans for read-only transactions (fair-scan variant)
};

__device__ __forceinline__ u32 vload(const u32* p) { return *(volatile const u32*)p; }
__device__ __forceinline__ void vstore(u32* p, u32 v) { *(volatile u32*)p = v; }

// ---------------- plain (lock-protected / CAS) hash operations ----------------
__device__ bool htFind(const Ctx& c, u32 u, u32 v, u32& pos, u32& freePos) {
  u32 cap = c.tcap[u], base = c.tbase[u], p = mix32(v) & (cap - 1);
  freePos = EMPTY;
  for (u32 i = 0; i < cap; i++, p = (p + 1) & (cap - 1)) {
    u32 s = vload(&c.slots[base + p]);
    if (s == v) { pos = base + p; return true; }
    if (s == EMPTY) { if (freePos == EMPTY) freePos = base + p; return false; }
    if (s == TOMB && freePos == EMPTY) freePos = base + p;
  }
  return false;
}

__device__ void scanPlain(const Ctx& c, u32 u, u32& cnt, u32& hx) {
  u32 cap = c.tcap[u], base = c.tbase[u]; cnt = 0; hx = 0;
  for (u32 i = 0; i < cap; i++) { u32 s = vload(&c.slots[base + i]); if (s < TOMB) { cnt++; hx ^= mix32(s); } }
}

__device__ __forceinline__ void backoffSleep(u32& rng, u32 att) {
  rng = mix32(rng + att + 0x9e37u);
  u32 sh = att < 10 ? att : 10;
  __nanosleep(32 + (rng & ((64u << sh) - 1)));
}

// ---------------- 2PL ----------------
__device__ void run2pl(const Ctx& c, u32 t, u32& rng, u32* st) {
  u32 b = c.off[t], K = c.off[t + 1] - b;
  u32 vs[MAXOPS]; bool wm[MAXOPS]; u32 n = 0;
  for (u32 j = 0; j < K; j++) {
    Op op = c.ops[b + j]; bool w = (op.type == OP_INS || op.type == OP_DEL);
    u32 k = 0; for (; k < n; k++) if (vs[k] == op.u) break;
    if (k == n) { vs[n] = op.u; wm[n] = w; n++; } else wm[k] |= w;
  }
  for (u32 i = 1; i < n; i++) { u32 x = vs[i]; bool y = wm[i]; int k = i - 1; while (k >= 0 && vs[k] > x) { vs[k + 1] = vs[k]; wm[k + 1] = wm[k]; k--; } vs[k + 1] = x; wm[k + 1] = y; }
  for (u32 i = 0; i < n; i++) {
    u32 att = 0;
    if (wm[i]) { while (atomicCAS(&c.locks[vs[i]], 0u, WBIT) != 0u) backoffSleep(rng, att++); }
    else {
      for (;;) { u32 x = vload(&c.locks[vs[i]]); if (!(x & WBIT) && atomicCAS(&c.locks[vs[i]], x, x + 1) == x) break; backoffSleep(rng, att++); }
    }
    st[ST_CAS_FAIL] += att;
  }
  __threadfence();
  u32 eff = 0, noop = 0;
  for (u32 j = 0; j < K; j++) {
    Op op = c.ops[b + j]; OpResult r; r.r = 0; r.aux = 0; r.obs = 0; r.pad = 0;
    u32 pos, fp;
    if (op.type == OP_INS) {
      if (htFind(c, op.u, op.v, pos, fp)) noop++;
      else if (fp != EMPTY) { vstore(&c.slots[fp], op.v); c.deg[op.u]++; r.r = 1; eff++; }
    } else if (op.type == OP_DEL) {
      if (htFind(c, op.u, op.v, pos, fp)) { vstore(&c.slots[pos], TOMB); c.deg[op.u]--; r.r = 1; eff++; } else noop++;
    } else if (op.type == OP_READ) { r.r = htFind(c, op.u, op.v, pos, fp); }
    else if (op.type == OP_SCAN) { scanPlain(c, op.u, r.r, r.aux); }
    c.res[b + j] = r;
  }
  u32 s = 0;
  if (c.record) s = atomicAdd(c.seq, 1u) + 1;
  __threadfence();
  for (u32 i = 0; i < n; i++) { if (wm[i]) atomicExch(&c.locks[vs[i]], 0u); else atomicSub(&c.locks[vs[i]], 1u); }
  st[ST_COMMITS]++; st[ST_EFFECTIVE] += eff; st[ST_NOOPS] += noop;
  c.rec[t].rts = s ? s - 1 : 0; c.rec[t].cts = s; c.rec[t].txid = 1; c.rec[t].attempts = 1;
}

// ---------------- NONTX (lock-free CAS, per-op) ----------------
__device__ void runNonTx(const Ctx& c, u32 t, u32* st) {
  u32 b = c.off[t], K = c.off[t + 1] - b, eff = 0, noop = 0;
  for (u32 j = 0; j < K; j++) {
    Op op = c.ops[b + j]; OpResult r; r.r = 0; r.aux = 0; r.obs = 0; r.pad = 0;
    u32 cap = c.tcap[op.u], base = c.tbase[op.u];
    if (op.type == OP_INS) {
      u32 p = mix32(op.v) & (cap - 1);
      for (u32 i = 0; i < cap; i++, p = (p + 1) & (cap - 1)) {
        u32 s = vload(&c.slots[base + p]);
        if (s == op.v) { noop++; break; }
        if (s == EMPTY) {
          u32 old = atomicCAS(&c.slots[base + p], EMPTY, op.v);
          if (old == EMPTY) { atomicAdd(&c.deg[op.u], 1u); r.r = 1; eff++; break; }
          if (old == op.v) { noop++; break; }
        }
      }
    } else if (op.type == OP_DEL) {
      u32 pos, fp;
      if (htFind(c, op.u, op.v, pos, fp) && atomicCAS(&c.slots[pos], op.v, TOMB) == op.v) { atomicSub(&c.deg[op.u], 1u); r.r = 1; eff++; } else noop++;
    } else if (op.type == OP_READ) { u32 pos, fp; r.r = htFind(c, op.u, op.v, pos, fp); }
    else if (op.type == OP_SCAN) { scanPlain(c, op.u, r.r, r.aux); }
    c.res[b + j] = r;
  }
  st[ST_COMMITS]++; st[ST_EFFECTIVE] += eff; st[ST_NOOPS] += noop;
  c.rec[t].txid = 1; c.rec[t].attempts = 1;
}

// ---------------- STM (TL2-style) ----------------
struct Tx {
  u32 rv; bool ro; bool ab; int cause;
  u32 nrs, nws; u32 rs[RSMAX]; u32 wsW[WSMAX], wsV[WSMAX];
};
__device__ __forceinline__ u32* wordPtr(const Ctx& c, u32 w) { return w < c.S ? &c.slots[w] : &c.deg[w - c.S]; }
__device__ __forceinline__ u32 orecOf(const Ctx& c, u32 w) { return mix32(w * 2654435761u) & c.orecMask; }

__device__ u32 txRead(const Ctx& c, Tx& x, u32 w) {
  if (x.ab) return 0;
  for (int i = (int)x.nws - 1; i >= 0; i--) if (x.wsW[i] == w) return x.wsV[i];
  u32 o = orecOf(c, w);
  u32 o1 = vload(&c.orecs[o]);
  __threadfence();
  u32 val = vload(wordPtr(c, w));
  __threadfence();
  u32 o2 = vload(&c.orecs[o]);
  if ((o1 & 1) || o1 != o2 || (o1 >> 1) > x.rv) { x.ab = true; x.cause = AB_STM_READ; return 0; }
  if (!x.ro) { if (x.nrs >= RSMAX) { x.ab = true; x.cause = AB_RESOURCE; return 0; } x.rs[x.nrs++] = o; }
  return val;
}
__device__ void txWrite(const Ctx& c, Tx& x, u32 w, u32 v) {
  if (x.ab) return;
  for (u32 i = 0; i < x.nws; i++) if (x.wsW[i] == w) { x.wsV[i] = v; return; }
  if (x.nws >= WSMAX) { x.ab = true; x.cause = AB_RESOURCE; return; }
  x.wsW[x.nws] = w; x.wsV[x.nws] = v; x.nws++;
}
__device__ bool txProbe(const Ctx& c, Tx& x, u32 u, u32 v, u32& pos, u32& freePos) {
  u32 cap = c.tcap[u], base = c.tbase[u], p = mix32(v) & (cap - 1);
  freePos = EMPTY;
  for (u32 i = 0; i < cap && !x.ab; i++, p = (p + 1) & (cap - 1)) {
    u32 s = txRead(c, x, base + p);
    if (x.ab) return false;
    if (s == v) { pos = base + p; return true; }
    if (s == EMPTY) { if (freePos == EMPTY) freePos = base + p; return false; }
    if (s == TOMB && freePos == EMPTY) freePos = base + p;
  }
  return false;
}

__device__ bool runStmAttempt(const Ctx& c, u32 t, Tx& x, u32* st, u64& rts, u64& cts) {
  u32 b = c.off[t], K = c.off[t + 1] - b;
  x.ab = false; x.cause = -1; x.nrs = 0; x.nws = 0; x.ro = true;
  for (u32 j = 0; j < K; j++) { u32 ty = c.ops[b + j].type; if (ty == OP_INS || ty == OP_DEL) x.ro = false; }
  x.rv = vload(c.gclock);
  __threadfence();
  u32 eff = 0, noop = 0;
  for (u32 j = 0; j < K && !x.ab; j++) {
    Op op = c.ops[b + j]; OpResult r; r.r = 0; r.aux = 0; r.obs = 0; r.pad = 0;
    u32 pos, fp;
    if (op.type == OP_INS) {
      bool f = txProbe(c, x, op.u, op.v, pos, fp);
      if (x.ab) break;
      if (f) noop++;
      else if (fp != EMPTY) {
        txWrite(c, x, fp, op.v);
        if (!c.nodeg) { u32 d = txRead(c, x, c.S + op.u); txWrite(c, x, c.S + op.u, d + 1); }
        r.r = 1; eff++;
      }
    } else if (op.type == OP_DEL) {
      bool f = txProbe(c, x, op.u, op.v, pos, fp);
      if (x.ab) break;
      if (f) {
        txWrite(c, x, pos, TOMB);
        if (!c.nodeg) { u32 d = txRead(c, x, c.S + op.u); txWrite(c, x, c.S + op.u, d - 1); }
        r.r = 1; eff++;
      } else noop++;
    } else if (op.type == OP_READ) { r.r = txProbe(c, x, op.u, op.v, pos, fp); }
    else if (op.type == OP_SCAN) {
      u32 cap = c.tcap[op.u], base = c.tbase[op.u];
      for (u32 i = 0; i < cap && !x.ab; i++) { u32 s = txRead(c, x, base + i); if (s < TOMB) { r.r++; r.aux ^= mix32(s); } }
    }
    if (!x.ab) c.res[b + j] = r;
  }
  if (x.ab) return false;
  if (x.nws == 0) {  // read-only (or all no-ops): consistent snapshot at rv, no validation needed
    rts = x.rv; cts = x.rv;
    st[ST_EFFECTIVE] += eff; st[ST_NOOPS] += noop;
    return true;
  }
  // commit-time locking in sorted orec order
  u32 lk[WSMAX]; u32 nl = 0;
  for (u32 i = 0; i < x.nws; i++) {
    u32 o = orecOf(c, x.wsW[i]); bool dup = false;
    for (u32 k = 0; k < nl; k++) if (lk[k] == o) { dup = true; break; }
    if (!dup) lk[nl++] = o;
  }
  for (u32 i = 1; i < nl; i++) { u32 v = lk[i]; int k = i - 1; while (k >= 0 && lk[k] > v) { lk[k + 1] = lk[k]; k--; } lk[k + 1] = v; }
  u32 oldv[WSMAX]; u32 got = 0;
  for (; got < nl; got++) {
    bool ok = false;
    for (int spin = 0; spin < 8 && !ok; spin++) {
      u32 o = vload(&c.orecs[lk[got]]);
      if (!(o & 1) && atomicCAS(&c.orecs[lk[got]], o, o | 1) == o) { oldv[got] = o; ok = true; }
      else __nanosleep(20);
    }
    if (!ok) break;
  }
  auto releaseOld = [&](u32 n) { for (u32 i = 0; i < n; i++) atomicExch(&c.orecs[lk[i]], oldv[i]); };
  if (got < nl) { releaseOld(got); x.cause = AB_LOCK; st[ST_CAS_FAIL]++; return false; }
  u32 wv = atomicAdd(c.gclock, 1u) + 1;
  if (wv != x.rv + 1) {
    for (u32 i = 0; i < x.nrs; i++) {
      u32 o = x.rs[i], cur = vload(&c.orecs[o]);
      bool mine = false; u32 mv = 0;
      for (u32 k = 0; k < nl; k++) if (lk[k] == o) { mine = true; mv = oldv[k]; break; }
      u32 ver = mine ? mv : cur;
      if ((!mine && (cur & 1)) || (ver >> 1) > x.rv) { releaseOld(nl); x.cause = AB_STM_READ; return false; }
    }
  }
  for (u32 i = 0; i < x.nws; i++) vstore(wordPtr(c, x.wsW[i]), x.wsV[i]);
  __threadfence();
  for (u32 i = 0; i < nl; i++) atomicExch(&c.orecs[lk[i]], wv << 1);
  rts = wv - 1; cts = wv;
  st[ST_EFFECTIVE] += eff; st[ST_NOOPS] += noop;
  return true;
}

// ---------------- cooperative read-only transactions (fair-scan variant, c.coopRO) ----------------
// Every member of the coalesced group g runs its own read-only transaction; adjacency scans are executed by the
// whole group (strided), exactly like GTX-GPU's warp-cooperative scans. 2PL takes shared locks with bounded
// try-lock (release + retry on failure) so that no lane ever waits for a lock inside a group collective.
// STM validates every slot read against the scanner's read version rv (TL2 read-only rule).
__device__ bool runRoGroup(const Ctx& c, cg::coalesced_group g, bool active, u32 t, int mode, Tx& x, u32* st, u64& rts, u64& cts) {
  u32 b = active ? c.off[t] : 0, K = active ? c.off[t + 1] - b : 0;
  bool ok = active;
  u32 rv = 0, vs[MAXOPS], n = 0;
  if (ok && mode == M_STM) { rv = vload(c.gclock); __threadfence(); }
  if (ok && mode == M_2PL) {
    for (u32 j = 0; j < K; j++) { u32 u = c.ops[b + j].u, k = 0; for (; k < n; k++) if (vs[k] == u) break; if (k == n) vs[n++] = u; }
    for (u32 i = 1; i < n; i++) { u32 v = vs[i]; int k = i - 1; while (k >= 0 && vs[k] > v) { vs[k + 1] = vs[k]; k--; } vs[k + 1] = v; }
    u32 got = 0;
    for (; got < n; got++) {
      bool okl = false;
      for (int tr = 0; tr < 64 && !okl; tr++) {
        u32 w = vload(&c.locks[vs[got]]);
        if (!(w & WBIT) && atomicCAS(&c.locks[vs[got]], w, w + 1) == w) okl = true; else __nanosleep(32);
      }
      if (!okl) break;
    }
    if (got < n) { for (u32 i = 0; i < got; i++) atomicSub(&c.locks[vs[i]], 1u); ok = false; st[ST_CAS_FAIL]++; }
    __threadfence();
  }
  x.ab = false; x.cause = -1; x.nrs = 0; x.nws = 0; x.ro = true; x.rv = rv;
  u32 maxK = cg::reduce(g, ok ? K : 0u, cg::greater<u32>());
  for (u32 j = 0; j < maxK; j++) {
    bool has = ok && j < K;
    Op op; op.type = OP_NOP; op.u = 0; op.v = 0;
    if (has) op = c.ops[b + j];
    if (has && op.type == OP_READ) {
      OpResult r; r.r = 0; r.aux = 0; r.obs = 0; r.pad = 0; u32 pos, fp;
      if (mode == M_STM) { r.r = txProbe(c, x, op.u, op.v, pos, fp); if (x.ab) ok = false; }
      else r.r = htFind(c, op.u, op.v, pos, fp);
      if (ok) c.res[b + j] = r;
    }
    u32 m = g.ballot(has && ok && op.type == OP_SCAN);
    while (m) {
      u32 L = __ffs(m) - 1; m &= m - 1;
      u32 su = g.shfl(op.u, L), srv = g.shfl(rv, L);
      u32 cap = c.tcap[su], base = c.tbase[su], cnt = 0, hx = 0; bool bad = false;
      for (u32 i = g.thread_rank(); i < cap; i += g.size()) {
        u32 s;
        if (mode == M_STM) {
          u32 o = orecOf(c, base + i), o1 = vload(&c.orecs[o]); __threadfence();
          s = vload(&c.slots[base + i]); __threadfence();
          u32 o2 = vload(&c.orecs[o]);
          if ((o1 & 1) || o1 != o2 || (o1 >> 1) > srv) bad = true;
        } else s = vload(&c.slots[base + i]);
        if (s < TOMB) { cnt++; hx ^= mix32(s); }
      }
      cnt = cg::reduce(g, cnt, cg::plus<u32>());
      hx = cg::reduce(g, hx, cg::bit_xor<u32>());
      bool anyBad = g.any(bad);
      if (g.thread_rank() == L) {
        if (anyBad) { ok = false; x.cause = AB_STM_READ; }
        else { OpResult r; r.r = cnt; r.aux = hx; r.obs = 0; r.pad = 0; c.res[b + j] = r; }
      }
    }
  }
  // 2PL: on success the shared locks are still held and are released by the caller after recording the commit.
  return ok;
}

__global__ void kRun(Ctx c, int mode) {
  u32 st[ST_N]; for (int i = 0; i < ST_N; i++) st[i] = 0;
  u32 rng = mix32(blockIdx.x * blockDim.x + threadIdx.x + 777);
  Tx x;
  if (c.coopRO) {  // warp-synchronous iterations: read-only txns cooperate on scans, update txns run per thread
    const u32 lane = threadIdx.x & 31;
    for (;;) {
      u32 base = 0;
      if (lane == 0) base = atomicAdd(c.nextTxn, 32u);
      base = __shfl_sync(FULLMASK, base, 0);
      if (base >= c.N) break;
      u32 t = base + lane;
      bool mine = t < c.N;
      bool ro = mine;
      if (mine) for (u32 j = c.off[t]; j < c.off[t + 1]; j++) { u32 ty = c.ops[j].type; if (ty == OP_INS || ty == OP_DEL) ro = false; }
      u64 tb = gtimer();
      if (mine && ro) {
        cg::coalesced_group g = cg::coalesced_threads();
        bool done = false; u32 att = 0; u64 rts = 0, cts = 0;
        while (g.any(!done)) {
          bool act = !done && att < c.maxAttempts;
          bool ok = runRoGroup(c, g, act, t, mode, x, st, rts, cts);
          if (act) {
            att++;
            if (ok) {
              if (mode == M_2PL) {
                u32 s = c.record ? atomicAdd(c.seq, 1u) + 1 : 0;
                // release shared locks of this txn (recompute its distinct vertex set)
                u32 b = c.off[t], K = c.off[t + 1] - b, vs[MAXOPS], n = 0;
                for (u32 j = 0; j < K; j++) { u32 u = c.ops[b + j].u, k = 0; for (; k < n; k++) if (vs[k] == u) break; if (k == n) vs[n++] = u; }
                __threadfence();
                for (u32 i = 0; i < n; i++) atomicSub(&c.locks[vs[i]], 1u);
                rts = s ? s - 1 : 0; cts = s;
              } else if (mode == M_STM) { rts = x.rv; cts = x.rv; }
              done = true;
            } else if (mode == M_STM || mode == M_2PL) {
              st[ST_ABORTS]++; st[ST_ABORT_BASE + (mode == M_STM ? AB_STM_READ : AB_LOCK)]++;
            }
            if (!ok && att >= c.maxAttempts) done = true;
          }
        }
        TxRecord r; r.rts = rts; r.cts = cts; r.txid = 1; r.attempts = att; r.tBegin = tb; r.tEnd = gtimer();
        c.rec[t] = r; st[ST_COMMITS]++;
      } else if (mine) {
        if (mode == M_2PL) run2pl(c, t, rng, st);
        else if (mode == M_NONTX) runNonTx(c, t, st);
        else {
          u32 att = 0; bool ok = false; u64 rts = 0, cts = 0;
          while (!ok && att < c.maxAttempts) {
            ok = runStmAttempt(c, t, x, st, rts, cts);
            att++;
            if (!ok) { st[ST_ABORTS]++; st[ST_ABORT_BASE + (x.cause < 0 ? AB_STM_READ : x.cause)]++; if (x.cause == AB_RESOURCE) break; backoffSleep(rng, att); }
          }
          TxRecord r; r.rts = rts; r.cts = cts; r.txid = ok ? 1 : 0; r.attempts = att; r.tBegin = tb; r.tEnd = gtimer();
          c.rec[t] = r;
          if (ok) st[ST_COMMITS]++; else st[ST_GIVEUP]++;
        }
        if (mode != M_STM) { c.rec[t].tBegin = tb; c.rec[t].tEnd = gtimer(); }
      }
      __syncwarp();
    }
    for (int i = 0; i < ST_N; i++) if (st[i]) atomicAdd(&c.stats[i], st[i]);
    return;
  }
  for (;;) {
    u32 t = atomicAdd(c.nextTxn, 1u);
    if (t >= c.N) break;
    u64 tb = gtimer();
    if (mode == M_2PL) run2pl(c, t, rng, st);
    else if (mode == M_NONTX) runNonTx(c, t, st);
    else {
      u32 att = 0; bool ok = false; u64 rts = 0, cts = 0;
      while (!ok && att < c.maxAttempts) {
        ok = runStmAttempt(c, t, x, st, rts, cts);
        att++;
        if (!ok) { st[ST_ABORTS]++; st[ST_ABORT_BASE + (x.cause < 0 ? AB_STM_READ : x.cause)]++; if (x.cause == AB_RESOURCE) break; backoffSleep(rng, att); }
      }
      TxRecord r; r.rts = rts; r.cts = cts; r.txid = ok ? 1 : 0; r.attempts = att; r.tBegin = tb; r.tEnd = gtimer();
      c.rec[t] = r;
      if (ok) st[ST_COMMITS]++; else st[ST_GIVEUP]++;
      continue;
    }
    c.rec[t].tBegin = tb; c.rec[t].tEnd = gtimer();
  }
  for (int i = 0; i < ST_N; i++) if (st[i]) atomicAdd(&c.stats[i], st[i]);
}

// ---------------- host wrapper ----------------
struct Store {
  Ctx c{}; u32 *dTbase = nullptr, *dTcap = nullptr; std::vector<u32> hTbase, hTcap; std::vector<u32> hSlots, hDeg;
  int gridBlocks = 0, blockThreads = 128; size_t bytes = 0;

  // Size tables from the workload (initial edges + all inserts) and pre-load the initial graph.
  void init(const HostWorkload& w, u32 orecBits = 22) {
    u32 V = w.V; std::vector<u32> cnt(V, 0);
    for (auto& e : w.initEdges) cnt[e.first]++;
    for (auto& o : w.ops) if (o.type == OP_INS) cnt[o.u]++;
    hTbase.resize(V); hTcap.resize(V);
    u64 S = 0;
    for (u32 u = 0; u < V; u++) { u32 need = cnt[u] * 2 < 8 ? 8 : cnt[u] * 2; u32 cap = 1; while (cap < need) cap <<= 1; hTcap[u] = cap; hTbase[u] = (u32)S; S += cap; }
    c.S = (u32)S; c.V = V;
    hSlots.assign(S, EMPTY); hDeg.assign(V, 0);
    for (auto& e : w.initEdges) {
      u32 u = e.first, v = e.second, cap = hTcap[u], p = mix32(v) & (cap - 1);
      while (hSlots[hTbase[u] + p] != EMPTY) p = (p + 1) & (cap - 1);
      hSlots[hTbase[u] + p] = v; hDeg[u]++;
    }
    CK(cudaMalloc(&dTbase, V * 4)); CK(cudaMalloc(&dTcap, V * 4));
    CK(cudaMemcpy(dTbase, hTbase.data(), V * 4, cudaMemcpyHostToDevice)); CK(cudaMemcpy(dTcap, hTcap.data(), V * 4, cudaMemcpyHostToDevice));
    c.tbase = dTbase; c.tcap = dTcap;
    CK(cudaMalloc(&c.slots, S * 4)); CK(cudaMalloc(&c.deg, V * 4)); CK(cudaMalloc(&c.locks, V * 4));
    c.orecMask = (1u << orecBits) - 1; CK(cudaMalloc(&c.orecs, (size_t)(c.orecMask + 1) * 4));
    u32* ctr; CK(cudaMalloc(&ctr, 64 * 4)); c.gclock = ctr; c.nextTxn = ctr + 1; c.seq = ctr + 2;
    CK(cudaMalloc(&c.stats, ST_N * 4));
    bytes = S * 4 + V * 12 + (size_t)(c.orecMask + 1) * 4;
    reset();
    int dev; CK(cudaGetDevice(&dev)); cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    int perSM = 0; CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&perSM, kRun, blockThreads, 0));
    gridBlocks = p.multiProcessorCount * (perSM > 0 ? perSM : 1);
  }
  void reset() {
    CK(cudaMemcpy(c.slots, hSlots.data(), (size_t)c.S * 4, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(c.deg, hDeg.data(), c.V * 4, cudaMemcpyHostToDevice));
    CK(cudaMemset(c.locks, 0, c.V * 4)); CK(cudaMemset(c.orecs, 0, (size_t)(c.orecMask + 1) * 4));
    u32 z[3] = {1, 0, 0}; CK(cudaMemcpy(c.gclock, z, 12, cudaMemcpyHostToDevice));
  }
  void release() { cudaFree(dTbase); cudaFree(dTcap); cudaFree(c.slots); cudaFree(c.deg); cudaFree(c.locks); cudaFree(c.orecs); cudaFree(c.gclock); cudaFree(c.stats); }
  float run(int mode, const u32* dOff, const Op* dOps, u32 N, OpResult* dRes, TxRecord* dRec, u32* hStats, int record, int nodeg, u32 maxAttempts = 4000, int coopRO = 0) {
    c.coopRO = coopRO;
    c.off = dOff; c.ops = dOps; c.N = N; c.res = dRes; c.rec = dRec; c.record = record; c.nodeg = nodeg; c.maxAttempts = maxAttempts;
    CK(cudaMemset(c.nextTxn, 0, 4)); CK(cudaMemset(c.seq, 0, 4)); CK(cudaMemset(c.stats, 0, ST_N * 4));
    int blocks = gridBlocks; u32 needB = (N + blockThreads - 1) / blockThreads; if ((u32)blocks > needB) blocks = needB ? needB : 1;
    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a)); kRun<<<blocks, blockThreads>>>(c, mode); CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b)); CK(cudaGetLastError());
    float ms = 0; CK(cudaEventElapsedTime(&ms, a, b)); CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    if (hStats) CK(cudaMemcpy(hStats, c.stats, ST_N * 4, cudaMemcpyDeviceToHost));
    return ms;
  }
  void finalEdges(std::vector<std::pair<u32, u32>>& out) {
    std::vector<u32> s(c.S); CK(cudaMemcpy(s.data(), c.slots, (size_t)c.S * 4, cudaMemcpyDeviceToHost));
    for (u32 u = 0; u < c.V; u++) for (u32 i = 0; i < hTcap[u]; i++) { u32 x = s[hTbase[u] + i]; if (x < TOMB) out.push_back({u, x}); }
  }
};

}  // namespace bl

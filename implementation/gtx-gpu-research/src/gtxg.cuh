// GTX-GPU: a GPU adaptation of GTX (Zhou et al., VLDB 2024/2025) for atomic multi-edge
// transactions with concurrent readers.
//
// Retained from GTX: versioned edge deltas (creation / invalidation stamps), per-vertex edge-delta
// blocks, destination-hashed delta chains used for write-write conflict detection, transaction
// descriptors resolved lazily by readers, group commit, post-commit lazy timestamp stamping.
//
// GPU-specific changes (each switchable for ablation, see Cfg):
//  * coop    : cooperative (warp-aggregated) delta reservation -- one fetch_add per (warp, block)
//  * dstconf : destination-precise conflict detection with validate-then-CAS on the SAME observed
//              chain head (prefix re-walk on CAS failure). dstconf=0 = GTX chain-granularity rule.
//  * epochs  : commit groups -- txns register in the open epoch with one fetch_add on (epoch,count), a single
//              advancer publishes a read frontier F only after every epoch <= F is fully published.
//  * block generations : a full block is never copied under writers; a new generation (2x) is
//              linked in front and older generations' chain heads are sealed lazily by writers.
//
// Descriptor word: 0 ACTIVE, 1 ABORTED, (e<<2)|2 COMMITTED at epoch e.
#pragma once
#include "common.cuh"

namespace gtxg {

constexpr u32 NILD = 0x7FFFFFFFu;   // null delta index
constexpr u32 SEAL = 0x80000000u;   // chain-head sealed bit (older generation: no more installs)
constexpr u32 NONEB = 0xFFFFFFFFu;  // vertex has no block yet
constexpr u32 PENDB = 0xFFFFFFFEu;  // first block being created
constexpr u32 OPB_INS = 1, OPB_DEL = 2, OPB_VOID = 3;
constexpr u64 TAGBIT = 1ull << 63;
constexpr int MAXOPS = 32;
constexpr u32 SCANV = 0xFFFFFFFFu;  // read-set marker for scan entries

struct Delta { u32 dstop; u32 prev; u32 owner; u32 pad; u64 cts; u64 its; };
struct Block { u32 base, cap, nch, chBase, fill, prevGen, vtx, pad; };

struct Cfg {
  int coop = 1;       // cooperative warp-aggregated reservation
  int dstconf = 1;    // destination-precise conflicts (0 = GTX chain granularity)
  int ser = 0;        // serializable validation (0 = snapshot isolation)
  int stamp = 1;      // lazy post-commit stamping
  int coopScan = 1;   // warp-cooperative adjacency scans
  int mut = 0;        // checker-sensitivity mutations: 1 no ww check, 2 dirty reads, 3 ignore snapshot
  u32 minCap = 8;
  u32 chRatio = 1;    // chain heads per block slot divisor (1 = one head per slot)
  u32 maxAttempts = 4000;
  u32 advanceNs = 0;
  u32 growShift = 3;  // new generation capacity = old capacity << growShift (8x)
  int prewalk = 0;    // optimistic read-only pre-walk before reserving a slot
  int dbg = 0;        // profiling ablations: 1 skip install walk/CAS, 2 skip result writes, 4 skip commit
};

struct Ctx {
  u32 V;
  u32* vcur;       // current generation, read by walkers/scanners (published before vfill)
  u64* vfill;      // writers' reservation word: (generation << 32) | slots reserved
  Block* B; u32* bTop; u32 bCap;
  Delta* D; u32* dTop; u32 dCap;
  u32* H; u32* hTop; u32 hCap;
  u64* desc; u32* txTop; u32 descCap;
  u64* E; u64* frontier; u32* inflight; u32* stop; u32* oom;
  const u32* off; const Op* ops; u32 N; u32* nextTxn;
  OpResult* res; TxRecord* rec;
  u32* stats; u32* doneWarps; u32 nWorkWarps;
  u32* dbgBuf = nullptr; u32* dbgTop = nullptr; u32 dbgCap = 0;  // forensic: counted delta ids per per-lane scan
  u64 watchdogNs;  // per-warp wall-clock limit; on expiry *oom = 2 and remaining work gives up
  Cfg cfg;
};

template <class T> __device__ __forceinline__ cuda::atomic_ref<T, cuda::thread_scope_device> AR(T& x) {
  return cuda::atomic_ref<T, cuda::thread_scope_device>(x);
}
#define ACQ cuda::memory_order_acquire
#define REL cuda::memory_order_release
#define RLX cuda::memory_order_relaxed
#define SEQ cuda::memory_order_seq_cst
#define ACQREL cuda::memory_order_acq_rel

enum Vis { V_SELF = 0, V_VIS = 1, V_LATE = 2, V_ACTIVE = 3, V_ABORTED = 4 };

__device__ __forceinline__ int resolveTx(const Ctx& c, u32 owner, u32 self, u64 rts) {
  if (owner == self) return V_SELF;
  u64 d = AR(c.desc[owner]).load(ACQ);
  if (d & 2) return ((d >> 2) <= rts || c.cfg.mut == 3) ? V_VIS : V_LATE;
  if (d == 1) return V_ABORTED;
  return c.cfg.mut == 2 ? V_VIS : V_ACTIVE;
}

__device__ __forceinline__ int createVis(const Ctx& c, Delta* d, u32 owner, u32 self, u64 rts) {
  if (owner == self) return V_SELF;
  u64 cts = AR(d->cts).load(RLX);
  if (cts) return (cts <= rts || c.cfg.mut == 3) ? V_VIS : V_LATE;
  return resolveTx(c, owner, self, rts);
}

// Is a visible INS delta invalidated for (self, rts)?
__device__ __forceinline__ bool invalidated(const Ctx& c, Delta* d, u32 self, u64 rts) {
  u64 its = AR(d->its).load(ACQ);
  if (!its) return false;
  if (its & TAGBIT) { int k = resolveTx(c, (u32)its, self, rts); return k == V_SELF || k == V_VIS; }
  return its <= rts || c.cfg.mut == 3;
}

struct WalkOut { u32 cur; int present; int cause; };

// Walk one chain newest-first from idx to stop (exclusive).
// writer: first-updater-wins rules; reader: first visible version.  Returns 0 none, 1 found, 2 abort.
__device__ int walkChain(const Ctx& c, u32 idx, u32 stop, u32 v, u32 self, u64 rts, bool writer,
                         bool& chainChecked, WalkOut& o) {
  u32 steps = 0;
  while (idx != NILD && idx != stop) {
    if (++steps > (1u << 24)) { atomicOr(c.oom, 8u); o.cause = AB_RESOURCE; return 2; }  // corrupt chain guard
    Delta* d = &c.D[idx];
    u32 owner = AR(d->owner).load(ACQ);
    u32 dstop = AR(d->dstop).load(RLX), dst = dstop & 0x3FFFFFFFu, op = dstop >> 30;
    u32 nxt = AR(d->prev).load(RLX);
    if (op == OPB_VOID) { idx = nxt; continue; }
    int k = createVis(c, d, owner, self, rts);
    if (writer && !chainChecked && !c.cfg.dstconf && k != V_ABORTED) {
      chainChecked = true;  // GTX rule: the chain's newest live delta must be visible (or ours)
      if ((k == V_ACTIVE || k == V_LATE) && c.cfg.mut != 1) {
        o.cause = (dst == v) ? (k == V_ACTIVE ? AB_WW_PENDING : AB_WW_LATE) : AB_CHAIN_FALSE;
        return 2;
      }
    }
    if (dst == v) {
      if (writer) {
        if (k == V_ACTIVE || k == V_LATE) {
          if (c.cfg.mut != 1) { o.cause = (k == V_ACTIVE) ? AB_WW_PENDING : AB_WW_LATE; return 2; }
        } else if (k != V_ABORTED) { o.cur = idx; o.present = (op == OPB_INS); return 1; }
      } else if (k == V_SELF || k == V_VIS) { o.cur = idx; o.present = (op == OPB_INS); return 1; }
    }
    idx = nxt;
  }
  return 0;
}

__device__ __forceinline__ u32 headSlot(const Block* b, u32 v) { return b->chBase + (mix32(v) & (b->nch - 1)); }

// Walk all generations of u newest-first starting at generation g with top-generation head h0.
// seal: seal older generations' heads before walking them (required for writers).
__device__ int walkGens(const Ctx& c, u32 g, u32 h0, u32 v, u32 self, u64 rts, bool writer, bool seal, WalkOut& o) {
  bool cc = false;
  int r = walkChain(c, h0 & NILD, NILD, v, self, rts, writer, cc, o);
  if (r) return r;
  u32 pg = c.B[g].prevGen;
  while (pg < PENDB) {
    Block* b = &c.B[pg];
    u32 hs = headSlot(b, v);
    u32 h = AR(c.H[hs]).load(ACQ);
    if (seal && !(h & SEAL)) h = AR(c.H[hs]).fetch_or(SEAL, ACQREL) | SEAL;
    bool cc2 = true;
    r = walkChain(c, h & NILD, NILD, v, self, rts, writer, cc2, o);
    if (r) return r;
    pg = b->prevGen;
  }
  return 0;
}

// Read-only walk from the vertex's current generation.
__device__ int walkFromCurrent(const Ctx& c, u32 u, u32 v, u32 self, u64 rts, bool writer, WalkOut& o) {
  o.cur = NILD; o.present = 0; o.cause = -1;
  u32 g = AR(c.vcur[u]).load(ACQ);
  if (g >= PENDB) return 0;
  u32 h0 = AR(c.H[headSlot(&c.B[g], v)]).load(ACQ);
  return walkGens(c, g, h0, v, self, rts, writer, false, o);
}

// Serializable validation of a point observation: newest non-aborted foreign version must be obs.
__device__ bool validatePoint(const Ctx& c, u32 u, u32 v, u32 obs, u32 self) {
  u32 g = AR(c.vcur[u]).load(ACQ);
  while (g < PENDB) {
    Block* b = &c.B[g];
    u32 idx = AR(c.H[headSlot(b, v)]).load(ACQ) & NILD;
    while (idx != NILD) {
      Delta* d = &c.D[idx];
      u32 owner = AR(d->owner).load(ACQ);
      u32 dstop = AR(d->dstop).load(RLX);
      if ((dstop & 0x3FFFFFFFu) == v && (dstop >> 30) != OPB_VOID && owner != self) {
        bool aborted = (AR(d->cts).load(RLX) == 0) && AR(c.desc[owner]).load(ACQ) == 1;
        if (!aborted) return idx == obs;
      }
      idx = AR(d->prev).load(RLX);
    }
    g = b->prevGen;
  }
  return obs == NILD;
}

// Scan of vertex u for (self, rts). mode 0: count visible neighbours. mode 1: serializable validation.
// Per-lane body over slot range [lo, n) stepping by `step`.
__device__ __forceinline__ void scanBody(const Ctx& c, u32 u, u32 self, u64 rts, int mode, u32 lo, u32 step,
                                         u32& cnt, u32& hx, bool& bad, u32* dbgOut = nullptr, u32 dbgMax = 0) {
  u32 g = AR(c.vcur[u]).load(ACQ);
  u32 ngen = 0;
  while (g < PENDB) {
    Block* b = &c.B[g];
    u64 w = AR(c.vfill[u]).load(RLX);
    u32 f = ((u32)(w >> 32) == g && !(c.cfg.dbg & 8)) ? (u32)w : b->cap;  // older generations are full (or sealed)
    u32 n = f < b->cap ? f : b->cap;
    if (dbgOut && ngen < 12) { dbgOut[dbgMax - 24 + 2 * ngen] = g; dbgOut[dbgMax - 23 + 2 * ngen] = n; ngen++; }
    for (u32 i = lo; i < n; i += step) {
      Delta* d = &c.D[b->base + i];
      u32 owner = AR(d->owner).load(ACQ);
      const bool rec = dbgOut && ngen == 1 && i < 2024;
      if (!owner) { if (rec) dbgOut[1024 + i] = 1; continue; }
      u32 dstop = AR(d->dstop).load(RLX), op = dstop >> 30;
      if (op == OPB_VOID) { if (rec) dbgOut[1024 + i] = 2; continue; }
      int k = createVis(c, d, owner, self, rts);
      if (rec) dbgOut[1024 + i] = 10 + k + (op == OPB_INS ? 0 : 50) + ((k == V_VIS && op == OPB_INS && invalidated(c, d, self, rts)) ? 100 : 0);
      if (mode == 0) {
        if (op == OPB_INS && (k == V_SELF || k == V_VIS) && !invalidated(c, d, self, rts)) {
          if (dbgOut && cnt < 1024) dbgOut[cnt] = b->base + i;
          cnt++; hx ^= mix32(dstop & 0x3FFFFFFFu);
        }
      } else {
        if (k == V_SELF || k == V_ABORTED) continue;
        if (k == V_VIS) {
          u64 its = AR(d->its).load(ACQ);
          if (its) {
            if (its & TAGBIT) {
              u32 t = (u32)its;
              if (t != self) { int kk = resolveTx(c, t, self, rts); if (kk == V_ACTIVE || kk == V_LATE) bad = true; }
            } else if (its > rts) bad = true;
          }
        } else bad = true;  // pending or committed after snapshot: phantom / concurrent change
      }
    }
    g = b->prevGen;
  }
  if (dbgOut && ngen < 12) dbgOut[dbgMax - 24 + 2 * ngen] = 0xFFFFFFFFu;
}

__device__ void allocBlock(const Ctx& c, u32 u, u32 old, u32& nGrow) {
  u32 cap = (old >= PENDB) ? c.cfg.minCap : (c.B[old].cap << c.cfg.growShift);
  u32 nch = cap / c.cfg.chRatio; if (nch < 1) nch = 1;
  u32 base = atomicAdd(c.dTop, cap), chb = atomicAdd(c.hTop, nch), bid = atomicAdd(c.bTop, 1);
  if ((u64)base + cap > c.dCap || (u64)chb + nch > c.hCap || bid >= c.bCap) { atomicOr(c.oom, 1u); return; }
  Block nb; nb.base = base; nb.cap = cap; nb.nch = nch; nb.chBase = chb; nb.fill = 0; nb.prevGen = old; nb.vtx = u; nb.pad = 0;
  c.B[bid] = nb;
  __threadfence();
  AR(c.vcur[u]).store(bid, REL);                  // readers first ...
  AR(c.vfill[u]).store((u64)bid << 32, REL);      // ... then open the generation to writers
  nGrow++;
}

enum InstallRes { IN_EFF = 0, IN_NOOP = 1, IN_ABORT = 2, IN_RESEAL = 3 };

__device__ int install(const Ctx& c, const Op& op, u32 self, u64 rts, u32 g, u32 slot, WalkOut& o, u32& nCasFail, u32& nVoid) {
  Block* b = &c.B[g];
  u32 hs = headSlot(b, op.v);
  Delta* d = &c.D[slot];
  o.cur = NILD; o.present = 0; o.cause = -1;
  u32 h0 = AR(c.H[hs]).load(ACQ);
  int r = 0;
  bool reseal = (h0 & SEAL) != 0;
  if (!reseal) r = walkGens(c, g, h0, op.v, self, rts, true, true, o);
  bool eff = false;
  if (!reseal && r != 2) { bool present = (r == 1) && o.present; eff = (op.type == OP_INS) ? !present : present; }
  if (!eff) {
    d->dstop = (OPB_VOID << 30) | op.v; d->prev = NILD;
    AR(d->owner).store(self, RLX); nVoid++;
    return reseal ? IN_RESEAL : (r == 2 ? IN_ABORT : IN_NOOP);
  }
  d->dstop = ((op.type == OP_INS ? OPB_INS : OPB_DEL) << 30) | op.v;
  d->prev = h0 & NILD; d->cts = 0; d->its = 0;
  // Relaxed: chain walkers see contents through the head CAS (release sequence); scanners only use a
  // delta once it is visible, which is established by the owner's commit release / frontier acquire.
  AR(d->owner).store(self, RLX);
  for (;;) {
    u32 exp = h0;
    if (AR(c.H[hs]).compare_exchange_strong(exp, slot, ACQREL, ACQ)) return IN_EFF;
    nCasFail++;
    bool bad = (exp & SEAL) != 0;
    int rr = 0;
    if (!bad) {
      bool cc = false; WalkOut o2; o2.cause = -1;
      rr = walkChain(c, exp & NILD, h0 & NILD, op.v, self, rts, true, cc, o2);  // only the new prefix
      if (rr == 2) o.cause = o2.cause; else if (rr == 1) o.cause = AB_WW_LATE;
    }
    if (bad || rr) {
      d->dstop = (OPB_VOID << 30) | op.v; nVoid++;
      return bad ? IN_RESEAL : IN_ABORT;
    }
    d->prev = exp & NILD;
    h0 = exp;
  }
}

__device__ void advancerLoop(const Ctx& c) {
  u32 n = 0;
  const u64 deadline = gtimer() + c.watchdogNs;
  // *E = (epoch << 32) | committers registered in that epoch.  Closing epoch e is one exchange that
  // atomically opens e+1 and returns how many committers registered in e; the frontier is published
  // once exactly that many have signalled completion on done[e & 1].  Committers never retry.
  while (!AR(*c.stop).load(ACQ)) {
    u64 e = AR(*c.E).load(RLX) >> 32;
    u64 old = AR(*c.E).exchange((e + 1) << 32, ACQREL);
    u32 reg = (u32)old;
    // Never publish early: on the deadline only raise the diagnostic flag and keep waiting (publishing
    // a frontier past unfinished committers breaks snapshot reads -- found by the checker).
    bool flagged = false, dead = false;
    while (AR(c.inflight[e & 1]).load(ACQ) != reg) {
      u64 now = gtimer();
      if (!flagged && now > deadline) { atomicOr(c.oom, 4u); flagged = true; }
      if (now > deadline + c.watchdogNs) {  // run is INVALID (flag 16): record the stuck epoch and stop publishing
        c.nextTxn[2] = (u32)e; c.nextTxn[3] = reg; c.nextTxn[4] = AR(c.inflight[e & 1]).load(ACQ);
        atomicOr(c.oom, 16u); dead = true; break;
      }
    }
    if (dead) break;
    AR(c.inflight[e & 1]).store(0u, RLX);  // no one can register in e any more; e+2 reuses the slot
    AR(*c.frontier).store(e, REL);
    n++;
    if (c.cfg.advanceNs) __nanosleep(c.cfg.advanceNs);
  }
  atomicAdd(&c.stats[ST_EPOCHS], n);
}

struct LaneStats { u32 commits, eff, noops, slots, voided, grows, casFail, resv, giveup; u32 ab[AB_NCAUSES]; u64 prof[6]; };
// prof: 0 begin, 1 op loop, 2 install (inside 1), 3 validation, 4 commit, 5 stamping  (SM cycles)

// One attempt of each active lane's transaction. Warp-collective: every lane of the warp calls it.
// Returns true if this lane committed.
__device__ bool attempt(const Ctx& c, bool act, u32 cur, u64& rtsO, u64& ctsO, u32& selfO, int& causeO, LaneStats& st) {
  const u32 lane = threadIdx.x & 31;
  u64 pc0 = clock64();
  u32 self = warpAggInc(c.txTop, act);
  bool alive = act;
  int cause = -1;
  if (act && self >= c.descCap) { alive = false; cause = AB_RESOURCE; }
  u64 rts = act ? AR(*c.frontier).load(ACQ) : 0;
  u32 b0 = act ? c.off[cur] : 0, K = act ? c.off[cur + 1] - b0 : 0;
  u32 maxK = __reduce_max_sync(FULLMASK, K);
  u32 nMy = 0, nSup = 0, nRd = 0, nEff = 0, nNoop = 0;
  u32 myD[MAXOPS], sup[MAXOPS], rdU[MAXOPS], rdV[MAXOPS], rdO[MAXOPS];

  u64 pc1 = clock64(); st.prof[0] += pc1 - pc0;
  for (u32 j = 0; j < maxK; j++) {
    bool has = alive && j < K;
    Op op; op.type = OP_NOP; op.u = 0; op.v = 0;
    if (has) op = c.ops[b0 + j];

    // ---- adjacency scans
    bool sc = has && op.type == OP_SCAN;
    if (c.cfg.coopScan) {
      u32 m = __ballot_sync(FULLMASK, sc);
      while (m) {
        u32 L = __ffs(m) - 1; m &= m - 1;
        u32 su = __shfl_sync(FULLMASK, op.u, L), ss = __shfl_sync(FULLMASK, self, L);
        u64 sr = __shfl_sync(FULLMASK, rts, L);
        u32 cnt = 0, hx = 0; bool bad = false;
        scanBody(c, su, ss, sr, 0, lane, 32, cnt, hx, bad);
        cnt = __reduce_add_sync(FULLMASK, cnt);
        hx = __reduce_xor_sync(FULLMASK, hx);
        if (lane == L) { OpResult rr; rr.r = cnt; rr.aux = hx; rr.obs = NILD; rr.pad = 0; c.res[b0 + j] = rr; }
      }
    } else if (sc) {
      u32 cnt = 0, hx = 0; bool bad = false;
      u32 doff = 0xFFFFFFFFu; u32* dout = nullptr;
      if (c.dbgBuf) { doff = (b0 + j) * 3072u; if ((u64)doff + 3072 <= c.dbgCap) dout = c.dbgBuf + doff; else doff = 0xFFFFFFFFu; }
      scanBody(c, op.u, self, rts, 0, 0, 1, cnt, hx, bad, dout, 3072);
      OpResult rr; rr.r = cnt; rr.aux = hx; rr.obs = NILD; rr.pad = doff; c.res[b0 + j] = rr;
    }
    if (sc && c.cfg.ser) { rdU[nRd] = op.u; rdV[nRd] = SCANV; rdO[nRd] = NILD; nRd++; }

    // ---- point reads
    if (has && op.type == OP_READ) {
      WalkOut o; walkFromCurrent(c, op.u, op.v, self, rts, false, o);
      OpResult rr; rr.r = o.present; rr.aux = 0; rr.obs = o.cur; rr.pad = 0; c.res[b0 + j] = rr;
      if (c.cfg.ser && (o.cur == NILD || c.D[o.cur].owner != self)) { rdU[nRd] = op.u; rdV[nRd] = op.v; rdO[nRd] = o.cur; nRd++; }
    }

    // ---- writes: optimistic pre-walk (no sealing) filters no-ops and certain conflicts
    bool wr = has && (op.type == OP_INS || op.type == OP_DEL);
    bool needSlot = false;
    if (wr) {
      WalkOut o; int r = 1; o.cur = NILD; o.present = (op.type == OP_DEL); o.cause = -1;
      if (c.cfg.prewalk) r = walkFromCurrent(c, op.u, op.v, self, rts, true, o);
      if (r == 2) { alive = false; cause = o.cause; }
      else {
        bool present = (r == 1) && o.present;
        bool eff = (op.type == OP_INS) ? !present : present;
        if (eff) needSlot = true;
        else {
          OpResult rr; rr.r = 0; rr.aux = 0; rr.obs = o.cur; rr.pad = 0; c.res[b0 + j] = rr; nNoop++;
          if (c.cfg.ser && (o.cur == NILD || c.D[o.cur].owner != self)) { rdU[nRd] = op.u; rdV[nRd] = op.v; rdO[nRd] = o.cur; nRd++; }
        }
      }
    }

    // ---- reservation + install (collective loop)
    while (__any_sync(FULLMASK, needSlot)) {
      // One fetch_add on the fused (generation, fill) word per (warp, vertex) group returns both the
      // generation and a contiguous slot range. The lane whose slot equals the capacity (or slot 0 of the
      // "no block" generation) is the unique grower; lanes past the capacity wait for the new generation.
      u32 key = needSlot ? op.u : (0xF0000000u | lane);
      u32 grp = c.cfg.coop ? __match_any_sync(FULLMASK, key) : (1u << lane);
      u32 leader = __ffs(grp) - 1, cnt = __popc(grp), rank = __popc(grp & lanemask_lt());
      u64 wv = 0;
      // ACQREL, not relaxed: the reservation must synchronize with the grower's release of the new
      // generation (vcur is stored before vfill), so that everything this txn later publishes carries a
      // happens-before edge to the generation link. With RLX a scanner whose snapshot covers our commit
      // could still load a stale vcur and skip the generation holding our delta (found by the checker).
      if (needSlot && lane == leader) { wv = (c.cfg.dbg & 32) ? AR(c.vfill[op.u]).fetch_add((u64)cnt, RLX) : AR(c.vfill[op.u]).fetch_add((u64)cnt, ACQREL); st.resv++; }
      if (c.cfg.coop) wv = __shfl_sync(FULLMASK, wv, leader);
      u32 g = (u32)(wv >> 32), slot = NILD;
      bool ready = false;
      if (needSlot) {
        u32 s = (u32)wv + rank;
        if (g == NONEB) { if (s == 0) allocBlock(c, op.u, NONEB, st.grows); }
        else {
          Block* bk = &c.B[g];
          if (s < bk->cap) { slot = bk->base + s; ready = true; }
          else if (s == bk->cap) allocBlock(c, op.u, g, st.grows);
        }
        if (!ready && AR(*c.oom).load(RLX)) { needSlot = false; alive = false; cause = AB_RESOURCE; }
      }
      if (slot != NILD) {
        st.slots++;
        WalkOut o;
        u64 pi0 = clock64();
        int ir;
        if (c.cfg.dbg & 1) { Delta* dd = &c.D[slot]; dd->dstop = (OPB_INS << 30) | op.v; dd->prev = NILD; AR(dd->owner).store(self, RLX); o.cur = NILD; ir = IN_EFF; }
        else ir = install(c, op, self, rts, g, slot, o, st.casFail, st.voided);
        st.prof[2] += clock64() - pi0;
        if (ir == IN_EFF) {
          needSlot = false; nEff++;
          myD[nMy++] = slot;
          if (op.type == OP_DEL) { AR(c.D[o.cur].its).store(TAGBIT | self, RLX); sup[nSup++] = o.cur; }
          if (!(c.cfg.dbg & 2)) { OpResult rr; rr.r = 1; rr.aux = 0; rr.obs = o.cur; rr.pad = 0; c.res[b0 + j] = rr; }
        } else if (ir == IN_NOOP) {
          needSlot = false; nNoop++;
          OpResult rr; rr.r = 0; rr.aux = 0; rr.obs = o.cur; rr.pad = 0; c.res[b0 + j] = rr;
          if (c.cfg.ser && (o.cur == NILD || c.D[o.cur].owner != self)) { rdU[nRd] = op.u; rdV[nRd] = op.v; rdO[nRd] = o.cur; nRd++; }
        } else if (ir == IN_ABORT) { needSlot = false; alive = false; cause = o.cause; }
      } else if (needSlot) {
        __nanosleep(64);  // waiting for a new generation
      }
    }
  }

  u64 pc2 = clock64(); st.prof[1] += pc2 - pc1;
  // ---- commit epoch + serializable validation (writes are already "locked" by pending deltas)
  // Writers register in the open epoch with one fetch_add on (epoch, count).  In serializable mode the
  // epoch is fixed BEFORE read validation (Silo order): any writer U that overwrites something T read
  // installs after T's validation, hence registers after T, so cts(U) >= cts(T) and every dependency
  // edge is non-decreasing in cts.  That makes the frontier snapshot a dependency-closed prefix, which
  // is why transactions without effective writes commit at cts = rts with no validation/registration.
  const bool early = c.cfg.ser != 0 && !(c.cfg.dbg & 16);
  u64 e = 0;
  u32 reg = 0, regLeader = 0;
  auto registerEpoch = [&](bool want) {
    reg = __ballot_sync(FULLMASK, want);
    if (reg) {
      regLeader = __ffs(reg) - 1;
      if (lane == regLeader) e = AR(*c.E).fetch_add((u64)__popc(reg), ACQREL) >> 32;  // wait-free
      e = __shfl_sync(FULLMASK, e, regLeader);
    }
  };
  if (early) registerEpoch(alive && nMy > 0);
  bool needVal = early && alive && nMy > 0;
  if (c.cfg.ser) {
    for (u32 r = 0; r < nRd && needVal; r++)
      if (rdV[r] != SCANV && !validatePoint(c, rdU[r], rdV[r], rdO[r], self)) { alive = false; needVal = false; cause = AB_SER_POINT; }
    u32 maxR = __reduce_max_sync(FULLMASK, needVal ? nRd : 0);
    for (u32 r = 0; r < maxR; r++) {
      bool isScan = needVal && alive && r < nRd && rdV[r] == SCANV;
      if (c.cfg.coopScan) {
        u32 m = __ballot_sync(FULLMASK, isScan);
        while (m) {
          u32 L = __ffs(m) - 1; m &= m - 1;
          u32 su = __shfl_sync(FULLMASK, isScan ? rdU[r] : 0, L), ss = __shfl_sync(FULLMASK, self, L);
          u64 sr = __shfl_sync(FULLMASK, rts, L);
          u32 cnt = 0, hx = 0; bool bad = false;
          scanBody(c, su, ss, sr, 1, lane, 32, cnt, hx, bad);
          bool anyBad = __any_sync(FULLMASK, bad);
          if (lane == L && anyBad) { alive = false; cause = AB_SER_SCAN; }
        }
      } else if (isScan) {
        u32 cnt = 0, hx = 0; bool bad = false;
        scanBody(c, rdU[r], self, rts, 1, 0, 1, cnt, hx, bad);
        if (bad) { alive = false; cause = AB_SER_SCAN; }
      }
    }
  }
  u64 pc3 = clock64(); st.prof[3] += pc3 - pc2;
  if (!early) registerEpoch(alive && nMy > 0);
  // Read-only commit: serializes at rts and owns no live deltas. Its descriptor must NOT read as
  // COMMITTED(rts): that would make its voided reservation slots "committed in the past" for concurrent
  // scanners (which may still read a pre-void opcode). ABORTED keeps every slot it touched invisible.
  if (alive && nMy == 0) { e = rts; AR(c.desc[self]).store(1ull, RLX); }
  if (reg) {
    __threadfence();  // release pattern: all txn writes ordered before the descriptor publication
    if ((reg >> lane) & 1) AR(c.desc[self]).store(alive ? ((e << 2) | 2) : 1ull, RLX);
    __syncwarp();
    if (lane == regLeader) { __threadfence(); AR(c.inflight[e & 1]).fetch_add((u32)__popc(reg), RLX); }  // done
  }
  if (act && !alive && self < c.descCap) AR(c.desc[self]).store(1ull, REL);
  u64 pc4 = clock64(); st.prof[4] += pc4 - pc3;
  if (alive && c.cfg.stamp) {
    for (u32 i = 0; i < nMy; i++) AR(c.D[myD[i]].cts).store(e, RLX);
    for (u32 i = 0; i < nSup; i++) AR(c.D[sup[i]].its).store(e, RLX);
  }
  st.prof[5] += clock64() - pc4;
  if (alive) { st.commits++; st.eff += nEff; st.noops += nNoop; }
  else if (act) st.ab[cause < 0 ? AB_RESOURCE : cause]++;
  rtsO = rts; ctsO = e; selfO = self; causeO = cause;
  return alive;
}

__global__ void kRun(Ctx c) {
  const u32 lane = threadIdx.x & 31;
  const u32 gw = (blockIdx.x * blockDim.x + threadIdx.x) >> 5;
  if (gw == 0) { if (lane == 0) advancerLoop(c); return; }
  LaneStats st; memset(&st, 0, sizeof(st));
  u32 cur = 0xFFFFFFFFu, attempts = 0, backoff = 0, rng = mix32(gw * 32 + lane + 12345);
  bool exhausted = false;
  u64 tBegin = 0;
  const u64 deadline = gtimer() + c.watchdogNs;
  for (;;) {
    bool need = (cur == 0xFFFFFFFFu) && !exhausted;
    u32 idx = warpAggInc(c.nextTxn, need);
    if (need) { if (idx < c.N) { cur = idx; attempts = 0; backoff = 0; tBegin = gtimer(); } else exhausted = true; }
    if (__all_sync(FULLMASK, cur == 0xFFFFFFFFu)) break;
    if (c.watchdogNs && lane == 0 && gtimer() > deadline) atomicOr(c.oom, 2u);
    bool act = (cur != 0xFFFFFFFFu) && backoff == 0;
    if (cur != 0xFFFFFFFFu && backoff) backoff--;
    if (__all_sync(FULLMASK, !act)) { __nanosleep(100); continue; }
    u64 rts, cts; u32 self; int cause;
    bool ok = attempt(c, act, cur, rts, cts, self, cause, st);
    if (act) {
      attempts++;
      if (ok) {
        TxRecord r; r.rts = rts; r.cts = cts; r.txid = self; r.attempts = attempts; r.tBegin = tBegin; r.tEnd = gtimer();
        c.rec[cur] = r; cur = 0xFFFFFFFFu;
      } else if (attempts >= c.cfg.maxAttempts || cause == AB_RESOURCE || (AR(*c.oom).load(RLX) & 2u)) {
        TxRecord r; r.rts = 0; r.cts = 0; r.txid = 0; r.attempts = attempts; r.tBegin = tBegin; r.tEnd = gtimer();
        c.rec[cur] = r; cur = 0xFFFFFFFFu; st.giveup++;
      } else {
        rng = mix32(rng + attempts);
        u32 sh = attempts < 8 ? attempts : 8;
        backoff = rng & ((1u << sh) - 1);
      }
    }
  }
  // flush stats
  u32 vals[ST_N]; for (int i = 0; i < ST_N; i++) vals[i] = 0;
  vals[ST_COMMITS] = st.commits; vals[ST_EFFECTIVE] = st.eff; vals[ST_NOOPS] = st.noops; vals[ST_SLOTS] = st.slots;
  vals[ST_VOIDED] = st.voided; vals[ST_GROWTHS] = st.grows; vals[ST_CAS_FAIL] = st.casFail; vals[ST_GIVEUP] = st.giveup;
  vals[ST_RESV_ATOMICS] = st.resv;
  for (int i = 0; i < 6; i++) vals[24 + i] = (u32)(st.prof[i] >> 10);  // kilocycles, summed over lanes
  u32 ab = 0; for (int i = 0; i < AB_NCAUSES; i++) { vals[ST_ABORT_BASE + i] = st.ab[i]; ab += st.ab[i]; }
  vals[ST_ABORTS] = ab;
  for (int i = 0; i < ST_N; i++) { u32 s = __reduce_add_sync(FULLMASK, vals[i]); if (lane == 0 && s) atomicAdd(&c.stats[i], s); }
  if (lane == 0) { u32 d = atomicAdd(c.doneWarps, 1); if (d + 1 == c.nWorkWarps) AR(*c.stop).store(1u, REL); }
}

__global__ void kFill64(u64* p, u32 n, u64 v) { for (u32 i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x) p[i] = v; }
__global__ void kFill(u32* p, u32 n, u32 v) { for (u32 i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x) p[i] = v; }

// ------------------------------------------------------------------------------------------------
// Host wrapper
struct Store {
  Ctx c{};
  u32 *dStats = nullptr;
  u32 V, dCap, hCap, bCap, descCap;
  int gridBlocks = 0, blockThreads = 128;
  u32 txidBaseOfRun = 1;

  void init(u32 V_, u32 dCap_, u32 descCap_, Cfg cfg) {
    V = V_; dCap = dCap_; hCap = dCap_ + 1024; bCap = V_ * 24 + 1024; descCap = descCap_;
    c.V = V; c.cfg = cfg; c.watchdogNs = 20ull * 1000000000ull;
    CK(cudaMalloc(&c.vcur, (size_t)V * 4));
    CK(cudaMalloc(&c.vfill, (size_t)V * 8));
    CK(cudaMalloc(&c.B, (size_t)bCap * sizeof(Block)));
    CK(cudaMalloc(&c.D, (size_t)dCap * sizeof(Delta)));
    CK(cudaMalloc(&c.H, (size_t)hCap * 4));
    CK(cudaMalloc(&c.desc, (size_t)descCap * 8));
    u32* ctrs; CK(cudaMalloc(&ctrs, 64 * 4)); // counters block (>= 4KB-safe staging not needed: D2D read below)
    c.bTop = ctrs + 0; c.dTop = ctrs + 1; c.hTop = ctrs + 2; c.txTop = ctrs + 3; c.inflight = ctrs + 4;
    c.stop = ctrs + 6; c.oom = ctrs + 7; c.nextTxn = ctrs + 8; c.doneWarps = ctrs + 9;
    u64* e64; CK(cudaMalloc(&e64, 4 * 8)); c.E = e64; c.frontier = e64 + 1;
    CK(cudaMalloc(&dStats, ST_N * 4)); c.stats = dStats;
    c.bCap = bCap; c.dCap = dCap; c.hCap = hCap; c.descCap = descCap;
    reset();
    int dev; CK(cudaGetDevice(&dev)); cudaDeviceProp p; CK(cudaGetDeviceProperties(&p, dev));
    int perSM = 0; CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&perSM, kRun, blockThreads, 0));
    gridBlocks = p.multiProcessorCount * (perSM > 0 ? perSM : 1);
  }
  void release() {
    cudaFree(c.vcur); cudaFree(c.vfill); cudaFree(c.B); cudaFree(c.D); cudaFree(c.H); cudaFree(c.desc); cudaFree(c.bTop); cudaFree(c.E); cudaFree(dStats);
  }
  void reset() {
    CK(cudaMemset(c.vcur, 0xFF, (size_t)V * 4));
    kFill64<<<1024, 256>>>(c.vfill, V, (u64)NONEB << 32); CK(cudaGetLastError());
    CK(cudaMemset(c.D, 0, (size_t)dCap * sizeof(Delta)));
    kFill<<<1024, 256>>>(c.H, hCap, NILD); CK(cudaGetLastError());
    CK(cudaMemset(c.desc, 0, (size_t)descCap * 8));
    CK(cudaMemset(c.bTop, 0, 64 * 4));
    u32 one = 1; CK(cudaMemcpy(c.txTop, &one, 4, cudaMemcpyHostToDevice));  // txid 0 invalid
    u64 ef[2] = {2ull << 32, 1}; CK(cudaMemcpy(c.E, ef, 16, cudaMemcpyHostToDevice));  // epoch 2 open, frontier 1
    CK(cudaDeviceSynchronize());
  }
  // Publish everything committed so far (host-side frontier advance between runs).
  void publishAll() {
    u64 ef[2]; CK(cudaMemcpy(ef, c.E, 16, cudaMemcpyDeviceToHost));
    u64 e = ef[0] >> 32;  // kernel finished: every registration in e has completed
    u64 nf[2] = {(e + 1) << 32, e}; CK(cudaMemcpy(c.E, nf, 16, cudaMemcpyHostToDevice));
    CK(cudaMemset(c.inflight, 0, 8));
  }
  u64 frontier() { u64 ef[2]; CK(cudaMemcpy(ef, c.E, 16, cudaMemcpyDeviceToHost)); return ef[1]; }
  u32 readCounter(u32* p) { u32 v; CK(cudaMemcpy(&v, p, 4, cudaMemcpyDeviceToHost)); return v; }

  // Run a device-resident workload; returns kernel ms.
  float run(const u32* dOff, const Op* dOps, u32 N, OpResult* dRes, TxRecord* dRec, u32* hStats) {
    c.off = dOff; c.ops = dOps; c.N = N; c.res = dRes; c.rec = dRec;
    CK(cudaMemset(c.nextTxn, 0, 4)); CK(cudaMemset(c.doneWarps, 0, 4)); CK(cudaMemset(c.stop, 0, 4));
    CK(cudaMemset(c.inflight, 0, 8)); CK(cudaMemset(dStats, 0, ST_N * 4));
    txidBaseOfRun = readCounter(c.txTop);
    int warpsPerBlock = blockThreads / 32;
    u32 needWarps = (N + 31) / 32 + 1;
    int blocks = gridBlocks;
    if ((u32)blocks * warpsPerBlock > needWarps) blocks = (needWarps + warpsPerBlock - 1) / warpsPerBlock;
    if (blocks < 1) blocks = 1;
    c.nWorkWarps = blocks * warpsPerBlock - 1;
    if (c.nWorkWarps == 0) { blocks = 1; c.nWorkWarps = warpsPerBlock - 1; }
    cudaEvent_t a, b; CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));
    CK(cudaEventRecord(a));
    kRun<<<blocks, blockThreads>>>(c);
    CK(cudaEventRecord(b)); CK(cudaEventSynchronize(b)); CK(cudaGetLastError());
    float ms = 0; CK(cudaEventElapsedTime(&ms, a, b));
    CK(cudaEventDestroy(a)); CK(cudaEventDestroy(b));
    if (hStats) { CK(cudaMemcpy(hStats, dStats, ST_N * 4, cudaMemcpyDeviceToHost)); hStats[ST_N - 1] = readCounter(c.oom); }
    { u32 fl = readCounter(c.oom); if (fl & 16) { u32 dg[3]; CK(cudaMemcpy(dg, c.nextTxn + 2, 12, cudaMemcpyDeviceToHost)); fprintf(stderr, "ADVANCER STUCK: epoch=%u registered=%u done=%u (run INVALID)\n", dg[0], dg[1], dg[2]); } }
    return ms;
  }

  size_t bytesUsed() {
    u32 t[4]; CK(cudaMemcpy(t, c.bTop, 16, cudaMemcpyDeviceToHost));
    return (size_t)t[0] * sizeof(Block) + (size_t)t[1] * sizeof(Delta) + (size_t)t[2] * 4 + (size_t)V * 12 + (size_t)t[3] * 8;
  }

  // Host snapshot of storage for checking.
  struct Snap { std::vector<u32> vcur; std::vector<u64> vfill; std::vector<Block> B; std::vector<Delta> D; std::vector<u64> desc; };
  Snap snapshot() {
    Snap s; u32 t[4]; CK(cudaMemcpy(t, c.bTop, 16, cudaMemcpyDeviceToHost));
    u32 nb = t[0] < bCap ? t[0] : bCap, nd = t[1] < dCap ? t[1] : dCap, nt = t[3] < descCap ? t[3] : descCap;
    s.vcur.resize(V); s.B.resize(nb); s.D.resize(nd); s.desc.resize(nt);
    CK(cudaMemcpy(s.vcur.data(), c.vcur, (size_t)V * 4, cudaMemcpyDeviceToHost));
    s.vfill.resize(V); CK(cudaMemcpy(s.vfill.data(), c.vfill, (size_t)V * 8, cudaMemcpyDeviceToHost));
    if (nb) CK(cudaMemcpy(s.B.data(), c.B, (size_t)nb * sizeof(Block), cudaMemcpyDeviceToHost));
    if (nd) CK(cudaMemcpy(s.D.data(), c.D, (size_t)nd * sizeof(Delta), cudaMemcpyDeviceToHost));
    if (nt) CK(cudaMemcpy(s.desc.data(), c.desc, (size_t)nt * 8, cudaMemcpyDeviceToHost));
    return s;
  }

  // Visible edge set at snapshot F (host re-implementation of the scan visibility rule).
  static void visibleEdges(const Snap& s, u64 F, std::vector<std::pair<u32, u32>>& out) {
    auto committedLE = [&](u32 owner) { if (owner >= s.desc.size()) return false; u64 d = s.desc[owner]; return (d & 2) && (d >> 2) <= F; };
    for (u32 u = 0; u < s.vcur.size(); u++) {
      u32 g = s.vcur[u];
      while (g < PENDB) {
        const Block& b = s.B[g];
        u32 f = ((u32)(s.vfill[u] >> 32) == g) ? (u32)s.vfill[u] : b.cap;
        u32 n = f < b.cap ? f : b.cap;
        for (u32 i = 0; i < n; i++) {
          const Delta& d = s.D[b.base + i];
          if (!d.owner || (d.dstop >> 30) != OPB_INS) continue;
          bool cv = d.cts ? d.cts <= F : committedLE(d.owner);
          if (!cv) continue;
          bool inv = false;
          if (d.its) inv = (d.its & TAGBIT) ? committedLE((u32)d.its) : d.its <= F;
          if (!inv) out.push_back({u, d.dstop & 0x3FFFFFFFu});
        }
        g = b.prevGen;
      }
    }
  }
};

}  // namespace gtxg
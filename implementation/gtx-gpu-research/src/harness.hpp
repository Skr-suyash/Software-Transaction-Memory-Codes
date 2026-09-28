// Shared host harness helpers: device workload buffers, GTX runner with optional checking.
#pragma once
#include <map>
#include <set>
#include <string>
#include <vector>
#include "checker.hpp"
#include "gtxg.cuh"
#include "workload.hpp"

struct DevWl {
  u32* off = nullptr; Op* ops = nullptr; OpResult* res = nullptr; TxRecord* rec = nullptr; u32 N = 0; size_t nOps = 0;
  void upload(const HostWorkload& w) {
    N = w.N(); nOps = w.ops.size();
    CK(cudaMalloc(&off, (N + 1) * 4)); CK(cudaMalloc(&ops, (nOps ? nOps : 1) * sizeof(Op)));
    CK(cudaMalloc(&res, (nOps ? nOps : 1) * sizeof(OpResult))); CK(cudaMalloc(&rec, (N ? N : 1) * sizeof(TxRecord)));
    CK(cudaMemcpy(off, w.off.data(), (N + 1) * 4, cudaMemcpyHostToDevice));
    if (nOps) CK(cudaMemcpy(ops, w.ops.data(), nOps * sizeof(Op), cudaMemcpyHostToDevice));
    CK(cudaMemset(res, 0, (nOps ? nOps : 1) * sizeof(OpResult))); CK(cudaMemset(rec, 0, (N ? N : 1) * sizeof(TxRecord)));
  }
  void release() { cudaFree(off); cudaFree(ops); cudaFree(res); cudaFree(rec); off = nullptr; }
};

struct RunOut {
  float ms = 0; u32 stats[ST_N] = {0};
  std::vector<OpResult> res; std::vector<TxRecord> rec;
  CheckReport rep; bool checked = false; size_t bytes = 0;
};

inline const char* abName(int i) {
  static const char* n[] = {"ww_pending", "ww_late", "chain_false", "ser_point", "ser_scan", "resource", "lock", "stm_read"};
  return n[i];
}

// Upper bound of delta slots needed (generous; growth doubles blocks => <= ~4x live + slack per vertex).
inline u32 gtxArenaFor(const HostWorkload& w, u32 minCap) {
  size_t writes = w.initEdges.size();
  for (auto& o : w.ops) if (o.type == OP_INS || o.type == OP_DEL) writes++;
  size_t cap = writes * 6 + (size_t)w.V * minCap * 2 + (1 << 20);
  if (cap > 60000000) cap = 60000000;  // 60M * 32B = 1.9 GB
  return (u32)cap;
}

// Load w.initEdges, then run w. If check, validate with the history checker.
inline RunOut runGtx(const HostWorkload& w, gtxg::Cfg cfg, bool check, gtxg::Store* reuse = nullptr, u32 arena = 0) {
  RunOut out;
  gtxg::Store local;
  gtxg::Store& S = reuse ? *reuse : local;
  if (!reuse) {
    u32 dcap = arena ? arena : gtxArenaFor(w, cfg.minCap);
    size_t descCap = (size_t)w.N() * 32 + w.initEdges.size() + (1 << 20);
    if (descCap > 100000000) descCap = 100000000;
    S.init(w.V, dcap, (u32)descCap, cfg);
  } else { S.c.cfg = cfg; S.reset(); }
  if (!w.initEdges.empty()) {
    HostWorkload lw = loaderWorkload(w);
    DevWl dl; dl.upload(lw);
    gtxg::Cfg lc = cfg; lc.ser = 0; lc.mut = 0; S.c.cfg = lc;
    S.run(dl.off, dl.ops, dl.N, dl.res, dl.rec, nullptr);
    dl.release();
    S.c.cfg = cfg;
    S.publishAll();
  }
  DevWl d; d.upload(w);
  u32* dbgBuf = nullptr; u32* dbgTop = nullptr; const u32 dbgCap = (u32)((w.ops.size() + 1) * 3072ull);
  if (getenv("GTX_FORENSIC")) {
    CK(cudaMalloc(&dbgBuf, (size_t)dbgCap * 4)); CK(cudaMalloc(&dbgTop, 4)); CK(cudaMemset(dbgTop, 0, 4));
    S.c.dbgBuf = dbgBuf; S.c.dbgTop = dbgTop; S.c.dbgCap = dbgCap;
  }
  out.ms = S.run(d.off, d.ops, d.N, d.res, d.rec, out.stats);
  S.c.dbgBuf = nullptr; S.c.dbgTop = nullptr; S.c.dbgCap = 0;
  std::vector<u32> dbgHost;
  if (dbgBuf) {
    u32 top = dbgCap;
    dbgHost.resize(top); if (top) CK(cudaMemcpy(dbgHost.data(), dbgBuf, (size_t)top * 4, cudaMemcpyDeviceToHost));
    cudaFree(dbgBuf); cudaFree(dbgTop);
  }
  out.bytes = S.bytesUsed();
  out.res.resize(d.nOps); out.rec.resize(d.N);
  if (d.nOps) CK(cudaMemcpy(out.res.data(), d.res, d.nOps * sizeof(OpResult), cudaMemcpyDeviceToHost));
  if (d.N) CK(cudaMemcpy(out.rec.data(), d.rec, d.N * sizeof(TxRecord), cudaMemcpyDeviceToHost));
  if (check) {
    S.publishAll();
    auto snap = S.snapshot();
    u64 F = S.frontier();
    CheckInput ci; ci.w = &w; ci.res = &out.res; ci.rec = &out.rec; ci.initial = w.initEdges; ci.ser = cfg.ser;
    std::unordered_map<u32, long long> txidToTxn;
    for (u32 i = 0; i < d.N; i++) if (out.rec[i].txid) txidToTxn[out.rec[i].txid] = i;
    u32 base = S.txidBaseOfRun;
    ci.checkObs = true;
    ci.obsWriter = [&](u32 obs) -> long long {
      if (obs == gtxg::NILD) return -1;
      if (obs >= snap.D.size()) return -3;
      u32 owner = snap.D[obs].owner;
      if (owner < base) return -2;
      auto it = txidToTxn.find(owner);
      return it == txidToTxn.end() ? -3 : it->second;
    };
    ci.haveFinal = true;
    gtxg::Store::visibleEdges(snap, F, ci.finalEdges);
    out.rep = checkHistory(ci);
    out.checked = true;
    if (out.rep.badScanTxn >= 0 && getenv("GTX_FORENSIC")) {
      const TxRecord& tr = out.rec[out.rep.badScanTxn];
      u32 u = out.rep.badScanU;
      fprintf(stderr, "FORENSIC scan txn=%lld op=%u vertex=%u self=%u rts=%llu cts=%llu attempts=%u frontierFinal=%llu\n",
              out.rep.badScanTxn, out.rep.badScanOp, u, tr.txid, (unsigned long long)tr.rts, (unsigned long long)tr.cts, tr.attempts, (unsigned long long)F);
      fprintf(stderr, "  txn ops:");
      for (u32 j = w.off[out.rep.badScanTxn]; j < w.off[out.rep.badScanTxn + 1]; j++) fprintf(stderr, " %u(%u,%u)->%u", w.ops[j].type, w.ops[j].u, w.ops[j].v, out.res[j].r);
      fprintf(stderr, "\n  expected(snapshot, not own):");
      for (u32 v : out.rep.badExpect) fprintf(stderr, " %u", v);
      fprintf(stderr, "\n  own:");
      for (auto& o : out.rep.badOwn) fprintf(stderr, " %u:%d", o.first, (int)o.second);
      fprintf(stderr, "\n");
      auto who = [&](u32 txid) -> std::string {
        char b[160];
        if (txid < base) { snprintf(b, sizeof b, "loader"); return b; }
        auto it = txidToTxn.find(txid);
        u64 d = txid < snap.desc.size() ? snap.desc[txid] : 0;
        if (it == txidToTxn.end()) snprintf(b, sizeof b, "attempt(tx%u desc=%llu)", txid, (unsigned long long)d);
        else { const TxRecord& r = out.rec[it->second]; snprintf(b, sizeof b, "T%lld(tx%u rts=%llu cts=%llu desc=%llu)", it->second, txid, (unsigned long long)r.rts, (unsigned long long)r.cts, (unsigned long long)d); }
        return b;
      };
      // Recompute visibility at (self, rts) from final descriptors; diff against the model.
      u32 self = tr.txid; u64 rts = tr.rts;
      auto commitLE = [&](u32 txid) { if (txid == self) return true; if (txid >= snap.desc.size()) return false; u64 d = snap.desc[txid]; return (d & 2) && (d >> 2) <= rts; };
      std::map<u32, int> devVis; std::map<u32, std::vector<u32>> hist;
      for (u32 g2 = snap.vcur[u]; g2 < gtxg::PENDB; g2 = snap.B[g2].prevGen) {
        const gtxg::Block& b = snap.B[g2];
        u32 f = ((u32)(snap.vfill[u] >> 32) == g2) ? (u32)snap.vfill[u] : b.cap; u32 n = f < b.cap ? f : b.cap;
        for (u32 i = 0; i < n; i++) {
          const gtxg::Delta& d = snap.D[b.base + i];
          if (!d.owner) continue;
          u32 dst = d.dstop & 0x3FFFFFFFu; hist[dst].push_back(b.base + i);
          if ((d.dstop >> 30) != 1) continue;
          bool cv = d.cts ? (d.cts <= rts) || d.owner == self : commitLE(d.owner);
          bool inv = d.its ? ((d.its & gtxg::TAGBIT) ? commitLE((u32)d.its) : d.its <= rts) : false;
          if (cv && !inv) devVis[dst]++;
        }
      }
      std::map<u32, int> model;
      for (u32 v : out.rep.badExpect) model[v] = 1;
      for (auto& o : out.rep.badOwn) model[o.first] = o.second ? 1 : 0;
      for (auto it = model.begin(); it != model.end();) { if (!it->second) it = model.erase(it); else ++it; }
      fprintf(stderr, "  device-visible-at-rts(final descs)=%zu model=%zu\n", devVis.size(), model.size());
      std::set<u32> diff;
      for (auto& kv : devVis) if (!model.count(kv.first) || kv.second != 1) diff.insert(kv.first);
      for (auto& kv : model) if (!devVis.count(kv.first)) diff.insert(kv.first);
      for (u32 dst : diff) {
        fprintf(stderr, "  DIFF dst=%u device=%d model=%d history:\n", dst, devVis.count(dst) ? devVis[dst] : 0, model.count(dst) ? 1 : 0);
        for (u32 idx : hist[dst]) {
          const gtxg::Delta& d = snap.D[idx];
          u32 op = d.dstop >> 30;
          std::string its = "-";
          if (d.its) { if (d.its & gtxg::TAGBIT) its = "by " + who((u32)d.its); else its = "@" + std::to_string(d.its); }
          fprintf(stderr, "    [%u] %s owner=%s cts=%llu its=%s prev=%u\n", idx, op == 1 ? "INS" : op == 2 ? "DEL" : "VOID",
                  who(d.owner).c_str(), (unsigned long long)d.cts, its.c_str(), d.prev);
        }
      }
      auto printHist = [&](u32 dst) {
        u32 skipped = 0;
        for (u32 idx : hist[dst]) {
          const gtxg::Delta& d = snap.D[idx]; u32 op = d.dstop >> 30; std::string its = "-";
          bool abortedAttempt = d.owner >= base && !txidToTxn.count(d.owner);
          if (abortedAttempt || op == 3) { skipped++; continue; }
          if (d.its) { if (d.its & gtxg::TAGBIT) its = "by " + who((u32)d.its); else its = "@" + std::to_string(d.its); }
          fprintf(stderr, "    [%u] %s owner=%s cts=%llu its=%s prev=%u\n", idx, op == 1 ? "INS" : op == 2 ? "DEL" : "VOID",
                  who(d.owner).c_str(), (unsigned long long)d.cts, its.c_str(), d.prev);
        }
      };
      {  // what did the scan actually count?
        const OpResult& sr = out.res[w.off[out.rep.badScanTxn] + out.rep.badScanOp];
        if (sr.pad != 0xFFFFFFFFu && (size_t)sr.pad + 3072 <= dbgHost.size()) {
          std::map<u32, u32> counted;  // dst -> delta idx
          for (u32 k = 0; k < sr.r && k < 1024; k++) { u32 idx = dbgHost[sr.pad + k]; counted[snap.D[idx].dstop & 0x3FFFFFFFu] = idx; }
          for (auto& kv : counted) if (!model.count(kv.first)) { fprintf(stderr, "  EXTRA counted dst=%u via [%u]:\n", kv.first, kv.second); printHist(kv.first); }
          for (auto& kv : model) if (!counted.count(kv.first)) { fprintf(stderr, "  MISSING dst=%u:\n", kv.first); printHist(kv.first);
            u32 g0 = dbgHost[sr.pad + 3048];
            for (u32 idx : hist[kv.first]) if (g0 < snap.B.size() && idx >= snap.B[g0].base && idx < snap.B[g0].base + 2024) fprintf(stderr, "    scan code for [%u] = %u\n", idx, dbgHost[sr.pad + 1024 + idx - snap.B[g0].base]); }
          fprintf(stderr, "  scan visited gens:");
          for (u32 q = 0; q < 12; q++) { u32 gg = dbgHost[sr.pad + 3048 + 2 * q]; if (gg == 0xFFFFFFFFu) break; fprintf(stderr, " g%u(n=%u)", gg, dbgHost[sr.pad + 3049 + 2 * q]); }
          fprintf(stderr, "\n  final gen chain:");
          for (u32 g2 = snap.vcur[u]; g2 < gtxg::PENDB; g2 = snap.B[g2].prevGen) fprintf(stderr, " g%u[base=%u cap=%u]", g2, snap.B[g2].base, snap.B[g2].cap);
          fprintf(stderr, "\n");
        } else fprintf(stderr, "  (no per-scan record: coop scan or overflow)\n");
      }
      u32 g = gtxg::PENDB;  // full block dump disabled
      while (g < gtxg::PENDB) {
        const gtxg::Block& b = snap.B[g];
        u32 f = ((u32)(snap.vfill[u] >> 32) == g) ? (u32)snap.vfill[u] : b.cap; u32 n = f < b.cap ? f : b.cap;
        fprintf(stderr, "  gen %u base=%u cap=%u used=%u prev=%u\n", g, b.base, b.cap, n, b.prevGen);
        for (u32 i = 0; i < n; i++) {
          const gtxg::Delta& d = snap.D[b.base + i];
          if (!d.owner) continue;
          u32 op = d.dstop >> 30;
          std::string its = "-";
          if (d.its) { if (d.its & gtxg::TAGBIT) its = "by " + who((u32)d.its); else its = "@" + std::to_string(d.its); }
          fprintf(stderr, "    [%u] %s dst=%u owner=%s cts=%llu its=%s\n", b.base + i, op == 1 ? "INS" : op == 2 ? "DEL" : "VOID",
                  d.dstop & 0x3FFFFFFFu, who(d.owner).c_str(), (unsigned long long)d.cts, its.c_str());
        }
        g = b.prevGen;
      }
    }
  }
  d.release();
  if (!reuse) S.release();
  return out;
}

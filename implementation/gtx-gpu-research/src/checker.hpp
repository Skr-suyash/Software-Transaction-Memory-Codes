// History checker for transactional graph runs.
//
// Model: each committed txn T has a snapshot rts(T) and commit timestamp cts(T) (rts < cts for
// writers; read-only txns may use cts == rts). S(e) = state after applying, in cts order, the net
// writes of every committed txn with cts <= e (plus the initial graph).
//
// Checks (all must hold for snapshot isolation):
//  C1 read rule    : every READ / no-op INS/DEL / SCAN result equals S(rts) overlaid with T's own
//                    earlier writes;  effective INS/DEL results agree with the same state.
//  C2 observation  : a point observation names the delta of the version the rule predicts
//                    (never an aborted or uncommitted writer).
//  C3 write-write  : no committed writer of key k has cts in (rts(T), cts(T)) for another writer T
//                    of k (first-committer-wins), and no two writers of k share a commit timestamp.
//  C4 final state  : device-visible final edge set == S(inf).
// Serializability additionally requires C5: the direct serialization graph (ww, wr, rw edges, with
// per-key version order = cts order and scans treated as reads of every key of the vertex) is acyclic.
#pragma once
#include <algorithm>
#include <functional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "common.cuh"

struct CheckReport {
  bool ok = true;
  long long committed = 0, readMismatch = 0, obsMismatch = 0, wwViolations = 0, sameEpochWW = 0,
            scanMismatch = 0, dsgEdges = 0, cycleTxns = 0, finalMissing = 0, finalExtra = 0,
            logFinalMissing = 0, logFinalExtra = 0;  // prototype-style log-vs-final check (informational)
  std::string first;
  // forensic data for the first scan mismatch
  long long badScanTxn = -1; u32 badScanU = 0, badScanOp = 0;
  std::vector<std::pair<u32, bool>> badOwn; std::vector<u32> badExpect;
  void fail(const std::string& s) { if (ok) first = s; ok = false; }
};

struct CheckInput {
  const HostWorkload* w = nullptr;
  const std::vector<OpResult>* res = nullptr;
  const std::vector<TxRecord>* rec = nullptr;           // committed iff cts != 0 && txid != 0
  std::vector<std::pair<u32, u32>> initial;              // graph before the run
  // obs delta index -> writer: -1 none, -2 initial/loader, >=0 txn index of this run, -3 invalid
  std::function<long long(u32)> obsWriter;
  bool checkObs = false;
  bool ser = false;
  bool haveFinal = false;
  std::vector<std::pair<u32, u32>> finalEdges;
  bool readOnlyUsesRtsAsCts = false;  // STM read-only txns
};

inline u64 ekey(u32 u, u32 v) { return ((u64)u << 32) | v; }

inline CheckReport checkHistory(const CheckInput& in) {
  CheckReport rep;
  const HostWorkload& w = *in.w;
  const u32 N = w.N();
  struct Ver { u64 cts; bool present; long long txn; };
  std::unordered_map<u64, std::vector<Ver>> vers;
  std::unordered_map<u32, std::unordered_set<u32>> adj;  // keys ever versioned per source
  vers.reserve(in.initial.size() * 2 + 1024);
  for (auto& e : in.initial) { vers[ekey(e.first, e.second)].push_back({0, true, -2}); adj[e.first].insert(e.second); }

  std::vector<u32> order;
  for (u32 i = 0; i < N; i++) { const TxRecord& r = (*in.rec)[i]; if (r.txid != 0 && (r.cts != 0 || r.rts != 0)) order.push_back(i); }
  // writers before read-only txns (rts == cts) that share the timestamp
  std::stable_sort(order.begin(), order.end(), [&](u32 a, u32 b) {
    const TxRecord &x = (*in.rec)[a], &y = (*in.rec)[b];
    if (x.cts != y.cts) return x.cts < y.cts;
    return (x.rts != x.cts) && (y.rts == y.cts);
  });
  rep.committed = order.size();

  auto stateAt = [&](u64 k, u64 rts, int& vi) -> bool {
    auto it = vers.find(k);
    vi = -1;
    if (it == vers.end()) return false;
    const auto& vl = it->second;
    // last version with cts <= rts (vl sorted by cts)
    int lo = 0, hi = (int)vl.size() - 1, ans = -1;
    while (lo <= hi) { int m = (lo + hi) / 2; if (vl[m].cts <= rts) { ans = m; lo = m + 1; } else hi = m - 1; }
    vi = ans;
    return ans >= 0 && vl[ans].present;
  };

  struct Obs { u32 txn; u64 key; int vi; };
  std::vector<Obs> observations;

  char buf[256];
  for (u32 t : order) {
    const TxRecord& r = (*in.rec)[t];
    u64 rts = r.rts;
    std::unordered_map<u64, bool> own;
    std::unordered_map<u64, bool> wrote;
    for (u32 j = w.off[t]; j < w.off[t + 1]; j++) {
      const Op& op = w.ops[j];
      const OpResult& rr = (*in.res)[j];
      if (op.type == OP_INS || op.type == OP_DEL || op.type == OP_READ) {
        u64 k = ekey(op.u, op.v);
        auto oi = own.find(k);
        int vi = -1;
        bool st = (oi != own.end()) ? oi->second : stateAt(k, rts, vi);
        bool isOwn = oi != own.end();
        u32 expect = (op.type == OP_INS) ? !st : (op.type == OP_DEL ? st : st);
        if (rr.r != expect) {
          rep.readMismatch++;
          snprintf(buf, sizeof buf, "C1 txn %u op %u type %u (%u,%u): got %u expected %u (rts=%llu cts=%llu)", t, j - w.off[t], op.type,
                   op.u, op.v, rr.r, expect, (unsigned long long)rts, (unsigned long long)r.cts);
          rep.fail(buf);
        }
        if (!isOwn && in.checkObs) {
          long long expW = vi >= 0 ? vers[k][vi].txn : -1;
          long long gotW = in.obsWriter(rr.obs);
          if (gotW != expW) {
            rep.obsMismatch++;
            snprintf(buf, sizeof buf, "C2 txn %u (%u,%u): observed writer %lld expected %lld", t, op.u, op.v, gotW, expW);
            rep.fail(buf);
          }
        }
        bool eff = (op.type != OP_READ) && rr.r == 1 && expect == 1;
        if (eff) { own[k] = (op.type == OP_INS); wrote[k] = true; }
        else if (!isOwn) observations.push_back({t, k, vi});
      } else if (op.type == OP_SCAN) {
        u32 cnt = 0, hx = 0;
        auto ai = adj.find(op.u);
        if (ai != adj.end()) for (u32 v : ai->second) {
          u64 k = ekey(op.u, v);
          auto oi = own.find(k);
          int vi = -1;
          bool st = (oi != own.end()) ? oi->second : stateAt(k, rts, vi);
          if (oi == own.end()) observations.push_back({t, k, vi});
          if (st) { cnt++; hx ^= mix32(v); }
        }
        for (auto& kv : own) {
          if ((u32)(kv.first >> 32) != op.u) continue;
          u32 v = (u32)kv.first;
          if (ai != adj.end() && ai->second.count(v)) continue;
          if (kv.second) { cnt++; hx ^= mix32(v); }
        }
        if (rr.r != cnt || rr.aux != hx) {
          if (!rep.scanMismatch) { rep.badScanTxn = t; rep.badScanU = op.u; rep.badScanOp = j - w.off[t];
            for (auto& kv : own) if ((u32)(kv.first >> 32) == op.u) rep.badOwn.push_back({(u32)kv.first, kv.second});
            if (ai != adj.end()) for (u32 v : ai->second) { int vi; if (!own.count(ekey(op.u, v)) && stateAt(ekey(op.u, v), rts, vi)) rep.badExpect.push_back(v); } }
          rep.scanMismatch++;
          snprintf(buf, sizeof buf, "C1 scan txn %u vertex %u: got %u/%08x expected %u/%08x", t, op.u, rr.r, rr.aux, cnt, hx);
          rep.fail(buf);
        }
      }
    }
    // append net writes as versions at cts
    for (auto& kv : wrote) {
      u64 k = kv.first;
      auto& vl = vers[k];
      if (!vl.empty()) {
        if (vl.back().cts == r.cts && vl.back().txn >= 0) { rep.sameEpochWW++; rep.fail("C3 two writers of one key share a commit timestamp"); }
        else if (vl.back().cts > rts) {
          rep.wwViolations++;
          snprintf(buf, sizeof buf, "C3 lost update on (%u,%u): txn %u rts=%llu but version at %llu", (u32)(k >> 32), (u32)k, t,
                   (unsigned long long)rts, (unsigned long long)vl.back().cts);
          rep.fail(buf);
        }
      }
      vl.push_back({r.cts, own[k], (long long)t});
      adj[(u32)(k >> 32)].insert((u32)k);
    }
  }

  // C4 final state
  if (in.haveFinal) {
    std::unordered_set<u64> expect, got;
    for (auto& kv : vers) if (kv.second.back().present) expect.insert(kv.first);
    for (auto& e : in.finalEdges) {
      u64 k = ekey(e.first, e.second);
      if (!got.insert(k).second) { rep.finalExtra++; rep.fail("C4 duplicate visible edge in final state"); }
    }
    for (u64 k : expect) if (!got.count(k)) rep.finalMissing++;
    for (u64 k : got) if (!expect.count(k)) rep.finalExtra++;
    if (rep.finalMissing || rep.finalExtra) {
      snprintf(buf, sizeof buf, "C4 final state: missing %lld extra %lld", rep.finalMissing, rep.finalExtra);
      rep.fail(buf);
    }
  }

  // Prototype-style check (for comparison only, never a pass criterion): replay the operations the DEVICE reported as
  // effective, in commit order, and compare with the device final state ("logged set == final set").
  if (in.haveFinal) {
    std::unordered_set<u64> logSet;
    for (auto& e : in.initial) logSet.insert(ekey(e.first, e.second));
    for (u32 t : order)
      for (u32 j = w.off[t]; j < w.off[t + 1]; j++) {
        const Op& op = w.ops[j];
        if ((*in.res)[j].r != 1) continue;
        if (op.type == OP_INS) logSet.insert(ekey(op.u, op.v));
        else if (op.type == OP_DEL) logSet.erase(ekey(op.u, op.v));
      }
    std::unordered_set<u64> got;
    for (auto& e : in.finalEdges) got.insert(ekey(e.first, e.second));
    for (u64 k : logSet) if (!got.count(k)) rep.logFinalMissing++;
    for (u64 k : got) if (!logSet.count(k)) rep.logFinalExtra++;
  }

  // C5 serialization graph (always computed; only a failure in serializable mode)
  {
    std::unordered_map<long long, std::vector<long long>> g;
    auto addE = [&](long long a, long long b) { if (a >= 0 && b >= 0 && a != b) { g[a].push_back(b); rep.dsgEdges++; } };
    for (auto& kv : vers) { auto& vl = kv.second; for (size_t i = 1; i < vl.size(); i++) addE(vl[i - 1].txn, vl[i].txn); }
    for (auto& o : observations) {
      auto it = vers.find(o.key);
      if (it == vers.end()) continue;
      auto& vl = it->second;
      if (o.vi >= 0) addE(vl[o.vi].txn, o.txn);
      size_t nx = (size_t)(o.vi + 1);
      if (nx < vl.size()) addE(o.txn, vl[nx].txn);
    }
    // iterative DFS cycle detection
    std::unordered_map<long long, int> color;
    long long inCycle = 0;
    for (auto& kv : g) {
      if (color[kv.first]) continue;
      std::vector<std::pair<long long, size_t>> st;
      st.push_back({kv.first, 0}); color[kv.first] = 1;
      while (!st.empty()) {
        auto& top = st.back();
        auto gi = g.find(top.first);
        if (gi != g.end() && top.second < gi->second.size()) {
          long long nb = gi->second[top.second++];
          int c = color[nb];
          if (c == 1) inCycle++;
          else if (c == 0) { color[nb] = 1; st.push_back({nb, 0}); }
        } else { color[top.first] = 2; st.pop_back(); }
      }
    }
    rep.cycleTxns = inCycle;
    if (in.ser && inCycle) {
      snprintf(buf, sizeof buf, "C5 serialization graph has %lld back edges (cycles)", inCycle);
      rep.fail(buf);
    }
  }
  return rep;
}

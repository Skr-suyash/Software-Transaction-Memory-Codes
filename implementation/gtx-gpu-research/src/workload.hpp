// Deterministic workload generator (splitmix64). All systems consume the same HostWorkload.
#pragma once
#include <algorithm>
#include <cmath>
#include <string>
#include <unordered_set>
#include <vector>
#include "common.cuh"

struct Rng {
  u64 s;
  explicit Rng(u64 seed) : s(seed * 0x9E3779B97F4A7C15ull + 1) {}
  u64 next() { u64 z = (s += 0x9E3779B97F4A7C15ull); z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull; z = (z ^ (z >> 27)) * 0x94D049BB133111EBull; return z ^ (z >> 31); }
  u32 below(u32 n) { return (u32)(next() % n); }
  double unit() { return (next() >> 11) * (1.0 / 9007199254740992.0); }
};

struct WlParams {
  u32 V = 1 << 16, N = 1 << 16, K = 1;
  double pIns = 1, pDel = 0, pRead = 0, pScan = 0;   // op mix of update transactions
  double roFrac = 0;                                  // fraction of read-only transactions
  double roScan = 0.2;                                // fraction of scans inside read-only txns
  std::string src = "uniform";                        // uniform | hub | zipf | rmat
  double hubFrac = 0; u32 nHubs = 1; double zipfS = 1.0;
  u32 hotEdges = 0; double hotFrac = 0;               // identical-edge contention
  u32 initEdges = 0;
  u64 seed = 1;
};

struct SrcSampler {
  const WlParams& p; std::vector<double> cdf; int rmatLevels = 0;
  explicit SrcSampler(const WlParams& p_) : p(p_) {
    if (p.src == "zipf") {
      cdf.resize(p.V); double s = 0;
      for (u32 i = 0; i < p.V; i++) { s += 1.0 / std::pow((double)(i + 1), p.zipfS); cdf[i] = s; }
      for (auto& x : cdf) x /= s;
    }
    if (p.src == "rmat") { while ((1u << rmatLevels) < p.V) rmatLevels++; }
  }
  u32 src(Rng& r) const {
    if (p.src == "hub") { if (r.unit() < p.hubFrac) return r.below(p.nHubs); return r.below(p.V); }
    if (p.src == "zipf") { double x = r.unit(); return (u32)(std::lower_bound(cdf.begin(), cdf.end(), x) - cdf.begin()) % p.V; }
    if (p.src == "rmat") {  // Graph500 parameters a=.57 b=.19 c=.19: source bits
      u32 u = 0; for (int l = 0; l < rmatLevels; l++) { double x = r.unit(); u = (u << 1) | (x >= 0.57 + 0.19 ? 1u : 0u); }
      return u % p.V;
    }
    return r.below(p.V);
  }
  u32 dst(Rng& r, u32 u) const { u32 v = r.below(p.V); if (v == u) v = (v + 1) % p.V; return v; }
};

inline HostWorkload makeWorkload(const WlParams& p) {
  HostWorkload w; w.V = p.V;
  Rng r(p.seed);
  SrcSampler S(p);
  std::vector<std::pair<u32, u32>> hot;
  for (u32 i = 0; i < p.hotEdges; i++) { u32 u = S.src(r); hot.push_back({u, S.dst(r, u)}); }
  std::unordered_set<u64> seen;
  for (u32 i = 0; i < p.initEdges; i++) {
    u32 u = S.src(r), v = S.dst(r, u);
    if (seen.insert(((u64)u << 32) | v).second) w.initEdges.push_back({u, v});
  }
  std::vector<std::pair<u32, u32>> pool(w.initEdges);  // candidate targets for deletes
  auto pick = [&](u32& u, u32& v) {
    if (!hot.empty() && r.unit() < p.hotFrac) { auto e = hot[r.below((u32)hot.size())]; u = e.first; v = e.second; return; }
    u = S.src(r); v = S.dst(r, u);
  };
  w.off.push_back(0);
  double tot = p.pIns + p.pDel + p.pRead + p.pScan;
  for (u32 t = 0; t < p.N; t++) {
    bool ro = r.unit() < p.roFrac;
    for (u32 j = 0; j < p.K; j++) {
      Op op; u32 u, v;
      if (ro) {
        pick(u, v);
        op.type = (r.unit() < p.roScan) ? OP_SCAN : OP_READ; op.u = u; op.v = v;
      } else {
        double x = r.unit() * tot;
        if (x < p.pIns) { pick(u, v); op.type = OP_INS; pool.push_back({u, v}); }
        else if (x < p.pIns + p.pDel) {
          if (!pool.empty() && !(p.hotEdges && r.unit() < p.hotFrac)) { auto e = pool[r.below((u32)pool.size())]; u = e.first; v = e.second; }
          else pick(u, v);
          op.type = OP_DEL;
        } else if (x < p.pIns + p.pDel + p.pRead) { pick(u, v); op.type = OP_READ; }
        else { pick(u, v); op.type = OP_SCAN; }
        op.u = u; op.v = v;
      }
      w.ops.push_back(op);
    }
    w.off.push_back((u32)w.ops.size());
  }
  return w;
}

// Workload made of single-insert transactions loading the initial graph.
inline HostWorkload loaderWorkload(const HostWorkload& w) {
  HostWorkload l; l.V = w.V; l.off.push_back(0);
  for (auto& e : w.initEdges) { l.ops.push_back({OP_INS, e.first, e.second}); l.off.push_back((u32)l.ops.size()); }
  return l;
}

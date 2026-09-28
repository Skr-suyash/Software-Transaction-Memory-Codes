// Benchmark driver: one scenario x one system per process (a WDDM TDR cannot poison other runs).
// Prints one CSV row per repetition:
// RESULT,label,sys,rep,ms,commits,aborts,giveup,eff,noop,txn_per_s,eff_per_s,upd_p50_us,upd_p95_us,upd_p99_us,
//        ro_p50_us,ro_p99_us,bytes,ab_ww_pending,ab_ww_late,ab_chain_false,ab_ser_point,ab_ser_scan,ab_resource,
//        ab_lock,ab_stm_read,casfail,growths,resv_atomics,epochs,check,flag(1 oom 2 watchdog 3 chain 4 advancer)
#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include "baselines.cuh"
#include "harness.hpp"

static std::map<std::string, std::string> args;
static std::string A(const char* k, const char* d) { auto it = args.find(k); return it == args.end() ? d : it->second; }
static double AD(const char* k, double d) { auto it = args.find(k); return it == args.end() ? d : atof(it->second.c_str()); }

static void pct(std::vector<double>& v, double& p50, double& p95, double& p99) {
  if (v.empty()) { p50 = p95 = p99 = 0; return; }
  std::sort(v.begin(), v.end());
  auto at = [&](double q) { size_t i = (size_t)(q * (v.size() - 1)); return v[i]; };
  p50 = at(.5); p95 = at(.95); p99 = at(.99);
}

int main(int argc, char** argv) {
  for (int i = 1; i + 1 < argc; i += 2) args[argv[i] + 2] = argv[i + 1];
  WlParams p;
  p.V = (u32)AD("V", 1 << 20); p.N = (u32)AD("N", 1 << 18); p.K = (u32)AD("K", 1);
  p.pIns = AD("pins", 1); p.pDel = AD("pdel", 0); p.pRead = AD("pread", 0); p.pScan = AD("pscan", 0);
  p.roFrac = AD("ro", 0); p.roScan = AD("roscan", 0.1);
  p.src = A("src", "uniform"); p.hubFrac = AD("hub", 0); p.nHubs = (u32)AD("nhubs", 1); p.zipfS = AD("zipf", 1.0);
  p.hotEdges = (u32)AD("hot", 0); p.hotFrac = AD("hotfrac", 0); p.initEdges = (u32)AD("init", 0); p.seed = (u64)AD("seed", 1);
  std::string sys = A("sys", "gtx"), label = A("label", "run");
  int reps = (int)AD("reps", 5), check = (int)AD("check", 0), ser = (int)AD("ser", 0);
  HostWorkload w = makeWorkload(p);
  std::vector<std::string> abn;

  auto emit = [&](int rep, float ms, const u32* st, const std::vector<TxRecord>& rec, size_t bytes, const char* chk) {
    std::vector<double> upd, ro;
    for (u32 t = 0; t < w.N(); t++) {
      const TxRecord& r = rec[t];
      if (!r.txid || r.tEnd < r.tBegin) continue;
      bool isRo = true;
      for (u32 j = w.off[t]; j < w.off[t + 1]; j++) if (w.ops[j].type == OP_INS || w.ops[j].type == OP_DEL) isRo = false;
      (isRo ? ro : upd).push_back((r.tEnd - r.tBegin) / 1000.0);
    }
    double a, b, c, d, e, f; pct(upd, a, b, c); pct(ro, d, e, f);
    double s = ms / 1000.0;
    printf("RESULT,%s,%s,%d,%.4f,%u,%u,%u,%u,%u,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%zu", label.c_str(), sys.c_str(), rep, ms,
           st[ST_COMMITS], st[ST_ABORTS], st[ST_GIVEUP], st[ST_EFFECTIVE], st[ST_NOOPS], st[ST_COMMITS] / s, st[ST_EFFECTIVE] / s,
           a, b, c, d, f, bytes);
    for (int i = 0; i < AB_NCAUSES; i++) printf(",%u", st[ST_ABORT_BASE + i]);
    printf(",%u,%u,%u,%u,%s,%u\n", st[ST_CAS_FAIL], st[ST_GROWTHS], st[ST_RESV_ATOMICS], st[ST_EPOCHS], chk, st[ST_N - 1]);
    fflush(stdout);
  };

  if (sys.rfind("gtx", 0) == 0) {
    gtxg::Cfg cfg; cfg.ser = ser;
    if (sys == "gtx-cons") { cfg.coop = 0; cfg.dstconf = 0; }       // conservative GTX port
    else if (sys == "gtx-coop-only") { cfg.coop = 1; cfg.dstconf = 0; }
    else if (sys == "gtx-dst-only") { cfg.coop = 0; cfg.dstconf = 1; }
    cfg.coopScan = (int)AD("coopscan", 1);
    cfg.chRatio = (u32)AD("chratio", 1); cfg.minCap = (u32)AD("mincap", 8);
    cfg.growShift = (u32)AD("growshift", 3); cfg.prewalk = (int)AD("prewalk", 0); cfg.dbg = (int)AD("dbg", 0);
    u32 arena = gtxArenaFor(w, cfg.minCap);
    size_t descCap = (size_t)w.N() * 32 + w.initEdges.size() + (1 << 20); if (descCap > 100000000) descCap = 100000000;
    gtxg::Store S; S.init(w.V, arena, (u32)descCap, cfg);
    for (int rep = -1; rep < reps; rep++) {
      bool doCheck = check && rep == reps - 1;
      RunOut o = runGtx(w, cfg, doCheck, &S);
      if (rep < 0) continue;  // warm-up
      if (AD("prof", 0)) { double tot = 0; for (int i = 0; i < 6; i++) tot += o.stats[24 + i]; const char* nm[] = {"begin", "oploop", "install", "validate", "commit", "stamp"}; fprintf(stderr, "PROF"); for (int i = 0; i < 6; i++) fprintf(stderr, " %s=%.1f%%", nm[i], 100.0 * o.stats[24 + i] / (tot - o.stats[26])); fprintf(stderr, "\n"); }
      emit(rep, o.ms, o.stats, o.rec, o.bytes, doCheck ? (o.rep.ok ? "PASS" : "FAIL") : "-");
      if (doCheck && !o.rep.ok) fprintf(stderr, "CHECK FAIL: %s\n", o.rep.first.c_str());
    }
    S.release();
  } else {
    int mode = sys == "2pl" ? bl::M_2PL : (sys == "nontx" ? bl::M_NONTX : bl::M_STM);
    int nodeg = sys == "stm-nodeg";
    bl::Store S; S.init(w);
    DevWl d; d.upload(w);
    for (int rep = -1; rep < reps; rep++) {
      bool doCheck = check && rep == reps - 1 && mode != bl::M_NONTX;
      S.reset();
      CK(cudaMemset(d.rec, 0, d.N * sizeof(TxRecord)));
      u32 st[ST_N];
      float ms = S.run(mode, d.off, d.ops, d.N, d.res, d.rec, st, doCheck ? 1 : 0, nodeg, 4000, (int)AD("blcoop", 0));
      std::vector<TxRecord> rec(d.N); CK(cudaMemcpy(rec.data(), d.rec, d.N * sizeof(TxRecord), cudaMemcpyDeviceToHost));
      if (rep < 0) continue;
      const char* chk = "-";
      if (doCheck) {
        std::vector<OpResult> res(d.nOps); CK(cudaMemcpy(res.data(), d.res, d.nOps * sizeof(OpResult), cudaMemcpyDeviceToHost));
        CheckInput ci; ci.w = &w; ci.res = &res; ci.rec = &rec; ci.initial = w.initEdges; ci.ser = true; ci.checkObs = false;
        ci.haveFinal = true; S.finalEdges(ci.finalEdges);
        CheckReport cr = checkHistory(ci);
        chk = cr.ok ? "PASS" : "FAIL";
        if (!cr.ok) fprintf(stderr, "CHECK FAIL: %s\n", cr.first.c_str());
      }
      emit(rep, ms, st, rec, S.bytes, chk);
    }
    d.release(); S.release();
  }
  return 0;
}

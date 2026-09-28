// Correctness suite for GTX-GPU (experiment step 1 of the protocol).
//  A. adversarial randomized histories, SI and SER, all ablation switches -> checker must PASS
//  B. write-skew probe: SI must exhibit DSG cycles (anomaly allowed), SER must not
//  C. mutation tests: deliberately broken protocols -> checker must FAIL (sensitivity)
//  D. resource exhaustion: committed prefix still checks clean
#include <cstring>
#include <string>
#include "harness.hpp"

static int failures = 0;

static void report(const char* name, const gtxg::Cfg& cfg, const RunOut& o, bool expectPass) {
  long long ab = o.stats[ST_ABORTS];
  bool pass = o.rep.ok;
  bool good = (pass == expectPass);
  if (!good) failures++;
  printf("%-26s coop=%d dst=%d ser=%d cscan=%d mut=%d | commits=%u aborts=%lld giveup=%u eff=%u noop=%u "
         "casfail=%u grow=%u void=%u | DSGcyc=%lld | checker=%s %s %s\n",
         name, cfg.coop, cfg.dstconf, cfg.ser, cfg.coopScan, cfg.mut, o.stats[ST_COMMITS], ab, o.stats[ST_GIVEUP],
         o.stats[ST_EFFECTIVE], o.stats[ST_NOOPS], o.stats[ST_CAS_FAIL], o.stats[ST_GROWTHS], o.stats[ST_VOIDED],
         o.rep.cycleTxns, pass ? "PASS" : "FAIL", good ? "[as expected]" : "[UNEXPECTED]",
         pass ? "" : o.rep.first.c_str());
  fflush(stdout);
}

static HostWorkload writeSkew(u32 pairs, u32 reps) {
  // For vertex p: A = {READ(p,2), INS(p,1)}, B = {READ(p,1), INS(p,2)} -- under SI both may commit.
  HostWorkload w; w.V = pairs + 3; w.off.push_back(0);
  for (u32 r = 0; r < reps; r++)
    for (u32 p = 3; p < pairs + 3; p++) {
      u32 a = 1 + 2 * r, b = 2 + 2 * r;
      a %= w.V; b %= w.V;
      w.ops.push_back({OP_READ, p, b}); w.ops.push_back({OP_INS, p, a}); w.off.push_back((u32)w.ops.size());
      w.ops.push_back({OP_READ, p, a}); w.ops.push_back({OP_INS, p, b}); w.off.push_back((u32)w.ops.size());
    }
  return w;
}

int main(int argc, char** argv) {
  int quick = argc > 1 && !strcmp(argv[1], "quick");
  const char* only = argc > 2 ? argv[2] : nullptr;  // run only cases whose name contains this
  struct Case { const char* name; WlParams p; };
  std::vector<Case> cases;
  { WlParams p; p.V = 256; p.N = 20000; p.K = 4; p.pIns = .4; p.pDel = .3; p.pRead = .2; p.pScan = .1; p.initEdges = 2000; p.seed = 11; cases.push_back({"mixed-uniform-V256", p}); }
  { WlParams p; p.V = 1024; p.N = 20000; p.K = 4; p.src = "hub"; p.hubFrac = .5; p.pIns = .5; p.pDel = .3; p.pRead = .1; p.pScan = .1; p.initEdges = 3000; p.seed = 12; cases.push_back({"hub50-mixed", p}); }
  { WlParams p; p.V = 512; p.N = 20000; p.K = 2; p.hotEdges = 8; p.hotFrac = .8; p.pIns = .5; p.pDel = .5; p.seed = 13; cases.push_back({"identical-edge-8", p}); }
  { WlParams p; p.V = 64; p.N = 10000; p.K = 8; p.pIns = .45; p.pDel = .45; p.pRead = .05; p.pScan = .05; p.initEdges = 500; p.seed = 14; cases.push_back({"churn-V64-K8", p}); }
  { WlParams p; p.V = 2048; p.N = 20000; p.K = 4; p.src = "zipf"; p.zipfS = 1.1; p.pIns = .6; p.pDel = .2; p.pRead = .1; p.pScan = .1; p.roFrac = .5; p.roScan = .3; p.initEdges = 8000; p.seed = 15; cases.push_back({"zipf-readers50", p}); }
  { WlParams p; p.V = 4096; p.N = 30000; p.K = 32; p.src = "hub"; p.hubFrac = .3; p.pIns = .7; p.pDel = .2; p.pRead = .1; p.seed = 16; cases.push_back({"hub30-K32", p}); }

  printf("== A. randomized adversarial histories (expect PASS) ==\n");
  for (auto& cs : cases) {
    if (only && !strstr(cs.name, only)) continue;
    HostWorkload w = makeWorkload(cs.p);
    for (int ser = 0; ser <= 1; ser++)
      for (int coop = 0; coop <= 1; coop++)
        for (int dst = 0; dst <= 1; dst++) {
          if (quick && (coop != dst)) continue;
          gtxg::Cfg cfg; cfg.ser = ser; cfg.coop = coop; cfg.dstconf = dst; cfg.coopScan = (coop + dst + ser) % 2;
          RunOut o = runGtx(w, cfg, true);
          report(cs.name, cfg, o, true);
        }
  }

  printf("== B. write-skew probe ==\n");
  {
    HostWorkload w = writeSkew(4000, 4);
    for (int ser = 0; ser <= 1; ser++) {
      gtxg::Cfg cfg; cfg.ser = ser;
      RunOut o = runGtx(w, cfg, true);
      report(ser ? "write-skew SER" : "write-skew SI", cfg, o, true);
      if (!ser) printf("   SI anomaly witnessed: %s (DSG back edges=%lld)\n", o.rep.cycleTxns ? "YES" : "no (probe too weak)", o.rep.cycleTxns);
      if (ser && o.rep.cycleTxns) { printf("   SER produced a cycle!\n"); failures++; }
    }
  }

  printf("== C. mutation tests (expect FAIL: checker must catch the broken protocol) ==\n");
  {
    WlParams p = cases[2].p;  // identical-edge contention
    HostWorkload w1 = makeWorkload(p);
    auto counts = [](const char* n, const RunOut& o) {
      printf("   %s violations: C1-read=%lld C1-scan=%lld C2-obs=%lld C3-ww=%lld C3-sameEpoch=%lld C4-finalMissing=%lld C4-finalExtra=%lld C5-backEdges=%lld | prototype log-vs-final: missing=%lld extra=%lld\n",
             n, o.rep.readMismatch, o.rep.scanMismatch, o.rep.obsMismatch, o.rep.wwViolations, o.rep.sameEpochWW,
             o.rep.finalMissing, o.rep.finalExtra, o.rep.cycleTxns, o.rep.logFinalMissing, o.rep.logFinalExtra);
    };
    gtxg::Cfg c1; c1.mut = 1; { RunOut o = runGtx(w1, c1, true); report("mut1-no-ww-check", c1, o, false); counts("mut1", o); }
    WlParams q = cases[0].p; q.N = 20000;
    HostWorkload w2 = makeWorkload(q);
    gtxg::Cfg c2; c2.mut = 2; { RunOut o = runGtx(w2, c2, true); report("mut2-dirty-reads", c2, o, false); counts("mut2", o); }
    gtxg::Cfg c3; c3.mut = 3; { RunOut o = runGtx(w2, c3, true); report("mut3-ignore-snapshot", c3, o, false); counts("mut3", o); }
  }

  printf("== D. resource exhaustion (tiny arena; expect PASS on committed prefix) ==\n");
  {
    WlParams p; p.V = 256; p.N = 20000; p.K = 4; p.pIns = .8; p.pDel = .2; p.seed = 17;
    HostWorkload w = makeWorkload(p);
    gtxg::Cfg cfg;
    RunOut o = runGtx(w, cfg, true, nullptr, 20000);
    report("tiny-arena", cfg, o, true);
    printf("   resource aborts=%u giveups=%u commits=%u flag=%u\n", o.stats[ST_ABORT_BASE + AB_RESOURCE], o.stats[ST_GIVEUP], o.stats[ST_COMMITS], o.stats[ST_N - 1]);
    for (u32 ar : {20000u, 40000u, 200000u}) { RunOut q = runGtx(w, cfg, true, nullptr, ar); printf("   arena=%u commits=%u resource=%u flag=%u grow=%u checker=%s\n", ar, q.stats[ST_COMMITS], q.stats[ST_ABORT_BASE + AB_RESOURCE], q.stats[ST_N - 1], q.stats[ST_GROWTHS], q.rep.ok ? "PASS" : q.rep.first.c_str()); }
  }
  printf("\nRESULT: %s (%d unexpected)\n", failures ? "FAILURES" : "ALL AS EXPECTED", failures);
  return failures ? 1 : 0;
}

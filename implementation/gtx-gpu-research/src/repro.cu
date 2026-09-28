// Loop a configuration until the history checker fails; prints forensic dump (set GTX_FORENSIC=1).
#include <cstring>
#include "harness.hpp"

int main(int argc, char** argv) {
  WlParams p; p.V = 1024; p.N = 20000; p.K = 4; p.src = "hub"; p.hubFrac = .5; p.pIns = .5; p.pDel = .3; p.pRead = .1; p.pScan = .1;
  p.initEdges = 3000; p.seed = 12;
  gtxg::Cfg cfg; cfg.ser = 1; cfg.coop = 0; cfg.dstconf = 1; cfg.coopScan = 0;
  int iters = argc > 1 ? atoi(argv[1]) : 20;
  if (argc > 2) cfg.ser = atoi(argv[2]);
  if (argc > 3) cfg.coopScan = atoi(argv[3]);
  if (argc > 4) cfg.dbg = atoi(argv[4]);
  for (int i = 0; i < iters; i++) {
    p.seed = 12 + i;
    HostWorkload w = makeWorkload(p);
    RunOut o = runGtx(w, cfg, true);
    printf("iter %d seed %llu: ms=%.0f flag=%u commits=%u aborts=%u giveup=%u -> %s %s\n", i, (unsigned long long)p.seed, o.ms, o.stats[ST_N - 1], o.stats[ST_COMMITS],
           o.stats[ST_ABORTS], o.stats[ST_GIVEUP], o.rep.ok ? "PASS" : "FAIL", o.rep.ok ? "" : o.rep.first.c_str());
    if (!o.rep.ok)
      printf("   counts: read=%lld obs=%lld scan=%lld ww=%lld sameEpochWW=%lld cycles=%lld finalMissing=%lld finalExtra=%lld\n",
             o.rep.readMismatch, o.rep.obsMismatch, o.rep.scanMismatch, o.rep.wwViolations, o.rep.sameEpochWW,
             o.rep.cycleTxns, o.rep.finalMissing, o.rep.finalExtra);
    fflush(stdout);
    if (!o.rep.ok) return 1;
  }
  return 0;
}

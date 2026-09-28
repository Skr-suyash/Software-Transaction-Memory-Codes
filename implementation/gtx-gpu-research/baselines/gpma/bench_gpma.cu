// GPMA+ batch-update benchmark on the SAME workload streams as bench.cu (workload.hpp generator).
// Built twice (see build_gpma.bat):
//   gpma_port.exe     : ../../../gpu-stm-dynamic-graphs/baselines/gpma_port/gpma.cuh (CDP flattened to host loop)
//   gpma_upstream.exe : pristine upstream gpma_demo/gpma.cuh, legacy CDP1 (CUDA_FORCE_CDP1_IF_SUPPORTED)
// A transaction stream is flattened into edge batches of --batch edges (INS -> value 1, DEL -> VALUE_NONE);
// reads/scans are not supported by the batch interface and are rejected.
// Timing: GPU operation time of update_gpma per batch (device-resident input, no PCIe), cudaEvent.
// Output: RESULT,label,gpma-<variant>,rep,ms,batches,edges,effective,edges_per_s,eff_per_s,p50_batch_ms,p99_batch_ms,bytes,verify
#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <unordered_set>
#include <vector>
#include "gpma.cuh"
#include "../../src/workload.hpp"

static std::map<std::string, std::string> args;
static double AD(const char* k, double d) { auto it = args.find(k); return it == args.end() ? d : atof(it->second.c_str()); }
static std::string A(const char* k, const char* d) { auto it = args.find(k); return it == args.end() ? d : it->second; }

#ifndef GPMA_VARIANT
#define GPMA_VARIANT "port"
#endif

int main(int argc, char** argv) {
  for (int i = 1; i + 1 < argc; i += 2) args[argv[i] + 2] = argv[i + 1];
  WlParams p;
  p.V = (u32)AD("V", 1 << 20); p.N = (u32)AD("N", 1 << 20); p.K = (u32)AD("K", 1);
  p.pIns = AD("pins", 1); p.pDel = AD("pdel", 0); p.src = A("src", "uniform"); p.hubFrac = AD("hub", 0);
  p.zipfS = AD("zipf", 1.0); p.hotEdges = (u32)AD("hot", 0); p.hotFrac = AD("hotfrac", 0);
  p.initEdges = (u32)AD("init", 0); p.seed = (u64)AD("seed", 1);
  u32 batch = (u32)AD("batch", 65536);
  int reps = (int)AD("reps", 5);
  std::string label = A("label", "run");
  HostWorkload w = makeWorkload(p);
  for (auto& o : w.ops) if (o.type != OP_INS && o.type != OP_DEL) { fprintf(stderr, "GPMA supports only INS/DEL batches\n"); return 2; }
  cudaDeviceSetLimit(cudaLimitMallocHeapSize, 1024ll * 1024 * 1024);

  // host-side batches (identical op order to the transactional run)
  std::vector<std::vector<KEY_TYPE>> bk; std::vector<std::vector<VALUE_TYPE>> bv;
  for (size_t i = 0; i < w.ops.size(); i += batch) {
    size_t e = std::min(w.ops.size(), i + batch);
    std::vector<KEY_TYPE> k; std::vector<VALUE_TYPE> v;
    for (size_t j = i; j < e; j++) { k.push_back(((KEY_TYPE)w.ops[j].u << 32) | w.ops[j].v); v.push_back(w.ops[j].type == OP_INS ? 1 : VALUE_NONE); }
    bk.push_back(k); bv.push_back(v);
  }
  // effective edge changes via sequential replay (same semantics as the transactional systems)
  std::unordered_set<u64> live;
  for (auto& e : w.initEdges) live.insert(((u64)e.first << 32) | e.second);
  size_t effective = 0;
  for (auto& o : w.ops) { u64 k = ((u64)o.u << 32) | o.v; if (o.type == OP_INS) effective += live.insert(k).second; else effective += live.erase(k); }

  for (int rep = -1; rep < reps; rep++) {
    GPMA gpma;
    init_csr_gpma(gpma, p.V);
    cudaDeviceSynchronize();
    if (!w.initEdges.empty()) {
      thrust::host_vector<KEY_TYPE> ik(w.initEdges.size()); thrust::host_vector<VALUE_TYPE> iv(w.initEdges.size(), 1);
      for (size_t i = 0; i < w.initEdges.size(); i++) ik[i] = ((KEY_TYPE)w.initEdges[i].first << 32) | w.initEdges[i].second;
      DEV_VEC_KEY dk = ik; DEV_VEC_VALUE dv = iv;
      update_gpma(gpma, dk, dv);
      cudaDeviceSynchronize();
    }
    std::vector<DEV_VEC_KEY> dks; std::vector<DEV_VEC_VALUE> dvs;
    for (size_t b = 0; b < bk.size(); b++) { thrust::host_vector<KEY_TYPE> hk(bk[b].begin(), bk[b].end()); thrust::host_vector<VALUE_TYPE> hv(bv[b].begin(), bv[b].end()); dks.emplace_back(hk); dvs.emplace_back(hv); }
    cudaDeviceSynchronize();
    cudaEvent_t a, c; cudaEventCreate(&a); cudaEventCreate(&c);
    std::vector<double> per; double tot = 0;
    for (size_t b = 0; b < bk.size(); b++) {
      DEV_VEC_KEY k2 = dks[b]; DEV_VEC_VALUE v2 = dvs[b];  // update_gpma consumes its inputs
      cudaDeviceSynchronize();
      cudaEventRecord(a);
      update_gpma(gpma, k2, v2);
      cudaEventRecord(c); cudaEventSynchronize(c);
      float ms = 0; cudaEventElapsedTime(&ms, a, c); per.push_back(ms); tot += ms;
    }
    if (rep < 0) continue;
    // verify final live edge set
    thrust::host_vector<KEY_TYPE> hk = gpma.keys; thrust::host_vector<VALUE_TYPE> hv = gpma.values;
    size_t got = 0, bad = 0;
    for (size_t i = 0; i < hk.size(); i++) {
      if (hk[i] == KEY_NONE || hv[i] == VALUE_NONE) continue;
      KEY_TYPE k = hk[i];
      if ((k & 0xFFFFFFFFull) == COL_IDX_NONE || k == KEY_MAX) continue;  // row / tree sentinels
      got++; if (!live.count(k)) bad++;
    }
    std::sort(per.begin(), per.end());
    size_t edges = w.ops.size();
    printf("RESULT,%s,gpma-%s,%d,%.4f,%zu,%zu,%zu,%.1f,%.1f,%.4f,%.4f,%zu,%s\n", label.c_str(), GPMA_VARIANT, rep, tot, bk.size(), edges,
           effective, edges / (tot / 1000), effective / (tot / 1000), per[per.size() / 2], per[(size_t)(0.99 * (per.size() - 1))],
           (size_t)(gpma.keys.size() * (sizeof(KEY_TYPE) + sizeof(VALUE_TYPE))), (got == live.size() && !bad) ? "PASS" : "FAIL");
    if (got != live.size() || bad) fprintf(stderr, "verify: live=%zu got=%zu bad=%zu\n", live.size(), got, bad);
    fflush(stdout);
  }
  return 0;
}

"""Summarize results/raw.csv -> results/summary.csv and results/summary.md.

Per (label, sys): median/min/max kernel ms over repetitions, committed txn/s and effective edge changes/s (from the
median run), abort ratio, give-ups, update/read-only latency percentiles, bytes, checker verdict and flags.
Speedups: GTX-GPU ('gtx') vs every other system on the same label = ratio of median COMMITTED-transaction throughput
(committed txns / kernel time; systems that give up transactions are not rewarded for finishing early), with a 95% bootstrap CI
over repetitions (ratio of resampled medians, 2000 resamples, fixed seed). DNF rows give a lower bound.
"""
import csv, os, random, statistics, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "results", "raw.csv")
ORDER = ["gtx", "gtx-cons", "gtx-coop-only", "gtx-dst-only", "2pl", "stm", "stm-nodeg", "nontx",
         "gpma-upstream", "gpma-port"]
NAMES = {"gtx": "GTX-GPU (ours)", "gtx-cons": "GTX-conservative port", "gtx-coop-only": "GTX coop only",
         "gtx-dst-only": "GTX dst-conflicts only", "2pl": "2PL vertex locks", "stm": "TL2 word-STM",
         "stm-nodeg": "TL2 word-STM (no degree)", "nontx": "non-transactional CAS",
         "gpma-upstream": "GPMA+ (upstream, CDP1)", "gpma-port": "GPMA+ (Windows port)"}


def load(path=RAW):
    rows = defaultdict(list)
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            rows[(r["label"], r["sys"])].append(r)
    return rows


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def boot_ratio(a, b, n=2000, seed=7):
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        ra = [rnd.choice(a) for _ in a]
        rb = [rnd.choice(b) for _ in b]
        out.append(med(ra) / med(rb))
    out.sort()
    return out[int(0.025 * n)], out[int(0.975 * n)]


def main():
    rows = load()
    summary = []
    times = {}
    for (label, sysn), rs in rows.items():
        ok = [r for r in rs if r["ms"].replace(".", "", 1).isdigit()]
        if not ok:
            summary.append({"label": label, "sys": sysn, "status": rs[0]["ms"], "reps": 0})
            times[(label, sysn)] = ("DNF", rs[0]["ms"])
            continue
        ms = [float(r["ms"]) for r in ok]
        ok.sort(key=lambda r: float(r["ms"]))
        m = ok[len(ok) // 2]
        commits, aborts = float(m["commits"] or 0), float(m["aborts"] or 0)
        summary.append({
            "label": label, "sys": sysn, "status": "ok", "reps": len(ok),
            "ms_median": med(ms), "ms_min": min(ms), "ms_max": max(ms),
            "txn_per_s": float(m["txn_per_s"]), "eff_per_s": float(m["eff_per_s"]),
            "commits": int(commits), "aborts": int(aborts), "abort_ratio": aborts / max(1.0, commits + aborts),
            "giveup": int(float(m["giveup"] or 0)),
            "upd_p50_us": float(m["upd_p50_us"]), "upd_p99_us": float(m["upd_p99_us"]),
            "ro_p50_us": float(m["ro_p50_us"]), "ro_p99_us": float(m["ro_p99_us"]),
            "bytes": int(float(m["bytes"] or 0)), "check": ";".join(sorted({r["check"] for r in ok})),
            "flag": ";".join(sorted({r.get("flag", "") for r in ok})),
        })
        times[(label, sysn)] = ("ok", [float(r["commits"] or 0) / float(r["ms"]) for r in ok])
    # speedups of gtx
    sp = []
    for (label, sysn), t in times.items():
        if sysn == "gtx" or (label, "gtx") not in times or times[(label, "gtx")][0] != "ok":
            continue
        g = times[(label, "gtx")][1]
        if t[0] == "DNF":
            # lower bound: the baseline committed at most N (= workload size) txns in more than the timeout
            nmax = max(s["commits"] for s in summary if s["label"] == label and s.get("status") == "ok")
            lb = med(g) / (nmax / float(t[1].split(">")[1])) if ">" in t[1] else float("nan")
            sp.append({"label": label, "vs": sysn, "speedup": f">{lb:.0f}", "ci_lo": "", "ci_hi": "", "note": "baseline did not finish"})
        else:
            lo, hi = boot_ratio(g, t[1])
            sp.append({"label": label, "vs": sysn, "speedup": f"{med(g) / med(t[1]):.2f}", "ci_lo": f"{lo:.2f}", "ci_hi": f"{hi:.2f}", "note": ""})
    out = os.path.join(ROOT, "results")
    keys = ["label", "sys", "status", "reps", "ms_median", "ms_min", "ms_max", "txn_per_s", "eff_per_s", "commits", "aborts",
            "abort_ratio", "giveup", "upd_p50_us", "upd_p99_us", "ro_p50_us", "ro_p99_us", "bytes", "check", "flag"]
    with open(os.path.join(out, "summary.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys); w.writeheader()
        for s in sorted(summary, key=lambda s: (s["label"], ORDER.index(s["sys"]) if s["sys"] in ORDER else 99)):
            w.writerow({k: s.get(k, "") for k in keys})
    with open(os.path.join(out, "speedups.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["label", "vs", "speedup", "ci_lo", "ci_hi", "note"]); w.writeheader()
        for s in sorted(sp, key=lambda s: (s["label"], ORDER.index(s["vs"]) if s["vs"] in ORDER else 99)):
            w.writerow(s)
    # markdown
    labels = sorted({s["label"] for s in summary})
    with open(os.path.join(out, "summary.md"), "w", encoding="utf-8") as f:
        f.write("# Benchmark summary (RTX 4060 Laptop, CUDA 12.8; medians over repetitions)\n\n")
        f.write("Speedup = GTX-GPU committed-transaction throughput / baseline committed-transaction throughput (>1: GTX-GPU faster; medians over repetitions); 95% bootstrap CI in brackets; '>x' = lower bound for runs that did not finish within the timeout.\n\n")
        for lab in labels:
            f.write(f"## {lab}\n\n| system | ms (median) | committed txn/s | effective edges/s | abort ratio | give-ups | upd p99 us | RO p99 us | check | speedup of GTX-GPU |\n|---|---:|---:|---:|---:|---:|---:|---:|---|---|\n")
            for s in sorted([s for s in summary if s["label"] == lab], key=lambda s: ORDER.index(s["sys"]) if s["sys"] in ORDER else 99):
                spd = next((x for x in sp if x["label"] == lab and x["vs"] == s["sys"]), None)
                st = f"{spd['speedup']}" + (f" [{spd['ci_lo']}, {spd['ci_hi']}]" if spd and spd["ci_lo"] else "") if spd else ("—" if s["sys"] == "gtx" else "")
                if s["status"] != "ok":
                    f.write(f"| {NAMES.get(s['sys'], s['sys'])} | {s['status']} | | | | | | | | {st} |\n")
                    continue
                f.write(f"| {NAMES.get(s['sys'], s['sys'])} | {s['ms_median']:.3f} | {s['txn_per_s'] / 1e6:.2f} M | {s['eff_per_s'] / 1e6:.2f} M | "
                        f"{s['abort_ratio']:.3f} | {s['giveup']} | {s['upd_p99_us']:.0f} | {s['ro_p99_us']:.0f} | {s['check']} | {st} |\n")
            f.write("\n")
    # GPMA+ on identical streams (K=1 => same edge order): compare effective edge changes per second
    gp = os.path.join(out, "gpma_raw.csv")
    if os.path.exists(gp):
        g = defaultdict(list)
        with open(gp, newline="") as f:
            for r in csv.DictReader(f):
                if r["ms"].replace(".", "", 1).isdigit():
                    g[(r["label"], r["sys"], r["batch"])].append(r)
        with open(os.path.join(out, "gpma_summary.md"), "w", encoding="utf-8") as f:
            f.write("# GPMA+ vs transactional systems on identical streams (effective edge changes per second)\n\n")
            f.write("GPMA+ applies each batch as one sorted unit (no multi-edge transactions, no concurrent readers, "
                    "intra-batch INS/DEL order not preserved). Transactional systems commit every operation as its own "
                    "transaction (K=1). Times are GPU operation time only.\n\n")
            f.write("| stream | system | batch | median ms | effective edges/s | final-state verify | GTX-GPU speedup |\n|---|---|---:|---:|---:|---|---:|\n")
            for lab in sorted({k[0] for k in g}):
                gt = next((s for s in summary if s["label"] == lab and s["sys"] == "gtx" and s["status"] == "ok"), None)
                rows = []
                for (l2, sysn, b), rs in g.items():
                    if l2 != lab:
                        continue
                    rs.sort(key=lambda r: float(r["ms"])); m = rs[len(rs) // 2]
                    rows.append((sysn, int(b), float(m["ms"]), float(m["eff_per_s"]), ";".join(sorted({r["verify"] for r in rs}))))
                for sysn, b, ms, eps, ver in sorted(rows):
                    spd = f"{gt['eff_per_s'] / eps:.1f}x" if gt else ""
                    f.write(f"| {lab} | {NAMES.get(sysn, sysn)} | {b} | {ms:.2f} | {eps / 1e6:.2f} M | {ver} | {spd} |\n")
                for s in sorted([s for s in summary if s["label"] == lab and s["status"] == "ok"], key=lambda s: ORDER.index(s["sys"]) if s["sys"] in ORDER else 99):
                    f.write(f"| {lab} | {NAMES.get(s['sys'], s['sys'])} | txn | {s['ms_median']:.2f} | {s['eff_per_s'] / 1e6:.2f} M | {s['check'] or '-'} | |\n")
    print(f"wrote {len(summary)} rows, {len(sp)} speedups")


if __name__ == "__main__":
    main()

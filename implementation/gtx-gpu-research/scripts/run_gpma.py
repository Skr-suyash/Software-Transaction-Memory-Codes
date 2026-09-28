"""GPMA+ (port and upstream-CDP1) on the same insert/churn streams as run_matrix.py (K=1 streams => identical op order).
Appends to results/gpma_raw.csv. Each run in its own process with a timeout (DNF recorded)."""
import csv, os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V = 1 << 20
SCEN = [
    ("uniform-ins-K1", f"--V {V} --N {1 << 20} --K 1 --init 4000000 --pins 1"),
    ("hub50-ins-K1", f"--V {V} --N {1 << 20} --K 1 --init 4000000 --src hub --hub 0.5 --pins 1"),
    ("uniform-churn-K1", f"--V {V} --N {1 << 20} --K 1 --init 4000000 --pins .5 --pdel .5"),
    ("rmat-churn-K1", f"--V {V} --N {1 << 20} --K 1 --init 4000000 --src rmat --pins .5 --pdel .5"),
]
BATCHES = [65536, 524288]
COLS = ["label", "sys", "rep", "ms", "batches", "edges", "effective", "edges_per_s", "eff_per_s", "p50_batch_ms",
        "p99_batch_ms", "bytes", "verify", "batch", "args", "timestamp"]


def main():
    reps = int(sys.argv[sys.argv.index("--reps") + 1]) if "--reps" in sys.argv else 5
    timeout = float(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 300
    out = os.path.join(ROOT, "results", "gpma_raw.csv")
    new = not os.path.exists(out)
    done = set()
    if not new:
        with open(out, newline="") as f:
            for r in csv.DictReader(f):
                done.add((r["label"], r["sys"], r["batch"]))
    with open(out, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(COLS)
        for label, args in SCEN:
            for b in BATCHES:
                for variant in ("upstream", "port"):
                    sysn = "gpma-" + variant
                    if (label, sysn, str(b)) in done:
                        continue
                    exe = os.path.join(ROOT, "bin", f"gpma_{variant}.exe")
                    cmd = [exe, "--label", label, "--reps", str(reps), "--batch", str(b)] + args.split()
                    t0 = time.time()
                    try:
                        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
                        rows = [l.split(",")[1:] for l in p.stdout.splitlines() if l.startswith("RESULT,")]
                        if not rows:
                            rows = [[label, sysn, "-1", "ERR"] + [""] * 9]
                            print("ERR", label, sysn, b, p.returncode, p.stderr[-400:])
                        elif p.stderr.strip():
                            print("  stderr:", p.stderr.strip()[-300:])
                    except subprocess.TimeoutExpired:
                        rows = [[label, sysn, "-1", f"DNF>{timeout * 1000:.0f}"] + [""] * 9]
                    for r in rows:
                        w.writerow(r + [b, args, time.strftime("%Y-%m-%d %H:%M:%S")])
                    f.flush()
                    ms = sorted(float(r[3]) for r in rows if r[3].replace(".", "", 1).isdigit())
                    print(f"{label:20s} {sysn:14s} batch={b:7d} median_ms={ms[len(ms) // 2] if ms else rows[0][3]} "
                          f"verify={rows[0][-1] if rows else '?'} ({time.time() - t0:.1f}s)", flush=True)


if __name__ == "__main__":
    main()

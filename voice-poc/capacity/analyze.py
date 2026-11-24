"""Turns the sampler CSV + lk load-test outputs into poc-capacity.md. Everything here is computed from samples taken
on the GitHub runner during the run (MEASURED on that runner), nothing is estimated.
usage: analyze.py report OUT_DIR   |   analyze.py gate OUT_DIR PHASE_PREFIX  (exit 0 = keep going)"""
import csv
import glob
import json
import os
import re
import sys

NCPU = os.cpu_count() or 1


def set_ncpu(out):
    """runner core count from the run itself (the analysis may run elsewhere)"""
    global NCPU
    fn = os.path.join(out, "raw", "hardware-summary.txt")
    if os.path.exists(fn):
        for line in open(fn):
            if line.startswith("nproc:"):
                NCPU = int(line.split(":")[1])


METRIC_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([-+0-9.eE]+|NaN)$")


def scrape(fn):
    tot = {}
    if not os.path.exists(fn):
        return tot
    for line in open(fn, errors="replace"):
        m = METRIC_RE.match(line.strip())
        if not m or m.group(3) == "NaN":
            continue
        name = m.group(1)
        if name.startswith("livekit_") and not name.endswith("_bucket"):
            tot[name] = tot.get(name, 0.0) + float(m.group(3))
    return tot


def metric_deltas(out, phase):
    a = scrape(os.path.join(out, "raw", phase, "metrics-start.txt"))
    b = scrape(os.path.join(out, "raw", phase, "metrics-end.txt"))
    d = {k: b[k] - a.get(k, 0.0) for k in b}
    res = {}
    for k, v in d.items():
        if k.endswith("_sum") and k[:-4] + "_count" in d and d[k[:-4] + "_count"] > 0:
            res[k[:-4] + " (avg)"] = v / d[k[:-4] + "_count"]
        elif not k.endswith("_count") and not k.endswith("_sum") and v != 0:
            res[k] = v
    return res


def load_samples(out):
    rows = []
    with open(os.path.join(out, "raw", "samples.csv")) as f:
        for r in csv.DictReader(f):
            try:
                rows.append({k: float(v) if k not in ("ds_cpu", "ds_mem") else v for k, v in r.items()})
            except ValueError:
                pass
    return rows


def load_phases(out):
    # the mapping text may contain commas: first 4 and last 5 fields are fixed, the middle is the mapping
    keys = ["name", "N", "pattern", "rooms"]
    tail = ["start", "end", "mstart", "mend", "srv_errors"]
    out_rows = []
    with open(os.path.join(out, "raw", "phases.csv")) as f:
        for i, line in enumerate(f):
            parts = line.rstrip("\n").split(",")
            if i == 0 or len(parts) < 10:
                continue
            row = dict(zip(keys, parts[:4]))
            row.update(dict(zip(tail, parts[-5:])))
            row["mapping"] = ",".join(parts[4:-5])
            out_rows.append(row)
    return out_rows


def intervals(rows, t0, t1):
    sel = [r for r in rows if t0 <= r["ts"] <= t1]
    out = []
    for a, b in zip(sel, sel[1:]):
        dt = b["ts"] - a["ts"]
        if dt <= 0:
            continue
        busy = (b["cpu_busy"] - a["cpu_busy"]) / max(1, (b["cpu_all"] - a["cpu_all"])) * 100 * NCPU
        out.append({
            "srv_cpu": (b["cg_usec"] - a["cg_usec"]) / dt / 1e4,
            "mem_mb": b["cg_mem"] / 1048576,
            "lo_mbit": (b["lo_rx"] - a["lo_rx"]) * 8 / dt / 1e6,
            "d0_mbit": (b["d0_rx"] - a["d0_rx"]) * 8 / dt / 1e6,
            "udp_in_pps": (b["udp_in"] - a["udp_in"]) / dt,
            "udp_out_pps": (b["udp_out"] - a["udp_out"]) / dt,
            "runner_cpu": busy,
        })
    err = 0
    if sel:
        err = int((sel[-1]["udp_inerr"] - sel[0]["udp_inerr"]) + (sel[-1]["udp_rcvbuf"] - sel[0]["udp_rcvbuf"])
                  + (sel[-1]["udp_sndbuf"] - sel[0]["udp_sndbuf"]))
    return out, err


def avg(xs):
    return sum(xs) / len(xs) if xs else 0.0


BITRATE = re.compile(r"([\d.]+)\s*(bps|kbps|mbps)")
LOSS = re.compile(r"(\d+) \(([\d.]+)%\)")


def lk_summary(out, phase):
    tracks = expected = errs = dropped_pk = 0
    kbps = 0.0
    worst_loss = 0.0
    warn = 0
    connect_fail = 0
    files = sorted(glob.glob(os.path.join(out, "raw", phase, "*.txt")))
    for fn in files:
        txt = open(fn, errors="replace").read()
        connect_fail += len(re.findall(r"could not connect", txt))
        warn += len(re.findall(r"could not connect|failed|error", txt, re.I)) - txt.count("Error")  # header word
        total = [l for l in txt.splitlines() if re.search(r"(^|[│|\s])Total([│|\s]|$)", l)]
        if not total:
            continue
        line = total[-1]
        m = re.search(r"(\d+)/(\d+)", line)
        if m:
            tracks += int(m.group(1))
            expected += int(m.group(2))
        b = BITRATE.search(line)
        if b:
            v = float(b.group(1))
            kbps += {"bps": v / 1000, "kbps": v, "mbps": v * 1000}[b.group(2)]
        lo = LOSS.search(line)
        if lo:
            dropped_pk += int(lo.group(1))
            worst_loss = max(worst_loss, float(lo.group(2)))
        nums = re.findall(r"(\d+)\s*[│|]?\s*$", line)
        if nums:
            errs += int(nums[-1])
    return {"files": len(files), "tracks": tracks, "expected": expected, "rx_kbps": kbps,
            "dropped_pkts": dropped_pk, "worst_room_loss_pct": worst_loss, "tester_errors": errs,
            "warn_lines": max(0, warn), "connect_failures": connect_fail}


def phase_stats(out, rows, p):
    iv, udp_err = intervals(rows, float(p["mstart"]), float(p["mend"]))
    lk = lk_summary(out, p["name"])
    sc = [i["srv_cpu"] for i in iv]
    mm = [i["mem_mb"] for i in iv]
    return {
        "name": p["name"], "N": p["N"], "pattern": p["pattern"], "rooms": p["rooms"], "mapping": p["mapping"],
        "samples": len(iv),
        "srv_cpu_avg": avg(sc), "srv_cpu_max": max(sc) if sc else 0,
        "mem_avg": avg(mm), "mem_max": max(mm) if mm else 0,
        "lo_mbit": avg([i["lo_mbit"] for i in iv]), "d0_mbit": avg([i["d0_mbit"] for i in iv]),
        "udp_in_pps": avg([i["udp_in_pps"] for i in iv]), "udp_out_pps": avg([i["udp_out_pps"] for i in iv]),
        "udp_err": udp_err, "runner_cpu_avg": avg([i["runner_cpu"] for i in iv]),
        "runner_cpu_max": max([i["runner_cpu"] for i in iv]) if iv else 0,
        "srv_log_errors": int(p.get("srv_errors") or 0), **lk,
        "prom": metric_deltas(out, p["name"]),
    }


def prom_cell(s):
    p = s.get("prom") or {}
    loss = p.get("livekit_packet_loss_percent (avg)")
    jit = p.get("livekit_jitter_us (avg)")
    rtt = p.get("livekit_rtt_ms (avg)")
    f = lambda v, k=1.0: "-" if v is None else f"{v / k:.2f}"
    return f"{f(loss)} / {f(jit, 1000)} / {f(rtt)}"


def gate(out, prefix):
    set_ncpu(out)
    rows = load_samples(out)
    ok = True
    for p in load_phases(out):
        if p["name"].startswith(prefix):
            s = phase_stats(out, rows, p)
            print(f"gate {p['name']}: cpu_max={s['srv_cpu_max']:.0f}% tester_errors={s['tester_errors']} "
                  f"udp_err={s['udp_err']} tracks={s['tracks']}/{s['expected']} srv_log_errors={s['srv_log_errors']}")
            if s["srv_cpu_max"] >= 140 or s["tester_errors"] > 0 or s["tracks"] < s["expected"]:
                ok = False
    sys.exit(0 if ok else 1)


def report(out):
    set_ncpu(out)
    rows = load_samples(out)
    phases = load_phases(out)
    stats = [phase_stats(out, rows, p) for p in phases]
    json.dump(stats, open(os.path.join(out, "poc-capacity.json"), "w"), indent=1)
    hw = open(os.path.join(out, "raw", "hardware-summary.txt")).read() if os.path.exists(
        os.path.join(out, "raw", "hardware-summary.txt")) else ""
    L = ["# Group voice PoC: capacity on a GitHub-hosted runner", "",
         "**MEASURED on a temporary GitHub Actions runner, NOT on the production VPS.** The load generator (lk) runs "
         "on the same machine and competes for CPU; see the runner CPU column. LiveKit is capped with "
         "`--cpus=1.5 --memory=2g --cpu-shares=256` (the proposed production limits).", "",
         "```", hw.strip(), "```", "",
         "Column notes: server CPU = livekit-server container cgroup usage, % of ONE core (cap 150%). "
         "Mbit/s = loopback bytes/s (all SFU media is local, so lo carries ingress+egress once each). "
         "pps = kernel UDP datagrams/s (on loopback each packet is counted once out and once in). "
         "UDP err = InErrors+RcvbufErrors+SndbufErrors during the window. Loss = lk subscriber-side dropped packets. "
         "Runner CPU = whole machine busy, % of one core (" + str(NCPU) + " cores = " + str(NCPU * 100) + "%); "
         "runner minus server is roughly the generator + sampler.", "",
         "| N | pattern | rooms | mapping per room | srv CPU avg/max % | mem avg/max MB | lo Mbit/s | UDP pps in/out "
         "| UDP err | tracks rx/expected | rx kbit/s (sum) | dropped pkts (worst room %) | tester errors / connect failures | runner CPU avg/max % | server-side loss % / jitter ms / RTT ms |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for s in stats:
        if not s["name"].startswith("cap-"):
            continue
        L.append(f"| {s['N']} | {s['pattern']} | {s['rooms']} | {s['mapping']} | {s['srv_cpu_avg']:.0f} / {s['srv_cpu_max']:.0f} "
                 f"| {s['mem_avg']:.0f} / {s['mem_max']:.0f} | {s['lo_mbit']:.1f} | {s['udp_in_pps']:.0f} / {s['udp_out_pps']:.0f} "
                 f"| {s['udp_err']} | {s['tracks']}/{s['expected']} | {s['rx_kbps']:.0f} | {s['dropped_pkts']} ({s['worst_room_loss_pct']:.2f}%) "
                 f"| {s['tester_errors']} / {s['connect_failures']} | {s['runner_cpu_avg']:.0f} / {s['runner_cpu_max']:.0f} | {prom_cell(s)} |")
    other = [s for s in stats if not s["name"].startswith("cap-")]
    if other:
        L += ["", "## TURN and impairment phases", "",
              "| phase | rooms | mapping | srv CPU avg/max % | lo Mbit/s | docker0 Mbit/s | UDP pps in/out | tracks rx/expected "
              "| dropped pkts (worst %) | tester errors | runner CPU avg % |", "|---|---|---|---|---|---|---|---|---|---|---|"]
        for s in other:
            L.append(f"| {s['name']} | {s['rooms']} | {s['mapping']} | {s['srv_cpu_avg']:.0f} / {s['srv_cpu_max']:.0f} | {s['lo_mbit']:.1f} "
                     f"| {s['d0_mbit']:.2f} | {s['udp_in_pps']:.0f} / {s['udp_out_pps']:.0f} | {s['tracks']}/{s['expected']} "
                     f"| {s['dropped_pkts']} ({s['worst_room_loss_pct']:.2f}%) | {s['tester_errors']} | {s['runner_cpu_avg']:.0f} |")
    L += ["", "## Server-side RTP metrics (Prometheus, delta over each whole phase; counters summed over labels)", ""]
    for s in stats:
        md = metric_deltas(out, s["name"])
        if md:
            L.append(f"- **{s['name']}**: " + "; ".join(f"{k}={v:.4g}" for k, v in sorted(md.items())))
    for extra in ("turn-evidence.txt", "perm.json", "impairment.txt"):
        fn = os.path.join(out, "raw", extra)
        if os.path.exists(fn):
            L += ["", f"## {extra}", "", "```", open(fn, errors="replace").read().strip()[:6000], "```"]
    open(os.path.join(out, "poc-capacity.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    if sys.argv[1] == "gate":
        gate(sys.argv[2], sys.argv[3])
    else:
        report(sys.argv[2])

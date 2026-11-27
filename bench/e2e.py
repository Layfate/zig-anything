"""Reproducible end-to-end benchmark of zig-anything's own workflow.

    python bench/e2e.py [--baseline v0.1.1] [--runs 9] [--out bench/results.json]

Builds the current tree (and, with --baseline, a git ref in a temporary
worktree) with -Doptimize=fast, copies each example into a fresh directory
per build, and times whole commands as a user runs them:

    record <unit>        re-record when nothing changed
    diff <unit>          replay every case when nothing changed
    gate <unit>          the full definition-of-done check

Runs are interleaved (current, baseline, current, ...) after one untimed
warm-up per command, so both builds see the same machine state; the report
gives the median and interquartile range of wall time.

Then it measures the per-call cost of calling each example's port from the
original language (`bridge`), next to calling the original function, using
bench/bridge_call.{mjs,py}: the same harness for every backend, excluding
runtime startup.

Results go to stdout as a table and to --out as JSON together with the
machine, OS and tool versions. Nothing is estimated: every number printed is
a measurement from this run.
"""
import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = "zig-anything.exe" if os.name == "nt" else "zig-anything"
EXAMPLES = [
    # (example dir, unit, language)
    ("fuzzy-js", "fuzzyScore", "js"),
    ("levenshtein-py", "levenshtein", "py"),
]
SKIP = {".za", ".zig-cache", "zig-out", "zig-out-fast", "bridge", "node_modules", "__pycache__"}


def sh(cmd, cwd=None, env=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        sys.exit(f"command failed ({r.returncode}): {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r


def build(src_dir, prefix):
    sh(["zig", "build", "-Doptimize=fast", "--prefix", prefix], cwd=src_dir)
    return os.path.join(prefix, "bin", EXE)


def copy_example(name, dst):
    def ignore(_, names):
        return [n for n in names if n in SKIP]
    shutil.copytree(os.path.join(ROOT, "examples", name), dst, ignore=ignore)


def timed(cmd, cwd):
    t0 = time.perf_counter_ns()
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ms = (time.perf_counter_ns() - t0) / 1e6
    if r.returncode != 0:
        sys.exit(f"benchmarked command failed ({r.returncode}): {' '.join(cmd)} in {cwd}")
    return ms


def stats(samples):
    s = sorted(samples)
    q = statistics.quantiles(s, n=4) if len(s) >= 2 else [s[0], s[0], s[0]]
    return {"median_ms": statistics.median(s), "p25_ms": q[0], "p75_ms": q[2], "runs": len(s)}


def versions():
    def first_line(cmd):
        try:
            return sh(cmd, check=False).stdout.strip().splitlines()[0]
        except (OSError, IndexError):
            return None
    rev = sh(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, check=False).stdout.strip()
    dirty = bool(sh(["git", "status", "--porcelain"], cwd=ROOT, check=False).stdout.strip())
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor() or None,
        "cpus": os.cpu_count(),
        "zig": first_line(["zig", "version"]),
        "node": first_line(["node", "--version"]),
        "python": platform.python_version(),
        "git": rev + ("+uncommitted" if dirty else ""),
    }


def bridge_costs(exe, work, label):
    """Per-call cost of the original and of each bridge backend."""
    out = []
    node = shutil.which("node") or "node"
    for example, unit, lang in EXAMPLES:
        d = os.path.join(work, example)
        sh([exe, "--no-color", "bridge", unit], cwd=d)
        unit_dir = os.path.join(d, "zig-port", unit)
        manifest = json.load(open(os.path.join(unit_dir, "unit.json"), encoding="utf-8"))
        source = os.path.normpath(os.path.join(unit_dir, manifest["source"]))
        cases = os.path.join(unit_dir, "cases.jsonl")
        if lang == "js":
            script = [node, os.path.join(ROOT, "bench", "bridge_call.mjs")]
            binding = os.path.join(unit_dir, "bridge", "index.mjs")
            variants = [("original", source, {}), ("bridge", binding, {}), ("bridge", binding, {"ZIG_ANYTHING_BRIDGE": "wasm"})]
        else:
            script = [sys.executable, os.path.join(ROOT, "bench", "bridge_call.py")]
            binding = os.path.join(unit_dir, "bridge", "port.py")
            variants = [("original", source, {}), ("bridge", binding, {})]
        for kind, target, extra in variants:
            if extra and out and out[-1]["what"] == "bridge (wasm)":
                continue  # a build without the native addon already used WebAssembly
            env = dict(os.environ, **extra)
            samples = []
            backend = None
            for _ in range(3):
                r = sh(script + [target, cases, unit, "300"], env=env)
                res = json.loads(r.stdout.strip().splitlines()[-1])
                samples.append(res["ns_per_call"])
                backend = res.get("backend")
            out.append({
                "build": label,
                "unit": unit,
                "what": "original" if kind == "original" else f"bridge ({backend})",
                "ns_per_call": statistics.median(samples),
                "samples": samples,
            })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", help="git ref to compare against, e.g. v0.1.1")
    ap.add_argument("--runs", type=int, default=9)
    ap.add_argument("--out", default=None, help="write results as JSON here")
    ap.add_argument("--no-bridge", action="store_true", help="skip the per-call bridge measurements")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="za-bench-")
    builds = []
    try:
        print("building the current tree...", flush=True)
        builds.append(("current", build(ROOT, os.path.join(tmp, "current"))))
        if args.baseline:
            print(f"building {args.baseline}...", flush=True)
            wt = os.path.join(tmp, "baseline-src")
            sh(["git", "worktree", "add", "--detach", wt, args.baseline], cwd=ROOT)
            try:
                builds.append((args.baseline, build(wt, os.path.join(tmp, "baseline"))))
            finally:
                sh(["git", "worktree", "remove", "--force", wt], cwd=ROOT, check=False)

        # A fresh copy of every example per build, recorded once (untimed).
        work = {}
        for label, exe in builds:
            work[label] = os.path.join(tmp, "work-" + label.replace("/", "_"))
            for example, unit, _ in EXAMPLES:
                d = os.path.join(work[label], example)
                copy_example(example, d)
                sh([exe, "--no-color", "record", unit], cwd=d)

        scenarios = [(cmd, example, unit) for example, unit, _ in EXAMPLES for cmd in ("record", "diff", "gate")]
        samples = {(label, cmd, unit): [] for label, _ in builds for cmd, _, unit in scenarios}
        for label, exe in builds:  # warm-up: brings every unit to "nothing changed"
            for cmd, example, unit in scenarios:
                timed([exe, "--no-color", cmd, unit], os.path.join(work[label], example))
        for i in range(args.runs):
            print(f"run {i + 1}/{args.runs}", flush=True)
            for cmd, example, unit in scenarios:
                for label, exe in builds:
                    samples[(label, cmd, unit)].append(timed([exe, "--no-color", cmd, unit], os.path.join(work[label], example)))

        rows = []
        for (label, cmd, unit), s in samples.items():
            rows.append({"build": label, "command": f"{cmd} {unit}", **stats(s)})

        bridge = []
        if not args.no_bridge:
            print("measuring bridge per-call cost...", flush=True)
            for label, exe in builds:
                bridge += bridge_costs(exe, work[label], label)

        print()
        print(f"{'command (nothing changed)':<26} " + " ".join(f"{label:>22}" for label, _ in builds))
        for cmd, example, unit in scenarios:
            cells = []
            for label, _ in builds:
                r = next(x for x in rows if x["build"] == label and x["command"] == f"{cmd} {unit}")
                cells.append(f"{r['median_ms']:8.1f} ms [{r['p25_ms']:.0f}-{r['p75_ms']:.0f}]")
            print(f"{cmd + ' ' + unit:<26} " + " ".join(f"{c:>22}" for c in cells))
        if bridge:
            print()
            print(f"{'per call':<36} {'build':<10} {'ns/call':>12}")
            for b in bridge:
                print(f"{b['unit'] + ': ' + b['what']:<36} {b['build']:<10} {b['ns_per_call']:>12.1f}")
        print("\nmedian [interquartile range] of wall time; per-call figures are medians of 3 timed passes")

        result = {"environment": versions(), "runs": args.runs, "commands": rows, "bridge": bridge}
        if args.out:
            with open(args.out, "w", encoding="utf-8", newline="\n") as f:
                json.dump(result, f, indent=2)
                f.write("\n")
            print(f"wrote {args.out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()

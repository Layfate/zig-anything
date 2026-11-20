# ZigAnything profiler helper for Python.
# (Written to disk as za_profiler.py: a file named profile.py would shadow the stdlib module cProfile imports.)
# usage: python za_profiler.py <out.json> <script> [args...]
# Runs the script under cProfile and writes per-function timings as JSON.
import cProfile
import json
import os
import pstats
import runpy
import sys


def main():
    out_path, script = sys.argv[1], sys.argv[2]
    sys.argv = [script] + sys.argv[3:]
    sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
    prof = cProfile.Profile()
    code = 0
    try:
        prof.runcall(runpy.run_path, script, run_name="__main__")
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    stats = pstats.Stats(prof)
    rows = []
    for (filename, line, func), (_cc, ncalls, tottime, cumtime, _callers) in stats.stats.items():
        rows.append({"file": filename, "line": line, "function": func, "calls": ncalls,
                     "self_s": tottime, "total_s": cumtime})
    total = max((r["total_s"] for r in rows), default=0.0)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"total_s": total, "functions": rows}, fh)
    sys.exit(code)


main()

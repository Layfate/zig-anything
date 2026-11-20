"""Measure process startup: run a command N times and report wall-clock stats.

usage: python bench/startup.py [--runs N] -- <command> [args...]
"""
import argparse
import os
import statistics
import subprocess
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=50)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    ns = ap.parse_args()
    cmd = ns.cmd[1:] if ns.cmd and ns.cmd[0] == "--" else ns.cmd
    if not cmd:
        ap.error("missing command")
    if os.path.exists(cmd[0]):
        cmd[0] = os.path.abspath(cmd[0])
    for _ in range(3):  # warm the file cache
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    samples = []
    for _ in range(ns.runs):
        t0 = time.perf_counter_ns()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        samples.append((time.perf_counter_ns() - t0) / 1e6)
    samples.sort()
    print(
        "%-40s median %.2f ms  mean %.2f ms  min %.2f ms  p90 %.2f ms  (n=%d)"
        % (" ".join(cmd)[-40:], statistics.median(samples), statistics.mean(samples),
           samples[0], samples[int(len(samples) * 0.9) - 1], len(samples))
    )


if __name__ == "__main__":
    sys.exit(main())

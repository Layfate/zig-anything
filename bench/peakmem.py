"""Measure wall time and peak memory (resident set / working set) of a command.

usage: python bench/peakmem.py [--runs N] [--cwd DIR] -- <command> [args...]

Reports the median over N runs. Works on Linux, macOS (wait4 rusage) and
Windows (GetProcessMemoryInfo on the exited process handle).
"""
import argparse
import os
import statistics
import subprocess
import sys
import time


def peak_windows(proc):
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    c = Counters()
    c.cb = ctypes.sizeof(c)
    psapi = ctypes.WinDLL("psapi")
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    if not psapi.GetProcessMemoryInfo(int(proc._handle), ctypes.byref(c), c.cb):
        raise OSError("GetProcessMemoryInfo failed")
    return c.PeakWorkingSetSize


def run_once(cmd, cwd):
    t0 = time.perf_counter_ns()
    if os.name == "nt":
        proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        proc.wait()
        ms = (time.perf_counter_ns() - t0) / 1e6
        return ms, peak_windows(proc)
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, _, usage = os.wait4(proc.pid, 0)
    ms = (time.perf_counter_ns() - t0) / 1e6
    proc.returncode = 0
    # ru_maxrss is bytes on macOS, kilobytes on Linux.
    rss = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
    return ms, rss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--cwd", default=None)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    ns = ap.parse_args()
    cmd = ns.cmd[1:] if ns.cmd and ns.cmd[0] == "--" else ns.cmd
    if not cmd:
        ap.error("missing command")
    if os.path.exists(cmd[0]):
        cmd[0] = os.path.abspath(cmd[0])
    run_once(cmd, ns.cwd)  # warm the file cache
    times, peaks = [], []
    for _ in range(ns.runs):
        ms, peak = run_once(cmd, ns.cwd)
        times.append(ms)
        peaks.append(peak)
    print("wall median %.1f ms   peak memory median %.1f MB   (n=%d)" % (
        statistics.median(times), statistics.median(peaks) / (1024 * 1024), ns.runs))


if __name__ == "__main__":
    sys.exit(main())

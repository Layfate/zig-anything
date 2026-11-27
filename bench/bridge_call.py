"""Per-call cost of a generated Python bridge, used by bench/e2e.py.

    python bench/bridge_call.py <bridge/port.py> <cases.jsonl> <function> [target_ms]

Calls the bridged function on every recorded case that returned a value
(cases that threw are excluded, as in `zig-anything bench`), first once
untimed, then in timed passes until target_ms has elapsed. Prints JSON:
{"backend": "ctypes", "ns_per_call": ..., "calls": ...}.
"""
import importlib.util
import json
import math
import sys
import time

_NUM = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}


def decode(v):
    if isinstance(v, list):
        return [decode(x) for x in v]
    if isinstance(v, dict):
        if len(v) == 1 and "$num" in v:
            return _NUM[v["$num"]]
        return {k: decode(x) for k, x in v.items()}
    return v


def main():
    binding, cases_path, name = sys.argv[1:4]
    target_ms = float(sys.argv[4]) if len(sys.argv) > 4 else 300.0
    spec = importlib.util.spec_from_file_location("bridge_under_test", binding)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fn = getattr(mod, name)
    calls = []
    with open(cases_path, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            c = json.loads(line)
            if c.get("flaky") or "ok" not in c.get("expect", {}):
                continue
            calls.append(decode(c["args"]))
    if not calls:
        raise SystemExit("no cases that return a value")
    for args in calls:
        fn(*args)
    n = 0
    t0 = time.perf_counter_ns()
    elapsed = 0
    while elapsed < target_ms * 1e6:
        for args in calls:
            fn(*args)
        n += len(calls)
        elapsed = time.perf_counter_ns() - t0
    print(json.dumps({"backend": "ctypes", "ns_per_call": elapsed / n, "calls": n}))


if __name__ == "__main__":
    main()

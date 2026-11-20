# ZigAnything recorder for Python sources.
# usage: python record.py <run|bench> <source> <function> <cases.jsonl> <out> [iterations]
import dataclasses
import importlib.util
import json
import math
import os
import sys
import time


def fail(msg):
    sys.stderr.write("zig-anything recorder: %s\n" % msg)
    sys.exit(3)


_NUM = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}


def decode(v):
    if isinstance(v, list):
        return [decode(x) for x in v]
    if isinstance(v, dict):
        if len(v) == 1 and "$num" in v:
            return _NUM[v["$num"]]
        return {k: decode(x) for k, x in v.items()}
    return v


def encode(v, depth=0):
    if depth > 200:
        return {"$opaque": "depth"}
    if v is None or isinstance(v, (bool, str)):
        return v
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        if math.isnan(v):
            return {"$num": "NaN"}
        if math.isinf(v):
            return {"$num": "Infinity" if v > 0 else "-Infinity"}
        return v
    if isinstance(v, (list, tuple)):
        return [encode(x, depth + 1) for x in v]
    if isinstance(v, (set, frozenset)):
        items = [encode(x, depth + 1) for x in v]
        try:
            return sorted(items)
        except TypeError:
            return sorted(items, key=lambda x: json.dumps(x, sort_keys=True))
    if isinstance(v, dict):
        return {str(k): encode(x, depth + 1) for k, x in v.items()}
    if isinstance(v, (bytes, bytearray)):
        return list(v)
    if dataclasses.is_dataclass(v) and not isinstance(v, type):
        return encode(dataclasses.asdict(v), depth + 1)
    if hasattr(v, "__next__") or (hasattr(v, "__iter__") and not hasattr(v, "__dict__")):
        try:
            return [encode(x, depth + 1) for x in v]
        except Exception:
            pass
    if hasattr(v, "__dict__"):
        return encode(vars(v), depth + 1)
    return {"$opaque": type(v).__name__}


def load(src, fn_name):
    sys.path.insert(0, os.path.dirname(os.path.abspath(src)))
    spec = importlib.util.spec_from_file_location("zig_anything_target", src)
    if spec is None or spec.loader is None:
        fail("cannot load %s" % src)
    mod = importlib.util.module_from_spec(spec)
    real_stdout = sys.stdout
    sys.stdout = sys.stderr
    try:
        spec.loader.exec_module(mod)
    except BaseException as e:  # noqa: BLE001 - report any import failure
        fail("cannot load %s: %s: %s" % (src, type(e).__name__, e))
    finally:
        sys.stdout = real_stdout
    f = getattr(mod, fn_name, None)
    if not callable(f):
        fail("'%s' is not a function in %s" % (fn_name, src))
    return f


def main():
    if len(sys.argv) < 6:
        fail("usage: record.py <run|bench> <source> <function> <cases> <out> [iterations]")
    mode, src, fn_name, cases_path, out_path = sys.argv[1:6]
    iters = int(sys.argv[6]) if len(sys.argv) > 6 else 1
    sys.setrecursionlimit(10000)
    f = load(src, fn_name)
    with open(cases_path, encoding="utf-8") as fh:
        cases = [decode(json.loads(line)["args"]) for line in fh if line.strip()]

    # The user's code may print; keep that away from our results.
    sys.stdout = sys.stderr
    if mode == "run":
        out = []
        for args in cases:
            try:
                rec = {"ok": encode(f(*args))}
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as e:  # noqa: BLE001 - exceptions are recorded behavior
                rec = {"err": type(e).__name__, "msg": str(e)[:200]}
            out.append(json.dumps(rec, ensure_ascii=False, allow_nan=False))
        with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("".join(line + "\n" for line in out))
    elif mode == "bench":
        sink = 0

        def once():
            nonlocal sink
            for args in cases:
                try:
                    if f(*args) is not None:
                        sink += 1
                except Exception:  # noqa: BLE001
                    sink -= 1

        once()  # untimed warm-up pass
        t0 = time.perf_counter_ns()
        for _ in range(iters):
            once()
        ns = time.perf_counter_ns() - t0
        with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps({"cases": len(cases), "iterations": iters, "ns": ns, "sink": sink}) + "\n")
    else:
        fail("unknown mode '%s'" % mode)


main()

# ZigAnything recorder for Python sources.
# usage: python record.py <run|bench|cover> <source> <function> <cases.jsonl> <out> [iterations]
#
# Environment switches (all optional):
#   ZA_EFFECTS=1       also record argument mutation ("mut") and printed output ("out")
#   ZA_SANDBOX=1       block file writes outside ZA_WRITABLE, subprocesses and
#                      network access while user code runs (an audit hook: a
#                      guard against accidents, not a security boundary)
#   ZA_COVER_ROOT=dir  `cover` mode: only count coverage in files under dir
import dataclasses
import importlib.util
import io
import json
import math
import os
import sys
import time

EFFECTS = os.environ.get("ZA_EFFECTS") == "1"
SANDBOX = os.environ.get("ZA_SANDBOX") == "1"


def fail(msg):
    sys.stderr.write("zig-anything recorder: %s\n" % msg)
    sys.exit(3)


# ------------------------------------------------------------------ sandbox


class SandboxBlocked(PermissionError):
    pass


_guard = {"on": False, "blocked": 0}
_WRITABLE = os.path.normcase(os.path.abspath(os.environ.get("ZA_WRITABLE") or os.devnull))
_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC
_DENY = {
    "subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork",
    "os.forkpty", "os.startfile", "pty.spawn", "socket.connect", "socket.bind", "socket.sendto",
    "socket.sendmsg", "socket.getaddrinfo", "os.remove", "os.rename", "os.rmdir", "os.mkdir",
    "os.truncate", "os.chmod", "os.chown", "os.link", "os.symlink", "os.utime", "shutil.rmtree",
    "shutil.copyfile", "shutil.move", "os.removexattr", "os.setxattr", "ctypes.dlopen",
}


def _writable(path):
    try:
        p = os.path.normcase(os.path.abspath(os.fsdecode(path)))
    except (TypeError, ValueError):
        return False
    return p == _WRITABLE or p.startswith(_WRITABLE + os.sep)


def _audit(event, args):
    if not _guard["on"]:
        return
    denied = False
    if event == "open":
        path, mode, flags = (tuple(args) + (None, None, 0))[:3]
        writes = (isinstance(mode, str) and any(ch in mode for ch in "wax+")) or (isinstance(flags, int) and flags & _WRITE_FLAGS)
        denied = bool(writes) and not (path is None or isinstance(path, int) or _writable(path))
    elif event in _DENY:
        denied = True
    if denied:
        _guard["blocked"] += 1
        raise SandboxBlocked("zig-anything sandbox blocked %s" % event)


if SANDBOX:
    sys.addaudithook(_audit)


# ------------------------------------------------------------------ values

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
    _guard["on"] = SANDBOX
    try:
        spec.loader.exec_module(mod)
    except BaseException as e:  # noqa: BLE001 - report any import failure
        _guard["on"] = False
        fail("cannot load %s: %s: %s" % (src, type(e).__name__, e))
    finally:
        _guard["on"] = False
        sys.stdout = real_stdout
    f = getattr(mod, fn_name, None)
    if not callable(f):
        fail("'%s' is not a function in %s" % (fn_name, src))
    return f


def call_once(f, args, raw):
    """One recorded call: {"ok": v} or {"err": name, "msg": text}, plus
    "mut", "out" and "blocked" when they apply."""
    buf = io.StringIO() if EFFECTS else None
    if buf is not None:
        sys.stdout = buf
    blocked_before = _guard["blocked"]
    _guard["on"] = SANDBOX
    try:
        rec = {"ok": encode(f(*args))}
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as e:  # noqa: BLE001 - exceptions are recorded behavior
        rec = {"err": type(e).__name__, "msg": str(e)[:200]}
    finally:
        _guard["on"] = False
        sys.stdout = sys.stderr
    if EFFECTS:
        after = encode(args)
        if after != raw:
            rec["mut"] = after
        if buf.getvalue():
            rec["out"] = buf.getvalue()
    if _guard["blocked"] != blocked_before:
        rec["blocked"] = True
    return rec


# ------------------------------------------------------------------ coverage


def _bucket(n):
    return n if n < 4 else 4 if n < 8 else 5 if n < 16 else 6 if n < 32 else 7 if n < 128 else 8


def coverage_tracer(root):
    """Line-transition coverage for files under `root`: each (file, previous
    line, line, hit-count bucket) is one feature."""
    root = os.path.normcase(os.path.abspath(root))
    counts = {}
    mine = {}

    def local(frame, event, arg):
        if event == "line":
            prev = last.get(id(frame), 0)
            key = (frame.f_code.co_filename, prev, frame.f_lineno)
            last[id(frame)] = frame.f_lineno
            counts[key] = counts.get(key, 0) + 1
        elif event == "return":
            last.pop(id(frame), None)
        return local

    last = {}

    def glob(frame, event, arg):
        if event != "call":
            return None
        fn = frame.f_code.co_filename
        ok = mine.get(fn)
        if ok is None:
            p = os.path.normcase(os.path.abspath(fn))
            ok = mine[fn] = (p.startswith(root + os.sep) and os.sep + "site-packages" + os.sep not in p and os.sep + ".za" + os.sep not in p)
        return local if ok else None

    def take():
        feats = sorted({hash((k, _bucket(n))) & 0xFFFFFFFF for k, n in counts.items()})
        counts.clear()
        last.clear()
        return feats

    return glob, take


# ------------------------------------------------------------------ main


def main():
    if len(sys.argv) < 6:
        fail("usage: record.py <run|bench|cover> <source> <function> <cases> <out> [iterations]")
    mode, src, fn_name, cases_path, out_path = sys.argv[1:6]
    iters = int(sys.argv[6]) if len(sys.argv) > 6 else 1
    sys.setrecursionlimit(10000)
    f = load(src, fn_name)
    with open(cases_path, encoding="utf-8") as fh:
        raws = [json.loads(line)["args"] for line in fh if line.strip()]
    cases = [decode(r) for r in raws]

    # The user's code may print; keep that away from our results.
    sys.stdout = sys.stderr
    if mode in ("run", "cover"):
        if mode == "run":
            try:
                with open(os.path.join(os.path.dirname(out_path), "runtime.txt"), "w", encoding="utf-8") as fh:
                    fh.write("python %d.%d.%d\n" % sys.version_info[:3])
            except OSError:
                pass
        tracer = coverage_tracer(os.environ.get("ZA_COVER_ROOT") or os.path.dirname(os.path.abspath(src))) if mode == "cover" else None
        out = []
        for args, raw in zip(cases, raws):
            if tracer:
                sys.settrace(tracer[0])
            rec = call_once(f, args, raw)
            if tracer:
                sys.settrace(None)
                rec["cov"] = tracer[1]()
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

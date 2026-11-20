<p align="center">
  <img src="docs/assets/logo.png" alt="ZigAnything logo" width="160">
</p>

<h1 align="center">ZigAnything</h1>

<p align="center">
  <strong>Port JavaScript, TypeScript and Python code to Zig one function at a time, and prove every port behaves exactly like the original.</strong>
</p>

<p align="center">
  <a href="https://github.com/Layfate/zig-anything/actions/workflows/ci.yml"><img src="https://github.com/Layfate/zig-anything/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/zig-0.17.1-f7a41d" alt="Zig 0.17.1">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT">
</p>

ZigAnything records what a function in your existing code actually does (on generated edge cases, semantic traps and inputs you supply), scaffolds a Zig port of it, and replays every recorded case against the port until they all match. A single command, `gate`, decides when a port is done.

```text
$ zig-anything diff fuzzyScore
case 22: different value
  args      ["🎉","emoji 🎉 ok"]
  expected  {"ok":0.75}
  got       {"ok":0.7}
285/288 cases match  [zig-port/fuzzyScore]
```

*That mismatch is real: the first Zig port counted bytes, but JavaScript counts UTF-16 code units. The recording caught it.*

- **One static binary**, about 0.4–0.8 MB, with no runtime dependencies. Written in Zig with only the standard library.
- **Language-agnostic replay.** The original runs in its own runtime (Node or Python) through a small embedded recorder. The port runs as a native Zig harness. Results meet as JSON lines.
- **Semantic comparison.** `1`, `1.0` and `1e0` are equal, object key order is ignored, and NaN/±Infinity survive the round trip. Thrown errors match returned Zig errors.
- **Measured, not claimed.** `bench` times both sides on the same recorded inputs and reports a verdict, including when the port is *slower*.
- **Agent-ready.** `zig-anything mcp` exposes every command as a Model Context Protocol tool.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [How it works](#how-it-works)
- [Writing a port](#writing-a-port)
- [Benchmarks](#benchmarks)
- [Configuration](#configuration)
- [MCP server](#mcp-server)
- [Scope and limitations](#scope-and-limitations)
- [Building from source](#building-from-source)
- [Contributing](#contributing) · [Changelog](CHANGELOG.md) · [License](#license)

## Install

**Prebuilt binaries.** Download the archive for your platform from the [releases page](https://github.com/Layfate/zig-anything/releases). Builds exist for Linux (x86_64, aarch64; static musl), macOS (x86_64, Apple Silicon) and Windows (x86_64, aarch64). Put `zig-anything` on your `PATH`.

**From source** (needs [Zig 0.17.1](https://ziglang.org/download/)):

```sh
git clone https://github.com/Layfate/zig-anything
cd zig-anything
zig build -Doptimize=fast
# binary: zig-out/bin/zig-anything
```

**Runtime requirements.** These are needed only for the commands that use them:

| Needed for | Tool |
| --- | --- |
| building and diffing ports | `zig` 0.17.1 on `PATH` (or `ZIG=/path/to/zig`) |
| recording JavaScript | Node.js 22.6+ |
| recording TypeScript | Node.js 23.6+ (native type stripping), or a loader configured in [`node`](#configuration) |
| recording Python | Python 3.8+ |

## Quick start

This walks through the [`examples/fuzzy-js`](examples/fuzzy-js) project.

```sh
cd examples/fuzzy-js

# 1. Find candidates: top-level functions with inferred parameter types.
zig-anything scan src
#   src/fuzzy.mjs  (javascript)
#         7  fuzzyScore(query: string, text: string)

# 2. Scaffold a port unit: manifest, Zig stub, harness and build files.
zig-anything init src/fuzzy.mjs fuzzyScore

# 3. Record the original's behavior on edge cases plus your own inputs.
zig-anything record fuzzyScore
#   recorded 288 cases -> zig-port/fuzzyScore/cases.jsonl
#     returned  288  (number 288)

# 4. Write zig-port/fuzzyScore/src/port.zig, then compare. Repeat until green.
zig-anything diff fuzzyScore
#   288/288 cases match

# 5. Done means this passes (exit code 0).
zig-anything gate fuzzyScore
#   [ok]   manifest       fuzzyScore
#   [ok]   port written   no TODO marker
#   [ok]   cases recorded 288 deterministic case(s)
#   [ok]   builds         -Doptimize=safe
#   [ok]   port tests     zig build test
#   [ok]   behavior       288/288 cases match
#   PASSED: fuzzyScore is a faithful port

# 6. Is it faster?
zig-anything bench fuzzyScore
```

`zig-anything status` lists every unit in the project with its state (`stub`, `unrecorded`, `untested`, `failing`, `stale` or `passing`), its last diff and its speedup.

> **Safety:** `record` and `bench` **run your original code**, once or more per case. If it writes files, talks to a database or calls the network, it will do so. Record pure functions, or run on a copy with test credentials.

## Commands

| Command | What it does |
| --- | --- |
| `scan [path]` | List top-level functions in a file or project, with inferred parameter and return types. `--all` includes non-exported functions; `--json` gives machine-readable output. |
| `init <file> <function>` | Create a port unit (default `zig-port/<function>/`). `--out DIR` chooses the directory. `--force` regenerates the manifest and harness; your `port.zig` and `build.zig` are never overwritten. |
| `record <unit>` | Run the original on generated cases plus `inputs.jsonl`, twice, and write `cases.jsonl`. Cases whose results differ between the two runs are marked flaky and skipped by `diff`. Flags: `--samples N`, `--seed N`, `--max-cases N`, `--no-verify`, `--no-generate`. |
| `build <unit>` | Compile the port and harness. `--optimize debug\|safe\|fast\|small` (default `safe`). |
| `diff <unit>` | Build, replay every case, and report mismatches with arguments, expected and actual results. Detects crashes and points at the crashing case. Flags: `--tolerance X`, `--strict-errors`, `--limit N`, `--no-build`, `--json`. |
| `bench <unit>` | Time the original against the port (built with `-Doptimize=fast`) on the recorded inputs and give a verdict. Flags: `--runs N`, `--target-ms MS`, `--json`. |
| `gate <unit>` | Every check must pass: port written, cases recorded, builds, `zig build test` passes, every case matches. `--bench` also requires the port to be at least as fast. |
| `status [dir]` | Overview of all units. `--json` is available. |
| `mcp` | Serve the commands as MCP tools over stdio. `--print-config` prints a registration snippet. |

A `<unit>` is a unit directory (`zig-port/slugify`) or just its name (`slugify`), which is looked up in the configured units directory.

**Exit codes:** `0` success · `1` a check failed (mismatches, compile errors, gate) · `2` usage error · `3` runtime or environment error (missing tool, unreadable file).

Every command has `--help`. Typos in commands and flags get suggestions.

## How it works

```text
             ┌──────────── record ────────────┐            ┌──────────── diff ─────────────┐
 inputs.jsonl ─┐                               │            │                               │
 generated   ──┼─► args ─► node/python recorder ─► cases.jsonl ─► zig harness ─► port.zig     │
 edge cases  ──┘          (embedded script)    │   (args +  │   (generic,      (your code)  │
                                               │   expected)│    comptime)                  │
             └─────────────────────────────────┘            └──► semantic compare ─► report ┘
```

A **port unit** is a directory:

```text
zig-port/fuzzyScore/
├── unit.json        what is being ported and from where (source path, params, types)
├── cases.jsonl      recorded behavior; commit it, it is the spec
├── inputs.jsonl     optional hand-written inputs, one argument array per line
├── build.zig        generated once; extend freely
└── src/
    ├── port.zig     the port: yours to write
    ├── harness.zig  generated: feeds cases to the port
    └── rt.zig       generated: JSON ⇄ Zig conversion
```

**Input generation.** Each parameter type has a pool of edge values and semantic traps:

- numbers: `0`, `-1`, `0.5`, `1e-9`, `2^31-1`, `2^53`, `0.1`, `NaN`, `±Infinity`
- strings: empty, whitespace, `"null"`, `"0"`, newlines, tabs, accents, CJK, emoji, a 300-character string, quotes and backslashes
- arrays: empty, singleton, unsorted, duplicates

Every parameter is driven through its whole pool while the others hold typical values. Then seeded random combinations are added. Recordings are reproducible: the same seed gives the same `cases.jsonl` byte for byte, and an unchanged recording is not rewritten.

**Type inference.** Parameter types come from TypeScript annotations, Python annotations and default values. When those are missing, they come from how the body uses the parameter: `x.toLowerCase()` means a string, `x * 2` or `Math.min(x, …)` a number, `range(n)` or `n // 2` an int. Parameter names are the last resort (`isEnabled` → bool, `count` → int). Inference only shapes the generated inputs and the stub signature, and you can override both.

**Comparison rules** (`diff`):

| Situation | Result |
| --- | --- |
| both returned values | match if semantically equal: numbers by value (`--tolerance` for floats), objects ignoring key order, arrays element by element |
| original threw, port returned an error | match (`--strict-errors` also requires equal names, e.g. `error.RangeError` for a `RangeError`) |
| one threw, the other did not | mismatch |
| port crashed | mismatch on that case; the remaining cases are reported as not run |
| result flaky across the two recording runs | skipped and reported |

**Value encoding.** Results travel as JSON. Non-finite floats are written as `{"$num":"NaN"}`, `{"$num":"Infinity"}` or `{"$num":"-Infinity"}`. `undefined` becomes `null`. `Map` and `Set` become objects and arrays, `Date` an ISO string, and Python tuples become arrays. Values JSON cannot carry (functions, symbols, BigInt) are flagged by `record`.

More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Writing a port

The stub `init` writes looks like this:

```zig
// TODO(zig-anything): port this function, then delete this line.
pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    ...
}
```

- **Any signature works.** The harness reads your function's parameter types at compile time and decodes each recorded argument into them. Supported types: `bool`, integers, floats, `[]const u8`, slices of any supported type, optionals, structs (from JSON objects), enums (from strings) and `std.json.Value`.
- **Allocation is free.** A `std.mem.Allocator` parameter receives a per-call arena that is reset after every call. Remove the parameter if you don't need it.
- **Throws become errors.** Return an error wherever the original throws or raises.
- **Return anything encodable**: the same types as parameters, plus tuples and fixed arrays.
- **Delete the TODO marker.** `gate` refuses a port that still carries it.
- **`port.zig` is plain Zig.** The unit's `build.zig` exposes it as the module `port`, so a Zig program can depend on it directly once the migration is complete.

Inferred types map like this: `number` → `f64`, `int` → `i64`, `string` → `[]const u8`, `bool` → `bool`, `number_array` → `[]const f64`, `int_array` → `[]const i64`, `string_array` → `[]const []const u8`, and anything else → `std.json.Value`.

## Benchmarks

All numbers below were measured on one machine: AMD Ryzen 7 5700X, 32 GB RAM, Windows 11, Zig 0.17.1, Node.js 24.21, Python 3.12.10. Each row is a median of 5 runs. Reproduce them with the commands shown; your numbers will differ.

**Example ports** (`zig-anything bench <unit>`):

| Unit | Original | Per call: original | Per call: Zig | Per call: speedup | One process, all cases: original | One process, all cases: Zig |
| --- | --- | --- | --- | --- | --- | --- |
| [`levenshtein`](examples/levenshtein-py) | Python 3.12 | 51.9 µs | 0.33 µs | **159x** | 162.8 ms | 17.9 ms |
| [`fuzzyScore`](examples/fuzzy-js) | Node.js 24 (V8 JIT) | 61.3 ns | 31.6 ns | **1.9x** | 54.2 ms | 17.7 ms |

"Per call" excludes runtime startup: both sides parse the inputs first, run one untimed warm-up pass, then run calibrated timed passes. "One process" is wall time for a fresh process that loads the code and runs every case once. Cases that throw are excluded from benchmarks, because exceptions cost much more in most runtimes than errors in Zig, and that would flatter the port.

A JIT is a strong baseline. The first `fuzzyScore` port matched every case but ran 2.6x *slower* than V8 (164 ns per call), because it converted both strings to UTF-16 buffers on every call. Profiling showed the conversion, not allocation, was the cost. JavaScript knows string lengths in O(1), while the port scanned whole strings to learn them. The final port streams UTF-16 units straight from the UTF-8 input, with an inline ASCII fast path, and drops the redundant length check. That brought it to 31.6 ns. The recorded cases stayed 288/288 green throughout, which is what made the rewrite safe. The story is in [examples/fuzzy-js](examples/fuzzy-js).

**The tool itself**:

| Measurement | Result | Reproduce |
| --- | --- | --- |
| binary size, size-optimized, x86_64 Linux / macOS / Windows | 462 KB / 438 KB / 768 KB | `zig build release` |
| startup, `zig-anything --version` (Windows, includes process creation) | 4.0 ms median | `python bench/startup.py -- zig-out/bin/zig-anything --version` |
| scan JavaScript | 137 MiB/s | `zig build microbench` |
| scan Python | 200 MiB/s | `zig build microbench` |
| parse and compare 100,000 recorded cases | 228 ms (70 MiB/s) | `zig build microbench` |
| generate 1,000 random cases for 3 parameters | 0.30 ms | `zig build microbench` |

## Configuration

Configuration is optional. ZigAnything looks for a `zig-anything.json` in the current directory or the unit's directory, then in each parent directory. Unknown fields are rejected, so typos surface immediately.

```json
{
  "units_dir": "zig-port",
  "node": ["node"],
  "python": ["python3"],
  "zig": "zig",
  "samples": 64,
  "seed": 1,
  "max_cases": 2000,
  "timeout": 300,
  "tolerance": 0
}
```

| Field | Meaning |
| --- | --- |
| `units_dir` | where `init` puts units, relative to the config file |
| `node`, `python` | command plus leading arguments used to run the original, e.g. `["node", "--import", "tsx"]` for TypeScript that needs a loader |
| `zig` | compiler used to build units |
| `samples`, `seed`, `max_cases` | case generation |
| `timeout` | seconds before any child process is stopped |
| `tolerance` | default float tolerance for `diff` |

Environment overrides: `ZIG_ANYTHING_NODE`, `ZIG_ANYTHING_PYTHON`, `ZIG`, `NO_COLOR`. Run `zig-anything help config` to see the defaults for your platform.

## MCP server

`zig-anything mcp` speaks the Model Context Protocol over stdio. It exposes eight tools: `zig_anything_scan`, `_init`, `_record`, `_build`, `_diff`, `_bench`, `_gate` and `_status`. With them, a coding agent can drive the whole loop: scan, init, record, write the port, diff until green, gate.

```sh
zig-anything mcp --print-config
```

That prints a snippet like this for your MCP client's configuration:

```json
{
  "mcpServers": {
    "zig-anything": { "command": "/path/to/zig-anything", "args": ["mcp"] }
  }
}
```

## Scope and limitations

ZigAnything is honest about what it can and cannot check:

- **Languages:** JavaScript, TypeScript and Python sources. The scanners are lightweight tokenizers, not full parsers. They handle the declaration forms in common use (functions, arrow functions, `export` lists, CommonJS exports, TS overloads, Python annotations and multi-line signatures).
- **Units are functions.** Each unit is one top-level function with JSON-representable inputs and outputs. Classes, closures, generators, callbacks and functions that mutate shared state need a wrapper function to be ported this way.
- **Side effects are not recorded.** Only return values and thrown errors are compared. A port that prints, writes files or mutates its arguments differently is not caught.
- **Coverage is only as good as the inputs.** Generated cases find many edge cases, but meaningful inputs for domain logic belong in `inputs.jsonl` (see [examples/fuzzy-js](examples/fuzzy-js)). A passing gate means "equal on every recorded case", not "proven equal".
- **Nondeterminism:** results that depend on time, randomness or I/O are detected (flaky) and skipped, not compared.
- **TypeScript** runs through Node's native type stripping, which supports erasable syntax only (no `enum` or `namespace` declarations). Configure a loader such as `tsx` for anything else.
- **Per-call speed is not end-to-end speed.** If the original code would call the port across a process or FFI boundary for every call, that boundary can cost more than the function itself. `bench` warns when calls take under 200 ns.

## Building from source

```sh
zig build                       # debug build -> zig-out/bin/zig-anything
zig build -Doptimize=fast       # optimized for speed
zig build -Doptimize=small      # optimized for size
zig build -Doptimize=safe       # optimized, with safety checks kept
zig build test                  # unit tests
zig build e2e                   # end-to-end tests (needs node, python, zig)
zig build microbench            # micro benchmarks of the tool's hot paths
zig build release               # size-optimized binaries for all six targets
```

Source layout:

```text
src/
├── main.zig        command table, help, dispatch
├── cli.zig         context, styled output, errors, flag parsing
├── config.zig      zig-anything.json
├── scan.zig        JS/TS/Python function scanners and type inference
├── gen.zig         edge-case and random input generation
├── unit.zig        unit manifest, scaffolding, builds
├── cases.zig       cases.jsonl
├── runtime.zig     running the original through node/python
├── jsonx.zig       semantic JSON equality
├── proc.zig        child processes
├── mcp.zig         MCP server
├── cmd/            scan+init, record, build+diff, bench, gate+status
└── assets/         files embedded in the binary: recorders, runtime, unit build.zig
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, test expectations and the rule about benchmarks (verified numbers only).

## License

[MIT](LICENSE)

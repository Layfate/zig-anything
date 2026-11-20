# Architecture

zig-anything is a single Zig executable with no dependencies outside the standard library. This document explains how the pieces fit and why they were built this way.

## Design goals

1. **Prove behavior, don't translate code.** zig-anything never rewrites source. It captures what the original *does* and checks that the port does the same.
2. **Stay small and fast to start.** The CLI is run in tight edit, diff, edit loops. It is one static binary of under 1 MB that starts in a few milliseconds.
3. **Keep runtimes apart.** The original runs in its own runtime and the port runs natively. They exchange JSON lines through files, so neither side needs FFI bindings, and a crash on one side cannot corrupt the other.
4. **Be explicit about memory.** Each command owns a process-lifetime arena for its bookkeeping. Large buffers come from the general-purpose allocator and are freed explicitly. Ports get a per-call arena that is reset after every call.

## Data flow

```text
scan ──► init ──► record ──► (edit port.zig) ──► diff ──► gate
                    │                              │
                    ▼                              ▼
          .za/inputs.gen.jsonl            zig build (harness)
          node/python recorder            harness run cases.jsonl
                    │                              │
                    ▼                              ▼
              cases.jsonl  ────────────────►  semantic compare
```

### Recording

`record` builds the input list from two sources: `inputs.jsonl`, written by the user, and `gen.generate`, which makes edge pools plus seeded random samples. It writes the list to `.za/inputs.gen.jsonl` and runs the embedded recorder for the source language:

- `assets/record.mjs` (Node) imports the module. It tries ESM first, then falls back to `require` for CommonJS. It finds the export, calls it once per case (awaiting promises), and writes `{"ok": value}` or `{"err": name, "msg": message}` per line to an output file. Output goes to a file rather than stdout, so `console.log` in user code cannot corrupt results.
- `assets/record.py` loads the file with `importlib`, redirects `sys.stdout` to stderr while user code runs, and records return values or exception class names. `PYTHONHASHSEED=0` makes set and dict ordering stable.

The recorder runs twice. Cases whose outcomes differ between the runs are marked `"flaky": true`. Error messages may legitimately differ between runs, so only error names are compared for this check. `cases.jsonl` is rewritten only when its content changed.

### The harness

Each unit's `src/harness.zig` is three lines that call `rt.harnessMain(init, port.<function>)`. Everything else happens at compile time in `rt.zig`:

- `std.meta.ArgsTuple(@TypeOf(f))` gives the argument tuple type.
- `buildArgs` walks the parameter types. `std.mem.Allocator` parameters receive the per-call scratch arena. All others are decoded from the case's JSON arguments by `decode(T, …)`, a comptime-recursive converter for bools, ints, floats, slices, optionals, structs, enums and `std.json.Value`.
- `callAndWrite` calls the port, inspects whether the return type is an error union, and writes `{"ok": …}` or `{"err": "Name"}` through `encode`. `encode` mirrors the JSON number formatting of JavaScript and Python: integral floats print without a fraction.

The harness flushes after every case in `run` mode. If the port crashes, the output still holds every completed result, and `diff` names the first missing case as the crash site.

In `bench` mode the harness decodes all arguments up front, runs one untimed warm-up pass, then times `iterations` passes with `std.mem.doNotOptimizeAway` on every result. The recorders implement the same protocol, so both sides measure the same thing.

### Comparing

`jsonx.equal` defines semantic equality. Numbers compare by value (exactly for two integers, by f64 otherwise, with an optional absolute or relative tolerance). Non-finite tags compare as numbers. Objects compare as unordered maps, and arrays element by element. `cmd/diff.zig` classifies each case as a match or as one of: different value, unexpected error, missing error, different error name (only with `--strict-errors`), harness error, crash, or not run.

### Scanning and type inference

`scan.zig` contains two scanners:

- **JS/TS:** a tokenizer that understands strings, template literals (including nested `${}`), comments, and regex literals (decided by the previous token). A pass over top-level tokens then recognizes function declarations, `const f = (…) =>`, `const f = function`, `export { a as b }`, `export default`, `module.exports = {…}`, and `exports.f = …`. TypeScript overload signatures, which have no body, are skipped.
- **Python:** a line scanner that tracks bracket depth and triple-quoted strings, then finds column-0 `def` and `async def`, including multi-line signatures.

Types are resolved in priority order: annotation, then default value literal, then usage in the body, then parameter name. Usage scoring weights strong signals (`.toLowerCase()`, `range(n)`, `Math.max(x, …)`) above weak ones (indexing, `.length`).

### Building

`unit.build` shells out to `zig build -Doptimize=<mode> --prefix <dir>` inside the unit directory. `diff` and `gate` use `safe`, which keeps safety checks so that out-of-bounds access and integer overflow in a port become crashes instead of silent wrong answers. `bench` builds `fast` into a separate prefix (`zig-out-fast`), so it never invalidates the diff build.

### Bridge, program units and profiling

- `bridge` writes `src/bridge.zig`, which exports `za_alloc`, `za_free`, `za_call` and `za_call_batch` through `rt.Bridge`. JS/TS units compile it for `wasm32-freestanding`; Python units compile it as a shared library. The generated `index.mjs` / `port.py` marshal arguments as JSON. Every recorded case is then replayed through the binding with the normal recorder.
- Program units (`kind: "cli"` in `unit.json`) store a command and a working directory. Cases are invocations (`args` plus optional `stdin`); `cmd/program.zig` runs the original and the built `port` executable and compares stdout and exit code.
- `profile` runs `node --cpu-prof` and aggregates the `.cpuprofile` (inclusive time counts each sample once per function, so recursion is not double counted), or runs an embedded `cProfile` helper for Python. Results are cross-referenced with the scanner to mark portable functions.

## Error handling

Every user-facing failure goes through `Ctx.fail`, which prints `error: …` (with an optional `hint:` line) and returns `error.Reported`. `main` maps that to exit code 3. Checks that fail (mismatches, compile errors, gate) return exit code 1, and usage errors return 2. Missing tools produce install hints instead of `FileNotFound`.

## Testing

- `zig build test`: unit tests in every module (scanners, generator, comparison, flag parsing, config, manifest rendering, MCP argument mapping) and in the unit runtime `rt.zig`.
- `zig build e2e`: `tests/e2e.zig` drives the real binary through complete JavaScript, TypeScript and Python workflows. It also covers regressions (wrong port, crashing port, compile error), user inputs, error messages, JSON output, the MCP protocol, and the gate of every committed example.
- `zig build microbench`: throughput of the tool's hot paths.

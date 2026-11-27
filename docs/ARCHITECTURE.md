# Architecture

zig-anything is a single Zig executable with no dependencies outside the standard library. This document explains how the pieces fit and why they were built this way.

## Design goals

1. **Prove behavior, don't translate code.** zig-anything never translates source. It captures what the original *does* and checks that the port does the same. The one command that edits source, `integrate`, only rewires a name to a port that has already been proven, re-verifies through the edited file, and restores the file byte for byte if anything fails.
2. **Stay small and fast to start.** The CLI is run in tight edit, diff, edit loops. It is one static binary of about 1 MB that starts in a few milliseconds, and commands skip work whose inputs did not change.
3. **Keep runtimes apart while proving.** The original runs in its own runtime and the port runs natively. During `record` and `diff` they exchange JSON lines through files, so neither side needs FFI, and a crash on one side cannot corrupt the other. Only the bridge, which is for production use after proof, crosses the boundary in-process.
4. **Be explicit about memory.** Each command owns a process-lifetime arena for its bookkeeping. Large buffers come from the general-purpose allocator and are freed explicitly. Ports get a per-call arena that is reset after every call, and the bridges keep their arenas between calls.
5. **Correctness before speed.** Every optimization (build caching, parallel replay, the native bridge) is checked by the same recorded cases as the port itself.

## Data flow

```text
profile ─► plan ─► init ─► record ◄─ fuzz ─► (edit port.zig) ─► diff ─► gate ─► bridge ─► integrate
                             │                                  │                  │          │
                             ▼                                  ▼                  ▼          ▼
                 node/python recorder                 zig build (cached)    port.node /   source rewritten,
                 (sandbox, effects)                   harness, sharded      port.wasm /   cases replayed
                             │                                  │           port.dll      through it,
                             ▼                                  ▼                         rollback on failure
              cases.jsonl + recording.json  ────────►  semantic compare
```

## Language adapters

Everything that differs between source languages lives behind one table, `adapter.zig`. Each language has one file in `src/adapters/` that fills in an `Adapter`: the runtime command, the embedded recorder script, environment variables, the scanner, whether functions must be exported, which bridge it uses, how to turn on the sandbox, and whether all of its numbers are IEEE doubles. Commands ask the adapter and never branch on the language.

Adding a language means a `Language` tag in `lang.zig`, a file in `src/adapters/`, a recorder in `src/assets/` that speaks the protocol below, and one line in `adapter.forLanguage`.

## Recording

`record` builds the input list from three sources: `inputs.jsonl` (written by the user), `inputs.fuzz.jsonl` (written by `fuzz`), and `gen.generate`, which makes edge pools plus seeded random samples. It runs the embedded recorder for the source language:

```text
<runtime> <recorder> <mode> <source> <function> <cases> <out> <iterations>
```

`mode` is `run` (record or replay), `bench` (timed passes) or `cover` (coverage, for `fuzz`). Optional behavior is switched on with environment variables, so the positional protocol never changes:

| Variable | Effect |
| --- | --- |
| `ZA_EFFECTS=1` | also record the arguments after the call (`"mut"`) and what the function printed (`"out"`) |
| `ZA_SANDBOX=1`, `ZA_WRITABLE=<dir>` | block file writes outside `<dir>`, subprocesses and network access while user code runs |

- `assets/record.mjs` (Node) imports the module (ESM first, then `require` for CommonJS), calls the export once per case (awaiting promises), and writes `{"ok": value}` or `{"err": name, "msg": message}` per line to an output file, never to stdout. The sandbox is Node's permission model (`--permission`, reads allowed, writes only to the unit's scratch directory, no child processes, workers or addons) plus a recorder-level block on network modules.
- `assets/record.py` loads the file with `importlib`, redirects `sys.stdout` while user code runs, and records return values or exception class names. `PYTHONHASHSEED=0` makes set and dict ordering stable. The sandbox is a `sys.addaudithook` hook that raises on file writes, subprocesses and sockets.

Both sandboxes guard against accidents in code you trust. They are not a security boundary for hostile code.

The recorder runs twice, in parallel. Cases whose outcomes differ between the runs are marked `"flaky": true`, and only error names are compared for this check because messages may legitimately differ. Large recordings are split into shards of consecutive cases, one process each (`--jobs`, `"jobs"`). `cases.jsonl` is rewritten only when its content changed.

**Reproducibility.** `record` writes `recording.json` next to `cases.jsonl`: seed, sample count, case cap, effects, sandbox, the case count, the runtime, and the SHA-256 of the source file. `record --check` re-records with those options in memory and fails, writing nothing, if any case would change; it says whether the source, the inputs, the runtime or the generator changed. `diff --case 3,17` replays single cases.

## Fuzzing

`fuzz` runs the recorder in `cover` mode, which reports coverage per case: V8's precise block coverage through an inspector session in Node (each executed block and a bucket of its hit count is a feature), and a `sys.settrace` tracer in Python, both restricted to files under the source file's directory. Starting from every recorded input, `mutate.zig` makes structure-aware mutations of a seeded random sample each round: boundary numbers, character edits that keep UTF-8 valid, element insertion, removal and swaps, and values spliced in from elsewhere in the corpus. Every mutation keeps each argument's arity and JSON shape, so the original keeps accepting it. Inputs that reach a coverage feature no earlier input reached are kept in `inputs.fuzz.jsonl`, which the next `record` picks up. Fuzzing only finds inputs; whether they are correct is still decided by recording the original and comparing the port.

## The harness

Each unit's `src/harness.zig` is three lines that call `rt.harnessMain(init, port.<function>)`. Everything else happens at compile time in `rt.zig`:

- `std.meta.ArgsTuple(@TypeOf(f))` gives the argument tuple type.
- `buildArgs` walks the parameter types. `std.mem.Allocator` parameters receive the per-call scratch arena and `*std.Io.Writer` parameters receive what the port prints. All others are decoded from the case's JSON arguments by `decode(T, …)`, a comptime-recursive converter for bools, ints, floats, slices, optionals, structs, enums and `std.json.Value`.
- `callAndWriteEffects` calls the port, inspects whether the return type is an error union, and writes `{"ok": …}` or `{"err": "Name"}` through `encode`, plus `"mut"` when the port has mutable slice parameters and `"out"` when it printed. `encode` mirrors JSON number formatting: integral floats print without a fraction.

The harness flushes after every case in `run` mode. If the port crashes or hangs on a case, `diff` reports that case and restarts the harness after it, so later cases are still compared.

In `bench` mode the harness decodes all arguments up front, runs one untimed warm-up pass, then times `iterations` passes with `std.mem.doNotOptimizeAway` on every result. The recorders implement the same protocol, so both sides measure the same thing.

## Comparing

`jsonx.equal` defines semantic equality. Numbers compare by value with an optional absolute or relative tolerance. Two integers compare exactly, except for languages whose numbers are all doubles (JavaScript), where they compare as doubles: JavaScript prints 2^56 − 8 as `72057594037927930`, a Zig port as `72057594037927928`, and both are the same double. Python integers are exact, so they stay exact. Non-finite tags compare as numbers, objects as unordered maps, arrays element by element. `cmd/diff.zig` classifies each case as a match or as one of: different value, unexpected error, missing error, different error name (only with `--strict-errors`), arguments differ after the call, different output, harness error, crash, hang, or not run.

## Scanning and type inference

`scan.zig` contains two scanners:

- **JS/TS:** a tokenizer that understands strings, template literals (including nested `${}`), comments, and regex literals (decided by the previous token). A pass over top-level tokens then recognizes function declarations, `const f = (…) =>`, `const f = function`, `export { a as b }`, `export default`, `module.exports = {…}`, and `exports.f = …`. TypeScript overload signatures, which have no body, are skipped.
- **Python:** a line scanner that tracks bracket depth and triple-quoted strings, then finds column-0 `def` and `async def`, including multi-line signatures.

Types are resolved in priority order: annotation, then default value literal, then usage in the body, then parameter name.

## Planning

`plan` scans a project and estimates each top-level function's body as the text up to the next top-level function. In that text it finds plain calls (`name(`, not `x.name(` or definitions) to other project functions: same-file names first, otherwise a name unique among the files of the same language that the caller's file mentions by module name. Calls inside a cycle are ignored, so mutually recursive functions share a wave. The wave of a function is the longest call chain below it, so porting in wave order means every function's callees are already ported and bridged.

Each function gets a readiness: `blocked` (async or variadic, so not a function unit as written), `review` (untyped parameters, or bodies that do I/O, read the clock, use randomness, `this`/`self`, or globals), or `ready`. Steps are ordered by wave, then by time from a `profile --json` file when given, then readiness, then size. Existing units contribute their state and the next command.

## Building

`unit.build` runs `zig build -Doptimize=<mode> --prefix <dir>` inside the unit directory. `diff` and `gate` use `safe`, which keeps safety checks so that out-of-bounds access and integer overflow in a port become crashes instead of silent wrong answers. `bench` builds `fast` into a separate prefix (`zig-out-fast`).

**Build cache.** Before building, `unit.zig` hashes (SHA-256) everything the build reads: `build.zig`, `build.zig.zon`, every file under `src/`, any file a unit source `@import`s or `@embedFile`s from outside the unit, the compiler (its path, plus the size and mtime of its binary, which change when Zig is upgraded), the optimize mode and the build step. If the hash matches the one stored with the last successful build and the build output is unchanged since then, the build is skipped. This removed about 90% of the time of a `diff` where nothing changed. `--no-cache` (or `"cache": false`) always runs the compiler.

## Bridge

`bridge` makes a proven port callable from the original code.

- **Node, native addon.** `src/bridge_node.zig` exports `napi_register_module_v1` from `napi.Addon(port.f)` and is compiled with `zig build-lib -dynamic` into `bridge/port.node`. The addon needs no Node headers or import library: when it loads, it resolves the ~30 Node-API functions it uses from the host process (`GetProcAddress` on the executable on Windows, `dlsym(RTLD_DEFAULT)` elsewhere), and loading fails cleanly if any is missing. Arguments are converted from JS values straight to the port's parameter types at compile time, and results straight back, with no JSON. A TypedArray whose element type matches a numeric slice parameter (`Float64Array` for `[]const f64`, `Int32Array` for `[]i32`, …) is borrowed in place when its memory is aligned, so large numeric inputs are not copied. The port sees that memory for the duration of the call only. Plain arrays passed to mutable slice parameters are copied in and copied back after the call, so in-place changes behave as they would in JavaScript. Per-thread arenas are kept between calls.
- **Node, WebAssembly.** `src/bridge.zig` exports `za_alloc`, `za_free`, `za_call` and `za_call_batch` through `rt.Bridge`, compiled for `wasm32-freestanding`. Calls cross as JSON. It is the fallback when the native addon is missing or fails to load, and can be forced with `ZIG_ANYTHING_BRIDGE=wasm`.
- **Python.** The same `src/bridge.zig` compiled as a shared library, loaded with `ctypes`; calls cross as JSON. Mutated list arguments are copied back.

`index.mjs` picks the backend once when it loads and exports `backend` (`"native"` or `"wasm"`). After building, every recorded case is replayed through the binding with the normal recorder, through every backend the binding can pick.

## Integration and rollback

`integrate` builds and verifies the bridge, then rewrites the source file:

- **ES modules and TypeScript:** an `import { f } from '<bridge>/index.mjs'` line is added at the top (after a shebang). The original declaration is renamed `f__original` and loses its `export`, and `export { f }` (or `export default f`) re-exports the imported binding. Imports are hoisted, so callers inside the file see the port too. CommonJS files are refused because the bridge is an ES module.
- **Python:** a small loader is inserted above the function (and its decorators), the `def` is renamed `f__original`, and `f = _za_load_f()` is placed right after the original's body, so module-level code below it sees the port.

The original bytes are saved in `<unit>/integration/` with their SHA-256 and the SHA-256 of the rewritten file. Then every recorded case is replayed through the rewritten source file, and the project's own tests run when a command is given after `--`. If either fails, the original file is restored and the backup removed. `integrate --rollback` restores the original later, and refuses when the file changed after integrating (that would discard edits) unless `--force`.

## Program units and profiling

- Program units (`kind: "cli"` in `unit.json`) store a command and a working directory. Cases are invocations (`args` plus optional `stdin`); `cmd/program.zig` runs the original and the built `port` executable and compares stdout and exit code.
- `profile` runs `node --cpu-prof` and aggregates the `.cpuprofile`, or runs an embedded `cProfile` helper for Python. Results are cross-referenced with the scanner to mark portable functions.

## MCP server and agents

`mcp` speaks the Model Context Protocol over stdio. Each tool call runs this executable as a subprocess with `--no-color`, so tools behave exactly like the CLI. To keep results cheap for a model to read, output is compacted unless the call passes `verbose: true`: progress lines overwritten with `\r` keep only their final state, and output over about 6,000 bytes keeps its first and last lines (where commands print the summary and the next step) with a note of how many lines were left out. `diff` and `plan` default to short listings. Tool descriptions are kept short because the tool list is sent to the model in every session.

`setup-agent` writes project-level MCP configuration for Claude Code (`.mcp.json`), Cursor (`.cursor/mcp.json`) and VS Code (`.vscode/mcp.json`), merging into existing files, and with `--agents-md` a marked workflow section in `AGENTS.md`.

## Error handling

Every user-facing failure goes through `Ctx.fail`, which prints `error: …` (with an optional `hint:` line) and returns `error.Reported`. `main` maps that to exit code 3. Checks that fail (mismatches, compile errors, gate, a failed integration) return exit code 1, and usage errors return 2. Missing tools produce install hints instead of `FileNotFound`.

## Testing

- `zig build test`: unit tests in every module (scanners, generator, comparison, flag parsing, config, manifest rendering, planning, source rewriting, MCP argument mapping and output compaction, agent configuration merging) and in the unit runtimes `rt.zig` and `napi.zig`.
- `zig build e2e`: `tests/e2e.zig` drives the real binary through complete JavaScript, TypeScript and Python workflows. It also covers side effects, both bridge backends (including mutation and typed arrays), the sandbox, reproducibility checks, fuzzing, planning, integration and rollback, regressions (wrong port, crashing port, compile error), error messages, JSON output, the MCP protocol, agent setup, and the gate of every committed example.
- `zig build microbench`: throughput of the tool's hot paths.
- `python bench/e2e.py --baseline <ref>`: end-to-end timing of the workflow against an earlier release, and per-call bridge cost.

# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-27

### Added

- **Native Node bridge.** `bridge` now also builds `port.node`, a Node-API addon that converts arguments directly to the port's types and back (no JSON). TypedArrays whose element type matches a numeric slice parameter are passed without copying. It needs no Node headers or build tools, and falls back to the WebAssembly build when it cannot load (`ZIG_ANYTHING_BRIDGE=wasm` forces WebAssembly; `--no-native` skips it). Both backends are verified against every recorded case. `index.mjs` also exports `backend`.
- `plan [path]`: an ordered migration plan for a whole project. Callees come before callers, then hot code first (`--hot` takes `profile --json` output). Async, variadic and side-effecting functions are flagged, and each step gives its next command. `--json` for agents.
- `integrate <unit> [-- test command]`: rewires the original source so callers run the port, after verifying the bridge. It then replays every recorded case through the rewritten file and runs the project's tests, and restores the original byte for byte if anything fails. `--dry-run` shows the rewrite. `--rollback` undoes it, refusing to discard later edits unless `--force`. `status` marks integrated units.
- `fuzz <unit>`: coverage-guided input discovery. Mutates recorded inputs and keeps those that reach new code in the original (`inputs.fuzz.jsonl`, used by the next `record`).
- `record --effects`: also records argument mutation and printed output, and `diff`/`gate`/`bridge` compare them.
- `record --sandbox`: blocks file writes, subprocesses and network access by the original while recording (Node's permission model; a Python audit hook). A guard against accidents, not a security boundary.
- Reproducible recordings: `record` writes `recording.json` (options, runtime, source hash); `record --check` fails without writing anything if re-recording would change a case. `diff --case 3,17` replays single cases.
- `setup-agent`: registers the MCP server in `.mcp.json` (Claude Code), `.cursor/mcp.json` and `.vscode/mcp.json`, merging with existing configuration. `--agents-md` adds the workflow to `AGENTS.md`.
- MCP: `plan`, `fuzz` and `integrate` tools, and the new `record`, `diff` and `bridge` options. Tool results are compacted (overwritten progress lines collapsed, long output cut to its head and tail) unless `verbose: true`. `diff` shows 3 mismatches and `plan` 10 steps by default.
- Packages: an npm package (`npx zig-anything`) and PyPI wheels (`pip install zig-anything`) with the prebuilt binaries, built by `packaging/build.py`. Releases publish them when registry tokens are configured.
- `bench/e2e.py`: reproducible end-to-end timing against an earlier release (`--baseline v0.1.1`), plus per-call bridge cost.
- Configuration: `sandbox`, `effects`, `jobs`, `cache` and `env` fields.

### Changed

- Build caching: `zig build` is skipped when nothing it reads has changed, which was most of the time of `diff` and `gate` when nothing changed. `--no-cache` turns it off.
- Recording runs, large recordings and large replays run in parallel processes (`--jobs`, `"jobs"`).
- When the port crashes or hangs on a case, `diff` reports that case and continues with the rest instead of marking every later case "not run".
- Languages are adapters (`src/adapters/`); commands no longer branch on the language.
- CI covers Linux, macOS and Windows on both x86_64 and arm64, the oldest supported Node (22) and Python (3.9), and builds and installs the npm package and a wheel.
- Release binaries are larger (about 0.75–1.1 MB) because of the new commands and the embedded Node-API runtime.

### Fixed

- Bridge verification of a recording with side effects replayed without them, so it reported mismatches.
- Through the bridges, in-place changes the port makes to array arguments were lost. They are now copied back into the caller's arrays (lists in Python), as they would be in the original.
- `diff` reported JavaScript integers above 2^53 as different when they were the same double (JavaScript prints 2^56 − 8 as `72057594037927930` where the port prints `72057594037927928`). Python integers are still compared exactly.
- Output redirected to a file opened for appending (`zig-anything ... >> log`) overwrote the start of the file.
- Global flags after `--` (for example in a test command) were taken as zig-anything's own.

## [0.1.1] - 2026-11-21

### Fixed

- `zig-anything help` now describes whole-program support in its first line.

## [0.1.0] - 2026-11-21

First release.

### Added

- `scan`: function discovery for JavaScript, TypeScript and Python, with type inference from annotations, defaults, body usage and names.
- `init`: port-unit scaffolding (manifest, Zig stub, generic comptime harness, build file).
- `record`: edge-case, semantic-trap and seeded random input generation, plus `inputs.jsonl`. Runs twice to detect flaky cases. Recordings are reproducible.
- `build` and `diff`: semantic comparison of every recorded case, crash detection, `--tolerance`, `--strict-errors` and `--json`.
- `bench`: calibrated per-call and end-to-end timing of the original against the port, with a verdict.
- `gate`: the definition of done for a port, with an optional performance requirement.
- `status`: overview of all units, including stale-diff detection.
- `mcp`: Model Context Protocol server exposing all commands as tools.
- `zig-anything.json` configuration with environment overrides.
- Examples: `fuzzy-js` (JavaScript, UTF-16 semantics) and `levenshtein-py` (Python, code points).
- `bridge`: call a finished port from the original code (WebAssembly for Node, a native library via ctypes for Python), with batch calls and verification against the recorded cases.
- Program units (`init-cli`): record and port whole command-line programs in any language, compared on stdout, stderr and exit code.
- `profile`: rank a script's functions by time with `node --cpu-prof` or `cProfile` and mark the portable ones.
- Builds refresh each unit's generated runtime, so upgrading zig-anything upgrades existing units.
- Fixed: on Windows every child process started a hidden console host (~9 ms each), which inflated `bench` end-to-end times.
- Size-optimized release builds for Linux, macOS and Windows on x86_64 and aarch64.

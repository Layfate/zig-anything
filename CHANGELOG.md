# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

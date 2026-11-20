# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-20

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
- Size-optimized release builds for Linux, macOS and Windows on x86_64 and aarch64.

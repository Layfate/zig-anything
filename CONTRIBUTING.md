# Contributing to zig-anything

Thanks for helping! This guide covers the development loop and the bar a change needs to clear.

## Setup

- [Zig 0.17.1](https://ziglang.org/download/)
- Node.js 24 and Python 3.10+ (for the end-to-end tests)

```sh
zig build test        # fast: unit tests
zig build e2e         # full workflows on JS, TS and Python fixtures, plus the examples
zig fmt --check src tests bench build.zig
```

CI runs all three on Linux, macOS and Windows.

## Guidelines

- **Standard library only.** Adding a dependency needs a strong reason.
- **Explicit memory.** Use the command arena for invocation-lifetime data, and free large buffers explicitly. Tests use `std.testing.allocator`, so leaks fail them.
- **Errors users can act on.** Report failures with `ctx.fail("what went wrong", …)` and, where possible, a `ctx.hint` that says what to do next. Never let a raw error name be the only message.
- **Keep embedded assets in sync.** `src/assets/rt.zig` is copied into every unit. If you change it, run `zig build test` (which tests it directly) and `zig build e2e`.
- **Tests with behavior changes.** Scanner or generator changes need unit tests. User-visible behavior needs an e2e check in `tests/e2e.zig`.

## Benchmarks and performance claims

Performance claims in the README or changelog must be **measured and reproducible**:

1. State the machine, OS and tool versions.
2. Give the exact command that reproduces the number (`zig-anything bench …`, `zig build microbench`, `bench/startup.py`, `bench/e2e.py`). For a change to the tool's own speed, compare against the last release with `python bench/e2e.py --baseline <tag>`.
3. Report medians, and report regressions honestly, including cases where a port is slower.

Optimize only after profiling. Every optimization must keep `gate` green.

## Adding a source language

Everything language-specific sits behind the adapter table in `src/adapter.zig`. A language needs:

1. a `Language` tag and its file extensions in `lang.zig`, and a scanner in `src/scan.zig` (with tests),
2. a recorder script in `src/assets/` that follows the run/bench/cover protocol and the `ZA_*` environment variables described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
3. a file in `src/adapters/` that fills in an `Adapter`, one line in `adapter.forLanguage`, and its runtime command in `config.zig`,
4. an e2e workflow with a fixture and a reference solution.

## Packaging

`python packaging/build.py --version X.Y.Z` turns the output of `zig build release` into the npm package (`dist-packages/npm/`) and one PyPI wheel per platform. CI builds and installs both on every push. Releases publish them when `NPM_TOKEN` and `PYPI_API_TOKEN` secrets are set. A release tag must match the version in `build.zig` and `build.zig.zon`.

## Commits and pull requests

- Keep pull requests focused. Describe the user-visible change and how you tested it.
- Update `CHANGELOG.md` under "Unreleased".
- Run `zig fmt` before committing.

<p align="center">
  <img src="docs/assets/logo.png" width="140" height="140" alt="zig-anything logo">
</p>

<h1 align="center">zig-anything</h1>

<p align="center">
<a href="https://github.com/Layfate/zig-anything/releases/latest"><img src="https://img.shields.io/github/v/release/Layfate/zig-anything?style=flat&colorA=111111&colorB=f7a41d&label=release" alt="Latest release"></a>
<a href="https://github.com/Layfate/zig-anything/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/Layfate/zig-anything/ci.yml?branch=main&style=flat&colorA=111111&label=CI" alt="CI status"></a>
<a href="https://ziglang.org/download/"><img src="https://img.shields.io/badge/zig-0.17.1-111111?style=flat&colorA=111111&colorB=f7a41d" alt="Zig 0.17.1"></a>
<a href="https://github.com/Layfate/zig-anything/stargazers"><img src="https://img.shields.io/github/stars/Layfate/zig-anything?style=flat&colorA=111111&colorB=f7a41d&label=stars" alt="GitHub stars"></a>
<a href="#license"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat&colorA=111111&colorB=f7a41d" alt="MIT license"></a>
</p>

<p align="center">
Port your JavaScript, TypeScript and Python code to Zig, and prove it still behaves the same.
</p>

<p align="center">
<b>Documentation:</b> <a href="docs/GUIDE.md">Guide</a> · <a href="docs/ARCHITECTURE.md">Architecture</a> · <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <img src="docs/assets/demo.gif" alt="A Python Levenshtein function and its Zig port running the same 253 recorded cases: 134.6 ms versus 6.5 ms" width="820">
</p>

## Quick start

Paste this into your coding agent:

```text
Install zig-anything with npm i -g https://github.com/Layfate/zig-anything/releases/download/v0.2.0/zig-anything-0.2.0.tgz, then run zig-anything setup-agent. Run zig-anything plan, port each function in that order until zig-anything gate passes for it, then switch callers to it with zig-anything integrate.
```

Or install it yourself:

```sh
npm i -g https://github.com/Layfate/zig-anything/releases/download/v0.2.0/zig-anything-0.2.0.tgz
zig-anything setup-agent   # adds it to Claude Code, Cursor and VS Code
```

Prebuilt binaries for Linux, macOS and Windows (x86_64 and arm64) and Python wheels are on the [releases page](https://github.com/Layfate/zig-anything/releases/latest).

## How it works

```sh
zig-anything plan src/                        # what to port, in what order
zig-anything init src/text.mjs slugify        # scaffold zig-port/slugify
zig-anything record slugify                   # record what the original does
$EDITOR zig-port/slugify/src/port.zig         # write the port
zig-anything diff slugify                     # repeat until every case matches
zig-anything gate slugify                     # done means this passes
zig-anything integrate slugify -- npm test    # switch callers to the port, verified
```

The original keeps running in its own runtime while zig-anything records what it does on generated edge cases and your own inputs. Every recorded case is then replayed against the port. A port is finished when every case matches, and `integrate` rolls the source back by itself if anything fails afterwards.

> [!TIP]
> Ports are built with [Zig 0.17.1](https://ziglang.org/download/). Recording needs Node.js 22.6+ for JavaScript and TypeScript, or Python 3.8+ for Python. The [guide](docs/GUIDE.md) covers every command, configuration, the bridge, benchmarks and limitations.

## License

[MIT](LICENSE) © zig-anything contributors. Ports and generated code in your repository are yours.

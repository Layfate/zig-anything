# Example: fuzzy matching (JavaScript → Zig)

`src/fuzzy.mjs` scores how well a query matches a text as a subsequence. Word starts, consecutive hits and exact case earn bonuses. The finished port is in `zig-port/fuzzyScore/src/port.zig`.

```sh
zig-anything record fuzzyScore   # 288 cases: 253 generated + 35 from inputs.jsonl
zig-anything gate fuzzyScore     # PASSED
zig-anything bench fuzzyScore
```

## What the recording caught

JavaScript strings are UTF-16: `length`, `charCodeAt` and indices count code units, so `🎉` is two units. A port that walks UTF-8 bytes passes every ASCII case and fails exactly the cases with multi-byte characters:

```text
case 22: different value
  args      ["🎉","emoji 🎉 ok"]
  expected  {"ok":0.75}
  got       {"ok":0.7}
285/288 cases match
```

The port decodes UTF-8 into UTF-16 units on the fly to reproduce the original's positions.

## Why `inputs.jsonl` matters here

Random strings almost never fuzzy-match, so almost every generated case scores `0`. That tests the "no match" path well but scoring hardly at all. `zig-port/fuzzyScore/inputs.jsonl` adds 35 hand-written queries that do match (word starts, streaks, case, emoji, CJK), and `record` includes them in every recording.

## Making it fast, safely

Measured with `zig-anything bench fuzzyScore` on a Ryzen 7 5700X, Windows 11, Node.js 24:

| Port version | Per call | Compared with V8 |
| --- | --- | --- |
| allocate two UTF-16 buffers per call | 164 ns | 2.6x slower |
| stream UTF-16 units, keep the length check | 168 ns | 2.7x slower |
| ASCII fast path, drop the redundant length check | **31.6 ns** | **1.9x faster** |

Allocation was not the cost. Computing UTF-16 lengths was: JavaScript stores them, but the port had to scan up to 300 bytes per string to get them. The original's `query.length > text.length` early exit gives the same answer as the main loop running out of text, so the port drops it. The recorded cases stayed 288/288 green throughout, which is what made the rewrite safe.

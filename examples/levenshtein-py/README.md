# Example: edit distance (Python → Zig)

`src/textdist.py` computes the Levenshtein distance with the classic two-row dynamic program. The finished port is in `zig-port/levenshtein/src/port.zig`.

```sh
zig-anything record levenshtein   # 253 generated cases
zig-anything gate levenshtein     # PASSED
zig-anything bench levenshtein
```

## The trap

Python strings are sequences of code points, so `levenshtein("café", "cafe") == 1`. A port that compares bytes says `2`, because `é` is two bytes in UTF-8. The generated cases include accented, CJK and emoji strings, so `diff` reports that mismatch immediately. The port decodes both inputs to code points first.

## Result

Measured with `zig-anything bench levenshtein` on a Ryzen 7 5700X, Windows 11, Python 3.12.10 (median of 5 runs):

| | Python | Zig port |
| --- | --- | --- |
| per call | 51.1 µs | 0.31 µs (164x) |
| one process, all 253 cases | 134.6 ms | 6.5 ms (20.8x) |

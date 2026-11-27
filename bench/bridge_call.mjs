// Per-call cost of a generated JS bridge, used by bench/e2e.py.
//
//   node bench/bridge_call.mjs <bridge/index.mjs> <cases.jsonl> <function> [target_ms]
//
// Calls the bridged function on every recorded case that returned a value
// (cases that threw are excluded, as in `zig-anything bench`), first once
// untimed, then in timed passes until target_ms has elapsed. Prints JSON:
// {"backend": "native" | "wasm", "ns_per_call": ..., "calls": ...}.
// Set ZIG_ANYTHING_BRIDGE=wasm to measure the WebAssembly backend.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const [binding, casesPath, name, targetArg] = process.argv.slice(2);
const targetMs = Number(targetArg ?? 300);
const mod = await import(pathToFileURL(resolve(binding)).href);
const fn = mod[name];

function decode(v) {
  if (Array.isArray(v)) return v.map(decode);
  if (v !== null && typeof v === 'object') {
    const keys = Object.keys(v);
    if (keys.length === 1 && keys[0] === '$num') return Number(v.$num);
    const o = {};
    for (const k of keys) o[k] = decode(v[k]);
    return o;
  }
  return v;
}

const calls = [];
for (const line of readFileSync(casesPath, 'utf8').split('\n')) {
  if (!line.trim()) continue;
  const c = JSON.parse(line);
  if (c.flaky || !c.expect || !('ok' in c.expect)) continue;
  calls.push(decode(c.args));
}
if (calls.length === 0) throw new Error('no cases that return a value');

let sink = 0;
const once = () => {
  for (const args of calls) {
    const r = fn(...args);
    sink += typeof r === 'number' ? r : 1;
  }
};
once();
let n = 0;
const t0 = process.hrtime.bigint();
let elapsed = 0n;
while (elapsed < BigInt(targetMs) * 1000000n) {
  once();
  n += calls.length;
  elapsed = process.hrtime.bigint() - t0;
}
console.log(JSON.stringify({ backend: mod.backend ?? 'wasm', ns_per_call: Number(elapsed) / n, calls: n, sink: sink > 0 }));

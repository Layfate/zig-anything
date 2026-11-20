// ZigAnything recorder for JavaScript and TypeScript sources.
// usage: node record.mjs <run|bench> <source> <function> <cases.jsonl> <out> [iterations]
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [, , mode, src, fnName, casesPath, outPath, itersArg] = process.argv;

// Keep stdout/stderr free for the user's code; results go to `outPath`.
const fail = (msg) => {
  process.stderr.write(`zig-anything recorder: ${msg}\n`);
  process.exit(3);
};

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

function encode(v, seen) {
  switch (typeof v) {
    case 'number':
      return Number.isFinite(v) ? v : { $num: String(v) };
    case 'bigint':
      return { $big: v.toString() };
    case 'undefined':
      return null;
    case 'string':
    case 'boolean':
      return v;
    case 'function':
    case 'symbol':
      return { $opaque: typeof v };
  }
  if (v === null) return null;
  if (seen.has(v)) return { $opaque: 'cycle' };
  seen.add(v);
  try {
    if (Array.isArray(v) || ArrayBuffer.isView(v)) return Array.from(v, (x) => encode(x, seen));
    if (v instanceof Map) {
      const o = {};
      for (const [k, x] of v) o[String(k)] = encode(x, seen);
      return o;
    }
    if (v instanceof Set) return Array.from(v, (x) => encode(x, seen));
    if (v instanceof Date) return Number.isNaN(v.getTime()) ? null : v.toISOString();
    if (v instanceof Error) return { $error: v.name };
    if (typeof v.toJSON === 'function') return encode(v.toJSON(), seen);
    const o = {};
    for (const k of Object.keys(v)) o[k] = encode(v[k], seen);
    return o;
  } finally {
    seen.delete(v);
  }
}

async function load() {
  let mod;
  try {
    mod = await import(pathToFileURL(src).href);
  } catch (err) {
    try {
      mod = createRequire(import.meta.url)(src);
    } catch {
      fail(`cannot load ${src}: ${err && err.message ? err.message : err}`);
    }
  }
  const candidates = [
    mod?.[fnName],
    mod?.default?.[fnName],
    mod?.['module.exports']?.[fnName],
    typeof mod?.default === 'function' && mod.default.name === fnName ? mod.default : undefined,
  ];
  const f = candidates.find((c) => typeof c === 'function');
  if (!f) fail(`'${fnName}' is not an exported function of ${src}`);
  return f;
}

const f = await load();
const cases = readFileSync(casesPath, 'utf8')
  .split('\n')
  .filter((l) => l.trim() !== '')
  .map((l) => decode(JSON.parse(l).args));

if (mode === 'run') {
  const out = [];
  for (const args of cases) {
    let line;
    try {
      let v = f(...args);
      if (v !== null && typeof v === 'object' && typeof v.then === 'function') v = await v;
      line = JSON.stringify({ ok: encode(v, new Set()) });
    } catch (e) {
      const name = e && typeof e === 'object' && e.name ? String(e.name) : 'Error';
      const msg = String(e && typeof e === 'object' && 'message' in e ? e.message : e).slice(0, 200);
      line = JSON.stringify({ err: name, msg });
    }
    out.push(line);
  }
  writeFileSync(outPath, out.length ? out.join('\n') + '\n' : '');
} else if (mode === 'bench') {
  const iters = Number(itersArg ?? 1);
  let sink = 0;
  const once = () => {
    for (const args of cases) {
      try {
        const v = f(...args);
        if (v !== undefined) sink++;
      } catch {
        sink--;
      }
    }
  };
  once(); // untimed warm-up pass
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < iters; i++) once();
  const ns = process.hrtime.bigint() - t0;
  writeFileSync(outPath, JSON.stringify({ cases: cases.length, iterations: iters, ns: Number(ns), sink }) + '\n');
} else {
  fail(`unknown mode '${mode}'`);
}

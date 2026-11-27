// ZigAnything recorder for JavaScript and TypeScript sources.
// usage: node record.mjs <run|bench|cover> <source> <function> <cases.jsonl> <out> [iterations]
//
// Environment switches (all optional):
//   ZA_EFFECTS=1       also record argument mutation ("mut") and printed output ("out")
//   ZA_SANDBOX=1       block network access (file writes and subprocesses are
//                      blocked by Node's permission model, which zig-anything
//                      enables on the command line)
//   ZA_COVER_ROOT=dir  `cover` mode: only count coverage in files under dir
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [, , mode, src, fnName, casesPath, outPath, itersArg] = process.argv;
const effects = process.env.ZA_EFFECTS === '1';
const sandbox = process.env.ZA_SANDBOX === '1';

// Keep stdout/stderr free for the user's code; results go to `outPath`.
const fail = (msg) => {
  process.stderr.write(`zig-anything recorder: ${msg}\n`);
  process.exit(3);
};

// ---------------------------------------------------------------- sandbox

let blocked = 0;
class SandboxError extends Error {
  constructor(what) {
    super(`zig-anything sandbox blocked ${what}`);
    this.name = 'Error';
    this.code = 'ERR_ACCESS_DENIED';
  }
}
if (sandbox) {
  // Patch the CommonJS builtins, then push the change to their ESM views.
  const require = createRequire(import.meta.url);
  const net = require('node:net');
  const dgram = require('node:dgram');
  const dns = require('node:dns');
  const deny = (what) => () => {
    blocked++;
    throw new SandboxError(what);
  };
  net.Socket.prototype.connect = deny('a network connection');
  net.Server.prototype.listen = deny('listening on a socket');
  dgram.Socket.prototype.send = deny('a UDP send');
  dgram.Socket.prototype.bind = deny('a UDP bind');
  dns.lookup = deny('a DNS lookup');
  dns.promises.lookup = deny('a DNS lookup');
  if (typeof globalThis.fetch === 'function') globalThis.fetch = deny('fetch()');
  require('node:module').syncBuiltinESMExports();
}
const isBlocked = (e) => e instanceof SandboxError || (e && typeof e === 'object' && e.code === 'ERR_ACCESS_DENIED');

// ---------------------------------------------------------------- values

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

// ---------------------------------------------------------------- output capture

let captured = null;
const realWrite = process.stdout.write;
function startCapture() {
  captured = [];
  process.stdout.write = function (chunk, encoding, cb) {
    captured.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8'));
    const done = typeof encoding === 'function' ? encoding : cb;
    if (typeof done === 'function') done();
    return true;
  };
}
function stopCapture() {
  process.stdout.write = realWrite;
  const text = captured.join('');
  captured = null;
  return text;
}

// One recorded call: {"ok": v} or {"err": name, "msg": text}, plus "mut",
// "out" and "blocked" when they apply.
async function callOnce(args) {
  const before = effects ? JSON.stringify(encode(args, new Set())) : '';
  const blockedBefore = blocked;
  if (effects) startCapture();
  let rec;
  try {
    let v = f(...args);
    if (v !== null && typeof v === 'object' && typeof v.then === 'function') v = await v;
    rec = { ok: encode(v, new Set()) };
  } catch (e) {
    const name = e && typeof e === 'object' && e.name ? String(e.name) : 'Error';
    const msg = String(e && typeof e === 'object' && 'message' in e ? e.message : e).slice(0, 200);
    rec = { err: name, msg };
    if (isBlocked(e)) rec.blocked = true;
  }
  if (effects) {
    const out = stopCapture();
    const after = encode(args, new Set());
    if (JSON.stringify(after) !== before) rec.mut = after;
    if (out !== '') rec.out = out;
  }
  if (blocked !== blockedBefore) rec.blocked = true;
  return rec;
}

// ---------------------------------------------------------------- coverage

// Block coverage from V8's inspector, taken (and reset) after every case.
// Each executed block becomes one feature: (script, range, hit-count bucket).
function coverageSession() {
  const require = createRequire(import.meta.url);
  const inspector = require('node:inspector');
  const session = new inspector.Session();
  session.connect();
  const post = (method, params) => {
    let error;
    let result;
    session.post(method, params ?? {}, (e, r) => {
      error = e;
      result = r;
    });
    if (error) throw error;
    return result;
  };
  post('Profiler.enable');
  post('Profiler.startPreciseCoverage', { callCount: true, detailed: true });
  const root = pathToFileURL(process.env.ZA_COVER_ROOT || dirname(src)).href;
  const bucket = (n) => (n < 4 ? n : n < 8 ? 4 : n < 16 ? 5 : n < 32 ? 6 : n < 128 ? 7 : 8);
  const hash = (s) => {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
    return h >>> 0;
  };
  return () => {
    const { result } = post('Profiler.takePreciseCoverage');
    const features = new Set();
    for (const script of result) {
      if (!script.url.startsWith(root) || script.url.includes('/node_modules/') || script.url.includes('/.za/')) continue;
      for (const fn of script.functions) {
        for (const r of fn.ranges) {
          if (r.count > 0) features.add(hash(`${script.url}:${r.startOffset}:${r.endOffset}:${bucket(r.count)}`));
        }
      }
    }
    return Array.from(features).sort((a, b) => a - b);
  };
}

// ---------------------------------------------------------------- main

const f = await load();
const cases = readFileSync(casesPath, 'utf8')
  .split('\n')
  .filter((l) => l.trim() !== '')
  .map((l) => decode(JSON.parse(l).args));

if (mode === 'run' || mode === 'cover') {
  if (mode === 'run') {
    try {
      writeFileSync(join(dirname(outPath), 'runtime.txt'), `node ${process.version}\n`);
    } catch {}
  }
  const take = mode === 'cover' ? coverageSession() : null;
  if (take) take(); // discard what loading the module covered
  const out = [];
  for (const args of cases) {
    const rec = await callOnce(args);
    if (take) rec.cov = take();
    out.push(JSON.stringify(rec));
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

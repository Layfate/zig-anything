// Used by the end-to-end tests: loads the scaleInPlace bridge with the
// backend named on the command line and prints what calls did to their
// arguments.
process.env.ZIG_ANYTHING_BRIDGE = process.argv[2] === 'wasm' ? 'wasm' : '';
const { scaleInPlace, scaleInPlaceBatch, backend } = await import('../zig-port/scaleInPlace/bridge/index.mjs');
const plain = [1, 2, 3];
const typed = new Float64Array([1, 2, 3]);
const ints = new Int32Array([1, 2, 3]);
const n = scaleInPlace(plain, 2);
scaleInPlace(typed, 2);
scaleInPlace(ints, 2);
const inBatch = [5];
const batch = scaleInPlaceBatch([[inBatch, 3], [[], 1]]);
let badArg = '';
try {
  scaleInPlace('not an array', 2);
} catch (e) {
  badArg = e instanceof Error ? 'threw' : 'no';
}
console.log(JSON.stringify({ backend, n, plain, typed: [...typed], ints: [...ints], inBatch, batch, badArg }));

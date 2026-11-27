// Array helpers used by the end-to-end tests: one mutates its argument,
// one has side effects the sandbox must stop.
import { writeFileSync } from 'node:fs';

export function scaleInPlace(xs, k) {
  for (let i = 0; i < xs.length; i++) xs[i] *= k;
  return xs.length;
}

export function saveNote(name) {
  writeFileSync(name, 'written by the original');
  return name.length;
}

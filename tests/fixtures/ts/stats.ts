// Statistics helpers used by the end-to-end tests.

export function mean(xs: number[]): number {
  if (xs.length === 0) throw new RangeError('mean of empty list');
  let total = 0;
  for (const x of xs) total += x;
  return total / xs.length;
}

export function range(xs: number[]): number[] {
  if (xs.length === 0) return [];
  return [Math.min(...xs), Math.max(...xs)];
}

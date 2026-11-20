// Small text helpers used by the end-to-end tests.

export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

export const clamp = (value, lo = 0, hi = 1) => Math.min(Math.max(value, lo), hi);

export function wordCount(text) {
  if (typeof text !== 'string') throw new TypeError('text must be a string');
  const words = text.trim().split(/\s+/);
  return words[0] === '' ? 0 : words.length;
}

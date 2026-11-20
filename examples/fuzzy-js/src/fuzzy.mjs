// Subsequence fuzzy matching with bonuses for word starts, streaks and exact
// case. Returns a score in [0, 1]; 0 means "not a match".

const lower = (c) => (c >= 65 && c <= 90 ? c + 32 : c);
const isBoundary = (c) => c === 32 || c === 45 || c === 95 || c === 47 || c === 46;

export function fuzzyScore(query, text) {
  if (query.length === 0) return 1;
  if (query.length > text.length) return 0;
  let qi = 0;
  let score = 0;
  let streak = 0;
  let prev = -2;
  for (let ti = 0; ti < text.length && qi < query.length; ti++) {
    const t = text.charCodeAt(ti);
    const q = query.charCodeAt(qi);
    if (lower(t) !== lower(q)) continue;
    let bonus = 1;
    if (ti === 0 || isBoundary(text.charCodeAt(ti - 1))) bonus += 2;
    if (prev === ti - 1) {
      streak++;
      bonus += streak;
    } else {
      streak = 0;
    }
    if (t === q) bonus += 0.5;
    score += bonus;
    prev = ti;
    qi++;
  }
  if (qi < query.length) return 0;
  const n = query.length;
  const best = n * 3.5 + (n * (n - 1)) / 2;
  return Math.round((score / best) * 1000) / 1000;
}

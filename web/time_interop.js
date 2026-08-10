// Time formatting for the Observatory dashboard — browser-side, locale-aware.
export function fmtWhen(ms) {
  const n = Number(ms);
  if (!n) return "—";
  const d = new Date(n);
  const diff = n - Date.now();
  const mins = Math.round(Math.abs(diff) / 60000);
  const rel = mins < 1 ? "now" : mins < 60 ? mins + "m" : Math.round(mins / 60) + "h";
  const abs = d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  return abs + (diff > 0 ? " · in " + rel : " · " + rel + " ago");
}

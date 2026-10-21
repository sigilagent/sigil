// Browser plumbing for the console: hash routes, local storage, file reading,
// the ⌘K shortcut, the clipboard and a few formatters. Plain JS because each is
// a browser API built on a callback or a Promise, which client Jac reaches more
// plainly through a function than through its interop spellings.

export function routeNow() {
  const h = window.location.hash || "";
  const p = h.startsWith("#") ? h.slice(1) : h;
  return p || "/";
}

export function onRoute(cb) {
  const f = () => cb(routeNow());
  window.addEventListener("hashchange", f);
  return () => window.removeEventListener("hashchange", f);
}

export function navTo(path) {
  const p = String(path || "/");
  const target = p.startsWith("/") ? p : "/" + p;
  if (routeNow() !== target) window.location.hash = target;
  window.scrollTo(0, 0);
}

export function storeGet(key, fallback) {
  try {
    const v = window.localStorage.getItem(key);
    return v === null ? fallback : JSON.parse(v);
  } catch (e) {
    return fallback;
  }
}

export function storeSet(key, value) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    // private window, or storage full: the console works without it
  }
}

// ⌘K / Ctrl+K opens the palette, Escape closes whatever is open.
export function onShortcut(cb) {
  const f = (e) => {
    if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
      e.preventDefault();
      cb("palette");
    } else if (e.key === "Escape") {
      cb("escape");
    }
  };
  window.addEventListener("keydown", f);
  return () => window.removeEventListener("keydown", f);
}

// The last answer each read got, for this tab only. Every call to Sigil starts
// a fresh process (several seconds), so a page shows what it saw last time at
// once and replaces it when the new answer lands.
const SEEN = new Map();

export function seen(key) {
  return SEEN.has(key) ? SEEN.get(key) : null;
}

export function remember(key, value) {
  SEEN.set(key, value);
  return value;
}

export function pageVisible() {
  return !document.hidden;
}

const MAX_FILE = 1024 * 1024;

// The text files of a picked folder (or of loose files), as [{path, text}].
// Hidden files, node_modules, anything over 1 MB and anything binary are left
// out: a skill folder is documents and scripts, not a build tree.
export async function readFiles(fileList) {
  const out = [];
  for (const f of Array.from(fileList || [])) {
    if (f.size > MAX_FILE) continue;
    const path = f.webkitRelativePath || f.name;
    if (path.split("/").some((seg) => seg.startsWith(".") || seg === "node_modules")) continue;
    let text = "";
    try {
      text = await f.text();
    } catch (e) {
      continue;
    }
    if (text.indexOf("\u0000") >= 0) continue;
    out.push({ path, text });
  }
  return out;
}

export function copyText(s) {
  try {
    navigator.clipboard.writeText(String(s));
    return true;
  } catch (e) {
    return false;
  }
}

export function nowMs() {
  return Date.now();
}

export function focusId(id) {
  setTimeout(() => {
    const el = document.getElementById(id);
    if (el) el.focus();
  }, 0);
}

export function scrollToEnd(id) {
  setTimeout(() => {
    const el = document.getElementById(id);
    if (el) el.scrollTop = el.scrollHeight;
  }, 0);
}

// "now", "5m ago", "3h ago", then a weekday and time within the week, then a date.
export function fmtAgo(ms) {
  const n = Number(ms);
  if (!n) return "never";
  const diff = Date.now() - n;
  const future = diff < 0;
  const a = Math.abs(diff);
  const mins = Math.round(a / 60000);
  if (mins < 1) return "now";
  if (mins < 60) return future ? "in " + mins + "m" : mins + "m ago";
  const hours = Math.round(mins / 60);
  if (hours < 24) return future ? "in " + hours + "h" : hours + "h ago";
  const d = new Date(n);
  if (hours < 24 * 6) {
    return d.toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" });
  }
  return d.toLocaleString(undefined, { month: "short", day: "numeric" });
}

export function fmtClock(ms) {
  const n = Number(ms);
  if (!n) return "";
  return new Date(n).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
}

// "2026-10-16" -> "Thu 16"
export function fmtDay(iso) {
  const parts = String(iso || "").split("-").map(Number);
  if (parts.length !== 3 || !parts[0]) return String(iso || "");
  const d = new Date(parts[0], parts[1] - 1, parts[2]);
  return d.toLocaleDateString(undefined, { weekday: "short" }) + " " + parts[2];
}

export function money(v) {
  const n = Number(v) || 0;
  if (n === 0) return "$0.00";
  if (n < 0.01) return "<$0.01";
  return "$" + n.toFixed(2);
}

export function compact(v) {
  const n = Number(v) || 0;
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "k";
  return String(Math.round(n));
}

export function secs(ms) {
  const n = Number(ms) || 0;
  if (n < 1000) return Math.round(n) + "ms";
  if (n < 60000) return (n / 1000).toFixed(1) + "s";
  return Math.floor(n / 60000) + "m " + Math.round((n % 60000) / 1000) + "s";
}

// Who may embed the Observatory in a frame — browser-side, run before it renders.
//
// The page at https://local.sigilagent.com (repo sigilagent/local) shows this
// machine's Observatory full-window inside a frame, so the address bar keeps a
// readable name. Any other site that framed it could dress it up and trick
// clicks (clickjacking), and jac's server sends no header to forbid framing. So
// the check lives here: the Observatory cannot render without this script, and
// this script refuses to render for any embedder not listed below. A frame
// sandboxed without scripts renders nothing at all.
const EMBED_ORIGINS = ["https://local.sigilagent.com"];

function embedderOrigins() {
  // Chrome and Safari list every ancestor, top-level page included.
  const anc = window.location.ancestorOrigins;
  if (anc && anc.length) return Array.from(anc);
  // Firefox has no ancestorOrigins. The referrer is the embedding page's origin
  // under the default referrer policy; an embedder that strips it
  // (referrerpolicy="no-referrer") is refused. The page at local.sigilagent.com
  // refuses to be framed itself, so the immediate parent is the whole chain.
  try {
    return [new URL(document.referrer).origin];
  } catch (_e) {
    return [];
  }
}

export function embedAllowed() {
  if (window.self === window.top) return true;
  const origins = embedderOrigins();
  return origins.length > 0 && origins.every((o) => EMBED_ORIGINS.includes(o));
}

// Tell an allowed embedder the Observatory loaded. It cannot see into this
// cross-origin frame, so this message is how it tells "Sigil is running" from
// the browser's own error page and shows how to start Sigil instead.
function announceReady() {
  if (window.self === window.top || !embedAllowed()) return;
  const parent = embedderOrigins()[0];
  window.parent.postMessage({ sigil: "observatory-ready" }, parent);
}

announceReady();

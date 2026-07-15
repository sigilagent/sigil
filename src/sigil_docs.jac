"""Self-docs — the reference the agent reads to answer questions about itself.

The docs are plain markdown under `docs/reference/` (browsable on GitHub); this module
loads them at run time so the chat tool and the CLI serve exactly the published text —
one source of truth. `list_docs()` enumerates the topics; `read_doc(topic)` returns one,
matching the topic name fuzzily. Exposed to chat as the `list_docs` / `read_docs` tools,
to the CLI as `sigil docs [topic]`, and to the REPL as `/docs`.
"""

import os;
import from pathlib { Path }

def _docs_dir() -> str {
    # docs/reference resolved relative to this package (src/), with a bundled fallback.
    here = Path(os.path.abspath(__file__)).parent;                 # .../src
    candidates = [
        str(here.parent / "docs" / "reference"),                   # repo root/docs/reference
        str(here / "docs" / "reference")                           # bundled next to the package
    ];
    for c in candidates { if os.path.isdir(c) { return c; } }
    return candidates[0];
}

def _entries() -> list {
    # every topic doc as {slug, title, summary, path}, excluding the index README.
    d = _docs_dir();
    out: list = [];
    if not os.path.isdir(d) { return out; }
    for name in sorted(os.listdir(d)) {
        if not name.endswith(".md") { continue; }
        if name.lower() == "readme.md" { continue; }
        slug = name[:-3];
        path = os.path.join(d, name);
        title = slug.replace("-", " ");
        summary = "";
        try {
            with open(path, "r") as f { lines = f.read().split(chr(10)); }
            for ln in lines {
                s = ln.strip();
                if s.startswith("# ") and title == slug.replace("-", " ") { title = s[2:].strip(); continue; }
                if s and not s.startswith("#") and not summary { summary = s; }
                if title != slug.replace("-", " ") and summary { break; }
            }
        } except Exception as e {}
        out.append({"slug": slug, "title": title, "summary": summary[:120], "path": path});
    }
    return out;
}

def doc_topics() -> list {
    return [{"slug": e["slug"], "title": e["title"], "summary": e["summary"]} for e in _entries()];
}

def list_docs() -> str {
    es = _entries();
    if not es { return "(no reference docs found)"; }
    rows: list = [];
    for e in es { rows.append(str(e["slug"]).ljust(24) + " — " + str(e["summary"])); }
    return "Reference topics (read one with read_docs <topic>):\n" + "\n".join(rows);
}

def _read(path: str) -> str {
    try {
        with open(path, "r") as f { return f.read(); }
    } except Exception as e { return "error reading doc: " + str(e)[:120]; }
}

def read_doc(topic: str) -> str {
    q = (topic or "").lower().strip().replace(" ", "-");
    es = _entries();
    if not es { return "(no reference docs found)"; }
    if not q { return list_docs(); }
    # 1) exact slug, 2) substring either way, 3) best word-overlap on slug/title
    for e in es { if str(e["slug"]) == q { return _read(str(e["path"])); } }
    for e in es { if (q in str(e["slug"])) or (str(e["slug"]) in q) { return _read(str(e["path"])); } }
    qwords = set(q.replace("-", " ").split());
    best_score = 0;
    best_path = "";
    for e in es {
        words = set((str(e["slug"]) + " " + str(e["title"])).lower().replace("-", " ").split());
        score = len(qwords & words);
        if score > best_score { best_score = score; best_path = str(e["path"]); }
    }
    if best_score > 0 { return _read(best_path); }
    return ("No reference topic matches '" + topic + "'. Available: "
            + ", ".join([str(e["slug"]) for e in es]));
}

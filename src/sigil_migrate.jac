"""Migration provider — OpenClaw -> Sigil.

Reads an OpenClaw agent export directory and folds it onto the graph: SOUL.md
(persona + rules/ethos) into the `Soul`, channels + model tiers from a config
JSON, and any `*.agir` procedures registered as compiled skills (SKILL.md
files are lifted by the frontier on demand via `register_skill`). Idempotent:
re-running updates in place rather than duplicating.
"""

import os;
import json;
import from .sigil { awaken, Soul, register_skill }

def _read(path: str) -> str {
    with open(path) as f { return str(f.read()); }
}

def _parse_soul_md(text: str) -> dict {
    persona_parts: list = [];
    ethos: list = [];
    section = "";
    for raw in text.splitlines() {
        s = raw.strip();
        if not s { continue; }
        if s.startswith("#") { section = s.lstrip("#").strip().lower(); continue; }
        if s.startswith("-") or s.startswith("*") {
            item = s.lstrip("-* ").strip();
            if ("rule" in section) or ("ethos" in section) or ("principle" in section) or ("guideline" in section) {
                if item { ethos.append(item); }
            }
        } elif ("persona" in section) or ("identity" in section) or (section in ["", "soul"]) {
            persona_parts.append(s);
        }
    }
    return {"persona": " ".join(persona_parts), "ethos": ethos};
}

def migrate_openclaw(path: str) -> dict {
    soul = awaken();
    out = {"persona": False, "ethos": 0, "channels": 0, "models": 0, "skills": 0};

    soulmd = os.path.join(path, "SOUL.md");
    if os.path.exists(soulmd) {
        parsed = _parse_soul_md(_read(soulmd));
        if parsed["persona"] { soul.persona = str(parsed["persona"]); out["persona"] = True; }
        for e in list(parsed["ethos"]) { if e not in soul.ethos { soul.ethos = soul.ethos + [str(e)]; out["ethos"] += 1; } }
    }

    for cfgname in ["openclaw.config.json", "config.json"] {
        cfg = os.path.join(path, cfgname);
        if os.path.exists(cfg) {
            data = json.loads(_read(cfg));
            for ch in (data.get("channels", []) or []) {
                nm = str(ch) if isinstance(ch, str) else str(ch.get("name", ""));
                if nm and (nm not in soul.channels) { soul.channels = soul.channels + [nm]; out["channels"] += 1; }
            }
            models = data.get("models", {}) or {};
            if models.get("frontier") { soul.frontier_model = str(models.get("frontier")); out["models"] += 1; }
            if models.get("small") { soul.small_model = str(models.get("small")); out["models"] += 1; }
            break;
        }
    }

    # compiled procedures: register hand-authored AG-IR (model-free); SKILL.md
    # lifts via the frontier when one is configured.
    skdir = os.path.join(path, "skills");
    if os.path.isdir(skdir) {
        for fn in sorted(os.listdir(skdir)) {
            full = os.path.join(skdir, fn);
            low = fn.lower();
            try {
                if low.endswith(".agir") or low.endswith(".ir") { register_skill(_read(full), "agir"); out["skills"] += 1; }
                elif low.endswith(".md") { register_skill(_read(full), "md"); out["skills"] += 1; }
            } except Exception as e {  }
        }
    }
    return out;
}

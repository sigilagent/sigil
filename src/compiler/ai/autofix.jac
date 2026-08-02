"""AI compiler — mechanical autofixes (fix-forward, no model).

The G9 `autofix_carry_types` pattern generalized: every fix here is pure code
over the assembled IR, applied BEFORE the residual gates read it, and re-gated
through G4 by the caller — a patch the oracle rejects is never adopted. Each
pass returns human-readable fix notes; the notes ride `LiftResult.fixes` so a
fixed defect is reported as fixed, not as open.

Three passes, straight from the 33-skill batch's failure classes:

- LANES: a node read with no lane. If the read names a file that exists next
  to SKILL.md (`templates/viewer.html`), the file IS the lane — inline it as a
  knowledge entry resident on the readers (the compile-time twin of G1's
  embody rule). Otherwise mint an input carry so the reference is a seedable
  lane instead of a dangling name.
- POINTERS: a knowledge entry whose body is "See FORMS.md" when FORMS.md sits
  in the skill directory. The lift had the file all along — embody it.
- HOLLOW: an owner=code CODE node no tool serves lowers to a marker comment —
  a station the walker visits that does nothing. Re-own it to a GEN-RAW model
  slot: the degraded-but-real realization (the step is at least executed)
  beats the hollow one (silently skipped), and the note says exactly what was
  traded.
"""

import os;
import re;
import yaml;
import from src.compiler.mechanical.compiler { _load_ir }

glob _POINTER_PREFIXES: list = ["see ", "refer to ", "read ", "as described in ",
                                "per the skill", "from the skill", "consult "];
glob _INLINE_CAP: int = 120000;

def _dump_ir(ir: any) -> str {
    # body + frontmatter, the same re-serialization autofix_carry_types uses.
    fm = ir.get("_frontmatter") if isinstance(ir.get("_frontmatter"), dict) else {};
    body: dict = {};
    for k in ir {
        if str(k) != "_frontmatter" { body[k] = ir[k]; }
    }
    out = str(yaml.safe_dump(body, sort_keys=False, allow_unicode=True));
    if fm {
        out = "---\n" + str(yaml.safe_dump(fm, sort_keys=False, allow_unicode=True)) + "---\n" + out;
    }
    return out;
}

def _skill_file(skill_dir: str, ref: str) -> str {
    # Resolve `ref` under skill_dir, refusing absolute paths and escapes.
    # Returns the file's text, or "" when it does not resolve.
    if (not skill_dir) or (not ref) { return ""; }
    r = str(ref).strip();
    if r.startswith("/") or r.startswith("~") or (".." in r) { return ""; }
    p = os.path.normpath(os.path.join(skill_dir, r));
    rootdir = str(os.path.realpath(skill_dir));
    if not str(os.path.realpath(p)).startswith(rootdir) { return ""; }
    if not os.path.isfile(p) { return ""; }
    try {
        with open(p, "r", errors="replace") as f { data = str(f.read()); }
    } except Exception { return ""; }
    return data if len(data) <= _INLINE_CAP else (data[:_INLINE_CAP] + "\n... [truncated]");
}

def _carries(ir: any) -> dict {
    wlk = ir.get("walker") if isinstance(ir.get("walker"), dict) else {};
    c = wlk.get("carries");
    return c if isinstance(c, dict) else {};
}

def _knowledge(ir: any) -> dict {
    k = ir.get("knowledge");
    return k if isinstance(k, dict) else {};
}

def _fix_lanes(ir: any, skill_dir: str) -> list {
    fixes: list = [];
    carries = _carries(ir);
    kn = _knowledge(ir);
    lanes: list = list(carries) + list(kn) + ["task"];
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        nid = str(nd.get("id"));
        for rd in list(nd.get("reads") or []) {
            r = str(rd);
            if r in lanes { continue; }
            content = _skill_file(skill_dir, r);
            if content {
                if not isinstance(ir.get("knowledge"), dict) { ir["knowledge"] = {}; }
                kn = ir["knowledge"];
                prev: any = kn.get(r);
                entry: dict = dict(prev) if isinstance(prev, dict) else {};
                entry["body"] = content;
                ro: list = list(entry.get("resident_on") or []);
                if nid not in ro { ro.append(nid); }
                entry["resident_on"] = ro;
                kn[r] = entry;
                lanes.append(r);
                fixes.append("lane: read '" + r + "' resolved from the skill directory — inlined "
                             + str(len(content)) + " chars as knowledge resident on '" + nid + "'");
            } else {
                if "walker" not in ir { ir["walker"] = {"carries": {}}; }
                if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
                ir["walker"]["carries"][r] = {"type": "str", "role": "input"};
                carries = _carries(ir);
                lanes.append(r);
                fixes.append("lane: minted input carry '" + r + "' (node '" + nid
                             + "' read it but no lane existed — it now seeds from the task input)");
            }
        }
        for wr in list(nd.get("writes") or []) {
            w = str(wr);
            if w in carries { continue; }
            if "walker" not in ir { ir["walker"] = {"carries": {}}; }
            if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
            ir["walker"]["carries"][w] = {"type": "str", "produced_by": nid};
            carries = _carries(ir);
            fixes.append("lane: declared carry '" + w + "' (node '" + nid
                         + "' writes it but the walker never declared the lane)");
        }
    }
    return fixes;
}

def _pointer_ref(text: str) -> str {
    # The file a pointer-shaped body points at ("See FORMS.md" -> FORMS.md).
    t = str(text).strip();
    if len(t) > 200 { return ""; }
    low = t.casefold();
    smells = False;
    for p in _POINTER_PREFIXES {
        if low.startswith(str(p)) { smells = True; break; }
    }
    if not smells { return ""; }
    m = re.search(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9]{1,5}", t);
    return str(m.group(0)) if m else "";
}

def _fix_pointers(ir: any, skill_dir: str) -> list {
    fixes: list = [];
    kn = _knowledge(ir);
    for key in list(kn) {
        entry = kn[key];
        body = "";
        if isinstance(entry, dict) { body = str(entry.get("body") or ""); }
        elif isinstance(entry, str) { body = str(entry); }
        else { continue; }
        ref = _pointer_ref(body);
        if not ref { continue; }
        content = _skill_file(skill_dir, ref);
        if not content { continue; }
        if isinstance(entry, dict) {
            entry["doc"] = "inlined from " + ref + " (was: " + body[:80] + ")";
            entry["body"] = content;
        } else {
            kn[key] = {"doc": "inlined from " + ref + " (was: " + body[:80] + ")", "body": content};
        }
        fixes.append("pointer: knowledge '" + str(key) + "' pointed at " + ref
                     + " — embodied " + str(len(content)) + " chars verbatim");
    }
    return fixes;
}

def _served_ids(ir: any) -> list {
    served: list = [];
    tools = ir.get("tools");
    if isinstance(tools, dict) {
        for k in tools {
            t = tools[k];
            if isinstance(t, dict) {
                for sv in list(t.get("serves") or []) { served.append(str(sv)); }
            }
            served.append(str(k));   # a tool named exactly the node id binds 1:1
        }
    }
    return served;
}

def _fix_hollow(ir: any) -> list {
    fixes: list = [];
    served = _served_ids(ir);
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        if str(nd.get("owner", "")).lower() != "code" { continue; }
        if str(nd.get("type", "")).upper() != "CODE" { continue; }
        if str(nd.get("body") or "").strip() { continue; }   # inline body lowers fine
        nid = str(nd.get("id"));
        tn = nd.get("tool");
        if isinstance(tn, list) { tn = tn[0] if tn else None; }
        if (nid in served) or (isinstance(tn, str) and (tn in tools)) { continue; }
        nd["type"] = "GEN-RAW";
        nd["owner"] = "model";
        fixes.append("hollow: code node '" + nid + "' had no tool and would lower to a no-op marker"
                     + " — re-owned to a model slot (degraded from code gate; the step now executes)");
    }
    return fixes;
}

def autofix_ir(ir_text: str, skill_dir: str = "") -> dict {
    # The driver: load once, run every pass, dump once. Returns the (possibly
    # unchanged) IR text + fix notes; the CALLER re-gates through G4.
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return {"ir_text": ir_text, "fixes": []}; }
    if not isinstance(ir, dict) or (not ir.get("nodes")) { return {"ir_text": ir_text, "fixes": []}; }
    fixes: list = [];
    for f in _fix_lanes(ir, skill_dir) { fixes.append(f); }
    for f in _fix_pointers(ir, skill_dir) { fixes.append(f); }
    for f in _fix_hollow(ir) { fixes.append(f); }
    if not fixes { return {"ir_text": ir_text, "fixes": []}; }
    return {"ir_text": _dump_ir(ir), "fixes": fixes};
}

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
  a station the walker visits that does nothing. Make it a GENERATE model
  slot: the degraded-but-real realization (the step is at least executed)
  beats the hollow one (silently skipped), and the note says exactly what was
  traded.
"""

import os;
import re;
import yaml;
import from src.compiler.mechanical.compiler { _load_ir, transpile_ir, _parse_sig, _pathish_carry, _py_ok, is_path_param }
import from src.compiler.mechanical.envbind { scraped_path_inputs, path_ext_hint, _unguarded_read_tools }
import from src.compiler.mechanical.toolib { builtin }
import from src.sigil_agir_yaml { dump_agir, strict_parses }

glob _POINTER_PREFIXES: list[any] = ["see ", "refer to ", "read ", "as described in ",
                                "per the skill", "from the skill", "consult "];
glob _INLINE_CAP: int = 120000;

def _dump_ir(ir: any) -> str {
    # Kept as a local name so the pass bodies read unchanged; the serialization
    # itself lives beside load_agir, which decides what "parses" in the first place.
    return dump_agir(ir);
}

def canonicalize_ir(ir_text: str, name: str) -> str {
    # Authored AG-IR is TEXT, and text can be malformed. `load_agir` relaxes a
    # document that is not strict YAML — a column-aligned key that swallowed the
    # space after its colon, a `list[str]` whose `[` opens a flow sequence YAML
    # never sees closed — and it never raises, so nothing downstream ever says
    # the artifact is not actually YAML. That artifact is the skill's persisted
    # provenance: what a human opens when a compile goes wrong, and what
    # `sigil gate` and `sigil relearn` re-read.
    #
    # Fires ONLY when the document needed the relaxer, so a well-formed IR is
    # untouched and the blast radius is exactly the defect class. Returns ""
    # when it does not fire — the same sentinel fold_untraced_prohibitions uses.
    if strict_parses(ir_text) { return ""; }
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return ""; }
    if (not isinstance(ir, dict)) or (not ir.get("nodes")) { return ""; }
    out = str(dump_agir(ir));
    # Re-emitting must actually fix it. A canonical form that STILL needs the
    # relaxer means the document is broken in a way this does not understand.
    if (not out.strip()) or (not strict_parses(out)) { return ""; }
    # And it must change the document's FORM without changing what it lowers to.
    # The relaxer already understood this text, so an identical module is the
    # proof that the canonical reading IS the reading the compiler was going to
    # use. If they differ, the round-trip reinterpreted something, and the
    # original text is worth more to a human than a silently changed meaning.
    try {
        if str(transpile_ir(ir_text, name)) != str(transpile_ir(out, name)) { return ""; }
    } except Exception { return ""; }
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

def _carries(ir: any) -> dict[str, any] {
    wlk = ir.get("walker") if isinstance(ir.get("walker"), dict) else {};
    c = wlk.get("carries");
    return c if isinstance(c, dict) else {};
}

def _knowledge(ir: any) -> dict[str, any] {
    k = ir.get("knowledge");
    return k if isinstance(k, dict) else {};
}

def _fix_lanes(ir: any, skill_dir: str) -> list[any] {
    fixes: list = [];
    carries = _carries(ir);
    kn = _knowledge(ir);
    lanes: list[any] = list(carries) + list(kn) + ["task"];
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
                `entry: dict[str, any] = dict(prev) if isinstance(prev, dict) else {};
                `entry["body"] = content;
                ro: list[any] = list(`entry.get("resident_on") or []);
                if nid not in ro { ro.append(nid); }
                `entry["resident_on"] = ro;
                kn[r] = `entry;
                lanes.append(r);
                fixes.append("lane: read '" + r + "' resolved from the skill directory — inlined "
                             + str(len(content)) + " chars as knowledge resident on '" + nid + "'");
            } else {
                # A read ref can be path-shaped ('./canvas-fonts') or otherwise
                # not a valid identifier — minting a carry under that raw name
                # emits `spawn Agent(./canvas-fonts=task)`, a syntax error that
                # breaks the whole module (caught live: canvas-design). Sanitize
                # to a valid identifier and REWRITE the node's read to match, so
                # the lane, the read, and every lowering site all agree.
                cn = re.sub(r"[^0-9a-zA-Z_]", "_", r);
                # collapse leading underscores: a carry named '__x' (from
                # './x' -> '__x') is Python name-mangled inside the walker
                # class, so the spawn kwarg __x=task is rejected by __init__
                # (caught live: canvas-design's './canvas-fonts' -> '__canvas_fonts').
                cn = re.sub(r"^_+", "", cn);
                if re.match(r"^[0-9]", cn) { cn = "c_" + cn; }
                if not cn { cn = "minted_input"; }
                if cn != r {
                    nd["reads"] = [(cn if str(x) == r else x) for x in list(nd.get("reads") or [])];
                }
                if "walker" not in ir { ir["walker"] = {"carries": {}}; }
                if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
                ir["walker"]["carries"][cn] = {"type": "str", "role": "input"};
                carries = _carries(ir);
                lanes.append(cn);
                fixes.append("lane: minted input carry '" + cn + "' (node '" + nid
                             + "' read '" + r + "' but no lane existed — it now seeds from the task input)");
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

def _fix_pointers(ir: any, skill_dir: str) -> list[any] {
    fixes: list = [];
    kn = _knowledge(ir);
    for key in list(kn) {
        `entry = kn[key];
        body = "";
        if isinstance(`entry, dict) { body = str(`entry.get("body") or ""); }
        elif isinstance(`entry, str) { body = str(`entry); }
        else { continue; }
        ref = _pointer_ref(body);
        if not ref { continue; }
        content = _skill_file(skill_dir, ref);
        if not content { continue; }
        if isinstance(`entry, dict) {
            `entry["doc"] = "inlined from " + ref + " (was: " + body[:80] + ")";
            `entry["body"] = content;
        } else {
            kn[key] = {"doc": "inlined from " + ref + " (was: " + body[:80] + ")", "body": content};
        }
        fixes.append("pointer: knowledge '" + str(key) + "' pointed at " + ref
                     + " — embodied " + str(len(content)) + " chars verbatim");
    }
    return fixes;
}

def _served_ids(ir: any) -> list[any] {
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

def _fix_hollow(ir: any) -> list[any] {
    fixes: list = [];
    served = _served_ids(ir);
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        if str(nd.get("owner", "")).lower() != "code" { continue; }
        if str(nd.get("type", "")).upper() != "COMPUTE" { continue; }
        if str(nd.get("body") or "").strip() { continue; }   # inline body lowers fine
        nid = str(nd.get("id"));
        tn = nd.get("tool");
        if isinstance(tn, list) { tn = tn[0] if tn else None; }
        if (nid in served) or (isinstance(tn, str) and (tn in tools)) { continue; }
        nd["type"] = "GENERATE";
        nd["owner"] = "model";
        fixes.append("hollow: code node '" + nid + "' had no tool and would lower to a no-op marker"
                     + " — made a GENERATE (degraded from an executable COMPUTE; the step now executes)");
    }
    return fixes;
}

# ---------------------------------------------------------------------------
# INPUTS: a path mined out of the task prose is not an input surface.
# ---------------------------------------------------------------------------
# The lowering already turns a role:input carry into a `--flag`, an MCP schema
# property and an `_EJ_PARAM_KEYS` entry — the whole structured-call surface.
# What was missing is the DECLARATION: when the lift authors a SENSE tool that
# regex-mines `template_path` / `data_path` / `output_path` out of the task
# sentence, the artifact has no parameter surface at all, and which file gets
# opened depends on the caller's phrasing (offer-letter-generator opened its own
# OUTPUT as the template and failed every cell). This pass lifts each mined name
# to a role:input carry and threads it into the tool, keeping the scrape as the
# fallback — so naming the file is possible, and not naming it is unchanged.
def _sig_add(sig: str, names: list[any]) -> str {
    s = str(sig);
    i = s.find("(");
    j = s.find(")");
    if (i < 0) or (j <= i) { return s; }
    inner = s[i + 1:j].strip();
    add = ", ".join([str(n) for n in names]);
    return s[:i + 1] + ((inner + ", " + add) if inner else add) + s[j:];
}

def _stmt_ends(lines: list[any]) -> list[any] {
    # True at each index that CLOSES a Python statement. An assignment can span
    # lines — `out_img = os.path.join(os.path.dirname(img) or ".",\n
    # "validation_page_%d.png" % n)` — and appending an override after the FIRST
    # of them lands inside the call's argument list. The module still lowers and
    # `jac check` still passes; the artifact raises SyntaxError only when the
    # walker reaches that tool, which is every run (caught live: pdf,
    # create_validation_images, 0/5 with the agent retrying 12 times).
    import re;
    out: list = [];
    depth: int = 0;
    for ln in lines {
        s = str(ln);
        # strings first, so brackets and '#' inside them never count
        s = re.sub(r"\'\'\'.*?\'\'\'|\"\"\".*?\"\"\"", "", s);
        s = re.sub(r"\'(?:\\.|[^\'\\])*\'|\"(?:\\.|[^\"\\])*\"", "", s);
        s = s.split("#")[0];
        for ch in s {
            if ch in "([{" { depth += 1; }
            elif ch in ")]}" { depth -= 1; }
        }
        if depth < 0 { depth = 0; }
        out.append((depth == 0) and (not str(ln).rstrip().endswith("\\")));
    }
    return out;
}

def _in_loop(lines: list[any], idx: int) -> bool {
    # Is this line inside a `for`/`while` block? A destination bound in a loop is
    # re-bound every iteration: pdf's create_validation_images writes ONE image
    # per page, so pointing the caller's output_path at it would send every page
    # to the same file. Such a tool is not a deliverable writer at all.
    import re;
    base = str(lines[idx]);
    cur: int = len(base) - len(base.lstrip());
    k: int = idx - 1;
    while k >= 0 {
        ln = str(lines[k]);
        if ln.strip() {
            ind: int = len(ln) - len(ln.lstrip());
            if ind < cur {
                if re.match(r"^\s*(?:for|while)\b", ln) { return True; }
                cur = ind;
            }
        }
        k -= 1;
    }
    return False;
}

def _injected_ok(before: str, after: str) -> str {
    # A mechanical pass must never leave a body that does not parse. The gates
    # read the IR, not the tool bodies, so a broken injection ships silently.
    if not str(after).strip() { return ""; }
    if _py_ok(str(before)) and (not _py_ok(str(after))) { return ""; }
    return str(after);
}

def _lift_tool_body(body: str, names: list[any]) -> str {
    # widen the inner def, capture the caller-supplied values, and let each
    # mined assignment be overridden by the value the caller actually passed.
    # Returns "" when the body is not the shape this can rewrite safely.
    import re;
    lines = str(body).split("\n");
    ends = _stmt_ends(lines);
    out: list = [];
    done: list = [];
    pend: list = [];
    injected = False;
    for idx in range(len(lines)) {
        ln = str(lines[idx]);
        dm = re.match(r"^(\s*)def\s+\w+\s*\(.*\)\s*(?:->[^:]*)?:\s*$", ln);
        if (not injected) and dm {
            i = ln.find("(");
            j = ln.rfind(")");
            if (i < 0) or (j <= i) { return ""; }
            inner = ln[i + 1:j];
            add = ", ".join([(str(n) + ": str = \"\"") for n in names]);
            out.append(ln[:i + 1] + ((inner + ", " + add) if inner.strip() else add) + ln[j:]);
            ind = str(dm.group(1)) + "    ";
            for n in names { out.append(ind + "_sigil_in_" + str(n) + " = " + str(n) + " or \"\""); }
            injected = True;
            continue;
        }
        out.append(ln);
        am = re.match(r"^(\s*)([a-z_]\w*)\s*=[^=]", ln);
        if am {
            n2 = str(am.group(2));
            if (n2 in names) and (n2 not in done) {
                pend.append(str(am.group(1)) + n2 + " = _sigil_in_" + n2 + " or " + n2);
                done.append(n2);
            }
        }
        # …but only after the assignment's own statement has CLOSED: a multi-line
        # call would otherwise take the override into its argument list
        if pend and ends[idx] {
            for pl in pend { out.append(str(pl)); }
            pend = [];
        }
    }
    if (not injected) or (len(done) != len(names)) { return ""; }
    return _injected_ok(body, "\n".join(out));
}

# What a minted input actually HOLDS, in the caller's terms. These docs become
# the MCP inputSchema property descriptions (_EJ_PARAM_DOCS) and the only thing
# a calling agent reads before it binds a value. "caller-supplied source
# location" describes the PROVENANCE of the parameter, not its content, so the
# agent was left matching on the parameter name: energy-ac handed `network_path`
# the maths write-up with network.json sitting beside it, in all 32 calls.
# The consuming tool and the file type the body was guessing at are both in
# scope at mint time; say them.
def _io_doc(is_out: bool, tool: str, body: str, local: str, tool_doc: str = "") -> str {
    exts = path_ext_hint(str(body), str(local));
    kind = (" or ".join([str(e) for e in exts]) + " ") if exts else "";
    tn = str(tool).strip();
    # The consuming tool's OWN doc is the sharpest thing available and was going
    # unused. Two inputs of the same shape are otherwise indistinguishable:
    # power-flow advertised `network_path` and `size_path` with byte-identical
    # descriptions, and the agent handed the solver the file it meant to measure.
    td = " ".join(str(tool_doc).split());
    if len(td) > 150 { td = td[:150].rsplit(" ", 1)[0] + "…"; }
    td = td.rstrip(" .");     # it is parenthesised into a sentence of ours
    # The literal 'caller-supplied' is a PROVENANCE MARKER as well as prose:
    # it is how a minted lane is told from an authored one when an IR is reset
    # to its authored shape for a re-lower. Keep it in every branch, lowercase.
    if is_out {
        d = "Path where this run should WRITE the " + kind + "deliverable";
        if tn { d += " produced by '" + tn + "'"; }
        if td { d += " (" + td + ")"; }
        return (d + ". Absolute path preferred. Optional (caller-supplied);"
                + " defaults to a name derived from the task.");
    }
    d = "Path to the " + kind + "file this run READS";
    if tn { d += ", the one '" + tn + "' opens"; }
    if td { d += " (" + tn + ": " + td + ")"; }
    return (d + ". It must be that file itself, not a document that describes or"
            + " refers to it. Optional (caller-supplied); defaults to a filename"
            + " named in the task.");
}

def _fix_task_scraped_inputs(ir: any) -> list[any] {
    fixes: list = [];
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    if not tools { return fixes; }
    mined = scraped_path_inputs(tools);
    if not mined { return fixes; }
    for tn in list(mined) {
        t = tools.get(tn);
        if not isinstance(t, dict) { continue; }
        carries = _carries(ir);
        want: list = [];
        for n in list(mined[tn]) {
            c = carries.get(str(n)) if isinstance(carries, dict) else None;
            # already a lane (input or produced upstream): not ours to mint
            if isinstance(c, dict) { continue; }
            want.append(str(n));
        }
        if not want { continue; }
        nb = _lift_tool_body(str(t.get("body") or ""), want);
        if not nb { continue; }
        t["body"] = nb;
        t["sig"] = _sig_add(str(t.get("sig") or ""), want);
        if "walker" not in ir { ir["walker"] = {"carries": {}}; }
        if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
        for n2 in want {
            # `path`, not `str`: a str input the ENTRY node reads inherits the whole
            # task sentence as its default (compiler.jac's task-text fallback), which
            # is exactly the prose-grounding this pass exists to replace.
            ir["walker"]["carries"][n2] = {"type": "path", "role": "input",
                "doc": _io_doc(False, str(tn), str(t.get("body") or ""), n2,
                                 str(t.get("doc") or ""))};
        }
        for nd in list(ir.get("nodes") or []) {
            if not isinstance(nd, dict) { continue; }
            tl = nd.get("tool");
            tls: list[any] = [str(x) for x in (tl if isinstance(tl, list) else ([tl] if tl else []))];
            if (str(nd.get("id")) != str(tn)) and (str(tn) not in tls) { continue; }
            rd: list[any] = [str(x) for x in list(nd.get("reads") or [])];
            for n3 in want {
                if n3 not in rd { rd.append(n3); }
            }
            nd["reads"] = rd;
        }
        fixes.append("inputs: tool '" + str(tn) + "' mined "
                     + ", ".join([("'" + str(n4) + "'") for n4 in want])
                     + " out of the task prose — lifted to role:input carr"
                     + ("ies" if len(want) > 1 else "y")
                     + " so a caller can name them (--" + str(want[0])
                     + "=…, MCP schema, _EJ_PARAM_KEYS); the scrape stays as the fallback");
    }
    return fixes;
}

def _input_name_for(nd: dict[str, any], tname: str, carries: any) -> str {
    # NAME the minted input after what it holds. A generic `input_path` tells the
    # caller nothing, and a model that cannot tell which file is meant guesses:
    # power-flow-data was handed `input_path=math-model.md` — the maths write-up —
    # 32 times while `network.json` sat beside it, and the cell scored 0/24. The
    # same agent bound docx's `template_file`/`data_file` correctly first try.
    # The carry the tool PRODUCES says what it consumed, so name it from that.
    import re;
    cands: list = [];
    _w: list[any] = [];
    if isinstance(nd, dict) { _w = list(nd.get("writes") or []); }
    for w in _w {
        stem = re.sub(r"_(path|file|dir|json|md)$", "", str(w));
        if stem { cands.append(stem); }
    }
    m = re.search(r"(?:load|read|open|parse|resolve|fetch|inspect|probe|summarize)_(\w+)", str(tname));
    if m { cands.append(re.sub(r"_(path|file|data|json)$", "", str(m.group(1)))); }
    for c in cands {
        for sfx in ["_path", "_file"] {
            n = str(c) + sfx;
            if n not in carries { return n; }
        }
    }
    return "input_path";
}

def _short_circuit_body(body: str, name: str) -> str {
    # widen the inner def and let a caller-supplied value return immediately —
    # everything below it, including the prose search, stays exactly as authored.
    import re;
    lines = str(body).split("\n");
    out: list = [];
    injected = False;
    for ln in lines {
        dm = re.match(r"^(\s*)def\s+\w+\s*\(.*\)\s*(?:->[^:]*)?:\s*$", ln);
        if (not injected) and dm {
            i = ln.find("(");
            j = ln.rfind(")");
            if (i < 0) or (j <= i) { return ""; }
            inner = ln[i + 1:j];
            add = str(name) + ": str = \"\"";
            out.append(ln[:i + 1] + ((inner + ", " + add) if inner.strip() else add) + ln[j:]);
            out.append(str(dm.group(1)) + "    if " + str(name) + ": return " + str(name));
            injected = True;
            continue;
        }
        out.append(ln);
    }
    if not injected { return ""; }
    return "\n".join(out);
}

def _fix_resolver_inputs(ir: any) -> list[any] {
    # The third shape of the same defect: a node whose whole job is to turn the
    # task sentence into a location — `resolve_pdf_path(task) -> str`, returning
    # the first .pdf the prose names and the literal "input.pdf" when it names
    # none. The location it produces is an INPUT the caller must be able to give,
    # so the resolver short-circuits on a supplied value and keeps its search as
    # the fallback. Guarded narrowly: reads only the task, writes exactly one
    # pathish carry, and returns a scalar.
    fixes: list = [];
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    if not tools { return fixes; }
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        reads: list[any] = [str(x) for x in list(nd.get("reads") or [])];
        writes: list[any] = [str(x) for x in list(nd.get("writes") or [])];
        if (reads != ["task"]) or (len(writes) != 1) { continue; }
        if not _pathish_carry(writes[0]) { continue; }
        tn = nd.get("tool");
        if isinstance(tn, list) { tn = tn[0] if tn else None; }
        tname = str(tn) if isinstance(tn, str) else "";
        if (not tname) or (tname not in tools) { continue; }
        t = tools[tname];
        if not isinstance(t, dict) { continue; }
        parsed = _parse_sig(t.get("sig"));
        if [str(p) for p in list(parsed[0])] != ["task"] { continue; }
        if str(parsed[1]).strip().lower() not in ["str", "path"] { continue; }
        carries = _carries(ir);
        cname = _input_name_for(nd, tname, carries);
        if cname in carries { continue; }
        nb = _short_circuit_body(str(t.get("body") or ""), cname);
        if not nb { continue; }
        t["body"] = nb;
        t["sig"] = _sig_add(str(t.get("sig") or ""), [cname]);
        if "walker" not in ir { ir["walker"] = {"carries": {}}; }
        if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
        ir["walker"]["carries"][cname] = {"type": "path", "role": "input",
            "doc": _io_doc(False, tname, str(t.get("body") or ""), writes[0],
                             str(t.get("doc") or ""))};
        reads.append(cname);
        nd["reads"] = reads;
        fixes.append("inputs: node '" + str(nd.get("id")) + "' resolves '" + str(writes[0])
                     + "' out of the task prose — declared '" + cname + "' as a role:input carry"
                     + " so the caller can name the file (--" + cname
                     + "=…, MCP schema, _EJ_PARAM_KEYS); the prose search stays as the fallback");
    }
    return fixes;
}

def _lift_output_body(body: str, local: str, param: str) -> str {
    # widen the inner def with `param`, and let a caller-supplied destination
    # override the FIRST assignment of the derived local. The derivation stays
    # as the fallback, so an unnamed call behaves exactly as before.
    import re;
    lines = str(body).split("\n");
    ends = _stmt_ends(lines);
    out: list = [];
    injected = False;
    done = False;
    pend: str = "";
    for idx in range(len(lines)) {
        ln = str(lines[idx]);
        dm = re.match(r"^(\s*)def\s+\w+\s*\(.*\)\s*(?:->[^:]*)?:\s*$", ln);
        if (not injected) and dm {
            i = ln.find("(");
            j = ln.rfind(")");
            if (i < 0) or (j <= i) { return ""; }
            inner = ln[i + 1:j];
            add = str(param) + ": str = \"\"";
            out.append(ln[:i + 1] + ((inner + ", " + add) if inner.strip() else add) + ln[j:]);
            injected = True;
            continue;
        }
        out.append(ln);
        am = re.match(r"^(\s*)([a-z_]\w*)\s*=[^=]", ln);
        if (not done) and (not pend) and am and (str(am.group(2)) == str(local)) {
            # a destination re-bound on every iteration is not a deliverable path
            if _in_loop(lines, idx) { continue; }
            pend = str(am.group(1)) + str(local) + " = " + str(param) + " or " + str(local);
        }
        # emit the override only once the statement it overrides has CLOSED
        if pend and ends[idx] {
            out.append(pend);
            pend = "";
            done = True;
        }
    }
    if (not injected) or (not done) { return ""; }
    return _injected_ok(body, "\n".join(out));
}

def _consumed_downstream(ir: any, tname: str) -> bool {
    # Does this tool's node write a carry that ANOTHER node reads? Then what it
    # writes is an intermediate, not the deliverable, and it must keep its own
    # derived filename. Binding the caller's output_path to it too made the pdf
    # artifact write field_values.json TO sc100-filled.pdf and then hand that
    # file to the fill script as its values file — the deliverable was a 2KB
    # copy of the tool's own JSON, and the verifier found no text in it.
    nodes: list[any] = [n for n in list(ir.get("nodes") or []) if isinstance(n, dict)];
    mine: list = [];
    for nd in nodes {
        tl = nd.get("tool");
        tls: list[any] = [str(x) for x in (tl if isinstance(tl, list) else ([tl] if tl else []))];
        if (str(nd.get("id")) == str(tname)) or (str(tname) in tls) {
            for w in list(nd.get("writes") or []) { mine.append(str(w)); }
        }
    }
    if not mine { return False; }
    for nd2 in nodes {
        tl2 = nd2.get("tool");
        tls2: list[any] = [str(x) for x in (tl2 if isinstance(tl2, list) else ([tl2] if tl2 else []))];
        if (str(nd2.get("id")) == str(tname)) or (str(tname) in tls2) { continue; }
        for r in list(nd2.get("reads") or []) {
            if str(r) in mine { return True; }
        }
    }
    return False;
}

def _fix_derived_outputs(ir: any) -> list[any] {
    # The output twin of input provenance. An artifact that DERIVES the file it
    # delivers — `out_pdf = os.path.splitext(pdf_path)[0] + "_filled.pdf"` — writes
    # to a name only it knows: the caller asked for /root/sc100-filled.pdf and got
    # /root/sc100-blank_filled.pdf, so the verifier found nothing and the tool
    # reported success (caught live: pdf, court-form-filling, 0/5; the same
    # "output file not found" ended docx and xlsx). A deliverable's destination is
    # an INPUT. Declare `output_path`, keep the derivation as the fallback.
    import re;
    fixes: list = [];
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    if not tools { return fixes; }
    carries = _carries(ir);
    # an already-declared destination means the author (or an earlier run) named
    # it: nothing to lift, and re-lifting would fight that decision
    if "output_path" in carries { return fixes; }
    writes_re = re.compile(r"\.save\s*\(|open\s*\([^)]*[\"\']w|to_excel\s*\(|to_csv\s*\(|savefig\s*\(|subprocess\.run\s*\(");
    deriv_re = re.compile(r"(?m)^[ \t]*([a-z_]\w*)[ \t]*=[ \t]*(.*(?:splitext|os\.path\.join|\+[ \t]*[\"\'][\w./-]*\.[A-Za-z0-9]{1,5}[\"\']|[\"\'][\w./-]+\.[A-Za-z0-9]{1,5}[\"\']).*)$");
    # WHICH tool holds the deliverable matters as much as the lift itself: taking
    # the first writer in dict order pointed the caller's `/root/sc100-filled.pdf`
    # at an intermediate field-info JSON (pdf, v2, still 0/5 — a misdirected
    # destination is worse than a derived one). Walk the pipeline BACKWARDS and
    # prefer ACT nodes: the deliverable is written by the last writer before the
    # terminal, not by the first tool that happens to open a file.
    ordered: list[any] = [];
    for nd0 in list(ir.get("nodes") or []) {
        if not isinstance(nd0, dict) { continue; }
        tl0 = nd0.get("tool");
        if isinstance(tl0, list) { tl0 = tl0[0] if tl0 else None; }
        t0 = str(tl0) if isinstance(tl0, str) else str(nd0.get("id"));
        if t0 in tools { ordered.append([t0, str(nd0.get("type", "")).upper()]); }
    }
    ordered.reverse();
    act_names: list[any] = [str(x[0]) for x in ordered if str(x[1]).startswith("ACT")];
    names: list[any] = list(act_names);
    for x2 in ordered {
        if str(x2[0]) not in names { names.append(str(x2[0])); }
    }
    for tn0 in list(tools) {
        if str(tn0) not in names { names.append(str(tn0)); }
    }
    # A ROUTE'd pipeline delivers from more than one place — a fillable PDF is
    # written by one tool and a flattened one by another — so EVERY deliverable
    # writer takes the same `output_path`. Lifting only the first left the other
    # branch writing a name the caller never chose (pdf, still 0/5 after the
    # destination fix). Non-ACT writers stay first-match-only: those are
    # intermediates, and pointing the caller's file at one is worse than a
    # derived name.
    for tn in names {
        t: dict[str, any] = {};
        _t0 = tools.get(tn);
        if not isinstance(_t0, dict) { continue; }
        t = _t0;
        # an intermediate's file is read by the next node: never the deliverable
        if _consumed_downstream(ir, str(tn)) { continue; }
        body = str(t.get("body") or "");
        if not body.strip() { continue; }
        if not writes_re.search(body) { continue; }
        params = [str(p) for p in _parse_sig(t.get("sig"))[0]];
        local: str = "";
        for mm in deriv_re.finditer(body) {
            nm = str(mm.group(1));
            if (not _pathish_carry(nm)) and (not nm.startswith("out")) { continue; }
            if nm in params { continue; }          # already a parameter: nothing to lift
            local = nm;
            break;
        }
        if not local { continue; }
        nb = _lift_output_body(body, local, "output_path");
        if not nb { continue; }
        t["body"] = nb;
        t["sig"] = _sig_add(str(t.get("sig") or ""), ["output_path"]);
        if "walker" not in ir { ir["walker"] = {"carries": {}}; }
        if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
        # `names` puts the ACT deliverable writers first, so the FIRST tool to
        # claim output_path is the one whose file the caller actually wants
        # named. Later writers share the lane but must not re-describe it: pdf's
        # advertised destination ended up "the .json produced by
        # extract_form_field_info", an intermediate, which is worse than silence.
        if "output_path" not in ir["walker"]["carries"] {
            ir["walker"]["carries"]["output_path"] = {"type": "path", "role": "input",
                "doc": _io_doc(True, str(tn), body, local, str(t.get("doc") or ""))};
        }
        for nd in list(ir.get("nodes") or []) {
            if not isinstance(nd, dict) { continue; }
            tl = nd.get("tool");
            tls: list[any] = [str(x) for x in (tl if isinstance(tl, list) else ([tl] if tl else []))];
            if (str(nd.get("id")) != str(tn)) and (str(tn) not in tls) { continue; }
            rd: list[any] = [str(x) for x in list(nd.get("reads") or [])];
            if "output_path" not in rd { rd.append("output_path"); }
            nd["reads"] = rd;
        }
        fixes.append("outputs: tool '" + str(tn) + "' derived its deliverable's path ('" + local
                     + "') instead of taking one — declared 'output_path' as a role:input carry so the"
                     + " caller can say where the file goes (--output_path=…, MCP schema,"
                     + " _EJ_PARAM_KEYS); the derived name stays as the fallback");
        if str(tn) not in act_names { break; }   # intermediates: first match only
    }
    return fixes;
}

glob _PATH_PARAM_NAMES: list[any] = ["path", "out", "dest", "outfile", "filename", "file",
    "out_path", "output_path", "outpath", "target", "target_path", "dest_path",
    "in_path", "input_path", "src", "source_path"];

def _fix_pathish_params(ir: any) -> list[any] {
    # The other half of the input surface: a tool whose signature already NAMES a
    # location (`load_network(path)`, `write_file(out_path)`) but which the walker
    # carries nowhere. The lowering used to bind those to `_inname(self.task)` /
    # `_outname(self.task, …)` — the filename mined from the task sentence — so
    # again the caller could not name the file. Declare the location as an input
    # carry; the binder keeps the prose extraction as the fallback, so an unnamed
    # call behaves exactly as before and a named one is now possible.
    fixes: list = [];
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    if not tools { return fixes; }
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        nid = str(nd.get("id"));
        tn = nd.get("tool");
        if isinstance(tn, list) { tn = tn[0] if tn else None; }
        tname = str(tn) if isinstance(tn, str) else (nid if nid in tools else "");
        if (not tname) or (tname not in tools) { continue; }
        t = tools[tname];
        if not isinstance(t, dict) { continue; }
        # A BUILTIN carries no `sig` in the IR — `_normalize_builtins` fills it in
        # at LOWERING, long after this pass runs. So a skill whose only file I/O
        # goes through `read_file`/`write_file` showed zero params here and got
        # no call surface at all: d3-visualization shipped _EJ_PARAM_KEYS = [] and
        # read whatever filename the task sentence happened to mention.
        _sig = t.get("sig");
        if not str(_sig or "").strip() {
            _bi = builtin(tname);
            if isinstance(_bi, dict) { _sig = _bi.get("sig"); }
        }
        params = _parse_sig(_sig)[0];
        carries = _carries(ir);
        reads: list[any] = [str(x) for x in list(nd.get("reads") or [])];
        # a pathish read carry already feeds the binder's role rung
        served = False;
        for r in reads {
            if (r in carries) and _pathish_carry(r) { served = True; }
        }
        for p in list(params) {
            pl = str(p).lower();
            # shape, not just the exact name: ffmpeg calls its locations
            # input_media/output_media and object-counter calls them
            # image_paths — none matched, so neither minted a carry and
            # both shipped _EJ_PARAM_KEYS = [].
            if not is_path_param(pl) { continue; }
            if str(p) in carries { continue; }
            writes = [str(w) for w in list(nd.get("writes") or [])];
            is_out = (str(nd.get("type", "")).upper().startswith("ACT")) and bool(writes);
            # …but a DESTINATION is not served by the source the node reads.
            # Skipping the whole node whenever any pathish read carry existed
            # left docx's `fill_template(template_file, fill_data, path)` with no
            # lane for `path`: the deliverable went to _outname(task), and on a
            # task that named no file that is the literal fallback "out_file.out"
            # — so the caller could not say where the document goes, and the
            # verifier looked for offer_letter_filled.docx and found nothing.
            if served and (not is_out) { continue; }
            cname = "output_path" if is_out else _input_name_for(nd, tname, carries);
            if cname not in carries {
                if "walker" not in ir { ir["walker"] = {"carries": {}}; }
                if not isinstance(ir["walker"].get("carries"), dict) { ir["walker"]["carries"] = {}; }
                ir["walker"]["carries"][cname] = {"type": "path", "role": "input",
                    "doc": _io_doc(is_out, tname, str(t.get("body") or ""), str(p),
                                     str(t.get("doc") or ""))};
            }
            if cname not in reads { reads.append(cname); }
            nd["reads"] = reads;
            fixes.append("inputs: tool '" + tname + "' takes a location ('" + str(p)
                         + "') the walker carried nowhere — declared '" + cname
                         + "' as a role:input carry so the caller can name it"
                         + " (--" + cname + "=…, MCP schema, _EJ_PARAM_KEYS);"
                         + " the task-filename extraction stays as the fallback");
            break;
        }
    }
    return fixes;
}

glob _NEUTRAL_RETURN: dict[str, any] = {"str": "\"\"", "path": "\"\"", "dict": "{}", "list": "[]",
                              "int": "0", "float": "0.0", "bool": "False"};

def _fix_unguarded_reads(ir: any) -> list[any] {
    # An optional input is EMPTY when the caller omits it, and a tool that opens
    # its path argument without checking turns that into a walker-killing
    # exception instead of a branch: power-flow-data raised
    # `FileNotFoundError: ''` ten times from `check_file_size`, whose whole job
    # is an "if needed" size probe. The detector for this shape already exists
    # (_unguarded_read_tools, gate G7); nothing acted on it. Route instead of
    # raise — return the declared type's empty value, which is what "absent"
    # means to every reader downstream.
    import re;
    fixes: list = [];
    tools = ir.get("tools") if isinstance(ir.get("tools"), dict) else {};
    if not tools { return fixes; }
    for tn in list(_unguarded_read_tools(tools)) {
        t = tools.get(str(tn));
        if not isinstance(t, dict) { continue; }
        body = str(t.get("body") or "");
        parsed = _parse_sig(t.get("sig"));
        params: list[any] = [str(p) for p in list(parsed[0])];
        rt = str(parsed[1] or "").strip().lower();
        neutral = str(_NEUTRAL_RETURN.get(rt) or "");
        if not neutral { continue; }          # unknown return type: not ours to invent
        # only a BARE parameter that names a location — an expression could be
        # anything, and guarding the wrong thing is worse than not guarding
        guarded: str = "";
        for p in params {
            if not _pathish_carry(p) { continue; }
            _op: str = str(r"(?<![\w.])(?:open|Presentation|Document|load_workbook|Image\.open|pd\.read_\w+|json\.load|yaml\.safe_load)\s*\(\s*");
            _pat: str = _op + str(re.escape(str(p))) + str(r"\s*[,)]");
            if re.search(_pat, body) {
                guarded = str(p);
                break;
            }
        }
        if not guarded { continue; }
        nb = _guard_body(body, guarded, neutral);
        if not nb { continue; }
        t["body"] = nb;
        fixes.append("inputs: tool '" + str(tn) + "' opened '" + guarded
                     + "' with no not-found route — an omitted optional input"
                     + " raised instead of routing; it now reports absent ("
                     + neutral + ") so the graph can branch");
    }
    return fixes;
}

def _guard_body(body: str, name: str, neutral: str) -> str {
    # insert the route at the top of the inner def, before anything opens it
    import re;
    lines = str(body).split("\n");
    out: list = [];
    injected = False;
    for ln in lines {
        out.append(str(ln));
        dm = re.match(r"^(\s*)def\s+\w+\s*\(.*\)\s*(?:->[^:]*)?:\s*$", str(ln));
        if (not injected) and dm {
            ind = str(dm.group(1)) + "    ";
            # EMPTY only. A non-empty path that does not resolve is a caller
            # error, and raising is what lets the caller correct it: guarding on
            # existence too turned a loud, self-correcting failure into a silent
            # no-op — offer-letter went 3/4 -> 0/4 the first run the agent passed
            # a relative path, producing no document at all instead of an error
            # it would have retried. Routing on absent is only right when the
            # input was genuinely omitted.
            out.append(ind + "if not " + str(name) + ":");
            out.append(ind + "    return " + str(neutral));
            injected = True;
        }
    }
    if not injected { return ""; }
    return _injected_ok(body, "\n".join(out));
}
def autofix_ir(ir_text: str, skill_dir: str = "") -> dict[str, any] {
    # The driver: load once, run every pass, dump once. Returns the (possibly
    # unchanged) IR text + fix notes; the CALLER re-gates through G4.
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return {"ir_text": ir_text, "fixes": []}; }
    if not isinstance(ir, dict) or (not ir.get("nodes")) { return {"ir_text": ir_text, "fixes": []}; }
    fixes: list[any] = [];
    for f in _fix_lanes(ir, skill_dir) { fixes.append(f); }
    for f in _fix_pointers(ir, skill_dir) { fixes.append(f); }
    for f in _fix_hollow(ir) { fixes.append(f); }
    for f in _fix_task_scraped_inputs(ir) { fixes.append(f); }
    for f in _fix_resolver_inputs(ir) { fixes.append(f); }
    for f in _fix_derived_outputs(ir) { fixes.append(f); }
    for f in _fix_pathish_params(ir) { fixes.append(f); }
    # last: it guards the params the passes above just minted
    for f in _fix_unguarded_reads(ir) { fixes.append(f); }
    if not fixes { return {"ir_text": ir_text, "fixes": []}; }
    return {"ir_text": _dump_ir(ir), "fixes": fixes};
}

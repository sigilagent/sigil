"""The Agent Instruction Set vocabulary, and the canonicalization every AG-IR passes.

The AIS is defined by the SIGIL paper (arXiv 2607.27309, §2.2 and §3.1, Table 1):
thirteen opcodes in five classes, where the OPCODE determines execution semantics.

    Semantic      SELECT  EXTRACT  MUTATE  GENERATE       the model produces the result
    Delegated     DELEGATE                                a bounded subtask, orchestration left open
    Executable    COMPUTE  OBSERVE  ACT                   a supplied implementation runs
    Control       BRANCH  LOOP  PARALLEL  CALL            explicit control flow
    Termination   RETURN

Sigil's earlier encoding spelled these differently (GEN-ENUM, SENSE, ROUTE, …) and
let an instruction's execution unit vary independently of its opcode through an
`owner` field — a model-owned ROUTE, a model-owned SENSE. Documents in that form
are still on disk and in persisted skills, so the reader canonicalizes them rather
than rejecting them: names map one-to-one, and the legacy model-owned executable
and control forms are rewritten into the paper's compositions (a model-chosen
branch becomes a SELECT over the successors feeding a BRANCH). After this pass,
`owner` is DERIVED from the opcode and every consumer — the lowering, the gates,
the faithfulness audit, the Observatory — sees one vocabulary.

A leaf module: `re` only, so the reader can import it without a cycle.
"""

import re;

glob AIS_SEMANTIC: list[str] = ["SELECT", "EXTRACT", "MUTATE", "GENERATE"];
glob AIS_DELEGATED: list[str] = ["DELEGATE"];
glob AIS_EXECUTABLE: list[str] = ["COMPUTE", "OBSERVE", "ACT"];
glob AIS_CONTROL: list[str] = ["BRANCH", "LOOP", "PARALLEL", "CALL"];
glob AIS_TERMINATION: list[str] = ["RETURN"];
glob AIS_OPCODES: list[str] = [
    "SELECT", "EXTRACT", "MUTATE", "GENERATE", "DELEGATE",
    "COMPUTE", "OBSERVE", "ACT", "BRANCH", "LOOP", "PARALLEL", "CALL", "RETURN"
];
# Instructions the model executes: their result (semantic) or their internal
# orchestration (delegated) is left to it. Everything else runs as code.
glob AIS_MODEL_OPS: list[str] = ["SELECT", "EXTRACT", "MUTATE", "GENERATE", "DELEGATE"];

# Earlier Sigil mnemonics -> the paper's. CALL is absent on purpose: the legacy CALL
# was a model sub-agent, which the paper calls DELEGATE, while the paper's CALL
# invokes a named procedure. Which one a document means is decided by whether it
# names a `procedure` (see canonicalize_ais).
glob LEGACY_OPCODES: dict[str, str] = {
    "GEN-ENUM": "SELECT", "GEN-FILL": "EXTRACT", "GEN-EDIT": "MUTATE", "GEN-RAW": "GENERATE",
    "SENSE": "OBSERVE", "CODE": "COMPUTE", "ROUTE": "BRANCH", "SPAWN": "PARALLEL",
    "TERMINAL": "RETURN"
};

# Pseudo-tool names an authored `autonomy.tools` list sometimes carries to mean
# "may read" — never a real binding.
glob PSEUDO_TOOLS: list[str] = ["SENSE", "OBSERVE"];

def canonical_opcode(raw: any) -> str {
    # Any spelling of an opcode -> the paper's mnemonic. Unknown stays as written
    # (upper-cased), so the validator can report it rather than have it vanish.
    k = str(raw or "").strip().upper().replace("_", "-");
    if k in LEGACY_OPCODES { return str(LEGACY_OPCODES[k]); }
    return k.replace("-", "_");
}

def opcode_class(op: any) -> str {
    o = canonical_opcode(op);
    if o in AIS_SEMANTIC { return "semantic"; }
    if o in AIS_DELEGATED { return "delegated"; }
    if o in AIS_EXECUTABLE { return "executable"; }
    if o in AIS_CONTROL { return "control"; }
    if o in AIS_TERMINATION { return "termination"; }
    return "";
}

def unit_of(op: any) -> str {
    return "model" if canonical_opcode(op) in AIS_MODEL_OPS else "code";
}

def canonical_surface(surface: any) -> str {
    # A tool's surface: OBSERVE for reads; ACT, or ACT·artifact, for effects.
    s = str(surface or "").strip();
    if s.upper().startswith("SENSE") { return "OBSERVE" + s[5:]; }
    return s;
}

def real_tools(au: any) -> list[str] {
    # The binding names in an `autonomy.tools` list, pseudo-tools dropped.
    tl = au.get("tools") if isinstance(au, dict) else None;
    if not isinstance(tl, list) { return []; }
    return [str(t) for t in tl if str(t).strip() and (str(t).strip().upper() not in PSEUDO_TOOLS)];
}

# ---------------------------------------------------------------------------
# section helpers — every mapping section comes in three spellings (spec §8.1)
# ---------------------------------------------------------------------------

def _section_items(d: any) -> list[any] {
    # [name, spec] pairs for any spelling; entries with no recoverable name are
    # skipped here (the compiler's own reader reports them with a shape message).
    r: list[any] = [];
    if isinstance(d, dict) {
        for k in d { r.append([str(k), d[k]]); }
        return r;
    }
    if not isinstance(d, list) { return r; }
    for e in d {
        if not isinstance(e, dict) { continue; }
        ks = list(e);
        if (len(ks) == 1) and isinstance(e[ks[0]], dict) { r.append([str(ks[0]), e[ks[0]]]); continue; }
        for nk in ["name", "id", "key"] {
            if e.get(nk) { r.append([str(e.get(nk)), e]); break; }
        }
    }
    return r;
}

def _section_names(d: any) -> list[str] {
    return [str(kv[0]) for kv in _section_items(d)];
}

def _section_get(d: any, name: str) -> any {
    for kv in _section_items(d) {
        if str(kv[0]) == name { return kv[1]; }
    }
    return None;
}

def _section_put(owner: dict[str, any], key: str, name: str, spec: dict[str, any]) -> None {
    # Add `name: spec` to owner[key] in whichever spelling that section uses.
    cur = owner.get(key);
    if isinstance(cur, list) {
        ent: dict[str, any] = {"name": name};
        for k in spec { ent[k] = spec[k]; }
        cur.append(ent);
    } elif isinstance(cur, dict) {
        cur[name] = spec;
    } else {
        owner[key] = {name: spec};
    }
}

def _camel(s: any) -> str {
    out = "";
    for p in re.split(r"[^0-9a-zA-Z]+", str(s)) {
        if p { out += str(p).capitalize(); }
    }
    return out;
}

def _ident(s: any) -> str {
    r = str(re.sub(r"[^0-9a-zA-Z_]", "_", str(s)));
    if r and r[0:1].isdigit() { r = "_" + r; }
    return r;
}

def _fresh(base: str, taken: list[str]) -> str {
    # A name not in `taken` (compared by its CamelCase form too, since node ids
    # become archetype names and `a_b` and `a__b` both camel to `AB`).
    camels = [_camel(t) for t in taken];
    cand = base;
    i = 2;
    while (cand in taken) or (_camel(cand) in camels) {
        cand = base + "_" + str(i);
        i += 1;
    }
    return cand;
}

def _tool_bound(ir: dict[str, any], n: dict[str, any]) -> bool {
    # The three binding mechanisms of spec §5.4: the instruction's `tool`, a tool
    # whose `serves` lists it, a tool named like it.
    if str(n.get("tool") or "").strip() { return True; }
    nid = str(n.get("id") or "");
    for kv in _section_items(ir.get("tools")) {
        td = kv[1];
        if str(kv[0]) == nid { return True; }
        if isinstance(td, dict) {
            sv = td.get("serves");
            svl = sv if isinstance(sv, list) else ([sv] if sv else []);
            if nid in [str(x) for x in svl] { return True; }
        }
    }
    return False;
}

def _carries(ir: dict[str, any]) -> any {
    wk = ir.get("walker");
    return wk.get("carries") if isinstance(wk, dict) else None;
}

def _semantic_for_result(ir: dict[str, any], n: dict[str, any]) -> str {
    # The tightest semantic opcode the node's result type admits (spec §4.1).
    types = ir.get("types");
    tname = str(n.get("output") or "").strip();
    if not tname {
        wl = n.get("writes") if isinstance(n.get("writes"), list) else [];
        if wl {
            c = _section_get(_carries(ir), str(wl[0]));
            if isinstance(c, dict) { tname = str(c.get("type") or "").strip(); }
        }
    }
    base = tname.split("[")[0].strip();
    td = _section_get(types, base);
    if isinstance(td, dict) and (str(td.get("kind")) == "enum") { return "SELECT"; }
    if isinstance(td, dict) and (str(td.get("kind")) == "object") { return "EXTRACT"; }
    if base in ["list", "dict"] { return "EXTRACT"; }
    return "GENERATE";
}

def _edges(ir: dict[str, any]) -> list[any] {
    e = ir.get("edges");
    if not isinstance(e, list) { e = []; ir["edges"] = e; }
    return e;
}

# ---------------------------------------------------------------------------
# the rewrite
# ---------------------------------------------------------------------------

def _split_choice(ir: dict[str, any], n: dict[str, any], writes_first: bool, notes: list[str]) -> list[dict[str, any]] {
    # A model-chosen branch -> SELECT over the successors, then a code BRANCH.
    # Returns the instructions to insert after `n` (which keeps its id, so every
    # edge INTO the region still lands on it).
    nid = str(n.get("id"));
    nodes: list[any] = ir.get("nodes") or [];
    taken = [str(x.get("id")) for x in nodes if isinstance(x, dict)];
    edges = _edges(ir);
    outs = [e for e in edges if isinstance(e, dict) and (str(e.get("from")) == nid)];
    nidx: dict[str, any] = {};
    for x in nodes { if isinstance(x, dict) { nidx[str(x.get("id"))] = x; } }

    types = ir.get("types");
    type_names = _section_names(types);
    all_members: list[str] = [];
    for kv in _section_items(types) {
        if isinstance(kv[1], dict) and isinstance(kv[1].get("members"), list) {
            all_members = all_members + [str(m) for m in kv[1]["members"]];
        }
    }
    ename = _fresh(_camel(nid) + "Route", type_names + taken);
    members: list[str] = [];
    options: list[str] = [];
    for e in outs {
        m = _fresh("to_" + _ident(e.get("to")), all_members + members);
        members.append(m);
        tgt = nidx.get(str(e.get("to")));
        tdoc = str(tgt.get("doc") or "").strip() if isinstance(tgt, dict) else "";
        options.append(m + " = " + str(e.get("to")) + ((": " + tdoc[:160]) if tdoc else ""));
    }
    if types is None { ir["types"] = {}; }
    _section_put(ir, "types", ename, {"kind": "enum", "members": members,
                                      "doc": "Successor chosen at '" + nid + "'."});

    carry_names = _section_names(_carries(ir));
    cname = _fresh(_ident(nid) + "_route", carry_names);
    if not isinstance(ir.get("walker"), dict) { ir["walker"] = {}; }
    wk = ir["walker"];
    if wk.get("carries") is None { wk["carries"] = {}; }

    reads = [str(r) for r in (n.get("reads") if isinstance(n.get("reads"), list) else [])];
    tr = n.get("traces_to") if isinstance(n.get("traces_to"), list) else [];
    intent = str(n.get("doc") or "").strip()
             or "Choose the outgoing step that best fits the task and the current state.";
    added: list[dict[str, any]] = [];
    if writes_first {
        # the node keeps its own work (a semantic step) and hands the choice on
        sel_id = _fresh(nid + "_choose", taken);
        taken.append(sel_id);
        sel_reads = reads + [str(w) for w in n.get("writes") if str(w) not in reads];
        sel: dict[str, any] = {"id": sel_id, "type": "SELECT", "owner": "model",
                               "reads": sel_reads, "writes": [cname], "traces_to": list(tr),
                               "origin": "canonicalize"};
        added.append(sel);
    } else {
        sel_id = nid;
        sel = n;
        n["type"] = "SELECT";
        n["owner"] = "model";
        n["writes"] = [cname];
    }
    sel["doc"] = intent + " Options: " + "; ".join(options) + ".";
    _section_put(wk, "carries", cname, {"type": ename, "produced_by": sel_id, "origin": "canonicalize"});

    br_id = _fresh(nid + "_branch", taken);
    br: dict[str, any] = {"id": br_id, "type": "BRANCH", "owner": "code", "reads": [cname],
                          "doc": "Branch on the successor chosen at '" + nid + "'.",
                          "traces_to": list(tr), "origin": "canonicalize"};
    added.append(br);
    for (i, e) in enumerate(outs) {
        e["from"] = br_id;
        e["guard"] = cname + " == " + members[i];
    }
    if writes_first {
        edges.append({"from": nid, "to": sel_id, "modality": "mandatory"});
    }
    edges.append({"from": sel_id, "to": br_id, "modality": "mandatory"});
    notes.append("AIS: model-chosen branch '" + nid + "' -> SELECT '" + sel_id
                 + "' over " + str(len(members)) + " successor(s) + BRANCH '" + br_id + "'");
    return added;
}

def _splice_out(ir: dict[str, any], n: dict[str, any], notes: list[str]) -> bool {
    # Remove a no-op instruction, joining its predecessors to its successors.
    # False when it cannot be removed without changing the entry point.
    nid = str(n.get("id"));
    nodes = ir.get("nodes");
    edges = _edges(ir);
    ins = [e for e in edges if isinstance(e, dict) and (str(e.get("to")) == nid)];
    outs = [e for e in edges if isinstance(e, dict) and (str(e.get("from")) == nid)];
    succ = [str(e.get("to")) for e in outs if str(e.get("to")) != nid];
    if nodes and (nodes[0] is n) {
        if len(succ) != 1 { return False; }
        # the entry moves to the single successor
        for (i, x) in enumerate(nodes) {
            if isinstance(x, dict) and (str(x.get("id")) == succ[0]) {
                nodes.insert(0, nodes.pop(i));
                break;
            }
        }
    }
    joined: list[dict[str, any]] = [];
    for ei in ins {
        if str(ei.get("from")) == nid { continue; }
        for s in succ {
            ne: dict[str, any] = {"from": ei.get("from"), "to": s};
            for k in ["modality", "guard", "traces_to"] {
                if ei.get(k) is not None { ne[k] = ei.get(k); }
            }
            joined.append(ne);
        }
    }
    ir["edges"] = [e for e in edges if not (isinstance(e, dict)
                   and ((str(e.get("from")) == nid) or (str(e.get("to")) == nid)))] + joined;
    ir["nodes"] = [x for x in nodes if x is not n];
    # Knowledge resident here would otherwise reach no instruction at all.
    for kv in _section_items(ir.get("knowledge")) {
        k = kv[1];
        if not isinstance(k, dict) { continue; }
        ro = k.get("resident_on");
        rl = [str(x) for x in ro] if isinstance(ro, list) else ([str(ro)] if ro else []);
        if nid not in rl { continue; }
        rl = [x for x in rl if x != nid];
        if not rl { rl = list(succ); }
        k["resident_on"] = rl;
    }
    notes.append("AIS: no-op model OBSERVE '" + nid + "' spliced out (its knowledge moves to "
                 + (", ".join(succ) if succ else "nothing") + ")");
    return True;
}

def canonicalize_ais(ir: any) -> list[str] {
    # Rewrite `ir` in place into the paper's AIS. Idempotent: a canonical document
    # passes through unchanged. Returns one note per structural rewrite (renames
    # are silent — they change no behavior).
    notes: list[str] = [];
    if not isinstance(ir, dict) { return notes; }

    for kv in _section_items(ir.get("tools")) {
        if isinstance(kv[1], dict) and kv[1].get("surface") {
            kv[1]["surface"] = canonical_surface(kv[1].get("surface"));
        }
    }
    nodes = ir.get("nodes");
    if not isinstance(nodes, list) { return notes; }

    # 1. names
    for n in nodes {
        if not isinstance(n, dict) { continue; }
        raw = str(n.get("type") or "");
        op = canonical_opcode(raw);
        if (op == "CALL") and (not str(n.get("procedure") or "").strip()) {
            # a legacy CALL: a sub-agent over the caller's carries
            op = "DELEGATE";
            n["from_legacy"] = "CALL";
        }
        if (op in AIS_SEMANTIC) and real_tools(n.get("autonomy")) {
            # a semantic step with a tool surface is a delegated subtask (paper
            # Table 3: DELEGATE lowers to by llm(tools=[...]))
            op = "DELEGATE";
        }
        n["type"] = op;
    }

    # 2. units — the opcode decides; legacy model-owned executable/control forms
    #    are rewritten into the composition they always meant
    splice: list[dict[str, any]] = [];
    inserts: list[any] = [];
    for n in list(nodes) {
        if not isinstance(n, dict) { continue; }
        op = str(n.get("type"));
        declared = str(n.get("owner") or "").strip().lower();
        if op in AIS_MODEL_OPS { n["owner"] = "model"; continue; }
        if (op not in ["OBSERVE", "ACT", "BRANCH", "LOOP"]) or (declared != "model") {
            n["owner"] = "code";
            continue;
        }
        nid = str(n.get("id"));
        n["owner_declared"] = "model";
        bound = _tool_bound(ir, n);
        writes = n.get("writes") if isinstance(n.get("writes"), list) else [];
        reads = [str(r) for r in (n.get("reads") if isinstance(n.get("reads"), list) else [])];
        if (op in ["OBSERVE", "ACT", "LOOP"]) and bound {
            n["owner"] = "code";
        } elif ((op == "ACT") and ("script" in reads) and bool(writes)
                and (_section_get(_carries(ir), "script") is not None)) {
            n["owner"] = "code";      # running an authored program is execution
        } elif op in ["OBSERVE", "ACT"] {
            if writes {
                n["type"] = _semantic_for_result(ir, n);
                n["owner"] = "model";
                notes.append("AIS: model " + op + " '" + nid + "' has no binding -> " + str(n["type"]));
            } elif op == "OBSERVE" {
                splice.append(n);
            } else {
                n["type"] = "GENERATE";
                n["owner"] = "model";
                notes.append("AIS: model ACT '" + nid + "' has no binding -> GENERATE");
            }
        } elif op == "LOOP" {
            if writes {
                # the productive work is a semantic step; the repetition is control
                taken = [str(x.get("id")) for x in nodes if isinstance(x, dict)];
                lid = _fresh(nid + "_loop", taken);
                for e in _edges(ir) {
                    if isinstance(e, dict) and (str(e.get("from")) == nid) { e["from"] = lid; }
                }
                _edges(ir).append({"from": nid, "to": lid, "modality": "mandatory"});
                n["type"] = _semantic_for_result(ir, n);
                n["owner"] = "model";
                inserts.append([n, [{"id": lid, "type": "LOOP", "owner": "code",
                                     "reads": [str(w) for w in writes],
                                     "doc": "Continue or repeat after '" + nid + "'.",
                                     "traces_to": list(n.get("traces_to") or []),
                                     "origin": "canonicalize"}]]);
                notes.append("AIS: model LOOP '" + nid + "' -> " + str(n["type"]) + " + LOOP '" + lid + "'");
            } else {
                n["owner"] = "code";
            }
        } else {
            # BRANCH
            outs = [e for e in _edges(ir) if isinstance(e, dict) and (str(e.get("from")) == nid)];
            if bound or (len(outs) <= 1) {
                if writes and (not bound) {
                    n["type"] = _semantic_for_result(ir, n);
                    n["owner"] = "model";
                    notes.append("AIS: model BRANCH '" + nid + "' with one successor -> " + str(n["type"]));
                } else {
                    n["owner"] = "code";
                }
            } else {
                wf = bool(writes);
                if wf {
                    n["type"] = _semantic_for_result(ir, n);
                    n["owner"] = "model";
                }
                inserts.append([n, _split_choice(ir, n, wf, notes)]);
            }
        }
    }
    for ins in inserts {
        anchor = ins[0];
        cur: list[any] = ir.get("nodes") or [];
        pos = 0;
        for (i, x) in enumerate(cur) {
            if x is anchor { pos = i + 1; break; }
        }
        for (j, nn) in enumerate(ins[1]) { cur.insert(pos + j, nn); }
    }
    for s in splice {
        if not _splice_out(ir, s, notes) {
            # an entry with several successors cannot be spliced; it stays as an
            # unconditional control step
            s["type"] = "BRANCH";
            s["owner"] = "code";
            notes.append("AIS: no-op model OBSERVE '" + str(s.get("id")) + "' is the entry -> BRANCH");
        }
    }
    return notes;
}

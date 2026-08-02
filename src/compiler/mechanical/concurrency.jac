"""Concurrency extraction (SkillRT AOT Pass 3 — made mechanical).

SkillRT's insight: 76% of skills carry procedural structure, but *sequential
prose does not reflect actual data dependencies* — so their compiler runs an
LLM-assisted analysis to recover a step DAG (inputs consumed, outputs
produced) and then extracts DLP / ILP / TLP. Up to 3.2x end-to-end.

The AG-IR is a strictly better substrate for the same pass: the IO view
already TYPES the dataflow (`reads` / `writes` / `produced_by` carries), so
the DAG SkillRT must ask a model to guess is simply *read off the IR* — no
LLM, no recovery error. What sigil lacked was the pass itself: the SPAWN
decision was model-judged (`spawn_note`) and validated only for being
*stated*, never for being *right*.

extract_concurrency(ir) -> {
  "stages":        [[node ids]]   ILP: consecutive chain nodes with no mutual
                                  data dependency, packed into parallel stages
  "opportunities": [str]          stages of >=2 (missed parallelism) — advisory
  "issues":        [str]          FALSE parallelism: a SPAWN whose branches
                                  share moving data (hard G8 gate issues —
                                  read-shared/write-isolated is the law, A.6)
  "dlp":           [str]          list-typed carry feeding one tool-backed
                                  code node: an item-parallel map candidate
}

Deterministic, judgment-free — it belongs to the MECHANICAL half. The ai gate
(G8) wraps it; lowering stages to `flow`/`wait` is the natural next step (the
generated modules' SPAWN lowering already uses that mechanism).
"""

# control-flow node types that end a linear chain (a ROUTE fans out to
# EXCLUSIVE alternatives — never a parallel stage; SPAWN is already parallel)
glob _BARRIERS: list = ["ROUTE", "SPAWN", "LOOP", "TERMINAL"];

def _lst(v: any) -> list {
    return list(v) if isinstance(v, list) else [];
}

def _dct(v: any) -> dict {
    return v if isinstance(v, dict) else {};
}

def _slist(v: any) -> list {
    return [str(x) for x in v] if isinstance(v, list) else [];
}

def _nodes(ir: any) -> list {
    return _lst(_dct(ir).get("nodes"));
}

def _edges(ir: any) -> list {
    return _lst(_dct(ir).get("edges"));
}

def _ntype(n: any) -> str {
    return str(_dct(n).get("type", "")).replace("_", "-").upper();
}

def _is_hil(n: any) -> bool {
    return "REQUIRE HUMAN GATE" in str(_dct(n).get("doc", ""));
}

def _producers(ir: any) -> dict {
    # carry name -> producing node id. Node `writes` is authoritative; the
    # walker.carries `produced_by` fills any carry no node declares.
    prod: dict = {};
    for n in _nodes(ir) {
        for w in _slist(_dct(n).get("writes")) { prod[w] = str(_dct(n).get("id", "")); }
    }
    carries = _dct(_dct(_dct(ir).get("walker")).get("carries"));
    for kv in carries.items() {
        cname = str(kv[0]);
        meta = _dct(kv[1]);
        if (cname not in prod) and meta.get("produced_by") {
            prod[cname] = str(meta.get("produced_by"));
        }
    }
    return prod;
}

def _data_deps(ir: any) -> dict {
    # node id -> direct data-dependency node ids (producers of what it reads)
    prod = _producers(ir);
    deps: dict = {};
    for n in _nodes(ir) {
        nid = str(_dct(n).get("id", ""));
        dd: list = [];
        for r in _slist(_dct(n).get("reads")) {
            p = str(prod.get(r, ""));
            if p and (p != nid) and (p not in dd) { dd.append(p); }
        }
        deps[nid] = dd;
    }
    return deps;
}

def _trans_deps(nid: str, deps: dict, memo: dict) -> list {
    # transitive data dependencies, memoized DFS (cycle-safe: a repair LOOP's
    # back-edge can make the carry graph cyclic — mark-before-recurse)
    if nid in memo { return _lst(memo.get(nid)); }
    memo[nid] = [];
    acc: list = [];
    for d in _lst(deps.get(nid)) {
        ds = str(d);
        if ds not in acc { acc.append(ds); }
        for t in _trans_deps(ds, deps, memo) {
            if t not in acc { acc.append(t); }
        }
    }
    memo[nid] = acc;
    return list(acc);
}

def _reach(start: str, succ: dict) -> list {
    seen: list = [start];
    frontier: list = [start];
    while frontier {
        cur = str(frontier.pop());
        for nxt in _lst(succ.get(cur)) {
            if nxt not in seen { seen.append(nxt); frontier.append(nxt); }
        }
    }
    return seen;
}

def _plain(nid: str, by_id: dict) -> bool {
    # "plain" = eligible to sit inside a linear chain: not a control barrier,
    # not a human gate
    n = by_id.get(nid);
    if n is None { return False; }
    return (_ntype(n) not in _BARRIERS) and (not _is_hil(n));
}

def _chain_segments(ir: any) -> list {
    # maximal linear runs of "plain" nodes: each link u->v where u has exactly
    # one out-edge, v exactly one in-edge, and neither is a control barrier or
    # a human gate. These are the spans where prose ORDER may exceed data NEED.
    nodes = _nodes(ir);
    by_id: dict = {};
    for n in nodes { by_id[str(_dct(n).get("id", ""))] = n; }
    outs: dict = {};
    ins: dict = {};
    for e in _edges(ir) {
        f = str(_dct(e).get("from", ""));
        t = str(_dct(e).get("to", ""));
        outs[f] = _lst(outs.get(f)) + [t];
        ins[t] = _lst(ins.get(t)) + [f];
    }
    segments: list = [];
    assigned: list = [];
    for n in nodes {
        nid = str(_dct(n).get("id", ""));
        if (nid in assigned) or (not _plain(nid, by_id)) { continue; }
        # only start a segment at a chain HEAD (predecessor is not a
        # continuable link), so each run is emitted once, maximal
        preds = _slist(ins.get(nid));
        if (len(preds) == 1) and _plain(preds[0], by_id) and (len(_lst(outs.get(preds[0]))) == 1) { continue; }
        seg: list = [nid];
        cur = nid;
        while True {
            nxt = _slist(outs.get(cur));
            if len(nxt) != 1 { break; }
            v = nxt[0];
            if (not _plain(v, by_id)) or (len(_lst(ins.get(v))) != 1) or (v in seg) { break; }
            seg.append(v);
            cur = v;
        }
        for s in seg { assigned.append(s); }
        segments.append(seg);
    }
    return segments;
}

def _pack_stages(seg: list, deps: dict, memo: dict) -> list {
    # greedy ILP packing: walk the chain in control order; a node joins the
    # open stage iff it has no transitive data dependency on a stage member.
    stages: list = [];
    cur: list = [];
    for nid in seg {
        td = _trans_deps(str(nid), deps, memo);
        blocked = False;
        for m in cur { if m in td { blocked = True; } }
        if cur and blocked { stages.append(cur); cur = [str(nid)]; }
        else { cur.append(str(nid)); }
    }
    if cur { stages.append(cur); }
    return stages;
}

def extract_concurrency(ir: any) -> dict {
    nodes = _nodes(ir);
    by_id: dict = {};
    for n in nodes { by_id[str(_dct(n).get("id", ""))] = n; }
    deps = _data_deps(ir);
    memo: dict = {};
    spawn_decl = _dct(_dct(ir).get("concurrency"));
    spawn_state = str(spawn_decl.get("spawn", "none"));
    spawn_reason = str(spawn_decl.get("reason", ""));

    stages: list = [];
    opportunities: list = [];
    issues: list = [];
    dlp: list = [];

    # ---- ILP: stage-pack every linear chain segment -------------------------
    for seg in _chain_segments(ir) {
        for st in _pack_stages(_lst(seg), deps, memo) {
            stg = _slist(st);
            stages.append(stg);
            if len(stg) < 2 { continue; }
            acts = [x for x in stg if _ntype(by_id.get(x, {})) == "ACT"];
            caution = " (>=2 ACT nodes — verify write isolation before lowering)" if len(acts) >= 2 else "";
            note: str = "G8: nodes [" + ", ".join(stg) + "] are sequential in the CFG but share no data dependency — parallelizable stage (flow/wait)";
            if spawn_state == "none" {
                why = (" spawn_note: '" + spawn_reason[:80] + "'") if spawn_reason else " (concurrency declared none)";
                note = note + ";" + why;
            }
            opportunities.append(note + caution);
        }
    }

    # ---- TLP check: a declared SPAWN must be genuinely independent ----------
    succ: dict = {};
    for e in _edges(ir) {
        f = str(_dct(e).get("from", ""));
        succ[f] = _lst(succ.get(f)) + [str(_dct(e).get("to", ""))];
    }
    for n in nodes {
        if _ntype(n) != "SPAWN" { continue; }
        sid = str(_dct(n).get("id", ""));
        branches = _slist(succ.get(sid));
        if len(branches) < 2 { continue; }
        reach: dict = {};
        for b in branches { reach[b] = _reach(b, succ); }
        # nodes visible from more than one branch are the JOIN suffix — shared
        # by construction, excluded from the cross-branch test
        shared: list = [];
        for b in branches {
            for x in _lst(reach.get(b)) {
                cnt = 0;
                for b2 in branches { if x in _lst(reach.get(b2)) { cnt += 1; } }
                if (cnt > 1) and (x not in shared) { shared.append(x); }
            }
        }
        for i in range(len(branches)) {
            for j in range(len(branches)) {
                if i == j { continue; }
                a_nodes = [x for x in _lst(reach.get(branches[i])) if x not in shared];
                b_nodes = [x for x in _lst(reach.get(branches[j])) if x not in shared];
                for an in a_nodes {
                    aw = _slist(_dct(by_id.get(str(an))).get("writes"));
                    for bn in b_nodes {
                        for rd in _slist(_dct(by_id.get(str(bn))).get("reads")) {
                            if rd in aw {
                                issues.append("G8: SPAWN '" + sid + "' branches share moving data — '" + str(rd)
                                    + "' is written in branch '" + str(branches[i]) + "' (node '" + str(an)
                                    + "') and read in branch '" + str(branches[j]) + "' (node '" + str(bn)
                                    + "'). False parallelism: hoist the carry to the orchestrator or serialize the branches (A.6 read-shared/write-isolated).");
                            }
                        }
                    }
                }
            }
        }
    }

    # ---- DLP: list-typed carry into a single tool-backed code node ----------
    served: list = [];
    for kv in _dct(_dct(ir).get("tools")).items() {
        t = _dct(kv[1]);
        for sv in _slist(t.get("serves")) { served.append(sv); }
    }
    carries = _dct(_dct(_dct(ir).get("walker")).get("carries"));
    for kv2 in carries.items() {
        cname = str(kv2[0]);
        meta = _dct(kv2[1]);
        if not str(meta.get("type", "")).startswith("list[") { continue; }
        for n2 in nodes {
            nid2 = str(_dct(n2).get("id", ""));
            if cname not in _slist(_dct(n2).get("reads")) { continue; }
            if str(_dct(n2).get("owner", "")).lower() != "code" { continue; }
            if nid2 not in served { continue; }
            dlp.append("G8-DLP: carry '" + cname + "' (list) feeds tool-backed code node '" + nid2
                + "' — item-parallel map candidate (language-level parallelism, no harness support needed)");
        }
    }

    return {"stages": stages, "opportunities": opportunities, "issues": issues, "dlp": dlp};
}

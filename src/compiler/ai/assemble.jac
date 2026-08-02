"""AI compiler — Stage 4: Assemble (join the views on the rule-id spine).

Pure code, no model. Joins the WorkflowView + the four annotator views into one
AG-IR YAML document for the MECHANICAL half, and audits the join:

- Reflexive 5d (the determinization-completeness gate applied to the harness's
  OWN carriers): every spec rule must be consumed by >=1 view — a rule kind no
  view carries is a silently dropped lane; the fix is to widen a view, never to
  ignore the rule.
- Cross-references: carries' producers exist, node reads/writes have a lane
  (carry / knowledge / task), residency + serves + HIL targets name real nodes.
- Prose-pointer precheck: a tool with neither body nor command, or a knowledge
  item with no content, is flagged here (G1 hardens this later).

Issues never block emission — assemble returns the IR WITH its issue list, and
the caller (lift) decides. Honest output, never a silent success.
"""

import re;
import yaml;
import from src.compiler.mechanical.toolib { builtin }
import from .lift_types { Modality, RuleKind }
import from .spec_loop { RuleSet }
import from .ir_views { NodeType, Owner, AssembleResult }
import from .workflow { WorkflowView }
import from .flows { ViewBundle }

def _ntype_str(t: NodeType) -> str {
    return t.name.replace("_", "-");
}

def assemble(spec: RuleSet, wf: WorkflowView, vb: ViewBundle, name: str) -> AssembleResult {
    issues: list = [];
    node_ids = [n.id for n in wf.nodes];
    carry_names = [c.name for c in vb.io.carries];
    knowledge_keys = [k.key for k in vb.kn.knowledge];

    # ---- reflexive 5d: every rule is consumed by some view ------------------
    consumed: list = [];
    for n in wf.nodes { for t in n.traces_to { consumed.append(t); } }
    for e in wf.edges { if e.traces_to { consumed.append(e.traces_to); } }
    for c in wf.constraints { if ":" in c { consumed.append(c.split(":")[0].strip()); } }
    for cr in vb.io.carries { if cr.traces_to { consumed.append(cr.traces_to); } }
    for td in vb.kn.tools { if td.traces_to { consumed.append(td.traces_to); } }
    for ki in vb.kn.knowledge { if ki.traces_to { consumed.append(ki.traces_to); } }
    for hp in vb.hil.points { if hp.traces_to { consumed.append(hp.traces_to); } }
    for r in spec.rules {
        if r.id not in consumed {
            issues.append("rule '" + r.id + "' (" + r.kind.name + ") consumed by no view — widen a view (5d)");
        }
    }

    # ---- cross-references ----------------------------------------------------
    for cr in vb.io.carries {
        if (cr.role != "input") and cr.produced_by and (cr.produced_by not in node_ids) {
            issues.append("carry '" + cr.name + "' produced_by unknown node '" + cr.produced_by + "'");
        }
        if (cr.role != "input") and (not cr.produced_by) {
            issues.append("carry '" + cr.name + "' has no producer and is not an input (dropped lane)");
        }
    }
    lanes = carry_names + knowledge_keys + ["task"];
    for n in wf.nodes {
        for rd in n.reads {
            if rd not in lanes {
                issues.append("node '" + n.id + "' reads '" + rd + "' which is neither a carry nor knowledge (no lane)");
            }
        }
        for wr in n.writes {
            if wr not in carry_names {
                issues.append("node '" + n.id + "' writes '" + wr + "' which is not a declared carry");
            }
        }
    }
    for res in vb.ctxv.residency {
        for nid in res.resident_on {
            if nid not in node_ids { issues.append("residency for '" + res.key + "' names unknown node '" + nid + "'"); }
        }
    }
    for td in vb.kn.tools {
        for sv in td.serves {
            if sv not in node_ids { issues.append("tool '" + td.name + "' serves unknown node '" + sv + "'"); }
        }
        if (not td.body.strip()) and (not td.command.strip()) and (not builtin(td.name)) {
            # builtin-named tools get their body spliced at lower time (toolib.jac)
            issues.append("tool '" + td.name + "' has neither body nor command (prose-pointer)");
        }
    }
    for ki in vb.kn.knowledge {
        if not ki.content.strip() { issues.append("knowledge '" + ki.key + "' has no content (prose-pointer)"); }
    }

    # ---- lowering completeness: no hollow code stations ---------------------
    # A code-owned CODE/SENSE/ACT node lowers through a tool. With no tool
    # serving it the mechanical half has nothing to emit and writes a marker
    # comment: the walker visits the station and does nothing. That is the
    # worst realization in the system — it looks like a gate in the graph, it
    # reads like a gate in the compiled module, and it enforces nothing. Catch
    # it HERE, where the repair loop can still bind a tool, rather than letting
    # it reach a green compile.
    served: list = [];
    for td in vb.kn.tools { for sv in td.serves { served.append(sv); } }
    tool_lowered = [NodeType.CODE, NodeType.SENSE, NodeType.ACT];
    for n in wf.nodes {
        if (n.owner != Owner.CODE) or (n.ntype not in tool_lowered) { continue; }
        if n.id in served { continue; }
        issues.append("node '" + n.id + "' (" + _ntype_str(n.ntype)
            + ", owner=code) has NO tool serving it — it lowers to a marker comment and enforces nothing."
            + " Add a tool with a body/command whose serves includes '" + n.id
            + "', or re-own the step to MODEL if it genuinely needs a guess.");
    }
    for hp in vb.hil.points {
        if hp.node not in node_ids { issues.append("HIL point targets unknown node '" + hp.node + "'"); }
    }

    # ---- residency: ContextFlow scoping overrides/extends KnowledgeFlow -----
    residency: dict = {};
    for ki in vb.kn.knowledge { residency[ki.key] = list(ki.resident_on); }
    for res in vb.ctxv.residency {
        cur = list(residency.get(res.key, []));
        for nid in res.resident_on { if nid not in cur { cur.append(nid); } }
        residency[res.key] = cur;
    }

    # ---- fold constraints + HIL gates into node docs -------------------------
    # (v1 lowering: FORBIDDEN rules ride every model Mind node's sem; a HIL gate
    # rides its target node's sem. The mechanical half folds doc into the slot
    # sem, which is where prohibitions and gates bind.)
    # ---- HIL points become REAL gates: an ask_user tool per gated node ----
    # (runtime _ask_user: file channel when HIL_QA_FILE is attached, an honest
    # sentinel in batch — the human gate exists either way, never fabricated.)
    hil_tool_by_node: dict[str, str] = {};
    hil_extra_tools: list[dict] = [];
    for hp0 in vb.hil.points {
        if hp0.node not in node_ids { continue; }
        tname = "ask_user_" + hp0.node;
        if hp0.node in hil_tool_by_node { continue; }
        hil_tool_by_node[hp0.node] = tname;
        # The tool takes a `prompt` because the gated node has a question to ask —
        # a Socratic clarify loop's question is authored at RUN time, not lift time.
        # Baking only the static text and ignoring the argument asked the human
        # "INPUT:" and nothing else, which is a gate the human cannot answer.
        # Runtime question wins; the lifted text is the fallback when there is none.
        static = (hp0.kind + ": " + hp0.prompt).replace('"', "'").rstrip();
        kind = hp0.kind.replace('"', "'");
        hil_extra_tools.append({"name": tname,
            "sig": "(prompt) -> str", "surface": "SENSE", "serves": [hp0.node],
            "body": 'q = str(prompt or "").strip()\n'
                    + 'return _ask_user(("' + kind + ': " + q) if q else "' + static + '")'});
    }

    # ---- constraint residency: a prohibition rides only the slots it governs ---
    # Folding EVERY constraint into EVERY Mind node's doc put ~30 unrelated
    # prohibitions (3kB) on each slot — a decl-syntax rule lecturing the node
    # that curls an endpoint. That is the whole-guide-per-block shape, and it
    # lures a model into applying the wrong rule to the wrong step; scoping is
    # what makes a rule land. Same precedence knowledge already uses:
    #   1. provenance — the node's traces_to names the FORBIDDEN rule;
    #   2. lexical    — the prohibition shares a distinctive token with the
    #      node's identity (id / doc / carries it reads and writes);
    #   3. neither    — the constraint cannot be placed. Keep it global so the
    #      prohibition is never silently dropped, and SAY SO, because an
    #      unplaceable constraint is a gap the front-end should close.
    mind = [NodeType.GEN_RAW, NodeType.GEN_ENUM, NodeType.GEN_FILL, NodeType.GEN_EDIT];
    mind_ids: list[str] = [n0.id for n0 in wf.nodes
                           if (n0.owner == Owner.MODEL) and (n0.ntype in mind)];
    reads_of: dict[str, list[str]] = {};
    for n0 in wf.nodes { reads_of[n0.id] = list(n0.reads); }
    producer_of: dict[str, str] = {};
    for cr0 in vb.io.carries {
        if cr0.produced_by { producer_of[cr0.name] = cr0.produced_by; }
    }
    con_by_node: dict[str, list[str]] = {};
    con_global: list[str] = [];
    for c0 in wf.constraints {
        if ":" not in c0 { continue; }
        cid = str(c0.split(":", 1)[0]).strip();
        ctext = str(c0.split(":", 1)[1]).strip();
        if not ctext { continue; }
        owners: list[str] = [n0.id for n0 in wf.nodes if cid in n0.traces_to];
        if not owners {
            toks = set([t.lower() for t in re.findall(r"[A-Za-z_]{4,}", ctext)]);
            for n1 in wf.nodes {
                ident = " ".join([n1.id, n1.doc] + list(n1.reads) + list(n1.writes)).lower();
                if [t for t in toks if t in ident] { owners.append(n1.id); }
            }
        }
        # Only Mind slots carry the fold, so a prohibition scoped to code nodes
        # alone would vanish. Escalate it to the model slot that PRODUCES what
        # that node consumes — "never emit X" binds on whoever writes X, not on
        # the mechanical step that hands it onward.
        mind_owners: list[str] = [oid for oid in owners if oid in mind_ids];
        if not mind_owners {
            for oid in owners {
                for rd0 in reads_of.get(oid, []) {
                    p0 = producer_of.get(rd0, "");
                    if p0 and (p0 in mind_ids) and (p0 not in mind_owners) { mind_owners.append(p0); }
                }
            }
        }
        if mind_owners { owners = mind_owners; }
        if owners {
            for oid in owners {
                cur3: list[str] = list(con_by_node.get(oid, []));
                if ctext not in cur3 { cur3.append(ctext); }
                con_by_node[oid] = cur3;
            }
        } else {
            con_global.append(ctext);
            issues.append("constraint '" + cid + "' could not be scoped to any node — it rides"
                + " every model slot. Trace it from the node(s) it governs, or name those nodes"
                + " in the constraint text: " + ctext[:80]);
        }
    }
    hil_by_node: dict[str, list[str]] = {};
    for hp in vb.hil.points {
        cur2: list[str] = list(hil_by_node.get(hp.node, []));
        cur2.append(hp.kind + ": " + hp.prompt);
        hil_by_node[hp.node] = cur2;
    }

    # ---- emit ----------------------------------------------------------------
    nodes_out: list = [];
    for n in wf.nodes {
        doc = n.doc;
        mine = list(con_by_node.get(n.id, [])) + con_global;
        if mine and (n.owner == Owner.MODEL) and (n.ntype in mind) {
            sep = " " if doc else "";
            doc = doc + sep + "NEVER violate: " + "; ".join(mine);
        }
        if n.id in hil_by_node {
            sep2 = " " if doc else "";
            doc = doc + sep2 + "REQUIRE HUMAN GATE — " + "; ".join(hil_by_node[n.id]);
        }
        nd: dict = {"id": n.id, "type": _ntype_str(n.ntype), "owner": n.owner.name.lower()};
        if doc { nd["doc"] = doc; }
        if n.reads { nd["reads"] = list(n.reads); }
        if n.writes { nd["writes"] = list(n.writes); }
        if n.surface { nd["surface"] = "ACT·" + n.surface if not n.surface.startswith("ACT") else n.surface; }
        atools = list(n.autonomy_tools);
        if (n.id in hil_tool_by_node) and (n.owner == Owner.MODEL) and (n.ntype in mind) {
            # the gated Mind slot can genuinely ASK (clarify loops converge on
            # real answers when a channel is attached)
            if hil_tool_by_node[n.id] not in atools { atools.append(hil_tool_by_node[n.id]); }
        }
        if atools { nd["autonomy"] = {"tools": atools}; }
        # persist the rule-id spine into the IR: node -> rule ids -> (spec.json) verbatim skill spans.
        # The mechanical half ignores unknown keys; provenance rides for free.
        if n.traces_to { nd["traces_to"] = list(n.traces_to); }
        nodes_out.append(nd);
    }

    carries_out: dict = {};
    if "task" not in carry_names { carries_out["task"] = {"type": "str", "role": "input"}; }
    for cr in vb.io.carries {
        if cr.name == "report" { continue; }   # the mechanical half adds `report` itself
        ce: dict = {"type": cr.ctype if cr.ctype else "str"};
        if cr.role { ce["role"] = cr.role; }
        if cr.produced_by { ce["produced_by"] = cr.produced_by; }
        carries_out[cr.name] = ce;
    }

    tools_out: dict = {};
    for ht in hil_extra_tools {
        tools_out[str(ht["name"])] = {"sig": ht["sig"], "surface": ht["surface"],
                                      "serves": list(ht["serves"]), "body": ht["body"]};
    }
    for td in vb.kn.tools {
        te: dict = {};
        if td.sig { te["sig"] = td.sig; }
        if td.surface { te["surface"] = td.surface; }
        if td.serves { te["serves"] = list(td.serves); }
        if td.body.strip() { te["body"] = td.body; }
        if td.command.strip() { te["command"] = td.command; }
        tools_out[td.name] = te;
    }

    knowledge_out: dict = {};
    for ki in vb.kn.knowledge {
        knowledge_out[ki.key] = {"body": ki.content, "resident_on": list(residency.get(ki.key, []))};
    }

    edges_out: list = [];
    for e in wf.edges {
        ee: dict = {"from": e.src, "to": e.dst, "modality": e.modality.name.lower()};
        if e.guard { ee["guard"] = e.guard; }
        edges_out.append(ee);
    }

    body: dict = {
        "agir_version": 0.1,
        "standalone": True,
        "shape": "pipeline",
        "types": {},
        "walker": {"name": _walker_name(name), "carries": carries_out},
        "nodes": nodes_out,
        "edges": edges_out,
    };
    if tools_out { body["tools"] = tools_out; }
    if knowledge_out { body["knowledge"] = knowledge_out; }
    body["concurrency"] = {"spawn": "none", "reason": wf.spawn_note} if wf.spawn_note else {"spawn": "none"};

    fm = "---\nname: " + name + "\ndescription: Compiled by the sigil AI compiler (LIFT front-end).\n---\n";
    ir_text = fm + str(yaml.safe_dump(body, sort_keys=False, allow_unicode=True));
    return AssembleResult(ir_text=ir_text, issues=issues);
}

def _walker_name(name: str) -> str {
    parts = [p for p in name.replace("-", " ").replace("_", " ").split() if p];
    out = "";
    for p in parts { out += p.capitalize(); }
    return (out if out else "Lifted") + "Agent";
}

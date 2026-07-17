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

import yaml;
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
        if (not td.body.strip()) and (not td.command.strip()) {
            issues.append("tool '" + td.name + "' has neither body nor command (prose-pointer)");
        }
    }
    for ki in vb.kn.knowledge {
        if not ki.content.strip() { issues.append("knowledge '" + ki.key + "' has no content (prose-pointer)"); }
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
    con_texts: list[str] = [];
    for c0 in wf.constraints {
        if ":" in c0 { con_texts.append(str(c0.split(":", 1)[1]).strip()); }
    }
    hil_by_node: dict[str, list[str]] = {};
    for hp in vb.hil.points {
        cur2: list[str] = list(hil_by_node.get(hp.node, []));
        cur2.append(hp.kind + ": " + hp.prompt);
        hil_by_node[hp.node] = cur2;
    }
    mind = [NodeType.GEN_RAW, NodeType.GEN_ENUM, NodeType.GEN_FILL, NodeType.GEN_EDIT];

    # ---- emit ----------------------------------------------------------------
    nodes_out: list = [];
    for n in wf.nodes {
        doc = n.doc;
        if con_texts and (n.owner == Owner.MODEL) and (n.ntype in mind) {
            sep = " " if doc else "";
            doc = doc + sep + "NEVER violate: " + "; ".join(con_texts);
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
        if n.autonomy_tools { nd["autonomy"] = {"tools": list(n.autonomy_tools)}; }
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

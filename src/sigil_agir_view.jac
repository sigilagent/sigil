"""AG-IR as a drawable graph — the projection the Observatory renders.

A compiled skill already IS a graph: `TaskGraph.agir` holds the typed contract the
frontier authored, and that contract is nodes and edges. The Observatory drew the
agent's own graph but never this one, so the thing the compiler exists to produce
was the one thing you could not look at.

This reads the stored AG-IR and projects it to `{nodes, edges}` for the canvas.

Reading is delegated to `sigil_agir_yaml`, the same reader the mechanical back-end
uses, so what the Observatory draws is what the compiler compiled. That module is a
leaf on purpose: `eject_agent.test.jac` asserts no module in the runtime closure
imports the compiler — which is what lets an ejected agent ship the runtime without
the whole AI front-end — and a shared leaf lets both sides agree without either
importing the other.

This projection is read-only and total: anything it cannot decode comes back as a
`warning` for the UI to show, never an exception.
"""

import from .sigil_agir_yaml { load_agir }
import from .sigil_core { Registry, TaskGraph, latest_by_sig }

# AG-IR node type -> the group the canvas colours by. Mirrors the primitive
# families in src/contracts/: model-owned cognition, code-owned mechanism, flow.
glob _GROUPS: dict = {
    "GEN-RAW": "mind", "GEN-FILL": "mind", "GEN-ENUM": "mind", "GEN-EDIT": "mind",
    "SENSE": "boundary", "ACT": "boundary", "CODE": "code",
    "ROUTE": "flow", "LOOP": "flow", "CALL": "flow", "SPAWN": "flow",
    "TERMINAL": "terminal"
};

def _group_for(ntype: str) -> str {
    # `ACT·artifact` / `ACT·workspace` share the ACT surface; split on the dot
    # separator the contract uses so both land in the same group.
    t: str = str(ntype or "").strip();
    head: str = t.split("·", 1)[0].strip() if ("·" in t) else t;
    if head in _GROUPS { return str(_GROUPS[head]); }
    return "other";
}

def _as_list(v: any) -> list {
    if v is None { return []; }
    if isinstance(v, list) { return list(v); }
    return [v];
}

def parse_agir(text: str) -> dict {
    # AG-IR YAML -> {nodes, edges, tools, carries, warning}. Total: never raises.
    out: dict = {"nodes": [], "edges": [], "tools": [], "carries": [], "warning": ""};
    if not str(text or "").strip() {
        out["warning"] = "this skill has no stored AG-IR";
        return out;
    }
    # Same reader the mechanical back-end uses, so what draws is what compiles.
    ir: dict = load_agir(text);
    if not [k for k in ir.keys() if str(k) != "_frontmatter"] {
        out["warning"] = "the stored AG-IR could not be decoded";
        return out;
    }
    # which tool serves which node — so a node can show what it actually runs
    serves: dict = {};
    tools_raw: any = ir.get("tools") or {};
    tool_names: list = [];
    if isinstance(tools_raw, dict) {
        for (tname, tbody) in tools_raw.items() {
            tool_names.append(str(tname));
            if isinstance(tbody, dict) {
                for nid in _as_list(tbody.get("serves")) { serves[str(nid)] = str(tname); }
            }
        }
    }
    out["tools"] = tool_names;

    wk: any = ir.get("walker") or {};   # not `walker` — that is a Jac keyword
    if isinstance(wk, dict) {
        carries: any = wk.get("carries") or {};
        if isinstance(carries, dict) {
            for (cname, cbody) in carries.items() {
                role: str = "";
                if isinstance(cbody, dict) { role = str(cbody.get("role") or cbody.get("type") or ""); }
                out["carries"].append({"name": str(cname), "role": role});
            }
        }
    }

    seen: dict = {};
    for n in _as_list(ir.get("nodes")) {
        if not isinstance(n, dict) { continue; }
        nid: str = str(n.get("id") or "").strip();
        if not nid { continue; }
        ntype: str = str(n.get("type") or "");
        seen[nid] = True;
        out["nodes"].append({
            "id": nid,
            "type": ntype,
            "group": _group_for(ntype),
            "owner": str(n.get("owner") or ("code" if _group_for(ntype) == "code" else "")),
            "op": str(n.get("op") or ""),
            "tool": str(n.get("tool") or serves.get(nid) or ""),
            "reads": [str(x) for x in _as_list(n.get("reads"))],
            "writes": [str(x) for x in _as_list(n.get("writes"))],
            "doc": str(n.get("doc") or "")[:400],
            "traces_to": [str(x) for x in _as_list(n.get("traces_to"))]
        });
    }
    for e in _as_list(ir.get("edges")) {
        if not isinstance(e, dict) { continue; }
        src: str = str(e.get("from") or "").strip();
        dst: str = str(e.get("to") or "").strip();
        if (not src) or (not dst) { continue; }
        out["edges"].append({
            "from": src, "to": dst,
            "modality": str(e.get("modality") or ""),
            "label": str(e.get("when") or e.get("label") or "")[:60]
        });
    }
    # An edge naming a node that does not exist would silently vanish from the
    # canvas; say so instead, because it means the IR itself is inconsistent.
    dangling: list = [str(e["from"]) + "->" + str(e["to"]) for e in out["edges"]
                      if (str(e["from"]) not in seen) or (str(e["to"]) not in seen)];
    if dangling {
        out["warning"] = "edges reference unknown nodes: " + ", ".join(dangling[:4]);
    } elif not out["nodes"] {
        out["warning"] = "the AG-IR declares no nodes";
    }
    return out;
}

def skill_agir(signature: str) -> dict {
    # The drawable AG-IR for one compiled skill, latest version.
    sig: str = str(signature or "").strip();
    reg = [root -->][?:Registry];
    if not reg { return {"ok": False, "error": "no registry on this graph"}; }
    for tg in latest_by_sig([reg[0] -->][?:TaskGraph]) {
        if tg.signature == sig {
            g: dict = parse_agir(tg.agir);
            g["ok"] = True;
            g["signature"] = tg.signature;
            g["version"] = tg.version;
            g["intent"] = tg.intent;
            g["origin"] = tg.origin;
            return g;
        }
    }
    return {"ok": False, "error": "no compiled skill named '" + sig + "'"};
}

"""Prometheus agent-graph canvas — same mechanism as the AG-IR studio: vis-network
free-floating, draggable, physics-laid-out nodes (forceAtlas2Based), zoom/pan.

The network is built ONCE on mount; every poll UPSERTS nodes/edges into the live
DataSets (add new, update changed, remove gone) in place — so watching the agent
evolve never resets the zoom/pan/layout, and new skills/memories animate in.
"""

import from "./vis_interop.js" { makeNetwork, makeDataSet }

# node group -> vis colour object (background / border / hover highlight)
def _vcolor(group: str) -> dict {
    bg = "#64748b";
    if group == "soul" { bg = "#f59e0b"; }
    elif group == "registry" { bg = "#6366f1"; }
    elif group == "skill" { bg = "#10b981"; }
    elif group == "memory" { bg = "#0ea5e9"; }
    elif group == "mcp" { bg = "#8b5cf6"; }
    elif group == "attempt-ok" { bg = "#22c55e"; }
    elif group == "attempt-fail" { bg = "#ef4444"; }
    return {"background": bg, "border": bg, "highlight": {"background": "#fbbf24", "border": "#f59e0b"}};
}

def _eid(src: str, dst: str, kind: str) -> str { return src + "->" + dst + ":" + kind; }

def:pub GraphCanvas(nodes: list, edges: list) -> JsxElement {
    has containerRef: Ref[any] = Ref();
    has netRef: Ref[any] = Ref();
    has dsNodesRef: Ref[any] = Ref();
    has dsEdgesRef: Ref[any] = Ref();

    # ----- build the network ONCE on mount -----
    can init with entry {
        cr: any = containerRef;
        el = cr.current;
        if not el { return; }
        nr: any = netRef;
        if nr.current { return; }
        dn: any = makeDataSet([]);
        de: any = makeDataSet([]);
        dnr: any = dsNodesRef;
        der: any = dsEdgesRef;
        dnr.current = dn;
        der.current = de;
        options: dict = {
            "autoResize": True,
            "nodes": {"shape": "dot", "size": 16, "borderWidth": 2,
                      "font": {"color": "#e2e8f0", "size": 13, "face": "ui-sans-serif"},
                      "shadow": {"enabled": True, "color": "rgba(0,0,0,0.25)", "size": 6}},
            "edges": {"width": 1.4, "color": {"color": "#475569", "opacity": 0.85},
                      "arrows": {"to": {"enabled": True, "scaleFactor": 0.5}},
                      "font": {"size": 9, "color": "#94a3b8", "strokeWidth": 0, "align": "middle"},
                      "smooth": {"type": "continuous", "forceDirection": "none"}},
            "interaction": {"hover": True, "tooltipDelay": 150, "zoomView": True, "dragView": True, "dragNodes": True},
            "layout": {"improvedLayout": True},
            "physics": {"enabled": True, "solver": "forceAtlas2Based",
                        "forceAtlas2Based": {"gravitationalConstant": -55, "centralGravity": 0.012,
                                             "springLength": 130, "springConstant": 0.08,
                                             "damping": 0.45, "avoidOverlap": 0.9},
                        "stabilization": {"enabled": True, "iterations": 200, "updateInterval": 25, "fit": True}}
        };
        nr.current = makeNetwork(el, {"nodes": dn, "edges": de}, options);
    }

    # ----- upsert on every data change (in-place; layout/zoom preserved) -----
    can sync with (nodes, edges) entry {
        dnr: any = dsNodesRef;
        der: any = dsEdgesRef;
        if (not dnr.current) or (not der.current) { return; }

        vn = [{"id": str(n.id), "label": str(n.label), "color": _vcolor(str(n.group)),
               "shape": ("box" if (str(n.group) == "memory") else "dot"),
               "title": str(n.detail)} for n in nodes];
        ve = [{"id": _eid(str(e.src), str(e.dst), str(e.kind)),
               "from": str(e.src), "to": str(e.dst), "label": str(e.kind)} for e in edges];
        dnr.current.update(vn);
        der.current.update(ve);

        # prune nodes/edges that no longer exist
        keepN: dict = {};
        for n in nodes { keepN[str(n.id)] = True; }
        goneN = [str(x["id"]) for x in dnr.current.get() if str(x["id"]) not in keepN];
        if goneN { dnr.current.remove(goneN); }
        keepE: dict = {};
        for e in edges { keepE[_eid(str(e.src), str(e.dst), str(e.kind))] = True; }
        goneE = [str(x["id"]) for x in der.current.get() if str(x["id"]) not in keepE];
        if goneE { der.current.remove(goneE); }
    }

    return <div ref={containerRef}
                style={{"position": "absolute", "top": "0", "left": "0", "right": "0", "bottom": "0"}}></div>;
}

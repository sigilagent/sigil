"""Sigil agent-graph canvas — same mechanism as the AG-IR studio: vis-network
free-floating, draggable, physics-laid-out nodes (forceAtlas2Based), zoom/pan.

The network is built ONCE on mount; every poll UPSERTS nodes/edges into the live
DataSets (add new, update changed, remove gone) in place — so watching the agent
evolve never resets the zoom/pan/layout, and new skills/memories animate in.
Theme-aware: node/edge/label colours re-flow through the same upsert when `dark`
flips. Clicking a node reports (id, label) up via `onSelect`; the label is read
from the live DataSet (a stable ref) so the once-registered vis handler never
closes over stale component state.
"""

import from "./vis_interop.js" { makeNetwork, makeDataSet }

# node group -> vis colour object (background / border / hover highlight).
# Palette = the website's (docs/index.html): gold soul, violet registry,
# cyan compiled core (skills), light-violet memory, sky mcp.
def _vcolor(group: str) -> dict {
    bg = "#6f6c86";
    if group == "soul" { bg = "#f5c451"; }
    elif group == "registry" { bg = "#8b5cf6"; }
    elif group == "skill" { bg = "#22d3ee"; }
    elif group == "memory" { bg = "#a78bfa"; }
    elif group == "mcp" { bg = "#38bdf8"; }
    elif group == "attempt-ok" { bg = "#4ade80"; }
    elif group == "attempt-fail" { bg = "#f87171"; }
    return {"background": bg, "border": bg, "highlight": {"background": "#f5c451", "border": "#fbbf24"}};
}

def _eid(src: str, dst: str, kind: str) -> str { return src + "->" + dst + ":" + kind; }

def:pub GraphCanvas(nodes: list, edges: list, dark: bool, sel: str, onSelect: Callable[[str, str], None]) -> JsxElement {
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
                      "shadow": {"enabled": True, "color": "rgba(0,0,0,0.25)", "size": 6}},
            "edges": {"width": 1.4,
                      "arrows": {"to": {"enabled": True, "scaleFactor": 0.5}},
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
        net: any = nr.current;
        # An attempt node ("tg:0:a1") reports its PARENT skill's label so the app
        # can resolve the signature without touching (stale) graph state.
        net.on("selectNode", lambda (p: any) {
            nid = str((p["nodes"])[0]);
            base = nid.split(":a")[0];
            nd: any = dn.get(base);
            onSelect(nid, (str(nd["label"]) if nd else ""));
        });
        net.on("deselectNode", lambda (p: any) { onSelect("", ""); });
    }

    # ----- upsert on every data/theme change (in-place; layout/zoom preserved) -----
    can sync with (nodes, edges, dark) entry {
        dnr: any = dsNodesRef;
        der: any = dsEdgesRef;
        if (not dnr.current) or (not der.current) { return; }

        fontColor = "#e9e7f3" if dark else "#1a1826";
        edgeColor = "#3f3b54" if dark else "#9d9ab4";
        labelColor = "#9d9ab4" if dark else "#6f6c86";

        # truthy fallbacks: a malformed report must never hand undefined to .map
        ns = nodes if nodes else [];
        es = edges if edges else [];
        vn = [{"id": str(n.id), "label": str(n.label), "color": _vcolor(str(n.group)),
               "shape": ("box" if (str(n.group) == "memory") else "dot"),
               "font": {"color": fontColor, "size": 13, "face": "ui-sans-serif"},
               "title": str(n.detail)} for n in ns];
        ve = [{"id": _eid(str(e.src), str(e.dst), str(e.kind)),
               "from": str(e.src), "to": str(e.dst), "label": str(e.kind),
               "color": {"color": edgeColor, "opacity": 0.85},
               "font": {"size": 9, "color": labelColor, "strokeWidth": 0, "align": "middle"}} for e in es];
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

    # ----- reflect the app-side selection (sidebar click, ✕ dismiss) -----
    can select with (sel) entry {
        nr: any = netRef;
        dnr: any = dsNodesRef;
        if (not nr.current) or (not dnr.current) { return; }
        if not sel { nr.current.unselectAll(); return; }
        nd: any = dnr.current.get(str(sel));
        if nd { nr.current.selectNodes([str(sel)]); }
    }

    return <div ref={containerRef} className="absolute inset-0"></div>;
}

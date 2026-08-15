"""AG-IR canvas — a compiled skill's typed contract, drawn as the graph it is.

Sibling of graph_canvas.cl.jac, and deliberately not the same component. That one
draws the AGENT's graph: an evolving web of skills and memories, laid out by
physics because it has no natural direction. An AG-IR is a control-flow graph with
a start and a terminal, so it is laid out hierarchically left-to-right and reads
like the flowchart the skill's steps actually are.

Colour is by primitive family, matching src/contracts/: what the model owns, what
code owns, what crosses the boundary, and what routes. That is the property worth
seeing at a glance — a skill whose mandated steps are all violet is one where the
compiler left everything to model judgment.

The network is rebuilt when the node set changes (an AG-IR is static per skill
version, unlike the live agent graph, so there is nothing to preserve across a
switch) and re-themed in place when `dark` flips.
"""

import from "./vis_interop.js" { makeNetwork, makeDataSet }

# AG-IR primitive family -> colour. Mind = model-owned cognition (violet, the
# registry colour), code = deterministic (cyan, the compiled-core colour),
# boundary = SENSE/ACT touching the world (sky), flow = control (gold).
def _acolor(group: str) -> dict {
    bg = "#6f6c86";
    if group == "mind" { bg = "#a78bfa"; }
    elif group == "code" { bg = "#22d3ee"; }
    elif group == "boundary" { bg = "#38bdf8"; }
    elif group == "flow" { bg = "#f5c451"; }
    elif group == "terminal" { bg = "#4ade80"; }
    return {"background": bg, "border": bg,
            "highlight": {"background": "#f5c451", "border": "#fbbf24"}};
}

def _tooltip(n: any) -> str {
    # vis renders the title as plain text; keep it to lines a person can scan.
    bits: list = [str(n.id) + "  [" + str(n.type) + "]"];
    if str(n.owner) { bits.append("owner: " + str(n.owner)); }
    if str(n.tool) { bits.append("tool: " + str(n.tool)); }
    if n.reads { bits.append("reads: " + ", ".join([str(x) for x in n.reads])); }
    if n.writes { bits.append("writes: " + ", ".join([str(x) for x in n.writes])); }
    if n.traces_to { bits.append("realizes: " + ", ".join([str(x) for x in n.traces_to])); }
    if str(n.doc) { bits.append(""); bits.append(str(n.doc)); }
    return "\n".join(bits);
}

def:pub AgirCanvas(nodes: list, edges: list, dark: bool,
                   onSelect: Callable[[str], None]) -> JsxElement {
    has containerRef: Ref[any] = Ref();
    has netRef: Ref[any] = Ref();

    can draw with (nodes, edges, dark) entry {
        cr: any = containerRef;
        el = cr.current;
        if not el { return; }

        fontColor = "#e9e7f3" if dark else "#1a1826";
        edgeColor = "#3f3b54" if dark else "#9d9ab4";
        labelColor = "#9d9ab4" if dark else "#6f6c86";

        ns = nodes if nodes else [];
        es = edges if edges else [];
        vn = [{"id": str(n.id), "label": str(n.id),
               "color": _acolor(str(n.group)),
               # a model-owned slot is a diamond, code is a box, the rest are dots:
               # the shape says who decides, before you have read a single label
               "shape": ("diamond" if (str(n.group) == "mind")
                         else ("box" if (str(n.group) == "code") else "dot")),
               "font": {"color": fontColor, "size": 12, "face": "ui-monospace"},
               "title": _tooltip(n)} for n in ns];
        # a forbidden/optional edge should not read like the mandated spine
        ve = [{"id": str(e.src) + "->" + str(e.dst),
               "from": str(e.src), "to": str(e.dst),
               "label": str(e.label),
               "dashes": (str(e.modality) != "mandatory"),
               "color": {"color": edgeColor, "opacity": 0.9},
               "font": {"size": 9, "color": labelColor, "strokeWidth": 0, "align": "middle"}}
              for e in es];

        options: dict = {
            "autoResize": True,
            "nodes": {"size": 14, "borderWidth": 2,
                      "shadow": {"enabled": True, "color": "rgba(0,0,0,0.25)", "size": 5}},
            "edges": {"width": 1.4,
                      "arrows": {"to": {"enabled": True, "scaleFactor": 0.55}},
                      "smooth": {"type": "cubicBezier", "forceDirection": "horizontal",
                                 "roundness": 0.45}},
            "interaction": {"hover": True, "tooltipDelay": 120,
                            "zoomView": True, "dragView": True, "dragNodes": True},
            # A contract has a direction; physics would hide it.
            "layout": {"hierarchical": {"enabled": True, "direction": "LR",
                                        "sortMethod": "directed",
                                        "levelSeparation": 170, "nodeSpacing": 110}},
            "physics": {"enabled": False}
        };
        nr: any = netRef;
        dn: any = makeDataSet(vn);
        de: any = makeDataSet(ve);
        nr.current = makeNetwork(el, {"nodes": dn, "edges": de}, options);
        net: any = nr.current;
        net.on("selectNode", lambda (p: any) { onSelect(str((p["nodes"])[0])); });
        net.on("deselectNode", lambda (p: any) { onSelect(""); });
    }

    return <div ref={containerRef} className="absolute inset-0"></div>;
}

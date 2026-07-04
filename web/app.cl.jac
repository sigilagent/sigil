"""Prometheus Observatory — the browser app.

Left: the agent's own graph, drawn live from `api_graph` (soul · registry · skills ·
memory · MCP servers · run lineage), re-polled so you watch it evolve as tasks are
solved. Right: 100% token observability — every LLM call captured by prom_observe
(model, in/out/reasoning tokens, cache, cost, content, tool calls).
"""

sv import from prometheus { api_graph, api_observability, api_solve }

# positioned draw items
obj Dot { has x: float = 0.0; has y: float = 0.0; has label: str = ""; has color: str = ""; has detail: str = ""; }
obj Seg { has x1: float = 0.0; has y1: float = 0.0; has x2: float = 0.0; has y2: float = 0.0; }

def _color(g: str) -> str {
    if g == "soul" { return "#f59e0b"; }
    if g == "registry" { return "#6366f1"; }
    if g == "skill" { return "#10b981"; }
    if g == "memory" { return "#0ea5e9"; }
    if g == "mcp" { return "#8b5cf6"; }
    if g == "attempt-ok" { return "#22c55e"; }
    if g == "attempt-fail" { return "#ef4444"; }
    return "#64748b";
}

def _cluster(g: str) -> str {
    if (g == "attempt-ok") or (g == "attempt-fail") { return "attempt"; }
    return g;
}

# deterministic column layout (no trig -> compiles cleanly)
def _basexy(c: str) -> list[float] {
    if c == "soul" { return [70.0, 300.0]; }
    if c == "registry" { return [240.0, 110.0]; }
    if c == "mcp" { return [240.0, 400.0]; }
    if c == "memory" { return [240.0, 520.0]; }
    if c == "skill" { return [440.0, 70.0]; }
    if c == "attempt" { return [640.0, 50.0]; }
    return [440.0, 50.0];
}

def:pub App() -> JsxElement {
    has graph: any = None;
    has obs: any = None;
    has task: str = "";
    has status: str = "idle";
    has timer: any = 0;

    def refresh() -> None {
        rg = root spawn api_graph();
        if rg.reports { graph = rg.reports[0]; }
        ro = root spawn api_observability(n=150);
        if ro.reports { obs = ro.reports[0]; }
    }

    def launch() -> None {
        if not task { return; }
        status = "solving…";
        root spawn api_solve(task=task, skill="");
        status = "idle";
        refresh();
    }

    can with entry {
        refresh();
        timer = setInterval(lambda -> None { refresh(); }, 2000);
    }
    can with exit {
        clearInterval(float(str(timer)));
    }

    # ---- build graph geometry ----
    gnodes = graph.nodes if graph is not None else [];
    gedges = graph.edges if graph is not None else [];
    dots: list[Dot] = [];
    dmap: dict = {};
    cnt: dict = {};
    for n in gnodes {
        c = _cluster(str(n.group));
        b = _basexy(c);
        i = int(cnt[c]) if c in cnt else 0;
        cnt[c] = i + 1;
        d = Dot(x=b[0], y=b[1] + (float(i) * 52.0), label=str(n.label),
                color=_color(str(n.group)), detail=str(n.detail));
        dots.append(d);
        dmap[str(n.id)] = d;
    }
    segs: list[Seg] = [];
    for e in gedges {
        if (str(e.src) in dmap) and (str(e.dst) in dmap) {
            a = dmap[str(e.src)];
            z = dmap[str(e.dst)];
            segs.append(Seg(x1=float(str(a.x)), y1=float(str(a.y)),
                            x2=float(str(z.x)), y2=float(str(z.y))));
        }
    }

    calls: list = list(reversed(obs.calls)) if obs is not None else [];
    sk = str(graph.skills) if graph is not None else "0";
    mm = str(graph.memories) if graph is not None else "0";
    mc = str(graph.mcp) if graph is not None else "0";
    tin = str(obs.tin) if obs is not None else "0";
    tout = str(obs.tout) if obs is not None else "0";
    treason = str(obs.treason) if obs is not None else "0";
    tcost = str(obs.cost) if obs is not None else "0";
    ncalls = str(obs.n) if obs is not None else "0";

    return <div style={{"display": "flex", "height": "100vh", "fontFamily": "ui-sans-serif, system-ui",
                        "background": "#0b1220", "color": "#e2e8f0"}}>
        <div style={{"flex": "1.4", "borderRight": "1px solid #1e293b", "display": "flex", "flexDirection": "column"}}>
            <div style={{"padding": "14px 18px", "borderBottom": "1px solid #1e293b"}}>
                <div style={{"fontSize": "18px", "fontWeight": "700"}}>🔥 Prometheus Observatory</div>
                <div style={{"fontSize": "12px", "color": "#94a3b8"}}>
                    {"skills " + sk + " · memories " + mm + " · mcp " + mc + " · " + status}
                </div>
            </div>
            <div style={{"flex": "1", "overflow": "auto"}}>
                <svg width="820" height="820">
                    {[<line x1={s.x1} y1={s.y1} x2={s.x2} y2={s.y2}
                            stroke="#334155" strokeWidth="1.4" /> for s in segs]}
                    {[<g>
                        <circle cx={d.x} cy={d.y} r="11" fill={d.color} stroke="#0b1220" strokeWidth="2">
                            <title>{d.detail}</title>
                        </circle>
                        <text x={d.x + 16} y={d.y + 4} fill="#cbd5e1" fontSize="11">{d.label}</text>
                    </g> for d in dots]}
                </svg>
            </div>
            <div style={{"padding": "12px 18px", "borderTop": "1px solid #1e293b", "display": "flex", "gap": "8px"}}>
                <input value={task} placeholder="give the agent a task…"
                       onChange={lambda e: ChangeEvent { task = e.target.value; }}
                       onKeyDown={lambda e: KeyboardEvent { if e.key == "Enter" { launch(); } }}
                       style={{"flex": "1", "padding": "9px 12px", "borderRadius": "8px",
                               "border": "1px solid #334155", "background": "#0f172a", "color": "#e2e8f0"}} />
                <button onClick={lambda -> None { launch(); }}
                        style={{"padding": "9px 18px", "borderRadius": "8px", "border": "none",
                                "background": "#f59e0b", "color": "#0b1220", "fontWeight": "700", "cursor": "pointer"}}>
                    solve
                </button>
            </div>
        </div>

        <div style={{"flex": "1", "display": "flex", "flexDirection": "column", "minWidth": "360px"}}>
            <div style={{"padding": "14px 18px", "borderBottom": "1px solid #1e293b"}}>
                <div style={{"fontSize": "14px", "fontWeight": "700"}}>token observability</div>
                <div style={{"fontSize": "12px", "color": "#94a3b8"}}>
                    {"in " + tin + " · out " + tout + " · reasoning " + treason + " · $" + tcost + " · " + ncalls + " calls"}
                </div>
            </div>
            <div style={{"flex": "1", "overflow": "auto", "padding": "10px 14px", "fontSize": "12px"}}>
                {[<div style={{"borderBottom": "1px solid #1e293b", "padding": "8px 0"}}>
                    <div style={{"display": "flex", "justifyContent": "space-between", "color": "#94a3b8"}}>
                        <span>{str(c.model) + "  ·  " + str(c.signature)}</span>
                        <span>{"in " + str(c.prompt_tokens) + " out " + str(c.completion_tokens)
                               + (" r" + str(c.reasoning_tokens) if c.reasoning_tokens else "")}</span>
                    </div>
                    <div style={{"color": "#cbd5e1", "whiteSpace": "pre-wrap"}}>{str(c.content)}</div>
                    {(str(c.reasoning) if c.reasoning else "") and
                        <div style={{"color": "#64748b", "fontStyle": "italic"}}>
                            {"reasoning: " + str(c.reasoning)}
                        </div>}
                </div> for c in calls]}
            </div>
        </div>
    </div>;
}

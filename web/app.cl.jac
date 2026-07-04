"""Prometheus Observatory — the browser app.

Left: the agent's own graph, drawn live with vis-network (same mechanism as the
AG-IR studio) from `api_graph` — soul · registry · skills · memory · MCP servers ·
run lineage — re-polled and upserted in place so you watch it evolve as tasks are
solved. Right: 100% token observability — every LLM call captured by prom_observe.
"""

sv import from prometheus { api_graph, api_observability, api_solve }
import from .graph_canvas { GraphCanvas }

def:pub App() -> JsxElement {
    has graph: any = None;
    has obs: any = None;
    has task: str = "";
    has status: str = "idle";
    has timer: any = 0;

    async def refresh() {
        rg = root spawn api_graph();
        if rg.reports { graph = rg.reports[0]; }
        ro = root spawn api_observability(n=150);
        if ro.reports { obs = ro.reports[0]; }
    }

    async def launch() {
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

    gnodes = graph.nodes if graph is not None else [];
    gedges = graph.edges if graph is not None else [];
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
            <div style={{"flex": "1", "position": "relative", "overflow": "hidden"}}>
                <GraphCanvas nodes={gnodes} edges={gedges} />
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

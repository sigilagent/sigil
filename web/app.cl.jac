"""Sigil Observatory — the full dashboard, styled like the website.

Left: the skill library + the graph legend. Center: the agent's own graph drawn
live with vis-network from `api_graph` (soul · registry · skills · memory · MCP ·
run lineage) — re-polled and upserted in place so the layout never resets — plus
the chat bar. Right: tabs — chat (each message routes as a task: HIT / MISS /
MUTATE, with the trace one click away), 100% token observability, cron (the
schedule, with a manual tick), ops (work feed · hooks · channels · approvals),
the soul, the selected skill (eval / relearn / forget), MCP servers, and memory
(teach / recall).

Every endpoint answers by running the request against the agent's REAL graph in
a fresh `jac run` process (see sigil_api), so each fetch costs a process start:
the 2.5s poll covers only graph + token tail; soul/library/mcp re-fetch when the
graph's counts change, and cron/ops load when their tab opens (or on ↻).
"""

sv import from src.sigil {
    api_graph, api_observability, api_solve, api_soul, api_library, api_mcp,
    api_teach, api_recall, api_eval, api_relearn, api_forget,
    api_cron_list, api_cron_runs, api_cron_enable, api_cron_remove,
    api_skill_agir, api_tasks, api_hooks, api_channels, api_approvals
}
sv import from src.cron { api_cron_tick }
import from .graph_canvas { GraphCanvas }
import from .agir_canvas { AgirCanvas }
import from "./time_interop.js" { fmtWhen }
import from react { useEffect }

glob BTN: str = "px-3 py-1.5 rounded-md bg-violet-600 hover:bg-violet-500 text-white text-xs font-bold transition-colors";
glob BTN2: str = "px-3 py-1.5 rounded-md border border-slate-300 dark:border-slate-700 text-xs hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors";
glob CHIP: str = "px-2 py-0.5 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 text-[11px] font-mono";
glob INP: str = "px-2 py-1 rounded-md border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-800 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500";
glob TILE: str = "rounded-lg border border-slate-200 dark:border-slate-800 p-2";

# AG-IR legend: [key, dot colour, label] — mirrors agir_canvas._acolor, which
# mirrors the primitive families in src/contracts/.
glob AGIR_LEGEND: list = [
    ["mind", "bg-[#a78bfa]", "model slot"],
    ["code", "bg-[#22d3ee]", "code"],
    ["boundary", "bg-[#38bdf8]", "sense / act"],
    ["flow", "bg-[#f5c451]", "route / loop"],
    ["terminal", "bg-[#4ade80]", "terminal"]
];

# graph legend: [label, dot colour, shape, blurb] — mirrors graph_canvas._vcolor
# (the website's palette: gold soul, violet registry, cyan compiled core).
glob LEGEND: list = [
    ["soul", "bg-[#f5c451]", "rounded-full", "identity + config"],
    ["registry", "bg-[#8b5cf6]", "rounded-full", "anchors the skills"],
    ["skill", "bg-[#22d3ee]", "rounded-full", "compiled procedure"],
    ["memory", "bg-[#a78bfa]", "rounded-sm", "durable fact"],
    ["mcp", "bg-[#38bdf8]", "rounded-full", "registered tool server"],
    ["ran ok", "bg-[#4ade80]", "rounded-full", "attempt succeeded"],
    ["ran fail", "bg-[#f87171]", "rounded-full", "attempt failed"]
];

# skill health dot: never run → grey; all ok → green; some ok → gold; none → red
def _dot(s: any) -> str {
    r = int(str(s.runs));
    ok = int(str(s.successes));
    if r == 0 { return "bg-slate-400"; }
    if ok == r { return "bg-[#4ade80]"; }
    if ok > 0 { return "bg-[#f5c451]"; }
    return "bg-[#f87171]";
}

def _money(v: any) -> str {
    return "$" + str(int(float(str(v)) * 10000.0 + 0.5) / 10000.0);
}

# colour a solve-trace line by what it reports
def _traceCls(ln: str) -> str {
    if "DONE ok" in ln { return "text-green-600 dark:text-green-400 font-semibold"; }
    if ("FAIL" in ln) or ("DONE fail" in ln) { return "text-rose-500 font-semibold"; }
    if ("compiled" in ln) or ("mutated" in ln) or ("relearn" in ln) { return "text-amber-600 dark:text-sigil-gold"; }
    if ("route" in ln) or ("HIT" in ln) { return "text-cyan-600 dark:text-cyan-400"; }
    return "text-slate-500 dark:text-slate-400";
}

def:pub App() -> JsxElement {
    has dark: bool = True,
        tab: str = "chat",
        status: str = "connecting…",
        live: bool = True;
    has graph: any = None,
        obs: any = None,
        soul: any = None,
        lib: list = [],
        mcp: list = [];
    has libN: str = "?",
        memN: str = "?",
        mcpN: str = "?";
    has gSel: str = "",
        selSkill: str = "";
    has task: str = "",
        solving: bool = False;
    has chat: list = [],
        traceOpen: int = -1;
    has cron: list = [],
        opsTasks: list = [],
        hooks: list = [],
        channels: list = [],
        approvals: any = None,
        ticking: bool = False;
    has callSel: int = -1;
    has teachFact: str = "",
        teachKind: str = "fact",
        teachMsg: str = "";
    has recallQ: str = "",
        recallRes: list = [];
    has agir: any = None,
        agirSig: str = "",
        agirNode: str = "",
        agirLoading: bool = False;
    has cronRuns: dict = {},
        cronOpen: str = "",
        cronBusy: str = "";
    has probe: str = "",
        hint: str = "",
        actMsg: str = "",
        acting: bool = False,
        confirmForget: bool = False;

    async def fetchLibrary() {
        r = root spawn api_library();
        if r.reports {
            l = r.reports[0];
            if (l is not None) and (not l.error) { lib = list(l); }
        }
    }

    async def fetchSoul() {
        r = root spawn api_soul();
        if r.reports {
            s = r.reports[0];
            if (s is not None) and (not s.error) { soul = s; }
        }
    }

    async def fetchMcp() {
        r = root spawn api_mcp();
        if r.reports {
            m = r.reports[0];
            if (m is not None) and (not m.error) { mcp = list(m); }
        }
    }

    async def fetchCron() {
        r = root spawn api_cron_list();
        if r.reports {
            m = r.reports[0];
            if (m is not None) and (not m.error) { cron = list(m); }
        }
    }

    # The AG-IR for the selected skill. Fetched on demand rather than polled: it
    # only changes when the skill is recompiled, and each call is a whole process.
    async def fetchAgir(sig: str) {
        if (not sig) or agirLoading { return; }
        agirLoading = True;
        agirNode = "";
        r = root spawn api_skill_agir(signature=sig);
        agirLoading = False;
        if r.reports {
            m = r.reports[0];
            if (m is not None) and (not m.error) { agir = m; agirSig = sig; }
            else { agir = None; agirSig = ""; }
        }
    }

    # Run history for one job, folded open on click. The CronRun nodes have always
    # been on the graph; nothing surfaced them.
    async def toggleRuns(name: str) {
        if cronOpen == name { cronOpen = ""; return; }
        cronOpen = name;
        r = root spawn api_cron_runs(name=name);
        if r.reports {
            m = r.reports[0];
            if (m is not None) and (not m.error) { cronRuns = {**cronRuns, name: list(m)}; }
        }
    }

    async def setCronEnabled(name: str, on: bool) {
        if cronBusy { return; }
        cronBusy = name;
        root spawn api_cron_enable(name=name, on=on);
        cronBusy = "";
        fetchCron();
    }

    async def dropCron(name: str) {
        if cronBusy { return; }
        cronBusy = name;
        root spawn api_cron_remove(name=name);
        cronBusy = "";
        cronOpen = "";
        fetchCron();
    }

    async def fetchOps() {
        r = root spawn api_tasks(n=30);
        if r.reports {
            m = r.reports[0];
            if (m is not None) and (not m.error) { opsTasks = list(m); }
        }
        rh = root spawn api_hooks();
        if rh.reports {
            h = rh.reports[0];
            if (h is not None) and (not h.error) { hooks = list(h); }
        }
        rc = root spawn api_channels();
        if rc.reports {
            c = rc.reports[0];
            if (c is not None) and (not c.error) { channels = list(c); }
        }
        ra = root spawn api_approvals();
        if ra.reports {
            a = ra.reports[0];
            if (a is not None) and (not a.error) { approvals = a; }
        }
    }

    async def tickCron() {
        if ticking { return; }
        ticking = True;
        root spawn api_cron_tick();
        ticking = False;
        fetchCron();
        fetchOps();
        refresh();
    }

    async def refresh() {
        rg = root spawn api_graph();
        if rg.reports {
            g = rg.reports[0];
            if (g is not None) and (not g.error) and g.nodes {
                graph = g;
                status = str(g.skills) + " skills · " + str(g.memories) + " memories · " + str(g.mcp) + " mcp";
                # the graph's counts are the change signal for the heavier fetches
                if str(g.skills) != libN { libN = str(g.skills); fetchLibrary(); }
                if str(g.memories) != memN { memN = str(g.memories); fetchSoul(); }
                if str(g.mcp) != mcpN { mcpN = str(g.mcp); fetchMcp(); }
            } elif g is not None {
                status = "⚠ " + str(g.error);
            }
        }
        ro = root spawn api_observability(n=150);
        if ro.reports {
            o = ro.reports[0];
            if (o is not None) and (not o.error) { obs = o; }
        }
    }

    async def launch() {
        if (not task) or solving { return; }
        q = task;
        task = "";
        tab = "chat";
        solving = True;
        # local accumulator: after the await, `chat` reads the render-time
        # snapshot — appending to `log` keeps the user's bubble in the reply
        log = chat + [{"role": "you", "text": q, "signature": "", "trace": "", "err": False}];
        chat = log;
        r = root spawn api_solve(task=q, skill="");
        m: any = (r.reports[0] if r.reports else None);
        if (m is not None) and (not m.error) {
            log = log + [{"role": "sigil", "text": str(m.result), "signature": str(m.signature),
                          "trace": str(m.trace), "err": False}];
        } else {
            log = log + [{"role": "sigil",
                          "text": (("⚠ " + str(m.error)) if m is not None else "⚠ no response from the agent"),
                          "signature": "", "trace": "", "err": True}];
        }
        chat = log;
        solving = False;
        fetchLibrary();
        fetchSoul();
        refresh();
    }

    # canvas click → (id, label); label comes from the DataSet so no stale state is read
    async def pickNode(nid: str, lbl: str) {
        gSel = nid;
        confirmForget = False;
        if not nid { return; }
        kind = nid.split(":")[0];
        if kind == "tg" {
            if lbl { selSkill = lbl.split(" v")[0]; }
            tab = "skill";
            actMsg = "";
        } elif kind == "mem" { tab = "memory"; }
        elif kind == "mcp" { tab = "mcp"; }
        elif (nid == "soul") or (nid == "registry") { tab = "soul"; }
    }

    async def teachH() {
        if not teachFact { return; }
        r = root spawn api_teach(fact=teachFact, kind=teachKind);
        if r.reports {
            m = r.reports[0];
            teachMsg = ("⚠ " + str(m.error)) if ((m is not None) and m.error) else str(m);
        }
        teachFact = "";
        fetchSoul();
        refresh();
    }

    async def recallH() {
        if not recallQ { return; }
        r = root spawn api_recall(query=recallQ, k=8);
        if r.reports {
            m = r.reports[0];
            if (m is not None) and (not m.error) { recallRes = list(m); }
        }
    }

    async def evalH() {
        if (not selSkill) or acting { return; }
        acting = True;
        actMsg = "evaluating " + selSkill + " — running it on the probe, then judging the artifact…";
        r = root spawn api_eval(signature=selSkill, probe=probe);
        acting = False;
        if r.reports {
            m = r.reports[0];
            actMsg = ("⚠ " + str(m.error)) if ((m is not None) and m.error)
                     else ("score " + str(m.score) + "/100 — " + str(m.reason));
        }
        fetchLibrary();
        refresh();
    }

    async def relearnH() {
        if (not selSkill) or acting { return; }
        acting = True;
        actMsg = "relearning " + selSkill + " — the frontier re-authors the procedure from scratch…";
        r = root spawn api_relearn(signature=selSkill, hint=hint);
        acting = False;
        if r.reports {
            m = r.reports[0];
            actMsg = ("⚠ " + str(m.error)) if ((m is not None) and m.error)
                     else ("recompiled fresh → v" + str(m.version));
        }
        fetchLibrary();
        refresh();
    }

    async def forgetH() {
        if (not selSkill) or acting { return; }
        if not confirmForget { confirmForget = True; return; }
        confirmForget = False;
        acting = True;
        r = root spawn api_forget(signature=selSkill);
        acting = False;
        if r.reports {
            m = r.reports[0];
            actMsg = ("⚠ " + str(m.error)) if ((m is not None) and m.error)
                     else ("forgot " + str(m.removed) + " version(s)");
        }
        selSkill = "";
        fetchLibrary();
        refresh();
    }

    can with entry {
        refresh();
        fetchCron();
    }

    # live poll: graph + token tail every 4s while ◉ Live is on — each fetch
    # costs a whole `jac run` process (~seconds), so a tighter interval just
    # piles up subprocesses. The counter deps matter: they re-arm the interval
    # with a fresh closure after each change-detection write, so `refresh`
    # never reads a stale libN/memN/mcpN.
    useEffect(lambda {
        iv = setInterval(lambda { if live { refresh(); } }, 4000);
        return lambda { clearInterval(iv); };
    }, [live, libN, memN, mcpN]);

    gnodes = graph.nodes if graph is not None else [];
    gedges = graph.edges if graph is not None else [];
    calls: list = list(reversed(obs.calls)) if obs is not None else [];
    selNodes = ([n for n in gnodes if str(n.id) == gSel]) if gSel else [];

    return
        <div className={("dark " if dark else "") + "h-screen flex font-sans bg-slate-50 text-slate-900 dark:bg-slate-950 dark:text-slate-100 transition-colors overflow-hidden"}>

            <aside className="w-60 shrink-0 flex flex-col bg-white dark:bg-slate-900 border-r border-slate-200 dark:border-slate-800">
                <div className="px-4 py-4 flex items-center gap-2.5">
                    <svg viewBox="0 0 32 32" className="w-7 h-7 shrink-0" aria-hidden="true">
                        <g fill="none" stroke="#a78bfa" strokeWidth="1.2">
                            <polygon points="16,3 27.3,9.5 27.3,22.5 16,29 4.7,22.5 4.7,9.5"></polygon>
                            <path d="M16 3 L16 16 M27.3 9.5 L16 16 M27.3 22.5 L16 16 M16 29 L16 16 M4.7 22.5 L16 16 M4.7 9.5 L16 16"></path>
                        </g>
                        <polygon points="16,9.5 21.6,19.3 10.4,19.3" fill="none" stroke="#38bdf8" strokeWidth="1.2" strokeLinejoin="round"></polygon>
                        <circle cx="16" cy="16" r="2.2" fill="#38bdf8"></circle>
                    </svg>
                    <div className="font-bold text-lg tracking-tight">sigil <span className="font-medium text-slate-400 text-sm">observatory</span></div>
                </div>

                <div className="px-4 pb-1 text-[10px] uppercase tracking-wider text-slate-400 font-semibold">Skill library</div>
                <div className="flex-1 overflow-y-auto px-2">
                    {[
                        <div key={s.signature}
                            onClick={lambda (e: MouseEvent) { selSkill = str(s.signature); tab = "skill"; confirmForget = False; actMsg = ""; }}
                            className={"px-2 py-1.5 rounded-md cursor-pointer text-xs flex items-center gap-2 " + ("bg-violet-50 dark:bg-violet-500/10 text-violet-700 dark:text-violet-300 font-semibold" if (selSkill == str(s.signature)) else "hover:bg-slate-100 dark:hover:bg-slate-800")}>
                            <span className={"w-1.5 h-1.5 rounded-full shrink-0 " + _dot(s)}></span>
                            <span className="truncate flex-1">{s.signature}</span>
                            <span className="text-[10px] text-slate-400 font-mono">{"v" + str(s.version)}</span>
                        </div>
                        for s in lib
                    ]}
                    {(<div className="px-2 py-1 text-[11px] text-slate-400 leading-relaxed">No compiled skills yet — give the agent a task below, and a MISS compiles one.</div>) if (not lib) else <span></span>}
                </div>

                <div className="px-4 pt-3 pb-1 text-[10px] uppercase tracking-wider text-slate-400 font-semibold border-t border-slate-200 dark:border-slate-800">Graph legend</div>
                <div className="px-2 pb-2">
                    {[
                        <div key={lg[0]} className="px-2 py-0.5 text-[11px] flex items-center gap-2">
                            <span className={"w-2.5 h-2.5 shrink-0 " + str(lg[1]) + " " + str(lg[2])}></span>
                            <span className="font-semibold w-14">{lg[0]}</span>
                            <span className="text-slate-400 truncate">{lg[3]}</span>
                        </div>
                        for lg in LEGEND
                    ]}
                </div>

                <button onClick={lambda (e: MouseEvent) { dark = not dark; }} className="m-3 px-3 py-2 rounded-lg border border-slate-200 dark:border-slate-700 text-xs hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors">{"☀  Light" if dark else "🌙  Dark"}</button>
                <div className="px-4 pb-3 text-[11px] text-slate-400 truncate">{status}</div>
            </aside>

            <main className="flex-1 flex flex-col min-w-0">
                <header className="h-12 shrink-0 flex items-center gap-2 px-4 border-b border-slate-200 dark:border-slate-800">
                    <div className="font-semibold text-sm truncate">{str(soul.name) if soul is not None else "sigil"}</div>
                    {(<span className={CHIP}>{"frontier · " + str(soul.frontier_model)}</span>) if ((soul is not None) and soul.frontier_model) else <span></span>}
                    {(<span className={CHIP}>{"small · " + str(soul.small_model)}</span>) if ((soul is not None) and soul.small_model) else <span></span>}
                    {(<span className={CHIP}>{"router · " + str(soul.router_model)}</span>) if ((soul is not None) and soul.router_model) else <span></span>}
                    {(<span className="flex items-center gap-1.5 text-[11px] text-cyan-600 dark:text-cyan-400 font-semibold"><span className="w-2 h-2 rounded-full bg-cyan-400 animate-pulse"></span>solving</span>) if solving else <span></span>}
                    <div className="flex-1"></div>
                    <button onClick={lambda (e: MouseEvent) { live = not live; }}
                        title="Poll the agent's graph + token tail every 2.5s"
                        className={BTN2 + (" ring-2 ring-cyan-500 text-cyan-600 dark:text-cyan-400" if live else " text-slate-400")}>{"◉ Live" if live else "◌ Paused"}</button>
                    <button onClick={lambda (e: MouseEvent) { refresh(); fetchSoul(); fetchLibrary(); fetchMcp(); fetchCron(); fetchOps(); }} className={BTN2}>↻ Refresh</button>
                </header>

                <div className="flex-1 relative bg-slate-100/60 dark:bg-slate-900/40">
                    <GraphCanvas nodes={gnodes} edges={gedges} dark={dark} sel={gSel}
                        onSelect={lambda (nid: str, lbl: str) { pickNode(nid, lbl); }}/>
                    {(<div className="absolute inset-0 flex items-center justify-center text-slate-400 text-sm pointer-events-none">waking the agent…</div>) if (not gnodes) else <span></span>}

                    {[
                        <div key={"ov-" + str(n.id)} className="absolute bottom-3 left-3 max-w-sm rounded-lg border border-slate-200 dark:border-slate-700 bg-white/95 dark:bg-slate-900/95 backdrop-blur p-3 text-xs shadow-xl">
                            <div className="flex items-center gap-2">
                                <span className="font-mono font-bold truncate">{n.label}</span>
                                <span className={CHIP}>{n.group}</span>
                                <div className="flex-1"></div>
                                <button onClick={lambda (e: MouseEvent) { gSel = ""; }} className="text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 px-1" title="dismiss">✕</button>
                            </div>
                            {(<div className="mt-1 text-slate-500 dark:text-slate-400 leading-relaxed">{n.detail}</div>) if n.detail else <span></span>}
                        </div>
                        for n in selNodes
                    ]}
                </div>

                <div className="shrink-0 px-4 py-3 border-t border-slate-200 dark:border-slate-800 flex items-center gap-2 bg-white dark:bg-slate-900">
                    <input value={task} placeholder="chat with sigil — each message routes as a task: HIT re-runs a skill, MISS compiles one…"
                        onChange={lambda (e: ChangeEvent) { task = e.target.value; }}
                        onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { launch(); } }}
                        className={"flex-1 py-2 " + INP}/>
                    <button onClick={lambda (e: MouseEvent) { launch(); }} disabled={solving}
                        className={BTN + " py-2" + (" opacity-50" if solving else "")}>{"…thinking" if solving else "➤ send"}</button>
                </div>
            </main>

            <section className="w-[38%] max-w-xl shrink-0 flex flex-col border-l border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900">
                <div className="h-12 shrink-0 flex items-center gap-0.5 px-2 border-b border-slate-200 dark:border-slate-800">
                    {[
                        <button key={tb}
                            onClick={lambda (e: MouseEvent) { tab = tb; if tb == "cron" { fetchCron(); } elif tb == "ops" { fetchOps(); } }}
                            className={"px-2 py-1.5 rounded-md text-[11px] font-medium capitalize " + ("bg-violet-50 dark:bg-violet-500/10 text-violet-600 dark:text-violet-400" if (tab == tb) else "text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800")}>{tb}</button>
                        for tb in ["chat", "calls", "cron", "ops", "soul", "skill", "mcp", "memory"]
                    ]}
                    <div className="flex-1"></div>
                    {(<span className="text-[11px] text-amber-600 dark:text-sigil-gold font-mono pr-1">{_money(obs.cost)}</span>) if obs is not None else <span></span>}
                </div>

                <div className="flex-1 overflow-auto p-3 min-h-0">
                    {(
                        <div className="text-xs flex flex-col gap-2">
                            {[
                                <div key={"c-" + str(ci)} className={("self-end max-w-[90%]" if (str(cm.role) == "you") else "self-start w-full")}>
                                    {(
                                        <div className="px-3 py-2 rounded-2xl rounded-br-sm bg-violet-600 text-white whitespace-pre-wrap leading-relaxed">{cm.text}</div>
                                    ) if (str(cm.role) == "you") else (
                                        <div className={"rounded-2xl rounded-tl-sm border p-3 space-y-2 " + ("border-rose-300 dark:border-rose-800 bg-rose-50 dark:bg-rose-950/30" if cm.err else "border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-950")}>
                                            <div className="flex items-center gap-2">
                                                <span className="font-bold text-violet-600 dark:text-violet-400">sigil</span>
                                                {(<span onClick={lambda (e: MouseEvent) { selSkill = str(cm.signature); tab = "skill"; }}
                                                    className="font-mono text-[10px] text-cyan-600 dark:text-cyan-400 cursor-pointer hover:underline">{cm.signature}</span>) if cm.signature else <span></span>}
                                                <div className="flex-1"></div>
                                                {(<button onClick={lambda (e: MouseEvent) { traceOpen = (-1 if (traceOpen == ci) else ci); }}
                                                    className="text-[10px] text-slate-400 hover:text-slate-600 dark:hover:text-slate-200">{("▴ trace" if (traceOpen == ci) else "▾ trace")}</button>) if cm.trace else <span></span>}
                                            </div>
                                            {(<div className="rounded-lg bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 p-2 font-mono text-[10px] space-y-0.5">
                                                {[<div key={"tl-" + str(li)} className={_traceCls(str(tl))}>{tl}</div> for (li, tl) in enumerate(str(cm.trace).split(chr(10))) if tl]}
                                            </div>) if (cm.trace and (traceOpen == ci)) else <span></span>}
                                            <pre className="whitespace-pre-wrap leading-relaxed text-[11px] max-h-80 overflow-auto m-0">{cm.text}</pre>
                                        </div>
                                    )}
                                </div>
                                for (ci, cm) in enumerate(chat)
                            ]}
                            {(
                                <div className="self-start flex items-center gap-2 px-3 py-2 rounded-2xl rounded-tl-sm border border-cyan-300 dark:border-cyan-800 bg-cyan-50 dark:bg-cyan-500/10">
                                    <span className="w-2 h-2 rounded-full bg-cyan-400 animate-pulse"></span>
                                    <span className="text-cyan-700 dark:text-cyan-300">routing → running… watch the <span className="font-semibold">calls</span> tab for live tokens</span>
                                </div>
                            ) if solving else <span></span>}
                            {(<div className="text-slate-400 leading-relaxed">Talk to the agent in the bar below the graph. Each message routes through the skill library — a HIT re-runs a compiled procedure on the small model, a MISS compiles a new one, and the route + trace ride every reply.</div>) if ((not chat) and (not solving)) else <span></span>}
                        </div>
                    ) if (tab == "chat") else (
                        <div className="text-xs space-y-2">
                            {[
                                <div key="tot" className="grid grid-cols-5 gap-2">
                                    <div className={TILE + " text-center"}>
                                        <div className="font-mono font-bold text-sm">{str(o.tin)}</div>
                                        <div className="text-[9px] uppercase tracking-wider text-slate-400">in</div>
                                    </div>
                                    <div className={TILE + " text-center"}>
                                        <div className="font-mono font-bold text-sm">{str(o.tout)}</div>
                                        <div className="text-[9px] uppercase tracking-wider text-slate-400">out</div>
                                    </div>
                                    <div className={TILE + " text-center"}>
                                        <div className="font-mono font-bold text-sm text-violet-500">{str(o.treason)}</div>
                                        <div className="text-[9px] uppercase tracking-wider text-slate-400">reasoning</div>
                                    </div>
                                    <div className={TILE + " text-center"}>
                                        <div className="font-mono font-bold text-sm text-amber-600 dark:text-sigil-gold">{_money(o.cost)}</div>
                                        <div className="text-[9px] uppercase tracking-wider text-slate-400">cost</div>
                                    </div>
                                    <div className={TILE + " text-center"}>
                                        <div className="font-mono font-bold text-sm">{str(o.n)}</div>
                                        <div className="text-[9px] uppercase tracking-wider text-slate-400">calls</div>
                                    </div>
                                </div>
                                for o in ([obs] if obs is not None else [])
                            ]}
                            {[
                                <div key={str(i)}
                                    onClick={lambda (e: MouseEvent) { callSel = (-1 if (callSel == i) else i); }}
                                    className={"rounded-lg border p-2 cursor-pointer " + ("border-violet-300 dark:border-violet-700 bg-violet-50/50 dark:bg-violet-500/5" if (callSel == i) else "border-slate-200 dark:border-slate-800 hover:bg-slate-50 dark:hover:bg-slate-800/50")}>
                                    <div className="flex flex-wrap gap-x-3 gap-y-0.5 font-mono text-[10px] text-slate-500">
                                        <span className="font-bold text-slate-700 dark:text-slate-300">{c.model}</span>
                                        {(<span className="text-cyan-600 dark:text-cyan-400">{c.signature}</span>) if c.signature else <span></span>}
                                        <span>{str(c.prompt_tokens) + " in / " + str(c.completion_tokens) + " out"}</span>
                                        {(<span className="text-violet-500">{"💭 " + str(c.reasoning_tokens)}</span>) if c.reasoning_tokens else <span></span>}
                                        {(<span className="text-slate-400">{str(c.cache_read_tokens) + " cached"}</span>) if c.cache_read_tokens else <span></span>}
                                        <span className="text-amber-600 dark:text-sigil-gold">{_money(c.cost_usd)}</span>
                                    </div>
                                    {(<div className="mt-1 text-slate-600 dark:text-slate-300 truncate">{c.content}</div>) if ((callSel != i) and c.content) else <span></span>}
                                    {(<pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap text-[10px] text-slate-700 dark:text-slate-300">{c.content}</pre>) if ((callSel == i) and c.content) else <span></span>}
                                    {(<pre className="mt-1 max-h-32 overflow-auto whitespace-pre-wrap text-[10px] text-sky-700 dark:text-sky-300">{"tools: " + str(c.tools)}</pre>) if ((callSel == i) and c.tools) else <span></span>}
                                    {(<pre className="mt-1 max-h-32 overflow-auto whitespace-pre-wrap text-[10px] text-violet-600 dark:text-violet-300 italic">{"reasoning: " + str(c.reasoning)}</pre>) if ((callSel == i) and c.reasoning) else <span></span>}
                                    {(<div className="mt-1 text-[10px] text-slate-400 italic">{("no text — " + str(c.reasoning_tokens) + " hidden reasoning tokens") if c.reasoning_tokens else "no text / tools / reasoning captured"}</div>) if ((callSel == i) and (not c.content) and (not c.tools) and (not c.reasoning)) else <span></span>}
                                </div>
                                for (i, c) in enumerate(calls)
                            ]}
                            {(<div className="text-slate-400 leading-relaxed">No LLM calls yet — send the agent a message and every call lands here, tokens and all.</div>) if (not calls) else <span></span>}
                        </div>
                    ) if (tab == "calls") else (
                        <div className="text-xs space-y-2">
                            <div className="flex items-center gap-2">
                                <div className="text-[10px] uppercase tracking-wider text-slate-400">Scheduled jobs</div>
                                <div className="flex-1"></div>
                                <button onClick={lambda (e: MouseEvent) { tickCron(); }} disabled={ticking}
                                    className={BTN2 + (" opacity-50" if ticking else "")}>{"ticking…" if ticking else "▶ tick now"}</button>
                            </div>
                            {[
                                <div key={j.name} className={TILE + " space-y-1"}>
                                    <div className="flex items-center gap-2">
                                        <span className={"w-1.5 h-1.5 rounded-full shrink-0 " + ("bg-[#4ade80]" if j.enabled else "bg-slate-400")}></span>
                                        <span className="font-mono font-bold truncate">{j.name}</span>
                                        <span className={CHIP}>{j.schedule if j.schedule else (str(j.kind) + " · " + str(j.spec))}</span>
                                        <div className="flex-1"></div>
                                        <span className={"text-[10px] font-mono " + ("text-green-500" if (str(j.last_status) == "ok") else ("text-rose-400" if j.last_status else "text-slate-400"))}>{str(j.last_status) if j.last_status else "never ran"}</span>
                                    </div>
                                    <div className="text-slate-500 dark:text-slate-400 truncate">{j.task}</div>
                                    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-[10px] text-slate-400">
                                        <span>{"next · " + str(fmtWhen(j.next_run_ms))}</span>
                                        <span className="cursor-pointer hover:text-violet-500"
                                            onClick={lambda (e: MouseEvent) { toggleRuns(str(j.name)); }}>
                                            {("▾ " if (cronOpen == str(j.name)) else "▸ ") + str(j.runs) + " runs"}</span>
                                        {(<span className="text-rose-400">{str(j.errors) + " errors"}</span>) if j.errors else <span></span>}
                                        {(<span className="text-slate-400">{"tz " + str(j.zone)}</span>) if j.zone else <span></span>}
                                        <div className="flex-1"></div>
                                        <button onClick={lambda (e: MouseEvent) { setCronEnabled(str(j.name), not bool(j.enabled)); }}
                                            disabled={cronBusy == str(j.name)}
                                            className={"px-1.5 py-0.5 rounded border text-[10px] transition-colors " + ("opacity-50 " if (cronBusy == str(j.name)) else "") + "border-slate-300 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800"}>
                                            {"pause" if j.enabled else "resume"}</button>
                                        <button onClick={lambda (e: MouseEvent) { dropCron(str(j.name)); }}
                                            disabled={cronBusy == str(j.name)}
                                            className="px-1.5 py-0.5 rounded border border-rose-300 dark:border-rose-800 text-rose-500 text-[10px] hover:bg-rose-50 dark:hover:bg-rose-500/10 transition-colors">
                                            delete</button>
                                    </div>
                                    {(<div className="mt-1 pt-1 border-t border-slate-200 dark:border-slate-800 space-y-0.5">
                                        {[
                                            <div key={"r-" + str(ri)} className="flex items-start gap-2 font-mono text-[10px]">
                                                <span className={"mt-1 w-1 h-1 rounded-full shrink-0 " + ("bg-[#4ade80]" if r.ok else "bg-[#f87171]")}></span>
                                                <span className="text-slate-400 shrink-0">{str(fmtWhen(r.started_ms))}</span>
                                                <span className="text-slate-500 dark:text-slate-400 flex-1 min-w-0 truncate">{r.summary}</span>
                                            </div>
                                            for (ri, r) in enumerate(cronRuns[str(j.name)] if (str(j.name) in cronRuns) else [])
                                        ]}
                                        {(<div className="text-slate-400 text-[10px]">No fires recorded yet.</div>) if (not (cronRuns[str(j.name)] if (str(j.name) in cronRuns) else [])) else <span></span>}
                                    </div>) if (cronOpen == str(j.name)) else <span></span>}
                                </div>
                                for j in cron
                            ]}
                            {(<div className="text-slate-400 leading-relaxed">No scheduled jobs. <span className="font-mono">sigil cron add …</span> puts recurring work on the graph — it shows up here with its next fire time, and <span className="font-semibold">▶ tick now</span> runs anything due.</div>) if (not cron) else <span></span>}
                        </div>
                    ) if (tab == "cron") else (
                        <div className="text-xs space-y-4">
                            <div>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Work feed — solves + cron fires, newest first</div>
                                <div className="space-y-1">
                                    {[
                                        <div key={"w-" + str(wi)} className="px-2 py-1.5 rounded-md bg-slate-50 dark:bg-slate-800/60 flex items-start gap-2">
                                            <span className={"mt-1 w-1.5 h-1.5 rounded-full shrink-0 " + ("bg-[#4ade80]" if w.ok else "bg-[#f87171]")}></span>
                                            <span className={"font-mono text-[9px] px-1 py-0.5 rounded mt-0.5 shrink-0 " + ("bg-cyan-50 dark:bg-cyan-500/10 text-cyan-700 dark:text-cyan-300" if (str(w.kind) == "solve") else "bg-violet-50 dark:bg-violet-500/10 text-violet-700 dark:text-violet-300")}>{w.kind}</span>
                                            <span className="flex-1 min-w-0">
                                                <span className="font-mono font-semibold">{w.label}</span>
                                                {(<span className="text-slate-500 dark:text-slate-400">{" — " + str(w.summary)[:110]}</span>) if w.summary else <span></span>}
                                            </span>
                                            <span className="text-[9px] text-slate-400 font-mono shrink-0">{str(fmtWhen(w.at_ms))}</span>
                                        </div>
                                        for (wi, w) in enumerate(opsTasks)
                                    ]}
                                    {(<div className="text-slate-400">No work recorded yet — solves and cron fires land here.</div>) if (not opsTasks) else <span></span>}
                                </div>
                            </div>

                            <div>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Hooks — fire on lifecycle events</div>
                                <div className="space-y-1">
                                    {[
                                        <div key={h.name} className="px-2 py-1.5 rounded-md bg-slate-50 dark:bg-slate-800/60 flex items-center gap-2">
                                            <span className={"w-1.5 h-1.5 rounded-full shrink-0 " + ("bg-[#4ade80]" if h.enabled else "bg-slate-400")}></span>
                                            <span className="font-mono font-semibold">{h.name}</span>
                                            <span className={CHIP}>{str(h.event) + " → " + str(h.kind)}</span>
                                            <div className="flex-1"></div>
                                            <span className="text-[10px] text-slate-400 font-mono">{"fired " + str(h.fired) + "x"}</span>
                                        </div>
                                        for h in hooks
                                    ]}
                                    {(<div className="text-slate-400">No hooks — <span className="font-mono">sigil hooks add …</span> reacts to before/after-solve events.</div>) if (not hooks) else <span></span>}
                                </div>
                            </div>

                            <div>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Channels</div>
                                <div className="space-y-1">
                                    {[
                                        <div key={ch.name} className="px-2 py-1.5 rounded-md bg-slate-50 dark:bg-slate-800/60 flex items-center gap-2">
                                            <span className={"w-1.5 h-1.5 rounded-full shrink-0 " + ("bg-[#4ade80]" if ch.enabled else "bg-slate-400")}></span>
                                            <span className="font-mono font-semibold">{ch.name}</span>
                                            <span className={CHIP}>{ch.kind}</span>
                                            <div className="flex-1"></div>
                                            <span className="text-[10px] text-slate-400 font-mono">{str(ch.messages) + " msgs"}</span>
                                        </div>
                                        for ch in channels
                                    ]}
                                    {(<div className="text-slate-400">No channels wired — <span className="font-mono">sigil channels …</span> connects Slack/Telegram/webhooks.</div>) if (not channels) else <span></span>}
                                </div>
                            </div>

                            <div>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Exec approvals</div>
                                {[
                                    <div key="ap" className={TILE + " space-y-1.5"}>
                                        <div className="flex flex-wrap gap-1.5">
                                            <span className={CHIP}>{"security · " + str(ap.security)}</span>
                                            <span className={CHIP}>{"ask · " + str(ap.ask)}</span>
                                            {(<span className="px-2 py-0.5 rounded-full bg-amber-100 dark:bg-amber-500/20 text-amber-700 dark:text-sigil-gold text-[11px] font-mono">{"⚠ elevated " + str(int(int(str(ap.elevated_ms_left)) / 60000)) + "m left"}</span>) if ap.elevated else <span></span>}
                                        </div>
                                        {(<div className="flex flex-wrap gap-1">{[<span key={al} className="px-1.5 py-0.5 rounded bg-slate-100 dark:bg-slate-800 font-mono text-[10px]">{al}</span> for al in ap.allowlist]}</div>) if ap.allowlist else <span></span>}
                                        {[
                                            <div key={"p-" + str(pi)} className="px-2 py-1 rounded bg-rose-50 dark:bg-rose-950/30 text-rose-600 dark:text-rose-300 font-mono text-[10px]">{"pending · " + str(pd.cmd)}</div>
                                            for (pi, pd) in enumerate(ap.pending)
                                        ]}
                                    </div>
                                    for ap in ([approvals] if approvals is not None else [])
                                ]}
                                {(<div className="text-slate-400">not loaded yet — open this tab again or hit ↻.</div>) if (approvals is None) else <span></span>}
                            </div>
                        </div>
                    ) if (tab == "ops") else (
                        <div className="text-xs space-y-4 leading-relaxed">
                            {[
                                <div key="soul" className="space-y-4">
                                    <div>
                                        <div className="font-semibold text-sm">{so.name}</div>
                                        <div className="text-slate-500 dark:text-slate-400 mt-0.5">{so.persona}</div>
                                    </div>

                                    <div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Ethos</div>
                                        <div className="space-y-1">
                                            {[<div key={ei} className="flex gap-2"><span className="text-violet-400 shrink-0">◆</span><span>{ei}</span></div> for ei in so.ethos]}
                                            {(<div className="text-slate-400">No operating principles taught yet.</div>) if (not so.ethos) else <span></span>}
                                        </div>
                                    </div>

                                    <div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Model tiers</div>
                                        <div className="space-y-1 font-mono text-[11px]">
                                            <div className="flex justify-between px-2 py-1 rounded bg-slate-100 dark:bg-slate-800"><span className="text-slate-400">frontier · compiles</span><span>{so.frontier_model}</span></div>
                                            <div className="flex justify-between px-2 py-1 rounded bg-slate-100 dark:bg-slate-800"><span className="text-slate-400">small · executes</span><span>{so.small_model}</span></div>
                                            <div className="flex justify-between px-2 py-1 rounded bg-slate-100 dark:bg-slate-800"><span className="text-slate-400">router · routes</span><span>{so.router_model}</span></div>
                                            <div className="flex justify-between px-2 py-1 rounded bg-slate-100 dark:bg-slate-800"><span className="text-slate-400">chat</span><span>{so.chat_model}</span></div>
                                        </div>
                                    </div>

                                    <div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Config</div>
                                        <div className="flex flex-wrap gap-1.5">
                                            <span className={CHIP}>{"prompt · " + str(so.prompt_mode)}</span>
                                            <span className={CHIP}>{("auto-eval ≥ " + str(so.eval_threshold)) if so.auto_eval else "auto-eval off"}</span>
                                            <span className={CHIP}>{"sandbox · " + str(so.sandbox)}</span>
                                            <span className={CHIP}>{str(len(so.memories)) + " memories"}</span>
                                            <span className={CHIP}>{str(so.skills) + " skills"}</span>
                                        </div>
                                    </div>

                                    <div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Workspace</div>
                                        <div className="font-mono text-[10px] px-2 py-1 rounded bg-slate-100 dark:bg-slate-800 break-all">{so.workspace}</div>
                                    </div>

                                    {(<div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Channels</div>
                                        <div className="flex flex-wrap gap-1">{[<span key={ch2} className={CHIP}>{ch2}</span> for ch2 in so.channels]}</div>
                                    </div>) if so.channels else <span></span>}
                                </div>
                                for so in ([soul] if soul is not None else [])
                            ]}
                            {(<div className="text-slate-400">waking the soul…</div>) if (soul is None) else <span></span>}
                        </div>
                    ) if (tab == "soul") else (
                        <div className="text-xs space-y-3">
                            {[
                                <div key={sk.signature} className="space-y-3">
                                    <div className="flex items-center gap-2 flex-wrap">
                                        <span className="font-mono font-bold text-sm">{sk.signature}</span>
                                        <span className={CHIP}>{"v" + str(sk.version)}</span>
                                        <span className="px-2 py-0.5 rounded bg-emerald-100 dark:bg-emerald-500/20 text-emerald-700 dark:text-emerald-300 text-[10px]">{sk.origin}</span>
                                    </div>
                                    <div className="text-slate-500 dark:text-slate-400 leading-relaxed">{sk.intent if sk.intent else "(no recorded intent)"}</div>
                                    <div className="flex flex-wrap gap-1.5 font-mono text-[11px]">
                                        <span className={CHIP}>{str(sk.runs) + " runs"}</span>
                                        <span className={CHIP}>{str(sk.successes) + " ok"}</span>
                                    </div>
                                    <div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">Compiled module</div>
                                        <div className="font-mono text-[10px] px-2 py-1 rounded bg-slate-100 dark:bg-slate-800 break-all">{sk.module}</div>
                                    </div>

                                    <div>
                                        <div className="flex items-center gap-2 mb-1">
                                            <div className="text-[10px] uppercase tracking-wider text-slate-400">AG-IR — the typed contract this runs</div>
                                            <div className="flex-1"></div>
                                            <button onClick={lambda (e: MouseEvent) { fetchAgir(str(sk.signature)); }}
                                                disabled={agirLoading}
                                                className={BTN2 + (" opacity-50" if agirLoading else "")}>
                                                {"loading…" if agirLoading else ("↻ redraw" if (agirSig == str(sk.signature)) else "▶ draw the graph")}</button>
                                        </div>
                                        {(<div className="space-y-1">
                                            <div className="relative h-72 rounded-lg border border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-900 overflow-hidden">
                                                <AgirCanvas nodes={agir.nodes} edges={agir.edges} dark={dark}
                                                    onSelect={lambda (nid: str) { agirNode = nid; }}/>
                                            </div>
                                            <div className="flex flex-wrap gap-x-3 gap-y-1 text-[10px] text-slate-400">
                                                {[
                                                    <span key={str(lg[0])} className="flex items-center gap-1">
                                                        <span className={"w-1.5 h-1.5 rounded-full " + str(lg[1])}></span>{str(lg[2])}
                                                    </span>
                                                    for lg in AGIR_LEGEND
                                                ]}
                                                <div className="flex-1"></div>
                                                <span className="font-mono">{str(len(agir.nodes)) + " nodes · " + str(len(agir.edges)) + " edges"}</span>
                                            </div>
                                            {(<div className="px-2 py-1 rounded bg-amber-50 dark:bg-amber-500/10 text-amber-700 dark:text-sigil-gold text-[10px]">{"⚠ " + str(agir.warning)}</div>) if agir.warning else <span></span>}
                                            {[
                                                <div key={"an-" + str(n.id)} className="px-2 py-1.5 rounded bg-slate-100 dark:bg-slate-800 space-y-0.5">
                                                    <div className="flex items-center gap-2">
                                                        <span className="font-mono font-bold">{n.id}</span>
                                                        <span className={CHIP}>{n.type}</span>
                                                        {(<span className={CHIP}>{"owner · " + str(n.owner)}</span>) if n.owner else <span></span>}
                                                        {(<span className={CHIP}>{"tool · " + str(n.tool)}</span>) if n.tool else <span></span>}
                                                    </div>
                                                    {(<div className="text-slate-500 dark:text-slate-400 leading-relaxed">{n.doc}</div>) if n.doc else <span></span>}
                                                    <div className="font-mono text-[10px] text-slate-400">
                                                        {("reads " + ", ".join([str(x) for x in n.reads])) if n.reads else ""}
                                                        {("  →  writes " + ", ".join([str(x) for x in n.writes])) if n.writes else ""}
                                                    </div>
                                                </div>
                                                for n in agir.nodes if (str(n.id) == agirNode)
                                            ]}
                                            {(<div className="text-slate-400 text-[10px]">Click a node for what it reads, writes and runs. Diamonds are model-owned slots, boxes are code, dashed edges are not mandatory.</div>) if (not agirNode) else <span></span>}
                                        </div>) if ((agir is not None) and (agirSig == str(sk.signature))) else <span></span>}
                                    </div>

                                    <div className="pt-2 border-t border-slate-200 dark:border-slate-800 space-y-2">
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400">Grounded eval — run on a probe, judge the artifact</div>
                                        <div className="flex gap-1">
                                            <input value={probe} placeholder="probe task (default: the skill's intent)"
                                                onChange={lambda (e: ChangeEvent) { probe = e.target.value; }}
                                                className={"flex-1 " + INP}/>
                                            <button onClick={lambda (e: MouseEvent) { evalH(); }} disabled={acting} className={BTN2 + (" opacity-50" if acting else "")}>▶ eval</button>
                                        </div>
                                        <div className="text-[10px] uppercase tracking-wider text-slate-400">Relearn — the frontier re-authors it from scratch</div>
                                        <div className="flex gap-1">
                                            <input value={hint} placeholder="extra guidance (optional)"
                                                onChange={lambda (e: ChangeEvent) { hint = e.target.value; }}
                                                className={"flex-1 " + INP}/>
                                            <button onClick={lambda (e: MouseEvent) { relearnH(); }} disabled={acting} className={BTN2 + (" opacity-50" if acting else "")}>↻ relearn</button>
                                        </div>
                                        <button onClick={lambda (e: MouseEvent) { forgetH(); }} disabled={acting}
                                            className={"px-3 py-1.5 rounded-md text-xs transition-colors " + ("bg-rose-600 text-white hover:bg-rose-700" if confirmForget else "border border-rose-300 dark:border-rose-800 text-rose-500 hover:bg-rose-50 dark:hover:bg-rose-500/10")}>
                                            {"✕ really forget every version?" if confirmForget else "✕ forget"}</button>
                                        {(<div className={"p-2 rounded-lg leading-relaxed " + ("bg-cyan-50 dark:bg-cyan-500/10 text-cyan-700 dark:text-cyan-300 animate-pulse" if acting else "bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300")}>{actMsg}</div>) if actMsg else <span></span>}
                                    </div>
                                </div>
                                for sk in lib if (str(sk.signature) == selSkill)
                            ]}
                            {(<div className="text-slate-400 leading-relaxed">Select a skill — from the library on the left, or click a cyan node on the graph.</div>) if (not selSkill) else <span></span>}
                        </div>
                    ) if (tab == "skill") else (
                        <div className="text-xs space-y-2">
                            {[
                                <div key={m.name} className={TILE + " space-y-1.5"}>
                                    <div className="flex items-center gap-2">
                                        <span className="font-mono font-bold">{m.name}</span>
                                        <span className={CHIP}>{m.transport}</span>
                                        <span className="text-[10px] text-slate-400">{str(len(m.tools)) + " tools"}</span>
                                    </div>
                                    <div className="flex flex-wrap gap-1">
                                        {[<span key={t} className="px-1.5 py-0.5 rounded bg-sky-50 dark:bg-sky-500/10 text-sky-700 dark:text-sky-300 font-mono text-[10px]">{t}</span> for t in m.tools]}
                                    </div>
                                </div>
                                for m in mcp
                            ]}
                            {(<div className="text-slate-400 leading-relaxed">No MCP servers registered. <span className="font-mono">sigil mcp add …</span> exposes a server's tools to every compiled skill — the frontier binds them by name at compile time.</div>) if (not mcp) else <span></span>}
                        </div>
                    ) if (tab == "mcp") else (
                        <div className="text-xs space-y-4">
                            <div className={TILE + " space-y-1.5"}>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400">Teach — write a durable fact onto the graph</div>
                                <div className="flex gap-1">
                                    <input value={teachFact} placeholder="the agent should remember that…"
                                        onChange={lambda (e: ChangeEvent) { teachFact = e.target.value; }}
                                        onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { teachH(); } }}
                                        className={"flex-1 " + INP}/>
                                    <select value={teachKind} onChange={lambda (e: ChangeEvent) { teachKind = e.target.value; }} className={INP}>
                                        <option value="fact">fact</option>
                                        <option value="preference">preference</option>
                                        <option value="rule">rule</option>
                                    </select>
                                    <button onClick={lambda (e: MouseEvent) { teachH(); }} className={BTN}>＋ teach</button>
                                </div>
                                {(<div className="text-[11px] text-green-600 dark:text-green-400">{teachMsg}</div>) if teachMsg else <span></span>}
                            </div>

                            <div className={TILE + " space-y-1.5"}>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400">Recall — what would surface for a task</div>
                                <div className="flex gap-1">
                                    <input value={recallQ} placeholder="query…"
                                        onChange={lambda (e: ChangeEvent) { recallQ = e.target.value; }}
                                        onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { recallH(); } }}
                                        className={"flex-1 " + INP}/>
                                    <button onClick={lambda (e: MouseEvent) { recallH(); }} className={BTN2}>recall</button>
                                </div>
                                {[
                                    <div key={"rr-" + str(ri)} className="px-2 py-1 rounded bg-violet-50 dark:bg-violet-500/10 text-violet-800 dark:text-violet-300">
                                        {str(rm.content)}<span className="text-slate-400">{"  · " + str(rm.kind) + " · used " + str(rm.uses) + "x"}</span>
                                    </div>
                                    for (ri, rm) in enumerate(recallRes)
                                ]}
                            </div>

                            <div>
                                <div className="text-[10px] uppercase tracking-wider text-slate-400 mb-1">All memories</div>
                                {[
                                    <div key="mems" className="space-y-1">
                                        {[
                                            <div key={"m-" + str(mi)} className="px-2 py-1.5 rounded-md bg-slate-50 dark:bg-slate-800/60 flex items-start gap-2">
                                                <span className="mt-0.5 w-2 h-2 rounded-sm bg-[#a78bfa] shrink-0"></span>
                                                <span className="flex-1 leading-relaxed">{mm.content}</span>
                                                <span className="text-[10px] text-slate-400 font-mono shrink-0">{str(mm.kind) + " · " + str(mm.uses) + "x"}</span>
                                            </div>
                                            for (mi, mm) in enumerate(so.memories)
                                        ]}
                                        {(<div className="text-slate-400">No memories yet — teach one above, or let the agent distill its own from a task.</div>) if (not so.memories) else <span></span>}
                                    </div>
                                    for so in ([soul] if soul is not None else [])
                                ]}
                            </div>
                        </div>
                    )}
                </div>
            </section>
        </div>;
}

"""Library: every compiled skill and how it is doing.

A table by default: version, where the skill came from, how many of its runs
finished ok, its last grade, and whether MCP clients and the chat agent can call
it (the switch edits the tool policy). The Graph view is the Observatory's live
drawing of the agent's own graph: soul, registry, skills, memory, MCP servers
and recent runs.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_graph }
import from .ui {
    PageHead, Icon, Toggle, Segmented, Empty, Note, Spinner, Bar, CARD, BTN, BTN2, INP, SELECT, LABEL, chip
}
import from .graph_canvas { GraphCanvas }
import from "./console_interop.js" { storeGet, navTo, seen, remember }

glob FILTERS: list[any] = [["all", "All"], ["attention", "Needs attention"], ["healthy", "Healthy"], ["never", "Never run"]];
glob ORIGINS: list[any] = [["any", "Any origin"], ["skill", "Compiled from SKILL.md"], ["task", "Learned from a task"], ["mutated", "Mutated or relearned"]];

def _okPct(s: any) -> float {
    r = int(s.runs) if s.runs else 0;
    if r == 0 { return -1.0; }
    return (float(s.successes) * 100.0) / float(r);
}

def _origin(s: any) -> str {
    o = str(s.origin or "").lower();
    if ("mutat" in o) or ("relearn" in o) { return "mutated"; }
    if s.from_skill { return "skill"; }
    return "task";
}

def _originLabel(k: str) -> str {
    if k == "skill" { return "SKILL.md"; }
    if k == "mutated" { return "mutated"; }
    return "learned";
}

def _needsAttention(s: any, threshold: int) -> bool {
    p = _okPct(s);
    low = (s.last_score is not None) and (int(s.last_score) >= 0) and (int(s.last_score) < threshold);
    return ((p >= 0) and (p < 60) and (int(s.runs) >= 2)) or low;
}

def _bySig(s: any) -> str { return str(s.signature); }

def:pub LibraryPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None],
                    refresh: Callable[[], None]) -> JsxElement {
    has skills: list[any] = [];
    has loaded: bool = False;
    has err: str = "";
    has q: str = "";
    has filt: str = "all";
    has origin: str = "any";
    has view: str = "table";
    has gdata: any = None;
    has gsel: str = "";
    has busy: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def load() {
        m: any = await call("skills", {});
        loaded = True;
        if m and (not m.error) { skills = remember("skills", list(m)); err = ""; }
        elif m { err = str(m.error); }
    }

    async def loadGraph() {
        r = root spawn api_graph();
        g: any = r.reports[0] if r.reports else None;
        if g and (not g.error) and g.nodes { gdata = g; }
    }

    can with entry {
        prev: any = seen("skills");
        if prev { skills = prev; loaded = True; }
        load();
    }

    async def expose(sig: str, on: bool) {
        busy = sig;
        m: any = await call("skill_expose", {"signature": sig, "on": on});
        busy = "";
        if m and m.error { err = str(m.error); }
        load();
    }

    def pickView(v: str) {
        view = v;
        if (v == "graph") and (not gdata) { loadGraph(); }
    }

    def pickNode(nid: str, lbl: str) {
        gsel = nid;
        if nid.startswith("tg:") and lbl { navTo("/skills/" + lbl.split(" v")[0]); }
    }

    needle = q.strip().lower();
    shown: list[any] = [];
    for s in sorted(skills, key=_bySig) {
        if needle and (needle not in (str(s.signature) + " " + str(s.intent or "")).lower()) { continue; }
        if (origin != "any") and (_origin(s) != origin) { continue; }
        if (filt == "attention") and (not _needsAttention(s, 60)) { continue; }
        if (filt == "healthy") and (_needsAttention(s, 60) or (_okPct(s) < 0)) { continue; }
        if (filt == "never") and (_okPct(s) >= 0) { continue; }
        shown.append(s);
    }
    n_att = len([s for s in skills if _needsAttention(s, 60)]);
    n_never = len([s for s in skills if _okPct(s) < 0]);
    n_exposed = len([s for s in skills if s.exposed]);
    n_skill = len([s for s in skills if _origin(s) == "skill"]);
    n_task = len([s for s in skills if _origin(s) == "task"]);
    n_mut = len([s for s in skills if _origin(s) == "mutated"]);
    dark = not bool(storeGet("sigil.light", False));

    return <div className="flex flex-col">
        <PageHead title="Library" kicker="Skills" onAsk={ask} askHint="Ask about these skills" tag="library">
            <a href="#/compile" className={BTN + " no-underline"}><Icon name="plus" size={15}/>Compile a skill</a>
        </PageHead>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-4">
            <div className="grid gap-3 grid-cols-[repeat(auto-fit,minmax(170px,1fr))]">
                <div className={CARD + " px-3.5 py-3 flex flex-col gap-0.5"}><span className="text-xs text-muted">Compiled from SKILL.md</span><span className="text-[22px] font-semibold">{str(n_skill)}</span></div>
                <div className={CARD + " px-3.5 py-3 flex flex-col gap-0.5"}><span className="text-xs text-muted">Learned from a task</span><span className="text-[22px] font-semibold">{str(n_task)}</span></div>
                <div className={CARD + " px-3.5 py-3 flex flex-col gap-0.5"}><span className="text-xs text-muted">Mutated or relearned</span><span className="text-[22px] font-semibold">{str(n_mut)}</span></div>
                <div className={CARD + " px-3.5 py-3 flex flex-col gap-0.5"}><span className="text-xs text-muted">Callable over MCP</span><span className="text-[22px] font-semibold">{str(n_exposed)}</span></div>
            </div>

            <div className="flex flex-wrap gap-2.5 items-center">
                <label className="flex items-center gap-2 h-9 flex-[1_1_240px] max-w-[360px] px-3 rounded-lg bg-ink-2 border border-line-2">
                    <Icon name="search" size={15} cls="text-muted"/>
                    <span className="sr-only">Filter skills</span>
                    <input value={q} placeholder="Filter by name or intent" onChange={lambda (e: ChangeEvent) { q = e.target.value; }}
                        className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[13px] text-fg placeholder:text-faint"/>
                </label>
                <Segmented label="Status" value={filt} onPick={lambda (v: str) { filt = v; }}
                    options={[["all", "All " + str(len(skills))], ["attention", "Needs attention " + str(n_att)], ["healthy", "Healthy"], ["never", "Never run " + str(n_never)]]}/>
                <label className="flex items-center gap-2 text-[12.5px] text-muted">Origin
                    <select value={origin} onChange={lambda (e: ChangeEvent) { origin = e.target.value; }} className={SELECT}>
                        {[<option key={str(o[0])} value={str(o[0])}>{o[1]}</option> for o in ORIGINS]}
                    </select>
                </label>
                <span className="ml-auto"><Segmented label="View" value={view} onPick={pickView} options={[["table", "Table"], ["graph", "Graph"]]}/></span>
            </div>

            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Spinner label="Reading the library…"/>) if (not loaded) else None}

            {if view == "graph" {
                <section className={CARD + " relative h-[560px] overflow-hidden"}>
                    <GraphCanvas nodes={gdata.nodes if gdata else []} edges={gdata.edges if gdata else []} dark={dark} sel={gsel} onSelect={pickNode}/>
                    {(<div className="absolute inset-0 flex items-center justify-center text-muted text-sm pointer-events-none">Drawing the agent's graph…</div>) if (not gdata) else None}
                    <div className="absolute top-3 left-3 text-xs text-muted bg-ink-2/90 border border-line rounded-lg px-2.5 py-1.5">Click a skill to open it</div>
                </section>
            } elif loaded and (not skills) {
                <Empty title="No compiled skills yet"
                    body="A skill is compiled from a SKILL.md (upload one on the Compile page) or learned the first time Sigil does a task it has no skill for.">
                    <a href="#/compile" className={BTN + " no-underline"}>Compile a skill</a>
                </Empty>
            } elif loaded {
                <div className={CARD + " overflow-x-auto"}>
                    <table className="w-full min-w-[900px] border-collapse text-[13px]">
                        <thead>
                            <tr className="text-left text-xs text-muted">
                                <th scope="col" className="px-4 py-3 font-medium">Skill</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Version</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Origin</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Runs ok</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Last grade</th>
                                <th scope="col" className="px-2.5 py-3 pr-4 font-medium">MCP</th>
                            </tr>
                        </thead>
                        <tbody>
                            {for s in shown {
                                <tr key={str(s.signature)} className={"border-t border-line" + (" bg-[#f5c451]/5" if _needsAttention(s, 60) else "")}>
                                    <td className="px-4 py-3 max-w-[420px]">
                                        <a href={"#/skills/" + str(s.signature)} className="font-mono text-[13px] text-fg no-underline hover:text-acc">{s.signature}</a>
                                        <div className="text-xs text-muted truncate">{str(s.intent or "")}</div>
                                    </td>
                                    <td className="px-2.5 py-3 font-mono">{"v" + str(s.version)}</td>
                                    <td className="px-2.5 py-3 text-fg-2">{_originLabel(_origin(s))}</td>
                                    <td className="px-2.5 py-3">
                                        {if _okPct(s) < 0 {
                                            <span className="text-faint">never run</span>
                                        } else {
                                            <span className="flex items-center gap-2">
                                                <span className={"font-mono " + ("text-bad" if (_okPct(s) < 60) else "")}>{str(s.successes) + "/" + str(s.runs)}</span>
                                                <span className="w-14"><Bar pct={_okPct(s)} tone={"ok" if (_okPct(s) >= 90) else ("warn" if (_okPct(s) >= 60) else "bad")}/></span>
                                            </span>
                                        }}
                                    </td>
                                    <td className="px-2.5 py-3 font-mono">
                                        {(<span className={"text-bad" if (int(s.last_score) < 60) else ""}>{str(s.last_score)}</span>) if ((s.last_score is not None) and (int(s.last_score) >= 0)) else (<span className="text-faint">—</span>)}
                                    </td>
                                    <td className="px-2.5 py-3 pr-4">
                                        <Toggle on={bool(s.exposed)} label={"Let MCP clients call " + str(s.signature)}
                                            disabled={busy == str(s.signature)}
                                            onToggle={lambda (v: bool) { expose(str(s.signature), v); }}/>
                                    </td>
                                </tr>
                            }}
                        </tbody>
                    </table>
                    {(<div className="px-4 py-5 text-[13px] text-muted border-t border-line">No skill matches these filters.</div>) if (not shown) else None}
                </div>
            }}

            <div className="flex flex-wrap gap-3 items-center text-[12.5px] text-muted">
                <span>{"Showing " + str(len(shown)) + " of " + str(len(skills))}</span>
                <span className="ml-auto">MCP clients see a skill as <span className="font-mono text-fg-2">{"skill_<name>"}</span>. Set up the server on <a href="#/tools" className="text-acc no-underline hover:underline">MCP &amp; tools</a>.</span>
            </div>
        </div>
    </div>;
}

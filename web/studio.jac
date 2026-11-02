"""Studio: the console's main page. Chat with Sigil, build agents, see them.

Three panes. The shelf lists every compiled skill with a strip of marks, one per
AG-IR step, so you can see how much of each one the model decides before opening
it. The chat (web/chat.jac) is where you describe an agent, compile a skill
folder, or ask about one. The viewer draws the selected skill's AG-IR top-down,
with an inspector for the node you click, and its AG-IR and SKILL.md beside it.

On a first visit, with nothing said yet and nothing selected, the page is only
the greeting: the glyph draws itself in, a large input, a few things to try, and
the shelf as cards. The first message or compile opens the three panes, and a
new chat with nothing selected goes back to the greeting.

The chat is a general one. Building starts when you ask for an agent: Sigil
scopes it with you and, once confident, proposes it with a Build button
(web/chat.jac). Nothing on this page compiles until then, except a skill folder
you hand it with the paperclip.

#/studio/<signature> selects a skill, so a skill in the viewer can be linked to.
The panes talk through the page: a turn that compiled or ran a skill selects it,
and the viewer's "Ask about this step" and "Run" put a chip on the chat's input.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_skill_agir }
import from .ui {
    Icon, Logo, Glyph, Marks, Toggle, Note, Spinner, BTN, BTN_SM, BTN2_SM, BTN_GHOST_SM, INP, SELECT, LABEL,
    markCls, modelSteps, chip
}
import from .chat { ChatPane }
import from .agir_canvas { AgirCanvas }
import from "./console_interop.js" { storeGet, storeSet, navTo, focusId, readFiles, seen, remember, copyText }
import from react { useEffect }

glob SHELF_KEY: str = "sigil.shelf";

glob SUGGEST: list[str] = [
    "What can you do?",
    "I'd like an agent that tidies a CSV's headers",
    "Which of my agents lean most on the model?"
];

# [group, label]: the AG-IR canvas's instruction classes, as a legend.
glob LEGEND: list[any] = [
    ["semantic", "Semantic"], ["delegated", "Delegated"], ["executable", "Executable"],
    ["control", "Control"], ["termination", "Return"]
];

glob TAB_ON: str = "inline-flex items-center h-10 px-3 border-0 border-b-2 border-solid border-violet-400 bg-transparent text-fg text-[13px] font-medium cursor-pointer";
glob TAB_OFF: str = "inline-flex items-center h-10 px-3 border-0 border-b-2 border-solid border-transparent bg-transparent text-muted text-[13px] cursor-pointer hover:text-fg";
glob TAB_LINK: str = "inline-flex items-center gap-1 h-10 px-3 text-muted text-[13px] no-underline hover:text-fg";
glob PRE: str = "m-0 p-4 h-full overflow-auto text-xs leading-relaxed font-mono text-fg-2";

def _okPct(s: any) -> int {
    r = int(s.runs) if s.runs else 0;
    if r == 0 { return -1; }
    return int((float(s.successes) * 100.0) / float(r));
}

def _meta(s: any) -> str {
    r = int(s.runs) if s.runs else 0;
    if r == 0 { return "never run"; }
    return str(r) + (" run · " if (r == 1) else " runs · ") + str(_okPct(s)) + "% ok";
}

def _byRuns(s: any) -> int { return int(s.runs) if s.runs else 0; }

def _matches(s: any, words: list[str]) -> bool {
    hay = (str(s.signature) + " " + str(s.intent or "")).lower();
    for w in words { if w not in hay { return False; } }
    return True;
}

def _groupLabel(g: str) -> str {
    for lg in LEGEND { if lg[0] == g { return str(lg[1]); } }
    return "Other";
}

def _originLabel(origin: str, fromSkill: bool) -> str {
    o = str(origin or "").lower();
    if "relearn" in o { return "relearned"; }
    if "mutat" in o { return "mutated"; }
    if fromSkill or ("skill" in o) or ("compiled" in o) { return "compiled from SKILL.md"; }
    if "registered" in o { return "registered AG-IR"; }
    if o == "frontier" { return "learned from a task"; }
    return o if o else "learned from a task";
}

def _who(g: str) -> str {
    if g in ["semantic", "delegated"] { return "the model decides"; }
    if g == "executable" { return "runs as code"; }
    if g == "control" { return "routes"; }
    if g == "termination" { return "returns"; }
    return "";
}

def Field(label: str, children: any = None) -> JsxElement {
    return <div className="flex flex-col gap-1">
        <span className={LABEL}>{label}</span>
        <div className="text-[12.5px] text-fg-2 break-words">{children}</div>
    </div>;
}

def Hero(skills: list[any], onAsk: Callable[[str], None], onJob: Callable[[str], None],
         onOpen: Callable[[str], None]) -> JsxElement {
    has text: str = "";
    has starting: bool = False;
    has err: str = "";

    async def compileFiles(fl: any) {
        got: list[any] = await readFiles(fl);
        if not [f for f in got if str(f.path).lower().endswith("skill.md")] {
            err = "No SKILL.md in what you picked. Pick the skill's folder, or include its SKILL.md.";
            return;
        }
        starting = True;
        err = "";
        r = root spawn api_console(op="compile_start", args={"files": got, "mode": str(storeGet("sigil.compileMode", "ask")), "path": ""});
        m: any = r.reports[0] if r.reports else None;
        starting = False;
        if m and m.ok { onJob(str(m.job)); }
        else { err = str(m.error) if (m and m.error) else "The compile did not start."; }
    }

    def submit() {
        t = text.strip();
        if t { text = ""; onAsk(t); }
    }

    def keyed(e: any) {
        if (e.key == "Enter") and (not e.shiftKey) and (not e.nativeEvent.isComposing) {
            e.preventDefault();
            submit();
        }
    }

    ranked = sorted(skills, key=_byRuns, reverse=True)[:8];

    return <div className="flex-1 overflow-y-auto">
        <div className="flex flex-col items-center gap-8 px-4 pt-14 pb-14">
            <div className="flex flex-col items-center gap-4 text-center max-w-[640px]">
                <Glyph size={112}/>
                <div className="sg-rise flex flex-col gap-2.5">
                    <h1 className="m-0 text-[40px] leading-tight font-semibold tracking-tight">I'm Sigil.</h1>
                    <p className="m-0 text-base leading-relaxed text-fg-2">Ask me anything, or hand me a task. When you want an agent, describe it and I'll work out the details with you. Once it's clear, I'll compile it to AG-IR, check every rule made it in, and show you its graph.</p>
                </div>
            </div>

            <div className="relative w-full max-w-[760px] flex flex-col gap-2.5 p-3.5 rounded-2xl border border-line-2 bg-ink-2 focus-within:ring-2 focus-within:ring-violet-500/50">
                <label htmlFor="hero-input" className="sr-only">Message Sigil</label>
                <textarea id="hero-input" rows={3} value={text} onKeyDown={keyed}
                    onChange={lambda (e: ChangeEvent) { text = e.target.value; }}
                    placeholder="Message Sigil"
                    className="resize-none bg-transparent border-0 outline-none text-[15px] leading-relaxed text-fg placeholder:text-faint px-1.5 py-1"></textarea>
                <div className="flex flex-wrap items-center gap-2">
                    <label htmlFor="hero-pick" title="Compile a skill folder"
                        className={"inline-flex items-center justify-center w-11 h-11 rounded-[10px] border border-line-2 text-fg-2 hover:bg-ink-3 " + ("opacity-50" if starting else "cursor-pointer")}>
                        <span className="sr-only">Compile a skill folder</span>
                        <Icon name="clip" size={16}/>
                    </label>
                    <input id="hero-pick" type="file" webkitdirectory="" multiple={True} className="hidden" disabled={starting}
                        onChange={lambda (e: ChangeEvent) { compileFiles(e.target.files); }}/>
                    {(<Spinner label="Reading the folder…"/>) if starting else None}
                    <button type="button" className={BTN + " ml-auto h-11 px-4"} disabled={not text.strip()}
                        onClick={lambda (e: MouseEvent) { submit(); }}>
                        Send<Icon name="send" size={15}/>
                    </button>
                </div>
            </div>
            {(<div className="w-full max-w-[760px]"><Note text={err} tone="bad"/></div>) if err else None}

            <div className="flex flex-wrap justify-center gap-2.5 max-w-[900px]">
                {for sg in SUGGEST {
                    <button key={sg} type="button" onClick={lambda (e: MouseEvent) { onAsk(sg); }}
                        className="min-h-11 px-3.5 py-2 rounded-full border border-line-2 bg-transparent text-fg-2 text-[13px] cursor-pointer hover:bg-ink-3 hover:text-fg">{sg}</button>
                }}
            </div>

            {(<section aria-labelledby="hero-shelf" className="w-full max-w-[1120px] flex flex-col gap-3.5 mt-2">
                <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                    <h2 id="hero-shelf" className="m-0 text-[13px] font-semibold">On your shelf</h2>
                    <span className="text-[12.5px] text-faint">{str(len(skills)) + (" compiled agent" if (len(skills) == 1) else " compiled agents") + " · each mark is a step: diamonds the model decides, squares run as code"}</span>
                </div>
                <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(250px,1fr))]">
                    {for s in ranked {
                        <button key={str(s.signature)} type="button" onClick={lambda (e: MouseEvent) { onOpen(str(s.signature)); }}
                            className="flex flex-col gap-2 p-3.5 rounded-xl border border-line bg-ink-2 text-left cursor-pointer hover:border-line-2">
                            <span className="flex items-center gap-2 min-w-0 w-full">
                                <span className="font-mono text-[13px] font-medium text-fg truncate">{s.signature}</span>
                                <span className="font-mono text-[11px] text-acc bg-acc/10 rounded px-1.5 shrink-0">{"v" + str(s.version)}</span>
                            </span>
                            {(<span className="text-[12.5px] leading-snug text-muted line-clamp-2">{str(s.intent)}</span>) if s.intent else None}
                            <Marks marks={list(s.marks) if s.marks else []}/>
                            <span className="text-xs text-faint">{_meta(s)}</span>
                        </button>
                    }}
                </div>
            </section>) if (len(skills) > 0) else None}
        </div>
    </div>;
}

def Shelf(skills: list[any], sig: str, onCollapse: Callable[[], None], onNew: Callable[[], None]) -> JsxElement {
    has q: str = "";
    words = [w for w in q.lower().split(" ") if w];
    shown = [s for s in skills if _matches(s, words)];
    return <aside aria-labelledby="shelf-h" className="lg:w-[232px] shrink-0 max-h-[45vh] lg:max-h-none min-h-0 flex flex-col border-b lg:border-b-0 lg:border-r border-line bg-ink-1">
        <div className="flex flex-col gap-2.5 px-3 pt-3.5 pb-2.5">
            <div className="flex items-center gap-2">
                <h2 id="shelf-h" className="m-0 text-[13px] font-semibold">Shelf</h2>
                <span className="font-mono text-[11.5px] text-faint">{str(len(skills))}</span>
                <button type="button" aria-label="Collapse the shelf" onClick={lambda (e: MouseEvent) { onCollapse(); }}
                    className="ml-auto hidden lg:inline-flex items-center justify-center w-8 h-8 rounded-lg bg-transparent border-0 text-faint hover:text-fg hover:bg-ink-3 cursor-pointer">
                    <Icon name="back" size={15}/>
                </button>
            </div>
            <label className="flex items-center gap-2 h-10 px-2.5 rounded-[9px] border border-line-2 bg-ink-2 text-faint">
                <Icon name="search" size={14}/>
                <span className="sr-only">Filter agents</span>
                <input value={q} placeholder="Filter agents" onChange={lambda (e: ChangeEvent) { q = e.target.value; }}
                    className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[13px] text-fg placeholder:text-faint"/>
            </label>
        </div>
        <nav aria-label="Compiled agents" className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-0.5 px-2 pb-2">
            {(<p className="m-0 px-2 py-3 text-[12.5px] leading-relaxed text-muted">{"Nothing matches." if skills else "No compiled agents yet. Describe one in the chat, or compile a skill folder with the paperclip."}</p>) if (len(shown) == 0) else None}
            {for s in shown {
                <a key={str(s.signature)} href={"#/studio/" + str(s.signature)}
                    aria-current={"page" if (str(s.signature) == sig) else None}
                    className={"flex flex-col gap-1.5 min-h-11 px-2.5 py-2 rounded-[9px] no-underline " + ("bg-violet-500/15 text-fg" if (str(s.signature) == sig) else "text-fg-2 hover:bg-ink-3")}>
                    <span className="flex items-center gap-1.5 min-w-0">
                        <span className="font-mono text-[12.5px] truncate">{s.signature}</span>
                        <span className={"font-mono text-[10.5px] shrink-0 " + ("text-acc" if (str(s.signature) == sig) else "text-faint")}>{"v" + str(s.version)}</span>
                    </span>
                    <Marks marks={list(s.marks) if s.marks else []}/>
                </a>
            }}
        </nav>
        <div className="px-3 py-2.5 border-t border-line">
            <button type="button" onClick={lambda (e: MouseEvent) { onNew(); }}
                className="w-full inline-flex items-center justify-center gap-2 h-11 rounded-[10px] border border-dashed border-line-2 bg-transparent text-fg-2 text-[13px] cursor-pointer hover:bg-ink-3">
                <Icon name="plus" size={15}/>New agent
            </button>
        </div>
    </aside>;
}

def Viewer(sig: str, dark: bool, onFocus: Callable[[any], None], onChanged: Callable[[], None]) -> JsxElement {
    has detail: any = None;
    has agirG: any = None;
    has err: str = "";
    has agirErr: str = "";
    has sel: str = "";
    has tab: str = "graph";
    has exposing: bool = False;
    has copied: bool = False;
    has curRef: Ref[any] = Ref();

    cref: any = curRef;
    cref.current = sig;

    def isCurrent(s: str) -> bool {
        cr: any = curRef;
        return str(cr.current) == s;
    }

    async def loadDetail(s: str) {
        r = root spawn api_console(op="skill_detail", args={"signature": s});
        m: any = r.reports[0] if r.reports else None;
        if not isCurrent(s) { return; }
        if m and m.ok { detail = remember("skill:" + s, m); err = ""; }
        elif m { err = str(m.error); }
        else { err = "no response from Sigil"; }
    }

    async def loadAgir(s: str) {
        r = root spawn api_skill_agir(signature=s);
        m: any = r.reports[0] if r.reports else None;
        if not isCurrent(s) { return; }
        if m and m.ok { agirG = remember("agir:" + s, m); agirErr = ""; }
        elif m { agirErr = str(m.error); }
        else { agirErr = "no response from Sigil"; }
    }

    async def expose(on: bool) {
        exposing = True;
        r = root spawn api_console(op="skill_expose", args={"signature": sig, "on": on});
        m: any = r.reports[0] if r.reports else None;
        exposing = False;
        if m and m.ok and detail { detail = {**detail, "exposed": bool(m.exposed)}; onChanged(); }
        elif m and m.error { err = str(m.error); }
    }

    useEffect(lambda {
        detail = seen("skill:" + sig);
        agirG = seen("agir:" + sig);
        err = "";
        agirErr = "";
        sel = "";
        if sig {
            loadDetail(sig);
            loadAgir(sig);
        }
    }, [sig]);

    def copyIr(e: MouseEvent) {
        copyText(str(detail.agir));
        copied = True;
        setTimeout(lambda { copied = False; }, 1500);
    }

    d: any = detail if (detail and (str(detail.signature) == sig)) else None;
    ag: any = agirG if (agirG and (str(agirG.signature) == sig)) else None;
    nodes: list[any] = list(ag.nodes) if (ag and ag.nodes) else [];
    edges: list[any] = list(ag.edges) if (ag and ag.edges) else [];
    selNode: any = None;
    for n in nodes { if str(n.id) == sel { selNode = n; } }
    into = [e for e in edges if str(e.dst) == sel];
    outof = [e for e in edges if str(e.src) == sel];
    model = modelSteps([str(n.group) for n in nodes]);
    origin = str(d.origin) if d else "";
    fromSkill = bool(d) and bool(str(d.skill_src or "").strip());

    if not sig {
        return <section aria-label="Agent viewer" className="flex-1 min-w-0 min-h-[60vh] lg:min-h-0 flex items-center justify-center bg-ink-1 px-6">
            <div className="max-w-[380px] flex flex-col items-center gap-3 text-center">
                <Logo size={36}/>
                <h2 className="m-0 text-[15px] font-semibold">No agent open</h2>
                <p className="m-0 text-[13px] leading-relaxed text-muted">Pick one off the shelf, or ask Sigil to build one. Its AG-IR is drawn here as a graph you can click through.</p>
            </div>
        </section>;
    }

    return <section aria-labelledby="viewer-h" className="flex-1 min-w-0 min-h-[80vh] lg:min-h-0 flex flex-col bg-ink-1">
        <div className="flex flex-col gap-2 px-5 pt-3.5 border-b border-line">
            <div className="flex flex-wrap items-center gap-x-2.5 gap-y-2">
                <h2 id="viewer-h" className="m-0 font-mono text-lg font-medium truncate min-w-0">{sig}</h2>
                {(<span className="font-mono text-[11px] text-acc bg-acc/10 rounded px-1.5">{"v" + str(d.version)}</span>) if d else None}
                {(<span className={chip("")}>{_originLabel(origin, fromSkill)}</span>) if d else None}
                {(<span className={chip("acc")}>{str(model) + " of " + str(len(nodes)) + " steps decided by the model"}</span>) if (len(nodes) > 0) else None}
                <span className="ml-auto flex flex-wrap items-center gap-2">
                    <button type="button" className={BTN_SM} onClick={lambda (e: MouseEvent) { onFocus({"sig": sig, "node": "", "run": True}); }}>
                        <Icon name="play" size={12} fill={True}/>Run
                    </button>
                    {(<span className="inline-flex items-center gap-2 text-xs text-muted">
                        <Toggle on={bool(d.exposed)} label="Expose over MCP" disabled={exposing} onToggle={expose}/>MCP
                    </span>) if d else None}
                    <a href={"#/skills/" + sig} className={BTN2_SM + " no-underline"} title="Runs, gates, versions, eval and relearn">Full page<Icon name="external" size={12}/></a>
                </span>
            </div>
            {(<p className="m-0 text-[12.5px] leading-snug text-muted">{str(d.intent)}</p>) if (d and d.intent) else None}
            <div role="tablist" aria-label="Agent views" className="flex flex-wrap gap-1">
                <button type="button" role="tab" aria-selected={"true" if (tab == "graph") else "false"} className={TAB_ON if (tab == "graph") else TAB_OFF} onClick={lambda (e: MouseEvent) { tab = "graph"; }}>Graph</button>
                <button type="button" role="tab" aria-selected={"true" if (tab == "agir") else "false"} className={TAB_ON if (tab == "agir") else TAB_OFF} onClick={lambda (e: MouseEvent) { tab = "agir"; }}>AG-IR</button>
                <button type="button" role="tab" aria-selected={"true" if (tab == "source") else "false"} className={TAB_ON if (tab == "source") else TAB_OFF} onClick={lambda (e: MouseEvent) { tab = "source"; }}>SKILL.md</button>
                <a href={"#/skills/" + sig + "/gates"} className={TAB_LINK}>Gates</a>
                <a href={"#/skills/" + sig + "/runs"} className={TAB_LINK}>{"Runs" + ((" · " + str(d.runs)) if (d and d.runs) else "")}</a>
                <a href={"#/skills/" + sig + "/versions"} className={TAB_LINK}>{"Versions" + ((" · " + str(len(d.versions))) if (d and d.versions) else "")}</a>
            </div>
        </div>
        {(<div className="px-5 pt-3"><Note text={err} tone="bad"/></div>) if err else None}

        {if tab == "graph" {
            <div className="flex-1 min-h-0 flex flex-col">
                <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 px-5 py-2 border-b border-line text-xs text-muted">
                    {for lg in LEGEND {
                        <span key={str(lg[0])} className="inline-flex items-center gap-1.5">
                            <span className={markCls(str(lg[0]))}></span>
                            {str(lg[1]) + " " + str(len([n for n in nodes if str(n.group) == str(lg[0])]))}
                        </span>
                    }}
                    <span className="ml-auto text-faint">Click a step to inspect it · scroll to zoom</span>
                </div>
                {(<div className="px-5 pt-3"><Note text={str(ag.warning)}/></div>) if (ag and ag.warning) else None}
                <div className="flex-1 min-h-0 flex flex-col xl:flex-row">
                    <div className="relative flex-1 min-h-[380px]">
                        {if len(nodes) > 0 {
                            <AgirCanvas nodes={ag.nodes} edges={ag.edges} dark={dark} direction="UD"
                                onSelect={lambda (nid: str) { sel = nid; }}/>
                        } elif agirErr {
                            <div className="p-5"><Note text={agirErr} tone="bad"/></div>
                        } elif not ag {
                            <div className="absolute inset-0 flex items-center justify-center"><Spinner label="Drawing the AG-IR…"/></div>
                        }}
                    </div>
                    {(<aside aria-labelledby="insp-h" className="xl:w-[280px] shrink-0 max-h-[50vh] xl:max-h-none overflow-y-auto border-t xl:border-t-0 xl:border-l border-line bg-ink-2 p-4 flex flex-col gap-3.5">
                        <div className="flex flex-col gap-1.5">
                            <span className="inline-flex items-center gap-1.5 text-[11px] font-medium tracking-wider uppercase text-faint">
                                <span className={markCls(str(selNode.group))}></span>
                                {_groupLabel(str(selNode.group)) + ((" · " + _who(str(selNode.group))) if _who(str(selNode.group)) else "")}
                            </span>
                            <h3 id="insp-h" className="m-0 font-mono text-sm font-medium break-all">{str(selNode.id)}</h3>
                            <span className="font-mono text-[11.5px] text-acc">{str(selNode.type)}</span>
                        </div>
                        {(<p className="m-0 text-[12.5px] leading-relaxed text-fg-2 whitespace-pre-wrap">{str(selNode.doc)}</p>) if selNode.doc else None}
                        {(<Field label="Reads → writes">
                            <span className="font-mono">{(", ".join([str(x) for x in selNode.reads]) or "—") + "  →  " + (", ".join([str(x) for x in selNode.writes]) or "—")}</span>
                        </Field>) if ((len(selNode.reads) > 0) or (len(selNode.writes) > 0)) else None}
                        {(<Field label="Tool"><span className="font-mono">{str(selNode.tool)}</span></Field>) if selNode.tool else None}
                        {(<Field label="Realizes rules"><span className="font-mono">{", ".join([str(x) for x in selNode.traces_to])}</span></Field>) if (len(selNode.traces_to) > 0) else None}
                        {(<Field label="Comes from"><span className="font-mono">{", ".join([str(e.src) for e in into])}</span></Field>) if (len(into) > 0) else None}
                        {(<Field label="Goes to"><span className="font-mono">{", ".join([str(e.dst) + ((" (" + str(e.label) + ")") if e.label else "") for e in outof])}</span></Field>) if (len(outof) > 0) else None}
                        <div className="flex flex-col gap-2 mt-auto pt-1">
                            <button type="button" className={BTN2_SM + " h-10"}
                                onClick={lambda (e: MouseEvent) { onFocus({"sig": sig, "node": str(selNode.id), "run": False}); }}>Ask Sigil about this step</button>
                            <button type="button" className={BTN_GHOST_SM + " h-10"} onClick={lambda (e: MouseEvent) { sel = ""; }}>Close</button>
                        </div>
                    </aside>) if selNode else None}
                </div>
            </div>
        } elif tab == "agir" {
            <div className="flex-1 min-h-0 flex flex-col">
                <div className="flex items-center gap-2 px-5 py-2 border-b border-line text-xs text-muted">
                    <span>{("v" + str(d.version) + " · the typed contract it lowers to Jac") if d else ""}</span>
                    {(<button type="button" className={BTN_GHOST_SM + " ml-auto"} onClick={copyIr}><Icon name="copy" size={13}/>{"Copied" if copied else "Copy"}</button>) if (d and d.agir) else None}
                </div>
                <div className="flex-1 min-h-0">
                    {if d and d.agir { <pre className={PRE + " whitespace-pre"}>{str(d.agir)}</pre> }
                     elif d { <p className="m-0 p-5 text-[13px] text-muted">This skill has no stored AG-IR.</p> }
                     else { <div className="p-5"><Spinner label="Loading…"/></div> }}
                </div>
            </div>
        } else {
            <div className="flex-1 min-h-0">
                {if fromSkill { <pre className={PRE + " whitespace-pre-wrap break-words"}>{str(d.skill_src)}</pre> }
                 elif d { <p className="m-0 p-5 text-[13px] leading-relaxed text-muted">This skill was learned from a task, so it has no SKILL.md. Its AG-IR was authored from the task's intent.</p> }
                 else { <div className="p-5"><Spinner label="Loading…"/></div> }}
            </div>
        }}
    </section>;
}

def:pub StudioPage(route: list[str], draft: str, clearDraft: Callable[[], None],
                   refresh: Callable[[], None], dark: bool) -> JsxElement {
    has skills: list[any] = [];
    has chatN: int = 0;
    has panes: bool = False;
    has focus: any = None;
    has job: str = "";
    has asked: str = "";
    has shelfOpen: bool = True;

    sig = str(route[1]) if ((len(route) > 1) and (str(route[0]) == "studio")) else "";

    async def loadSkills() {
        r = root spawn api_console(op="skills", args={});
        m: any = r.reports[0] if r.reports else None;
        if m and isinstance(m, list) { skills = remember("skills", list(m)); }
    }

    can with entry {
        saved: any = storeGet("sigil.chat", None);
        chatN = len(saved.msgs) if (saved and saved.msgs) else 0;
        shelfOpen = bool(storeGet(SHELF_KEY, True));
        pv: any = seen("skills");
        if pv { skills = pv; }
        loadSkills();
    }

    def resolve(x: str) -> str {
        # A turn names a skill by signature or by its tool name (skill_<sig>).
        for s in skills {
            if (str(s.signature) == x) or (str(s.tool) == x) { return str(s.signature); }
        }
        return x[6:] if x.startswith("skill_") else x;
    }

    def openSkill(x: str) {
        panes = True;
        loadSkills();
        refresh();
        navTo("/studio/" + resolve(x));
    }

    def askFirst(t: str) { asked = t; panes = True; }
    def startJob(j: str) { job = j; panes = True; }
    def setFocus(f: any) { focus = f; panes = True; }
    def clearFocus() { focus = None; }
    def clearAsked() { asked = ""; clearDraft(); }
    def clearJob() { job = ""; }
    def counted(n: int) {
        chatN = n;
        if (n == 0) and (not sig) { panes = False; }
    }
    def collapse() { shelfOpen = False; storeSet(SHELF_KEY, False); }
    def expand(e: MouseEvent) { shelfOpen = True; storeSet(SHELF_KEY, True); }
    def newAgent() {
        focus = None;
        panes = True;
        navTo("/");
        focusId("chat-input");
    }

    # A chip frames a question about one skill: switching skills drops it.
    useEffect(lambda {
        focus = None;
        return;
    }, [sig]);

    pending = asked if asked else draft;
    hero = (chatN == 0) and (not sig) and (not panes) and (not pending) and (not job);

    if hero {
        return <Hero skills={skills} onAsk={askFirst} onJob={startJob} onOpen={openSkill}/>;
    }

    return <div className="flex-1 min-h-0 flex flex-col lg:flex-row overflow-y-auto lg:overflow-hidden">
        {if shelfOpen {
            <Shelf skills={skills} sig={sig} onCollapse={collapse} onNew={newAgent}/>
        } else {
            <div className="hidden lg:flex w-14 shrink-0 flex-col items-center gap-2 py-3 border-r border-line bg-ink-1">
                <button type="button" aria-label={"Open the shelf (" + str(len(skills)) + " agents)"} onClick={expand}
                    className="inline-flex items-center justify-center w-11 h-11 rounded-[10px] border-0 bg-ink-3 text-acc cursor-pointer hover:bg-ink-4">
                    <Icon name="library" size={17}/>
                </button>
                <span className="font-mono text-[11px] text-faint">{str(len(skills))}</span>
            </div>
        }}
        <div className="lg:w-[440px] xl:w-[480px] shrink-0 min-h-[70vh] lg:min-h-0 flex flex-col border-b lg:border-b-0 lg:border-r border-line">
            <ChatPane draft={pending} clearDraft={clearAsked} refresh={refresh} onSkill={openSkill} onCount={counted}
                focus={focus} clearFocus={clearFocus} job={job} clearJob={clearJob}/>
        </div>
        <Viewer sig={sig} dark={dark} onFocus={setFocus} onChanged={loadSkills}/>
    </div>;
}

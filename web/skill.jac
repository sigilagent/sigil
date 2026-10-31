"""Skill: one compiled skill, opened.

The top says what it is (signature, version, where it came from, how its runs
went) and carries what you can do to it: run it on a task, grade it on a probe,
relearn it, let MCP clients call it, forget it. The tabs are its views: the AG-IR
drawn as a graph with an inspector, the SKILL.md beside the AG-IR it compiled to,
the mechanical gates re-run against that AG-IR, its runs, and its versions.

#/skills/<signature>/<tab> is one view of it, so a tab can be linked to. The page
stays mounted while the signature changes, so every load is tied to the signature
it asked about and an answer that lands after you moved on is dropped.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_solve, api_eval, api_relearn, api_forget, api_skill_agir }
import from .ui {
    PageHead, Icon, Toggle, Segmented, Empty, Note, Spinner, Stat, Bar, CARD, BTN, BTN2, BTN_SM,
    BTN2_SM, BTN_GHOST_SM, BTN_BAD, BTN_BAD_SM, INP, AREA, LABEL, chip, tagCls, dotCls
}
import from .agir_canvas { AgirCanvas }
import from "./console_interop.js" { storeGet, navTo, seen, remember, fmtAgo, copyText }
import from react { useEffect }

glob TAB_KEYS: list[str] = ["overview", "source", "gates", "runs", "versions"];

# [group, label, mark]: the AG-IR canvas's colours and shapes, as a legend.
glob LEGEND: list[any] = [
    ["semantic", "Semantic", "inline-block w-2.5 h-2.5 shrink-0 rotate-45 bg-[#a78bfa]"],
    ["delegated", "Delegated", "inline-block w-2.5 h-2.5 shrink-0 rotate-45 bg-[#f472b6]"],
    ["executable", "Executable", "inline-block w-2.5 h-2.5 shrink-0 rounded-sm bg-[#22d3ee]"],
    ["control", "Control", "inline-block w-2.5 h-2.5 shrink-0 rounded-full bg-[#f5c451]"],
    ["termination", "Return", "inline-block w-2.5 h-2.5 shrink-0 rounded-full bg-[#4ade80]"]
];

glob CLOSE_BTN: str = "ml-auto inline-flex items-center justify-center w-7 h-7 rounded-md text-muted hover:text-fg hover:bg-ink-3 bg-transparent border-0 cursor-pointer";
glob PRE: str = "m-0 px-3 py-2.5 rounded-lg bg-ink-1 border border-line text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-fg-2 overflow-auto";

def _okPct(runs: int, oks: int) -> float {
    if runs <= 0 { return -1.0; }
    return (float(oks) * 100.0) / float(runs);
}

def _pctTone(p: float) -> str {
    if p < 0 { return ""; }
    if p >= 90 { return "ok"; }
    if p >= 60 { return "warn"; }
    return "bad";
}

def _originLabel(origin: str) -> str {
    o = str(origin or "").lower();
    if "relearn" in o { return "relearned"; }
    if "mutat" in o { return "mutated"; }
    if ("skill" in o) or ("compiled" in o) { return "compiled from SKILL.md"; }
    if o == "frontier" { return "learned from a task"; }
    return o if o else "unknown origin";
}

def _groupLabel(g: str) -> str {
    for lg in LEGEND { if lg[0] == g { return str(lg[1]); } }
    return "Other";
}

def _groupMark(g: str) -> str {
    for lg in LEGEND { if lg[0] == g { return str(lg[2]); } }
    return "inline-block w-2.5 h-2.5 shrink-0 rounded-full border border-faint";
}

def _nGroup(nodes: list[any], g: str) -> int {
    return len([n for n in nodes if str(n.group) == g]);
}

def _gateTone(gt: any) -> str {
    if not gt.enabled { return ""; }
    if gt.ok { return "ok"; }
    if str(gt.severity) == "warn" { return "warn"; }
    return "bad";
}

def _gateWord(gt: any) -> str {
    if not gt.enabled { return "off"; }
    if gt.ok { return "pass"; }
    if str(gt.severity) == "warn" { return "warning"; }
    return "fail";
}

def Field(label: str, children: any = None) -> JsxElement {
    return <div className="flex flex-col gap-0.5 min-w-0">
        <span className={LABEL}>{label}</span>
        <span className="text-fg-2 break-words">{children}</span>
    </div>;
}

def:pub SkillPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None],
                  refresh: Callable[[], None]) -> JsxElement {
    has detail: any = None;
    has missing: bool = False;
    has err: str = "";
    has agirG: any = None;
    has agirErr: str = "";
    has gates: any = None;
    has gatesFor: str = "";
    has gatesBusy: bool = False;
    has gatesErr: str = "";
    has sel: str = "";
    has panel: str = "";
    has confirming: bool = False;
    has task: str = "";
    has probe: str = "";
    has hint: str = "";
    has busy: str = "";
    has msg: str = "";
    has msgTone: str = "live";
    has runRes: any = None;
    has evalRes: any = None;
    has copied: str = "";
    has curRef: Ref[any] = Ref();

    sig = str(route[1]) if (len(route) > 1) else "";
    tab = str(route[2]) if ((len(route) > 2) and (str(route[2]) in TAB_KEYS)) else "overview";
    cref: any = curRef;
    cref.current = sig;

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    def isCurrent(s: str) -> bool {
        cr: any = curRef;
        return str(cr.current) == s;
    }

    async def loadDetail(s: str) {
        m: any = await call("skill_detail", {"signature": s});
        if not isCurrent(s) { return; }
        if m and m.ok {
            detail = remember("skill:" + s, m);
            missing = False;
            err = "";
        } elif m and ("no such skill" in str(m.error or "")) {
            remember("skill:" + s, None);
            missing = True;
        } elif m { err = str(m.error); }
    }

    async def loadAgir(s: str) {
        r = root spawn api_skill_agir(signature=s);
        m: any = r.reports[0] if r.reports else None;
        if not isCurrent(s) { return; }
        if m and m.ok { agirG = remember("agir:" + s, m); agirErr = ""; }
        elif m { agirErr = str(m.error); }
        else { agirErr = "no response from Sigil"; }
    }

    async def loadGates(s: str) {
        gatesBusy = True;
        gatesErr = "";
        m: any = await call("skill_gates", {"signature": s});
        gatesBusy = False;
        if not isCurrent(s) { return; }
        if m and m.ok { gates = remember("gates:" + s, m); }
        elif m { gatesErr = str(m.error); }
        else { gatesErr = "no response from Sigil"; }
    }

    # What this render shows: only answers about the skill in the route.
    d: any = detail if (detail and (str(detail.signature) == sig)) else None;
    ag: any = agirG if (agirG and (str(agirG.signature) == sig)) else None;
    gv: any = gates if (gates and (str(gates.signature) == sig)) else None;
    ver = int(d.version) if d else 0;

    useEffect(lambda {
        pd: any = seen("skill:" + sig);
        pg: any = seen("agir:" + sig);
        detail = pd;
        agirG = pg;
        missing = False;
        err = "";
        agirErr = "";
        sel = "";
        panel = "";
        confirming = False;
        runRes = None;
        evalRes = None;
        msg = "";
        if sig {
            loadDetail(sig);
            loadAgir(sig);
        }
    }, [sig]);

    # The gates lower and type-check the AG-IR, so they run only when their tab
    # opens, and again when a relearn has made a newer version than they saw.
    useEffect(lambda {
        if (tab != "gates") or (not sig) { return; }
        stale = bool(gv) and (ver > 0) and (int(gv.version) != ver);
        if (gatesFor != sig) or (stale and (not gatesBusy)) {
            gatesFor = sig;
            if not gv {
                pt: any = seen("gates:" + sig);
                if pt { gates = pt; }
            }
            loadGates(sig);
        }
    }, [sig, tab, ver]);

    acting = busy != "";

    def askAbout(q: str) { ask("About skill " + sig + ": " + q); }

    def pickTab(v: str) {
        navTo("/skills/" + sig + ("" if (v == "overview") else ("/" + v)));
    }

    def openPanel(p: str) {
        panel = "" if (panel == p) else p;
        confirming = False;
    }

    def pickNode(nid: str) { sel = nid; }

    def copy(what: str, text: str) {
        copyText(text);
        copied = what;
        setTimeout(lambda { copied = ""; }, 1500);
    }

    async def runIt() {
        t = task.strip();
        if not t { return; }
        s = sig;
        busy = "run";
        runRes = None;
        msg = "";
        r = root spawn api_solve(task=t, skill=s);
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        if not isCurrent(s) { return; }
        if m and (not m.error) {
            runRes = m;
            loadDetail(s);
            tr = str(m.trace or "");
            # a failed run is retried on a mutated (or relearned) version
            if ("mutate" in tr) or ("relearn" in tr) { loadAgir(s); }
            refresh();
        } else {
            msgTone = "bad";
            msg = str(m.error) if m else "no response from Sigil";
        }
    }

    async def evalIt() {
        s = sig;
        busy = "eval";
        evalRes = None;
        msg = "";
        r = root spawn api_eval(signature=s, probe=probe.strip());
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        if not isCurrent(s) { return; }
        if m and m.ok {
            evalRes = m;
            if detail { detail = {**detail, "last_score": m.score, "last_eval": m.reason}; }
            loadDetail(s);
        } else {
            msgTone = "bad";
            msg = str(m.error) if m else "no response from Sigil";
        }
    }

    async def relearnIt() {
        s = sig;
        h = hint.strip();
        busy = "relearn";
        msgTone = "live";
        msg = "Relearning " + s + ". This is a full compile and can take several minutes.";
        r = root spawn api_relearn(signature=s, hint=h);
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        if not isCurrent(s) { return; }
        if m and m.ok {
            msgTone = "ok";
            msg = "Relearned " + s + " as v" + str(m.version) + ".";
            hint = "";
            panel = "";
            loadDetail(s);
            loadAgir(s);
            refresh();
        } else {
            msgTone = "bad";
            msg = str(m.error) if m else "no response from Sigil";
        }
    }

    async def expose(on: bool) {
        s = sig;
        busy = "expose";
        if detail { detail = {**detail, "exposed": on}; }
        m: any = await call("skill_expose", {"signature": s, "on": on});
        busy = "";
        if not isCurrent(s) { return; }
        if m and m.ok {
            if detail { detail = remember("skill:" + s, {**detail, "exposed": bool(m.exposed)}); }
        } else {
            msgTone = "bad";
            msg = str(m.error) if m else "no response from Sigil";
            loadDetail(s);
        }
    }

    async def forgetIt() {
        s = sig;
        busy = "forget";
        msg = "";
        r = root spawn api_forget(signature=s);
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        confirming = False;
        if m and (not m.error) and m.removed {
            remember("skill:" + s, None);
            remember("agir:" + s, None);
            remember("gates:" + s, None);
            prevSkills: any = seen("skills");
            if prevSkills { remember("skills", [x for x in prevSkills if str(x.signature) != s]); }
            refresh();
            navTo("/skills");
        } elif m and (not m.error) {
            msgTone = "bad";
            msg = "Nothing was removed: no skill is named " + s + ".";
        } else {
            msgTone = "bad";
            msg = str(m.error) if m else "no response from Sigil";
        }
    }

    dark = not bool(storeGet("sigil.light", False));
    runs = int(d.runs) if (d and d.runs) else 0;
    oks = int(d.successes) if (d and d.successes) else 0;
    pct = _okPct(runs, oks);
    score = int(d.last_score) if (d and (d.last_score is not None)) else -1;
    exposed = bool(d.exposed) if d else False;
    hasSrc = bool(d and str(d.skill_src or "").strip());
    hasIr = bool(d and str(d.agir or "").strip());
    versions: list[any] = list(d.versions) if (d and d.versions) else [];
    attempts: list[any] = list(d.attempts) if (d and d.attempts) else [];

    origin = _originLabel(str(d.origin)) if d else "";
    if d and hasSrc and (origin in ["relearned", "mutated"]) { origin = origin + " · from SKILL.md"; }
    runsText = "never run";
    if runs > 0 { runsText = str(oks) + "/" + str(runs) + " runs ok"; }
    if score >= 0 { runsText = runsText + " · eval " + str(score); }

    nodes: list[any] = ag.nodes if (ag and ag.nodes) else [];
    edgesAll: list[any] = ag.edges if (ag and ag.edges) else [];
    tools: list[any] = ag.tools if (ag and ag.tools) else [];
    carries: list[any] = ag.carries if (ag and ag.carries) else [];
    selNode: any = None;
    for n in nodes { if str(n.id) == sel { selNode = n; } }
    into: list[any] = [e for e in edgesAll if str(e.dst) == sel] if selNode else [];
    outof: list[any] = [e for e in edgesAll if str(e.src) == sel] if selNode else [];

    grows: list[any] = list(gv.gates) if (gv and gv.gates) else [];
    gOn = [x for x in grows if x.enabled];
    gPass = [x for x in gOn if x.ok];
    gFail = [x for x in gOn if (not x.ok) and (str(x.severity) != "warn")];
    gWarn = [x for x in gOn if (not x.ok) and (str(x.severity) == "warn")];
    gOff = len(grows) - len(gOn);
    gTone = "bad" if (len(gFail) > 0) else ("warn" if (len(gWarn) > 0) else "ok");
    gText = "gates " + str(len(gPass)) + "/" + str(len(gOn));
    if len(gFail) > 0 { gText = gText + " · " + str(gFail[0].id) + " failed"; }
    elif len(gWarn) > 0 { gText = gText + " · " + str(gWarn[0].id) + " warning"; }
    gSummary = str(len(gPass)) + " pass";
    if len(gFail) > 0 { gSummary = gSummary + " · " + str(len(gFail)) + " fail"; }
    if len(gWarn) > 0 { gSummary = gSummary + " · " + str(len(gWarn)) + (" warning" if (len(gWarn) == 1) else " warnings"); }
    if gOff > 0 { gSummary = gSummary + " · " + str(gOff) + " off"; }

    runOk = ("DONE ok" in str(runRes.trace or "")) if runRes else False;

    return <div className="flex flex-col">
        <PageHead title={sig} kicker="Skills · Library" mono={True} onAsk={askAbout}
            askHint={"Ask about " + sig} tag={(sig + " v" + str(d.version)) if d else sig}/>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-4">
            {if missing {
                <Empty title={"No skill named " + sig}
                    body="Nothing in the library has this signature. It may have been forgotten, or the link has a typo.">
                    <a href="#/skills" className={BTN_SM + " no-underline"}>Back to the Library</a>
                </Empty>
            } elif not d {
                if err { <Note text={err} tone="bad"/> }
                else { <Spinner label="Reading the skill…"/> }
            } else {
                <div className="flex flex-wrap items-center gap-2.5">
                    <span className="font-mono text-[13px] text-fg-2">{"v" + str(d.version)}</span>
                    <span className={chip("")}>{origin}</span>
                    {(<span className={chip(gTone)}>{gText}</span>) if (len(gOn) > 0) else None}
                    <span className={chip("")}>{runsText}</span>
                    {(<span className={chip("acc") + " font-mono"}>{"MCP · " + str(d.tool)}</span>) if exposed else (<span className={chip("")}>not on MCP</span>)}
                </div>
                if d.intent { <p className="m-0 text-[13.5px] leading-relaxed text-fg-2 max-w-3xl">{str(d.intent)}</p> }

                <div className="flex flex-wrap items-center gap-2">
                    <button type="button" className={BTN} aria-expanded={"true" if (panel == "run") else "false"}
                        onClick={lambda (e: MouseEvent) { openPanel("run"); }}>
                        <Icon name="play" size={13} fill={True}/>Run…
                    </button>
                    <button type="button" className={BTN2} aria-expanded={"true" if (panel == "eval") else "false"}
                        onClick={lambda (e: MouseEvent) { openPanel("eval"); }}>Eval…</button>
                    <button type="button" className={BTN2} aria-expanded={"true" if (panel == "relearn") else "false"}
                        onClick={lambda (e: MouseEvent) { openPanel("relearn"); }}>Relearn…</button>
                    <span className="inline-flex items-center gap-2 h-9 px-1.5 text-[12.5px] text-fg-2">
                        <Toggle on={exposed} label={"Let MCP clients call " + sig} disabled={acting}
                            onToggle={lambda (v: bool) { expose(v); }}/>
                        Callable over MCP
                    </span>
                    {if confirming {
                        <span className="ml-auto inline-flex flex-wrap items-center gap-2 px-3 py-1.5 rounded-lg border border-bad/30 bg-bad/10">
                            <span className="text-[12.5px] text-bad">
                                {"Forget " + sig + "? Every version (" + str(len(versions)) + "), its run history and the lowered module on disk go. This cannot be undone."}
                            </span>
                            <button type="button" className={BTN_BAD_SM} disabled={acting}
                                onClick={lambda (e: MouseEvent) { forgetIt(); }}>{"Forgetting…" if (busy == "forget") else "Forget it"}</button>
                            <button type="button" className={BTN_GHOST_SM} disabled={busy == "forget"}
                                onClick={lambda (e: MouseEvent) { confirming = False; }}>Cancel</button>
                        </span>
                    } else {
                        <button type="button" className={BTN_BAD + " ml-auto"} disabled={acting}
                            onClick={lambda (e: MouseEvent) { confirming = True; panel = ""; }}>Forget</button>
                    }}
                </div>

                if msg { <Note text={msg} tone={msgTone}/> }
                if err { <Note text={err} tone="bad"/> }

                if panel == "run" {
                    <section aria-labelledby="run-h" className={CARD + " p-4 flex flex-col gap-3"}>
                        <div className="flex items-center gap-2">
                            <h2 id="run-h" className="m-0 text-sm font-semibold">Run this skill</h2>
                            <button type="button" aria-label="Close" className={CLOSE_BTN}
                                onClick={lambda (e: MouseEvent) { panel = ""; }}><Icon name="x" size={14}/></button>
                        </div>
                        <label className="flex flex-col gap-1.5 text-xs text-muted">Task
                            <textarea rows={3} value={task} placeholder="What should it do? Name the files or inputs it needs."
                                onChange={lambda (e: ChangeEvent) { task = e.target.value; }} className={AREA}/>
                        </label>
                        <div className="flex flex-wrap items-center gap-3">
                            <button type="button" className={BTN_SM} disabled={acting or (not task.strip())}
                                onClick={lambda (e: MouseEvent) { runIt(); }}>{"Running…" if (busy == "run") else "Run"}</button>
                            <span className="text-xs text-muted">Sent straight to this skill, skipping the router. If the run fails, Sigil mutates the skill with the frontier model and retries once.</span>
                        </div>
                    </section>
                } elif panel == "eval" {
                    <section aria-labelledby="eval-h" className={CARD + " p-4 flex flex-col gap-3"}>
                        <div className="flex items-center gap-2">
                            <h2 id="eval-h" className="m-0 text-sm font-semibold">Eval</h2>
                            <button type="button" aria-label="Close" className={CLOSE_BTN}
                                onClick={lambda (e: MouseEvent) { panel = ""; }}><Icon name="x" size={14}/></button>
                        </div>
                        <label className="flex flex-col gap-1.5 text-xs text-muted">Probe task
                            <input value={probe} placeholder="Leave empty to probe with the skill's own intent"
                                onChange={lambda (e: ChangeEvent) { probe = e.target.value; }} className={INP}/>
                        </label>
                        <div className="flex flex-wrap items-center gap-3">
                            <button type="button" className={BTN_SM} disabled={acting}
                                onClick={lambda (e: MouseEvent) { evalIt(); }}>{"Grading…" if (busy == "eval") else "Eval"}</button>
                            <span className="text-xs text-muted">Runs the skill on the probe and grades whether the output really does it, from 0 to 100. The grade is saved as its last score.</span>
                        </div>
                    </section>
                } elif panel == "relearn" {
                    <section aria-labelledby="rel-h" className={CARD + " p-4 flex flex-col gap-3"}>
                        <div className="flex items-center gap-2">
                            <h2 id="rel-h" className="m-0 text-sm font-semibold">Relearn</h2>
                            <button type="button" aria-label="Close" className={CLOSE_BTN}
                                onClick={lambda (e: MouseEvent) { panel = ""; }}><Icon name="x" size={14}/></button>
                        </div>
                        <p className="m-0 text-[12.5px] leading-relaxed text-muted">
                            {("Recompiles " + sig + " from its SKILL.md through the full gated compile, as v" + str(ver + 1) + ". A hint is added to the source as relearn guidance, so the spec loop reads it like any other rule.")
                             if hasSrc else
                             ("Re-authors " + sig + " from its intent with the frontier model, as v" + str(ver + 1) + ". A hint is added to the intent as extra guidance.")}
                        </p>
                        <label className="flex flex-col gap-1.5 text-xs text-muted">Hint (optional)
                            <textarea rows={2} value={hint} placeholder="What should it do differently?"
                                onChange={lambda (e: ChangeEvent) { hint = e.target.value; }} className={AREA}/>
                        </label>
                        <div>
                            <button type="button" className={BTN_SM} disabled={acting}
                                onClick={lambda (e: MouseEvent) { relearnIt(); }}>{"Relearning…" if (busy == "relearn") else ("Relearn as v" + str(ver + 1))}</button>
                        </div>
                    </section>
                }

                if runRes {
                    <section aria-labelledby="rr-h" className={CARD + " p-4 flex flex-col gap-3"}>
                        <div className="flex flex-wrap items-center gap-2.5">
                            <h2 id="rr-h" className="m-0 text-sm font-semibold">Run result</h2>
                            <span className={chip("ok" if runOk else "bad")}>{"finished ok" if runOk else "failed"}</span>
                            {(<span className="font-mono text-xs text-muted">{str(runRes.signature)}</span>) if runRes.signature else None}
                            <button type="button" aria-label="Dismiss the run result" className={CLOSE_BTN}
                                onClick={lambda (e: MouseEvent) { runRes = None; }}><Icon name="x" size={14}/></button>
                        </div>
                        <pre className={PRE + " max-h-80"}>{str(runRes.result or "") or "No output."}</pre>
                        {(<details className="text-[12.5px]"><summary className="cursor-pointer text-muted">Trace</summary>
                            <pre className={PRE + " mt-2 max-h-72"}>{str(runRes.trace)}</pre></details>) if runRes.trace else None}
                    </section>
                }

                if evalRes {
                    <section aria-labelledby="er-h" className={CARD + " p-4 flex flex-col gap-2.5"}>
                        <div className="flex flex-wrap items-center gap-2.5">
                            <h2 id="er-h" className="m-0 text-sm font-semibold">Eval</h2>
                            <span className="font-mono text-[15px] font-semibold">{str(evalRes.score) + "/100"}</span>
                            <span className={chip("ok" if evalRes.passed else "bad")}>{"passed" if evalRes.passed else "did not pass"}</span>
                            <span className="text-xs text-muted">{"on v" + str(evalRes.version)}</span>
                            <button type="button" aria-label="Dismiss the eval result" className={CLOSE_BTN}
                                onClick={lambda (e: MouseEvent) { evalRes = None; }}><Icon name="x" size={14}/></button>
                        </div>
                        {(<p className="m-0 text-[13px] leading-relaxed text-fg-2">{str(evalRes.reason)}</p>) if evalRes.reason else None}
                        {(<details className="text-[12.5px]"><summary className="cursor-pointer text-muted">The output it graded</summary>
                            <pre className={PRE + " mt-2 max-h-72"}>{str(evalRes.result)}</pre></details>) if evalRes.result else None}
                    </section>
                }

                <div className="pt-1">
                    <Segmented label="Skill views" value={tab} onPick={pickTab}
                        options={[["overview", "Overview"], ["source", "Source ↔ AG-IR"], ["gates", "Gates"],
                                  ["runs", "Runs " + str(len(attempts))], ["versions", "Versions " + str(len(versions))]]}/>
                </div>

                if tab == "overview" {
                    <div className="grid gap-3 grid-cols-[repeat(auto-fit,minmax(170px,1fr))]">
                        <Stat label="Runs" value={str(runs)} sub={"on v" + str(d.version) + ", the current version"}/>
                        <Stat label="Finished ok" value={str(oks)} sub={(str(runs - oks) + " failed") if (runs > 0) else "never run"}/>
                        <Stat label="Ok rate" value={(str(round(pct)) + "%") if (pct >= 0) else "—"}
                            tone={"ok" if (_pctTone(pct) == "ok") else ("bad" if (_pctTone(pct) == "bad") else "")}
                            sub={"runs that finished ok" if (pct >= 0) else "no runs yet"}/>
                        <Stat label="Last grade" value={str(score) if (score >= 0) else "—"}
                            tone={"bad" if ((score >= 0) and (score < 60)) else ""}
                            sub={"out of 100, from the last eval" if (score >= 0) else "never graded"}/>
                    </div>
                    if d.last_eval {
                        <div className="flex flex-wrap gap-x-3 gap-y-1 text-[13px]">
                            <span className={LABEL + " pt-0.5"}>Last eval</span>
                            <span className="flex-1 min-w-[240px] text-fg-2 leading-relaxed">{str(d.last_eval)}</span>
                        </div>
                    }

                    <div className="flex flex-wrap gap-4 items-start">
                        <section aria-labelledby="ag-h" className={CARD + " flex-[999_1_520px] min-w-0 overflow-hidden flex flex-col"}>
                            <div className="flex flex-wrap items-center gap-2 px-4 py-3 border-b border-line">
                                <h2 id="ag-h" className="m-0 text-sm font-semibold">AG-IR</h2>
                                <span className="text-xs text-muted">{str(len(nodes)) + " nodes · " + str(len(edgesAll)) + " edges"}</span>
                                <span className="ml-auto text-xs text-faint">Click a node to inspect it</span>
                            </div>
                            {(<div className="px-4 pt-3"><Note text={str(ag.warning)}/></div>) if (ag and ag.warning) else None}
                            {if len(nodes) > 0 {
                                <div className="relative h-[460px]">
                                    <AgirCanvas nodes={ag.nodes} edges={ag.edges} dark={dark} onSelect={pickNode}/>
                                </div>
                            } elif agirErr {
                                <div className="p-4"><Note text={agirErr} tone="bad"/></div>
                            } elif not ag {
                                <div className="h-[220px] flex items-center justify-center"><Spinner label="Drawing the AG-IR…"/></div>
                            }}
                            <div className="flex flex-wrap gap-x-4 gap-y-1.5 px-4 py-2.5 border-t border-line text-xs text-muted">
                                {for lg in LEGEND {
                                    <span key={str(lg[0])} className="inline-flex items-center gap-1.5">
                                        <span className={str(lg[2])}></span>
                                        {str(lg[1]) + " " + str(_nGroup(nodes, str(lg[0])))}
                                    </span>
                                }}
                            </div>
                        </section>

                        <aside aria-label="Node inspector" className={CARD + " flex-[1_1_280px] min-w-0 p-4 flex flex-col gap-3 text-[12.5px]"}>
                            {if selNode {
                                <div className="flex items-center gap-2 min-w-0">
                                    <span className={_groupMark(str(selNode.group))}></span>
                                    <span className="font-mono text-[13px] font-semibold break-all">{str(selNode.id)}</span>
                                    <span className="ml-auto shrink-0 font-mono text-[11px] text-muted">{str(selNode.type)}</span>
                                </div>
                                <Field label="Kind">{_groupLabel(str(selNode.group)) + ((" · owner " + str(selNode.owner)) if selNode.owner else "")}</Field>
                                if selNode.tool { <Field label="Tool"><span className="font-mono">{str(selNode.tool)}</span></Field> }
                                if selNode.op { <Field label="Op"><span className="font-mono">{str(selNode.op)}</span></Field> }
                                if len(selNode.reads) > 0 { <Field label="Reads"><span className="font-mono">{", ".join([str(x) for x in selNode.reads])}</span></Field> }
                                if len(selNode.writes) > 0 { <Field label="Writes"><span className="font-mono">{", ".join([str(x) for x in selNode.writes])}</span></Field> }
                                if len(selNode.traces_to) > 0 { <Field label="Realizes"><span className="font-mono">{", ".join([str(x) for x in selNode.traces_to])}</span></Field> }
                                if len(into) > 0 { <Field label="Comes from"><span className="font-mono">{", ".join([str(e.src) for e in into])}</span></Field> }
                                if len(outof) > 0 { <Field label="Goes to"><span className="font-mono">{", ".join([str(e.dst) + ((" (" + str(e.label) + ")") if e.label else "") for e in outof])}</span></Field> }
                                if selNode.doc { <p className="m-0 leading-relaxed text-fg-2 whitespace-pre-wrap">{str(selNode.doc)}</p> }
                                <button type="button" className={BTN_GHOST_SM + " self-start"}
                                    onClick={lambda (e: MouseEvent) { sel = ""; }}>Clear</button>
                            } else {
                                <h2 className="m-0 text-sm font-semibold">Inspector</h2>
                                <p className="m-0 leading-relaxed text-muted">Click a node in the graph to see what it reads and writes, the tool it runs, and which rules of the skill it realizes.</p>
                                if len(tools) > 0 { <Field label="Tools it calls"><span className="font-mono">{", ".join([str(t) for t in tools])}</span></Field> }
                                if len(carries) > 0 { <Field label="Walker state"><span className="font-mono">{", ".join([(str(c.name) + ((": " + str(c.role)) if c.role else "")) for c in carries])}</span></Field> }
                            }}
                        </aside>
                    </div>
                } elif tab == "source" {
                    <div className="flex flex-wrap gap-4 items-start">
                        <section aria-labelledby="src-h" className={CARD + " flex-[1_1_420px] min-w-0 overflow-hidden"}>
                            <div className="flex items-center gap-2 px-4 py-3 border-b border-line">
                                <h2 id="src-h" className="m-0 text-sm font-semibold">SKILL.md</h2>
                                <span className="text-xs text-muted">what it was compiled from</span>
                                {(<button type="button" className={BTN_GHOST_SM + " ml-auto"}
                                    onClick={lambda (e: MouseEvent) { copy("src", str(d.skill_src)); }}>
                                    <Icon name="copy" size={13}/>{"Copied" if (copied == "src") else "Copy"}
                                </button>) if hasSrc else None}
                            </div>
                            {if hasSrc {
                                <pre className="m-0 p-4 max-h-[70vh] overflow-auto text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-fg-2">{str(d.skill_src)}</pre>
                            } else {
                                <p className="m-0 p-4 text-[13px] leading-relaxed text-muted">This skill was learned from a task, so it has no SKILL.md. Its AG-IR was authored from the task's intent.</p>
                            }}
                        </section>
                        <section aria-labelledby="ir-h" className={CARD + " flex-[1_1_420px] min-w-0 overflow-hidden"}>
                            <div className="flex items-center gap-2 px-4 py-3 border-b border-line">
                                <h2 id="ir-h" className="m-0 text-sm font-semibold">AG-IR</h2>
                                <span className="text-xs text-muted">{"v" + str(d.version) + " · the typed contract it lowers to Jac"}</span>
                                {(<button type="button" className={BTN_GHOST_SM + " ml-auto"}
                                    onClick={lambda (e: MouseEvent) { copy("ir", str(d.agir)); }}>
                                    <Icon name="copy" size={13}/>{"Copied" if (copied == "ir") else "Copy"}
                                </button>) if hasIr else None}
                            </div>
                            {if hasIr {
                                <pre className="m-0 p-4 max-h-[70vh] overflow-auto text-xs leading-relaxed font-mono whitespace-pre text-fg-2">{str(d.agir)}</pre>
                            } else {
                                <p className="m-0 p-4 text-[13px] leading-relaxed text-muted">No AG-IR is stored with this version.</p>
                            }}
                        </section>
                    </div>
                } elif tab == "gates" {
                    <section aria-labelledby="g-h" className={CARD + " overflow-hidden"}>
                        <div className="flex flex-wrap items-center gap-2.5 px-4 py-3 border-b border-line">
                            <h2 id="g-h" className="m-0 text-sm font-semibold">Gates</h2>
                            {(<span className="text-xs text-muted">{gSummary}</span>) if gv else None}
                            <button type="button" className={BTN2_SM + " ml-auto"} disabled={gatesBusy}
                                onClick={lambda (e: MouseEvent) { loadGates(sig); }}>
                                <Icon name="refresh" size={13}/>{"Running…" if gatesBusy else "Run again"}
                            </button>
                        </div>
                        <p className="m-0 px-4 py-3 text-[12.5px] leading-relaxed text-muted border-b border-line">
                            {"The mechanical gates, run against the AG-IR stored with v" + str(gv.version if gv else d.version) + ". Faithfulness and the gates that need the extracted spec run only inside a compile, so they are not here."}
                        </p>
                        {(<div className="p-4"><Note text={gatesErr} tone="bad"/></div>) if gatesErr else None}
                        {if (not gv) and (not gatesErr) {
                            <div className="px-4 py-5"><Spinner label="Running the gates. Lowering and type-checking takes a little longer than a read."/></div>
                        }}
                        {for gt in grows {
                            <div key={str(gt.id)} className="flex flex-col gap-1.5 px-4 py-3 border-b border-line">
                                <div className="flex flex-wrap items-center gap-2.5">
                                    <span className={tagCls(_gateTone(gt))}>{str(gt.id)}</span>
                                    <span className="text-[13px] font-medium">{str(gt.name)}</span>
                                    <span className="text-xs text-faint">{str(gt.severity)}</span>
                                    <span className={chip(_gateTone(gt)) + " ml-auto"}>{_gateWord(gt)}</span>
                                </div>
                                {if len(gt.issues) > 0 {
                                    <ul className="m-0 pl-5 flex flex-col gap-1 text-xs font-mono text-fg-2">
                                        {for (ii, iss) in enumerate(gt.issues) {
                                            <li key={str(ii)} className="break-words whitespace-pre-wrap">{str(iss)}</li>
                                        }}
                                    </ul>
                                }}
                            </div>
                        }}
                        {(<div className="px-4 py-2.5 text-xs text-muted">{"It lowers to " + str(gv.lines) + " lines of Jac."}</div>) if (gv and gv.lines) else None}
                    </section>
                } elif tab == "runs" {
                    if len(attempts) == 0 {
                        <Empty title="No runs yet" body="Run it with the button above, or give Sigil a task this skill matches."/>
                    } else {
                        <div className={CARD + " overflow-x-auto"}>
                            <table className="w-full min-w-[760px] border-collapse text-[13px]">
                                <thead>
                                    <tr className="text-left text-xs text-muted">
                                        <th scope="col" className="px-4 py-3 font-medium">Result</th>
                                        <th scope="col" className="px-2.5 py-3 font-medium">Task</th>
                                        <th scope="col" className="px-2.5 py-3 font-medium">Version</th>
                                        <th scope="col" className="px-2.5 py-3 font-medium">Model</th>
                                        <th scope="col" className="px-2.5 py-3 pr-4 font-medium">When</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {for (i, at) in enumerate(attempts) {
                                        <tr key={"a" + str(i)} className="border-t border-line align-top">
                                            <td className="px-4 py-3 whitespace-nowrap">
                                                <span className="inline-flex items-center gap-2">
                                                    <span className={dotCls("ok" if at.ok else "bad")}></span>
                                                    {"ok" if at.ok else "failed"}
                                                </span>
                                            </td>
                                            <td className="px-2.5 py-3 max-w-[520px]">
                                                <div className="text-fg break-words">{str(at.task)}</div>
                                                {(<div className="mt-0.5 text-xs text-muted break-words line-clamp-2">{str(at.summary)}</div>) if at.summary else None}
                                            </td>
                                            <td className="px-2.5 py-3 font-mono">{"v" + str(at.version)}</td>
                                            <td className="px-2.5 py-3 font-mono text-xs text-fg-2">{str(at.model or "")}</td>
                                            <td className="px-2.5 py-3 pr-4 font-mono text-xs text-muted whitespace-nowrap">{fmtAgo(at.at_ms) if at.at_ms else "—"}</td>
                                        </tr>
                                    }}
                                </tbody>
                            </table>
                            {(<div className="px-4 py-2.5 border-t border-line text-xs text-muted">The 40 most recent runs, across every version.</div>) if (len(attempts) >= 40) else None}
                        </div>
                    }
                } elif tab == "versions" {
                    <div className={CARD + " overflow-x-auto"}>
                        <table className="w-full min-w-[560px] border-collapse text-[13px]">
                            <thead>
                                <tr className="text-left text-xs text-muted">
                                    <th scope="col" className="px-4 py-3 font-medium">Version</th>
                                    <th scope="col" className="px-2.5 py-3 font-medium">Origin</th>
                                    <th scope="col" className="px-2.5 py-3 font-medium">Runs ok</th>
                                    <th scope="col" className="px-2.5 py-3 pr-4 font-medium">Last grade</th>
                                </tr>
                            </thead>
                            <tbody>
                                {for (i, vr) in enumerate(versions) {
                                    <tr key={"v" + str(vr.version)} className="border-t border-line">
                                        <td className="px-4 py-3">
                                            <span className="inline-flex items-center gap-2">
                                                <span className="font-mono">{"v" + str(vr.version)}</span>
                                                {(<span className={chip("acc")}>current</span>) if (i == 0) else None}
                                            </span>
                                        </td>
                                        <td className="px-2.5 py-3 text-fg-2">{_originLabel(str(vr.origin))}</td>
                                        <td className="px-2.5 py-3">
                                            {if int(vr.runs or 0) == 0 {
                                                <span className="text-faint">never run</span>
                                            } else {
                                                <span className="flex items-center gap-2">
                                                    <span className="font-mono">{str(vr.successes) + "/" + str(vr.runs)}</span>
                                                    <span className="w-14"><Bar pct={_okPct(int(vr.runs), int(vr.successes or 0))}
                                                        tone={_pctTone(_okPct(int(vr.runs), int(vr.successes or 0)))}/></span>
                                                </span>
                                            }}
                                        </td>
                                        <td className="px-2.5 py-3 pr-4 font-mono">
                                            {(<span className={"text-bad" if (int(vr.last_score) < 60) else ""}>{str(vr.last_score)}</span>) if ((vr.last_score is not None) and (int(vr.last_score) >= 0)) else (<span className="text-faint">—</span>)}
                                        </td>
                                    </tr>
                                }}
                            </tbody>
                        </table>
                        <div className="px-4 py-2.5 border-t border-line text-xs text-muted">Every version keeps the signature and Sigil runs the newest. A relearn or a mutation adds a version and keeps the older ones as its lineage.</div>
                    </div>
                }
            }}
        </div>
    </div>;
}

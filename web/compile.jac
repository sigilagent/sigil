"""Compile: SKILL.md in, a typed agent out, watched as it happens.

Upload a skill folder (or name one on this machine), choose what Sigil does when
the skill leaves a rule's force unstated, press Compile. The compile runs as a
job (src/sigil_console.jac): this page polls it every two seconds and draws each
stage as it finishes, the question it is waiting on, and the result.

#/compile is a new compile; #/compile/<job> is that job, so a report can be
linked to and survives a reload.
"""

import from src.sigil_console { api_console }
import from .ui {
    PageHead, Icon, Note, Spinner, Empty, CARD, BTN, BTN2, BTN_SM, BTN2_SM, BTN_GHOST_SM, BTN_BAD_SM,
    INP, LABEL, LINK, chip, dotCls, tagCls
}
import from "./console_interop.js" { readFiles, storeGet, storeSet, fmtAgo, secs, navTo, nowMs }
import from react { useEffect }

glob MODES: list[any] = [
    ["ask", "Ask me", "The compile pauses on each one until you answer Do, Maybe or Don't"],
    ["decide", "Let Sigil decide", "A second model answers each from the skill's own text, citing the line it relied on"],
    ["optional", "Treat as optional", "Each unclear rule becomes a Maybe; no model is involved"]
];

# raise2's stages, in the order they run.
glob STAGES: list[any] = [
    ["spec", "Spec loop", "Read the skill into rules"],
    ["clarify", "Unclear rules", "Settle what the skill leaves open"],
    ["author", "Author", "Write the AG-IR"],
    ["faith", "Faithfulness", "Every rule realized by a node, gate or constraint"],
    ["repair", "Repair", "Close the gaps it found"],
    ["gates", "Gates", "Lower it, type-check it, run the gate battery"]
];

glob ANSWERS: list[any] = [
    ["do", "Do", "always"],
    ["maybe", "Maybe", "when the task calls for it"],
    ["dont", "Don't", "never"]
];

def _isEntry(p: str) -> bool {
    return str(p).lower().endswith("skill.md");
}

def _statusTone(s: str) -> str {
    if s in ["faithful", "clean", "fixed"] { return "ok"; }
    if s in ["degraded"] { return "warn"; }
    if s in ["unfaithful", "uncompilable", "failed"] { return "bad"; }
    return "";
}

def _stageRows(events: list[any], state: str, mode: str, done: bool) -> list[any] {
    # One row per stage: [key, name, about, status, line, took] where status is
    # wait | run | done | skip.
    started: dict[str, any] = {};
    finished: dict[str, any] = {};
    extra: list[str] = [];
    known = [str(s[0]) for s in STAGES];
    asked = 0;
    answered = 0;
    for ev in events {
        st = str(ev.stage or "");
        if st == "clarify" {
            if str(ev.state) == "asked" { asked += 1; }
            if str(ev.state) == "answered" { answered += 1; }
            continue;
        }
        if (not st) or (st in ["job", "spec_detail"]) { continue; }
        if (st not in known) and (st not in extra) { extra.append(st); }
        if str(ev.state) == "start" { started = {**started, (st): ev}; }
        if str(ev.state) == "done" { finished = {**finished, (st): ev}; }
    }
    rows: list[any] = [];
    for s in STAGES {
        k = str(s[0]);
        status = "wait";
        line = "";
        took = "";
        if k == "clarify" {
            after = ("author" in started) or done;
            if asked > answered { status = "run"; line = "waiting for your answer"; }
            elif after { status = "done"; }
            elif "spec" in finished { status = "run"; }
            if status == "done" {
                if mode == "ask" {
                    line = (str(answered) + " answered by you") if answered else "nothing was unclear";
                } elif mode == "decide" { line = "decided by Sigil, each answer citing the skill"; }
                else { line = "unclear rules kept as Maybe"; }
            }
        } else {
            if k in finished {
                status = "done";
                fe: any = finished[k];
                line = str(fe.line or "");
                took = str(fe.took or "");
            } elif k in started { status = "run"; }
            elif done { status = "skip"; }
        }
        rows.append([k, str(s[1]), str(s[2]), status, line, took]);
    }
    for k in extra {
        status = "done" if (k in finished) else ("run" if (k in started) else "wait");
        fe2: any = finished[k] if (k in finished) else None;
        rows.append([k, str(started[k].label if (k in started) else k), "", status,
                     str(fe2.line) if fe2 else "", str(fe2.took) if fe2 else ""]);
    }
    return rows;
}

def:pub CompilePage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None],
                    refresh: Callable[[], None]) -> JsxElement {
    has files: list[any] = [];
    has path: str = "";
    has mode: str = "ask";
    has st: any = None;
    has jobs: list[any] = [];
    has starting: bool = False;
    has answering: bool = False;
    has err: str = "";
    has tick: int = 0;

    job = str(route[1]) if (len(route) > 1) else "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def loadJobs() {
        m: any = await call("compile_jobs", {});
        if m and (not m.error) { jobs = list(m); }
    }

    async def poll() {
        if not job { st = None; return; }
        m: any = await call("compile_status", {"job": job});
        if m and m.ok {
            was = str(st.state) if st else "";
            st = m;
            if (str(m.state) in ["done", "stopped"]) and (was != str(m.state)) {
                loadJobs();
                refresh();
            }
        } elif m { err = str(m.error); }
        tick = tick + 1;
    }

    can with entry {
        mode = str(storeGet("sigil.compileMode", "ask"));
        loadJobs();
    }

    live = bool(st) and (str(st.state) in ["running", "waiting"]);

    # The bare `return;` matters: a one-statement lambda compiles to an arrow that
    # returns poll()'s Promise, and React would call it as the cleanup.
    useEffect(lambda {
        poll();
        return;
    }, [job]);

    useEffect(lambda {
        if not live { return; }
        iv = setInterval(lambda { poll(); }, 2000);
        return lambda { clearInterval(iv); };
    }, [job, live]);

    async def pick(fl: any) {
        got: list[any] = await readFiles(fl);
        files = got;
        err = "" if [f for f in got if _isEntry(f.path)] else "No SKILL.md in what you picked. Pick the skill's folder, or include its SKILL.md.";
    }

    def setMode(m: str) { mode = m; storeSet("sigil.compileMode", m); }

    async def start() {
        if starting { return; }
        if (not files) and (not path.strip()) { err = "Pick a skill folder or name one first."; return; }
        starting = True;
        err = "";
        m: any = await call("compile_start", {"files": files, "mode": mode, "path": path.strip()});
        starting = False;
        if m and m.ok {
            files = [];
            path = "";
            st = None;
            navTo("/compile/" + str(m.job));
            loadJobs();
        } else { err = str(m.error) if m else "the compile did not start"; }
    }

    async def answer(i: int, a: str) {
        answering = True;
        m: any = await call("compile_answer", {"job": job, "i": i, "answer": a});
        answering = False;
        if m and m.error { err = str(m.error); }
        poll();
    }

    def newCompile(e: MouseEvent) { st = None; navTo("/compile"); }

    entryFile = [f for f in files if _isEntry(f.path)];
    meta: any = st.meta if st else None;
    result: any = st.result if st else None;
    state = str(st.state) if st else "";
    events: list[any] = list(st.events) if (st and st.events) else [];
    jmode = str(meta.mode) if meta else mode;
    rows = _stageRows(events, state, jmode, state in ["done", "stopped"]);
    elapsed = 0;
    if meta {
        endms = int(result.finished_ms) if (result and result.finished_ms) else int(st.now_ms);
        elapsed = endms - int(meta.created_ms);
    }
    status = str(result.status) if result else "";
    warnings: list[any] = list(result.warnings) if (result and result.warnings) else [];
    findings: list[any] = list(result.findings) if (result and result.findings) else [];
    issues: list[any] = list(result.issues) if (result and result.issues) else [];
    q: any = st.ask if st else None;

    return <div className="flex flex-col">
        <PageHead title="Compile" kicker="Skills · SKILL.md in, a typed agent out" onAsk={ask}
            askHint="Ask about compiling" tag={(str(meta.name) if meta else "compile")}>
            {(<button type="button" className={BTN2} onClick={newCompile}><Icon name="plus" size={15}/>New compile</button>) if job else None}
        </PageHead>

        <div className="px-7 pt-6 pb-10 flex flex-wrap gap-5 items-start">
            <div className="flex-[1_1_320px] min-w-0 flex flex-col gap-4">
                <section aria-labelledby="up" className={CARD + " p-4 flex flex-col gap-3"}>
                    <h2 id="up" className="m-0 text-sm font-semibold">Upload a skill</h2>
                    <div className="flex flex-col items-center gap-2.5 p-5 rounded-[10px] border border-dashed border-line-2 bg-ink-1 text-center"
                        onDragOver={lambda (e: any) { e.preventDefault(); }}
                        onDrop={lambda (e: any) { e.preventDefault(); pick(e.dataTransfer.files); }}>
                        <Icon name="upload" size={20} cls="text-faint"/>
                        <span className="text-[13px] text-fg-2">Drop a SKILL.md and its files here</span>
                        <div className="flex flex-wrap justify-center gap-2">
                            <label htmlFor="pick-folder" className={BTN2_SM}>Choose folder</label>
                            <label htmlFor="pick-files" className={BTN_GHOST_SM}>Choose files</label>
                        </div>
                        <input id="pick-folder" type="file" webkitdirectory="" multiple={True} className="hidden"
                            onChange={lambda (e: ChangeEvent) { pick(e.target.files); }}/>
                        <input id="pick-files" type="file" multiple={True} className="hidden"
                            onChange={lambda (e: ChangeEvent) { pick(e.target.files); }}/>
                    </div>
                    {(<div className="flex flex-col gap-1.5 text-[12.5px]">
                        {for f in (entryFile[:1] + [x for x in files if not _isEntry(x.path)][:6]) {
                            <div key={str(f.path)} className="flex items-center gap-2 px-2.5 py-2 rounded-lg bg-ink-1 border border-line">
                                <span className="font-mono truncate">{f.path}</span>
                                <span className="ml-auto text-muted shrink-0">{"entry" if _isEntry(f.path) else "sibling"}</span>
                            </div>
                        }}
                        {(<span className="text-xs text-muted">{"and " + str(len(files) - 7) + " more files"}</span>) if (len(files) > 7) else None}
                        <button type="button" className={BTN_GHOST_SM + " self-start"} onClick={lambda (e: MouseEvent) { files = []; err = ""; }}>Clear</button>
                    </div>) if files else None}
                    <label className="flex flex-col gap-1.5 text-xs text-muted">or a folder on this machine
                        <input value={path} placeholder="~/skills/clean-csv" onChange={lambda (e: ChangeEvent) { path = e.target.value; }}
                            className={INP + " font-mono"}/>
                    </label>
                </section>

                <section aria-labelledby="modeh" className={CARD + " p-4 flex flex-col gap-3"}>
                    <h2 id="modeh" className="m-0 text-sm font-semibold">When a rule is unclear</h2>
                    <div role="radiogroup" aria-labelledby="modeh" className="flex flex-col gap-1.5">
                        {for m in MODES {
                            <button key={str(m[0])} type="button" role="radio" aria-checked={"true" if (mode == m[0]) else "false"}
                                onClick={lambda (e: MouseEvent) { setMode(str(m[0])); }}
                                className={"flex flex-col items-start gap-0.5 px-3 py-2.5 rounded-[9px] text-left cursor-pointer border " + ("bg-violet-500/10 border-violet-400 text-fg" if (mode == m[0]) else "bg-ink-1 border-line-2 text-fg hover:border-faint")}>
                                <span className="text-[13px] font-medium">{m[1]}</span>
                                <span className="text-xs text-muted">{m[2]}</span>
                            </button>
                        }}
                    </div>
                    <button type="button" className={BTN + " w-full h-[38px]"} disabled={starting or live or ((not files) and (not path.strip()))}
                        onClick={lambda (e: MouseEvent) { start(); }}>
                        {"Starting…" if starting else ("A compile is running" if live else "Compile")}
                    </button>
                    {(<Note text={err} tone="bad"/>) if err else None}
                </section>

                <section aria-labelledby="past" className={CARD + " overflow-hidden"}>
                    <div className="px-4 py-3 border-b border-line"><h2 id="past" className="m-0 text-sm font-semibold">Recent compiles</h2></div>
                    {(<div className="px-4 py-4 text-[12.5px] text-muted">None yet.</div>) if (not jobs) else None}
                    {for jb in jobs {
                        <a key={str(jb.job)} href={"#/compile/" + str(jb.job)}
                            className={"flex items-center gap-2.5 px-4 py-2.5 border-b border-line no-underline text-fg hover:bg-ink-3" + (" bg-violet-500/10" if (str(jb.job) == job) else "")}>
                            <span className={dotCls(_statusTone(str(jb.status)) if jb.status else ("live" if (str(jb.state) in ["running", "waiting"]) else ""))}></span>
                            <span className="flex-1 min-w-0 flex flex-col">
                                <span className="font-mono text-[12.5px] truncate">{str(jb.signature or jb.name)}</span>
                                <span className="text-[11.5px] text-muted">{(str(jb.status) if jb.status else str(jb.state)) + " · " + fmtAgo(jb.created_ms)}</span>
                            </span>
                        </a>
                    }}
                </section>
            </div>

            <div className="flex-[999_1_520px] min-w-0 flex flex-col gap-4">
                {if not job {
                    <Empty title="Nothing compiling"
                        body="Pick a skill on the left and press Compile. Each stage shows up here as it finishes: the spec loop reads the SKILL.md into rules, authoring writes the AG-IR, the faithfulness check matches every rule to a node, and the gates lower and type-check the result."/>
                } elif not st {
                    <Spinner label="Loading the compile…"/>
                } else {
                    <section aria-labelledby="runh" className={CARD + " overflow-hidden"}>
                        <div className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4.5 py-3.5 border-b border-line">
                            <h2 id="runh" className="m-0 font-mono text-base font-semibold">{str(result.signature) if (result and result.signature) else str(meta.name)}</h2>
                            {if state == "waiting" { <span className={chip("warn")}>waiting for you</span> }
                             elif state == "running" { <span className={chip("live")}>compiling</span> }
                             elif status { <span className={chip(_statusTone(status))}>{status}</span> }
                             elif state == "stopped" { <span className={chip("bad")}>stopped</span> }}
                            <span className="ml-auto text-[12.5px] text-muted">{secs(elapsed) + " · " + MODES_LABEL(jmode)}</span>
                        </div>
                        <ol className="list-none m-0 py-2 px-0">
                            {for r in rows {
                                <li key={str(r[0])} className={"flex gap-3 px-4.5 py-2.5" + (" bg-[#f5c451]/5" if ((r[3] == "run") and (r[0] == "clarify") and (state == "waiting")) else "")}>
                                    <span className={"w-5 text-center shrink-0 " + ("text-ok" if (r[3] == "done") else ("text-live" if (r[3] == "run") else "text-faint"))} aria-hidden="true">
                                        {"✓" if (r[3] == "done") else ("◐" if (r[3] == "run") else ("–" if (r[3] == "skip") else "○"))}
                                    </span>
                                    <span className="flex-1 min-w-0">
                                        <span className={"font-medium " + ("text-fg" if (r[3] in ["done", "run"]) else "text-muted")}>{r[1]}</span>
                                        <span className="block text-[12.5px] text-muted">{r[4] if r[4] else r[2]}</span>
                                    </span>
                                    <span className="font-mono text-xs text-muted shrink-0">{r[5]}</span>
                                </li>
                            }}
                        </ol>
                    </section>

                    if q {
                        <section aria-labelledby="qh" className="rounded-xl border border-[#f5c451]/40 bg-[#f5c451]/5 p-4.5 flex flex-col gap-3">
                            <h2 id="qh" className="m-0 text-[15px] font-semibold">The skill leaves this open</h2>
                            <p className="m-0 text-[13.5px] leading-relaxed text-fg whitespace-pre-wrap">{str(q.question)}</p>
                            <div className="flex flex-wrap gap-2">
                                {for a in ANSWERS {
                                    <button key={str(a[0])} type="button" disabled={answering} className={BTN2_SM}
                                        onClick={lambda (e: MouseEvent) { answer(int(q.i), str(a[0])); }}>
                                        <span className="font-semibold">{a[1]}</span><span className="text-muted">{a[2]}</span>
                                    </button>
                                }}
                            </div>
                            <span className="text-xs text-muted">The compile waits up to 30 minutes for an answer, then leaves the rule as written.</span>
                        </section>
                    }

                    if (state == "stopped") and (not result) {
                        <section className={CARD + " p-4 flex flex-col gap-2"}>
                            <Note text="The compile process ended without a result. Its log is below." tone="bad"/>
                            <pre className="m-0 max-h-72 overflow-auto text-xs font-mono whitespace-pre-wrap text-muted">{str(st.log)}</pre>
                        </section>
                    }

                    if result {
                        <section aria-labelledby="resh" className={CARD + " p-4.5 flex flex-col gap-3"}>
                            <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                                <h2 id="resh" className="m-0 text-[15px] font-semibold">Result</h2>
                                {(<span className={chip(_statusTone(status))}>{status}</span>) if status else None}
                                {(<span className="text-[12.5px] text-muted">{"saved as v" + str(result.version)}</span>) if result.version else None}
                                {(<a href={"#/skills/" + str(result.signature)} className={BTN_SM + " ml-auto no-underline"}>Open the skill</a>) if (result.signature and result.ok) else None}
                            </div>
                            {(<Note text={str(result.error)} tone="bad"/>) if result.error else None}
                            {(<p className="m-0 text-[13px] leading-relaxed text-fg-2 whitespace-pre-wrap">{str(result.explain)}</p>) if result.explain else None}
                            {if findings {
                                <div className="flex flex-col gap-1.5">
                                    <span className={LABEL}>Gate findings</span>
                                    {for (fi, f) in enumerate(findings[:20]) {
                                        <div key={"f" + str(fi)} className="flex gap-2.5 text-[12.5px]">
                                            <span className={tagCls("bad" if (str(f.severity) in ["fatal", "error"]) else "warn")}>{str(f.gate)}</span>
                                            <span className="text-fg-2 min-w-0 break-words">{str(f.message)}</span>
                                        </div>
                                    }}
                                </div>
                            }}
                            {if issues and (not findings) {
                                <div className="flex flex-col gap-1.5">
                                    <span className={LABEL}>Issues</span>
                                    {for (ii, it) in enumerate(issues[:20]) {
                                        <div key={"i" + str(ii)} className="text-[12.5px] text-fg-2 break-words">{str(it)}</div>
                                    }}
                                </div>
                            }}
                            {if warnings {
                                <div className="flex flex-col gap-1.5">
                                    <span className={LABEL}>Notes from the compile</span>
                                    {for (wi, w) in enumerate(warnings[:20]) {
                                        <div key={"w" + str(wi)} className="text-[12.5px] text-muted break-words">{str(w)}</div>
                                    }}
                                </div>
                            }}
                            {(<details className="text-[12.5px]"><summary className="cursor-pointer text-muted">Compile errors</summary>
                                <pre className="mt-2 max-h-72 overflow-auto text-xs font-mono whitespace-pre-wrap text-bad">{str(result.compile_errors)}</pre></details>) if result.compile_errors else None}
                            {(<details className="text-[12.5px]"><summary className="cursor-pointer text-muted">AG-IR</summary>
                                <pre className="mt-2 max-h-96 overflow-auto text-xs font-mono whitespace-pre text-fg-2">{str(result.agir)}</pre></details>) if result.agir else None}
                        </section>
                    }
                }}
            </div>
        </div>
    </div>;
}

def MODES_LABEL(m: str) -> str {
    for x in MODES { if x[0] == m { return str(x[1]); } }
    return m;
}

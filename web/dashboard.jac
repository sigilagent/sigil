"""Dashboard: what needs you, what ran, what it cost, and every page but the Studio.

Everything here comes from the shell's overview (one request), plus the recent
compile jobs. "Needs you" is built in the browser from what the overview holds:
a pending approval, a skill that keeps failing or graded below the threshold, a
schedule whose last run failed, a schedule that cannot fire because the daemon
is down, a compile that came out unfaithful. Each item carries the button that
fixes it.

Below it, one tile per page that used to sit in the sidebar (runs, usage, memory,
schedules, approvals, connections, settings, docs), each with the one line of the
overview that says whether it needs a look. Building and opening agents is the
Studio's job (web/studio.jac), so it has no tile here.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_relearn }
import from .ui {
    PageHead, Stat, Icon, Note, Spinner, CARD, BTN, BTN_SM, BTN2_SM, BTN_BAD_SM,
    BTN_GHOST_SM, chip, tagCls, dotCls, LINK, LABEL
}
import from "./console_interop.js" { fmtAgo, money, compact }
import from react { useEffect }

def _okPct(s: any) -> float {
    r = int(s.runs) if s.runs else 0;
    if r == 0 { return -1.0; }
    return (float(s.successes) * 100.0) / float(r);
}

def _routeTag(summary: str) -> str {
    s = str(summary or "");
    if "MUTATE" in s { return "MUTATE"; }
    if "MISS" in s { return "MISS"; }
    if "HIT" in s { return "HIT"; }
    return "";
}

def:pub DashboardPage(ov: any, go: Callable[[str], None], ask: Callable[[str], None],
                 refresh: Callable[[], None]) -> JsxElement {
    has jobs: list[any] = [];
    has busy: str = "";
    has msg: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def loadJobs() {
        m: any = await call("compile_jobs", {});
        if m and (not m.error) { jobs = list(m); }
    }

    can with entry { loadJobs(); }

    async def decide(cmd: str, decision: str) {
        busy = cmd;
        m: any = await call("approve", {"cmd": cmd, "decision": decision, "pattern": ""});
        busy = "";
        msg = ("⚠ " + str(m.error)) if (m and m.error) else "";
        refresh();
    }

    async def relearn(sig: str) {
        busy = sig;
        msg = "Relearning " + sig + ". The frontier model recompiles it from its source.";
        r = root spawn api_relearn(signature=sig, hint="");
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        msg = ("⚠ " + str(m.error)) if (m and m.error) else ("Relearned " + sig + (" → v" + str(m.version) if m else ""));
        refresh();
    }

    soul: any = ov.soul if ov else None;
    skills: list[any] = list(ov.skills) if (ov and ov.skills) else [];
    pending: list[any] = list(ov.pending) if (ov and ov.pending) else [];
    cron: list[any] = list(ov.cron) if (ov and ov.cron) else [];
    tasks: list[any] = list(ov.tasks) if (ov and ov.tasks) else [];
    today: any = ov.today if ov else None;
    threshold = int(soul.eval_threshold) if (soul and soul.eval_threshold) else 60;

    failing: list[any] = [];
    for s in skills {
        p = _okPct(s);
        graded_low = (int(s.last_score) >= 0) and (int(s.last_score) < threshold) if (s.last_score is not None) else False;
        if ((p >= 0) and (p < 50) and (int(s.runs) >= 3)) or graded_low { failing.append(s); }
    }
    broken_cron = [j for j in cron if j.last_status and (str(j.last_status) != "ok")];
    armed = [j for j in cron if j.enabled];
    daemon_down = bool(ov) and (not ov.daemon) and (len(armed) > 0);
    bad_jobs = [j for j in jobs if str(j.status) in ["unfaithful", "uncompilable", "failed"]][:3];
    needs = len(pending) + len(failing) + len(broken_cron) + len(bad_jobs) + (1 if daemon_down else 0);

    next_job: any = None;
    for j in armed {
        if int(j.next_run_ms) > 0 {
            if (next_job is None) or (int(j.next_run_ms) < int(next_job.next_run_ms)) { next_job = j; }
        }
    }
    ok_runs = len([t for t in tasks if t.ok]);
    chans: list[any] = list(ov.channels) if (ov and ov.channels) else [];
    connected: any = ov.connected if ov else None;
    nmem = int(soul.memories) if (soul and soul.memories) else 0;
    # [label, path, icon, one line, needs a look]
    tiles: list[any] = [
        ["Runs", "/runs", "runs", ((str(ok_runs) + " of the last " + str(len(tasks)) + " finished ok") if tasks else "Nothing has run yet"), bool(tasks) and (ok_runs < len(tasks))],
        ["Usage", "/usage", "usage", ((money(today.cost) + " today · " + compact(today.tokens) + " tokens") if today else "Tokens and spend by model"), False],
        ["Memory", "/memory", "memory", (str(nmem) + (" thing remembered" if (nmem == 1) else " things remembered")), False],
        ["Automations", "/automations", "clock", ((str(len(armed)) + " of " + str(len(cron)) + " schedules armed" + ((" · next " + str(next_job.name) + " " + fmtAgo(next_job.next_run_ms)) if next_job else "")) if cron else "No schedules yet"), (len(broken_cron) > 0) or daemon_down],
        ["Approvals", "/approvals", "shield", ((str(len(pending)) + " waiting on you") if pending else "Nothing waiting · the allowlist"), len(pending) > 0],
        ["Model providers", "/settings/connections", "key", (("chat " + str(soul.chat_model)) if soul else "ChatGPT, Claude Code, OpenRouter, Ollama or a key"), bool(connected) and (not connected.ok)],
        ["Channels", "/channels", "channels", ((str(len(chans)) + (" channel connected" if (len(chans) == 1) else " channels connected")) if chans else "Where Sigil can be messaged"), False],
        ["MCP & tools", "/tools", "plug", "MCP servers, and which skills MCP clients may call", False],
        ["Compiles", "/compile", "compile", ((str(len(jobs)) + " recent compiles" + ((" · " + str(len(bad_jobs)) + " unfaithful") if bad_jobs else "")) if jobs else "Compile reports, newest first"), len(bad_jobs) > 0],
        ["All skills", "/skills", "library", (str(len(skills)) + (" compiled skill" if (len(skills) == 1) else " compiled skills") + " · the full library"), len(failing) > 0],
        ["Settings", "/settings", "settings", "Model providers, models, keys, agent, behaviour, workspace, system", False],
        ["Docs", "/docs", "docs", "How Sigil works: AG-IR, the gates, the CLI", False]
    ];

    return <div className="flex flex-col">
        <PageHead title="Dashboard"
            kicker={("frontier " + str(soul.frontier_model) + " · small " + str(soul.small_model)) if soul else "connecting to Sigil…"}
            onAsk={ask} askHint="Ask Sigil about anything here" tag="dashboard">
            <a href="#/" className={BTN + " no-underline"}><Icon name="chat" size={15}/>Open the Studio</a>
        </PageHead>

        <div className="px-7 pt-6 pb-10 flex flex-col gap-5">
            {(<Spinner label="Reading the agent's graph…"/>) if (not ov) else None}

            <div className="grid gap-3.5 grid-cols-[repeat(auto-fit,minmax(200px,1fr))]">
                <Stat label="Compiled skills" value={str(len(skills))}
                    sub={(str(len(failing)) + " need attention") if failing else "all healthy"}/>
                <Stat label="Spend today" value={money(today.cost) if today else "—"} tone="gold"
                    sub={(compact(today.tokens) + " tokens · " + str(today.calls) + " calls") if today else ""}/>
                <Stat label="Recent runs" value={(str(ok_runs) + "/" + str(len(tasks))) if tasks else "0"}
                    sub={"ok in the last " + str(len(tasks))  if tasks else "nothing has run yet"}/>
                <Stat label="Next scheduled" value={str(next_job.name) if next_job else "—"}
                    sub={fmtAgo(next_job.next_run_ms) if next_job else "no schedules armed"}/>
            </div>

            {(<Note text={msg} tone={"bad" if msg.startswith("⚠") else "live"}/>) if msg else None}

            <div className="flex flex-wrap gap-5 items-start">
                <section aria-labelledby="needs" className={CARD + " flex-[999_1_520px] min-w-0 overflow-hidden"}>
                    <div className="flex items-center gap-2.5 px-4.5 py-3.5 border-b border-line">
                        <h2 id="needs" className="m-0 text-[15px] font-semibold">Needs you</h2>
                        {(<span className={chip("warn")}>{str(needs)}</span>) if needs else None}
                    </div>
                    {if needs == 0 {
                        <div className="px-4.5 py-6 text-[13px] text-muted">
                            {"Nothing is waiting on you." if skills else "Nothing yet. Build an agent in the Studio to give Sigil something to run."}
                            {(<a href="#/" className={LINK + " ml-1.5"}>Build one in the Studio →</a>) if (not skills) else None}
                        </div>
                    }}
                    {for p in pending {
                        <div key={"p-" + str(p.cmd)} className="flex flex-wrap items-center gap-x-4 gap-y-3 px-4.5 py-4 border-b border-line">
                            <span className="w-[34px] h-[34px] rounded-[9px] bg-[#f5c451]/15 text-[#f5c451] flex items-center justify-center shrink-0"><Icon name="shield" size={17}/></span>
                            <div className="flex-[1_1_280px] min-w-0 flex flex-col gap-0.5">
                                <div className="font-medium">Waiting for approval: <span className="font-mono text-[13px] text-warn break-all">{p.cmd}</span></div>
                                <div className="text-[12.5px] text-muted">{"asked " + fmtAgo(float(p.ts) * 1000) + " · no allowlist rule matches"}</div>
                            </div>
                            <div className="flex flex-wrap gap-2">
                                <button type="button" disabled={busy == str(p.cmd)} className={BTN_SM}
                                    onClick={lambda (e: MouseEvent) { decide(str(p.cmd), "allow-once"); }}>Allow once</button>
                                <a href="#/approvals" className={BTN2_SM + " no-underline"}>Always allow…</a>
                                <button type="button" disabled={busy == str(p.cmd)} className={BTN_BAD_SM}
                                    onClick={lambda (e: MouseEvent) { decide(str(p.cmd), "deny"); }}>Deny</button>
                            </div>
                        </div>
                    }}
                    {for j in bad_jobs {
                        <div key={"j-" + str(j.job)} className="flex flex-wrap items-center gap-x-4 gap-y-3 px-4.5 py-4 border-b border-line">
                            <span className="w-[34px] h-[34px] rounded-[9px] bg-[#f87171]/15 text-[#f87171] flex items-center justify-center shrink-0"><Icon name="compile" size={17}/></span>
                            <div className="flex-[1_1_280px] min-w-0 flex flex-col gap-0.5">
                                <div className="font-medium"><span className="font-mono text-[13px]">{j.signature or j.name}</span>{" compiled " + str(j.status)}</div>
                                <div className="text-[12.5px] text-muted">{"compiled " + fmtAgo(j.created_ms) + ". Open the report to see which rules have no node."}</div>
                            </div>
                            <a href={"#/compile/" + str(j.job)} className={BTN2_SM + " no-underline"}>Open report</a>
                        </div>
                    }}
                    {for s in failing {
                        <div key={"f-" + str(s.signature)} className="flex flex-wrap items-center gap-x-4 gap-y-3 px-4.5 py-4 border-b border-line">
                            <span className="w-[34px] h-[34px] rounded-[9px] bg-[#f5c451]/15 text-[#f5c451] flex items-center justify-center shrink-0"><Icon name="library" size={17}/></span>
                            <div className="flex-[1_1_280px] min-w-0 flex flex-col gap-0.5">
                                <div className="font-medium"><span className="font-mono text-[13px]">{s.signature}</span> is struggling</div>
                                <div className="text-[12.5px] text-muted">
                                    {str(s.successes) + " of " + str(s.runs) + " runs ok"}
                                    {(" · last grade " + str(s.last_score) + ", below your threshold of " + str(threshold)) if ((int(s.last_score) >= 0) and (int(s.last_score) < threshold)) else ""}
                                </div>
                            </div>
                            <div className="flex flex-wrap gap-2">
                                <a href={"#/skills/" + str(s.signature)} className={BTN2_SM + " no-underline"}>Open</a>
                                <button type="button" disabled={busy == str(s.signature)} className={BTN2_SM}
                                    onClick={lambda (e: MouseEvent) { relearn(str(s.signature)); }}>{"Relearning…" if (busy == str(s.signature)) else "Relearn"}</button>
                            </div>
                        </div>
                    }}
                    {for j in broken_cron {
                        <div key={"c-" + str(j.name)} className="flex flex-wrap items-center gap-x-4 gap-y-3 px-4.5 py-4 border-b border-line">
                            <span className="w-[34px] h-[34px] rounded-[9px] bg-[#f87171]/15 text-[#f87171] flex items-center justify-center shrink-0"><Icon name="clock" size={17}/></span>
                            <div className="flex-[1_1_280px] min-w-0 flex flex-col gap-0.5">
                                <div className="font-medium"><span className="font-mono text-[13px]">{j.name}</span>{" last run: " + str(j.last_status)}</div>
                                <div className="text-[12.5px] text-muted">{str(j.schedule) + " · " + str(j.errors) + " errors in " + str(j.runs) + " runs"}</div>
                            </div>
                            <a href="#/automations" className={BTN2_SM + " no-underline"}>Open schedule</a>
                        </div>
                    }}
                    {(<div className="flex flex-wrap items-center gap-x-4 gap-y-3 px-4.5 py-4">
                        <span className="w-[34px] h-[34px] rounded-[9px] bg-[#f87171]/15 text-[#f87171] flex items-center justify-center shrink-0"><Icon name="clock" size={17}/></span>
                        <div className="flex-[1_1_280px] min-w-0 flex flex-col gap-0.5">
                            <div className="font-medium">Schedules will not fire: the daemon is not running</div>
                            <div className="text-[12.5px] text-muted">{str(len(armed)) + " schedules are armed. Start it with "}<span className="font-mono">sigil daemon start</span>.</div>
                        </div>
                        <a href="#/settings/system" className={BTN2_SM + " no-underline"}>System</a>
                    </div>) if daemon_down else None}
                </section>

                <section aria-labelledby="recent" className={CARD + " flex-[1_1_320px] min-w-0 overflow-hidden"}>
                    <div className="flex items-center gap-2.5 px-4.5 py-3.5 border-b border-line">
                        <h2 id="recent" className="m-0 text-[15px] font-semibold">Recent runs</h2>
                        <a href="#/runs" className={LINK + " ml-auto text-[12.5px] no-underline"}>All runs →</a>
                    </div>
                    {(<div className="px-4.5 py-6 text-[13px] text-muted">Nothing has run yet.</div>) if (not tasks) else None}
                    {for (i, t) in enumerate(tasks[:7]) {
                        <a key={"t-" + str(i)} href={"#/runs/" + str(i)} className="flex gap-3 px-4.5 py-3 border-b border-line no-underline text-fg hover:bg-ink-3">
                            <span className={dotCls("ok" if t.ok else "bad") + " mt-1.5"}></span>
                            <span className="flex-1 min-w-0 flex flex-col gap-1">
                                <span className="text-[13.5px] truncate">{str(t.detail or t.label)}</span>
                                <span className="flex flex-wrap items-center gap-1.5 text-xs text-muted">
                                    <span className="font-mono">{t.label}</span>
                                    <span>{"· " + str(t.kind)}</span>
                                    {(<span className={tagCls("live" if (_routeTag(t.summary) == "HIT") else ("warn" if (_routeTag(t.summary) == "MUTATE") else "acc"))}>{_routeTag(t.summary)}</span>) if _routeTag(t.summary) else None}
                                </span>
                            </span>
                            <span className="font-mono text-xs text-muted shrink-0">{fmtAgo(t.at_ms)}</span>
                        </a>
                    }}
                </section>
            </div>

            <section aria-labelledby="pages" className="flex flex-col gap-3">
                <h2 id="pages" className={LABEL + " m-0"}>Everything else</h2>
                <div className="grid gap-3 grid-cols-[repeat(auto-fill,minmax(250px,1fr))]">
                    {for t in tiles {
                        <a key={str(t[0])} href={"#" + str(t[1])}
                            className={CARD + " flex flex-col gap-1.5 px-4 py-3.5 no-underline text-fg hover:border-line-2" + (" border-warn/40" if t[4] else "")}>
                            <span className="flex items-center gap-2 text-[13px] font-medium text-fg-2">
                                <Icon name={str(t[2])} size={16} cls={"text-warn" if t[4] else "text-violet-400"}/>{t[0]}
                            </span>
                            <span className={"text-[12.5px] leading-snug " + ("text-warn" if t[4] else "text-muted")}>{t[3]}</span>
                        </a>
                    }}
                </div>
            </section>
        </div>
    </div>;
}

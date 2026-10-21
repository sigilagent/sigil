"""Runs: every task Sigil ran, newest first.

One request (`api_tasks`, src/sigil_tasks.jac) reads the run ledger off the
graph: each solve a skill handled (an Attempt on its TaskGraph) and each fire of
a schedule (a CronRun on its CronJob), merged by time. A row opens in place to
show what the ledger kept: the task, the model, the outcome and the run's report.

#/runs/<n> opens the n-th run (newest is 0), which is how Home links a run here.
"""

import from src.sigil { api_tasks }
import from .ui {
    PageHead, Icon, Segmented, Empty, Note, Spinner, CARD, BTN2, BTN2_SM, BTN_GHOST_SM, LABEL, chip
}
import from "./console_interop.js" { seen, remember, fmtAgo, fmtClock, money, secs, copyText }
import from react { useEffect }

def _isCron(t: any) -> bool { return str(t.kind or "") == "cron"; }

def _kindLabel(t: any) -> str {
    k = str(t.kind or "");
    if k == "cron" { return "scheduled"; }
    return k if k else "run";
}

def _task(t: any) -> str { return str(t.detail or t.label or ""); }

def _cost(t: any) -> float {
    c = t.cost_usd if t.cost_usd else t.cost;
    return float(c) if c else 0.0;
}

def _took(t: any) -> float { return float(t.duration_ms) if t.duration_ms else 0.0; }

def:pub RunsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None],
                 refresh: Callable[[], None]) -> JsxElement {
    has runs: list[any] = [];
    has loaded: bool = False;
    has loading: bool = False;
    has err: str = "";
    has filt: str = "all";
    has q: str = "";
    has openKey: str = "";
    has copied: str = "";

    sub = str(route[1]) if (len(route) > 1) else "";

    async def load() {
        loading = True;
        r = root spawn api_tasks(n=200);
        m: any = r.reports[0] if r.reports else {"ok": False, "error": "no response from Sigil"};
        loading = False;
        loaded = True;
        if m and (not m.error) { runs = remember("runs", list(m)); err = ""; }
        elif m { err = str(m.error); }
    }

    can with entry {
        prev: any = seen("runs");
        if prev { runs = prev; loaded = True; }
        load();
    }

    useEffect(lambda {
        if sub { openKey = sub; }
    }, [sub]);

    def toggle(k: str) {
        openKey = "" if (openKey == k) else k;
        copied = "";
    }

    def copyTask(k: str, text: str) {
        copyText(text);
        copied = k;
    }

    def context(t: any) -> str {
        return "About this run: " + _kindLabel(t) + " " + str(t.label or "") + ", "
            + ("ok" if t.ok else "failed") + ", " + fmtAgo(t.at_ms) + ". Task: " + _task(t);
    }

    def askHere(text: str) {
        sel: any = None;
        for (i, t) in enumerate(runs) { if str(i) == openKey { sel = t; } }
        if sel { ask(text + chr(10) + chr(10) + context(sel)); }
        else { ask(text); }
    }

    needle = q.strip().lower();
    shown: list[any] = [];
    n_solve = 0;
    n_cron = 0;
    n_failed = 0;
    any_took = False;
    any_cost = False;
    for (i, t) in enumerate(runs) {
        if _isCron(t) { n_cron += 1; } else { n_solve += 1; }
        if not t.ok { n_failed += 1; }
        if _took(t) > 0 { any_took = True; }
        if _cost(t) > 0 { any_cost = True; }
        if (filt == "solve") and _isCron(t) { continue; }
        if (filt == "cron") and (not _isCron(t)) { continue; }
        if (filt == "failed") and t.ok { continue; }
        if needle and (needle not in (_task(t) + " " + str(t.label or "") + " " + str(t.model or "")).lower()) { continue; }
        shown.append([str(i), t]);
    }
    ncols = 5 + (1 if any_took else 0) + (1 if any_cost else 0);
    selTag = "runs";
    for (i, t) in enumerate(runs) {
        if str(i) == openKey { selTag = "run " + fmtClock(t.at_ms); }
    }

    return <div className="flex flex-col">
        <PageHead title="Runs" kicker="Activity · solves and scheduled runs" onAsk={askHere}
            askHint={"Ask about this run" if openKey else "Ask about these runs"} tag={selTag}>
            <button type="button" className={BTN2} disabled={loading} onClick={lambda (e: MouseEvent) { load(); }}>
                <Icon name="refresh" size={15} cls={"animate-spin" if loading else ""}/>{"Refreshing…" if loading else "Refresh"}
            </button>
        </PageHead>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-4">
            <div className="flex flex-wrap gap-2.5 items-center">
                <Segmented label="Kind" value={filt} onPick={lambda (v: str) { filt = v; }}
                    options={[["all", "All " + str(len(runs))], ["solve", "Solves " + str(n_solve)],
                              ["cron", "Scheduled " + str(n_cron)], ["failed", "Failed " + str(n_failed)]]}/>
                <label className="flex items-center gap-2 h-9 flex-[1_1_240px] max-w-[360px] px-3 rounded-lg bg-ink-2 border border-line-2">
                    <Icon name="search" size={15} cls="text-muted"/>
                    <span className="sr-only">Search runs</span>
                    <input value={q} placeholder="Search tasks or skills" onChange={lambda (e: ChangeEvent) { q = e.target.value; }}
                        className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[13px] text-fg placeholder:text-faint"/>
                </label>
                <span className="ml-auto text-[12.5px] text-muted">{"Showing " + str(len(shown)) + " of " + str(len(runs))}</span>
            </div>

            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Spinner label="Reading the run ledger…"/>) if (not loaded) else None}

            {if loaded and (len(runs) == 0) and (not err) {
                <Empty title="Nothing has run yet"
                    body="Each task Sigil solves with a compiled skill, and each time a schedule fires, is recorded here with its outcome and report.">
                    <a href="#/chat" className={BTN2_SM + " no-underline"}>Give Sigil a task</a>
                </Empty>
            } elif loaded and (len(runs) > 0) {
                <div className={CARD + " overflow-x-auto"}>
                    <table className="w-full min-w-[820px] border-collapse text-[13px]">
                        <thead>
                            <tr className="text-left text-xs text-muted">
                                <th scope="col" className="px-4 py-3 font-medium w-[110px]">Time</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Task</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Handled by</th>
                                <th scope="col" className="px-2.5 py-3 font-medium">Result</th>
                                {(<th scope="col" className="px-2.5 py-3 font-medium text-right">Took</th>) if any_took else None}
                                {(<th scope="col" className="px-2.5 py-3 font-medium text-right">Cost</th>) if any_cost else None}
                                <th scope="col" className="px-2.5 py-3 pr-4 w-10"><span className="sr-only">Details</span></th>
                            </tr>
                        </thead>
                        <tbody>
                            {for p in shown {
                                <tr key={"r" + p[0]} onClick={lambda (e: MouseEvent) { toggle(str(p[0])); }}
                                    className={"border-t border-line cursor-pointer " + ("bg-violet-500/10" if (openKey == p[0]) else ("bg-bad/5 hover:bg-ink-3" if (not p[1].ok) else "hover:bg-ink-3"))}>
                                    <td className="px-4 py-3 font-mono text-xs text-muted whitespace-nowrap" title={fmtClock(p[1].at_ms)}>{fmtAgo(p[1].at_ms)}</td>
                                    <td className="px-2.5 py-3 max-w-[420px]">
                                        <span className="block truncate text-fg">{_task(p[1])}</span>
                                    </td>
                                    <td className="px-2.5 py-3">
                                        <span className="flex flex-col gap-0.5 min-w-0">
                                            <span className="flex items-center gap-1.5 text-xs text-muted">
                                                <span>{_kindLabel(p[1])}</span>
                                                {if _isCron(p[1]) {
                                                    <a href="#/automations" onClick={lambda (e: MouseEvent) { e.stopPropagation(); }}
                                                        className="font-mono text-[12.5px] text-fg no-underline hover:text-acc truncate">{str(p[1].label)}</a>
                                                } else {
                                                    <a href={"#/skills/" + str(p[1].label)} onClick={lambda (e: MouseEvent) { e.stopPropagation(); }}
                                                        className="font-mono text-[12.5px] text-fg no-underline hover:text-acc truncate">{str(p[1].label)}</a>
                                                }}
                                            </span>
                                            {(<span className="text-[11.5px] text-faint font-mono truncate">{str(p[1].model)}</span>) if p[1].model else None}
                                        </span>
                                    </td>
                                    <td className="px-2.5 py-3"><span className={chip("ok" if p[1].ok else "bad")}>{"ok" if p[1].ok else "failed"}</span></td>
                                    {(<td className="px-2.5 py-3 font-mono text-xs text-right text-fg-2">{secs(_took(p[1])) if (_took(p[1]) > 0) else "—"}</td>) if any_took else None}
                                    {(<td className="px-2.5 py-3 font-mono text-xs text-right text-[#f5c451]">{money(_cost(p[1])) if (_cost(p[1]) > 0) else "—"}</td>) if any_cost else None}
                                    <td className="px-2.5 py-3 pr-4 text-right">
                                        <button type="button" aria-expanded={"true" if (openKey == p[0]) else "false"}
                                            aria-label={("Hide" if (openKey == p[0]) else "Show") + " details of this run"}
                                            className="inline-flex items-center justify-center w-7 h-7 rounded-md text-muted hover:text-fg hover:bg-ink-4 bg-transparent border-0 cursor-pointer">
                                            <Icon name="chevron" size={14} cls={"transition-transform " + ("rotate-90" if (openKey == p[0]) else "")}/>
                                        </button>
                                    </td>
                                </tr>
                                if openKey == p[0] {
                                    <tr key={"d" + p[0]} className="bg-violet-500/5">
                                        <td colSpan={ncols} className="px-4 pt-1 pb-4">
                                            <div className="flex flex-col gap-3.5 pl-[94px] max-md:pl-0">
                                                <dl className="m-0 grid gap-x-6 gap-y-2 grid-cols-[repeat(auto-fit,minmax(150px,1fr))] text-[12.5px]">
                                                    <div className="flex flex-col gap-0.5"><dt className={LABEL}>Kind</dt><dd className="m-0 text-fg-2">{_kindLabel(p[1])}</dd></div>
                                                    <div className="flex flex-col gap-0.5"><dt className={LABEL}>{"Schedule" if _isCron(p[1]) else "Skill"}</dt><dd className="m-0 font-mono text-fg-2 break-all">{str(p[1].label)}</dd></div>
                                                    <div className="flex flex-col gap-0.5"><dt className={LABEL}>Model</dt><dd className="m-0 font-mono text-fg-2 break-all">{str(p[1].model) if p[1].model else "—"}</dd></div>
                                                    <div className="flex flex-col gap-0.5"><dt className={LABEL}>Result</dt><dd className={"m-0 " + ("text-ok" if p[1].ok else "text-bad")}>{"finished ok" if p[1].ok else "failed"}</dd></div>
                                                    <div className="flex flex-col gap-0.5"><dt className={LABEL}>When</dt><dd className="m-0 text-fg-2">{fmtClock(p[1].at_ms) + " · " + fmtAgo(p[1].at_ms)}</dd></div>
                                                    {(<div className="flex flex-col gap-0.5"><dt className={LABEL}>Took</dt><dd className="m-0 font-mono text-fg-2">{secs(_took(p[1]))}</dd></div>) if (_took(p[1]) > 0) else None}
                                                    {(<div className="flex flex-col gap-0.5"><dt className={LABEL}>Cost</dt><dd className="m-0 font-mono text-fg-2">{money(_cost(p[1]))}</dd></div>) if (_cost(p[1]) > 0) else None}
                                                </dl>
                                                <div className="flex flex-col gap-1.5">
                                                    <span className={LABEL}>Task</span>
                                                    <p className="m-0 text-[13.5px] leading-relaxed text-fg whitespace-pre-wrap break-words">{_task(p[1])}</p>
                                                </div>
                                                {(<Note text={str(p[1].error)} tone="bad"/>) if p[1].error else None}
                                                <div className="flex flex-col gap-1.5">
                                                    <span className={LABEL}>{"Result" if _isCron(p[1]) else "Report"}</span>
                                                    {if p[1].summary {
                                                        <pre className="m-0 max-h-80 overflow-auto px-3 py-2.5 rounded-lg bg-ink-1 border border-line text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-fg-2">{str(p[1].summary)}</pre>
                                                        if len(str(p[1].summary)) >= 400 {
                                                            <span className="text-xs text-faint">The ledger keeps the first 400 characters of each report.</span>
                                                        }
                                                    } else {
                                                        <span className="text-[12.5px] text-faint">The run left no report.</span>
                                                    }}
                                                </div>
                                                <div className="flex flex-wrap gap-2">
                                                    {if _isCron(p[1]) {
                                                        <a href="#/automations" className={BTN2_SM + " no-underline"}><Icon name="clock" size={14}/>Open schedules</a>
                                                    } else {
                                                        <a href={"#/skills/" + str(p[1].label)} className={BTN2_SM + " no-underline"}>{"Open " + str(p[1].label)}</a>
                                                    }}
                                                    <button type="button" className={BTN_GHOST_SM}
                                                        onClick={lambda (e: MouseEvent) { copyTask(str(p[0]), _task(p[1])); }}>
                                                        <Icon name={"check" if (copied == p[0]) else "copy"} size={14}/>{"Copied" if (copied == p[0]) else "Copy task"}
                                                    </button>
                                                    <button type="button" className={BTN_GHOST_SM}
                                                        onClick={lambda (e: MouseEvent) { ask(("Why did this run fail?" if (not p[1].ok) else "Explain what this run did.") + chr(10) + chr(10) + context(p[1])); }}>
                                                        <Icon name="chat" size={14}/>{"Ask why it failed" if (not p[1].ok) else "Ask about this run"}
                                                    </button>
                                                </div>
                                            </div>
                                        </td>
                                    </tr>
                                }
                            }}
                        </tbody>
                    </table>
                    {(<div className="px-4 py-5 text-[13px] text-muted border-t border-line">No run matches these filters.</div>) if (len(shown) == 0) else None}
                </div>
            }}
        </div>
    </div>;
}

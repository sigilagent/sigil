"""Usage: every model call Sigil made, what it cost and how long it took.

One request (`usage` in src/sigil_console.jac) reads the token log every model
call appends to (the last 3000 calls at most): totals, spend per day, spend by
model and by skill signature, and the newest 200 calls with what each returned.
The per-day chart covers the last 14 calendar days, a day with no calls drawn
as an empty slot.
"""

import from src.sigil_console { api_console }
import from .ui {
    PageHead, Stat, Icon, Segmented, Empty, Note, Spinner, Bar, CARD, BTN2, BTN2_SM, LABEL, chip
}
import from "./console_interop.js" { seen, remember, fmtAgo, fmtClock, fmtDay, money, compact, secs }

glob DAYS: int = 14;

def _pad(n: int) -> str { return ("0" + str(n)) if (n < 10) else str(n); }

def _lastDays(n: int) -> list[str] {
    # The last n local calendar days, oldest first, keyed the way the backend
    # keys them (YYYY-MM-DD in local time). Noon, so a DST change never lands
    # two keys on one day.
    t: any = new(Date);
    y = t.getFullYear();
    mo = t.getMonth();
    dd = t.getDate();
    out: list[str] = [];
    for i in range(n) {
        d: any = new(Date, y, mo, dd - (n - 1 - i), 12);
        out.append(str(d.getFullYear()) + "-" + _pad(int(d.getMonth()) + 1) + "-" + _pad(int(d.getDate())));
    }
    return out;
}

def _num(v: any) -> float { return float(v) if v else 0.0; }

def _pct(part: float, whole: float) -> float {
    if whole <= 0 { return 0.0; }
    return (part * 100.0) / whole;
}

def _int(v: any) -> str { return str(int(v)) if v else "0"; }

def _csvCell(v: any) -> str {
    s = str(v if v else "");
    if ("," in s) or ("\"" in s) or (chr(10) in s) { return "\"" + s.replace("\"", "\"\"") + "\""; }
    return s;
}

def _csv(calls: list[any]) -> str {
    rows: list[str] = ["time,model,signature,prompt_tokens,completion_tokens,reasoning_tokens,cache_read_tokens,duration_ms,cost_usd,error"];
    for c in calls {
        rows.append(",".join([
            _csvCell(fmtClock(_num(c.ts) * 1000)), _csvCell(c.model), _csvCell(c.signature),
            _int(c.prompt_tokens), _int(c.completion_tokens), _int(c.reasoning_tokens), _int(c.cache_read_tokens),
            _int(c.duration_ms), str(_num(c.cost_usd)), _csvCell(c.error)
        ]));
    }
    return chr(10).join(rows);
}

def:pub UsagePage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None],
                  refresh: Callable[[], None]) -> JsxElement {
    has data: any = None;
    has loaded: bool = False;
    has loading: bool = False;
    has err: str = "";
    has view: str = "chart";
    has hover: str = "";
    has q: str = "";
    has openKey: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def load() {
        loading = True;
        m: any = await call("usage", {});
        loading = False;
        loaded = True;
        if m and (not m.error) and m.totals { data = remember("usage", m); err = ""; }
        elif m and m.error { err = str(m.error); }
    }

    can with entry {
        prev: any = seen("usage");
        if prev { data = prev; loaded = True; }
        load();
    }

    def toggle(k: str) { openKey = "" if (openKey == k) else k; }

    tot: any = data.totals if data else None;
    models: list[any] = list(data.models) if (data and data.models) else [];
    sigs: list[any] = list(data.signatures) if (data and data.signatures) else [];
    calls: list[any] = list(data.calls) if (data and data.calls) else [];

    # The 14-day series: [key, cost, calls, tokens], oldest first.
    byDay: dict[str, any] = {};
    if data and data.days {
        for d in data.days { byDay[str(d.key)] = d; }
    }
    series: list[any] = [];
    maxCost = 0.0;
    span_cost = 0.0;
    span_calls = 0;
    for k in _lastDays(DAYS) {
        d: any = byDay[k] if (k in byDay) else None;
        c = _num(d.cost) if d else 0.0;
        n = int(d.calls) if d else 0;
        series.append([k, c, n, int(d.tokens) if d else 0]);
        if c > maxCost { maxCost = c; }
        span_cost = span_cost + c;
        span_calls = span_calls + n;
    }
    hk = hover if hover else (str(series[len(series) - 1][0]) if series else "");
    readout = "";
    for s in series {
        if s[0] == hk { readout = fmtDay(s[0]) + " · " + money(s[1]) + " · " + str(s[2]) + " calls"; }
    }
    newest: list[any] = [];
    for (i, s) in enumerate(series) { newest.append(series[len(series) - 1 - i]); }

    tin = _num(tot.tin) if tot else 0.0;
    tout = _num(tot.tout) if tot else 0.0;
    ncalls = int(tot.calls) if tot else 0;
    nerr = int(tot.errors) if tot else 0;
    topModel = str(models[0].key) if ((len(models) > 0) and (_num(models[0].cost) > 0)) else "";
    maxModel = _num(models[0].cost) if (len(models) > 0) else 0.0;
    maxSig = _num(sigs[0].cost) if (len(sigs) > 0) else 0.0;

    needle = q.strip().lower();
    shown: list[any] = [];
    for (i, c) in enumerate(calls) {
        if needle and (needle not in (str(c.model or "") + " " + str(c.signature or "") + " " + str(c.error or "")).lower()) { continue; }
        shown.append([str(i), c]);
    }
    csvHref = "data:text/csv;charset=utf-8," + encodeURIComponent(_csv([p[1] for p in shown]));

    return <div className="flex flex-col">
        <PageHead title="Usage" kicker="Activity · every LLM call Sigil made" onAsk={ask} askHint="Ask about spend" tag="usage">
            <button type="button" className={BTN2} disabled={loading} onClick={lambda (e: MouseEvent) { load(); }}>
                <Icon name="refresh" size={15} cls={"animate-spin" if loading else ""}/>{"Refreshing…" if loading else "Refresh"}
            </button>
        </PageHead>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-4.5">
            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Spinner label="Reading the token log…"/>) if (not loaded) else None}

            {if loaded and (not err) and ((not tot) or (ncalls == 0)) {
                <Empty title="No model calls yet"
                    body="Every call Sigil makes to a model, while compiling a skill, routing a task, running a skill's slots or chatting, is logged with its tokens, cost and latency. Nothing has been logged yet."/>
            } elif tot {
                <div className="grid gap-3 grid-cols-[repeat(auto-fit,minmax(160px,1fr))]">
                    <Stat label="Spend" value={money(tot.cost)} tone="gold" sub={("most on " + topModel) if topModel else "no priced calls"}/>
                    <Stat label="LLM calls" value={str(ncalls)} sub={str(len(models)) + (" model" if (len(models) == 1) else " models")}/>
                    <Stat label="Tokens" value={compact(tin + tout)}
                        sub={compact(tin) + " in · " + compact(tout) + " out" + ((" · " + compact(tot.reasoning) + " reasoning") if _num(tot.reasoning) > 0 else "")}/>
                    <Stat label="Cache hits" value={(str(int(_pct(_num(tot.cached), tin))) + "%") if (tin > 0) else "—"} sub="of input tokens"/>
                    <Stat label="Median latency" value={secs(tot.p50_ms) if _num(tot.p50_ms) > 0 else "—"}
                        sub={("p95 " + secs(tot.p95_ms)) if _num(tot.p95_ms) > 0 else ""}/>
                    <Stat label="Errors" value={str(nerr)} tone={"bad" if (nerr > 0) else ""}
                        sub={(str(round(_pct(float(nerr), float(ncalls)), 1)) + "% of calls") if (ncalls > 0) else ""}/>
                </div>

                <section aria-labelledby="perday" className={CARD + " px-4.5 py-4 flex flex-col gap-3"}>
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-2">
                        <h2 id="perday" className="m-0 text-sm font-semibold">Spend per day</h2>
                        <span className="text-[12.5px] font-mono text-fg-2" aria-live="polite">{readout}</span>
                        <span className="text-xs text-muted">{"last 14 days · " + money(span_cost) + " · " + str(span_calls) + " calls"}</span>
                        <span className="ml-auto"><Segmented label="View" small={True} value={view} onPick={lambda (v: str) { view = v; }} options={[["chart", "Chart"], ["table", "Table"]]}/></span>
                    </div>
                    {if view == "chart" {
                        <div className="flex flex-col gap-2">
                            <div className="relative h-[200px] ml-14">
                                {if maxCost > 0 {
                                    <div className="absolute -left-14 right-0 top-0 flex items-center gap-2"><span className="w-12 text-right font-mono text-[11px] text-muted">{money(maxCost)}</span><span className="flex-1 h-px bg-line"></span></div>
                                    <div className="absolute -left-14 right-0 top-1/3 flex items-center gap-2"><span className="w-12 text-right font-mono text-[11px] text-muted">{money((maxCost * 2.0) / 3.0)}</span><span className="flex-1 h-px bg-line"></span></div>
                                    <div className="absolute -left-14 right-0 top-2/3 flex items-center gap-2"><span className="w-12 text-right font-mono text-[11px] text-muted">{money(maxCost / 3.0)}</span><span className="flex-1 h-px bg-line"></span></div>
                                } else {
                                    <div className="absolute inset-0 flex items-center justify-center text-[12.5px] text-muted">No priced calls in the last 14 days.</div>
                                }}
                                <div className="absolute left-0 right-0 bottom-0 h-px bg-line-2"></div>
                                <div className="absolute inset-0 flex items-end gap-1.5 px-1.5">
                                    {for s in series {
                                        <button key={"b" + str(s[0])} type="button"
                                            aria-label={fmtDay(s[0]) + ": " + money(s[1]) + ", " + str(s[2]) + " calls"}
                                            title={fmtDay(s[0]) + " · " + money(s[1]) + " (" + str(s[1]) + " USD) · " + str(s[2]) + " calls · " + compact(s[3]) + " tokens"}
                                            onMouseEnter={lambda (e: MouseEvent) { hover = str(s[0]); }}
                                            onFocus={lambda (e: any) { hover = str(s[0]); }}
                                            className="flex-1 h-full flex items-end justify-center bg-transparent border-0 p-0 cursor-pointer">
                                            <span className={"block w-full max-w-[44px] rounded-t " + ("bg-[#a78bfa]" if (str(s[0]) == hk) else "bg-[#8b6fe0]")}
                                                style={{"height": (("max(2px, " + str(_pct(s[1], maxCost)) + "%)") if (s[1] > 0) else "0")}}></span>
                                        </button>
                                    }}
                                </div>
                            </div>
                            <div className="flex gap-1.5 px-1.5 ml-14" aria-hidden="true">
                                {for s in series {
                                    <span key={"l" + str(s[0])} className={"flex-1 min-w-0 flex flex-col items-center leading-tight text-[11px] " + ("text-fg" if (str(s[0]) == hk) else "text-muted")}>
                                        <span>{fmtDay(s[0]).split(" ")[0]}</span>
                                        <span className="font-mono">{fmtDay(s[0]).split(" ")[1] if (len(fmtDay(s[0]).split(" ")) > 1) else ""}</span>
                                    </span>
                                }}
                            </div>
                        </div>
                    } else {
                        <div className="overflow-x-auto">
                            <table className="w-full min-w-[420px] border-collapse text-[13px]">
                                <thead>
                                    <tr className="text-left text-xs text-muted">
                                        <th scope="col" className="py-2 pr-2.5 font-medium">Day</th>
                                        <th scope="col" className="py-2 px-2.5 font-medium text-right">Calls</th>
                                        <th scope="col" className="py-2 px-2.5 font-medium text-right">Tokens</th>
                                        <th scope="col" className="py-2 pl-2.5 font-medium text-right">Cost</th>
                                    </tr>
                                </thead>
                                <tbody className="font-mono">
                                    {for s in newest {
                                        <tr key={"t" + str(s[0])} className="border-t border-line">
                                            <td className="py-2 pr-2.5 font-sans">{fmtDay(s[0])}<span className="ml-2 text-xs text-faint font-mono">{s[0]}</span></td>
                                            <td className="py-2 px-2.5 text-right">{str(s[2])}</td>
                                            <td className="py-2 px-2.5 text-right">{compact(s[3])}</td>
                                            <td className={"py-2 pl-2.5 text-right " + ("text-[#f5c451]" if (s[1] > 0) else "text-muted")}>{money(s[1])}</td>
                                        </tr>
                                    }}
                                </tbody>
                            </table>
                        </div>
                    }}
                </section>

                <div className="flex flex-wrap gap-4 items-stretch">
                    <section aria-labelledby="bymodel" className={CARD + " flex-[1_1_380px] min-w-0 overflow-hidden"}>
                        <div className="px-4.5 py-3.5 border-b border-line"><h2 id="bymodel" className="m-0 text-sm font-semibold">By model</h2></div>
                        <div className="overflow-x-auto">
                            <table className="w-full min-w-[380px] border-collapse text-[13px]">
                                <thead>
                                    <tr className="text-left text-xs text-muted">
                                        <th scope="col" className="px-4.5 py-2.5 font-medium">Model</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Calls</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Tokens</th>
                                        <th scope="col" className="px-2.5 py-2.5 pr-4.5 font-medium text-right">Cost</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {for r in models {
                                        <tr key={"m" + str(r.key)} className="border-t border-line">
                                            <td className="px-4.5 py-2.5">
                                                <span className="block font-mono text-[12.5px] truncate max-w-[220px]">{str(r.key)}</span>
                                                <span className="block w-full max-w-[220px] mt-1"><Bar pct={_pct(_num(r.cost), maxModel)} tone="acc"/></span>
                                            </td>
                                            <td className="px-2.5 py-2.5 text-right font-mono">{str(r.calls)}</td>
                                            <td className="px-2.5 py-2.5 text-right font-mono">{compact(r.tokens)}</td>
                                            <td className={"px-2.5 py-2.5 pr-4.5 text-right font-mono " + ("text-[#f5c451]" if (_num(r.cost) > 0) else "text-muted")}>{money(r.cost)}</td>
                                        </tr>
                                    }}
                                </tbody>
                            </table>
                        </div>
                    </section>

                    <section aria-labelledby="bysig" className={CARD + " flex-[1_1_380px] min-w-0 overflow-hidden"}>
                        <div className="px-4.5 py-3.5 border-b border-line"><h2 id="bysig" className="m-0 text-sm font-semibold">By skill</h2></div>
                        <div className="overflow-x-auto">
                            <table className="w-full min-w-[380px] border-collapse text-[13px]">
                                <thead>
                                    <tr className="text-left text-xs text-muted">
                                        <th scope="col" className="px-4.5 py-2.5 font-medium">Signature</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Calls</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Tokens</th>
                                        <th scope="col" className="px-2.5 py-2.5 pr-4.5 font-medium text-right">Cost</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {for r in sigs {
                                        <tr key={"s" + str(r.key)} className="border-t border-line">
                                            <td className="px-4.5 py-2.5">
                                                {if str(r.key) == "(no signature)" {
                                                    <span className="block text-[12.5px] text-muted">outside any skill</span>
                                                } else {
                                                    <a href={"#/skills/" + str(r.key)} className="block font-mono text-[12.5px] text-fg no-underline hover:text-acc truncate max-w-[220px]">{str(r.key)}</a>
                                                }}
                                                <span className="block w-full max-w-[220px] mt-1"><Bar pct={_pct(_num(r.cost), maxSig)} tone="acc"/></span>
                                            </td>
                                            <td className="px-2.5 py-2.5 text-right font-mono">{str(r.calls)}</td>
                                            <td className="px-2.5 py-2.5 text-right font-mono">{compact(r.tokens)}</td>
                                            <td className={"px-2.5 py-2.5 pr-4.5 text-right font-mono " + ("text-[#f5c451]" if (_num(r.cost) > 0) else "text-muted")}>{money(r.cost)}</td>
                                        </tr>
                                    }}
                                </tbody>
                            </table>
                        </div>
                    </section>
                </div>

                <section aria-labelledby="calls" className={CARD + " overflow-hidden"}>
                    <div className="flex flex-wrap items-center gap-2.5 px-4.5 py-3.5 border-b border-line">
                        <h2 id="calls" className="m-0 text-sm font-semibold">Calls</h2>
                        <span className="text-xs text-muted">Open a row to see the reply, reasoning and tool calls</span>
                        <span className="ml-auto flex flex-wrap items-center gap-2">
                            <label className="flex items-center gap-2 h-8 w-[240px] max-w-full px-2.5 rounded-lg bg-ink-1 border border-line-2">
                                <Icon name="search" size={14} cls="text-muted"/>
                                <span className="sr-only">Filter calls</span>
                                <input value={q} placeholder="Filter: skill, model, error" onChange={lambda (e: ChangeEvent) { q = e.target.value; }}
                                    className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[12.5px] text-fg placeholder:text-faint"/>
                            </label>
                            <a href={csvHref} download="sigil-calls.csv" className={BTN2_SM + " no-underline"}>Export CSV</a>
                        </span>
                    </div>
                    <div className="overflow-x-auto">
                        <table className="w-full min-w-[960px] border-collapse text-[12.5px]">
                            <thead>
                                <tr className="text-left text-xs text-muted">
                                    <th scope="col" className="px-4.5 py-2.5 font-medium">Time</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium">Model</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium">For</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">In</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Out</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Reasoning</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Cached</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Took</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Cost</th>
                                    <th scope="col" className="px-2.5 py-2.5 pr-4.5 w-10"><span className="sr-only">Details</span></th>
                                </tr>
                            </thead>
                            <tbody className="font-mono">
                                {for p in shown {
                                    <tr key={"c" + p[0]} onClick={lambda (e: MouseEvent) { toggle(str(p[0])); }}
                                        className={"border-t border-line cursor-pointer " + ("bg-violet-500/10" if (openKey == p[0]) else ("bg-bad/5 hover:bg-ink-3" if p[1].error else "hover:bg-ink-3"))}>
                                        <td className="px-4.5 py-2.5 text-muted whitespace-nowrap" title={fmtClock(_num(p[1].ts) * 1000)}>{fmtAgo(_num(p[1].ts) * 1000)}</td>
                                        <td className="px-2.5 py-2.5 whitespace-nowrap">{str(p[1].model)}</td>
                                        <td className="px-2.5 py-2.5 font-sans">
                                            <span className="flex flex-wrap items-center gap-1.5">
                                                {(<span className="font-mono text-fg-2 truncate max-w-[260px]">{str(p[1].signature)}</span>) if p[1].signature else (<span className="text-faint">—</span>)}
                                                {(<span className={chip("bad")}>error</span>) if p[1].error else None}
                                            </span>
                                        </td>
                                        <td className="px-2.5 py-2.5 text-right">{_int(p[1].prompt_tokens)}</td>
                                        <td className="px-2.5 py-2.5 text-right">{_int(p[1].completion_tokens)}</td>
                                        <td className="px-2.5 py-2.5 text-right">{_int(p[1].reasoning_tokens)}</td>
                                        <td className="px-2.5 py-2.5 text-right">{_int(p[1].cache_read_tokens)}</td>
                                        <td className="px-2.5 py-2.5 text-right">{secs(p[1].duration_ms) if _num(p[1].duration_ms) > 0 else "—"}</td>
                                        <td className={"px-2.5 py-2.5 text-right " + ("text-[#f5c451]" if (_num(p[1].cost_usd) > 0) else "text-muted")}>{money(p[1].cost_usd)}</td>
                                        <td className="px-2.5 py-2.5 pr-4.5 text-right">
                                            <button type="button" aria-expanded={"true" if (openKey == p[0]) else "false"}
                                                aria-label={("Hide" if (openKey == p[0]) else "Show") + " what this call returned"}
                                                className="inline-flex items-center justify-center w-7 h-7 rounded-md text-muted hover:text-fg hover:bg-ink-4 bg-transparent border-0 cursor-pointer">
                                                <Icon name="chevron" size={14} cls={"transition-transform " + ("rotate-90" if (openKey == p[0]) else "")}/>
                                            </button>
                                        </td>
                                    </tr>
                                    if openKey == p[0] {
                                        <tr key={"x" + p[0]} className="bg-violet-500/5">
                                            <td colSpan={10} className="px-4.5 pt-1 pb-4 font-sans">
                                                <div className="flex flex-col gap-3">
                                                    <span className="text-xs text-muted">{fmtClock(_num(p[1].ts) * 1000) + " · " + fmtAgo(_num(p[1].ts) * 1000) + " · " + str(p[1].model) + ((" · " + str(p[1].signature)) if p[1].signature else "")}</span>
                                                    {(<Note text={str(p[1].error)} tone="bad"/>) if p[1].error else None}
                                                    <div className="flex flex-col gap-1.5">
                                                        <span className={LABEL}>Reply</span>
                                                        {if p[1].content {
                                                            <pre className="m-0 max-h-72 overflow-auto px-3 py-2.5 rounded-lg bg-ink-1 border border-line text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-fg-2">{str(p[1].content)}</pre>
                                                        } else {
                                                            <span className="text-[12.5px] text-faint">No text in the reply.</span>
                                                        }}
                                                    </div>
                                                    {if p[1].reasoning {
                                                        <div className="flex flex-col gap-1.5">
                                                            <span className={LABEL}>Reasoning</span>
                                                            <pre className="m-0 max-h-72 overflow-auto px-3 py-2.5 rounded-lg bg-ink-1 border border-line text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-muted">{str(p[1].reasoning)}</pre>
                                                        </div>
                                                    }}
                                                    {if p[1].tools {
                                                        <div className="flex flex-col gap-1.5">
                                                            <span className={LABEL}>Tool calls</span>
                                                            <pre className="m-0 px-3 py-2.5 rounded-lg bg-ink-1 border border-line text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-fg-2">{str(p[1].tools)}</pre>
                                                        </div>
                                                    }}
                                                    <span className="text-xs text-faint">The log keeps the first 600 characters of each reply.</span>
                                                </div>
                                            </td>
                                        </tr>
                                    }
                                }}
                            </tbody>
                        </table>
                        {(<div className="px-4.5 py-5 text-[13px] text-muted border-t border-line font-sans">No call matches this filter.</div>) if (len(shown) == 0) else None}
                    </div>
                    <div className="px-4.5 py-3 border-t border-line text-[12.5px] text-muted">
                        {"Showing " + str(len(shown)) + " of the newest " + str(len(calls)) + " calls · totals above cover the last " + str(ncalls) + " calls in the log"}
                    </div>
                </section>
            }}
        </div>
    </div>;
}

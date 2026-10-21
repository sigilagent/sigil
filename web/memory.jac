"""Memory: what Sigil knows about you, and what a task would recall from it.

Teach writes a memory onto the agent's graph (`api_teach`); Recall runs the same
retrieval a task runs before it starts (`api_recall`); the list is every memory
on the Soul, by salience (`memory_list`), each with a Forget behind a confirm
(`memory_forget`). A kind is a label on the memory: recall weighs every kind the
same way.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_teach, api_recall }
import from .ui {
    PageHead, Icon, Segmented, Empty, Note, Spinner, Bar, CARD, BTN, BTN2, BTN_GHOST_SM, BTN_BAD_SM,
    AREA, INP
}
import from "./console_interop.js" { seen, remember, fmtAgo }

glob KINDS: list[any] = [["fact", "Fact"], ["preference", "Preference"], ["procedure", "Procedure"]];

def _kindLabel(k: str) -> str {
    if k == "fact" { return "Facts"; }
    if k == "preference" { return "Preferences"; }
    if k == "procedure" { return "Procedures"; }
    if k == "observation" { return "Observations"; }
    return k;
}

def _kindCls(k: str) -> str {
    if k == "preference" { return "text-live"; }
    if k == "procedure" { return "text-warn"; }
    if k == "fact" { return "text-fg-2"; }
    return "text-muted";
}

def _age(m: any) -> str {
    ms = m.at_ms or m.created_ms or m.ts_ms;
    return fmtAgo(ms) if ms else "";
}

def _dropFirst(xs: list[any], content: str) -> list[any] {
    # memory_forget deletes the first memory with this content; mirror that.
    out: list[any] = [];
    gone = False;
    for x in xs {
        if (not gone) and (str(x.content) == content) { gone = True; continue; }
        out.append(x);
    }
    return out;
}

def:pub MemoryPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None],
                   refresh: Callable[[], None]) -> JsxElement {
    has mems: list[any] = [];
    has loaded: bool = False;
    has err: str = "";
    has msg: str = "";
    has busy: str = "";
    has fact: str = "";
    has kind: str = "fact";
    has rq: str = "";
    has hits: list[any] = [];
    has recalled: str = "";
    has recallErr: str = "";
    has filt: str = "all";
    has q: str = "";
    has confirmKey: str = "";
    has fresh: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def load() {
        m: any = await call("memory_list", {});
        loaded = True;
        if m and (not m.error) { mems = remember("memories", list(m)); err = ""; }
        elif m { err = str(m.error); }
    }

    can with entry {
        prev: any = seen("memories");
        if prev { mems = prev; loaded = True; }
        load();
    }

    async def teach() {
        f = fact.strip();
        if (not f) or busy { return; }
        busy = "teach";
        err = "";
        msg = "";
        r = root spawn api_teach(fact=f, kind=kind);
        m: any = r.reports[0] if r.reports else {"ok": False, "error": "no response from Sigil"};
        busy = "";
        if (not m) or m.error {
            err = str(m.error) if m else "Sigil did not answer.";
            return;
        }
        mems = remember("memories", [{"content": f, "kind": kind, "salience": 1.0, "uses": 0}] + mems);
        fresh = f;
        fact = "";
        msg = "Remembered as a " + kind + ".";
        load();
    }

    async def doRecall() {
        qq = rq.strip();
        if (not qq) or busy { return; }
        busy = "recall";
        recallErr = "";
        r = root spawn api_recall(query=qq, k=8);
        m: any = r.reports[0] if r.reports else {"ok": False, "error": "no response from Sigil"};
        busy = "";
        recalled = qq;
        if m and (not m.error) { hits = list(m); }
        else { hits = []; recallErr = str(m.error) if m else "Sigil did not answer."; }
    }

    async def forget(key: str, content: str) {
        busy = key;
        err = "";
        msg = "";
        m: any = await call("memory_forget", {"content": content});
        busy = "";
        confirmKey = "";
        if m and m.ok {
            mems = remember("memories", _dropFirst(mems, content));
            hits = _dropFirst(hits, content);
            msg = "Forgotten.";
        } else { err = str(m.error) if m else "Sigil did not answer."; }
        load();
    }

    def keyed(e: KeyboardEvent) {
        if (e.key == "Enter") and (not e.shiftKey) {
            e.preventDefault();
            teach();
        }
    }

    def recallKeyed(e: KeyboardEvent) {
        if e.key == "Enter" { doRecall(); }
    }

    # Counts per kind, the known kinds first, then any other the graph holds.
    counts: dict[str, int] = {};
    order: list[str] = [];
    maxSal = 0.0;
    for m in mems {
        k = str(m.kind or "fact");
        if k in counts { counts[k] = counts[k] + 1; }
        else { counts[k] = 1; order.append(k); }
        s = float(m.salience) if m.salience else 0.0;
        if s > maxSal { maxSal = s; }
    }
    opts: list[any] = [["all", "All " + str(len(mems))]];
    for kk in KINDS {
        if kk[0] in counts { opts.append([kk[0], _kindLabel(kk[0]) + " " + str(counts[kk[0]])]); }
    }
    for k in order {
        if k not in ["fact", "preference", "procedure"] { opts.append([k, _kindLabel(k) + " " + str(counts[k])]); }
    }
    activeFilt = filt if ((filt == "all") or (filt in counts)) else "all";

    needle = q.strip().lower();
    shown: list[any] = [];
    for (i, m) in enumerate(mems) {
        if (activeFilt != "all") and (str(m.kind or "fact") != activeFilt) { continue; }
        if needle and (needle not in str(m.content).lower()) { continue; }
        shown.append([str(i), m]);
    }
    anyAge = len([m for m in mems if _age(m)]) > 0;

    return <div className="flex flex-col">
        <PageHead title="Memory" kicker="Agent · what Sigil knows about you" onAsk={ask}
            askHint="Ask what Sigil knows" tag="memory"/>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-4.5">
            <div className="flex flex-wrap gap-4 items-stretch">
                <section aria-labelledby="teach" className={CARD + " flex-[1_1_360px] min-w-0 px-4.5 py-4 flex flex-col gap-3"}>
                    <h2 id="teach" className="m-0 text-sm font-semibold">Teach</h2>
                    <label className="flex flex-col gap-1.5 text-xs text-muted">What should Sigil remember?
                        <textarea rows={2} value={fact} placeholder="e.g. Accounting closes the month on the 3rd"
                            onChange={lambda (e: ChangeEvent) { fact = e.target.value; }} onKeyDown={keyed}
                            className={AREA + " text-[13.5px]"}></textarea>
                    </label>
                    <div className="flex flex-wrap gap-2.5 items-center">
                        <Segmented label="Kind" value={kind} onPick={lambda (v: str) { kind = v; }} options={KINDS}/>
                        <button type="button" className={BTN + " ml-auto"} disabled={(not fact.strip()) or (busy != "")}
                            onClick={lambda (e: MouseEvent) { teach(); }}>
                            {"Teaching…" if (busy == "teach") else "Teach"}
                        </button>
                    </div>
                    <span className="text-xs text-faint">Before a task runs, Sigil recalls the memories that match it. Enter teaches; Shift+Enter adds a line.</span>
                </section>

                <section aria-labelledby="recall" className={CARD + " flex-[1_1_360px] min-w-0 px-4.5 py-4 flex flex-col gap-3"}>
                    <div className="flex items-center gap-2">
                        <h2 id="recall" className="m-0 text-sm font-semibold">Recall</h2>
                        <span className="ml-auto text-xs text-muted">what a task would see</span>
                    </div>
                    <div className="flex gap-2">
                        <input aria-label="Recall query" value={rq} placeholder="e.g. invoices"
                            onChange={lambda (e: ChangeEvent) { rq = e.target.value; }} onKeyDown={recallKeyed}
                            className={INP + " flex-1 h-[38px] text-[13.5px]"}/>
                        <button type="button" className={BTN2 + " h-[38px]"} disabled={(not rq.strip()) or (busy != "")}
                            onClick={lambda (e: MouseEvent) { doRecall(); }}>
                            {"Recalling…" if (busy == "recall") else "Recall"}
                        </button>
                    </div>
                    {(<Note text={recallErr} tone="bad"/>) if recallErr else None}
                    {if busy == "recall" {
                        <Spinner label="Recalling…"/>
                    } elif recalled and (len(hits) == 0) and (not recallErr) {
                        <span className="text-[12.5px] text-muted">{"Nothing Sigil remembers matches " + chr(8220) + recalled + chr(8221) + ". A task with these words would start with no memories."}</span>
                    } elif len(hits) > 0 {
                        <ol className="list-none m-0 p-0 flex flex-col gap-1.5 text-[13px]">
                            {for (hi, h) in enumerate(hits) {
                                <li key={"h" + str(hi)} className="flex gap-2.5 items-baseline">
                                    <span className="w-9 shrink-0 font-mono text-[11.5px] text-acc">{str(round(float(h.score), 2)) if h.score else ("#" + str(hi + 1))}</span>
                                    <span className="flex-1 min-w-0 break-words">{str(h.content)}</span>
                                    <span className={"text-[11.5px] shrink-0 " + _kindCls(str(h.kind or "fact"))}>{str(h.kind or "fact")}</span>
                                </li>
                            }}
                        </ol>
                    }}
                    {(<span className="text-xs text-faint">Ranked by how well each matches, weighted by salience. Recalling here counts as a use.</span>) if (len(hits) > 0) else None}
                </section>
            </div>

            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Note text={msg} tone="ok"/>) if msg else None}

            <section aria-labelledby="all" className={CARD + " overflow-hidden"}>
                <div className="flex flex-wrap items-center gap-2.5 px-4.5 py-3.5 border-b border-line">
                    <h2 id="all" className="m-0 text-sm font-semibold">Everything Sigil remembers</h2>
                    {(<Segmented label="Kind filter" small={True} value={activeFilt} onPick={lambda (v: str) { filt = v; }} options={opts}/>) if (len(mems) > 0) else None}
                    <label className="ml-auto flex items-center gap-2 h-8 w-[220px] max-w-full px-2.5 rounded-lg bg-ink-1 border border-line-2">
                        <Icon name="search" size={14} cls="text-muted"/>
                        <span className="sr-only">Filter memories</span>
                        <input value={q} placeholder="Filter" onChange={lambda (e: ChangeEvent) { q = e.target.value; }}
                            className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[12.5px] text-fg placeholder:text-faint"/>
                    </label>
                </div>

                {if not loaded {
                    <div className="px-4.5 py-5"><Spinner label="Reading the agent's memory…"/></div>
                } elif len(mems) == 0 {
                    <div className="p-4.5">
                        <Empty title="Sigil remembers nothing yet"
                            body="Teach it a fact above, or let it learn: when a task finishes ok, Sigil keeps the facts worth carrying into the next one."/>
                    </div>
                } else {
                    <div className="overflow-x-auto">
                        <table className="w-full min-w-[760px] border-collapse text-[13px]">
                            <thead>
                                <tr className="text-left text-xs text-muted">
                                    <th scope="col" className="px-4.5 py-2.5 font-medium">Memory</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium">Kind</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium">Salience</th>
                                    <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Uses</th>
                                    {(<th scope="col" className="px-2.5 py-2.5 font-medium">Added</th>) if anyAge else None}
                                    <th scope="col" className="px-2.5 py-2.5 pr-4.5"><span className="sr-only">Actions</span></th>
                                </tr>
                            </thead>
                            <tbody>
                                {for p in shown {
                                    <tr key={"m" + p[0]} className={"border-t border-line" + (" bg-live/5" if (fresh and (str(p[1].content) == fresh)) else "")}>
                                        <td className="px-4.5 py-2.5 max-w-[560px] break-words">
                                            {str(p[1].content)}
                                            {(<span className="ml-1.5 px-1.5 py-px rounded text-[11px] text-live bg-live/10">new</span>) if (fresh and (str(p[1].content) == fresh)) else None}
                                        </td>
                                        <td className={"px-2.5 py-2.5 " + _kindCls(str(p[1].kind or "fact"))}>{str(p[1].kind or "fact")}</td>
                                        <td className="px-2.5 py-2.5">
                                            <span className="flex items-center gap-2" title={"salience " + str(p[1].salience)}>
                                                <span className="block w-[72px]"><Bar pct={((float(p[1].salience) * 100.0) / maxSal) if ((maxSal > 0) and p[1].salience) else 0.0} tone="acc"/></span>
                                                <span className="font-mono text-[11.5px] text-muted">{str(round(float(p[1].salience), 2)) if p[1].salience else "0"}</span>
                                            </span>
                                        </td>
                                        <td className="px-2.5 py-2.5 text-right font-mono">{str(p[1].uses) if p[1].uses else "0"}</td>
                                        {(<td className="px-2.5 py-2.5 text-muted">{_age(p[1]) if _age(p[1]) else "—"}</td>) if anyAge else None}
                                        <td className="px-2.5 py-2.5 pr-4.5 text-right whitespace-nowrap">
                                            {if confirmKey == p[0] {
                                                <span className="inline-flex items-center gap-2">
                                                    <span className="text-xs text-muted">Forget this?</span>
                                                    <button type="button" className={BTN_BAD_SM} disabled={busy != ""}
                                                        onClick={lambda (e: MouseEvent) { forget(str(p[0]), str(p[1].content)); }}>
                                                        {"Forgetting…" if (busy == p[0]) else "Forget"}
                                                    </button>
                                                    <button type="button" className={BTN_GHOST_SM} disabled={busy == p[0]}
                                                        onClick={lambda (e: MouseEvent) { confirmKey = ""; }}>Keep</button>
                                                </span>
                                            } else {
                                                <button type="button" className={BTN_BAD_SM} disabled={busy != ""}
                                                    aria-label={"Forget: " + str(p[1].content)}
                                                    onClick={lambda (e: MouseEvent) { confirmKey = str(p[0]); }}>Forget</button>
                                            }}
                                        </td>
                                    </tr>
                                }}
                            </tbody>
                        </table>
                        {(<div className="px-4.5 py-5 text-[13px] text-muted border-t border-line">No memory matches this filter.</div>) if (len(shown) == 0) else None}
                    </div>
                }}

                {(<div className="px-4.5 py-3 border-t border-line text-[12.5px] text-muted">{"Showing " + str(len(shown)) + " of " + str(len(mems)) + " · sorted by salience"}</div>) if (len(mems) > 0) else None}
            </section>
        </div>
    </div>;
}

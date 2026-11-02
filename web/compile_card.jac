"""A compile, drawn inside the Studio's chat.

The same job the Compile page runs (`compile_start` in src/sigil_console.jac),
shown as one card in the conversation: each raise2 stage as it finishes, the
question it is waiting on with its Do / Maybe / Don't answers, and the result.
The chat stores only the job id, so a reload redraws the card from the job.

`onDone` fires once, when this card watched the job finish: the Studio opens the
new skill in its viewer. A card for a job that was already over when it mounted
stays quiet, so reopening the Studio does not jump to an old compile.
"""

import from src.sigil_console { api_console }
import from .ui { Icon, Note, Spinner, BTN_SM, BTN2_SM, chip }
import from .compile { ANSWERS, stageRows, statusTone, MODES_LABEL }
import from "./console_interop.js" { secs }
import from react { useEffect }

def:pub CompileCard(job: str, onDone: Callable[[str], None]) -> JsxElement {
    has st: any = None;
    has err: str = "";
    has answering: bool = False;
    has sawLive: bool = False;
    has told: bool = False;

    async def call(op: str, args: dict[str, any]) -> any {
        try {
            r = root spawn api_console(op=op, args=args);
            if r.reports { return r.reports[0]; }
        } except Exception as e {
            return {"ok": False, "error": str(e)};
        }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def poll() {
        m: any = await call("compile_status", {"job": job});
        if m and m.ok {
            st = m;
            if str(m.state) in ["running", "waiting"] { sawLive = True; }
            res: any = m.result;
            over = str(m.state) in ["done", "stopped"];
            if over and sawLive and (not told) and res and res.ok and res.signature {
                told = True;
                onDone(str(res.signature));
            }
        } elif m { err = str(m.error); }
    }

    async def answer(i: int, a: str) {
        answering = True;
        m: any = await call("compile_answer", {"job": job, "i": i, "answer": a});
        answering = False;
        if m and m.error { err = str(m.error); }
        poll();
    }

    live = (not st) or (str(st.state) in ["running", "waiting"]);

    useEffect(lambda {
        poll();
        return;
    }, [job]);

    useEffect(lambda {
        if not live { return; }
        iv = setInterval(lambda { poll(); }, 2000);
        return lambda { clearInterval(iv); };
    }, [job, live]);

    if not st {
        return <div className="rounded-xl border border-line-2 bg-ink-2 px-3.5 py-3">
            {(<Note text={err} tone="bad"/>) if err else (<Spinner label="Starting the compile…"/>)}
        </div>;
    }

    meta: any = st.meta;
    result: any = st.result;
    state = str(st.state);
    events: list[any] = list(st.events) if st.events else [];
    mode = str(meta.mode) if meta else "ask";
    rows = stageRows(events, state, mode, state in ["done", "stopped"]);
    status = str(result.status) if result else "";
    sig = str(result.signature) if (result and result.signature) else "";
    name = sig if sig else (str(meta.name) if meta else "skill");
    endms = int(result.finished_ms) if (result and result.finished_ms) else int(st.now_ms or 0);
    elapsed = (endms - int(meta.created_ms)) if (meta and meta.created_ms) else 0;
    q: any = st.ask;

    return <div className="rounded-xl border border-line-2 bg-ink-2 overflow-hidden">
        <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1.5 px-3.5 py-2.5 border-b border-line">
            <span className="text-[12.5px] font-semibold">{"Compiled" if (state == "done") else ("Stopped" if (state == "stopped") else "Compiling")}</span>
            <span className="font-mono text-xs text-acc truncate min-w-0">{name + ((" v" + str(result.version)) if (result and result.version) else "")}</span>
            {if state == "waiting" { <span className={chip("warn")}>waiting for you</span> }
             elif state == "running" { <span className={chip("live")}>compiling</span> }
             elif status { <span className={chip(statusTone(status))}>{status}</span> }
             elif state == "stopped" { <span className={chip("bad")}>stopped</span> }}
            <span className="ml-auto text-[11.5px] text-muted">{secs(elapsed) + " · " + MODES_LABEL(mode)}</span>
        </div>
        <ol className="list-none m-0 px-3.5 py-2 flex flex-col gap-1.5">
            {for r in rows {
                <li key={str(r[0])} className="flex gap-2 text-[12.5px] leading-snug">
                    <span aria-hidden="true" className={"w-4 text-center shrink-0 " + ("text-ok" if (r[3] == "done") else ("text-live" if (r[3] == "run") else "text-faint"))}>
                        {"✓" if (r[3] == "done") else ("◐" if (r[3] == "run") else ("–" if (r[3] == "skip") else "○"))}
                    </span>
                    <span className="min-w-0">
                        <span className={"font-medium " + ("text-fg" if (r[3] in ["done", "run"]) else "text-muted")}>{r[1]}</span>
                        <span className="text-muted">{" " + (str(r[4]) if r[4] else str(r[2]))}</span>
                    </span>
                    <span className="ml-auto pl-2 font-mono text-[11px] text-faint shrink-0">{r[5]}</span>
                </li>
            }}
        </ol>
        {(<div className="mx-3.5 mb-3 rounded-lg border border-[#f5c451]/40 bg-[#f5c451]/5 p-3 flex flex-col gap-2.5">
            <span className="text-[12.5px] font-semibold">The skill leaves this open</span>
            <p className="m-0 text-[13px] leading-relaxed text-fg whitespace-pre-wrap">{str(q.question)}</p>
            <div className="flex flex-wrap gap-2">
                {for a in ANSWERS {
                    <button key={str(a[0])} type="button" disabled={answering} className={BTN2_SM}
                        onClick={lambda (e: MouseEvent) { answer(int(q.i), str(a[0])); }}>
                        <span className="font-semibold">{a[1]}</span><span className="text-muted">{a[2]}</span>
                    </button>
                }}
            </div>
        </div>) if q else None}
        {(<div className="px-3.5 pb-3"><Note text={err} tone="bad"/></div>) if err else None}
        {(<div className="px-3.5 pb-3"><Note text={str(result.error)} tone="bad"/></div>) if (result and result.error) else None}
        {(<div className="px-3.5 pb-3"><Note text="The compile process ended without a result. The full report has its log." tone="bad"/></div>) if ((state == "stopped") and (not result)) else None}
        {(<div className="flex flex-wrap items-center gap-2 px-3.5 py-2.5 border-t border-line bg-ink-1">
            {(<button type="button" className={BTN_SM} onClick={lambda (e: MouseEvent) { onDone(sig); }}>Open in viewer</button>) if (sig and result and result.ok) else None}
            <a href={"#/compile/" + job} className={BTN2_SM + " no-underline"}>Full report<Icon name="external" size={12}/></a>
        </div>) if (state in ["done", "stopped"]) else None}
    </div>;
}

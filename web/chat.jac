"""Chat: hand Sigil a task and watch what it does.

The agent here is the one the `sigil` REPL runs: the workspace tools, the web,
memory, schedules and one tool per compiled skill on its shelf. A console request
is a fresh process, so the browser holds the conversation: each turn sends the
history back (`chat_turn`), and the reply carries the updated history, what the
agent was handed this turn (`context`, drawn in "What Sigil sees") and any
command the turn left waiting for approval. Each of those gets an inline card;
allowing them sends a follow-up turn so the agent retries.

The model's history is not what this page shows: byLLM stores each user turn
with the agent's instructions folded into it. So the page keeps its own
transcript (what you typed, the replies, each turn's tool calls) beside the
history, and both live in localStorage under "sigil.chat".

A draft handed over from another page (the "Ask Sigil" boxes, the palette) is
sent at once: whoever typed it already pressed Enter.

This is the Studio's middle pane (web/studio.jac), so it also talks to the panes
beside it. A turn that compiles, learns or runs a skill names it through
`onSkill`, and the viewer opens it. The viewer's "Ask about this step" and "Run"
set `focus`, a chip above the input that frames the next message.

It stays a general chat. Asked for an agent, Sigil scopes it with you and, once
it is confident, calls `propose_agent` (src/chat_agent.jac, web turns only): the
reply carries a card with the SKILL.md it wrote and a Build button. Build, like
the paperclip's skill folder, runs the Compile page's job and lands in the
conversation as a card (web/compile_card.jac).
"""

import from src.sigil_console { api_console }
import from .ui {
    Icon, Logo, Note, Spinner, BTN_SM, BTN2_SM, BTN_BAD_SM, BTN_GHOST_SM, LABEL, LINK, CHIP, SELECT
}
import from .compile { MODES }
import from .compile_card { CompileCard }
import from .markdown { Markdown }
import from "./console_interop.js" { storeGet, storeSet, scrollToEnd, focusId, nowMs, fmtClock, readFiles }
import from react { useEffect }

glob STORE_KEY: str = "sigil.chat";
glob CAP: int = 60;
# What a turn sends back: the backend reads only the last 32 messages, and the
# history travels to the agent process as one command-line argument.
glob SEND_CAP: int = 32;
glob SLIM_AT: int = 4000;
glob NL: str = chr(10);
glob KNOWN: list[str] = [
    "agent_name", "persona", "principles", "workspace", "sandbox", "running_shell_jobs",
    "compiled_skills", "relevant_memory", "chat_model", "model"
];

glob PRESS_ON: str = "inline-flex items-center gap-1.5 h-8 px-2.5 rounded-lg border text-xs font-medium cursor-pointer bg-violet-500/15 border-violet-400/30 text-acc";
glob PRESS_OFF: str = "inline-flex items-center gap-1.5 h-8 px-2.5 rounded-lg border text-xs font-medium cursor-pointer bg-transparent border-line-2 text-fg-2 hover:bg-ink-3";
glob TOOL_CHIP: str = "inline-flex items-center h-6 px-2 rounded-md font-mono text-[11.5px] text-fg-2 bg-ink-3";
glob TOOL_CHIP_ACC: str = "inline-flex items-center h-6 px-2 rounded-md font-mono text-[11.5px] text-acc bg-acc/10";
glob TOOL_CHIP_LIVE: str = "inline-flex items-center h-6 px-2 rounded-md font-mono text-[11.5px] text-live bg-live/10";
glob SKILL_CHIP: str = "inline-flex items-center h-[26px] px-2.5 rounded-md font-mono text-[11.5px] text-acc bg-acc/10 no-underline hover:bg-acc/20";

# A turn outlives the page: leave Chat while one runs and the request still
# finishes and saves its reply. "since" tells a remounted page to wait for it.
glob TURN: dict[str, any] = {"since": 0};

def _tail(xs: list[any], n: int) -> list[any] {
    if len(xs) > n { return xs[len(xs) - n:]; }
    return xs;
}

def _clip(s: str, n: int) -> str {
    if len(s) > n { return s[:n] + " …"; }
    return s;
}

def _text(v: any) -> str {
    # A message's content as text: a string, or a list of {type, text} parts.
    if not v { return ""; }
    if isinstance(v, str) { return v; }
    if isinstance(v, list) {
        parts: list[str] = [];
        for p in v {
            if isinstance(p, str) { parts.append(p); }
            elif p and p.text { parts.append(str(p.text)); }
        }
        return NL.join(parts);
    }
    return JSON.stringify(v);
}

def _show(v: any) -> str {
    if isinstance(v, str) { return v; }
    if isinstance(v, list) {
        return ", ".join([(x if isinstance(x, str) else JSON.stringify(x)) for x in v]);
    }
    return JSON.stringify(v);
}

def _pretty(raw: str) -> str {
    # Tool-call arguments arrive as a JSON string; indent it for reading.
    out = raw;
    try { out = JSON.stringify(JSON.parse(raw), None, 2); }
    except Exception as e { out = raw; }
    return out;
}

def _argLine(raw: str) -> str {
    # '{"path": "~/x", "n": 3}' -> '~/x · 3': the arguments on one line.
    s = raw.strip();
    out = s;
    try {
        v: any = JSON.parse(s);
        if v and (not isinstance(v, str)) and (not isinstance(v, list)) {
            vals: list[str] = [];
            for (k, x) in v.items() {
                vals.append(x if isinstance(x, str) else JSON.stringify(x));
            }
            out = " · ".join(vals);
        }
    } except Exception as e { out = s; }
    return _clip(out.replace(NL, " "), 140);
}

def _turnTools(hist: list[any], trace: list[any]) -> list[any] {
    # The tool calls of the turn that just ended: everything after the last user
    # message in the returned history, each call paired with its result by id.
    start = 0;
    for (i, m) in enumerate(hist) {
        if m and (str(m.role) == "user") { start = i + 1; }
    }
    turn: list[any] = hist[start:];
    results: dict[str, any] = {};
    for m in turn {
        if m and (str(m.role) == "tool") and m.tool_call_id { results[str(m.tool_call_id)] = m; }
    }
    rows: list[any] = [];
    for m in turn {
        calls: list[any] = list(m.tool_calls) if (m and m.tool_calls) else [];
        for tc in calls {
            f: any = tc.function if (tc and tc.function) else None;
            name = str(f.name) if (f and f.name) else "tool";
            if name == "finish_tool" { continue; }
            cid = str(tc.id) if tc.id else "";
            res: any = results[cid] if (cid and (cid in results)) else None;
            args = _text(f.arguments) if f else "";
            rows.append({
                "name": name, "line": _argLine(args), "args": _clip(_pretty(args), 800),
                "result": _clip(_text(res.content), 1200) if res else "", "ok": True, "done": bool(res)
            });
        }
    }
    # The trace says which tool failed; it names tools by a short word ("exec",
    # "skill"), so a failure marks the first call whose name contains it.
    for t in trace {
        if t and (not t.ok) {
            for r in rows {
                if r.ok and (str(t.tool) in str(r.name)) { r["ok"] = False; break; }
            }
        }
    }
    if (len(rows) == 0) and (len(trace) > 0) {
        for t in trace {
            rows.append({"name": str(t.tool), "line": _clip(str(t.detail or ""), 140), "args": "",
                         "result": "", "ok": bool(t.ok), "done": True});
        }
    }
    return rows;
}

def _slim(hist: list[any]) -> list[any] {
    # A tool result can be a whole file. Past turns keep the head of it, so the
    # history fits in storage and in the request that carries it.
    out: list[any] = [];
    for m in hist {
        if m and (str(m.role) == "tool") and isinstance(m.content, str) and (len(m.content) > SLIM_AT) {
            out.append({**m, "content": m.content[:SLIM_AT] + " …[trimmed]"});
        } else { out.append(m); }
    }
    return out;
}

def _shelf(v: any) -> list[any] {
    # "skill_clean_csv — Clean a CSV  (runs=3)" -> [signature, intent, runs]
    out: list[any] = [];
    if not isinstance(v, list) { return out; }
    for e in v {
        s = str(e);
        head = s.split("  (runs=")[0];
        runs = s.split("  (runs=")[1].split(")")[0] if ("  (runs=" in s) else "";
        name = head.split(" — ")[0].strip();
        intent = head.split(" — ")[1].strip() if (" — " in head) else "";
        sig = name[6:] if name.startswith("skill_") else name;
        out.append([sig, intent, runs]);
    }
    return out;
}

def _firstWord(cmd: str) -> str {
    w = cmd.strip().split(" ")[0] if cmd.strip() else "";
    return w;
}

def _dur(s: int) -> str {
    if s < 60 { return str(s) + "s"; }
    r = s % 60;
    return str(int(s / 60)) + "m " + ("0" if r < 10 else "") + str(r) + "s";
}

def Avatar() -> JsxElement {
    return <div className="w-7 h-7 rounded-lg bg-ink-3 border border-line-2 flex items-center justify-center shrink-0">
        <Logo size={16}/>
    </div>;
}

def ToolRows(tools: list[any]) -> JsxElement {
    return <div className="rounded-[10px] bg-ink-1 border border-line px-3 py-2 font-mono text-xs text-muted flex flex-col gap-0.5">
        {for (ti, t) in enumerate(tools) {
            <details key={"t" + str(ti)} className="group min-w-0">
                <summary className="list-none [&::-webkit-details-marker]:hidden cursor-pointer flex items-center gap-2 min-w-0 py-0.5 hover:text-fg-2">
                    <Icon name="chevron" size={12} cls="text-faint transition-transform group-open:rotate-90"/>
                    {if not t.done {
                        <span className="text-faint" aria-label="no result">…</span>
                    } elif t.ok {
                        <span className="text-ok" aria-label="ok">✓</span>
                    } else {
                        <span className="text-bad" aria-label="failed">✗</span>
                    }}
                    <span className="text-fg-2 shrink-0">{t.name}</span>
                    <span className="truncate min-w-0">{t.line}</span>
                </summary>
                <div className="ml-6 mt-1 mb-2 flex flex-col gap-2">
                    {(<div className="flex flex-col gap-0.5">
                        <span className="text-[10.5px] uppercase tracking-wider text-faint">Arguments</span>
                        <pre className="m-0 max-h-48 overflow-auto whitespace-pre-wrap break-all text-fg-2">{t.args}</pre>
                    </div>) if t.args else None}
                    {(<div className="flex flex-col gap-0.5">
                        <span className="text-[10.5px] uppercase tracking-wider text-faint">Result</span>
                        <pre className="m-0 max-h-60 overflow-auto whitespace-pre-wrap break-words text-fg-2">{t.result}</pre>
                    </div>) if t.result else None}
                    {(<span className="text-faint">Nothing more was recorded for this call.</span>) if ((not t.args) and (not t.result)) else None}
                </div>
            </details>
        }}
    </div>;
}

def Reply(text: str) -> JsxElement {
    # The model writes markdown; draw it as such (web/markdown.jac), never as HTML.
    return <div className="text-sm leading-relaxed text-fg min-w-0"><Markdown text={text}/></div>;
}

def ApprovalCard(cmd: str, rec: any, busy: bool, onDecide: Callable[[str, str], None]) -> JsxElement {
    isSkill = cmd.startswith("skill:");
    what = "Compiled skill " if isSkill else "Shell command ";
    shown = cmd[6:] if isSkill else cmd;
    always = "Always allow this skill" if isSkill else ("Always allow " + _firstWord(cmd));
    label = "";
    tone = "text-muted";
    if rec {
        d = str(rec.decision);
        if d == "allow-once" { label = "Allowed once by you"; tone = "text-ok"; }
        elif d == "allow-always" {
            label = "Always allowed" + ((", rule " + str(rec.rule)) if rec.rule else "");
            tone = "text-ok";
        } elif d == "deny" { label = "Denied by you"; tone = "text-bad"; }
        else { label = "No longer waiting: it was answered elsewhere"; }
        label = label + " · " + fmtClock(rec.at);
    }
    return <div className="rounded-xl border border-warn/30 bg-warn/5 px-3.5 py-3 flex flex-wrap items-center gap-x-3.5 gap-y-2.5">
        <Icon name="shield" size={16} cls="text-warn"/>
        <span className="flex-[1_1_260px] min-w-0 text-[13px] text-fg-2">
            {what}<span className="font-mono text-warn break-all">{shown}</span>{"" if rec else " is waiting for your approval"}
        </span>
        {if rec {
            <span className={"text-[12.5px] " + tone}>{label}</span>
        } else {
            <span className="flex flex-wrap gap-2">
                <button type="button" className={BTN_SM} disabled={busy}
                    onClick={lambda (e: MouseEvent) { onDecide(cmd, "allow-once"); }}>Allow once</button>
                <button type="button" className={BTN2_SM} disabled={busy}
                    title={"Adds an allowlist rule for " + (cmd if isSkill else _firstWord(cmd))}
                    onClick={lambda (e: MouseEvent) { onDecide(cmd, "allow-always"); }}>{always}</button>
                <button type="button" className={BTN_BAD_SM} disabled={busy}
                    onClick={lambda (e: MouseEvent) { onDecide(cmd, "deny"); }}>Deny</button>
            </span>
        }}
    </div>;
}

def _proposal(hist: list[any]) -> any {
    # The agent the turn proposed with propose_agent, from the call's own
    # arguments (the tool rows clip them, and a SKILL.md runs long).
    start = 0;
    for (i, m) in enumerate(hist) {
        if m and (str(m.role) == "user") { start = i + 1; }
    }
    found: any = None;
    for m in hist[start:] {
        calls: list[any] = list(m.tool_calls) if (m and m.tool_calls) else [];
        for tc in calls {
            f: any = tc.function if (tc and tc.function) else None;
            if f and (str(f.name) == "propose_agent") {
                try {
                    a: any = JSON.parse(_text(f.arguments));
                    if a and a.skill_md {
                        found = {"name": str(a.name or "agent"), "summary": str(a.summary or ""), "skill_md": str(a.skill_md)};
                    }
                } except Exception as e { }
            }
        }
    }
    return found;
}

def ProposalCard(p: any, built: str, busy: bool, onBuild: Callable[[str], None]) -> JsxElement {
    # Sigil scoped an agent and is confident in it: here is what it would
    # compile, and the button that does it.
    has mode: str = "ask";
    can with entry { mode = str(storeGet("sigil.compileMode", "ask")); }
    def setMode(v: str) { mode = v; storeSet("sigil.compileMode", v); }
    return <div className="rounded-xl border border-violet-400/30 bg-violet-500/5 overflow-hidden">
        <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-3.5 pt-3">
            <span className="text-[11px] font-medium tracking-wider uppercase text-acc">Ready to build</span>
            <span className="font-mono text-[13px] text-fg">{str(p.name)}</span>
        </div>
        {(<p className="m-0 px-3.5 pt-1 text-[13px] leading-relaxed text-fg-2">{str(p.summary)}</p>) if p.summary else None}
        <details className="px-3.5 pt-2 text-[12.5px]">
            <summary className="cursor-pointer text-muted hover:text-fg">The SKILL.md it compiles</summary>
            <pre className="m-0 mt-2 max-h-72 overflow-auto px-3 py-2.5 rounded-lg bg-ink-1 border border-line text-xs leading-relaxed font-mono whitespace-pre-wrap break-words text-fg-2">{str(p.skill_md)}</pre>
        </details>
        <div className="flex flex-wrap items-center gap-2 px-3.5 py-3">
            {if built {
                <span className="text-[12.5px] text-muted">Building. The compile is below.</span>
            } else {
                <label className="inline-flex items-center gap-1.5 text-xs text-muted">Unclear rules
                    <select value={mode} onChange={lambda (e: ChangeEvent) { setMode(str(e.target.value)); }}
                        title="What the compile does when the skill leaves a rule unclear"
                        className={SELECT + " h-9 text-xs"}>
                        {for md in MODES { <option key={str(md[0])} value={str(md[0])}>{str(md[1])}</option> }}
                    </select>
                </label>
                <button type="button" className={BTN_SM + " ml-auto h-9"} disabled={busy}
                    onClick={lambda (e: MouseEvent) { onBuild(mode); }}>
                    <Icon name="compile" size={14}/>{"Build " + str(p.name)}
                </button>
            }}
        </div>
    </div>;
}

def Assistant(x: any, idx: int, showTools: bool, busy: str,
              onDecide: Callable[[int, str, str], None],
              onBuild: Callable[[int, str], None], building: bool) -> JsxElement {
    tools: list[any] = list(x.tools) if x.tools else [];
    pend: list[any] = list(x.pending) if x.pending else [];
    decided: any = x.decided if x.decided else {};
    text = str(x.text or "");
    return <div className="flex gap-3">
        <Avatar/>
        <div className="flex-1 min-w-0 flex flex-col gap-2.5">
            {(<ToolRows tools={tools}/>) if (showTools and (len(tools) > 0)) else None}
            {if text {
                <Reply text={text}/>
            } elif len(pend) == 0 {
                <span className="text-[13px] text-muted">No reply text this turn.</span>
            }}
            {(<span className="text-xs text-warn">The turn was cut short; this is what it had written.</span>) if x.interrupted else None}
            {(<ProposalCard p={x.proposal} built={str(x.built or "")} busy={building}
                onBuild={lambda (md: str) { onBuild(idx, md); }}/>) if x.proposal else None}
            {for p in pend {
                <div key={"p-" + str(p.cmd)}>
                    <ApprovalCard cmd={str(p.cmd)} rec={decided[str(p.cmd)] if (str(p.cmd) in decided) else None}
                        busy={busy != ""}
                        onDecide={lambda (c: str, d: str) { onDecide(idx, c, d); }}/>
                </div>
            }}
        </div>
    </div>;
}

def PanelSec(title: str, children: any = None) -> JsxElement {
    return <section className="flex flex-col gap-1.5">
        <h3 className={LABEL + " m-0"}>{title}</h3>
        {children}
    </section>;
}


def _skillFrom(tools: list[any]) -> str {
    # The skill a turn compiled, learned or ran, read off its tool calls: a
    # signature, or a skill's tool name (skill_<signature>) the Studio resolves.
    # The last one wins: it is what the turn ended on.
    out = "";
    for t in tools {
        name = str(t.name);
        res = str(t.result or "");
        if (name == "sigil_compile") and ("compiled skill: " in res) {
            out = res.split("compiled skill: ")[1].split(" ")[0].strip();
        } elif (name == "learn_skill") and ("skill '" in res) {
            out = res.split("skill '")[1].split("'")[0].strip();
        } elif name == "use_skill" {
            try {
                a: any = JSON.parse(str(t.args or "{}"));
                if a and a.signature { out = str(a.signature); }
            } except Exception as e { }
        } elif name.startswith("skill_") {
            out = name;
        }
    }
    return out;
}

def _framed(t: str, focus: any) -> str {
    # What the model is sent when the viewer framed the message.
    if not focus { return t; }
    if focus.run { return "Use the compiled skill " + str(focus.sig) + " on this: " + t; }
    return "About skill " + str(focus.sig) + ((", step " + str(focus.node)) if focus.node else "") + ": " + t;
}

def _focusLabel(focus: any) -> str {
    if not focus { return ""; }
    if focus.run { return "run " + str(focus.sig); }
    return "@" + str(focus.sig) + ((" · " + str(focus.node)) if focus.node else "");
}

def:pub ChatPane(draft: str, clearDraft: Callable[[], None], refresh: Callable[[], None],
                 onSkill: Callable[[str], None], onCount: Callable[[int], None],
                 focus: any, clearFocus: Callable[[], None],
                 job: str, clearJob: Callable[[], None]) -> JsxElement {
    has msgs: list[any] = [];
    has history: list[any] = [];
    has ctx: any = None;
    has compose: str = "";
    has running: bool = False;
    has started: int = 0;
    has clock: int = 0;
    has busy: str = "";
    has err: str = "";
    has booted: bool = False;
    has showTools: bool = True;
    has panel: bool = False;
    has adopted: bool = False;
    has starting: bool = False;

    async def call(op: str, args: dict[str, any]) -> any {
        # A turn can run for minutes; a dropped request must not leave the page
        # stuck on "working", so a failure comes back as an answer too.
        try {
            r = root spawn api_console(op=op, args=args);
            if r.reports { return r.reports[0]; }
        } except Exception as e {
            return {"ok": False, "error": str(e)};
        }
        return {"ok": False, "error": "no response from Sigil"};
    }

    def save(ms: list[any], hs: list[any], cx: any) {
        storeSet(STORE_KEY, {"msgs": _tail(ms, CAP), "history": _slim(_tail(hs, CAP)), "context": cx});
    }

    def load() {
        saved: any = storeGet(STORE_KEY, None);
        msgs = list(saved.msgs) if (saved and saved.msgs) else [];
        history = list(saved.history) if (saved and saved.history) else [];
        ctx = saved.context if (saved and saved.context) else None;
    }

    def boot() {
        load();
        showTools = bool(storeGet("sigil.chatTools", True));
        if int(TURN["since"]) > 0 {
            # A turn started before this page was last left is still running.
            running = True;
            adopted = True;
            started = int(TURN["since"]);
            clock = nowMs();
        }
        booted = True;
    }

    async def send(raw: str, auto: bool) {
        t = raw.strip();
        if (not t) or running { return; }
        fr: any = None if auto else focus;
        sent = _framed(t, fr);
        running = True;
        err = "";
        started = nowMs();
        clock = started;
        TURN["since"] = started;
        shown: list[any] = msgs + [{"role": "user", "text": t, "at": nowMs(), "auto": auto, "focus": _focusLabel(fr)}];
        msgs = shown;
        if not auto { compose = ""; }
        if fr { clearFocus(); }
        save(shown, history, ctx);
        m: any = await call("chat_turn", {"message": sent, "history": _slim(_tail(history, SEND_CAP))});
        running = False;
        good = bool(m) and (not m.error) and (m.ok != False);
        if good {
            hs: list[any] = list(m.history) if m.history else history;
            trace: list[any] = list(m.trace) if m.trace else [];
            pend: list[any] = [{"cmd": str(p.cmd), "ts": p.ts} for p in (list(m.pending) if m.pending else [])];
            tools = _turnTools(hs, trace);
            asst = {
                "role": "assistant", "text": str(m.reply or ""), "at": nowMs(),
                "tools": tools, "pending": pend, "decided": {},
                "interrupted": bool(m.interrupted), "proposal": _proposal(hs)
            };
            after: list[any] = msgs + [asst];
            msgs = after;
            history = hs;
            if m.context { ctx = m.context; }
            save(after, hs, ctx);
            if len(pend) > 0 { refresh(); }
            picked = _skillFrom(tools);
            if picked { onSkill(picked); }
        } else {
            why = str(m.error) if (m and m.error) else "Sigil did not answer.";
            failed: list[any] = msgs + [{"role": "error", "text": why, "at": nowMs()}];
            msgs = failed;
            save(failed, history, ctx);
        }
        TURN["since"] = 0;
        focusId("chat-input");
    }

    def retry(i: int) {
        # Resend the message an error (or a reload mid-turn) left without a reply.
        t = "";
        cut = i;
        j = i;
        while j >= 0 {
            if str(msgs[j].role) == "user" { t = str(msgs[j].text); cut = j; break; }
            j -= 1;
        }
        if (not t) or running { return; }
        kept: list[any] = msgs[:cut];
        msgs = kept;
        save(kept, history, ctx);
        send(t, False);
    }

    async def decide(idx: int, cmd: str, decision: str) {
        if busy { return; }
        busy = cmd;
        err = "";
        m: any = await call("approve", {"cmd": cmd, "decision": decision, "pattern": ""});
        busy = "";
        rec: dict[str, any] = {"decision": decision, "at": nowMs(), "rule": ""};
        if m and m.ok {
            rec = {"decision": decision, "at": nowMs(), "rule": str(m.rule or "")};
        } elif m and m.error and ("no pending approval" in str(m.error)) {
            rec = {"decision": "gone", "at": nowMs(), "rule": ""};
        } else {
            err = str(m.error) if (m and m.error) else "The approval did not go through.";
            return;
        }
        out: list[any] = [];
        target: any = None;
        for (i, x) in enumerate(msgs) {
            if i == idx {
                dd: dict[str, any] = {**(x.decided if x.decided else {}), (cmd): rec};
                target = {**x, "decided": dd};
                out.append(target);
            } else { out.append(x); }
        }
        msgs = out;
        save(out, history, ctx);
        refresh();
        if not target { return; }
        # Once every command the turn asked about is answered, the agent carries on.
        pend: list[any] = list(target.pending) if target.pending else [];
        left = [p for p in pend if not (str(p.cmd) in target.decided)];
        if len(left) > 0 { return; }
        yes = [str(p.cmd) for p in pend if str(target.decided[str(p.cmd)].decision) in ["allow-once", "allow-always"]];
        no = [str(p.cmd) for p in pend if str(target.decided[str(p.cmd)].decision) == "deny"];
        if len(yes) == 0 { return; }
        follow = "Approved. Continue.";
        if len(no) > 0 {
            follow = "Approved: " + ", ".join(yes) + ". Denied: " + ", ".join(no) + ". Continue with what was approved.";
        }
        send(follow, True);
    }

    def addJob(j: str) {
        after: list[any] = msgs + [{"role": "compile", "job": j, "at": nowMs()}];
        msgs = after;
        save(after, history, ctx);
    }

    async def compileFiles(fl: any) {
        got: list[any] = await readFiles(fl);
        if not [f for f in got if str(f.path).lower().endswith("skill.md")] {
            err = "No SKILL.md in what you picked. Pick the skill's folder, or include its SKILL.md.";
            return;
        }
        starting = True;
        err = "";
        m: any = await call("compile_start", {"files": got, "mode": str(storeGet("sigil.compileMode", "ask")), "path": ""});
        starting = False;
        if m and m.ok { addJob(str(m.job)); }
        else { err = str(m.error) if (m and m.error) else "The compile did not start."; }
    }

    async def build(idx: int, md: str) {
        # The Build button on a proposal: compile the SKILL.md Sigil wrote, as the
        # same job a skill folder makes, and draw it as a card under the proposal.
        x: any = msgs[idx];
        if (not x) or (not x.proposal) or starting { return; }
        p: any = x.proposal;
        starting = True;
        err = "";
        name = str(p.name or "agent");
        m: any = await call("compile_start", {"files": [{"path": name + "/SKILL.md", "text": str(p.skill_md)}], "mode": md, "path": ""});
        starting = False;
        if not (m and m.ok) {
            err = str(m.error) if (m and m.error) else "The compile did not start.";
            return;
        }
        j = str(m.job);
        out: list[any] = [];
        for (i, y) in enumerate(msgs) { out.append({**y, "built": j} if (i == idx) else y); }
        after: list[any] = out + [{"role": "compile", "job": j, "at": nowMs()}];
        msgs = after;
        save(after, history, ctx);
    }

    def newChat(e: MouseEvent) {
        if running { return; }
        msgs = [];
        history = [];
        ctx = None;
        err = "";
        save([], [], None);
        focusId("chat-input");
    }

    def flipTools(e: MouseEvent) {
        showTools = not showTools;
        storeSet("sigil.chatTools", showTools);
    }

    def flipPanel(e: MouseEvent) { panel = not panel; }

    def keyed(e: any) {
        if (e.key == "Enter") and (not e.shiftKey) and (not e.nativeEvent.isComposing) {
            e.preventDefault();
            send(compose, False);
        }
    }

    # Load the stored conversation once, then send whatever draft another page
    # handed over (on mount, or while this page is already open).
    useEffect(lambda {
        if not booted { boot(); }
        if draft {
            d = draft;
            clearDraft();
            if running { compose = d; }
            else { send(d, False); }
        }
        focusId("chat-input");
    }, [draft]);

    # A compile started from the Studio's greeting joins the conversation here.
    useEffect(lambda {
        if not job { return; }
        if not booted { boot(); }
        addJob(job);
        clearJob();
    }, [job]);

    useEffect(lambda {
        if focus { focusId("chat-input"); }
        return;
    }, [focus]);

    useEffect(lambda {
        scrollToEnd("chat-log");
        onCount(len(msgs));
        return;
    }, [len(msgs), running]);

    useEffect(lambda {
        if not running { return; }
        iv = setInterval(lambda { clock = nowMs(); }, 1000);
        return lambda { clearInterval(iv); };
    }, [running]);

    # Waiting on a turn an earlier visit started: its reply lands in storage.
    useEffect(lambda {
        if not adopted { return; }
        iv = setInterval(lambda {
            if int(TURN["since"]) == 0 {
                load();
                running = False;
                adopted = False;
            }
        }, 1500);
        return lambda { clearInterval(iv); };
    }, [adopted]);

    lastTools: list[any] = [];
    for x in msgs {
        if (str(x.role) == "assistant") and x.tools { lastTools = list(x.tools); }
    }
    toolNames: list[str] = [];
    for t in lastTools {
        if str(t.name) not in toolNames { toolNames.append(str(t.name)); }
    }
    shelf = _shelf(ctx.compiled_skills) if ctx else [];
    noShelf = str(ctx.compiled_skills) if (ctx and isinstance(ctx.compiled_skills, str)) else "";
    sandbox = str(ctx.sandbox) if (ctx and ctx.sandbox) else "";
    model = "";
    if ctx and ctx.chat_model { model = str(ctx.chat_model); }
    elif ctx and ctx.model { model = str(ctx.model); }
    jobs = int(ctx.running_shell_jobs) if (ctx and ctx.running_shell_jobs) else 0;
    principles: list[any] = list(ctx.principles) if (ctx and ctx.principles) else [];
    recalled: list[any] = list(ctx.relevant_memory) if (ctx and ctx.relevant_memory) else [];
    extras: list[any] = [];
    if ctx {
        for (k, v) in ctx.items() {
            if (k not in KNOWN) and (v is not None) { extras.append([k, v]); }
        }
    }
    lastIdx = len(msgs) - 1;
    orphan = (not running) and (len(msgs) > 0) and (str(msgs[lastIdx].role) == "user");
    elapsed = int((clock - started) / 1000) if running else 0;

    return <section aria-label="Chat with Sigil" className="relative flex flex-col h-full min-h-0">
        <div className="flex flex-wrap items-center gap-2 px-4 py-2 border-b border-line">
            <h2 className="m-0 text-[13px] font-semibold mr-auto">Chat</h2>
            {(<span className={CHIP + " font-mono"}>{model}</span>) if model else None}
            <button type="button" aria-pressed={"true" if showTools else "false"} onClick={flipTools}
                className={PRESS_ON if showTools else PRESS_OFF}>Tool calls</button>
            <button type="button" aria-pressed={"true" if panel else "false"} aria-controls="chat-sees" onClick={flipPanel}
                className={PRESS_ON if panel else PRESS_OFF}>What Sigil sees</button>
            <button type="button" className={BTN_GHOST_SM} disabled={running} onClick={newChat}>
                <Icon name="plus" size={14}/>New
            </button>
        </div>

        <div id="chat-log" role="log" aria-label="Messages" className="flex-1 min-h-0 overflow-y-auto">
            <div className="px-4 pt-5 pb-3 flex flex-col gap-5">
                {(<p className="m-0 text-[13px] leading-relaxed text-muted">Ask Sigil anything, or hand it a task. Describe an agent you want and it will scope it with you; once it is sure, you get a Build button. The paperclip compiles a skill folder you already have.</p>) if (booted and (len(msgs) == 0) and (not running)) else None}

                {for (i, x) in enumerate(msgs) {
                    if str(x.role) == "user" {
                        <div key={"m" + str(i)} className="self-end max-w-[88%] flex flex-col items-end gap-1">
                            {(<span className="font-mono text-[11px] text-acc">{x.focus}</span>) if x.focus else None}
                            <div className="rounded-[14px_14px_4px_14px] bg-violet-500/10 border border-violet-400/25 px-3.5 py-2.5 text-sm leading-relaxed text-fg whitespace-pre-wrap break-words">{x.text}</div>
                            {(<span className="text-[11.5px] text-faint">sent for you after your approval</span>) if x.auto else None}
                        </div>
                    } elif str(x.role) == "assistant" {
                        <div key={"m" + str(i)}>
                            <Assistant x={x} idx={i} showTools={showTools} busy={busy} onDecide={decide}
                                onBuild={build} building={starting}/>
                        </div>
                    } elif str(x.role) == "compile" {
                        <div key={"m" + str(i)} className="flex gap-3">
                            <Avatar/>
                            <div className="flex-1 min-w-0"><CompileCard job={str(x.job)} onDone={onSkill}/></div>
                        </div>
                    } else {
                        <div key={"m" + str(i)} className="flex flex-col items-start gap-2 pl-10">
                            <Note text={"Sigil did not answer: " + str(x.text)} tone="bad"/>
                            {(<button type="button" className={BTN_GHOST_SM} disabled={running}
                                onClick={lambda (e: MouseEvent) { retry(i); }}>Send again</button>) if (i == lastIdx) else None}
                        </div>
                    }
                }}

                {(<div className="flex flex-wrap items-center gap-3 pl-10 text-[12.5px] text-muted">
                    <span>No reply arrived for this message. The page may have reloaded while Sigil was working.</span>
                    <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { retry(lastIdx); }}>Send again</button>
                </div>) if orphan else None}

                {(<div className="flex items-center gap-3" role="status">
                    <Avatar/>
                    <Spinner label="Sigil is working…"/>
                    <span className="text-xs text-faint">{_dur(elapsed)}</span>
                </div>) if running else None}
            </div>
        </div>

        <div className="px-4 pt-2 pb-4 flex flex-col gap-2">
            {(<Note text={err} tone="bad"/>) if err else None}
            <div className="rounded-[14px] border border-line-2 bg-ink-2 px-3 py-2.5 flex flex-col gap-2 focus-within:ring-2 focus-within:ring-violet-500/50">
                {(<span className="self-start inline-flex items-center gap-1.5 h-[26px] pl-2 pr-1 rounded-md bg-acc/10 font-mono text-[11.5px] text-acc max-w-full">
                    <span className="truncate">{_focusLabel(focus)}</span>
                    <button type="button" aria-label="Remove this context" onClick={lambda (e: MouseEvent) { clearFocus(); }}
                        className="inline-flex items-center justify-center w-5 h-5 rounded bg-transparent border-0 text-acc cursor-pointer hover:bg-acc/20">
                        <Icon name="x" size={11}/>
                    </button>
                </span>) if focus else None}
                <label htmlFor="chat-input" className="sr-only">Message Sigil</label>
                <textarea id="chat-input" rows={2} value={compose}
                    placeholder={("What should " + str(focus.sig) + " run on?") if (focus and focus.run) else "Message Sigil"}
                    onChange={lambda (e: ChangeEvent) { compose = e.target.value; }} onKeyDown={keyed}
                    className="resize-none max-h-48 bg-transparent border-0 outline-none text-sm leading-relaxed text-fg placeholder:text-faint"></textarea>
                <div className="flex flex-wrap items-center gap-2">
                    <label htmlFor="chat-pick" title="Compile a skill folder"
                        className={"inline-flex items-center justify-center w-9 h-9 rounded-lg border border-line-2 text-fg-2 hover:bg-ink-3 " + ("opacity-50" if starting else "cursor-pointer")}>
                        <span className="sr-only">Compile a skill folder</span>
                        <Icon name="clip" size={15}/>
                    </label>
                    <input id="chat-pick" type="file" webkitdirectory="" multiple={True} className="hidden" disabled={starting}
                        onChange={lambda (e: ChangeEvent) { compileFiles(e.target.files); }}/>
                    {(<Spinner label="Starting the compile…"/>) if starting else None}
                    <button type="button" aria-label="Send" className={BTN_SM + " ml-auto"}
                        disabled={running or (busy != "") or (not compose.strip())}
                        onClick={lambda (e: MouseEvent) { send(compose, False); }}>
                        <Icon name="send" size={14}/>Send
                    </button>
                </div>
            </div>
        </div>

        {(<aside id="chat-sees" aria-label="What Sigil sees"
            className="absolute inset-y-0 right-0 z-20 w-[300px] max-w-full border-l border-line bg-ink-1 overflow-y-auto px-4 py-4.5 flex flex-col gap-5 shadow-xl">
            <div className="flex items-center gap-2">
                <h2 className="m-0 text-[13px] font-semibold">What Sigil sees this turn</h2>
                <button type="button" aria-label="Hide this panel" onClick={flipPanel}
                    className="ml-auto w-7 h-7 inline-flex items-center justify-center rounded-md text-muted hover:text-fg hover:bg-ink-3 cursor-pointer bg-transparent border-0">
                    <Icon name="x" size={14}/>
                </button>
            </div>
            {if not ctx {
                <p className="m-0 text-[12.5px] leading-relaxed text-muted">Each turn the agent is handed its persona, the workspace, the compiled skills on its shelf and the memories that match your message. Send a message to see them here.</p>
            } else {
                <PanelSec title="Soul">
                    <span className="text-[13px] text-fg">{str(ctx.agent_name or "Sigil")}</span>
                    {(<span className="text-[12.5px] leading-relaxed text-muted">{str(ctx.persona)}</span>) if ctx.persona else None}
                    {(<ul className="m-0 pl-4 flex flex-col gap-0.5 text-[12.5px] text-fg-2">
                        {[<li key={"pr" + str(pi)}>{_show(pr)}</li> for (pi, pr) in enumerate(principles)]}
                    </ul>) if (len(principles) > 0) else None}
                    <a href="#/settings/agent" className={LINK + " text-xs no-underline self-start"}>Edit</a>
                </PanelSec>

                if model {
                    <PanelSec title="Model">
                        <span className="font-mono text-xs text-fg">{model}</span>
                    </PanelSec>
                }

                if ctx.workspace or sandbox {
                    <PanelSec title="Workspace">
                        {(<span className="font-mono text-xs text-fg break-all">{str(ctx.workspace)}</span>) if ctx.workspace else None}
                        <span className="text-[12.5px] text-muted">
                            {("sandbox " + sandbox + " · ") if sandbox else ""}
                            {"no shell jobs running" if (jobs == 0) else (str(jobs) + (" shell job running" if (jobs == 1) else " shell jobs running"))}
                        </span>
                    </PanelSec>
                }

                <PanelSec title={"Skills on the shelf" + ((" · " + str(len(shelf))) if (len(shelf) > 0) else "")}>
                    {if len(shelf) > 0 {
                        <div className="flex flex-wrap gap-1.5">
                            {for sk in shelf {
                                <a key={"sk-" + str(sk[0])} href={"#/studio/" + str(sk[0])} className={SKILL_CHIP}
                                    title={(str(sk[1]) + ((" · " + str(sk[2]) + " runs") if sk[2] else "")) if sk[1] else ((str(sk[2]) + " runs") if sk[2] else "")}>{sk[0]}</a>
                            }}
                        </div>
                    } else {
                        <span className="text-[12.5px] text-muted">{(noShelf[:1].upper() + noShelf[1:] + ".") if noShelf else "None."}</span>
                    }}
                </PanelSec>

                <PanelSec title="Recalled memory">
                    {if len(recalled) > 0 {
                        <div className="flex flex-col gap-1.5">
                            {for (mi, mem) in enumerate(recalled) {
                                <div key={"mem" + str(mi)} className="px-2.5 py-2 rounded-lg bg-ink-2 border border-line text-[12.5px] leading-relaxed text-fg break-words">{_show(mem)}</div>
                            }}
                        </div>
                    } else {
                        <span className="text-[12.5px] text-muted">Nothing in memory matched this message.</span>
                    }}
                    <a href="#/memory" className={LINK + " text-xs no-underline self-start"}>All memory</a>
                </PanelSec>

                <PanelSec title="Tools used this turn">
                    {if len(toolNames) > 0 {
                        <div className="flex flex-wrap gap-1.5">
                            {for tn in toolNames {
                                <span key={"tn-" + tn} className={TOOL_CHIP_LIVE if (tn == "sigil_compile") else (TOOL_CHIP_ACC if tn.startswith("skill_") else TOOL_CHIP)}>{tn}</span>
                            }}
                        </div>
                    } else {
                        <span className="text-[12.5px] text-muted">None. It answered from what it already had.</span>
                    }}
                </PanelSec>

                for ex in extras {
                    <div key={"x-" + str(ex[0])}>
                        <PanelSec title={str(ex[0]).replace("_", " ")}>
                            <span className="text-[12.5px] text-fg-2 break-words">{_show(ex[1])}</span>
                        </PanelSec>
                    </div>
                }
            }}
        </aside>) if panel else None}
    </section>;
}

"""Automations: what Sigil does on a clock, and what it does when something happens.

A schedule is a CronJob on the agent's graph (src/cron.jac): a task, and when to
run it: once, every interval, or on a cron expression. Each fire runs the task
like any other, through the router to a compiled skill, and records a run. The
daemon does the firing, so while it is down nothing fires, and the page says so.

A hook (src/hooks.jac) runs an action each time a lifecycle event happens: a
task starts or fails, a tool runs, a channel message arrives, a schedule fires.

Reads: `api_cron_list` and `api_hooks` for the two lists, and the `overview` op
for the daemon and the channels a schedule can deliver to, all three at once.
Writes: `api_cron_enable`, `api_cron_remove`, `api_cron_runs` (a card's history),
and the `cron_add`, `cron_run`, `hook_add`, `hook_enable`, `hook_remove` ops.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_cron_list, api_cron_runs, api_cron_enable, api_cron_remove, api_hooks }
import from .ui {
    PageHead, Icon, Toggle, Segmented, Empty, Note, Spinner, CARD, BTN, BTN_GHOST, BTN_SM, BTN2_SM,
    BTN_GHOST_SM, BTN_BAD_SM, INP, AREA, SELECT, LABEL, tagCls, dotCls
}
import from "./console_interop.js" { seen, remember, fmtAgo, nowMs, focusId }

glob KINDS: list[any] = [["at", "Once"], ["every", "Every…"], ["cron", "Cron"]];

glob PRESETS: list[any] = [
    ["0 8 * * *", "Every morning 08:00"],
    ["0 9 * * 1-5", "Weekdays 09:00"],
    ["0 * * * *", "Hourly"],
    ["0 9 * * 1", "Mondays 09:00"]
];

glob INTERVALS: list[any] = [["15m", "15 min"], ["1h", "1 hour"], ["6h", "6 hours"], ["1d", "1 day"]];

glob SOON: list[any] = [["10m", "In 10 min"], ["1h", "In an hour"], ["1d", "In a day"]];

glob ZONES: list[any] = [["", "This machine's clock"], ["UTC", "UTC"], ["other", "Another time zone…"]];

# [event, when it fires, what a webhook receives]: every place src/ calls fire_hooks.
glob EVENTS: list[any] = [
    ["before_solve", "a task starts", "the task"],
    ["after_solve", "a task finishes ok", "the result"],
    ["solve_failed", "a task fails", "the result"],
    ["before_tool", "a tool is about to run", "the tool and what it was asked"],
    ["after_tool", "a tool call succeeds", "the tool and what it did"],
    ["tool_failed", "a tool call fails", "the tool and what it did"],
    ["message_received", "a channel message arrives", "the channel, the sender and the text"],
    ["session_start", "a chat session starts", "the session and why it started"],
    ["cron_fired", "a schedule fires", "the schedule's name"],
    ["gateway_start", "the daemon starts", "the daemon's process id"]
];

# [kind, label, what it does, field label, placeholder]
glob ACTIONS: list[any] = [
    ["note", "Note", "Counts the event and keeps the text. Nothing runs.", "Note", "what this hook is for"],
    ["shell", "Shell", "Runs the command, for up to 30 seconds. It runs as you, outside the approvals policy.", "Command", "./scripts/audit.sh"],
    ["memory", "Memory", "Saves the text as a fact in Sigil's memory.", "Fact", "the fact to remember"],
    ["webhook", "Webhook", "POSTs the event's text to the URL.", "URL", "https://example.com/hook"]
];

glob HOOKS_ABOUT: str = "A hook runs an action each time something happens in Sigil: a task starts, finishes or fails, a tool runs, a channel message arrives, a schedule fires. The action records a note, runs a shell command, saves a fact to memory, or POSTs the event to a webhook.";

def _digits(s: str) -> bool {
    if not s { return False; }
    for ch in s {
        if ch not in "0123456789" { return False; }
    }
    return True;
}

def _intervalSecs(raw: str) -> int {
    # "90s", "10m", "6h", "1d" or a bare number of seconds, as seconds; 0 if neither.
    # The backend's `every` takes whole seconds only.
    s = raw.strip().lower().replace(" ", "");
    if not s { return 0; }
    mult = 1;
    num = s;
    tail = s[len(s) - 1:];
    if tail == "s" { num = s[:len(s) - 1]; }
    elif tail == "m" { mult = 60; num = s[:len(s) - 1]; }
    elif tail == "h" { mult = 3600; num = s[:len(s) - 1]; }
    elif tail == "d" { mult = 86400; num = s[:len(s) - 1]; }
    if not _digits(num) { return 0; }
    return int(num) * mult;
}

def _atSpec(raw: str) -> str {
    # What `parse_at` reads: a delay ("20m"), epoch ms, or an ISO date and time.
    # Anything else it silently turns into "now", so refuse it here instead.
    t = raw.strip();
    if not t { return ""; }
    low = t.lower();
    tail = low[len(low) - 1:];
    if (tail in ["s", "m", "h", "d"]) and _digits(low[:len(low) - 1]) { return low; }
    if _digits(t) { return t if (len(t) >= 12) else ""; }
    if len(t) < 10 { return ""; }
    if not (_digits(t[0:4]) and (t[4:5] == "-") and _digits(t[5:7]) and (t[7:8] == "-") and _digits(t[8:10])) { return ""; }
    if len(t) == 10 { return t; }
    sep = t[10:11];
    if (sep != "T") and (sep != "t") and (sep != " ") { return ""; }
    clock = t[11:];
    if (len(clock) >= 5) and _digits(clock[0:2]) and (clock[2:3] == ":") and _digits(clock[3:5]) { return t; }
    return "";
}

def _cronSpec(raw: str) -> str {
    parts = [p for p in raw.strip().split(" ") if p];
    if (len(parts) == 5) or (len(parts) == 6) { return " ".join(parts); }
    return "";
}

def _cap(s: str) -> str {
    if not s { return ""; }
    return s[:1].upper() + s[1:];
}

def _count(n: int, word: str) -> str {
    return str(n) + " " + word + ("" if (n == 1) else "s");
}

def _byStart(r: any) -> int { return int(r.started_ms) if r.started_ms else 0; }

def _withEnabled(x: any, on: bool) -> any { return {**x, "enabled": on}; }

def _action(kind: str) -> list[any] {
    for a in ACTIONS {
        if a[0] == kind { return a; }
    }
    return ACTIONS[0];
}

def _event(ev: str) -> list[any] {
    for e in EVENTS {
        if e[0] == ev { return e; }
    }
    return [ev, "", "the event"];
}

def _isNoSuch(m: any) -> bool {
    return str(m or "").startswith("no such");
}

def JobCard(job: any, busy: bool, onEnable: Callable[[str, bool], None], onRemove: Callable[[str], None],
            onRan: Callable[[], None]) -> JsxElement {
    has showRuns: bool = False;
    has runs: list[any] = [];
    has runsLoaded: bool = False;
    has confirming: bool = False;
    has running: bool = False;
    has ran: any = None;
    has rerr: str = "";

    name = str(job.name);

    async def loadRuns() {
        r = root spawn api_cron_runs(name=name);
        m: any = r.reports[0] if r.reports else None;
        runsLoaded = True;
        if m and (not m.error) { runs = sorted(list(m), key=_byStart, reverse=True); rerr = ""; }
        elif m { rerr = str(m.error); }
        else { rerr = "no response from Sigil"; }
    }

    def flipHistory(e: MouseEvent) {
        nxt = not showRuns;
        showRuns = nxt;
        if nxt { loadRuns(); }
    }

    async def runNow() {
        running = True;
        rerr = "";
        r = root spawn api_console(op="cron_run", args={"name": name});
        m: any = r.reports[0] if r.reports else None;
        running = False;
        if m and m.ok and m.ran { ran = m.ran; }
        else {
            ran = None;
            rerr = str(m.error) if (m and m.error) else "The run did not report back.";
        }
        onRan();
        if showRuns { loadRuns(); }
    }

    kind = str(job.kind);
    on = bool(job.enabled);
    nxt_ms = int(job.next_run_ms) if job.next_run_ms else 0;
    status = str(job.last_status or "pending");
    failed = status == "error";
    spent = (kind == "at") and (nxt_ms <= 0);
    tone = "";
    if on and failed { tone = "bad"; }
    elif on and (status == "ok") { tone = "ok"; }
    elif on { tone = "acc"; }
    elif spent and failed { tone = "bad"; }
    when = "";
    if spent { when = "retired after a failed run" if failed else "done"; }
    elif not on { when = "paused"; }
    elif nxt_ms <= 0 { when = "not scheduled"; }
    elif nxt_ms < nowMs() { when = "due " + fmtAgo(nxt_ms); }
    else { when = "next " + fmtAgo(nxt_ms); }
    if (kind == "at") and on and (nxt_ms > 0) { when = when + " · deletes itself after a run that finishes ok"; }
    last = "never run";
    if status == "ok" { last = "last run ok"; }
    elif failed { last = "last run failed"; }
    nruns = int(job.runs) if job.runs else 0;
    nerr = int(job.errors) if job.errors else 0;

    return <article className={"rounded-xl bg-ink-2 border px-4 py-3.5 flex flex-col gap-2 " + ("border-bad/30" if (failed and on) else "border-line") + ("" if (on or spent) else " opacity-85")}>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5">
            <span className={dotCls(tone)}></span>
            <h3 className="m-0 font-mono text-sm font-semibold break-all">{name}</h3>
            <span className="text-[13px] text-fg-2">{_cap(str(job.schedule or ""))}</span>
            {(<span className="font-mono text-[11.5px] text-faint">{str(job.spec)}</span>) if (kind == "cron") else None}
            <span className="ml-auto text-xs text-muted">{when}</span>
        </div>
        {(<p className="m-0 text-[13px] text-fg-2 break-words">{str(job.task)}</p>) if job.task else None}
        {(<div className="px-2.5 py-2 rounded-lg bg-bad/10 text-[12.5px] text-bad">
            {"The run failed, so this one-time schedule retired instead of deleting itself. History shows what it said." if spent else "The last run failed. History shows what each run said."}
        </div>) if failed else None}
        <div className="flex flex-wrap items-center gap-2 text-xs text-muted">
            <span>{last}</span>
            <span aria-hidden="true">·</span>
            <span>{_count(nruns, "run") + ", " + _count(nerr, "error")}</span>
            <span className="ml-auto flex flex-wrap items-center gap-1.5">
                <span className="inline-flex items-center gap-2 mr-1.5">
                    <Toggle on={on} label={name + " runs on its schedule"} disabled={busy or spent}
                        onToggle={lambda (v: bool) { onEnable(name, v); }}/>
                    <span className="text-fg-2">{"On" if on else "Paused"}</span>
                </span>
                <button type="button" className={BTN2_SM} disabled={running}
                    onClick={lambda (e: MouseEvent) { runNow(); }}>{"Running…" if running else "Run now"}</button>
                <button type="button" className={BTN_GHOST_SM} aria-expanded={"true" if showRuns else "false"}
                    onClick={flipHistory}>History</button>
                <button type="button" className={BTN_GHOST_SM} disabled={busy}
                    onClick={lambda (e: MouseEvent) { confirming = True; }}>Remove</button>
            </span>
        </div>
        {(<div className="flex flex-wrap items-center gap-2 px-2.5 py-2 rounded-lg bg-bad/10 border border-bad/30 text-[12.5px]">
            <span className="text-fg mr-auto">{"Remove " + name + "? It stops running, and cannot be brought back."}</span>
            <button type="button" className={BTN_BAD_SM} disabled={busy}
                onClick={lambda (e: MouseEvent) { confirming = False; onRemove(name); }}>Remove</button>
            <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { confirming = False; }}>Keep it</button>
        </div>) if confirming else None}
        {(<Spinner label="Running the task now. This takes as long as the task does."/>) if running else None}
        {(<div className={"px-2.5 py-2 rounded-lg text-[12.5px] border " + ("bg-ok/10 border-ok/25" if ran.ok else "bg-bad/10 border-bad/30")}>
            <span className={"font-medium " + ("text-ok" if ran.ok else "text-bad")}>{"Ran just now: ok" if ran.ok else "Ran just now: failed"}</span>
            {(<span className="block mt-1 text-fg-2 whitespace-pre-wrap break-words">{str(ran.summary)}</span>) if ran.summary else None}
        </div>) if (ran and (not running)) else None}
        {(<Note text={rerr} tone="bad"/>) if rerr else None}
        {if showRuns {
            <div className="flex flex-col pt-2 mt-0.5 border-t border-line">
                <span className={LABEL + " pb-1"}>Runs, newest first</span>
                {(<Spinner label="Reading the run history…"/>) if (not runsLoaded) else None}
                {(<span className="py-1 text-[12.5px] text-muted">No runs yet.</span>) if (runsLoaded and (not runs) and (not rerr)) else None}
                {for (i, r) in enumerate(runs[:20]) {
                    <div key={"r" + str(i)} className="flex gap-2.5 py-1.5 text-[12.5px]">
                        <span className={dotCls("ok" if r.ok else "bad") + " mt-1.5"}></span>
                        <span className="font-mono text-xs text-muted shrink-0 w-24">{fmtAgo(r.started_ms)}</span>
                        <span className="text-fg-2 min-w-0 break-words">{str(r.summary) if r.summary else ("ok" if r.ok else "failed")}</span>
                    </div>
                }}
                {(<span className="pt-1 text-xs text-faint">{"and " + str(len(runs) - 20) + " older runs"}</span>) if (len(runs) > 20) else None}
            </div>
        }}
    </article>;
}

def:pub AutomationsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None], refresh: Callable[[], None]) -> JsxElement {
    has jobs: list[any] = [];
    has loaded: bool = False;
    has err: str = "";
    has hooks: list[any] = [];
    has hooksLoaded: bool = False;
    has hooksErr: str = "";
    has ov: any = None;
    has busy: str = "";
    has flash: str = "";
    has flashTone: str = "ok";

    has fname: str = "";
    has ftask: str = "";
    has fkind: str = "cron";
    has fcron: str = "";
    has fevery: str = "";
    has fat: str = "";
    has fzone: str = "";
    has fzoneOther: str = "";
    has fchan: str = "";
    has fpeer: str = "";
    has saving: bool = False;
    has ferr: str = "";

    has hopen: bool = False;
    has hname: str = "";
    has hevent: str = "solve_failed";
    has hkind: str = "note";
    has haction: str = "";
    has hsaving: bool = False;
    has herr: str = "";
    has hconfirm: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    def say(text: str, tone: str) { flash = text; flashTone = tone; }

    async def loadJobs() {
        r = root spawn api_cron_list();
        m: any = r.reports[0] if r.reports else None;
        loaded = True;
        if m and (not m.error) { jobs = remember("automations.cron", list(m)); err = ""; }
        elif m { err = str(m.error); }
        else { err = "no response from Sigil"; }
    }

    async def loadHooks() {
        r = root spawn api_hooks();
        m: any = r.reports[0] if r.reports else None;
        hooksLoaded = True;
        if m and (not m.error) { hooks = remember("automations.hooks", list(m)); hooksErr = ""; }
        elif m { hooksErr = str(m.error); }
        else { hooksErr = "no response from Sigil"; }
    }

    async def loadOv() {
        m: any = await call("overview", {});
        if m and (not m.error) {
            # `scheduler` (if the overview grows it) also counts `sigil cron daemon`.
            ov = remember("automations.ov", {"daemon": bool(m.daemon or m.scheduler),
                                             "channels": list(m.channels) if m.channels else []});
        }
    }

    can with entry {
        pj: any = seen("automations.cron");
        if pj { jobs = pj; loaded = True; }
        ph: any = seen("automations.hooks");
        if ph { hooks = ph; hooksLoaded = True; }
        po: any = seen("automations.ov");
        if po { ov = po; }
        loadJobs();
        loadHooks();
        loadOv();
    }

    async def enableJob(name: str, on: bool) {
        busy = "c:" + name;
        jobs = [_withEnabled(j, on) if (str(j.name) == name) else j for j in jobs];
        r = root spawn api_cron_enable(name=name, on=on);
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        elif _isNoSuch(m) { say(str(m), "bad"); }
        elif not on { say("Paused " + name + ". It keeps its history and does not fire until you turn it back on.", "ok"); }
        else { say("Turned " + name + " back on. Its next run counts from now.", "ok"); }
        loadJobs();
        refresh();
    }

    async def removeJob(name: str) {
        busy = "c:" + name;
        r = root spawn api_cron_remove(name=name);
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        elif _isNoSuch(m) { say(str(m), "bad"); }
        else {
            jobs = [j for j in jobs if str(j.name) != name];
            say("Removed " + name + ".", "ok");
        }
        loadJobs();
        refresh();
    }

    def resetForm() {
        fname = "";
        ftask = "";
        fcron = "";
        fevery = "";
        fat = "";
        fpeer = "";
        ferr = "";
    }

    async def save() {
        n = fname.strip();
        t = ftask.strip();
        spec = "";
        tz = "";
        secs = 0;
        problem = "";
        if not n { problem = "Give the schedule a name."; }
        elif len([j for j in jobs if str(j.name) == n]) > 0 { problem = "A schedule named " + n + " already exists. Remove it first, or pick another name."; }
        elif not t { problem = "Say what Sigil should do when it fires."; }
        elif fkind == "every" {
            secs = _intervalSecs(fevery);
            if secs <= 0 { problem = "Give an interval like 90s, 10m, 6h or 1d."; }
            else { spec = str(secs); }
        } elif fkind == "at" {
            spec = _atSpec(fat);
            if not spec { problem = "Give a delay like 20m, 2h or 3d, or a date and time like 2026-10-21T18:00."; }
        } else {
            spec = _cronSpec(fcron);
            if not spec { problem = "A cron expression has five fields (six with seconds first), like 0 9 * * 1-5."; }
            tz = fzoneOther.strip() if (fzone == "other") else fzone;
        }
        if problem { ferr = problem; return; }
        ferr = "";
        saving = True;
        chan = fchan;
        if fchan and fpeer.strip() { chan = fchan + ":" + fpeer.strip(); }
        m: any = await call("cron_add", {"name": n, "kind": fkind, "spec": spec, "task": t, "tz": tz,
                                         "channel": chan, "delete_after_run": False});
        saving = False;
        if m and m.ok {
            nx = int(m.next_run_ms) if m.next_run_ms else 0;
            say("Scheduled " + n + (("; first run " + fmtAgo(nx)) if (nx > 0) else "") + ".", "ok");
            resetForm();
            loadJobs();
            refresh();
        } else {
            ferr = str(m.error) if (m and m.error) else "The schedule was not saved.";
        }
    }

    async def saveHook() {
        n = hname.strip();
        act = haction.strip();
        problem = "";
        if not n { problem = "Give the hook a name."; }
        elif (hkind != "note") and (not act) { problem = "A " + hkind + " hook needs its " + str(_action(hkind)[3]).lower() + "."; }
        elif (hkind == "webhook") and (not (act.startswith("http://") or act.startswith("https://"))) { problem = "A webhook needs an http:// or https:// URL."; }
        if problem { herr = problem; return; }
        herr = "";
        hsaving = True;
        m: any = await call("hook_add", {"name": n, "event": hevent, "kind": hkind, "action": act});
        hsaving = False;
        if m and (not m.error) {
            say(("Updated the hook " if m.updated else "Added the hook ") + n + ". It runs on " + hevent + ".", "ok");
            hname = "";
            haction = "";
            hopen = False;
            loadHooks();
        } else {
            herr = str(m.error) if (m and m.error) else "The hook was not saved.";
        }
    }

    async def enableHook(name: str, on: bool) {
        busy = "h:" + name;
        hooks = [_withEnabled(h, on) if (str(h.name) == name) else h for h in hooks];
        m: any = await call("hook_enable", {"name": name, "on": on});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        elif m and _isNoSuch(m.message) { say(str(m.message), "bad"); }
        loadHooks();
    }

    async def removeHook(name: str) {
        busy = "h:" + name;
        hconfirm = "";
        m: any = await call("hook_remove", {"name": name});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        elif m and _isNoSuch(m.message) { say(str(m.message), "bad"); }
        else {
            hooks = [h for h in hooks if str(h.name) != name];
            say("Removed the hook " + name + ".", "ok");
        }
        loadHooks();
    }

    armed = [j for j in jobs if j.enabled and (int(j.next_run_ms or 0) > 0)];
    daemonDown = bool(ov) and (not ov.daemon) and (len(armed) > 0);
    nextMs = 0;
    for j in armed {
        v = int(j.next_run_ms);
        if (nextMs == 0) or (v < nextMs) { nextMs = v; }
    }
    kicker = "Agent";
    if loaded and hooksLoaded { kicker = kicker + " · " + _count(len(jobs), "schedule") + ", " + _count(len(hooks), "hook"); }
    if nextMs > nowMs() { kicker = kicker + " · next run " + fmtAgo(nextMs); }
    chans: list[any] = list(ov.channels) if (ov and ov.channels) else [];
    actRow = _action(hkind);
    evRow = _event(hevent);

    return <div className="flex flex-col">
        <PageHead title="Automations" kicker={kicker} onAsk={ask}
            askHint="“every weekday at 9, send me a digest”" tag="automations">
            <button type="button" className={BTN} onClick={lambda (e: MouseEvent) { focusId("cron-name"); }}>
                <Icon name="plus" size={15}/>New schedule
            </button>
        </PageHead>

        <div className="px-7 pt-5.5 pb-10 flex flex-wrap gap-5 items-start">
            <div className="flex-[999_1_520px] min-w-0 flex flex-col gap-5">
                {(<Note text={flash} tone={flashTone}/>) if flash else None}

                <section aria-labelledby="sched" className="flex flex-col gap-3">
                    <h2 id="sched" className="m-0 text-[15px] font-semibold">Schedules</h2>
                    {(<Note text={"The daemon is not running, so " + ("the 1 armed schedule" if (len(armed) == 1) else ("the " + str(len(armed)) + " armed schedules")) + " will not fire. Start it in a terminal with: sigil daemon start"} tone="warn"/>) if daemonDown else None}
                    {(<Note text={err} tone="bad"/>) if err else None}
                    {(<Spinner label="Reading the schedules…"/>) if (not loaded) else None}
                    {(<Empty title="No schedules yet"
                        body="A schedule runs a task on a clock: once, every interval, or on a cron expression. Each run goes through the router like any task, so a compiled skill that fits does the work, and a task with no skill gets one compiled."/>) if (loaded and (not jobs) and (not err)) else None}
                    {for j in jobs {
                        <JobCard key={str(j.name)} job={j} busy={busy == ("c:" + str(j.name))}
                            onEnable={lambda (n: str, v: bool) { enableJob(n, v); }}
                            onRemove={lambda (n: str) { removeJob(n); }}
                            onRan={lambda { loadJobs(); }}/>
                    }}
                </section>

                <section aria-labelledby="hooks" className={CARD + " overflow-hidden"}>
                    <div className="flex flex-wrap items-center gap-2.5 px-4 py-3.5 border-b border-line">
                        <h2 id="hooks" className="m-0 text-[15px] font-semibold">Hooks</h2>
                        <span className="text-xs text-muted">When something happens, do something</span>
                        <button type="button" className={BTN2_SM + " ml-auto"} aria-expanded={"true" if hopen else "false"}
                            onClick={lambda (e: MouseEvent) { hopen = not hopen; herr = ""; }}>
                            {(<Icon name="plus" size={14}/>) if (not hopen) else None}
                            {"Close" if hopen else "Add hook"}
                        </button>
                    </div>
                    <p className="m-0 px-4 py-3 text-[12.5px] leading-relaxed text-muted border-b border-line">{HOOKS_ABOUT}</p>

                    {if hopen {
                        <div className="px-4 py-4 border-b border-line bg-ink-1 flex flex-col gap-3">
                            <div className="flex flex-wrap gap-3">
                                <label className="flex flex-col gap-1.5 text-[12.5px] text-muted flex-[1_1_160px] min-w-0">Name
                                    <input value={hname} placeholder="notify-on-failure" className={INP + " font-mono"}
                                        onChange={lambda (e: ChangeEvent) { hname = e.target.value; }}/>
                                </label>
                                <label className="flex flex-col gap-1.5 text-[12.5px] text-muted flex-[1_1_240px] min-w-0">When
                                    <select value={hevent} className={SELECT} onChange={lambda (e: ChangeEvent) { hevent = e.target.value; }}>
                                        {[<option key={str(x[0])} value={str(x[0])}>{str(x[0]) + ": " + str(x[1])}</option> for x in EVENTS]}
                                    </select>
                                </label>
                            </div>
                            <div className="flex flex-col gap-1.5">
                                <span className="text-[12.5px] text-muted">Do</span>
                                <span><Segmented label="Hook action" value={hkind} small={True}
                                    onPick={lambda (v: str) { hkind = v; herr = ""; }}
                                    options={[[a[0], a[1]] for a in ACTIONS]}/></span>
                                <span className="text-xs text-muted">{str(actRow[2])}</span>
                            </div>
                            <label className="flex flex-col gap-1.5 text-[12.5px] text-muted">{str(actRow[3])}
                                <input value={haction} placeholder={str(actRow[4])}
                                    className={INP + (" font-mono" if (hkind in ["shell", "webhook"]) else "")}
                                    onChange={lambda (e: ChangeEvent) { haction = e.target.value; }}/>
                            </label>
                            {(<span className="text-xs text-muted">{"The webhook receives " + str(evRow[2]) + ", as plain text."}</span>) if (hkind == "webhook") else None}
                            <div className="flex flex-wrap items-center gap-2">
                                <button type="button" className={BTN_SM} disabled={hsaving}
                                    onClick={lambda (e: MouseEvent) { saveHook(); }}>{"Saving…" if hsaving else "Save hook"}</button>
                                <button type="button" className={BTN_GHOST_SM}
                                    onClick={lambda (e: MouseEvent) { hopen = False; herr = ""; }}>Cancel</button>
                                <span className="text-xs text-faint">Saving under a name that exists replaces that hook.</span>
                            </div>
                            {(<Note text={herr} tone="bad"/>) if herr else None}
                        </div>
                    }}

                    {(<div className="px-4 pt-3"><Note text={hooksErr} tone="bad"/></div>) if hooksErr else None}
                    {(<div className="px-4 py-4"><Spinner label="Reading the hooks…"/></div>) if (not hooksLoaded) else None}
                    {(<div className="px-4 py-5 text-[13px] text-muted">No hooks yet. Add one to act on an event, for example to POST to a webhook when a task fails.</div>) if (hooksLoaded and (not hooks) and (not hooksErr)) else None}
                    {if hooks {
                        <div className="overflow-x-auto">
                            <table className="w-full min-w-[620px] border-collapse text-[13px]">
                                <thead>
                                    <tr className="text-left text-xs text-muted">
                                        <th scope="col" className="px-4 py-2.5 font-medium">When</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium">Do</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium text-right">Fired</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium">On</th>
                                        <th scope="col" className="px-2.5 py-2.5 pr-4 font-medium"><span className="sr-only">Remove</span></th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {for h in hooks {
                                        <tr key={str(h.name)} className="border-t border-line">
                                            <td className="px-4 py-2.5">
                                                <span className="font-mono text-[12.5px]">{str(h.event)}</span>
                                                <span className="block text-xs text-muted">{str(h.name)}</span>
                                            </td>
                                            <td className="px-2.5 py-2.5">
                                                <span className={tagCls("")}>{str(h.kind)}</span>
                                                {(<span className="ml-2 font-mono text-xs text-fg-2 break-all">{str(h.action)}</span>) if h.action else None}
                                            </td>
                                            <td className="px-2.5 py-2.5 text-right font-mono">{str(h.fired or 0)}</td>
                                            <td className="px-2.5 py-2.5">
                                                <Toggle on={bool(h.enabled)} label={"Hook " + str(h.name) + " enabled"}
                                                    disabled={busy == ("h:" + str(h.name))}
                                                    onToggle={lambda (v: bool) { enableHook(str(h.name), v); }}/>
                                            </td>
                                            <td className="px-2.5 py-2.5 pr-4 text-right whitespace-nowrap">
                                                {if hconfirm == str(h.name) {
                                                    <span className="inline-flex gap-1.5">
                                                        <button type="button" className={BTN_BAD_SM} disabled={busy == ("h:" + str(h.name))}
                                                            onClick={lambda (e: MouseEvent) { removeHook(str(h.name)); }}>Remove</button>
                                                        <button type="button" className={BTN_GHOST_SM}
                                                            onClick={lambda (e: MouseEvent) { hconfirm = ""; }}>Keep</button>
                                                    </span>
                                                } else {
                                                    <button type="button" aria-label={"Remove hook " + str(h.name)}
                                                        onClick={lambda (e: MouseEvent) { hconfirm = str(h.name); }}
                                                        className="inline-flex items-center justify-center w-7 h-7 rounded-md text-muted hover:text-bad hover:bg-ink-3 cursor-pointer">
                                                        <Icon name="x" size={14}/>
                                                    </button>
                                                }}
                                            </td>
                                        </tr>
                                    }}
                                </tbody>
                            </table>
                        </div>
                    }}
                </section>
            </div>

            <section aria-labelledby="new" className="flex-[1_1_340px] min-w-0 rounded-xl bg-ink-2 border border-line-2 p-4.5 flex flex-col gap-3.5">
                <h2 id="new" className="m-0 text-[15px] font-semibold">New schedule</h2>
                <label className="flex flex-col gap-1.5 text-[12.5px] text-muted">Name
                    <input id="cron-name" value={fname} placeholder="standup-notes" className={INP + " font-mono"}
                        onChange={lambda (e: ChangeEvent) { fname = e.target.value; }}/>
                </label>
                <div className="flex flex-col gap-1.5">
                    <label htmlFor="cron-task" className="text-[12.5px] text-muted">What should Sigil do?</label>
                    <textarea id="cron-task" rows={3} value={ftask} className={AREA}
                        placeholder="Summarise what I merged and reviewed yesterday, as three standup bullets."
                        onChange={lambda (e: ChangeEvent) { ftask = e.target.value; }}></textarea>
                    <span className="text-xs text-faint leading-relaxed">Each run goes through the router like any task, so a compiled skill that fits does the work.</span>
                </div>

                <div className="flex flex-col gap-2">
                    <span className="text-[12.5px] text-muted">When</span>
                    <span><Segmented label="Schedule kind" value={fkind} options={KINDS}
                        onPick={lambda (v: str) { fkind = v; ferr = ""; }}/></span>
                    {if fkind == "cron" {
                        <div className="flex flex-wrap gap-1.5">
                            {for p in PRESETS {
                                <button key={str(p[0])} type="button" aria-pressed={"true" if (fcron.strip() == p[0]) else "false"}
                                    onClick={lambda (e: MouseEvent) { fcron = str(p[0]); }}
                                    className={"h-7 px-2.5 rounded-full text-xs cursor-pointer border " + ("bg-acc/10 border-acc/30 text-acc" if (fcron.strip() == p[0]) else "bg-transparent border-line-2 text-fg-2 hover:text-fg")}>{p[1]}</button>
                            }}
                        </div>
                        <input aria-label="Cron expression" value={fcron} placeholder="0 9 * * 1-5" className={INP + " font-mono"}
                            onChange={lambda (e: ChangeEvent) { fcron = e.target.value; }}/>
                        <span className="text-xs text-muted leading-relaxed">Five fields: minute, hour, day of month, month, day of week (a sixth in front adds seconds). Each takes *, a number, a range like 1-5, a step like */15, or a list like 1,3,5. Months and weekdays also take names, like jan or mon.</span>
                        <label className="flex flex-col gap-1.5 text-[12.5px] text-muted">Time zone
                            <select value={fzone} className={SELECT} onChange={lambda (e: ChangeEvent) { fzone = e.target.value; }}>
                                {[<option key={"z" + str(z[0])} value={str(z[0])}>{z[1]}</option> for z in ZONES]}
                            </select>
                        </label>
                        if fzone == "other" {
                            <input aria-label="Time zone name" value={fzoneOther} placeholder="America/Detroit" className={INP + " font-mono"}
                                onChange={lambda (e: ChangeEvent) { fzoneOther = e.target.value; }}/>
                        }
                    } elif fkind == "every" {
                        <div className="flex flex-wrap gap-1.5">
                            {for p in INTERVALS {
                                <button key={str(p[0])} type="button" aria-pressed={"true" if (fevery.strip() == p[0]) else "false"}
                                    onClick={lambda (e: MouseEvent) { fevery = str(p[0]); }}
                                    className={"h-7 px-2.5 rounded-full text-xs cursor-pointer border " + ("bg-acc/10 border-acc/30 text-acc" if (fevery.strip() == p[0]) else "bg-transparent border-line-2 text-fg-2 hover:text-fg")}>{p[1]}</button>
                            }}
                        </div>
                        <input aria-label="Interval" value={fevery} placeholder="10m" className={INP + " font-mono"}
                            onChange={lambda (e: ChangeEvent) { fevery = e.target.value; }}/>
                        <span className="text-xs text-muted leading-relaxed">An interval like 90s, 10m, 6h or 1d. A bare number is seconds. The first run is one interval from now.</span>
                    } else {
                        <div className="flex flex-wrap gap-1.5">
                            {for p in SOON {
                                <button key={str(p[0])} type="button" aria-pressed={"true" if (fat.strip() == p[0]) else "false"}
                                    onClick={lambda (e: MouseEvent) { fat = str(p[0]); }}
                                    className={"h-7 px-2.5 rounded-full text-xs cursor-pointer border " + ("bg-acc/10 border-acc/30 text-acc" if (fat.strip() == p[0]) else "bg-transparent border-line-2 text-fg-2 hover:text-fg")}>{p[1]}</button>
                            }}
                        </div>
                        <input aria-label="When to run" value={fat} placeholder="20m, or 2026-10-21T18:00" className={INP + " font-mono"}
                            onChange={lambda (e: ChangeEvent) { fat = e.target.value; }}/>
                        <label className="flex flex-col gap-1.5 text-xs text-muted">or pick a date and time
                            <input type="datetime-local" className={INP}
                                onChange={lambda (e: ChangeEvent) { fat = e.target.value; }}/>
                        </label>
                        <span className="text-xs text-muted leading-relaxed">A delay (90s, 20m, 2h, 3d) or a date and time on this machine's clock. It runs once, and deletes itself after a run that finishes ok.</span>
                    }}
                </div>

                <label className="flex flex-col gap-1.5 text-[12.5px] text-muted">Send the result to
                    <select value={fchan} className={SELECT} onChange={lambda (e: ChangeEvent) { fchan = e.target.value; }}>
                        <option value="">Nowhere, just keep the run</option>
                        {[<option key={"c" + str(c.name)} value={str(c.name)}>{str(c.name) + " · " + str(c.kind)}</option> for c in chans]}
                    </select>
                </label>
                {(<label className="flex flex-col gap-1.5 text-[12.5px] text-muted">Chat or channel id
                    <input value={fpeer} placeholder="a Telegram chat id, a Slack channel id" className={INP + " font-mono"}
                        onChange={lambda (e: ChangeEvent) { fpeer = e.target.value; }}/>
                </label>) if fchan else None}
                <span className="text-xs text-faint leading-relaxed -mt-1.5">
                    {"Sigil sends the result there after a run that finishes ok." if chans else "No channels are connected, so results stay with the run. "}
                    {(<a href="#/channels" className="text-acc no-underline hover:underline">Connect a channel</a>) if ((not chans) and ov) else None}
                </span>

                <div className="flex gap-2">
                    <button type="button" className={BTN + " flex-1 h-[38px]"} disabled={saving}
                        onClick={lambda (e: MouseEvent) { save(); }}>{"Saving…" if saving else "Save schedule"}</button>
                    <button type="button" className={BTN_GHOST + " h-[38px]"} onClick={lambda (e: MouseEvent) { resetForm(); }}>Clear</button>
                </div>
                {(<Note text={ferr} tone="bad"/>) if ferr else None}
                <div className="px-3 py-2.5 rounded-[9px] bg-ink-1 border border-line text-[12.5px] text-muted leading-relaxed">You can also ask Sigil in Chat, or in the box at the top: it can set up a schedule itself.</div>
            </section>
        </div>
    </div>;
}

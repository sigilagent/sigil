"""Approvals: what Sigil may run without asking, and what is waiting on you.

The gate (src/approvals.jac) stands in front of every shell command and every
skill called as a tool. Its policy is a security mode (deny, allowlist, full),
when to ask (off, on-miss, always), and the allowlist's patterns. A command the
policy will not run on its own is queued here. The run that asked was told no;
what you decide applies the next time that command runs. Elevating opens a
bounded window in which everything runs, each one logged.

One read (the `approvals` op) fills the page. Each write is its own op:
`approve`, `approvals_policy`, `allow_add`, `allow_remove`, `elevate`,
`deescalate`.
"""

import from src.sigil_console { api_console }
import from .ui {
    PageHead, Icon, Segmented, Empty, Note, Spinner, CARD, BTN, BTN2, BTN_BAD, BTN_SM, BTN_GHOST_SM,
    INP, chip
}
import from "./console_interop.js" { seen, remember, fmtAgo, nowMs }
import from react { useEffect }

# [value, label, what it means]
glob SECURITY: list[any] = [
    ["deny", "Deny all", "Nothing gated runs: no shell command, and no skill called as a tool."],
    ["allowlist", "Allowlist", "What a pattern below matches runs. Anything else follows Ask me."],
    ["full", "Full access", "Everything runs, unless Ask me is set to Always."]
];

glob ASK: list[any] = [
    ["off", "Never", "Never ask. In Allowlist mode, a command no pattern matches is refused."],
    ["on-miss", "When no rule matches", "In Allowlist mode, a command no pattern matches waits here for you."],
    ["always", "Always", "Every command waits here first, even one a pattern or Full access would run."]
];

glob ELEVATE: list[int] = [15, 30, 60];

def _decision(s: str) -> list[str] {
    # [tone, label] for a decided approval.
    if s == "allow-once" { return ["ok", "allowed once"]; }
    if s == "used" { return ["ok", "allowed once, ran"]; }
    if s == "allow-always" { return ["ok", "always allowed"]; }
    if s == "deny" { return ["bad", "denied"]; }
    if s == "elevated-allow" { return ["warn", "ran while elevated"]; }
    return ["", s];
}

def _about(rows: list[any], value: str) -> str {
    for r in rows {
        if r[0] == value { return str(r[2]); }
    }
    return "";
}

def _suggest(cmd: str) -> str {
    # The pattern "Always allow" starts from: the first word and " *", which
    # covers the command and its arguments. A one-word command or a skill
    # (`skill:<name>`) is its own pattern, since "ls *" does not match "ls".
    c = cmd.strip();
    words = [w for w in c.split(" ") if w];
    if not words { return ""; }
    if c.startswith("skill:") or (len(words) == 1) { return str(words[0]); }
    return str(words[0]) + " *";
}

def PendingCard(item: any, busy: bool, onDecide: Callable[[str, str, str], None]) -> JsxElement {
    has always: bool = False;
    has pattern: str = "";

    cmd = str(item.cmd);
    skill = cmd.startswith("skill:");
    asked = fmtAgo(float(item.ts) * 1000) if item.ts else "";

    def openAlways(e: MouseEvent) {
        pattern = _suggest(cmd);
        always = True;
    }

    return <article className="rounded-xl border border-warn/30 bg-warn/5 p-4 flex flex-col gap-2.5">
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span className="text-xs font-medium uppercase tracking-wider text-warn">{"Skill run" if skill else "Shell command"}</span>
            {(<span className="ml-auto text-xs text-muted">{"asked " + asked}</span>) if asked else None}
        </div>
        <div className="font-mono text-[15px] text-warn bg-ink-1 rounded-lg px-3 py-2.5 break-all whitespace-pre-wrap">{cmd}</div>
        <div className="text-[12.5px] text-muted">
            {"A skill called as a tool. It did not run; allow it and the next call goes through." if skill else "It did not run. Allow it once and the next run of exactly this command goes through."}
        </div>
        {if always {
            <div className="flex flex-wrap items-center gap-2">
                <label className="flex flex-wrap items-center gap-2 text-[12.5px] text-muted">Always allow
                    <input value={pattern} className={INP + " font-mono w-[240px] max-w-full"}
                        onChange={lambda (e: ChangeEvent) { pattern = e.target.value; }}/>
                </label>
                <button type="button" className={BTN_SM} disabled={busy or (not pattern.strip())}
                    onClick={lambda (e: MouseEvent) { onDecide(cmd, "allow-always", pattern.strip()); }}>Confirm</button>
                <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { always = False; }}>Cancel</button>
            </div>
            <span className="text-xs text-faint leading-relaxed">The pattern is matched as a glob against the whole command or its first word, or as a prefix. Whatever it matches runs without asking from now on.</span>
        } else {
            <div className="flex flex-wrap items-center gap-2">
                <button type="button" className={BTN} disabled={busy}
                    onClick={lambda (e: MouseEvent) { onDecide(cmd, "allow-once", ""); }}>Allow once</button>
                <button type="button" className={BTN2} disabled={busy} onClick={openAlways}>{"Always allow this skill…" if skill else "Always allow…"}</button>
                <button type="button" className={BTN_BAD + " ml-auto"} disabled={busy}
                    onClick={lambda (e: MouseEvent) { onDecide(cmd, "deny", ""); }}>Deny</button>
            </div>
        }}
    </article>;
}

def:pub ApprovalsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None], refresh: Callable[[], None]) -> JsxElement {
    has data: any = None;
    has loaded: bool = False;
    has err: str = "";
    has busy: str = "";
    has flash: str = "";
    has flashTone: str = "ok";
    has newPat: str = "";
    has elevEnd: int = 0;
    has tick: int = 0;

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    def say(text: str, tone: str) { flash = text; flashTone = tone; }

    async def load() {
        m: any = await call("approvals", {});
        loaded = True;
        if m and (not m.error) and m.policy {
            data = remember("approvals", m);
            left = int(m.policy.elevated_ms_left) if m.policy.elevated else 0;
            end = (nowMs() + left) if (left > 0) else 0;
            elevEnd = remember("approvals.end", end);
            err = "";
        } elif m { err = str(m.error) if m.error else "Sigil sent back no policy."; }
    }

    can with entry {
        prev: any = seen("approvals");
        if prev {
            data = prev;
            loaded = True;
            pe: any = seen("approvals.end");
            elevEnd = int(pe) if pe else 0;
        }
        load();
    }

    elevOn = elevEnd > nowMs();

    # While elevated, redraw the minutes left now and then, and reload once the
    # window closes so the page stops saying it is open.
    useEffect(lambda {
        if not elevOn { return; }
        iv = setInterval(lambda {
            tick = tick + 1;
            if nowMs() >= elevEnd {
                elevEnd = 0;
                load();
            }
        }, 15000);
        return lambda { clearInterval(iv); };
    }, [elevOn]);

    async def decide(cmd: str, decision: str, pattern: str) {
        busy = cmd;
        m: any = await call("approve", {"cmd": cmd, "decision": decision, "pattern": pattern});
        busy = "";
        if m and m.ok {
            rule = str(m.rule or "");
            if decision == "allow-once" { say("Allowed once. The next run of that command goes through; after that it asks again.", "ok"); }
            elif decision == "allow-always" { say("Allowlisted " + rule + ". Whatever it matches runs without asking.", "ok"); }
            else { say("Denied. If it is tried again, it asks again.", "ok"); }
            if data {
                pend = [p for p in list(data.pending or []) if str(p.cmd) != cmd];
                hist = [{"cmd": cmd, "status": decision, "ts": nowMs() / 1000.0}] + list(data.history or []);
                pol: any = data.policy;
                if rule and pol and (rule not in list(pol.allowlist or [])) {
                    pol = {**pol, "allowlist": list(pol.allowlist or []) + [rule]};
                }
                data = {**data, "pending": pend, "history": hist, "policy": pol};
            }
        } else {
            say(str(m.error) if (m and m.error) else "The decision was not saved.", "bad");
        }
        refresh();
        load();
    }

    async def setPolicy(sec: str, askv: str) {
        busy = "policy";
        if data and data.policy {
            pol: any = data.policy;
            data = {**data, "policy": {**pol, "security": sec, "ask": askv}};
        }
        # Both settings travel together: the op fills a missing one with its default.
        m: any = await call("approvals_policy", {"security": sec, "ask": askv});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        load();
    }

    async def addPattern() {
        p = newPat.strip();
        if not p { return; }
        busy = "allow";
        m: any = await call("allow_add", {"pattern": p});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        else {
            newPat = "";
            if data and data.policy {
                pol: any = data.policy;
                cur = list(pol.allowlist or []);
                if p not in cur { data = {**data, "policy": {**pol, "allowlist": cur + [p]}}; }
            }
            say(("Already allowed: " + p) if str(m.message or "").startswith("already") else ("Allowlisted " + p + "."), "ok");
        }
        load();
    }

    async def removePattern(p: str) {
        busy = "rm:" + p;
        m: any = await call("allow_remove", {"pattern": p});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        else {
            if data and data.policy {
                pol: any = data.policy;
                data = {**data, "policy": {**pol, "allowlist": [x for x in list(pol.allowlist or []) if str(x) != p]}};
            }
            say("Removed " + p + " from the allowlist.", "ok");
        }
        load();
    }

    async def elevate(mins: int) {
        busy = "elevate";
        m: any = await call("elevate", {"minutes": mins});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        else {
            elevEnd = remember("approvals.end", nowMs() + (mins * 60000));
            say("Elevated for " + str(mins) + " minutes. Every command runs without asking, and each one is logged under Decisions.", "warn");
        }
        load();
    }

    async def drop() {
        busy = "elevate";
        m: any = await call("deescalate", {});
        busy = "";
        if m and m.error { say(str(m.error), "bad"); }
        else {
            elevEnd = remember("approvals.end", 0);
            say("Back on the policy. Commands are checked again.", "ok");
        }
        load();
    }

    policy: any = data.policy if data else None;
    security = str(policy.security) if (policy and policy.security) else "allowlist";
    askm = str(policy.ask) if (policy and policy.ask) else "on-miss";
    rules: list[any] = list(policy.allowlist) if (policy and policy.allowlist) else [];
    pending: list[any] = list(data.pending) if (data and data.pending) else [];
    history: list[any] = list(data.history) if (data and data.history) else [];
    leftMin = (int((elevEnd - nowMs()) / 60000) + 1) if elevOn else 0;
    pendingLabel = "";
    if loaded { pendingLabel = (str(len(pending)) + " waiting") if pending else "nothing waiting"; }

    return <div className="flex flex-col">
        <PageHead title="Approvals" kicker="Agent · what Sigil may run without asking" onAsk={ask}
            askHint="Ask why something needs approval" tag="approvals"/>

        <div className="px-7 pt-5.5 pb-10 flex flex-wrap gap-5 items-start">
            <div className="flex-[999_1_520px] min-w-0 flex flex-col gap-5">
                {(<Note text={flash} tone={flashTone}/>) if flash else None}
                {(<Note text={err} tone="bad"/>) if err else None}
                {(<Note text={"Elevated for about " + str(leftMin) + " more " + ("minute" if (leftMin == 1) else "minutes") + ": every command runs without asking, whatever the policy says."} tone="warn"/>) if elevOn else None}

                <section aria-labelledby="pend" className="flex flex-col gap-3">
                    <div className="flex items-center gap-2.5">
                        <h2 id="pend" className="m-0 text-[15px] font-semibold">Waiting for you</h2>
                        <span className="text-[12.5px] text-muted">{pendingLabel}</span>
                    </div>
                    {(<Spinner label="Reading the approvals…"/>) if (not loaded) else None}
                    {(<Empty title="Nothing is waiting for you"
                        body="When the policy stops a shell command or a skill call, it shows up here. The run that asked is told no; what you decide applies the next time it runs."/>) if (loaded and (not pending) and (not err)) else None}
                    {for p in pending {
                        <PendingCard key={str(p.cmd)} item={p} busy={busy == str(p.cmd)}
                            onDecide={lambda (c: str, d: str, pat: str) { decide(c, d, pat); }}/>
                    }}
                </section>

                <section aria-labelledby="audit" className={CARD + " overflow-hidden"}>
                    <div className="flex flex-wrap items-center gap-2.5 px-4 py-3.5 border-b border-line">
                        <h2 id="audit" className="m-0 text-[15px] font-semibold">Decisions</h2>
                        <span className="text-xs text-muted">your answers, and what ran while elevated, newest first</span>
                    </div>
                    {(<div className="px-4 py-5 text-[13px] text-muted">No decisions yet.</div>) if (loaded and (not history)) else None}
                    {if history {
                        <div className="overflow-x-auto">
                            <table className="w-full min-w-[560px] border-collapse text-[13px]">
                                <thead>
                                    <tr className="text-left text-xs text-muted">
                                        <th scope="col" className="px-4 py-2.5 font-medium">When</th>
                                        <th scope="col" className="px-2.5 py-2.5 font-medium">Command</th>
                                        <th scope="col" className="px-2.5 py-2.5 pr-4 font-medium">Decision</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {for (i, h) in enumerate(history) {
                                        <tr key={"h" + str(i)} className="border-t border-line">
                                            <td className="px-4 py-2.5 text-muted whitespace-nowrap">{fmtAgo(float(h.ts) * 1000) if h.ts else ""}</td>
                                            <td className="px-2.5 py-2.5 font-mono text-[12.5px] break-all">{str(h.cmd)}</td>
                                            <td className="px-2.5 py-2.5 pr-4 whitespace-nowrap"><span className={chip(_decision(str(h.status))[0])}>{_decision(str(h.status))[1]}</span></td>
                                        </tr>
                                    }}
                                </tbody>
                            </table>
                        </div>
                    }}
                </section>
            </div>

            <section aria-labelledby="pol" className={CARD + " flex-[1_1_340px] min-w-0 p-4.5 flex flex-col gap-4.5"}>
                <h2 id="pol" className="m-0 text-[15px] font-semibold">Policy</h2>

                <div className="flex flex-col gap-2">
                    <span className="text-[12.5px] text-muted">Security mode</span>
                    <span><Segmented label="Security mode" value={security} options={[[s[0], s[1]] for s in SECURITY]}
                        onPick={lambda (v: str) { if (v != security) and (busy != "policy") { setPolicy(v, askm); } }}/></span>
                    <ul className="m-0 p-0 list-none flex flex-col gap-1 text-xs">
                        {for s in SECURITY {
                            <li key={str(s[0])} className={"text-fg" if (s[0] == security) else "text-muted"}>
                                <span className="font-medium">{s[1]}</span>{": " + str(s[2])}
                            </li>
                        }}
                    </ul>
                </div>

                <div className="flex flex-col gap-2">
                    <span className="text-[12.5px] text-muted">Ask me</span>
                    <span><Segmented label="Ask me" value={askm} small={True} options={[[a[0], a[1]] for a in ASK]}
                        onPick={lambda (v: str) { if (v != askm) and (busy != "policy") { setPolicy(security, v); } }}/></span>
                    <span className="text-xs text-muted leading-relaxed">{_about(ASK, askm)}</span>
                </div>

                <div className="flex flex-col gap-2">
                    <span className="text-[12.5px] text-muted">Allowlist</span>
                    {(<span className="text-xs text-faint">No patterns yet.</span>) if (loaded and (not rules)) else None}
                    <div className="flex flex-col gap-1.5 font-mono text-[12.5px]">
                        {for r in rules {
                            <div key={str(r)} className="flex items-center gap-2 py-1.5 pl-2.5 pr-1.5 rounded-lg bg-ink-1 border border-line">
                                <span className="min-w-0 break-all">{str(r)}</span>
                                <button type="button" aria-label={"Remove " + str(r)} disabled={busy == ("rm:" + str(r))}
                                    onClick={lambda (e: MouseEvent) { removePattern(str(r)); }}
                                    className="ml-auto shrink-0 inline-flex items-center justify-center w-[26px] h-[26px] rounded-md text-muted hover:text-bad hover:bg-ink-3 cursor-pointer disabled:opacity-50">
                                    <Icon name="x" size={14}/>
                                </button>
                            </div>
                        }}
                    </div>
                    <div className="flex gap-2">
                        <input aria-label="New allowlist pattern" value={newPat} placeholder="pattern, e.g. npm test"
                            className={INP + " flex-1 font-mono"}
                            onChange={lambda (e: ChangeEvent) { newPat = e.target.value; }}
                            onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { addPattern(); } }}/>
                        <button type="button" className={BTN2} disabled={(busy == "allow") or (not newPat.strip())}
                            onClick={lambda (e: MouseEvent) { addPattern(); }}>Add</button>
                    </div>
                    <span className="text-xs text-faint leading-relaxed">A pattern is matched as a glob against the whole command (git diff *) or its first word (ls), or as a prefix. A skill is skill:name.</span>
                </div>

                <div className="flex flex-col gap-2 pt-3.5 border-t border-line">
                    {if elevOn {
                        <span className="text-[12.5px] text-warn">{"Elevated: about " + str(leftMin) + " " + ("minute" if (leftMin == 1) else "minutes") + " left"}</span>
                        <button type="button" className={BTN2} disabled={busy == "elevate"}
                            onClick={lambda (e: MouseEvent) { drop(); }}>Drop back to the policy now</button>
                        <span className="text-xs text-muted leading-relaxed">Every command runs without asking until then, whatever the policy says. Each one is logged under Decisions.</span>
                    } else {
                        <span className="text-[12.5px] text-muted">Elevate: run everything without asking for</span>
                        <div className="flex gap-2">
                            {for n in ELEVATE {
                                <button key={"e" + str(n)} type="button" className={BTN2 + " flex-1"} disabled={busy == "elevate"}
                                    onClick={lambda (e: MouseEvent) { elevate(n); }}>{str(n) + " min"}</button>
                            }}
                        </div>
                        <span className="text-xs text-muted leading-relaxed">Off now. While elevated, the policy is set aside and every command is logged under Decisions.</span>
                    }}
                </div>
            </section>
        </div>
    </div>;
}

"""MCP & tools: tools in, skills out.

Three parts. Sigil as an MCP server: the command that registers it with a
client, and every tool it serves (its own two, plus one per compiled skill),
each with the switch that edits the tool policy. The MCP servers Sigil itself
uses, whose tools reach chat and every compiled skill, with a form to add one.
And the chat agent's built-in tools, shown read-only, because the tool policy
does not gate them.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_add_mcp }
import from .ui {
    PageHead, Icon, Toggle, Note, Spinner, CARD, BTN_SM, BTN2_SM, BTN_GHOST_SM, BTN_BAD_SM, INP, SELECT, LABEL,
    LINK, chip, dotCls, tagCls
}
import from "./console_interop.js" { seen, remember, copyText }

glob TRANSPORTS: list[any] = [["stdio", "stdio"], ["http", "http"], ["sse", "sse"]];

# What Sigil's own two served tools do (src/sigil_mcp_serve.jac).
glob DOORS: dict[str, str] = {
    "sigil_solve": "Routes a task: reuses a skill that fits, compiles one when none does",
    "sigil_library": "Lists the compiled skills with their run statistics"
};

# One line per built-in group in TOOL_GROUPS (src/sigil_console.jac).
glob GROUP_ABOUT: dict[str, str] = {
    "Files": "Read, write, edit and search files in the workspace.",
    "Shell": "Run commands in the workspace, and watch or stop them.",
    "Web": "Fetch a page or search the web.",
    "Schedules": "Schedule a task, list the schedules, cancel one or run it now.",
    "Memory": "Remember a fact and recall what Sigil knows.",
    "Skills": "Compile a skill, learn one from a task, list the library and run a skill.",
    "Channels and MCP": "Call a tool on an MCP server, send a message, connect or set up a channel.",
    "Self-config": "Change the agent's models, persona and prompt mode.",
    "Docs and sub-agents": "Read Sigil's docs, and hand work to one sub-agent or several in parallel."
};

def _unreachable(s: any) -> str {
    for t in list(s.tools or []) {
        if str(t).startswith("<unreachable") { return str(t).strip("<>"); }
    }
    return "";
}

def _toolNames(s: any) -> list[str] {
    return [str(t) for t in list(s.tools or []) if not str(t).startswith("<unreachable")];
}

def _status(s: any) -> str {
    # fresh | bad | ok | warn
    if s.fresh { return "fresh"; }
    if _unreachable(s) { return "bad"; }
    return "ok" if _toolNames(s) else "warn";
}

def _clip(xs: list[any], n: int) -> list[any] {
    return [x for (i, x) in enumerate(xs) if i < n];
}

def:pub ToolsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None], refresh: Callable[[], None]) -> JsxElement {
    has served: list[any] = [];
    has servers: list[any] = [];
    has groups: list[any] = [];
    has policy: any = None;
    has command: str = "";
    has loaded: bool = False;
    has err: str = "";
    has flash: str = "";
    has flashTone: str = "ok";
    has busy: str = "";
    has confirm: str = "";
    has shown: str = "";
    has copied: bool = False;
    has nm: str = "";
    has transport: str = "stdio";
    has target: str = "";
    has argv: str = "";
    has addErr: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    def apply(m: any) {
        served = list(m.served) if m.served else [];
        servers = list(m.servers) if m.servers else [];
        groups = list(m.groups) if m.groups else [];
        policy = m.policy if m.policy else None;
        command = str(m.command or "");
    }

    async def load() {
        m: any = await call("tools", {});
        loaded = True;
        if m and (not m.error) { apply(remember("tools", m)); err = ""; }
        elif m { err = str(m.error); }
    }

    can with entry {
        prev: any = seen("tools");
        if prev { apply(prev); loaded = True; }
        load();
    }

    async def expose(sig: str, on: bool) {
        busy = sig;
        served = [({**s, "exposed": on} if (str(s.signature) == sig) else s) for s in served];
        m: any = await call("skill_expose", {"signature": sig, "on": on});
        busy = "";
        if m and m.error { flash = str(m.error); flashTone = "bad"; }
        load();
    }

    async def removeServer(name: str) {
        busy = "rm:" + name;
        m: any = await call("mcp_remove", {"name": name});
        busy = "";
        confirm = "";
        if m and (not m.error) {
            servers = [s for s in servers if str(s.name) != name];
            said = str(m.message or "");
            flash = ("Removed " + name + ".") if ((not said) or said.startswith("removed")) else said;
            flashTone = "ok";
            load();
        } else {
            flash = str(m.error) if m else "no response from Sigil";
            flashTone = "bad";
        }
    }

    async def addServer() {
        n = nm.strip();
        t = target.strip();
        if (not n) or (not t) {
            addErr = "Give the server a name and a " + ("command" if (transport == "stdio") else "URL") + ".";
            return;
        }
        extra: list[str] = [x for x in argv.split() if x] if (transport == "stdio") else [];
        if (transport == "stdio") and (not extra) and (" " in t) {
            # The whole command line went into one field: the first word is the
            # executable, the rest its arguments.
            words = [x for x in t.split() if x];
            t = words[0];
            extra = [w for (i, w) in enumerate(words) if i > 0];
        }
        busy = "add";
        addErr = "";
        r = root spawn api_add_mcp(name=n, target=t, transport=transport, args=extra);
        m: any = r.reports[0] if r.reports else None;
        busy = "";
        if m and (not m.error) {
            servers = [s for s in servers if str(s.name) != n] + [{"name": n, "transport": transport, "tools": [], "fresh": True}];
            nm = "";
            target = "";
            argv = "";
            flash = "Added " + n + ". Sigil is connecting to it to list its tools.";
            flashTone = "live";
            load();
        } else {
            addErr = str(m.error) if m else "no response from Sigil";
        }
    }

    def copyCmd(e: MouseEvent) {
        copied = bool(copyText(command));
        setTimeout(lambda { copied = False; }, 2000);
    }

    skills = [s for s in served if s.signature];
    n_exposed = len([s for s in skills if s.exposed]);
    allow: list[any] = list(policy.effective_allow) if (policy and policy.effective_allow) else [];
    deny: list[any] = list(policy.effective_deny) if (policy and policy.effective_deny) else [];
    profile = str(policy.profile) if (policy and policy.profile) else "";

    return <div className="flex flex-col">
        <PageHead title="MCP & tools" kicker="Connect · tools in, skills out" onAsk={ask}
            askHint="“add the GitHub MCP server”" tag="tools"/>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-5">
            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Note text={flash} tone={flashTone}/>) if flash else None}
            {(<Spinner label="Reading the tools and asking each MCP server for its own…"/>) if (not loaded) else None}

            <div className="flex flex-wrap gap-5 items-start">
                <section aria-labelledby="out" className="flex-[1_1_440px] min-w-0 rounded-xl bg-ink-2 border border-violet-500/30 overflow-hidden">
                    <div className="px-4.5 py-4 border-b border-line flex flex-col gap-2.5">
                        <div className="flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
                            <h2 id="out" className="m-0 text-[15px] font-semibold">Sigil as an MCP server</h2>
                            <span className="text-xs text-muted">your compiled skills, callable from other agents</span>
                        </div>
                        {if command {
                            <div className="flex items-center gap-2 pl-3 pr-1.5 py-1.5 rounded-[9px] bg-ink-1 border border-line-2">
                                <code className="flex-1 min-w-0 font-mono text-[13px] text-fg break-all">{command}</code>
                                <button type="button" className={BTN2_SM} onClick={copyCmd}>
                                    <Icon name={"check" if copied else "copy"} size={13}/>{"Copied" if copied else "Copy"}
                                </button>
                            </div>
                        }}
                        <span className="text-xs text-muted">Run it once where the client lives. Each skill shows up as <span className="font-mono">{"skill_<name>"}</span>, described by its intent.</span>
                    </div>
                    <div className="overflow-x-auto">
                        <table className="w-full min-w-[400px] border-collapse text-[13px]">
                            <thead>
                                <tr className="text-left text-xs text-muted">
                                    <th scope="col" className="px-4.5 py-2.5 font-medium">Tool</th>
                                    <th scope="col" className="px-2.5 py-2.5 pr-4.5 font-medium w-24">Exposed</th>
                                </tr>
                            </thead>
                            <tbody>
                                {for s in served {
                                    <tr key={str(s.tool)} className="border-t border-line">
                                        <td className="px-4.5 py-2.5 min-w-0">
                                            <span className="font-mono">{str(s.tool)}</span>
                                            {if s.signature {
                                                <div className="text-xs text-muted">
                                                    <a href={"#/skills/" + str(s.signature)} className="font-mono text-muted no-underline hover:text-acc">{str(s.signature)}</a>
                                                    {(" · v" + str(s.version)) if s.version else ""}
                                                </div>
                                            } else {
                                                <div className="text-xs text-muted">{DOORS[str(s.tool)] if (str(s.tool) in DOORS) else "Sigil's own tool"}</div>
                                            }}
                                        </td>
                                        <td className="px-2.5 py-2.5 pr-4.5">
                                            {if s.signature {
                                                <Toggle on={bool(s.exposed)} label={"Let MCP clients call " + str(s.tool)}
                                                    disabled={busy == str(s.signature)}
                                                    onToggle={lambda (v: bool) { expose(str(s.signature), v); }}/>
                                            } else {
                                                <Toggle on={bool(s.exposed)} label={str(s.tool) + " follows the tool policy"}
                                                    disabled={True} onToggle={lambda (v: bool) { return; }}/>
                                            }}
                                        </td>
                                    </tr>
                                }}
                            </tbody>
                        </table>
                    </div>
                    <div className="px-4.5 py-3 border-t border-line text-[12.5px] text-muted flex flex-col gap-1">
                        {if loaded and (not skills) {
                            <span>No compiled skills yet. <a href="#/compile" className={LINK + " no-underline"}>Compile one</a> and it is served here.</span>
                        } elif skills {
                            <span>{str(n_exposed) + " of " + str(len(skills)) + " skills exposed. "}<a href="#/skills" className={LINK + " no-underline"}>Library →</a></span>
                        }}
                        <span className="text-xs text-faint">Sigil's own two tools follow the tool policy and have no switch here.</span>
                    </div>
                </section>

                <section aria-labelledby="in" className={CARD + " flex-[1_1_440px] min-w-0 overflow-hidden"}>
                    <div className="px-4.5 py-4 border-b border-line flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
                        <h2 id="in" className="m-0 text-[15px] font-semibold">MCP servers Sigil uses</h2>
                        <span className="text-xs text-muted">their tools show up in chat and in compiled skills</span>
                    </div>
                    {(<div className="px-4.5 py-5 text-[13px] text-muted border-b border-line">No MCP servers yet. Add one below; its tools reach chat and every compiled skill.</div>) if (loaded and (not servers)) else None}
                    {for s in servers {
                        <div key={str(s.name)} className={"flex flex-col gap-2 px-4.5 py-3 border-b border-line" + (" bg-bad/5" if (_status(s) == "bad") else "")}>
                            <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                                <span className={dotCls("live" if (_status(s) == "fresh") else _status(s))}></span>
                                <span className="flex flex-col flex-[1_1_180px] min-w-0">
                                    <span className="font-medium truncate">{str(s.name)}</span>
                                    <span className="font-mono text-[11.5px] text-muted">{str(s.transport)}</span>
                                </span>
                                {if _status(s) == "fresh" {
                                    <span className="text-xs text-live">connecting…</span>
                                } elif _status(s) == "bad" {
                                    <span className="text-xs text-bad">not answering</span>
                                } elif _status(s) == "warn" {
                                    <span className="text-xs text-warn">no tools listed</span>
                                } else {
                                    <button type="button" className={BTN_GHOST_SM} aria-expanded={"true" if (shown == str(s.name)) else "false"}
                                        onClick={lambda (e: MouseEvent) { shown = "" if (shown == str(s.name)) else str(s.name); }}>
                                        {str(len(_toolNames(s))) + (" tool" if (len(_toolNames(s)) == 1) else " tools")}
                                    </button>
                                }}
                                {(<button type="button" className={BTN_BAD_SM} onClick={lambda (e: MouseEvent) { confirm = str(s.name); }}>Remove</button>) if (confirm != str(s.name)) else None}
                            </div>
                            {if _status(s) == "warn" {
                                <span className="text-xs text-muted">It did not answer, or none of its tools pass the tool policy.</span>
                            } elif _status(s) == "bad" {
                                <span className="text-xs text-muted break-words">{_unreachable(s)}</span>
                            }}
                            {if (shown == str(s.name)) and _toolNames(s) {
                                <div className="flex flex-wrap gap-1.5">
                                    {for t in _toolNames(s) {
                                        <span key={t} className={tagCls("")}>{t}</span>
                                    }}
                                </div>
                            }}
                            {if confirm == str(s.name) {
                                <div className="flex flex-wrap items-center gap-2 px-3 py-2.5 rounded-lg bg-bad/10 border border-bad/30 text-[12.5px]">
                                    <span className="flex-[1_1_100%] text-fg">Remove <span className="font-mono">{str(s.name)}</span>? Chat and the skills that call its tools lose them.</span>
                                    <button type="button" className={BTN_BAD_SM} disabled={busy == ("rm:" + str(s.name))}
                                        onClick={lambda (e: MouseEvent) { removeServer(str(s.name)); }}>
                                        {"Removing…" if (busy == ("rm:" + str(s.name))) else "Remove"}
                                    </button>
                                    <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { confirm = ""; }}>Cancel</button>
                                </div>
                            }}
                        </div>
                    }}
                    <form className="px-4.5 py-3.5 flex flex-col gap-2.5 bg-ink-1"
                        onSubmit={lambda (e: any) { e.preventDefault(); addServer(); }}>
                        <span className="text-[13px] font-medium">Add a server</span>
                        <div className="flex flex-wrap gap-2">
                            <input aria-label="Server name" placeholder="name" value={nm}
                                onChange={lambda (e: ChangeEvent) { nm = e.target.value; }}
                                className={INP + " flex-[1_1_110px] font-mono"}/>
                            <select aria-label="Transport" value={transport}
                                onChange={lambda (e: ChangeEvent) { transport = e.target.value; }}
                                className={SELECT + " flex-[0_1_110px]"}>
                                {[<option key={str(o[0])} value={str(o[0])}>{o[1]}</option> for o in TRANSPORTS]}
                            </select>
                            <input aria-label={"Command" if (transport == "stdio") else "URL"}
                                placeholder={"command, e.g. npx" if (transport == "stdio") else "https://…/mcp"} value={target}
                                onChange={lambda (e: ChangeEvent) { target = e.target.value; }}
                                className={INP + " flex-[3_1_200px] font-mono"}/>
                        </div>
                        {if transport == "stdio" {
                            <input aria-label="Arguments, separated by spaces" placeholder="arguments, separated by spaces, e.g. -y @modelcontextprotocol/server-github"
                                value={argv} onChange={lambda (e: ChangeEvent) { argv = e.target.value; }}
                                className={INP + " font-mono"}/>
                        }}
                        <div className="flex flex-wrap items-center gap-2.5">
                            <button type="submit" className={BTN_SM} disabled={busy == "add"}>{"Adding…" if (busy == "add") else "Add server"}</button>
                            <span className="text-xs text-muted">Once it is added, Sigil connects to it and lists its tools.</span>
                        </div>
                        {(<Note text={addErr} tone="bad"/>) if addErr else None}
                    </form>
                </section>
            </div>

            <section aria-labelledby="builtin" className={CARD + " overflow-hidden"}>
                <div className="px-4.5 py-4 border-b border-line flex flex-col gap-3">
                    <div className="flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
                        <h2 id="builtin" className="m-0 text-[15px] font-semibold">Built-in tools</h2>
                        <span className="text-xs text-muted">what the chat agent can reach for</span>
                    </div>
                    <Note tone="live" text="Built-in chat tools are always on. The tool policy only gates skill tools and what MCP clients see."/>
                    {if policy {
                        <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-[12.5px] items-baseline">
                            <dt className={LABEL}>Profile</dt>
                            <dd className="m-0 font-mono text-fg-2">{profile if profile else "none"}</dd>
                            <dt className={LABEL}>Allows</dt>
                            <dd className="m-0 flex flex-wrap gap-1">
                                {if not allow {
                                    <span className="text-fg-2">every tool not denied</span>
                                }}
                                {for a in _clip(allow, 16) { <span key={"a-" + str(a)} className={tagCls("ok")}>{str(a)}</span> }}
                                {(<span className="text-xs text-muted">{"and " + str(len(allow) - 16) + " more"}</span>) if (len(allow) > 16) else None}
                            </dd>
                            <dt className={LABEL}>Denies</dt>
                            <dd className="m-0 flex flex-wrap gap-1">
                                {if not deny {
                                    <span className="text-fg-2">nothing</span>
                                }}
                                {for d in _clip(deny, 16) { <span key={"d-" + str(d)} className={tagCls("bad")}>{str(d)}</span> }}
                                {(<span className="text-xs text-muted">{"and " + str(len(deny) - 16) + " more"}</span>) if (len(deny) > 16) else None}
                            </dd>
                        </dl>
                    }}
                </div>
                <div className="overflow-x-auto">
                    <table className="w-full min-w-[620px] border-collapse text-[13px]">
                        <thead>
                            <tr className="text-left text-xs text-muted">
                                <th scope="col" className="px-4.5 py-2.5 font-medium w-[34%]">Group</th>
                                <th scope="col" className="px-2.5 py-2.5 pr-4.5 font-medium">Tools</th>
                            </tr>
                        </thead>
                        <tbody>
                            {for g in groups {
                                <tr key={str(g.name)} className="border-t border-line align-top">
                                    <td className="px-4.5 py-3">
                                        <div className="font-medium">{str(g.name)}</div>
                                        {(<div className="text-xs text-muted">{GROUP_ABOUT[str(g.name)]}</div>) if (str(g.name) in GROUP_ABOUT) else None}
                                        {(<div className="text-xs text-muted">Every command passes your <a href="#/approvals" className={LINK + " no-underline"}>Approvals</a> policy first.</div>) if (str(g.name) == "Shell") else None}
                                    </td>
                                    <td className="px-2.5 py-3 pr-4.5">
                                        <div className="flex flex-wrap gap-1.5">
                                            {for t in list(g.tools or []) {
                                                <span key={str(t)} className={tagCls("")}>{str(t)}</span>
                                            }}
                                            {(<span className={tagCls("acc")}>{"skill_* ×" + str(len(skills))}</span>) if ((str(g.name) == "Skills") and skills) else None}
                                        </div>
                                    </td>
                                </tr>
                            }}
                        </tbody>
                    </table>
                </div>
            </section>
        </div>
    </div>;
}

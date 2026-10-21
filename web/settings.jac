"""Settings: every setting the agent has, one section at a time.

#/settings/<section> is that section (keys, models, behaviour, agent, workspace,
system); plain #/settings opens Keys & secrets. Each section fetches what it
shows the first time it opens, and shows what it saw last time at once:

- keys: the `keys` op (src/sigil_console.jac keys_overview). A value is never
  sent to the browser, only whether it is set, where from, and its last four
  characters. Saving and clearing a value run in the server process
  (`secret_save`, `secret_delete`); testing one (`secret_test`) and dropping a
  named reference (`secret_remove`) run against the graph.
- models: the `models` op (tiers, aliases, fallbacks, Claude Code mode, the
  models already pulled into a local Ollama). Each tier saves through the
  `api_configure` walker, as `configure <tier>_model <name>` does.
- behaviour, agent, workspace, system: the `system` op. Its `soul` holds the
  config values; each one saves through `api_configure`.
"""

import from src.sigil_console { api_console }
import from src.sigil { api_configure }
import from .ui {
    PageHead, Icon, Toggle, Segmented, Note, Spinner, CARD, BTN_SM, BTN2_SM, BTN_GHOST_SM, BTN_BAD_SM,
    INP, AREA, SELECT, LABEL, LINK, chip, dotCls
}
import from "./console_interop.js" { navTo, seen, remember, focusId, fmtAgo }
import from react { useEffect }

# [section, label]; "tools" leaves for the MCP & tools page, where the policy lives.
glob SECTIONS: list[any] = [
    ["agent", "Agent"],
    ["keys", "Keys & secrets"],
    ["models", "Models"],
    ["behaviour", "Behaviour"],
    ["tools", "Tool policy"],
    ["workspace", "Workspace & sandbox"],
    ["system", "System"]
];
glob SECTION_KEYS: list[str] = ["agent", "keys", "models", "behaviour", "workspace", "system"];

# [tier, label, config key, what the tier does]
glob TIERS: list[any] = [
    ["frontier", "Frontier", "frontier_model", "Compiles skills: authoring, the faithfulness check and repair. Also mutating, relearning and grading."],
    ["small", "Small", "small_model", "Runs compiled skills: the cheap by-llm slots inside each procedure."],
    ["router", "Router", "router_model", "Picks the skill for each task. Empty means it uses the small model."],
    ["chat", "Chat", "chat_model", "The chat agent and its tools. Empty means it uses the frontier model."]
];

# [model-name prefix, provider, the env var its key lives in ("" when none is needed)].
# The same prefixes keys_overview uses to say which tier needs which key.
glob PROVIDERS: list[any] = [
    ["claude-cc/", "Claude Code", ""],
    ["ollama", "Ollama", ""],
    ["openrouter/", "OpenRouter", "OPENROUTER_API_KEY"],
    ["openai/", "OpenAI", "OPENAI_API_KEY"],
    ["gpt", "OpenAI", "OPENAI_API_KEY"],
    ["chatgpt", "OpenAI", "OPENAI_API_KEY"],
    ["o1", "OpenAI", "OPENAI_API_KEY"],
    ["o3", "OpenAI", "OPENAI_API_KEY"],
    ["o4", "OpenAI", "OPENAI_API_KEY"],
    ["claude-", "Anthropic", "ANTHROPIC_API_KEY"],
    ["anthropic/", "Anthropic", "ANTHROPIC_API_KEY"],
    ["gemini", "Google Gemini", "GEMINI_API_KEY"],
    ["google/", "Google Gemini", "GEMINI_API_KEY"],
    ["zai/", "Z.ai", "ZAI_API_KEY"],
    ["glm", "Z.ai", "ZAI_API_KEY"]
];

glob PROMPT_MODES: list[any] = [
    ["full", "Full", "The ethos and recalled memory wrap every compile and run."],
    ["minimal", "Minimal", "Only the compiler's contract: no ethos, no memory."],
    ["none", "None", "The bare task, nothing around it."]
];

glob SANDBOXES: list[any] = [
    ["off", "Off", "Full host access, so Sigil can drive the tools and agents already installed here. The default."],
    ["jail", "Jail", "The file tools are confined to the workspace; a path that escapes it is refused."],
    ["docker", "Docker", "As jail, and each shell command also runs in a locked-down container."]
];

glob SUB_ON: str = "flex items-center gap-2 h-9 px-3 rounded-lg no-underline text-[13.5px] font-medium text-fg bg-ink-3";
glob SUB_OFF: str = "flex items-center gap-2 h-9 px-3 rounded-lg no-underline text-[13.5px] text-fg-2 hover:bg-ink-2 hover:text-fg";
glob GROUP: str = "px-4.5 pt-3 pb-1 border-t border-line text-[11px] font-medium tracking-wider uppercase text-faint";
glob ROW: str = "flex flex-wrap items-center gap-x-3.5 gap-y-2";
glob PILL: str = "px-1.5 py-px rounded-[5px] bg-ink-3 text-fg-2 no-underline";

def _provider(model: str) -> list[str] {
    m = str(model or "").lower();
    for p in PROVIDERS {
        if m.startswith(str(p[0])) { return [str(p[1]), str(p[2])]; }
    }
    return ["", ""];
}

def _tierTag(t: str) -> str {
    return "router" if (t == "router") else (t + " model");
}

def _dur(s: int) -> str {
    n = int(s) if s else 0;
    if n < 60 { return str(n) + "s"; }
    if n < 3600 { return str(int(n / 60)) + "m"; }
    if n < 86400 { return str(int(n / 3600)) + "h " + str(int((n % 3600) / 60)) + "m"; }
    return str(int(n / 86400)) + "d " + str(int((n % 86400) / 3600)) + "h";
}

def _threshold(v: str) -> int {
    # 0..100, or -1 when the text is not a whole number in range.
    t = str(v or "").strip();
    if (not t) or (len(t) > 3) { return -1; }
    for ch in t {
        if ch not in "0123456789" { return -1; }
    }
    n = int(t);
    return n if (n <= 100) else -1;
}

def _patchRows(rows: any, env: str, p: dict[str, any]) -> list[any] {
    src: list[any] = list(rows) if rows else [];
    return [({**r, **p} if (str(r.env) == env) else r) for r in src];
}

def _suggest(tier: str, tiers: any, aliases: dict[str, any], fallbacks: dict[str, any], local: list[any]) -> list[any] {
    # [value, label] for the tier's picker: what it uses now, what the other tiers
    # use, the aliases, this tier's fallback chain, and the local Ollama models.
    out: list[any] = [];
    vals: list[str] = [];
    cur = str(tiers[tier] or "") if tiers else "";
    if cur {
        out.append([cur, cur + " (current)"]);
        vals.append(cur);
    }
    for t in ["frontier", "small", "router", "chat"] {
        v = str(tiers[t] or "") if tiers else "";
        if v and (v not in vals) {
            out.append([v, v + " (" + t + " tier)"]);
            vals.append(v);
        }
    }
    for (k, target) in aliases.items() {
        if str(k) not in vals {
            out.append([str(k), str(k) + " → " + str(target) + " (alias)"]);
            vals.append(str(k));
        }
    }
    for fb in str(fallbacks.get(tier) or "").split(",") {
        f = fb.strip();
        if f and (f not in vals) {
            out.append([f, f + " (fallback)"]);
            vals.append(f);
        }
    }
    for lm in local {
        v2 = str(lm);
        if v2 and (v2 not in vals) {
            out.append([v2, v2]);
            vals.append(v2);
        }
    }
    return out;
}

def:pub SettingsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None], refresh: Callable[[], None]) -> JsxElement {
    has kdata: any = None;
    has mdata: any = None;
    has sysv: any = None;
    has kerr: str = "";
    has merr: str = "";
    has serr: str = "";
    has fetched: dict[str, bool] = {};
    has busy: str = "";
    has note: str = "";
    has noteTone: str = "ok";
    has editing: str = "";
    has draft: str = "";
    has tests: dict[str, any] = {};
    has drafts: dict[str, str] = {};
    has edits: dict[str, str] = {};
    has nsName: str = "";
    has nsEnv: str = "";
    has nsVal: str = "";

    raw = str(route[1]) if (len(route) > 1) else "keys";
    sec = raw if (raw in SECTION_KEYS) else "keys";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def configure(key: str, val: str) -> str {
        # "" when the change took, else why it did not.
        r = root spawn api_configure(key=key, value=val);
        m: any = r.reports[0] if r.reports else None;
        if not m { return "no response from Sigil"; }
        if m.error { return str(m.error); }
        said = str(m);
        if said.startswith("unknown key") or ("must be one of" in said) { return said; }
        return "";
    }

    async def loadKeys() {
        m: any = await call("keys", {});
        if m and (not m.error) { kdata = remember("settings.keys", m); kerr = ""; }
        elif m { kerr = str(m.error); }
    }

    async def loadModels() {
        m: any = await call("models", {});
        if m and (not m.error) { mdata = remember("settings.models", m); merr = ""; }
        elif m { merr = str(m.error); }
    }

    async def loadSystem() {
        m: any = await call("system", {});
        if m and (not m.error) { sysv = remember("settings.system", m); serr = ""; }
        elif m { serr = str(m.error); }
    }

    def loadOp(op: str) {
        if op == "keys" { loadKeys(); }
        elif op == "models" { loadModels(); }
        else { loadSystem(); }
    }

    can with entry {
        pk: any = seen("settings.keys");
        if pk { kdata = pk; }
        pm: any = seen("settings.models");
        if pm { mdata = pm; }
        ps: any = seen("settings.system");
        if ps { sysv = ps; }
    }

    # Fetch a section's data the first time it opens on this visit. Models also
    # wants the keys, to say whether each tier's provider key is set.
    useEffect(lambda {
        want = "keys" if (sec == "keys") else ("models" if (sec == "models") else "system");
        nf: dict[str, bool] = {**fetched};
        if want not in fetched {
            nf[want] = True;
            loadOp(want);
        }
        if (want == "models") and ("keys" not in fetched) {
            nf["keys"] = True;
            loadOp("keys");
        }
        fetched = nf;
        note = "";
    }, [sec]);

    def say(text: str, tone: str) {
        note = text;
        noteTone = tone;
    }

    def openSection(s: str) { navTo("/settings/" + s); }

    # --- keys -------------------------------------------------------------
    def patchKey(env: str, p: dict[str, any]) {
        if not kdata { return; }
        kdata = {**kdata, "models": _patchRows(kdata.models, env, p), "search": _patchRows(kdata.search, env, p),
                 "channels": _patchRows(kdata.channels, env, p), "other": _patchRows(kdata.other, env, p)};
    }

    def startEdit(env: str) {
        editing = env;
        draft = "";
        focusId("kv-" + env);
    }

    def stopEdit() {
        editing = "";
        draft = "";
    }

    def typeDraft(v: str) { draft = v; }

    async def saveKey(env: str) {
        v = draft;
        if (not v.strip()) or (busy != "") { return; }
        busy = "save:" + env;
        m: any = await call("secret_save", {"env": env, "value": v, "name": ""});
        busy = "";
        if m and m.ok {
            editing = "";
            draft = "";
            patchKey(env, {"set": bool(m.set), "source": str(m.source or ""), "tail": str(m.tail or "")});
            tests = {**tests, (env): None};
            say(env + " saved to the secrets file.", "ok");
            loadKeys();
        } else { say(str(m.error) if m else "Sigil did not answer.", "bad"); }
    }

    def keyIn(e: any, env: str) {
        if e.key == "Enter" { saveKey(env); }
        elif e.key == "Escape" { stopEdit(); }
    }

    async def testKey(env: str) {
        busy = "test:" + env;
        m: any = await call("secret_test", {"env": env});
        busy = "";
        tests = {**tests, (env): (m if m else {"ok": False, "detail": "Sigil did not answer"})};
    }

    async def clearKey(env: str) {
        busy = "clear:" + env;
        m: any = await call("secret_delete", {"env": env, "name": ""});
        busy = "";
        if m and m.ok {
            if not m.set { patchKey(env, {"set": False, "source": "", "tail": ""}); }
            tests = {**tests, (env): None};
            say((env + " removed from the secrets file.") if m.removed else (env + " was not in the secrets file."), "ok");
            loadKeys();
        } else { say(str(m.error) if m else "Sigil did not answer.", "bad"); }
    }

    async def removeRef(name: str) {
        busy = "rm:" + name;
        m: any = await call("secret_remove", {"name": name});
        busy = "";
        if m and m.ok {
            if kdata { kdata = {**kdata, "other": [r for r in list(kdata.other or []) if str(r.name) != name]}; }
            said = str(m.message or "");
            say(("Removed the name " + name + ". Its value, if any, is still where it was.") if said.startswith("removed") else said, "ok");
            loadKeys();
        } else { say(str(m.error) if m else "Sigil did not answer.", "bad"); }
    }

    async def addNamed() {
        nm = nsName.strip();
        ev = nsEnv.strip();
        if not ev { ev = nm.upper().replace("-", "_").replace(" ", "_"); }
        if not nm { say("Give the secret a name.", "bad"); return; }
        busy = "add";
        m: any = await call("secret_save", {"name": nm, "env": ev, "value": nsVal});
        busy = "";
        if m and m.ok {
            nsName = "";
            nsEnv = "";
            nsVal = "";
            if m.stored { say("Saved " + nm + " as " + ev + ", with its value in the secrets file.", "ok"); }
            elif m.set { say("Saved " + nm + " as " + ev + ". Sigil reads its value from your shell.", "ok"); }
            else { say("Saved the name " + nm + ", but " + ev + " is not set yet. Set it below or export it in your shell.", "warn"); }
            loadKeys();
        } else { say(str(m.error) if m else "Sigil did not answer.", "bad"); }
    }

    # --- models -----------------------------------------------------------
    def pickTier(tier: str, v: str) { drafts = {**drafts, (tier): v}; }

    async def saveTier(tier: str, key: str, val: str) {
        if (not val) or (busy != "") { return; }
        busy = "tier:" + tier;
        why = await configure(key, val);
        busy = "";
        if why { say(why, "bad"); }
        else {
            say("The " + tier + " tier now uses " + val + ", from the next run.", "ok");
            if mdata and mdata.configured { mdata = {**mdata, "configured": {**mdata.configured, (tier): val}}; }
            elif mdata and mdata.tiers { mdata = {**mdata, "tiers": {**mdata.tiers, (tier): val}}; }
            drafts = {**drafts, (tier): val};
        }
        loadModels();
    }

    # --- soul fields (behaviour, agent, workspace) ------------------------
    def typeEdit(key: str, v: str) { edits = {**edits, (key): v}; }

    async def saveSoul(key: str, val: str, shown: any, label: str) {
        if busy != "" { return; }
        busy = "cfg:" + key;
        if sysv and sysv.soul { sysv = {**sysv, "soul": {**sysv.soul, (key): shown}}; }
        why = await configure(key, val);
        busy = "";
        if why { say(why, "bad"); }
        else {
            say(label + " saved.", "ok");
            edits = {**edits, (key): val};
        }
        loadSystem();
    }

    # ======================================================================
    # What each part draws
    # ======================================================================
    soul: any = sysv.soul if sysv else None;
    mrows_all: list[any] = list(kdata.models or []) if kdata else [];
    missing = 0;
    if kdata {
        for r in mrows_all {
            if r.used_by and (len(r.used_by) > 0) and (not r.set) { missing += 1; }
        }
        for r2 in list(kdata.channels or []) {
            if r2.used_by and (len(r2.used_by) > 0) and (not r2.set) { missing += 1; }
        }
    }

    def fieldVal(key: str, fallback: str) -> str {
        return str(edits[key]) if (key in edits) else fallback;
    }

    def keyRow(row: any, group: str) -> JsxElement {
        env = str(row.env);
        src = str(row.source or "");
        isSet = bool(row.set);
        used: list[any] = list(row.used_by) if row.used_by else [];
        needed = len(used) > 0;
        tr: any = tests[env] if (env in tests) else None;
        inUse = (group == "search") and kdata and (str(kdata.search_active or "") == str(row.label));
        return <div key={group + ":" + env + ":" + str(row.name or "")} className={"flex flex-col gap-2 px-4.5 py-2.5" + (" bg-bad/5" if (needed and (not isSet)) else "")}>
            <div className={ROW}>
                <span className="flex-[1_1_200px] min-w-0 flex flex-col gap-px">
                    <span className="flex items-center gap-2 text-[13.5px] font-medium">
                        {str(row.label)}
                        {(<span className="px-1.5 py-px rounded-[5px] text-[11px] font-medium text-acc bg-acc/15">in use</span>) if inUse else None}
                    </span>
                    <span className="font-mono text-xs text-muted break-all">{env}</span>
                </span>
                <span className="flex-[1_1_200px] min-w-0 flex flex-wrap items-center gap-1.5 text-xs text-muted">
                    {if tr {
                        <span className={"text-ok" if tr.ok else "text-bad"}>{("✓ " if tr.ok else "") + str(tr.detail or tr.error or "")}</span>
                    } elif (group == "models") and needed {
                        <span>used by</span>
                        for t in used { <span key={str(t)} className={PILL}>{_tierTag(str(t))}</span> }
                    } elif (group == "channels") and needed {
                        <span>{"used by" if isSet else "needed by"}</span>
                        for cn in used { <a key={str(cn)} href="#/channels" className={PILL + " text-acc"}>{str(cn)}</a> }
                    } elif group == "search" {
                        <span>{str(row.about or "")}</span>
                    } elif group == "other" {
                        <span>referred to as <span className="font-mono text-fg-2">{"secret:" + str(row.name)}</span></span>
                    } else {
                        <span>not used yet</span>
                    }}
                </span>
                <span className="flex-[0_0_180px] flex items-center gap-2">
                    {if src == "console" {
                        <span className={chip("ok")} title={"Saved from the console in the secrets file"}>Set from console</span>
                    } elif src == "shell" {
                        <span className={chip("ok")} title={"Exported in your shell, which wins over the secrets file"}>Set in shell</span>
                    } else {
                        <span className={chip("bad" if needed else "")}>Not set</span>
                    }}
                    {(<span className="font-mono text-xs text-fg-2">{"…" + str(row.tail)}</span>) if row.tail else None}
                </span>
                <span className="flex flex-wrap items-center gap-1.5">
                    {(<button type="button" className={BTN2_SM} disabled={busy != ""}
                        onClick={lambda (e: MouseEvent) { testKey(env); }}>{"Testing…" if (busy == ("test:" + env)) else "Test"}</button>) if isSet else None}
                    <button type="button" className={BTN_GHOST_SM if isSet else (BTN_SM if needed else BTN2_SM)} disabled={busy != ""}
                        onClick={lambda (e: MouseEvent) { startEdit(env); }}>{"Replace" if isSet else "Set key"}</button>
                    {(<button type="button" className={BTN_BAD_SM} disabled={busy != ""}
                        onClick={lambda (e: MouseEvent) { clearKey(env); }}>{"Clearing…" if (busy == ("clear:" + env)) else "Clear"}</button>) if (src == "console") else None}
                    {(<span className="text-xs text-faint cursor-help"
                        title={"Sigil can only clear a value it saved. This one is exported in your shell: unset it there."}>clear it in your shell</span>) if (src == "shell") else None}
                    {(<button type="button" className={BTN_GHOST_SM} disabled={busy != ""}
                        title={"Forget the name. The value stays where it is."}
                        onClick={lambda (e: MouseEvent) { removeRef(str(row.name)); }}>{"Removing…" if (busy == ("rm:" + str(row.name))) else "Remove"}</button>) if (group == "other") else None}
                </span>
            </div>
            {(<div className="flex flex-wrap items-center gap-2">
                <input id={"kv-" + env} type="password" autoComplete="off" value={draft} aria-label={"New value for " + env}
                    placeholder={"Paste the value of " + env}
                    onChange={lambda (e: ChangeEvent) { typeDraft(e.target.value); }}
                    onKeyDown={lambda (e: KeyboardEvent) { keyIn(e, env); }}
                    className={INP + " flex-[1_1_260px] font-mono"}/>
                <button type="button" className={BTN_SM} disabled={(not draft.strip()) or (busy != "")}
                    onClick={lambda (e: MouseEvent) { saveKey(env); }}>{"Saving…" if (busy == ("save:" + env)) else "Save"}</button>
                <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { stopEdit(); }}>Cancel</button>
                {(<span className="basis-full text-xs text-muted">{"Your shell exports " + env + ", and the shell's value wins whenever Sigil starts. Change it there to change it everywhere."}</span>) if (src == "shell") else None}
            </div>) if (editing == env) else None}
        </div>;
    }

    def keylessRow(rid: str, label: str, sub: str, tiers: list[any], status: str) -> JsxElement {
        return <div key={rid} className={ROW + " px-4.5 py-2.5"}>
            <span className="flex-[1_1_200px] min-w-0 flex flex-col gap-px">
                <span className="text-[13.5px] font-medium">{label}</span>
                <span className="font-mono text-xs text-muted">{sub}</span>
            </span>
            <span className="flex-[1_1_200px] min-w-0 flex flex-wrap items-center gap-1.5 text-xs text-muted">
                <span>used by</span>
                {[<span key={str(t)} className={PILL}>{_tierTag(str(t))}</span> for t in tiers]}
            </span>
            <span className="flex-[0_0_180px]"><span className={chip("")}>{status}</span></span>
        </div>;
    }

    def loading(err: str, label: str) -> JsxElement {
        return <section className={CARD + " p-4.5 flex flex-col gap-2"}>
            {(<Note text={err} tone="bad"/>) if err else (<Spinner label={label}/>)}
        </section>;
    }

    def keysCard() -> JsxElement {
        if not kdata { return loading(kerr, "Reading your keys…"); }
        mrows: list[any] = list(kdata.models or []);
        srows: list[any] = list(kdata.search or []);
        crows: list[any] = list(kdata.channels or []);
        orows: list[any] = list(kdata.other or []);
        ltiers: list[any] = list(kdata.local_tiers or []);
        ctiers: list[any] = list(kdata.claude_code_tiers or []);
        active = str(kdata.search_active or "");
        return <section aria-labelledby="kh" className={CARD + " overflow-hidden"}>
            <div className="px-4.5 py-4 flex flex-col gap-1">
                <h2 id="kh" className="m-0 text-[15px] font-semibold">Keys &amp; secrets</h2>
                <span className="text-[12.5px] text-muted leading-relaxed">
                    {"Values are kept in "}<span className="font-mono text-fg-2 break-all">{str(kdata.file)}</span>
                    {" (0600, readable by you alone), never on the graph. A value exported in your shell wins over the file."}
                </span>
            </div>

            <div className={GROUP}>Model providers</div>
            {[keyRow(r, "models") for r in mrows]}
            {(keylessRow("ollama", "Ollama", "no key · runs on this machine", ltiers, "No key needed")) if ltiers else None}
            {(keylessRow("claude-cc", "Claude Code", "no key · your Claude Code sign-in", ctiers, "No key needed")) if ctiers else None}

            <div className={ROW + " px-4.5 pt-3 pb-1 border-t border-line"}>
                <span className="text-[11px] font-medium tracking-wider uppercase text-faint">Web search</span>
                <span className="text-xs text-muted">for the <span className="font-mono text-fg-2">web_search</span> tool; <span className="font-mono text-fg-2">web_fetch</span> needs no key</span>
                <span className={"ml-auto " + chip("acc" if active else "warn")}>{("In use: " + active) if active else "None set up"}</span>
            </div>
            <div className="px-4.5 pt-1 text-xs text-muted">Sigil tries Brave first, then Firecrawl, then Claude Code's own search when it runs with <span className="font-mono">--claude</span>.</div>
            {(<div className="px-4.5 pt-2"><Note text="No search provider is set up, so web_search answers with setup steps. Add a Brave or Firecrawl key, or run Sigil with --claude." tone="warn"/></div>) if (not active) else None}
            {[keyRow(r, "search") for r in srows]}
            <div className={ROW + " px-4.5 py-2.5"}>
                <span className="flex-[1_1_200px] min-w-0 flex flex-col gap-px">
                    <span className="flex items-center gap-2 text-[13.5px] font-medium">
                        Claude Code web search
                        {(<span className="px-1.5 py-px rounded-[5px] text-[11px] font-medium text-acc bg-acc/15">in use</span>) if (active == "Claude Code") else None}
                    </span>
                    <span className="font-mono text-xs text-muted">no key · only with sigil --claude</span>
                </span>
                <span className="flex-[1_1_200px] min-w-0 text-xs text-muted">uses your Claude Code sign-in for each search</span>
                <span className="flex-[0_0_180px]">
                    <span className={chip("ok" if kdata.claude_search else "")}>{"Ready" if kdata.claude_search else "Off"}</span>
                </span>
            </div>

            {(<div className={GROUP}>Channels</div>) if crows else None}
            {[keyRow(r, "channels") for r in crows]}

            <div className={GROUP}>Other secrets</div>
            {(<div className="px-4.5 py-2.5 text-[12.5px] text-muted">No named secrets yet. A channel or MCP server refers to one as <span className="font-mono">secret:&lt;name&gt;</span>, and Sigil resolves it from the environment when it runs.</div>) if (not orows) else None}
            {[keyRow(r, "other") for r in orows]}

            <div id="add-secret" className="px-4.5 pt-3.5 pb-4 border-t border-line bg-ink-1 flex flex-col gap-2.5">
                <span className="text-[13px] font-medium">Add a named secret</span>
                <div className="flex flex-wrap gap-2">
                    <input value={nsName} aria-label="Secret name" placeholder="name, e.g. notion"
                        onChange={lambda (e: ChangeEvent) { nsName = e.target.value; }}
                        className={INP + " flex-[1_1_160px] font-mono"}/>
                    <input value={nsEnv} aria-label="Environment variable" placeholder="ENV VAR, e.g. NOTION_TOKEN"
                        onChange={lambda (e: ChangeEvent) { nsEnv = e.target.value; }}
                        className={INP + " flex-[1_1_200px] font-mono"}/>
                    <input value={nsVal} type="password" autoComplete="off" aria-label="Secret value" placeholder="value"
                        onChange={lambda (e: ChangeEvent) { nsVal = e.target.value; }}
                        className={INP + " flex-[2_1_220px] font-mono"}/>
                    <button type="button" className={BTN_SM + " h-9"} disabled={(busy != "") or (not nsName.strip())}
                        onClick={lambda (e: MouseEvent) { addNamed(); }}>{"Saving…" if (busy == "add") else "Save"}</button>
                </div>
                <span className="text-xs text-muted">Already exported in your shell? Leave the value empty: Sigil reads it from the environment. With no variable given, it uses the name in capitals.</span>
            </div>
        </section>;
    }

    def tierStatus(model: str, aliases: dict[str, any], local: list[any]) -> JsxElement {
        target = str(aliases[model]) if (model in aliases) else model;
        pv = _provider(target);
        name = pv[0];
        env = pv[1];
        if not target { return <span className="text-xs text-muted">No model set</span>; }
        if name == "Claude Code" { return <span className="text-xs text-ok">✓ Claude Code sign-in, no key</span>; }
        if name == "Ollama" {
            if target in local { return <span className="text-xs text-ok">✓ local, pulled in Ollama</span>; }
            if local { return <span className="text-xs text-warn">local, but not pulled in this Ollama</span>; }
            return <span className="text-xs text-warn">local; no Ollama models found on this machine</span>;
        }
        if not name {
            return <span className="text-xs text-muted">Provider not recognised: Sigil passes the name to litellm as is. Check its key on <a href="#/settings/keys" className={LINK + " no-underline"}>Keys</a>.</span>;
        }
        row: any = None;
        for r in mrows_all {
            if str(r.env) == env { row = r; }
        }
        if row and row.set { return <span className="text-xs text-ok">{"✓ " + name + " key set (" + env + ")"}</span>; }
        if row {
            return <span className="text-xs text-bad">{name + " key not set. "}<a href="#/settings/keys" className={LINK + " no-underline"}>{"Add " + env}</a></span>;
        }
        return <span className="text-xs text-muted">{"Needs " + env + ". "}<a href="#/settings/keys" className={LINK + " no-underline"}>Check on Keys</a></span>;
    }

    def modelsCard() -> JsxElement {
        if not mdata { return loading(merr, "Reading the model tiers…"); }
        # What each tier is saved as; in claude mode `tiers` is what it runs as.
        tiers: any = mdata.configured if mdata.configured else mdata.tiers;
        running: any = mdata.tiers;
        aliases: dict[str, any] = dict(mdata.aliases or {});
        fallbacks: dict[str, any] = dict(mdata.fallbacks or {});
        local: list[any] = list(mdata.local or []);
        return <section aria-labelledby="mh" className={CARD + " overflow-hidden"}>
            <div className="px-4.5 py-4 border-b border-line flex flex-col gap-1">
                <h2 id="mh" className="m-0 text-[15px] font-semibold">Models</h2>
                <span className="text-[12.5px] text-muted">A frontier model compiles each skill once. Small models run the compiled skills from then on.</span>
            </div>
            {(<div className="px-4.5 pt-3.5"><Note tone="live"
                text="Claude Code mode is on: every tier runs through your Claude Code sign-in, as shown under each one. A model you save here is used when Sigil runs without --claude."/></div>) if mdata.claude_mode else None}
            {for tr in TIERS {
                <div key={str(tr[0])} className={ROW + " items-start px-4.5 py-3.5 border-b border-line"}>
                    <div className="flex-[1_1_220px] min-w-0 flex flex-col gap-0.5">
                        <span className="text-[13.5px] font-medium">{str(tr[1])}</span>
                        <span className="text-xs text-muted leading-relaxed">{str(tr[3])}</span>
                        <span className="font-mono text-[11.5px] text-faint">{str(tr[2])}</span>
                    </div>
                    <div className="flex-[2_1_320px] min-w-0 flex flex-col gap-1.5">
                        <div className="flex flex-wrap items-center gap-2">
                            <select aria-label={"Suggested models for the " + str(tr[0]) + " tier"}
                                value={(fieldOf(str(tr[0]), tiers)) if (fieldOf(str(tr[0]), tiers) in [str(o[0]) for o in _suggest(str(tr[0]), tiers, aliases, fallbacks, local)]) else ""}
                                onChange={lambda (e: ChangeEvent) { if e.target.value { pickTier(str(tr[0]), e.target.value); } else { focusId("model-" + str(tr[0])); } }}
                                className={SELECT + " flex-[1_1_200px] min-w-0 font-mono text-[12.5px]"}>
                                {[<option key={str(o[0])} value={str(o[0])}>{str(o[1])}</option> for o in _suggest(str(tr[0]), tiers, aliases, fallbacks, local)]}
                                <option value="">Another model (type it)</option>
                            </select>
                            <input id={"model-" + str(tr[0])} value={fieldOf(str(tr[0]), tiers)} aria-label={str(tr[1]) + " model"}
                                placeholder="e.g. gpt-5 or ollama_chat/qwen3:8b"
                                onChange={lambda (e: ChangeEvent) { pickTier(str(tr[0]), e.target.value); }}
                                className={INP + " flex-[1_1_200px] font-mono text-[12.5px]"}/>
                            <button type="button" className={BTN_SM + " h-9"}
                                disabled={(busy != "") or (not fieldOf(str(tr[0]), tiers).strip()) or (fieldOf(str(tr[0]), tiers).strip() == str(tiers[str(tr[0])] or ""))}
                                onClick={lambda (e: MouseEvent) { saveTier(str(tr[0]), str(tr[2]), fieldOf(str(tr[0]), tiers).strip()); }}>
                                {"Saving…" if (busy == ("tier:" + str(tr[0]))) else "Save"}
                            </button>
                        </div>
                        {tierStatus(fieldOf(str(tr[0]), tiers).strip(), aliases, local)}
                        {(<span className="text-xs text-live font-mono">{"runs as " + str(running[str(tr[0])])}</span>) if (mdata.claude_mode and running and (str(running[str(tr[0])] or "") != str(tiers[str(tr[0])] or ""))) else None}
                    </div>
                </div>
            }}
            {(<div className={ROW + " px-4.5 py-3.5 border-b border-line"}>
                <span className="flex-[1_1_300px] flex flex-col gap-0.5">
                    <span className="text-[13.5px] font-medium">Run every tier through Claude Code</span>
                    <span className="text-[12.5px] text-muted">Off. Start Sigil with <span className="font-mono">sigil --claude</span> to use your Claude Code sign-in instead of API keys.</span>
                </span>
                <span className={chip("")}>off</span>
            </div>) if (not mdata.claude_mode) else None}
            <div className="px-4.5 py-3.5 flex flex-wrap gap-6 text-[13px]">
                <div className="flex-[1_1_240px] flex flex-col gap-1.5">
                    <span className="text-[12.5px] text-muted">Aliases</span>
                    <div className="flex flex-wrap gap-1.5 font-mono text-xs">
                        {[<span key={str(a[0])} className="px-2 py-0.5 rounded-md bg-ink-3">{str(a[0]) + " → " + str(a[1])}</span> for a in aliases.items()]}
                        {(<span className="font-sans text-muted">None. <span className="font-mono">sigil models alias fast gpt-4o-mini</span> adds one.</span>) if (not aliases) else None}
                    </div>
                </div>
                <div className="flex-[1_1_240px] flex flex-col gap-1.5">
                    <span className="text-[12.5px] text-muted">Fallbacks</span>
                    <div className="flex flex-wrap gap-1.5 font-mono text-xs">
                        {[<span key={str(f[0])} className="px-2 py-0.5 rounded-md bg-ink-3">{str(f[0]) + " → " + str(f[1])}</span> for f in fallbacks.items()]}
                        {(<span className="font-sans text-muted">None. <span className="font-mono">sigil models fallback chat gpt-4o-mini</span> adds a chain.</span>) if (not fallbacks) else None}
                    </div>
                </div>
            </div>
        </section>;
    }

    def fieldOf(tier: str, tiers: any) -> str {
        return str(drafts[tier]) if (tier in drafts) else (str(tiers[tier] or "") if tiers else "");
    }

    def behaviourCard() -> JsxElement {
        if not soul { return loading(serr, "Reading the agent's settings…"); }
        thr = fieldVal("eval_threshold", str(soul.eval_threshold));
        thrN = _threshold(thr);
        pm = str(soul.prompt_mode or "full");
        pmAbout = "";
        for p in PROMPT_MODES {
            if str(p[0]) == pm { pmAbout = str(p[2]); }
        }
        return <section aria-labelledby="bh" className={CARD + " px-4.5 py-4 flex flex-col gap-4"}>
            <h2 id="bh" className="m-0 text-[15px] font-semibold">Behaviour</h2>
            <div className={ROW + " gap-3"}>
                <span className="flex-[1_1_300px] flex flex-col gap-0.5">
                    <span className="text-[13.5px] font-medium">Grade every solve</span>
                    <span className="text-[12.5px] text-muted">The frontier model scores each result. Below the threshold, Sigil relearns the skill and tries again.</span>
                </span>
                <Toggle on={bool(soul.auto_eval)} label="Grade every solve" disabled={busy != ""}
                    onToggle={lambda (v: bool) { saveSoul("auto_eval", "true" if v else "false", v, "Grading"); }}/>
            </div>
            <div className={ROW + " gap-3 text-[13px]"}>
                <label htmlFor="eval-threshold" className="flex-[0_0_160px] text-fg-2">Relearn below</label>
                <input id="eval-threshold" type="number" min="0" max="100" step="1" value={thr}
                    onChange={lambda (e: ChangeEvent) { typeEdit("eval_threshold", e.target.value); }}
                    className={INP + " w-24 font-mono"}/>
                <button type="button" className={BTN2_SM}
                    disabled={(busy != "") or (thrN < 0) or (thr.strip() == str(soul.eval_threshold))}
                    onClick={lambda (e: MouseEvent) { saveSoul("eval_threshold", str(thrN), thrN, "Relearn threshold"); }}>
                    {"Saving…" if (busy == "cfg:eval_threshold") else "Save"}
                </button>
                <span className={"text-xs " + ("text-bad" if (thrN < 0) else "text-muted")}>{"A whole number from 0 to 100." if (thrN < 0) else "A graded run that scores below this relearns its skill."}</span>
            </div>
            <div className={ROW + " gap-3 text-[13px]"}>
                <span className="flex-[0_0_160px] text-fg-2">System prompt</span>
                <Segmented label="System prompt" value={pm} options={[[str(p[0]), str(p[1])] for p in PROMPT_MODES]}
                    onPick={lambda (v: str) { if v != pm { saveSoul("prompt_mode", v, v, "System prompt"); } }}/>
                <span className="flex-[1_1_220px] text-xs text-muted">{pmAbout}</span>
            </div>
        </section>;
    }

    def agentCard() -> JsxElement {
        if not soul { return loading(serr, "Reading the agent's settings…"); }
        nm = fieldVal("name", str(soul.name or ""));
        per = fieldVal("persona", str(soul.persona or ""));
        ethos: list[any] = list(soul.ethos or []);
        return <section aria-labelledby="ah" className={CARD + " px-4.5 py-4 flex flex-col gap-4"}>
            <div className="flex flex-col gap-1">
                <h2 id="ah" className="m-0 text-[15px] font-semibold">Agent</h2>
                <span className="text-[12.5px] text-muted">Who the agent is. The name and persona live on the graph and take effect on the next turn.</span>
            </div>
            <div className="flex flex-col gap-1.5">
                <label htmlFor="agent-name" className="text-[13px] text-fg-2">Name</label>
                <div className="flex flex-wrap gap-2">
                    <input id="agent-name" value={nm} onChange={lambda (e: ChangeEvent) { typeEdit("name", e.target.value); }}
                        className={INP + " flex-[0_1_320px]"}/>
                    <button type="button" className={BTN2_SM + " h-9"}
                        disabled={(busy != "") or (not nm.strip()) or (nm == str(soul.name or ""))}
                        onClick={lambda (e: MouseEvent) { saveSoul("name", nm.strip(), nm.strip(), "Name"); }}>
                        {"Saving…" if (busy == "cfg:name") else "Save"}
                    </button>
                </div>
            </div>
            <div className="flex flex-col gap-1.5">
                <label htmlFor="agent-persona" className="text-[13px] text-fg-2">Persona</label>
                <textarea id="agent-persona" rows={4} value={per} onChange={lambda (e: ChangeEvent) { typeEdit("persona", e.target.value); }}
                    className={AREA + " w-full"}></textarea>
                <div className="flex flex-wrap items-center gap-2">
                    <button type="button" className={BTN2_SM}
                        disabled={(busy != "") or (not per.strip()) or (per == str(soul.persona or ""))}
                        onClick={lambda (e: MouseEvent) { saveSoul("persona", per.strip(), per.strip(), "Persona"); }}>
                        {"Saving…" if (busy == "cfg:persona") else "Save persona"}
                    </button>
                    <span className="text-xs text-muted">The voice the agent speaks with in chat and on channels.</span>
                </div>
            </div>
            <div className="flex flex-col gap-1.5">
                <span className="text-[13px] text-fg-2">Ethos</span>
                {(<span className="text-[12.5px] text-muted">No principles set.</span>) if (not ethos) else None}
                <ul className="m-0 pl-5 list-disc flex flex-col gap-1 text-[13px] leading-relaxed text-fg">
                    {[<li key={"e" + str(i)}>{str(x)}</li> for (i, x) in enumerate(ethos)]}
                </ul>
                <span className="text-xs text-muted">Operating principles that wrap every compile in full prompt mode. Add one from a terminal with <span className="font-mono">{"sigil configure add_ethos \"…\""}</span>.</span>
            </div>
        </section>;
    }

    def workspaceCard() -> JsxElement {
        if not soul { return loading(serr, "Reading the agent's settings…"); }
        ws = fieldVal("workspace", str(soul.workspace or ""));
        sb = str(soul.sandbox or "off");
        winfo: any = sysv.workspace if sysv else None;
        sbAbout = "";
        for s in SANDBOXES {
            if str(s[0]) == sb { sbAbout = str(s[2]); }
        }
        return <section aria-labelledby="wh" className={CARD + " px-4.5 py-4 flex flex-col gap-4"}>
            <div className="flex flex-col gap-1">
                <h2 id="wh" className="m-0 text-[15px] font-semibold">Workspace &amp; sandbox</h2>
                <span className="text-[12.5px] text-muted">Where the file and shell tools start, and how far they can reach.</span>
            </div>
            <div className="flex flex-col gap-1.5">
                <label htmlFor="ws-path" className="text-[13px] text-fg-2">Workspace</label>
                <div className="flex flex-wrap gap-2">
                    <input id="ws-path" value={ws} placeholder="~/.sigil/workspace" onChange={lambda (e: ChangeEvent) { typeEdit("workspace", e.target.value); }}
                        className={INP + " flex-[1_1_320px] font-mono"}/>
                    <button type="button" className={BTN2_SM + " h-9"}
                        disabled={(busy != "") or (not ws.strip()) or (ws == str(soul.workspace or ""))}
                        onClick={lambda (e: MouseEvent) { saveSoul("workspace", ws.strip(), ws.strip(), "Workspace"); }}>
                        {"Saving…" if (busy == "cfg:workspace") else "Save"}
                    </button>
                </div>
                <span className="text-xs text-muted">
                    {"Relative paths resolve here and shell jobs start here."}
                    {(" Now " + str(winfo.root) + ", " + str(winfo.items) + " items.") if winfo else ""}
                </span>
            </div>
            <div className="flex flex-col gap-1.5">
                <span className="text-[13px] text-fg-2">Sandbox</span>
                <div className="flex flex-wrap items-center gap-3">
                    <Segmented label="Sandbox" value={sb} options={[[str(s[0]), str(s[1])] for s in SANDBOXES]}
                        onPick={lambda (v: str) { if v != sb { saveSoul("sandbox", v, v, "Sandbox"); } }}/>
                    <span className="flex-[1_1_240px] text-xs text-muted">{sbAbout}</span>
                </div>
                {(<Note text="Docker is not available on this machine, so commands cannot run in a container." tone="warn"/>) if ((sb == "docker") and winfo and (not winfo.docker)) else None}
            </div>
            <div className={ROW + " gap-3"}>
                <span className="flex-[1_1_300px] flex flex-col gap-0.5">
                    <span className="text-[13.5px] font-medium">Show the model's output as it is written</span>
                    <span className="text-[12.5px] text-muted">Verbose mode streams each model call's words during a compile. <span className="font-mono">--quiet</span> turns it off for one run.</span>
                </span>
                <Toggle on={bool(soul.verbose)} label="Verbose output" disabled={busy != ""}
                    onToggle={lambda (v: bool) { saveSoul("verbose", "on" if v else "off", v, "Verbose output"); }}/>
            </div>
        </section>;
    }

    def systemCard() -> JsxElement {
        if not sysv { return loading(serr, "Reading the system state…"); }
        d: any = sysv.daemon;
        sv: any = sysv.serve;
        winfo: any = sysv.workspace;
        up = bool(d.running) if d else False;
        bridges: list[any] = list(d.bridges or []) if d else [];
        dsub = "Schedules and channel bridges need it running.";
        if up {
            dsub = "up " + _dur(int(d.uptime_s or 0)) + " · " + str(d.armed) + " of " + str(d.jobs) + " schedules armed";
            if int(d.next_due_ms or 0) > 0 { dsub = dsub + " · next " + fmtAgo(d.next_due_ms); }
            if bridges { dsub = dsub + " · bridges: " + ", ".join([str(b) for b in bridges]); }
        }
        svc = str(d.service) if d else "";
        return <section aria-labelledby="sh" className={CARD + " overflow-hidden"}>
            <div className="px-4.5 py-4 border-b border-line"><h2 id="sh" className="m-0 text-[15px] font-semibold">System</h2></div>
            <div className={ROW + " gap-x-4 px-4.5 py-3.5 border-b border-line"}>
                <span className={dotCls("ok" if up else "")}></span>
                <span className="flex-[1_1_300px] flex flex-col gap-0.5">
                    <span className="text-[13.5px] font-medium">{"Daemon running" if up else "Daemon not running"}</span>
                    <span className="text-[12.5px] text-muted">{dsub}</span>
                </span>
                {(<span className="font-mono text-xs text-muted">{"pid " + str(d.pid)}</span>) if (up and d.pid) else None}
            </div>
            <div className={ROW + " gap-x-4 px-4.5 py-3.5 border-b border-line"}>
                <span className={dotCls("ok" if (svc == "installed") else "")}></span>
                <span className="flex-[1_1_300px] flex flex-col gap-0.5">
                    <span className="text-[13.5px] font-medium">Start Sigil when you log in</span>
                    <span className="text-[12.5px] text-muted">{"Installed: the operating system starts the daemon at login and keeps it alive." if (svc == "installed") else "Not installed. sigil daemon install adds a login service so the daemon survives restarts."}</span>
                </span>
            </div>
            <div className={ROW + " gap-x-4 px-4.5 py-3.5 border-b border-line"}>
                <span className={dotCls("live" if (sv and sv.running) else "")}></span>
                <span className="flex-[1_1_300px] flex flex-col gap-0.5">
                    <span className="text-[13.5px] font-medium">Web console</span>
                    <span className="text-[12.5px] text-muted"><span className="font-mono">{str(sv.url) if sv else window.location.host}</span>{(" · pid " + str(sv.pid)) if (sv and sv.pid) else ""}</span>
                </span>
            </div>
            <div className="px-4.5 py-3.5 border-b border-line flex flex-col gap-1.5">
                <span className="text-[12.5px] text-muted">The daemon runs from a terminal:</span>
                <div className="flex flex-wrap gap-1.5 font-mono text-xs">
                    <span className="px-2 py-0.5 rounded-md bg-ink-3">sigil daemon start</span>
                    <span className="px-2 py-0.5 rounded-md bg-ink-3">sigil daemon stop</span>
                    <span className="px-2 py-0.5 rounded-md bg-ink-3">sigil daemon status</span>
                    <span className="px-2 py-0.5 rounded-md bg-ink-3">sigil daemon logs</span>
                </div>
            </div>
            <dl className="m-0 px-4.5 py-3.5 grid grid-cols-[minmax(120px,auto)_1fr] gap-x-4 gap-y-1.5 text-[12.5px]">
                <dt className="text-muted">Version</dt>
                <dd className="m-0">{("Sigil " + str(sysv.version) if sysv.version else "Sigil") + (" · jac " + str(sysv.jac) if sysv.jac else "")}</dd>
                <dt className="text-muted">Graph store</dt>
                <dd className="m-0 font-mono break-all">{str(d.graph) if d else (str(sv.graph) if sv else "")}</dd>
                <dt className="text-muted">Workspace</dt>
                <dd className="m-0 font-mono break-all">{str(winfo.root) if winfo else ""}</dd>
                <dt className="text-muted">Sandbox</dt>
                <dd className="m-0 font-mono">{str(winfo.sandbox) if winfo else ""}</dd>
                <dt className="text-muted">Sigil home</dt>
                <dd className="m-0 font-mono break-all">{str(sysv.home)}</dd>
                <dt className="text-muted">Project</dt>
                <dd className="m-0 font-mono break-all">{str(sysv.project)}</dd>
                <dt className="text-muted">Secrets file</dt>
                <dd className="m-0 font-mono break-all">{str(sysv.secrets_file)}</dd>
                <dt className="text-muted">Daemon log</dt>
                <dd className="m-0 font-mono break-all">{str(d.log) if d else ""}</dd>
                <dt className="text-muted">Console log</dt>
                <dd className="m-0 font-mono break-all">{str(sv.log) if sv else ""}</dd>
            </dl>
        </section>;
    }

    body: any = None;
    if sec == "keys" { body = keysCard(); }
    elif sec == "models" { body = modelsCard(); }
    elif sec == "behaviour" { body = behaviourCard(); }
    elif sec == "agent" { body = agentCard(); }
    elif sec == "workspace" { body = workspaceCard(); }
    else { body = systemCard(); }

    return <div className="flex flex-col">
        <PageHead title="Settings" kicker="Every setting, in one place" onAsk={ask}
            askHint="Ask Sigil, e.g. “switch the small model to qwen3:14b”" tag="settings"/>

        <div className="flex flex-wrap items-start">
            <nav aria-label="Settings sections" className="flex-[1_1_200px] lg:max-w-[240px] px-5 py-5 flex flex-col gap-0.5">
                {for s in SECTIONS {
                    if s[0] == "tools" {
                        <a key="tools" href="#/tools" className={SUB_OFF}>
                            <span>{str(s[1])}</span>
                            <span className="ml-auto text-xs text-muted" aria-hidden="true">↗</span>
                        </a>
                    } else {
                        <a key={str(s[0])} href={"#/settings/" + str(s[0])} aria-current={"page" if (sec == s[0]) else None}
                            onClick={lambda (e: MouseEvent) { e.preventDefault(); openSection(str(s[0])); }}
                            className={SUB_ON if (sec == s[0]) else SUB_OFF}>
                            <span>{str(s[1])}</span>
                            {(<span className="ml-auto min-w-[18px] h-[18px] px-1.5 rounded-full bg-[#f5c451] text-[#1a1406] text-[11px] font-semibold inline-flex items-center justify-center"
                                aria-label={str(missing) + " missing"}>{str(missing)}</span>) if ((s[0] == "keys") and (missing > 0)) else None}
                        </a>
                    }
                }}
            </nav>

            <div className="flex-[999_1_560px] min-w-0 max-w-[980px] px-7 lg:pl-2 pt-5 pb-10 flex flex-col gap-4">
                {(<Note text={note} tone={noteTone}/>) if note else None}
                {body}
            </div>
        </div>
    </div>;
}

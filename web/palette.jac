"""The ⌘K palette: jump to any page, setting, skill, run or schedule, or ask Sigil.

Everything it lists comes from the shell's overview (`ov`), so opening it costs
no request. ↑↓ move, ↵ opens, ⌘↵ asks Sigil whatever is typed, a leading ">"
narrows the list to actions, and Escape or a click outside closes it.
"""

import from .ui { Icon, Logo, dotCls }
import from "./console_interop.js" { focusId, fmtAgo, money }

# [label, path, sub]
glob PAGES: list[any] = [
    ["Home", "/", "What needs you, what ran, what it cost"],
    ["Chat", "/chat", "Hand Sigil a task"],
    ["Library", "/skills", "Every compiled skill"],
    ["Compile", "/compile", "SKILL.md in, a typed agent out"],
    ["Runs", "/runs", "What ran and how it went"],
    ["Usage", "/usage", "Tokens and spend by model"],
    ["Memory", "/memory", "What Sigil remembers"],
    ["Automations", "/automations", "Schedules and hooks"],
    ["Approvals", "/approvals", "Commands waiting on you, and the allowlist"],
    ["Channels", "/channels", "Where Sigil can be messaged"],
    ["MCP & tools", "/tools", "MCP servers and the tool policy"],
    ["Settings", "/settings", "Every setting, in one place"],
    ["Docs", "/docs", "How Sigil works"]
];

glob SETTINGS: list[any] = [
    ["Agent", "/settings/agent", "Name, persona and principles"],
    ["Keys & secrets", "/settings/keys", "Model provider, search and channel keys"],
    ["Models", "/settings/models", "Frontier, small, router and chat models"],
    ["Behaviour", "/settings/behaviour", "Grading, relearning and the system prompt"],
    ["Workspace & sandbox", "/settings/workspace", "Where Sigil works and how shell commands run"],
    ["System", "/settings/system", "Daemon, web console and graph store"]
];

glob ACTIONS: list[any] = [
    ["Compile a skill", "/compile", "Upload a SKILL.md and compile it into a typed procedure"],
    ["New chat", "/chat", "Hand Sigil a task"],
    ["Teach Sigil something", "/memory", "A fact, preference or rule to remember"],
    ["New schedule", "/automations", "Run a task on a timer"]
];

def _okPct(s: any) -> float {
    r = int(s.runs) if s.runs else 0;
    if r == 0 { return -1.0; }
    return (float(s.successes) * 100.0) / float(r);
}

def _byRuns(s: any) -> int { return int(s.runs) if s.runs else 0; }

def _skillTone(s: any) -> str {
    p = _okPct(s);
    if p < 0 { return ""; }
    if p >= 90 { return "ok"; }
    if p >= 60 { return "warn"; }
    return "bad";
}

def _skillSub(s: any) -> str {
    runs = int(s.runs) if s.runs else 0;
    out = "v" + str(s.version) + " · " + ((str(s.successes) + "/" + str(runs) + " ok") if runs else "never run");
    intent = str(s.intent or "").strip();
    if intent { out = out + " · " + intent; }
    return out;
}

def _item(group: str, label: str, sub: str, path: str, tone: str, hint: str, mono: bool) -> dict[str, any] {
    return {"group": group, "label": label, "sub": sub, "path": path, "tone": tone, "hint": hint, "mono": mono};
}

def _pick(items: list[any], words: list[str], limit: int) -> list[any] {
    # Every typed word must appear in the item's label, sub or group.
    out: list[any] = [];
    for it in items {
        hay = (str(it["label"]) + " " + str(it["sub"]) + " " + str(it["group"])).lower();
        hit = True;
        for w in words {
            if w not in hay { hit = False; break; }
        }
        if hit { out.append(it); }
        if (limit > 0) and (len(out) >= limit) { break; }
    }
    return out;
}

def _groups(ov: any, q: str) -> list[any] {
    # [[group name, items], ...] for what is typed. Empty: the pages first, a
    # few of everything else. Typed: whatever matches, the closest kinds first.
    raw = q.strip();
    actionsOnly = raw.startswith(">");
    needle = (raw[1:] if actionsOnly else raw).strip().lower();
    words: list[str] = [w for w in needle.split(" ") if w];
    typed = len(words) > 0;

    skills: list[any] = list(ov.skills) if (ov and ov.skills) else [];
    tasks: list[any] = list(ov.tasks) if (ov and ov.tasks) else [];
    cron: list[any] = list(ov.cron) if (ov and ov.cron) else [];
    pending = len(ov.pending) if (ov and ov.pending) else 0;
    today: any = ov.today if ov else None;

    acts = [_item("Actions", str(a[0]), str(a[2]), str(a[1]), "acc", "action", False) for a in ACTIONS];
    if actionsOnly { return [["Actions", _pick(acts, words, 0)]]; }

    sk = [_item("Skills", str(s.signature), _skillSub(s), "/skills/" + str(s.signature), _skillTone(s), "skill", True)
          for s in sorted(skills, key=_byRuns, reverse=True)];
    rn = [_item("Runs", str(t.detail or t.label), str(t.label) + " · " + str(t.kind), "/runs/" + str(i),
                "ok" if t.ok else "bad", fmtAgo(t.at_ms), False) for (i, t) in enumerate(tasks)];
    sc = [_item("Schedules", str(j.name), str(j.schedule) + ("" if j.enabled else " · paused"), "/automations",
                ("bad" if (j.last_status and (str(j.last_status) != "ok")) else ("ok" if j.enabled else "")), "schedule", True)
          for j in cron];
    pg: list[any] = [];
    for p in PAGES {
        sub = str(p[2]);
        tone = "";
        if (p[1] == "/skills") and skills { sub = str(len(skills)) + (" skill" if len(skills) == 1 else " skills"); }
        if (p[1] == "/approvals") and pending { sub = str(pending) + " waiting"; tone = "warn"; }
        if (p[1] == "/usage") and today { sub = money(today.cost) + " today"; }
        pg.append(_item("Pages", str(p[0]), sub, str(p[1]), tone, "page", False));
    }
    st = [_item("Settings", str(x[0]), str(x[2]), str(x[1]), "", "setting", False) for x in SETTINGS];

    out: list[any] = [];
    if typed {
        out = [["Skills", _pick(sk, words, 6)], ["Runs", _pick(rn, words, 4)], ["Schedules", _pick(sc, words, 4)],
               ["Actions", _pick(acts, words, 0)], ["Pages", _pick(pg, words, 0)], ["Settings", _pick(st, words, 0)]];
    } else {
        out = [["Pages", pg], ["Actions", acts], ["Settings", st], ["Skills", sk[:4]], ["Runs", rn[:3]], ["Schedules", sc[:3]]];
    }
    return [g for g in out if len(g[1]) > 0];
}

def:pub Palette(ov: any, go: Callable[[str], None], ask: Callable[[str], None], onClose: Callable[[], None]) -> JsxElement {
    has q: str = "";
    has sel: int = 0;

    can with entry { focusId("pal-q"); }

    groups = _groups(ov, q);
    shown: list[any] = [];
    flat: list[any] = [];
    for g in groups {
        rows: list[any] = [];
        for it in g[1] {
            row = {**it, "idx": len(flat)};
            flat.append(row);
            rows.append(row);
        }
        shown.append([g[0], rows]);
    }
    n = len(flat) + 1;
    cur = sel if (sel < n) else (n - 1);
    text = q.strip();
    askText = text[1:].strip() if text.startswith(">") else text;
    askIdx = len(flat);

    def close() { onClose(); }

    def askNow() {
        if askText { ask(askText); }
        else { go("/chat"); }
        onClose();
    }

    def activate(i: int) {
        if i < len(flat) {
            go(str(flat[i]["path"]));
            onClose();
        } else { askNow(); }
    }

    def move(i: int) {
        sel = i;
        setTimeout(lambda {
            el: any = document.getElementById("pal-" + str(i));
            if el { el.scrollIntoView({"block": "nearest"}); }
        }, 0);
    }

    def keyed(e: any) {
        if e.key == "ArrowDown" { e.preventDefault(); move((cur + 1) % n); }
        elif e.key == "ArrowUp" { e.preventDefault(); move((cur + n - 1) % n); }
        elif e.key == "Enter" {
            e.preventDefault();
            if e.metaKey or e.ctrlKey { askNow(); }
            else { activate(cur); }
        } elif e.key == "Escape" { e.preventDefault(); close(); }
    }

    def typed(e: ChangeEvent) { q = e.target.value; sel = 0; }

    return <div className="fixed inset-0 z-50 flex items-start justify-center px-4 pt-[12vh] pb-10">
        <div aria-hidden="true" className="absolute inset-0 bg-ink-0/80 backdrop-blur-[2px]"
            onClick={lambda (e: MouseEvent) { close(); }}></div>
        <div role="dialog" aria-modal="true" aria-label="Search or ask Sigil"
            className="relative w-[640px] max-w-full max-h-[76vh] flex flex-col rounded-2xl bg-ink-2 border border-line-2 shadow-2xl overflow-hidden">
            <div className="flex items-center gap-2.5 px-4 py-3.5 border-b border-line">
                <Icon name="search" size={18} cls="text-muted"/>
                <input id="pal-q" role="combobox" aria-label="Search or ask" aria-expanded="true"
                    aria-controls="pal-list" aria-autocomplete="list" aria-activedescendant={"pal-" + str(cur)}
                    value={q} onChange={typed} onKeyDown={keyed} autoFocus={True} autoComplete="off" spellCheck={False}
                    placeholder="Jump to anything, or ask Sigil"
                    className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[17px] text-fg placeholder:text-faint"/>
                <button type="button" aria-label="Close" onClick={lambda (e: MouseEvent) { close(); }}
                    className="font-mono text-[11px] text-muted border border-line-2 rounded-[5px] px-1.5 bg-transparent cursor-pointer hover:text-fg">esc</button>
            </div>

            <div id="pal-list" role="listbox" aria-label="Results" className="flex flex-col min-h-0">
                <div className="min-h-0 overflow-y-auto py-1.5">
                    {for g in shown {
                        <div key={"g-" + str(g[0])} role="group" aria-label={str(g[0])}>
                            <div role="presentation" className="px-4 pt-2.5 pb-1 text-[11px] font-medium tracking-wider uppercase text-faint">{g[0]}</div>
                            {for it in g[1] {
                                <div key={"i-" + str(it["idx"])} id={"pal-" + str(it["idx"])} role="option"
                                    aria-selected={"true" if (it["idx"] == cur) else "false"}
                                    onMouseEnter={lambda (e: MouseEvent) { sel = int(it["idx"]); }}
                                    onClick={lambda (e: MouseEvent) { activate(int(it["idx"])); }}
                                    className={"flex items-center gap-3 px-4 py-2 cursor-pointer " + ("bg-violet-500/15" if (it["idx"] == cur) else "")}>
                                    <span className={dotCls(str(it["tone"]))}></span>
                                    <span className="flex-1 min-w-0 flex flex-col">
                                        <span className={"text-[13.5px] text-fg truncate" + (" font-mono" if it["mono"] else "")}>{it["label"]}</span>
                                        {(<span className="text-xs text-muted truncate">{it["sub"]}</span>) if it["sub"] else None}
                                    </span>
                                    <span className="text-[11.5px] text-faint shrink-0">{"↵" if (it["idx"] == cur) else str(it["hint"])}</span>
                                </div>
                            }}
                        </div>
                    }}
                    {(<div className="px-4 py-3.5 text-[13px] text-muted">Nothing in Sigil matches. Press ↵ to ask instead.</div>) if (len(flat) == 0) else None}
                </div>

                <div id={"pal-" + str(askIdx)} role="option" aria-selected={"true" if (cur == askIdx) else "false"}
                    onMouseEnter={lambda (e: MouseEvent) { sel = askIdx; }}
                    onClick={lambda (e: MouseEvent) { askNow(); }}
                    className={"flex items-center gap-3 px-4 py-3 border-t border-line cursor-pointer " + ("bg-violet-500/15" if (cur == askIdx) else "bg-ink-3")}>
                    <Logo size={18}/>
                    <span className="flex-1 min-w-0 text-[13.5px] text-fg truncate">
                        {"Ask Sigil: "}<span className="text-acc">{("“" + askText + "”") if askText else "…"}</span>
                    </span>
                    <span className="font-mono text-[11px] text-muted border border-line-2 rounded-[5px] px-1.5 shrink-0">⌘↵</span>
                </div>
            </div>

            <div className="flex flex-wrap gap-x-4 gap-y-1 px-4 py-2.5 border-t border-line text-xs text-muted">
                <span><span className="font-mono">↑↓</span> move</span>
                <span><span className="font-mono">↵</span> open</span>
                <span><span className="font-mono">⌘↵</span> ask Sigil</span>
                <span><span className="font-mono">&gt;</span> actions only</span>
            </div>
        </div>
    </div>;
}

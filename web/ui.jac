"""The console's shared pieces: one look, written once.

Colours come from the `ink-*`, `line`, `fg*` and tone tokens in src/global.css,
so every component follows the light/dark switch. Class strings are spelled out
whole on purpose: Tailwind finds classes by reading the source, and a class
assembled from parts at run time is a class it never generates.
"""

glob:pub BTN: str = "inline-flex items-center justify-center gap-2 h-9 px-3.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white text-[13px] font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN2: str = "inline-flex items-center justify-center gap-2 h-9 px-3.5 rounded-lg bg-ink-3 border border-line-2 text-fg text-[13px] font-medium hover:border-faint transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN_GHOST: str = "inline-flex items-center justify-center gap-2 h-9 px-3 rounded-lg border border-line-2 text-fg-2 text-[13px] font-medium hover:bg-ink-3 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN_BAD: str = "inline-flex items-center justify-center gap-2 h-9 px-3.5 rounded-lg border border-bad/30 text-bad text-[13px] font-medium hover:bg-bad/10 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN_SM: str = "inline-flex items-center justify-center gap-1.5 h-8 px-3 rounded-lg bg-violet-600 hover:bg-violet-500 text-white text-xs font-medium transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN2_SM: str = "inline-flex items-center justify-center gap-1.5 h-8 px-2.5 rounded-lg bg-ink-3 border border-line-2 text-fg text-xs font-medium hover:border-faint transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN_GHOST_SM: str = "inline-flex items-center justify-center gap-1.5 h-8 px-2.5 rounded-lg border border-line-2 text-fg-2 text-xs font-medium hover:bg-ink-3 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub BTN_BAD_SM: str = "inline-flex items-center justify-center gap-1.5 h-8 px-2.5 rounded-lg border border-bad/30 text-bad text-xs font-medium hover:bg-bad/10 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-default";
glob:pub INP: str = "h-9 px-3 rounded-lg bg-ink-1 border border-line-2 text-[13px] text-fg placeholder:text-faint focus:outline-none focus:ring-2 focus:ring-violet-500/50 min-w-0";
glob:pub AREA: str = "px-3 py-2 rounded-lg bg-ink-1 border border-line-2 text-[13px] leading-relaxed text-fg placeholder:text-faint focus:outline-none focus:ring-2 focus:ring-violet-500/50 min-w-0 resize-y";
glob:pub SELECT: str = "h-9 px-2.5 rounded-lg bg-ink-1 border border-line-2 text-[13px] text-fg focus:outline-none focus:ring-2 focus:ring-violet-500/50";
glob:pub CARD: str = "rounded-xl bg-ink-2 border border-line";
glob:pub LABEL: str = "text-[11px] font-medium tracking-wider uppercase text-faint";
glob:pub LINK: str = "text-acc hover:underline cursor-pointer";

glob:pub CHIP_OK: str = "inline-flex items-center gap-1.5 h-[22px] px-2 rounded-full text-[11.5px] whitespace-nowrap border text-ok bg-ok/10 border-ok/25";
glob:pub CHIP_BAD: str = "inline-flex items-center gap-1.5 h-[22px] px-2 rounded-full text-[11.5px] whitespace-nowrap border text-bad bg-bad/10 border-bad/30";
glob:pub CHIP_WARN: str = "inline-flex items-center gap-1.5 h-[22px] px-2 rounded-full text-[11.5px] whitespace-nowrap border text-warn bg-warn/10 border-warn/30";
glob:pub CHIP_LIVE: str = "inline-flex items-center gap-1.5 h-[22px] px-2 rounded-full text-[11.5px] whitespace-nowrap border text-live bg-live/10 border-live/30";
glob:pub CHIP_ACC: str = "inline-flex items-center gap-1.5 h-[22px] px-2 rounded-full text-[11.5px] whitespace-nowrap border text-acc bg-acc/10 border-acc/30";
glob:pub CHIP: str = "inline-flex items-center gap-1.5 h-[22px] px-2 rounded-full text-[11.5px] whitespace-nowrap border text-fg-2 bg-ink-3 border-line-2";
glob:pub TAG: str = "inline-flex items-center h-5 px-1.5 rounded text-[11px] font-mono";

def:pub chip(tone: str) -> str {
    if tone == "ok" { return CHIP_OK; }
    if tone == "bad" { return CHIP_BAD; }
    if tone == "warn" { return CHIP_WARN; }
    if tone == "live" { return CHIP_LIVE; }
    if tone == "acc" { return CHIP_ACC; }
    return CHIP;
}

def:pub tagCls(tone: str) -> str {
    if tone == "ok" { return TAG + " text-ok bg-ok/10"; }
    if tone == "bad" { return TAG + " text-bad bg-bad/10"; }
    if tone == "warn" { return TAG + " text-warn bg-warn/10"; }
    if tone == "live" { return TAG + " text-live bg-live/10"; }
    if tone == "acc" { return TAG + " text-acc bg-acc/10"; }
    return TAG + " text-fg-2 bg-ink-3";
}

def:pub dotCls(tone: str) -> str {
    if tone == "ok" { return "inline-block w-2 h-2 rounded-full shrink-0 bg-[#4ade80]"; }
    if tone == "bad" { return "inline-block w-2 h-2 rounded-full shrink-0 bg-[#f87171]"; }
    if tone == "warn" { return "inline-block w-2 h-2 rounded-full shrink-0 bg-[#f5c451]"; }
    if tone == "live" { return "inline-block w-2 h-2 rounded-full shrink-0 bg-[#22d3ee] animate-pulse"; }
    if tone == "acc" { return "inline-block w-2 h-2 rounded-full shrink-0 bg-[#a78bfa]"; }
    return "inline-block w-2 h-2 rounded-full shrink-0 border border-faint";
}

# Stroke icons, 24-unit grid: each entry is the list of path `d`s that draw it.
glob:pub ICONS: dict[str, list[str]] = {
    "home": ["M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"],
    "chat": ["M4 5h16v11H9l-5 4z"],
    "library": ["m12 3 9 5-9 5-9-5z", "m3 13 9 5 9-5"],
    "compile": ["M12 3 20 7.5v9L12 21l-8-4.5v-9z", "M12 8.5 15.5 15h-7z"],
    "runs": ["M3 12h4l3-8 4 16 3-8h4"],
    "usage": ["M5 20V11M11 20V5M17 20v-6M3 20h18"],
    "memory": ["M5 6a7 3 0 1 0 14 0a7 3 0 1 0-14 0", "M5 6v12c0 1.7 3.1 3 7 3s7-1.3 7-3V6M5 12c0 1.7 3.1 3 7 3s7-1.3 7-3"],
    "clock": ["M3 12a9 9 0 1 0 18 0a9 9 0 1 0-18 0", "M12 7v5l3 2"],
    "shield": ["M12 3 5 6v6c0 4.5 3 7.7 7 9 4-1.3 7-4.5 7-9V6z", "m9 12 2 2 4-4"],
    "channels": ["M10 12a2 2 0 1 0 4 0a2 2 0 1 0-4 0", "M16.2 7.8a6 6 0 0 1 0 8.4M7.8 16.2a6 6 0 0 1 0-8.4M19.1 4.9a10 10 0 0 1 0 14.2M4.9 19.1a10 10 0 0 1 0-14.2"],
    "plug": ["M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0zM12 17v4"],
    "settings": ["M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1", "M13 6a2 2 0 1 0 4 0a2 2 0 1 0-4 0", "M7 12a2 2 0 1 0 4 0a2 2 0 1 0-4 0", "M15 18a2 2 0 1 0 4 0a2 2 0 1 0-4 0"],
    "docs": ["M5 4h11a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3z", "M5 17a3 3 0 0 1 3-3h11"],
    "search": ["M4 11a7 7 0 1 0 14 0a7 7 0 1 0-14 0", "m20 20-4-4"],
    "plus": ["M12 5v14M5 12h14"],
    "x": ["M6 6l12 12M18 6 6 18"],
    "send": ["M12 19V5M6 11l6-6 6 6"],
    "clip": ["M20 11.5 12 19.5a5 5 0 0 1-7-7l8-8a3.5 3.5 0 0 1 5 5l-8 8a2 2 0 0 1-3-3l7-7"],
    "check": ["m5 12 5 5 9-10"],
    "refresh": ["M20 11a8 8 0 1 0-2.3 5.7", "M20 4v7h-7"],
    "upload": ["M12 16V4M7 9l5-5 5 5M4 20h16"],
    "key": ["M7 14a4 4 0 1 0 0-8 4 4 0 0 0 0 8z", "M10.5 10H21M17 10v4M20 10v3"],
    "moon": ["M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"],
    "sun": ["M8 12a4 4 0 1 0 8 0a4 4 0 1 0-8 0", "M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"],
    "chevron": ["m9 6 6 6-6 6"],
    "copy": ["M8 8h11v11H8z", "M5 16V5h11"],
    "play": ["M7 5v14l11-7z"],
    "stop": ["M7 7h10v10H7z"]
};

def:pub Icon(name: str, size: int = 16, cls: str = "", fill: bool = False) -> JsxElement {
    paths: list[str] = ICONS[name] if (name in ICONS) else [];
    return <svg width={size} height={size} viewBox="0 0 24 24"
        fill={"currentColor" if fill else "none"} stroke={"none" if fill else "currentColor"}
        strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"
        aria-hidden="true" className={"shrink-0 " + cls}>
        {[<path key={str(i)} d={p}></path> for (i, p) in enumerate(paths)]}
    </svg>;
}

def:pub Logo(size: int = 26) -> JsxElement {
    return <svg viewBox="0 0 32 32" width={size} height={size} aria-hidden="true" className="shrink-0">
        <g fill="none" stroke="#a78bfa" strokeWidth="1.4">
            <polygon points="16,3 27.3,9.5 27.3,22.5 16,29 4.7,22.5 4.7,9.5"></polygon>
            <path d="M16 3 L16 29 M4.7 9.5 L27.3 22.5 M27.3 9.5 L4.7 22.5" opacity="0.55" strokeWidth="0.8"></path>
        </g>
        <polygon points="16,9.5 22,20 10,20" fill="none" stroke="#38bdf8" strokeWidth="1.4" strokeLinejoin="round"></polygon>
        <circle cx="16" cy="16" r="2.2" fill="#22d3ee"></circle>
    </svg>;
}

def:pub Toggle(on: bool, label: str, onToggle: Callable[[bool], None], disabled: bool = False) -> JsxElement {
    def flip(e: MouseEvent) {
        if not disabled { onToggle(not on); }
    }
    return <button type="button" role="switch" aria-checked={"true" if on else "false"} aria-label={label}
        disabled={disabled} onClick={flip}
        className={"inline-flex w-9 h-5 shrink-0 rounded-full p-0.5 transition-colors " + ("bg-violet-600 justify-end" if on else "bg-line-2 justify-start") + (" opacity-50" if disabled else " cursor-pointer")}>
        <span className={"block w-4 h-4 rounded-full " + ("bg-white" if on else "bg-faint")}></span>
    </button>;
}

# options: [[value, label], ...]
def:pub Segmented(options: list[any], value: str, onPick: Callable[[str], None], label: str = "", small: bool = False) -> JsxElement {
    return <div role="group" aria-label={label} className="inline-flex flex-wrap p-[3px] gap-0.5 rounded-lg bg-ink-1 border border-line-2">
        {[
            <button key={str(opt[0])} type="button" aria-pressed={"true" if (str(opt[0]) == value) else "false"}
                onClick={lambda (e: MouseEvent) { onPick(str(opt[0])); }}
                className={("h-7 px-2.5 text-xs" if small else "h-[30px] px-3 text-[12.5px]") + " rounded-md font-medium cursor-pointer transition-colors " + ("bg-ink-4 text-fg" if (str(opt[0]) == value) else "text-fg-2 hover:text-fg")}>
                {str(opt[1])}
            </button>
            for opt in options
        ]}
    </div>;
}

def:pub PageHead(title: str, kicker: str = "", onAsk: Callable[[str], None] | None = None,
                 askHint: str = "Ask Sigil about this page", tag: str = "", mono: bool = False,
                 children: any = None) -> JsxElement {
    has q: str = "";
    def typed(e: ChangeEvent) { q = e.target.value; }
    def keyed(e: KeyboardEvent) {
        if (e.key == "Enter") and q.strip() and onAsk {
            onAsk(q.strip());
            q = "";
        }
    }
    return <header className="flex flex-wrap items-center gap-x-4 gap-y-3 px-7 py-3.5 border-b border-line bg-ink-1">
        <div className="flex flex-col gap-0.5 mr-auto min-w-0">
            {(<span className="text-xs text-faint">{kicker}</span>) if kicker else None}
            <h1 className={"m-0 text-xl font-semibold tracking-tight truncate" + (" font-mono" if mono else "")}>{title}</h1>
        </div>
        {(<label className="flex items-center gap-2 h-[38px] flex-[0_1_400px] min-w-[220px] pl-3 pr-1.5 rounded-[10px] bg-ink-2 border border-line-2">
            <Logo size={16}/>
            <span className="sr-only">Ask Sigil</span>
            <input value={q} onChange={typed} onKeyDown={keyed} placeholder={askHint}
                className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[13px] text-fg placeholder:text-faint"/>
            {(<span className="inline-flex items-center h-6 px-2 rounded-md font-mono text-[11px] text-acc bg-acc/10">{tag}</span>) if tag else None}
        </label>) if onAsk else None}
        {children}
    </header>;
}

def:pub Empty(title: str, body: str = "", children: any = None) -> JsxElement {
    return <div className="flex flex-col items-start gap-2 p-6 rounded-xl border border-dashed border-line-2 text-[13px]">
        <span className="font-medium text-fg">{title}</span>
        {(<span className="text-muted leading-relaxed max-w-xl">{body}</span>) if body else None}
        {children}
    </div>;
}

def:pub Note(text: str, tone: str = "warn") -> JsxElement {
    cls = "px-3 py-2 rounded-lg text-[12.5px] leading-relaxed border ";
    if tone == "bad" { cls = cls + "bg-bad/10 border-bad/30 text-bad"; }
    elif tone == "ok" { cls = cls + "bg-ok/10 border-ok/25 text-ok"; }
    elif tone == "live" { cls = cls + "bg-live/10 border-live/30 text-live"; }
    else { cls = cls + "bg-warn/10 border-warn/30 text-warn"; }
    return <div className={cls}>{text}</div>;
}

def:pub Spinner(label: str = "") -> JsxElement {
    return <span className="inline-flex items-center gap-2 text-[12.5px] text-muted">
        <span className="inline-block w-3.5 h-3.5 rounded-full border-2 border-line-2 border-t-violet-400 animate-spin"></span>
        {label}
    </span>;
}

def:pub Stat(label: str, value: str, sub: str = "", tone: str = "") -> JsxElement {
    vcls = "text-[26px] font-semibold tracking-tight leading-tight";
    if tone == "gold" { vcls = vcls + " text-[#f5c451]"; }
    elif tone == "ok" { vcls = vcls + " text-ok"; }
    elif tone == "bad" { vcls = vcls + " text-bad"; }
    return <section className={CARD + " px-4 py-3.5 flex flex-col gap-1 min-w-0"}>
        <h2 className="m-0 text-xs font-medium text-muted">{label}</h2>
        <span className={vcls}>{value}</span>
        {(<span className="text-xs text-muted truncate">{sub}</span>) if sub else None}
    </section>;
}

def:pub Bar(pct: float, tone: str = "ok") -> JsxElement {
    p = pct if pct > 0 else 0.0;
    p = 100.0 if p > 100 else p;
    fill = "bg-[#4ade80]";
    if tone == "warn" { fill = "bg-[#f5c451]"; }
    elif tone == "bad" { fill = "bg-[#f87171]"; }
    elif tone == "acc" { fill = "bg-[#a78bfa]"; }
    return <span className="block h-1.5 w-full rounded-full bg-ink-4 overflow-hidden">
        <span className={"block h-full rounded-full " + fill} style={{"width": str(p) + "%"}}></span>
    </span>;
}

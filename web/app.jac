"""Sigil's web console: the shell.

A sidebar, one page at a time, and the ⌘K palette over all of it. The pages live
in their own modules (web/<page>.jac) and fetch their own data through
`api_console`; the shell owns only what more than one page shows: the overview
behind the sidebar's badges, the route, the theme, and a message waiting to be
asked in Chat.

Routes are hash paths (#/skills/clean_csv) so a page can be bookmarked and the
browser's back button works, with no server routing to configure.

Every request answers by running against the agent's real graph in a fresh
`jac run` process (see src/sigil_api.jac), so each fetch costs a process start:
the shell refreshes its overview every 20 seconds, and pages fetch when opened.
"""

import from src.sigil_console { api_console }
import from .ui { Icon, Logo }
import from .home { HomePage }
import from .chat { ChatPage }
import from .library { LibraryPage }
import from .skill { SkillPage }
import from .compile { CompilePage }
import from .runs { RunsPage }
import from .usage { UsagePage }
import from .memory { MemoryPage }
import from .automations { AutomationsPage }
import from .approvals { ApprovalsPage }
import from .channels { ChannelsPage }
import from .tools { ToolsPage }
import from .settings { SettingsPage }
import from .docs { DocsPage }
import from .palette { Palette }
import from "./console_interop.js" { routeNow, onRoute, navTo, storeGet, storeSet, onShortcut, pageVisible }
import from react { useEffect }

# [page, label, path, icon], or ["", heading] for a group heading.
glob NAV: list[any] = [
    ["home", "Home", "/", "home"],
    ["chat", "Chat", "/chat", "chat"],
    ["", "Skills"],
    ["skills", "Library", "/skills", "library"],
    ["compile", "Compile", "/compile", "compile"],
    ["", "Activity"],
    ["runs", "Runs", "/runs", "runs"],
    ["usage", "Usage", "/usage", "usage"],
    ["", "Agent"],
    ["memory", "Memory", "/memory", "memory"],
    ["automations", "Automations", "/automations", "clock"],
    ["approvals", "Approvals", "/approvals", "shield"],
    ["", "Connect"],
    ["channels", "Channels", "/channels", "channels"],
    ["tools", "MCP & tools", "/tools", "plug"]
];

glob FOOT: list[any] = [
    ["settings", "Settings", "/settings", "settings"],
    ["docs", "Docs", "/docs", "docs"]
];

glob NAV_ON: str = "flex items-center gap-2.5 h-9 px-2.5 rounded-lg no-underline text-[13.5px] font-medium text-fg bg-violet-500/15";
glob NAV_OFF: str = "flex items-center gap-2.5 h-9 px-2.5 rounded-lg no-underline text-[13.5px] text-fg-2 hover:bg-ink-3 hover:text-fg";

def:pub App() -> JsxElement {
    has route: str = "/";
    has light: bool = False;
    has ov: any = None;
    has draft: str = "";
    has palette: bool = False;

    async def loadOverview() {
        r = root spawn api_console(op="overview", args={});
        m: any = r.reports[0] if r.reports else None;
        if m and (not m.error) { ov = m; }
    }

    can with entry {
        route = routeNow();
        light = bool(storeGet("sigil.light", False));
        loadOverview();
    }

    useEffect(lambda {
        return onRoute(lambda (p: str) { route = p; palette = False; });
    }, []);

    useEffect(lambda {
        return onShortcut(lambda (k: str) {
            if k == "palette" { palette = not palette; }
            elif k == "escape" { palette = False; }
        });
    }, []);

    # Each read is a fresh Sigil process, so the shell refreshes slowly and not
    # at all while the tab is in the background.
    useEffect(lambda {
        iv = setInterval(lambda { if pageVisible() { loadOverview(); } }, 45000);
        return lambda { clearInterval(iv); };
    }, []);

    def go(p: str) { navTo(p); }
    def ask(text: str) { draft = text; navTo("/chat"); }
    def clearDraft() { draft = ""; }
    def refresh() { loadOverview(); }
    def closePalette() { palette = False; }
    def openPalette(e: MouseEvent) { palette = True; }
    def flipTheme(e: MouseEvent) { light = not light; storeSet("sigil.light", light); }

    parts: list[str] = [x for x in route.split("/") if x];
    page = parts[0] if parts else "home";
    pending = len(ov.pending) if (ov and ov.pending) else 0;
    nskills = len(ov.skills) if (ov and ov.skills) else 0;
    daemonUp = bool(ov.daemon) if ov else False;
    nchan = len(ov.channels) if (ov and ov.channels) else 0;

    return <div className={("light " if light else "") + "min-h-screen flex flex-wrap items-stretch bg-ink-0 text-fg font-sans text-sm leading-normal"}>
        <nav aria-label="Main" className="flex-[1_1_232px] lg:max-w-[232px] bg-ink-1 border-r border-line px-3 py-4 flex flex-col gap-0.5 lg:sticky lg:top-0 lg:h-screen lg:overflow-y-auto">
            <a href="#/" className="flex items-center gap-2.5 px-2 pt-1 pb-3.5 no-underline text-fg">
                <Logo size={26}/>
                <span className="text-[17px] font-semibold tracking-tight">sigil</span>
            </a>
            <button type="button" onClick={openPalette}
                className="flex items-center gap-2 h-9 px-2.5 mb-2.5 rounded-lg border border-line-2 bg-ink-2 text-muted text-[13px] cursor-pointer hover:text-fg">
                <Icon name="search" size={15}/>
                <span>Search or ask</span>
                <span className="ml-auto font-mono text-[11px] text-muted border border-line-2 rounded px-1.5">⌘K</span>
            </button>
            {for item in NAV {
                if not item[0] {
                    <div key={"h-" + str(item[1])} className="px-2.5 pt-3.5 pb-1 text-[11px] font-medium tracking-wider uppercase text-faint">{item[1]}</div>
                } else {
                    <a key={str(item[0])} href={"#" + str(item[2])}
                        aria-current={"page" if (page == item[0]) else None}
                        className={NAV_ON if (page == item[0]) else NAV_OFF}>
                        <Icon name={str(item[3])} cls={"text-violet-400" if (page == item[0]) else ""}/>
                        <span>{item[1]}</span>
                        {(<span className="ml-auto font-mono text-[11.5px] text-faint">{str(nskills)}</span>) if ((item[0] == "skills") and nskills) else None}
                        {(<span className="ml-auto min-w-5 h-5 px-1.5 rounded-full bg-[#f5c451] text-[#1a1406] text-[11.5px] font-semibold inline-flex items-center justify-center"
                            aria-label={str(pending) + " waiting"}>{str(pending)}</span>) if ((item[0] == "approvals") and pending) else None}
                    </a>
                }
            }}
            <div className="grow min-h-5"></div>
            {for item in FOOT {
                <a key={str(item[0])} href={"#" + str(item[2])}
                    aria-current={"page" if (page == item[0]) else None}
                    className={NAV_ON if (page == item[0]) else NAV_OFF}>
                    <Icon name={str(item[3])} cls={"text-violet-400" if (page == item[0]) else ""}/>
                    <span>{item[1]}</span>
                </a>
            }}
            <button type="button" onClick={flipTheme} className={NAV_OFF + " w-full cursor-pointer bg-transparent border-0"}>
                <Icon name={"moon" if light else "sun"}/>
                <span>{"Dark theme" if light else "Light theme"}</span>
            </button>
            <a href="#/settings/system" className="mt-2.5 p-3 rounded-[10px] border border-line bg-ink-2 text-xs text-muted flex flex-col gap-1.5 no-underline">
                <span className="flex items-center gap-2">
                    <span className={"inline-block w-[7px] h-[7px] rounded-full " + ("bg-[#4ade80]" if daemonUp else "border border-faint")}></span>
                    {"Daemon running" if daemonUp else "Daemon not running"}
                </span>
                <span className="flex items-center gap-2">
                    <span className={"inline-block w-[7px] h-[7px] rounded-full " + ("bg-[#4ade80]" if nchan else "border border-faint")}></span>
                    {(str(nchan) + (" channel" if nchan == 1 else " channels")) if nchan else "No channels"}
                </span>
                <span className="flex items-center gap-2">
                    <span className="inline-block w-[7px] h-[7px] rounded-full bg-[#22d3ee]"></span>
                    <span className="font-mono">{window.location.host}</span>
                </span>
            </a>
        </nav>

        <main className="flex-[999_1_560px] min-w-0 flex flex-col">
            {if page == "home" {
                <HomePage ov={ov} go={go} ask={ask} refresh={refresh}/>
            } elif page == "chat" {
                <ChatPage route={parts} go={go} draft={draft} clearDraft={clearDraft} refresh={refresh}/>
            } elif (page == "skills") and (len(parts) > 1) {
                <SkillPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "skills" {
                <LibraryPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "compile" {
                <CompilePage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "runs" {
                <RunsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "usage" {
                <UsagePage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "memory" {
                <MemoryPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "automations" {
                <AutomationsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "approvals" {
                <ApprovalsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "channels" {
                <ChannelsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "tools" {
                <ToolsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "settings" {
                <SettingsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } elif page == "docs" {
                <DocsPage route={parts} go={go} ask={ask} refresh={refresh}/>
            } else {
                <HomePage ov={ov} go={go} ask={ask} refresh={refresh}/>
            }}
        </main>

        {(<Palette ov={ov} go={go} ask={ask} onClose={closePalette}/>) if palette else None}
    </div>;
}

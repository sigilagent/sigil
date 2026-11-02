"""Sigil's web console: the shell.

A top bar, one page at a time, and the ⌘K palette over all of it. The bar has
three places: the Studio (web/studio.jac), where you chat with Sigil, build agents
and see their graphs; the Dashboard (web/dashboard.jac), which holds what needs
you and a tile for every other page; and Settings, with its sections (model
providers, models, keys, agent, behaviour, tool policy, workspace, system). The
other pages (runs, usage, memory, automations, approvals, channels, tools, docs,
the library, compile reports, a skill's full page) live in their own modules and
keep their routes, so old links still land; while one is open the bar shows
Dashboard as current.

The pages fetch their own data through `api_console`; the shell owns only what
more than one page shows: the overview behind the bar's approval count and
status, the route, the theme, and a message waiting to be asked in the Studio.

Routes are hash paths (#/studio/clean_csv) so a page can be bookmarked and the
browser's back button works, with no server routing to configure.

Every request answers by running against the agent's real graph in a fresh
`jac run` process (see src/sigil_api.jac), so each fetch costs a process start:
the shell refreshes its overview every 45 seconds, and pages fetch when opened.
"""

import from src.sigil_console { api_console }
import from .ui { Icon, Logo }
import from .studio { StudioPage }
import from .dashboard { DashboardPage }
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

glob TOP_ON: str = "inline-flex items-center h-[38px] px-4 rounded-[9px] no-underline text-[13.5px] font-medium text-fg bg-ink-4";
glob TOP_OFF: str = "inline-flex items-center h-[38px] px-4 rounded-[9px] no-underline text-[13.5px] font-medium text-muted hover:text-fg";

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
    # A question asked anywhere (a page's "Ask Sigil" box, the palette) is sent
    # from the Studio's chat.
    def ask(text: str) { draft = text; navTo("/"); }
    def clearDraft() { draft = ""; }
    def refresh() { loadOverview(); }
    def closePalette() { palette = False; }
    def openPalette(e: MouseEvent) { palette = True; }
    def flipTheme(e: MouseEvent) { light = not light; storeSet("sigil.light", light); }

    parts: list[str] = [x for x in route.split("/") if x];
    page = parts[0] if parts else "studio";
    studio = page in ["studio", "chat"];
    settings = page == "settings";
    dash = (not studio) and (not settings);
    pending = len(ov.pending) if (ov and ov.pending) else 0;
    daemonUp = bool(ov.daemon) if ov else False;
    chatModel = str(ov.soul.chat_model) if (ov and ov.soul and ov.soul.chat_model) else "";
    onConnections = (page == "settings") and ((len(parts) < 2) or (parts[1] == "connections"));

    return <div className={("light " if light else "") + "flex flex-col bg-ink-0 text-fg font-sans text-sm leading-normal " + ("h-screen overflow-hidden" if studio else "min-h-screen")}>
        <header className="flex flex-wrap items-center gap-x-5 gap-y-2 px-6 py-2.5 border-b border-line bg-ink-1 shrink-0">
            <a href="#/" className="flex items-center gap-2.5 min-h-11 no-underline text-fg">
                <Logo size={24}/>
                <span className="text-[17px] font-semibold tracking-tight">sigil</span>
            </a>
            <nav aria-label="Main" className="flex gap-0.5 p-[3px] rounded-xl bg-ink-2 border border-line-2">
                <a href="#/" aria-current={"page" if studio else None} className={TOP_ON if studio else TOP_OFF}>Studio</a>
                <a href="#/dashboard" aria-current={"page" if dash else None} className={TOP_ON if dash else TOP_OFF}>Dashboard</a>
                <a href="#/settings" aria-current={"page" if settings else None} className={TOP_ON if settings else TOP_OFF}>Settings</a>
            </nav>
            <button type="button" onClick={openPalette}
                className="ml-auto flex items-center gap-2.5 h-11 min-w-[220px] px-3 rounded-[10px] border border-line-2 bg-ink-2 text-muted text-[13px] cursor-pointer hover:text-fg">
                <Icon name="search" size={15}/>
                <span>Search agents, runs, settings</span>
                <span className="ml-auto font-mono text-[11px] border border-line-2 rounded px-1.5">⌘K</span>
            </button>
            {(<a href="#/approvals" className="inline-flex items-center gap-2 h-11 px-3 rounded-[10px] bg-[#f5c451]/10 border border-[#f5c451]/30 text-warn no-underline text-[12.5px] font-medium">
                <Icon name="shield" size={15}/>{str(pending) + (" approval waiting" if (pending == 1) else " approvals waiting")}
            </a>) if pending else None}
            <span className="inline-flex items-center gap-2 h-11 px-1 text-[12.5px] text-muted">
                <span className={"inline-block w-[7px] h-[7px] rounded-full " + ("bg-[#4ade80]" if daemonUp else "border border-faint")}></span>
                {(<a href="#/settings/models" className="text-muted no-underline hover:text-fg" title="Change the models Sigil uses">{chatModel}</a>) if chatModel else None}
                {(<span aria-hidden="true">·</span>) if chatModel else None}
                <a href="#/settings/system" className="text-muted no-underline hover:text-fg"
                    title={"Daemon running" if daemonUp else "Daemon not running: schedules will not fire"}>{"daemon running" if daemonUp else "daemon stopped"}</a>
            </span>
            <button type="button" onClick={flipTheme} aria-label={"Switch to dark theme" if light else "Switch to light theme"}
                className="inline-flex items-center justify-center w-11 h-11 rounded-[10px] border border-line-2 bg-transparent text-muted cursor-pointer hover:text-fg">
                <Icon name={"moon" if light else "sun"}/>
            </button>
        </header>

        {(<div role="status" className="flex flex-wrap items-center gap-x-3 gap-y-1 px-6 py-2.5 border-b border-warn/30 bg-warn/10 text-[13px] text-warn shrink-0">
            <span className="font-medium">No model is connected.</span>
            <span className="text-fg-2">{"Sigil cannot compile or chat until one is" + ((" (" + str(ov.connected.why) + ")") if ov.connected.why else "") + "."}</span>
            <a href="#/settings/connections" className="ml-auto font-medium text-warn no-underline hover:underline">Connect a model →</a>
        </div>) if (ov and ov.connected and (not ov.connected.ok) and (not onConnections)) else None}

        <main className={"min-w-0 flex flex-col " + ("flex-1 min-h-0" if studio else "")}>
            {if studio {
                <StudioPage route={parts} draft={draft} clearDraft={clearDraft} refresh={refresh} dark={not light}/>
            } elif page in ["dashboard", "home"] {
                <DashboardPage ov={ov} go={go} ask={ask} refresh={refresh}/>
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
                <DashboardPage ov={ov} go={go} ask={ask} refresh={refresh}/>
            }}
        </main>

        {(<Palette ov={ov} go={go} ask={ask} onClose={closePalette}/>) if palette else None}
    </div>;
}

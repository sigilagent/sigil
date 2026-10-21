"""Channels: where Sigil listens and replies.

A channel is a node on the agent's graph (src/channels.jac). A message that
arrives on one runs as a task, and the reply goes back on the same thread. The
top of the page is what is connected: the webhook every adapter posts to, and
each channel with its history, a test send and a way to remove it. Below it is a
card per provider Sigil has a guide for, with the steps to get a token.

A token is saved with the `secret_save` op, which runs in the server process and
writes the console's secrets file: it never rides on a command line, never
reaches the graph, and this page never shows it again.
"""

import from src.sigil_console { api_console }
import from .ui {
    PageHead, Icon, Note, Spinner, CARD, BTN_SM, BTN2_SM, BTN_GHOST_SM, BTN_BAD_SM, INP, LABEL, chip, dotCls
}
import from "./console_interop.js" { seen, remember, copyText, fmtAgo, focusId, scrollToEnd, nowMs }

glob KINDS: dict[str, str] = {
    "telegram": "Telegram", "slack": "Slack", "discord": "Discord", "whatsapp": "WhatsApp",
    "webhook": "Webhook", "cli": "CLI"
};
# What `channel_send`'s peer is for each provider.
glob PEERS: dict[str, str] = {
    "telegram": "Chat id", "slack": "Channel id", "discord": "Channel id", "whatsapp": "Phone number"
};
glob TOKEN_LABELS: dict[str, str] = {
    "telegram": "Bot token", "slack": "Bot token", "discord": "Bot token", "whatsapp": "Access token"
};
glob TOKEN_HINTS: dict[str, str] = {
    "telegram": "123456:ABC-DEF…", "slack": "xoxb-…", "discord": "Bot token", "whatsapp": "Access token"
};
glob SCOPES: dict[str, str] = {
    "per-peer": "One per person", "main": "One for everyone", "per-channel-peer": "One per person, per channel"
};
glob TEST_TEXT: str = "Test message from Sigil. If you can read this, the channel works.";

def _get(d: dict[str, any], k: str) -> any {
    return d[k] if (k in d) else "";
}

def _with(d: dict[str, any], k: str, v: any) -> dict[str, any] {
    # A copy of d with k set. A `{**d, k: v}` literal would not do: the client
    # compiler emits a bare key as the literal name "k".
    out: dict[str, any] = dict(d);
    out[k] = v;
    return out;
}

def _kind(k: any) -> str {
    s = str(k or "");
    if s in KINDS { return KINDS[s]; }
    return s.capitalize() if s else "Channel";
}

def _title(c: any) -> str {
    # A channel named after its kind reads as the provider; anything else by its name.
    return _kind(c.kind) if (str(c.name) == str(c.kind)) else str(c.name);
}

def _peerLabel(kind: str) -> str {
    return PEERS[kind] if (kind in PEERS) else "Peer";
}

def _delivery(d: str) -> str {
    if d == "webhook" { return "The provider pushes each message to Sigil's webhook."; }
    if d == "gateway-bridge" { return "Receives over a gateway bridge that forwards each message to Sigil's webhook."; }
    return ("Delivery: " + d) if d else "";
}

def _lastPeer(rows: list[any]) -> str {
    p = "";
    for r in rows { if (str(r.dir) == "in") and r.peer { p = str(r.peer); } }
    if not p { for r in rows { if r.peer { p = str(r.peer); } } }
    return p;
}

def _bubble(dir: str) -> str {
    if dir == "out" {
        return "self-end max-w-[85%] px-[11px] py-2 rounded-[12px_12px_4px_12px] bg-violet-500/10 border border-violet-500/25";
    }
    return "self-start max-w-[85%] px-[11px] py-2 rounded-[12px_12px_12px_4px] bg-ink-3";
}

def _meta(r: any) -> str {
    when = fmtAgo(float(r.ts) * 1000) if r.ts else "";
    who = "";
    if r.peer { who = ("from " + str(r.peer)) if (str(r.dir) == "in") else ("to " + str(r.peer)); }
    bits = [b for b in [when, who, ("edited" if r.edited else "")] if b];
    return " · ".join(bits);
}

def _lines(v: any) -> list[any] {
    if isinstance(v, list) { return [str(x) for x in v]; }
    return [str(v)] if v else [];
}

def:pub ChannelsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None], refresh: Callable[[], None]) -> JsxElement {
    has configured: list[any] = [];
    has guides: list[any] = [];
    has endpoint: str = "";
    has loaded: bool = False;
    has err: str = "";
    has busy: str = "";
    has flash: str = "";
    has flashTone: str = "ok";
    has sel: str = "";
    has hists: dict[str, any] = {};
    has histBusy: bool = False;
    has peer: str = "";
    has draft: str = "";
    has sendNote: str = "";
    has sendTone: str = "ok";
    has confirm: str = "";
    has opened: dict[str, any] = {};
    has tokens: dict[str, any] = {};
    has cardErr: dict[str, any] = {};
    has copied: bool = False;
    has example: bool = False;

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    def apply(m: any) {
        configured = list(m.configured) if m.configured else [];
        guides = list(m.guides) if m.guides else [];
        endpoint = str(m.endpoint or "");
    }

    async def load() {
        m: any = await call("channels", {});
        loaded = True;
        if m and (not m.error) { apply(remember("channels", m)); err = ""; }
        elif m { err = str(m.error); }
    }

    can with entry {
        prev: any = seen("channels");
        if prev { apply(prev); loaded = True; }
        load();
    }

    async def loadHist(name: str, fillPeer: bool) {
        histBusy = True;
        m: any = await call("channel_history", {"name": name, "n": 30});
        histBusy = False;
        if m and (not m.error) {
            got: list[any] = remember("channel_history:" + name, list(m));
            hists = _with(hists, name, got);
            if fillPeer and (sel == name) and (not peer.strip()) { peer = _lastPeer(got); }
            scrollToEnd("chan-hist");
        } elif m {
            sendNote = str(m.error);
            sendTone = "bad";
        }
    }

    def openHist(name: str) {
        if sel != name {
            sel = name;
            sendNote = "";
            draft = "";
            peer = "";
            cached: any = hists[name] if (name in hists) else seen("channel_history:" + name);
            if cached {
                hists = _with(hists, name, cached);
                peer = _lastPeer(cached);
            }
        }
        scrollToEnd("chan-hist");
        loadHist(name, True);
    }

    def openTest(name: str) {
        openHist(name);
        draft = TEST_TEXT;
        focusId("chan-text" if peer else "chan-peer");
    }

    async def send() {
        name = sel;
        p = peer.strip();
        t = draft.strip();
        kind = "";
        for c in configured { if str(c.name) == name { kind = str(c.kind); } }
        if not t { return; }
        if (not p) and (kind in PEERS) {
            sendNote = "Add the " + PEERS[kind].lower() + " to send to.";
            sendTone = "bad";
            focusId("chan-peer");
            return;
        }
        busy = "send";
        sendNote = "";
        m: any = await call("channel_send", {"channel": name, "peer": p, "text": t});
        busy = "";
        if m and (not m.error) and m.mid {
            draft = "";
            if m.delivered and m.note { sendNote = str(m.note); sendTone = "live"; }
            elif m.delivered { sendNote = "Delivered."; sendTone = "ok"; }
            else {
                sendNote = "Recorded on the graph, not delivered: " + str(m.delivery_error or "no transport");
                sendTone = "warn";
            }
            had: list[any] = list(hists[name]) if (name in hists) else [];
            hists = _with(hists, name, had + [{"mid": str(m.mid), "dir": "out", "peer": p, "text": t, "ts": nowMs() / 1000}]);
            scrollToEnd("chan-hist");
            loadHist(name, False);
        } else {
            sendNote = str(m.error) if m else "no response from Sigil";
            sendTone = "bad";
        }
    }

    async def removeChannel(name: str) {
        busy = "rm:" + name;
        m: any = await call("channel_remove", {"name": name});
        busy = "";
        confirm = "";
        if m and (not m.error) {
            configured = [c for c in configured if str(c.name) != name];
            if sel == name { sel = ""; }
            said = str(m.message or "");
            flash = ("Removed " + name + ".") if ((not said) or said.startswith("removed")) else said;
            flashTone = "ok";
            refresh();
            load();
        } else {
            flash = str(m.error) if m else "no response from Sigil";
            flashTone = "bad";
        }
    }

    def setTok(kind: str, v: str) { tokens = _with(tokens, kind, v); }

    def markSet(kind: str) {
        guides = [({**g, "token_set": True} if (str(g.kind) == kind) else g) for g in guides];
    }

    async def saveToken(g: any) {
        kind = str(g.kind);
        tok = str(_get(tokens, kind)).strip();
        if not tok { cardErr = _with(cardErr, kind, "Paste the token first."); return; }
        busy = "tok:" + kind;
        cardErr = _with(cardErr, kind, "");
        s: any = await call("secret_save", {"env": str(g.token_env), "value": tok});
        busy = "";
        if s and s.ok {
            tokens = _with(tokens, kind, "");
            markSet(kind);
            load();
        } else {
            cardErr = _with(cardErr, kind, str(s.error) if s else "no response from Sigil");
        }
    }

    async def connect(g: any) {
        kind = str(g.kind);
        tok = str(_get(tokens, kind)).strip();
        if (not tok) and (not g.token_set) {
            cardErr = _with(cardErr, kind, "Paste the token first. Sigil needs it to send replies.");
            return;
        }
        busy = "connect:" + kind;
        cardErr = _with(cardErr, kind, "");
        if tok {
            s: any = await call("secret_save", {"env": str(g.token_env), "value": tok});
            if (not s) or (not s.ok) {
                busy = "";
                cardErr = _with(cardErr, kind, str(s.error) if s else "no response from Sigil");
                return;
            }
            tokens = _with(tokens, kind, "");
            markSet(kind);
        }
        m: any = await call("channel_connect", {"kind": kind, "name": kind, "token_env": str(g.token_env)});
        busy = "";
        if m and (not m.error) and m.name {
            if not [c for c in configured if str(c.name) == str(m.name)] {
                configured = configured + [{"name": str(m.name), "kind": str(m.kind), "enabled": True,
                                            "dm_scope": "per-peer", "messages": 0}];
            }
            flash = "Connected " + _kind(kind) + ". Wire the provider to Sigil's webhook; the steps are on its card.";
            flashTone = "ok";
            refresh();
            load();
        } else {
            cardErr = _with(cardErr, kind, str(m.error) if m else "no response from Sigil");
        }
    }

    def copyUrl(url: str) {
        copied = bool(copyText(url));
        setTimeout(lambda { copied = False; }, 2000);
    }

    gby: dict[str, any] = {};
    for g in guides { gby[str(g.kind)] = g; }
    ckinds: list[str] = [str(c.kind) for c in configured];
    avail: list[any] = [g for g in guides if str(g.kind) not in ckinds];
    url = (str(window.location.origin) + endpoint) if endpoint else "";
    curl = "curl -X POST " + url + " -H 'Content-Type: application/json' -d '{\"channel\": \"webhook\", \"peer\": \"me\", \"text\": \"hello\"}'";
    selC: any = None;
    for c in configured { if str(c.name) == sel { selC = c; } }
    selKind = str(selC.kind) if selC else "";
    selTitle = _title(selC) if selC else sel;
    rows: list[any] = list(hists[sel]) if (sel and (sel in hists)) else [];

    return <div className="flex flex-col">
        <PageHead title="Channels" kicker="Connect · where Sigil listens and replies" onAsk={ask}
            askHint="“connect my Slack workspace”" tag="channels"/>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-6">
            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Note text={flash} tone={flashTone}/>) if flash else None}
            {(<Spinner label="Reading the channels…"/>) if (not loaded) else None}

            <section aria-labelledby="connected" className="flex flex-col gap-3">
                <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                    <h2 id="connected" className="m-0 text-[15px] font-semibold">Connected</h2>
                    <span className="text-xs text-muted">While the daemon runs, it keeps a bridge open for each enabled channel.</span>
                </div>
                {(<span className="text-[13px] text-muted">No channels yet. Add one below, or have any adapter post to the webhook.</span>) if (loaded and (not configured)) else None}

                <div className="flex flex-wrap gap-5 items-start">
                    <div className="flex-[999_1_520px] min-w-0 grid gap-3.5 grid-cols-[repeat(auto-fill,minmax(300px,1fr))]">
                        {if endpoint {
                            <article className={CARD + " p-4 flex flex-col gap-2.5"}>
                                <div className="flex items-center gap-2.5">
                                    <h3 className="m-0 text-[15px] font-semibold">Webhook</h3>
                                    <span className={chip("ok")}><span className={dotCls("ok")}></span>on</span>
                                </div>
                                <div className="font-mono text-xs px-2.5 py-2 rounded-lg bg-ink-1 text-fg-2 break-all">{"POST " + url}</div>
                                <span className="text-xs text-muted">Any adapter can post {"{channel, peer, text}"} here. The reply comes back in the response.</span>
                                <div className="flex flex-wrap gap-1.5">
                                    <button type="button" className={BTN2_SM} onClick={lambda (e: MouseEvent) { copyUrl(url); }}>
                                        <Icon name={"check" if copied else "copy"} size={13}/>{"Copied" if copied else "Copy URL"}
                                    </button>
                                    <button type="button" className={BTN_GHOST_SM} aria-expanded={"true" if example else "false"}
                                        onClick={lambda (e: MouseEvent) { example = not example; }}>Example request</button>
                                </div>
                                {(<pre className="m-0 px-2.5 py-2 rounded-lg bg-ink-1 text-[11.5px] font-mono text-fg-2 whitespace-pre-wrap break-all">{curl}</pre>) if example else None}
                            </article>
                        }}

                        {for c in configured {
                            <article key={"c-" + str(c.name)}
                                className={"rounded-xl bg-ink-2 border p-4 flex flex-col gap-2.5 " + ("border-violet-400/60" if (sel == str(c.name)) else "border-line")}>
                                <div className="flex items-center gap-2.5 min-w-0">
                                    <h3 className="m-0 text-[15px] font-semibold truncate">{_title(c)}</h3>
                                    {if not c.enabled {
                                        <span className={chip("warn")}>paused</span>
                                    } elif (str(c.kind) in gby) and (not gby[str(c.kind)].token_set) {
                                        <span className={chip("warn")}>token not set</span>
                                    } else {
                                        <span className={chip("ok")}><span className={dotCls("ok")}></span>on</span>
                                    }}
                                </div>
                                <dl className="m-0 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[12.5px]">
                                    {(<dt className="text-muted">Kind</dt>) if (str(c.name) != str(c.kind)) else None}
                                    {(<dd className="m-0 font-mono">{str(c.kind)}</dd>) if (str(c.name) != str(c.kind)) else None}
                                    <dt className="text-muted">Messages</dt>
                                    <dd className="m-0">{str(c.messages or 0)}</dd>
                                    {(<dt className="text-muted">Last peer</dt>) if ((str(c.name) in hists) and _lastPeer(hists[str(c.name)])) else None}
                                    {(<dd className="m-0 font-mono truncate">{_lastPeer(hists[str(c.name)])}</dd>) if ((str(c.name) in hists) and _lastPeer(hists[str(c.name)])) else None}
                                    <dt className="text-muted">Conversations</dt>
                                    <dd className="m-0">{SCOPES[str(c.dm_scope)] if (str(c.dm_scope) in SCOPES) else str(c.dm_scope)}</dd>
                                    {(<dt className="text-muted">Token</dt>) if (str(c.kind) in gby) else None}
                                    {(<dd className="m-0"><span className="font-mono">{str(gby[str(c.kind)].token_env)}</span>
                                        {(<span className="text-ok">{" · set"}</span>) if gby[str(c.kind)].token_set else (<span className="text-warn">{" · not set"}</span>)}
                                    </dd>) if (str(c.kind) in gby) else None}
                                </dl>

                                {if (str(c.kind) in gby) and (not gby[str(c.kind)].token_set) {
                                    <div className="flex flex-col gap-1.5">
                                        <div className="flex gap-2">
                                            <input type="password" autoComplete="off" spellCheck={False}
                                                aria-label={TOKEN_LABELS[str(c.kind)] if (str(c.kind) in TOKEN_LABELS) else "Token"}
                                                value={str(_get(tokens, str(c.kind)))}
                                                placeholder={TOKEN_HINTS[str(c.kind)] if (str(c.kind) in TOKEN_HINTS) else "Token"}
                                                onChange={lambda (e: ChangeEvent) { setTok(str(c.kind), e.target.value); }}
                                                className={INP + " flex-1 font-mono"}/>
                                            <button type="button" className={BTN_SM} disabled={busy == ("tok:" + str(c.kind))}
                                                onClick={lambda (e: MouseEvent) { saveToken(gby[str(c.kind)]); }}>
                                                {"Saving…" if (busy == ("tok:" + str(c.kind))) else "Save token"}
                                            </button>
                                        </div>
                                        {(<Note text={str(_get(cardErr, str(c.kind)))} tone="bad"/>) if _get(cardErr, str(c.kind)) else None}
                                    </div>
                                }}

                                {if confirm == str(c.name) {
                                    <div className="flex flex-wrap items-center gap-2 px-3 py-2.5 rounded-lg bg-bad/10 border border-bad/30 text-[12.5px]">
                                        <span className="flex-[1_1_100%] text-fg">Remove <span className="font-mono">{str(c.name)}</span>? Sigil stops answering on it, and its history goes with it. The token stays in your secrets.</span>
                                        <button type="button" className={BTN_BAD_SM} disabled={busy == ("rm:" + str(c.name))}
                                            onClick={lambda (e: MouseEvent) { removeChannel(str(c.name)); }}>
                                            {"Removing…" if (busy == ("rm:" + str(c.name))) else "Remove"}
                                        </button>
                                        <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { confirm = ""; }}>Cancel</button>
                                    </div>
                                } else {
                                    <div className="flex flex-wrap gap-1.5">
                                        <button type="button" className={BTN2_SM} aria-pressed={"true" if (sel == str(c.name)) else "false"}
                                            onClick={lambda (e: MouseEvent) { openHist(str(c.name)); }}>History</button>
                                        <button type="button" className={BTN_GHOST_SM}
                                            onClick={lambda (e: MouseEvent) { openTest(str(c.name)); }}>Send a test</button>
                                        <button type="button" className={BTN_BAD_SM}
                                            onClick={lambda (e: MouseEvent) { confirm = str(c.name); }}>Remove</button>
                                    </div>
                                }}

                                {if (str(c.kind) in gby) and _lines(gby[str(c.kind)].wire) {
                                    <details className="text-xs text-muted">
                                        <summary className="cursor-pointer">How messages reach Sigil</summary>
                                        <div className="mt-2 flex flex-col gap-1 font-mono text-[11.5px] leading-relaxed text-faint whitespace-pre-wrap break-words">
                                            {for (wi, w) in enumerate(_lines(gby[str(c.kind)].wire)) {
                                                <span key={str(wi)}>{w}</span>
                                            }}
                                        </div>
                                    </details>
                                }}
                            </article>
                        }}
                    </div>

                    {if sel {
                        <section aria-labelledby="hist" className={CARD + " flex-[1_1_340px] min-w-0 overflow-hidden flex flex-col"}>
                            <div className="flex items-center gap-2 px-4 py-3 border-b border-line">
                                <h3 id="hist" className="m-0 mr-auto text-sm font-semibold truncate">{selTitle + " · history"}</h3>
                                {(<Spinner/>) if histBusy else None}
                                <button type="button" aria-label="Reload the history" disabled={histBusy}
                                    className={BTN_GHOST_SM + " w-8 px-0"} onClick={lambda (e: MouseEvent) { loadHist(sel, False); }}>
                                    <Icon name="refresh" size={14}/>
                                </button>
                                <button type="button" aria-label="Close the history" className={BTN_GHOST_SM + " w-8 px-0"}
                                    onClick={lambda (e: MouseEvent) { sel = ""; }}>
                                    <Icon name="x" size={14}/>
                                </button>
                            </div>
                            <div id="chan-hist" className="px-4 py-3.5 flex flex-col gap-2.5 text-[13px] max-h-[460px] overflow-y-auto">
                                {if histBusy and (not rows) {
                                    <Spinner label="Reading the history…"/>
                                } elif not rows {
                                    <span className="text-[12.5px] text-muted">No messages on this channel yet.</span>
                                }}
                                {for (i, r) in enumerate(rows) {
                                    <div key={str(r.mid) if r.mid else ("m" + str(i))} className={_bubble(str(r.dir))}>
                                        <span className="whitespace-pre-wrap break-words">{str(r.text)}</span>
                                        <span className="block mt-0.5 text-[11px] text-muted">{_meta(r)}</span>
                                    </div>
                                }}
                            </div>
                            <div className="mt-auto px-4 py-3 border-t border-line flex flex-col gap-2">
                                <label className="flex items-center gap-2 text-xs text-muted">{_peerLabel(selKind)}
                                    <input id="chan-peer" value={peer} placeholder={"who to send to" if (selKind in PEERS) else "optional"}
                                        onChange={lambda (e: ChangeEvent) { peer = e.target.value; }}
                                        className={INP + " flex-1 h-8 font-mono"}/>
                                </label>
                                <div className="flex gap-2">
                                    <input id="chan-text" value={draft} aria-label={"Send as Sigil on " + selTitle} placeholder="Send as Sigil"
                                        onChange={lambda (e: ChangeEvent) { draft = e.target.value; }}
                                        onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { send(); } }}
                                        className={INP + " flex-1"}/>
                                    <button type="button" className={BTN2_SM + " h-9"} disabled={(busy == "send") or (not draft.strip())}
                                        onClick={lambda (e: MouseEvent) { send(); }}>{"Sending…" if (busy == "send") else "Send"}</button>
                                </div>
                                {(<Note text={sendNote} tone={sendTone}/>) if sendNote else None}
                            </div>
                        </section>
                    }}
                </div>
            </section>

            {if avail {
                <section aria-labelledby="add" className="flex flex-col gap-3">
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                        <h2 id="add" className="m-0 text-[15px] font-semibold">Add a channel</h2>
                        <span className="text-xs text-muted">The token is saved to your secrets file by the server itself, never on a command line. This page does not show it again.</span>
                    </div>
                    <div className="grid gap-3.5 grid-cols-[repeat(auto-fill,minmax(300px,1fr))]">
                        {for g in avail {
                            <article key={"g-" + str(g.kind)} className={CARD + " p-4 flex flex-col gap-2.5"}>
                                <div className="flex items-center gap-2.5">
                                    <h3 className="m-0 text-[15px] font-semibold">{_kind(g.kind)}</h3>
                                    {(<span className={chip("ok")}>token set</span>) if g.token_set else (<span className={chip("")}>not set up</span>)}
                                </div>
                                {(<p className="m-0 text-[12.5px] text-muted">{_delivery(str(g.delivery))}</p>) if g.delivery else None}

                                {if not _get(opened, str(g.kind)) {
                                    <button type="button" className={BTN2_SM + " self-start"}
                                        onClick={lambda (e: MouseEvent) { opened = _with(opened, str(g.kind), True); }}>
                                        {"Set up " + _kind(g.kind)}
                                    </button>
                                } else {
                                    <span className={LABEL}>Get a token</span>
                                    if isinstance(g.get_token, list) {
                                        <ol className="m-0 pl-[18px] list-decimal text-[12.5px] text-fg-2 flex flex-col gap-1">
                                            {for (si, st) in enumerate(g.get_token) {
                                                <li key={str(si)} className="break-words">{str(st)}</li>
                                            }}
                                        </ol>
                                    } elif g.get_token {
                                        <p className="m-0 text-[12.5px] text-fg-2 whitespace-pre-wrap break-words">{str(g.get_token)}</p>
                                    }
                                    <label className="flex flex-col gap-1.5 text-xs text-muted">
                                        {TOKEN_LABELS[str(g.kind)] if (str(g.kind) in TOKEN_LABELS) else "Token"}
                                        <input type="password" autoComplete="off" spellCheck={False}
                                            value={str(_get(tokens, str(g.kind)))}
                                            placeholder={("Leave empty to keep the one that is set") if g.token_set else (TOKEN_HINTS[str(g.kind)] if (str(g.kind) in TOKEN_HINTS) else "Token")}
                                            onChange={lambda (e: ChangeEvent) { setTok(str(g.kind), e.target.value); }}
                                            className={INP + " font-mono"}/>
                                    </label>
                                    if g.token_set {
                                        <span className="text-xs text-muted"><span className="font-mono">{str(g.token_env)}</span> is already set, so you can connect without pasting it again. A new token replaces it.</span>
                                    } else {
                                        <span className="text-xs text-muted">Saved as <span className="font-mono">{str(g.token_env)}</span> in your secrets file on this machine. Sigil reads it when it sends; it never goes into the graph.</span>
                                    }
                                    <div className="flex flex-wrap gap-1.5">
                                        <button type="button" className={BTN_SM} disabled={busy == ("connect:" + str(g.kind))}
                                            onClick={lambda (e: MouseEvent) { connect(g); }}>
                                            {"Connecting…" if (busy == ("connect:" + str(g.kind))) else "Connect"}
                                        </button>
                                        <button type="button" className={BTN_GHOST_SM}
                                            onClick={lambda (e: MouseEvent) { ask("Walk me through connecting " + _kind(g.kind) + " to Sigil."); }}>
                                            Walk me through it in chat
                                        </button>
                                    </div>
                                    if _get(cardErr, str(g.kind)) {
                                        <Note text={str(_get(cardErr, str(g.kind)))} tone="bad"/>
                                    }
                                    if _lines(g.wire) {
                                        <details className="text-xs text-muted">
                                            <summary className="cursor-pointer">{"How messages reach Sigil · " + str(g.delivery or "webhook") + " delivery"}</summary>
                                            <div className="mt-2 flex flex-col gap-1 font-mono text-[11.5px] leading-relaxed text-faint whitespace-pre-wrap break-words">
                                                {for (wi, w) in enumerate(_lines(g.wire)) {
                                                    <span key={str(wi)}>{w}</span>
                                                }}
                                            </div>
                                        </details>
                                    }
                                }}
                            </article>
                        }}
                    </div>
                </section>
            }}
        </div>
    </div>;
}

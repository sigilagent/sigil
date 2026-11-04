"""Channels: where Sigil listens and replies.

A channel is a node on the agent's graph (src/channels.jac). A message that
arrives on one runs as a task, and the reply goes back on the same thread. The
page is two lists, the shape other claw-style consoles settled on: what is
connected (a row each, with status; a row opens its history, a test send and
removal), then what can be added (a row each with one line on what connecting
costs). Set up opens a dialog with the provider's steps and the fields it
needs. The plain webhook any adapter can post to is the last row.

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
    "telegram": "Chat id", "slack": "Channel id", "discord": "Channel id"
};
glob TOKEN_LABELS: dict[str, str] = {
    "telegram": "Bot token", "slack": "Bot token", "discord": "Bot token", "whatsapp": "API key"
};
glob TOKEN_HINTS: dict[str, str] = {
    "telegram": "123456:ABC-DEF…", "slack": "xoxb-…", "discord": "Bot token", "whatsapp": "API key from the agent's Chat info"
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

def _nextStep(delivery: str) -> str {
    # What to do right after Connect, by how the provider reaches Sigil.
    if delivery == "long-poll" { return "Send it a message to try it; Sigil answers while the daemon runs."; }
    if delivery == "gateway-bridge" { return "Replies work now. Receiving needs the bridge under How messages reach Sigil."; }
    return "Next, give its bridge a public URL; the steps are under How messages reach Sigil.";
}

def _tile(kind: str) -> JsxElement {
    # A neutral initial in a square: which provider at a glance, no brand marks.
    k = str(kind or "?");
    return <span aria-hidden="true"
        className="shrink-0 w-9 h-9 rounded-lg bg-ink-3 border border-line-2 grid place-items-center text-[14px] font-semibold text-fg-2">{k[:1].upper()}</span>;
}

def _wire(lines: list[any]) -> JsxElement {
    return <details className="text-xs text-muted">
        <summary className="cursor-pointer select-none">How messages reach Sigil</summary>
        <div className="mt-2 flex flex-col gap-1 font-mono text-[11.5px] leading-relaxed text-faint whitespace-pre-wrap break-words">
            {for (wi, w) in enumerate(lines) {
                <span key={str(wi)}>{w}</span>
            }}
        </div>
    </details>;
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
    has setup: str = "";
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
        wa = len([c for c in configured if (str(c.name) == name) and (str(c.kind) == "whatsapp")]) > 0;
        focusId("chan-text" if (peer or wa) else "chan-peer");
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

    async def saveSecret(kind: str, env: str, val: str) -> bool {
        s: any = await call("secret_save", {"env": env, "value": val});
        if s and s.ok { return True; }
        cardErr = _with(cardErr, kind, str(s.error) if s else "no response from Sigil");
        return False;
    }

    async def connect(g: any) {
        kind = str(g.kind);
        tok = str(_get(tokens, kind)).strip();
        if (not tok) and (not g.token_set) {
            cardErr = _with(cardErr, kind, "Paste the token first. Sigil needs it to send replies.");
            focusId("tok-" + kind);
            return;
        }
        busy = "connect:" + kind;
        cardErr = _with(cardErr, kind, "");
        if tok {
            if not (await saveSecret(kind, str(g.token_env), tok)) { busy = ""; return; }
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
            setup = "";
            flash = "Connected " + _kind(kind) + ". " + _nextStep(str(g.delivery));
            flashTone = "ok";
            openHist(str(m.name));
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
    sg: any = gby[setup] if (setup and (setup in gby)) else None;
    ROW = "flex items-center gap-3 px-4 py-3 min-w-0";

    def statusChip(c: any) -> JsxElement {
        k = str(c.kind);
        if not c.enabled { return <span className={chip("warn")}>paused</span>; }
        if (k in gby) and (not gby[k].token_set) { return <span className={chip("warn")}>needs token</span>; }
        return <span className={chip("ok")}><span className={dotCls("ok")}></span>on</span>;
    }

    def subline(c: any) -> str {
        # The list's count is from the last `channels` read; a history read since is newer.
        n = int(c.messages or 0);
        if (str(c.name) in hists) and (len(hists[str(c.name)]) > n) { n = len(hists[str(c.name)]); }
        bits: list[str] = [(str(n) + (" message" if n == 1 else " messages")) if n else "no messages yet"];
        if str(c.name) in hists {
            lp = _lastPeer(hists[str(c.name)]);
            if lp { bits.append("last with " + lp); }
        }
        if str(c.name) != str(c.kind) { bits.append(_kind(c.kind)); }
        return " · ".join(bits);
    }

    def detail(c: any) -> JsxElement {
        k = str(c.kind);
        nm = str(c.name);
        g: any = gby[k] if (k in gby) else None;
        return <div className="px-4 pb-4 pt-1 flex flex-col gap-3 border-t border-line bg-ink-1/40">
            {if g and (not g.token_set) {
                <div className="flex flex-col gap-1.5 pt-3">
                    <span className="text-xs text-warn">{"Its token is not set, so Sigil cannot reply on " + _title(c) + "."}</span>
                    <div className="flex gap-2">
                        <input type="password" autoComplete="off" spellCheck={False}
                            aria-label={TOKEN_LABELS[k] if (k in TOKEN_LABELS) else "Token"}
                            value={str(_get(tokens, k))}
                            placeholder={TOKEN_HINTS[k] if (k in TOKEN_HINTS) else "Token"}
                            onChange={lambda (e: ChangeEvent) { setTok(k, e.target.value); }}
                            className={INP + " flex-1 font-mono"}/>
                        <button type="button" className={BTN_SM} disabled={busy == ("tok:" + k)}
                            onClick={lambda (e: MouseEvent) { saveToken(g); }}>
                            {"Saving…" if (busy == ("tok:" + k)) else "Save token"}
                        </button>
                    </div>
                    {(<Note text={str(_get(cardErr, k))} tone="bad"/>) if _get(cardErr, k) else None}
                </div>
            }}

            <div className="flex items-center gap-2 pt-3">
                <span className={LABEL + " mr-auto"}>History</span>
                {(<Spinner/>) if histBusy else None}
                <button type="button" aria-label="Reload the history" disabled={histBusy}
                    className={BTN_GHOST_SM + " w-8 px-0"} onClick={lambda (e: MouseEvent) { loadHist(nm, False); }}>
                    <Icon name="refresh" size={14}/>
                </button>
            </div>
            <div id="chan-hist" className="flex flex-col gap-2.5 text-[13px] max-h-[340px] overflow-y-auto">
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
            <div className="flex flex-col gap-2">
                {(<span className="text-xs text-muted">{"Replies go to you, the person who created the agent." if _lastPeer(rows) else "Message your agent from WhatsApp first. Sigil learns where to reply from your message."}</span>) if (selKind == "whatsapp") else None}
                <div className="flex flex-wrap gap-2">
                    {if selKind != "whatsapp" {
                    <input id="chan-peer" value={peer} aria-label={_peerLabel(selKind)}
                        placeholder={(_peerLabel(selKind) + " to send to") if (selKind in PEERS) else "Peer (optional)"}
                        onChange={lambda (e: ChangeEvent) { peer = e.target.value; }}
                        className={INP + " w-[180px] font-mono"}/>
                    }}
                    <input id="chan-text" value={draft} aria-label={"Send as Sigil on " + selTitle} placeholder="Send as Sigil"
                        onChange={lambda (e: ChangeEvent) { draft = e.target.value; }}
                        onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { send(); } }}
                        className={INP + " flex-[1_1_220px]"}/>
                    <button type="button" className={BTN2_SM + " h-9"} disabled={(busy == "send") or (not draft.strip())}
                        onClick={lambda (e: MouseEvent) { send(); }}>{"Sending…" if (busy == "send") else "Send"}</button>
                </div>
                {(<Note text={sendNote} tone={sendTone}/>) if sendNote else None}
            </div>

            {if confirm == nm {
                <div className="flex flex-wrap items-center gap-2 px-3 py-2.5 rounded-lg bg-bad/10 border border-bad/30 text-[12.5px]">
                    <span className="flex-[1_1_100%] text-fg">Remove <span className="font-mono">{nm}</span>? Sigil stops answering on it, and its history goes with it. The token stays in your secrets.</span>
                    <button type="button" className={BTN_BAD_SM} disabled={busy == ("rm:" + nm)}
                        onClick={lambda (e: MouseEvent) { removeChannel(nm); }}>
                        {"Removing…" if (busy == ("rm:" + nm)) else "Remove"}
                    </button>
                    <button type="button" className={BTN_GHOST_SM} onClick={lambda (e: MouseEvent) { confirm = ""; }}>Cancel</button>
                </div>
            } else {
                <div className="flex flex-wrap items-center gap-1.5">
                    <button type="button" className={BTN_GHOST_SM}
                        onClick={lambda (e: MouseEvent) { openTest(nm); }}>Send a test</button>
                    <span className="text-xs text-muted mx-1.5">{"Conversations: " + (SCOPES[str(c.dm_scope)] if (str(c.dm_scope) in SCOPES) else str(c.dm_scope)).lower()}</span>
                    <button type="button" className={BTN_BAD_SM + " ml-auto"}
                        onClick={lambda (e: MouseEvent) { confirm = nm; }}>Remove</button>
                </div>
            }}
            {(_wire(_lines(g.wire))) if (g and _lines(g.wire)) else None}
        </div>;
    }

    return <div className="flex flex-col">
        <PageHead title="Channels" kicker="Connect · where Sigil listens and replies" onAsk={ask}
            askHint="“connect my Slack workspace”" tag="channels"/>

        <div className="px-7 pt-5 pb-10 flex flex-col gap-7 max-w-[860px]">
            {(<Note text={err} tone="bad"/>) if err else None}
            {(<Note text={flash} tone={flashTone}/>) if flash else None}
            {(<Spinner label="Reading the channels…"/>) if (not loaded) else None}

            <section aria-labelledby="connected" className="flex flex-col gap-2.5">
                <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                    <h2 id="connected" className="m-0 text-[15px] font-semibold">Connected</h2>
                    <span className="text-xs text-muted">While the daemon runs, it keeps a bridge open for each enabled channel.</span>
                </div>
                {if loaded and (not configured) {
                    <div className={CARD + " px-4 py-5 text-[13px] text-muted"}>No channels yet. Pick one below to get started.</div>
                } elif configured {
                    <ul className={CARD + " m-0 p-0 list-none divide-y divide-line overflow-hidden"}>
                        {for c in configured {
                            <li key={"c-" + str(c.name)} className="flex flex-col">
                                <button type="button" aria-expanded={"true" if (sel == str(c.name)) else "false"}
                                    onClick={lambda (e: MouseEvent) { if sel == str(c.name) { sel = ""; } else { openHist(str(c.name)); } }}
                                    className={ROW + " w-full text-left bg-transparent border-0 cursor-pointer hover:bg-ink-3/50 text-fg"}>
                                    {_tile(str(c.kind))}
                                    <span className="flex-1 min-w-0 flex flex-col">
                                        <span className="text-[14px] font-semibold truncate">{_title(c)}</span>
                                        <span className="text-xs text-muted truncate">{subline(c)}</span>
                                    </span>
                                    {statusChip(c)}
                                    <Icon name="chevron" size={15} cls={"text-muted transition-transform " + ("rotate-90" if (sel == str(c.name)) else "")}/>
                                </button>
                                {(detail(c)) if (sel == str(c.name)) else None}
                            </li>
                        }}
                    </ul>
                }}
            </section>

            <section aria-labelledby="add" className="flex flex-col gap-2.5">
                <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                    <h2 id="add" className="m-0 text-[15px] font-semibold">Add a channel</h2>
                    <span className="text-xs text-muted">Pick a service and follow the steps.</span>
                </div>
                <ul className={CARD + " m-0 p-0 list-none divide-y divide-line overflow-hidden"}>
                    {for g in avail {
                        <li key={"g-" + str(g.kind)} className={ROW}>
                            {_tile(str(g.kind))}
                            <span className="flex-1 min-w-0 flex flex-col">
                                <span className="text-[14px] font-semibold">{_kind(g.kind)}</span>
                                <span className="text-xs text-muted">{str(g.summary) if g.summary else _delivery(str(g.delivery))}</span>
                            </span>
                            {(<span className={chip("ok")}>token saved</span>) if g.token_set else None}
                            <button type="button" className={BTN2_SM}
                                onClick={lambda (e: MouseEvent) { setup = str(g.kind); cardErr = _with(cardErr, str(g.kind), ""); }}>Set up</button>
                        </li>
                    }}
                    {if endpoint {
                        <li className="flex flex-col">
                            <div className={ROW + " flex-wrap"}>
                                <span aria-hidden="true" className="shrink-0 w-9 h-9 rounded-lg bg-ink-3 border border-line-2 grid place-items-center text-fg-2"><Icon name="plug" size={16}/></span>
                                <span className="flex-[1_1_220px] min-w-0 flex flex-col">
                                    <span className="text-[14px] font-semibold">Your own adapter</span>
                                    <span className="text-xs text-muted">Anything that can POST {"{channel, peer, text}"} to the webhook. The reply comes back in the response.</span>
                                </span>
                                <span className="flex gap-1.5 ml-auto">
                                    <button type="button" className={BTN_GHOST_SM} aria-expanded={"true" if example else "false"}
                                        onClick={lambda (e: MouseEvent) { example = not example; }}>Example</button>
                                    <button type="button" className={BTN2_SM} onClick={lambda (e: MouseEvent) { copyUrl(url); }}>
                                        <Icon name={"check" if copied else "copy"} size={13}/>{"Copied" if copied else "Copy URL"}
                                    </button>
                                </span>
                            </div>
                            {if example {
                                <div className="px-4 pb-3.5 flex flex-col gap-2">
                                    <div className="font-mono text-xs px-2.5 py-2 rounded-lg bg-ink-1 text-fg-2 break-all">{"POST " + url}</div>
                                    <pre className="m-0 px-2.5 py-2 rounded-lg bg-ink-1 text-[11.5px] font-mono text-fg-2 whitespace-pre-wrap break-all">{curl}</pre>
                                </div>
                            }}
                        </li>
                    }}
                </ul>
            </section>
        </div>

        {if sg {
            <div className="fixed inset-0 z-50 flex items-start justify-center px-4 pt-[10vh] pb-10"
                onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Escape" { setup = ""; } }}>
                <div aria-hidden="true" className="absolute inset-0 bg-ink-0/80 backdrop-blur-[2px]"
                    onClick={lambda (e: MouseEvent) { setup = ""; }}></div>
                <div role="dialog" aria-modal="true" aria-labelledby="setup-title"
                    className="relative w-[520px] max-w-full max-h-[80vh] flex flex-col rounded-2xl bg-ink-2 border border-line-2 shadow-2xl overflow-hidden">
                    <div className="flex items-start gap-3 px-5 py-4 border-b border-line">
                        {_tile(str(sg.kind))}
                        <div className="flex-1 min-w-0 flex flex-col">
                            <h2 id="setup-title" className="m-0 text-[16px] font-semibold">{"Set up " + _kind(sg.kind)}</h2>
                            <span className="text-xs text-muted">{str(sg.summary) if sg.summary else _delivery(str(sg.delivery))}</span>
                        </div>
                        <button type="button" aria-label="Close" className={BTN_GHOST_SM + " w-8 px-0"}
                            onClick={lambda (e: MouseEvent) { setup = ""; }}><Icon name="x" size={14}/></button>
                    </div>

                    <div className="px-5 py-4 flex flex-col gap-5 overflow-y-auto min-h-0">
                        <div className="flex flex-col gap-2">
                            <span className={LABEL}>{"1 · Create the " + ("agent" if (str(sg.kind) == "whatsapp") else "bot")}</span>
                            {if isinstance(sg.get_token, list) {
                                <ol className="m-0 pl-[18px] list-decimal text-[13px] text-fg-2 flex flex-col gap-1.5">
                                    {for (si, st) in enumerate(sg.get_token) {
                                        <li key={str(si)} className="break-words">{str(st)}</li>
                                    }}
                                </ol>
                            } elif sg.get_token {
                                <p className="m-0 text-[13px] text-fg-2 whitespace-pre-wrap break-words">{str(sg.get_token)}</p>
                            }}
                            {if sg.link and (len(sg.link) > 1) {
                                <a href={str(sg.link[1])} target="_blank" rel="noopener noreferrer"
                                    className={BTN2_SM + " self-start no-underline"}>
                                    {str(sg.link[0])}<Icon name="external" size={13}/>
                                </a>
                            }}
                        </div>

                        <div className="flex flex-col gap-2">
                            <span className={LABEL}>{"2 · Paste the " + (TOKEN_LABELS[str(sg.kind)] if (str(sg.kind) in TOKEN_LABELS) else "token").lower()}</span>
                            <label className="flex flex-col gap-1.5 text-xs text-muted">
                                {TOKEN_LABELS[str(sg.kind)] if (str(sg.kind) in TOKEN_LABELS) else "Token"}
                                <input id={"tok-" + str(sg.kind)} type="password" autoComplete="off" spellCheck={False} autoFocus={True}
                                    value={str(_get(tokens, str(sg.kind)))}
                                    placeholder={("Leave empty to keep the one that is set") if sg.token_set else (TOKEN_HINTS[str(sg.kind)] if (str(sg.kind) in TOKEN_HINTS) else "Token")}
                                    onChange={lambda (e: ChangeEvent) { setTok(str(sg.kind), e.target.value); }}
                                    onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { connect(sg); } }}
                                    className={INP + " font-mono"}/>
                            </label>
                            <span className="text-xs text-muted">
                                {"Saved as "}<span className="font-mono">{str(sg.token_env)}</span>
                                {" in your secrets file on this machine. Sigil reads it when it sends; it never goes into the graph, and this page does not show it again."}
                            </span>
                        </div>

                        {(_wire(_lines(sg.wire))) if _lines(sg.wire) else None}
                        {(<Note text={str(_get(cardErr, str(sg.kind)))} tone="bad"/>) if _get(cardErr, str(sg.kind)) else None}
                    </div>

                    <div className="flex flex-wrap items-center gap-2 px-5 py-3.5 border-t border-line">
                        <button type="button" className={BTN_SM} disabled={busy == ("connect:" + str(sg.kind))}
                            onClick={lambda (e: MouseEvent) { connect(sg); }}>
                            {"Connecting…" if (busy == ("connect:" + str(sg.kind))) else "Connect"}
                        </button>
                        <button type="button" className={BTN_GHOST_SM}
                            onClick={lambda (e: MouseEvent) { k = _kind(sg.kind); setup = ""; ask("Walk me through connecting " + k + " to Sigil."); }}>
                            Walk me through it in chat
                        </button>
                    </div>
                </div>
            </div>
        }}
    </div>;
}

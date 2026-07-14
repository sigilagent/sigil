"""Sessions & transcripts — OpenClaw parity for conversational scope.

A `Session` node holds a rolling transcript of turns keyed by (channel, scope),
where the scope follows the channel's `dm_scope` (main | per-peer | per-channel-peer)
— so two peers on a per-peer channel keep separate transcripts. Transcripts reset
daily (OpenClaw's daily reset). `session_context` projects the recent turns as
run-time context (bounded), and `channels.inbound` records each turn.
"""

import time;
import from .sigil { awaken, Soul }
import from datetime { date }

edge Sessioned {}   # Soul -> Session

node Session {
    has key: str;          # "<channel>:<scope-key>"
    has channel: str = "";
    has scope: str = "";
    has day: str = "";     # yyyy-mm-dd of the current transcript (for the daily reset)
    has turns: list = [];  # [{role, text, ts}]
}

def _today() -> str { return date.today().isoformat(); }

def _scope_key(peer: str, dm_scope: str, channel: str) -> str {
    if dm_scope == "main" { return "main"; }
    if dm_scope == "per-channel-peer" { return channel + "/" + peer; }
    return peer;   # per-peer (default)
}

def _sessions(soul: Soul) -> list[Session] { return [soul -->[?:Session]]; }

def _get(channel: str, peer: str, dm_scope: str) -> Session {
    soul = awaken();
    key = channel + ":" + _scope_key(peer, dm_scope, channel);
    for s in _sessions(soul) {
        if s.key == key {
            if s.day != _today() { s.turns = []; s.day = _today(); }   # daily reset
            return s;
        }
    }
    s = Session(key=key, channel=channel, scope=_scope_key(peer, dm_scope, channel), day=_today(), turns=[]);
    soul +>:Sessioned:+> s;
    return s;
}

def session_note(channel: str, peer: str, dm_scope: str, role: str, text: str) -> str {
    s = _get(channel, peer, dm_scope);
    s.turns = s.turns + [{"role": role, "text": text, "ts": time.time()}];
    return s.key;
}

def session_show(channel: str, peer: str, dm_scope: str = "per-peer") -> list {
    return list(_get(channel, peer, dm_scope).turns);
}

def session_context(channel: str, peer: str, dm_scope: str = "per-peer", n: int = 6) -> str {
    recent: list = list(_get(channel, peer, dm_scope).turns)[-n:];
    parts: list = [];
    for t in recent { parts.append(str(t["role"]) + ": " + str(t["text"])); }
    return "\n".join(parts);
}

def session_reset(channel: str, peer: str, dm_scope: str = "per-peer") -> str {
    s = _get(channel, peer, dm_scope);
    s.turns = [];
    return "reset session " + s.key;
}

def session_list() -> list {
    soul = awaken();
    return [{"key": s.key, "day": s.day, "turns": len(list(s.turns))} for s in _sessions(soul)];
}

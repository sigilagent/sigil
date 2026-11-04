"""Interrupting a chat turn: stop at the next safe point, keep what was done.

A turn can run for minutes. When the person writes again in the middle of it
("actually, only the top 3", "stop"), the turn should stop, take the new message
into account and carry on, not finish an answer to the old question first. The
terminal chat always had this (^C); the web console and the channels did not:
a WhatsApp message sent mid-turn waited until the turn ended and then ran as an
unrelated turn.

A turn opens a scope (`begin_turn`). Anyone may then ask it to stop
(`request_interrupt`): from the same process (the web console, whose turns run
in the Observatory) or from another one (a channel bridge, whose turn runs in a
`channel inbound` child) through a flag file named after the scope, which is safe
to write at any moment, even while the child is still starting. The turn checks
at its safe points, each streamed token and each tool call's start and end
(`interrupt_point`), and raises KeyboardInterrupt there, which chat_turn already
turns into "the answer so far, marked interrupted". Work a tool finished stays
done, and the graph writes it made were committed at the tool's checkpoint.
"""

import os;
import time;

glob _TURN: dict[str, any] = {"scope": "", "asked": False, "checked": 0.0};

def _flag_dir() -> str {
    from_env = str(os.environ.get("SIGIL_HOME") or "");
    home = from_env if from_env else os.path.expanduser("~/.sigil");
    d = os.path.join(home, "run", "interrupts");
    try { os.makedirs(d, exist_ok=True); } except Exception as e { }
    return d;
}

def flag_path(scope: str) -> str {
    safe = "".join([c for c in str(scope) if c.isalnum() or c in "-_."]);
    return os.path.join(_flag_dir(), safe or "turn");
}

def channel_scope(pid: int) -> str { return "channel-" + str(pid); }

def begin_turn(scope: str) -> None {
    _TURN["scope"] = str(scope or "");
    _TURN["asked"] = False;
    _TURN["checked"] = 0.0;
    return None;
}

def end_turn() -> None {
    s = str(_TURN["scope"]);
    _TURN["scope"] = "";
    _TURN["asked"] = False;
    if s { clear_interrupt(s); }
    return None;
}

def request_interrupt(scope: str) -> bool {
    # Ask the turn running under `scope` to stop. True when one is running here
    # (in this process); the flag file reaches one in another process.
    s = str(scope or "");
    if not s { return False; }
    try {
        with open(flag_path(s), "w") as f { f.write(str(time.time())); }
    } except Exception as e { }
    if s == str(_TURN["scope"]) {
        _TURN["asked"] = True;
        return True;
    }
    return False;
}

def clear_interrupt(scope: str) -> None {
    try { os.remove(flag_path(scope)); } except Exception as e { }
    return None;
}

def interrupt_requested() -> bool {
    s = str(_TURN["scope"]);
    if not s { return False; }
    if _TURN["asked"] { return True; }
    now = time.time();
    # a stat at most four times a second, not one per token
    if (now - float(_TURN["checked"])) < 0.25 { return False; }
    _TURN["checked"] = now;
    if os.path.exists(flag_path(s)) {
        _TURN["asked"] = True;
        return True;
    }
    return False;
}

def interrupt_point() -> None {
    # A safe point: stop here if someone asked. Fires once per request.
    if interrupt_requested() {
        _TURN["asked"] = False;
        clear_interrupt(str(_TURN["scope"]));
        raise KeyboardInterrupt("interrupted by a new message");
    }
    return None;
}

def interrupted_note(reply: str, tools: list[str]) -> str {
    # What the conversation keeps of an interrupted turn, so the next turn knows
    # what was asked, what was already done, and that it should carry on.
    parts: list[str] = ["(Interrupted by the user's next message before this answer was finished."];
    if tools { parts.append(" Already done: " + "; ".join(tools[-8:]) + "."); }
    said = " ".join(str(reply or "").split());
    if said { parts.append(" Said so far: " + (said[:1200] + ("…" if len(said) > 1200 else "")) ); }
    parts.append(" Carry on with the request, taking the new message into account, unless it changes the subject.)");
    return "".join(parts);
}

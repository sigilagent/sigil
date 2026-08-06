"""Channel bridges — the long-lived process that carries a conversation.

One bridge per channel: it waits for messages (long poll, or an HTTP listener for
providers that push), hands each to the agent, and sends the reply back. The
daemon supervises them, so a channel stays connected with nothing open on screen.

The awkward constraint shapes the whole design: **a bridge may not answer the
message itself.** A long-lived jac process serves the graph it loaded at startup,
so a bridge that called `inbound()` in-process would answer out of a snapshot —
memory taught an hour ago missing, a skill compiled since invisible. Every
message is handed to a fresh `sigil channel inbound` subprocess instead, which
reads the current graph, and the bridge only moves bytes.

That costs one process start per message. It buys an agent that knows what it
learned five minutes ago, which is the entire point of a channel.
"""

import os;
import sys;
import json;
import time;
import signal;
import subprocess;
import from pathlib { Path }
import from .sigil_core { awaken }
import from .channels { Channel, _channels }
import from .sigil_secrets { resolve_credential }
import from .sigil_runtime {
    run_dir, write_pidfile, clear_pidfile, process_running, read_pid, pid_alive,
    _jac_bin, entry_script, project_root
}
import from .sigil_transports {
    deliver, normalize_inbound, poll_telegram, supports_polling
}

glob REPLY_MARKER: str = "<<<SIGIL_REPLY>>>";
glob _STOP: dict = {"now": False};

def bridge_pid_name(channel: str) -> str {
    return "bridge-" + str(channel);
}

def bridge_running(channel: str) -> bool {
    return process_running(bridge_pid_name(channel));
}

def running_bridges() -> list[str] {
    # Read from the pidfiles, not from the channel list: a bridge for a channel
    # that has since been removed is exactly the orphan worth finding.
    out: list[str] = [];
    try {
        names = sorted(os.listdir(run_dir()));
    } except Exception as e {
        return out;
    }
    for f in names {
        if f.startswith("bridge-") and f.endswith(".pid") {
            chan = f[len("bridge-"):-len(".pid")];
            if process_running(bridge_pid_name(chan)) { out.append(chan); }
        }
    }
    return out;
}

def stop_bridge(channel: str, timeout_s: int = 15) -> bool {
    pid = int(read_pid(bridge_pid_name(channel)));
    if (pid <= 0) or (not pid_alive(pid)) {
        clear_pidfile(bridge_pid_name(channel));
        return False;
    }
    try {
        os.kill(pid, int(signal.SIGTERM));
    } except Exception as e {
        return False;
    }
    waited = 0.0;
    while waited < timeout_s {
        if not pid_alive(pid) {
            clear_pidfile(bridge_pid_name(channel));
            return True;
        }
        time.sleep(0.5);
        waited += 0.5;
    }
    return False;
}

def offset_path(channel: str) -> str {
    # Long-poll cursor. On disk rather than on the graph: the bridge cannot write
    # the graph safely (see the module note), and replaying handled updates after
    # a restart would answer the same message twice.
    return os.path.join(run_dir(), "bridge-" + str(channel) + ".offset");
}

def read_offset(channel: str) -> int {
    p = Path(offset_path(channel));
    if not p.exists() { return 0; }
    try {
        return int((p.read_text() or "0").strip() or "0");
    } except Exception as e {
        return 0;
    }
}

def write_offset(channel: str, value: int) -> None {
    try {
        Path(offset_path(channel)).write_text(str(int(value)));
    } except Exception as e {
        return None;
    }
    return None;
}

# ---------------------------------------------------------------------------
# Channel config, resolved once at bridge start
# ---------------------------------------------------------------------------
def channel_config(name: str) -> dict {
    # {kind, token, target, enabled, dm_scope}. `Channel.config` holds a
    # `secret:<name>` reference, never a value — resolve_refs pulls it from the
    # environment at run time so the token stays off the graph and out of logs.
    soul = awaken();
    for c in _channels(soul) {
        if c.name == name {
            raw = str(c.config or "");
            resolved = str(resolve_credential(raw)) if raw else "";
            # a config of "<credential>|<target>" carries the second coordinate
            # some providers need (a WhatsApp phone id, a webhook URL)
            token = resolved;
            target = "";
            if "|" in resolved {
                bits = resolved.split("|", 1);
                token = bits[0].strip();
                target = bits[1].strip();
            }
            return {"found": True, "kind": c.kind, "token": token, "target": target,
                    "enabled": c.enabled, "dm_scope": c.dm_scope,
                    "configured": bool(token) or (raw == "")};
        }
    }
    return {"found": False, "kind": "", "token": "", "target": "",
            "enabled": False, "dm_scope": "", "configured": False};
}

# ---------------------------------------------------------------------------
# Handing one message to the agent
# ---------------------------------------------------------------------------
def ask_agent(channel: str, peer: str, text: str, thread_id: str = "",
              timeout_s: int = 900) -> dict {
    # A fresh process, the current graph, one reply. Returns {ok, reply, error}.
    argv = [_jac_bin(), "run", entry_script(), "--", "channel", "inbound",
            channel, peer, text, thread_id];
    try {
        p = subprocess.run(argv, cwd=project_root(), capture_output=True,
                           text=True, timeout=timeout_s);
    } except subprocess.TimeoutExpired as e {
        return {"ok": False, "reply": "", "error": "the agent took longer than "
                + str(timeout_s) + "s"};
    } except Exception as ex {
        return {"ok": False, "reply": "", "error": str(ex)[:300]};
    }
    out = str(p.stdout or "");
    if REPLY_MARKER in out {
        return {"ok": True, "reply": out.split(REPLY_MARKER, 1)[1].strip(), "error": ""};
    }
    return {"ok": False, "reply": "",
            "error": (str(p.stderr or out)[-400:] or "the agent produced no reply")};
}

# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------
def _stop_signal(signum: int, frame: any) -> None {
    _STOP["now"] = True;
    return None;
}

def _install_stop_handlers() -> None {
    try {
        signal.signal(int(signal.SIGTERM), _stop_signal);
        signal.signal(int(signal.SIGINT), _stop_signal);
    } except Exception as e {
        return None;
    }
    return None;
}

def _log(msg: str) -> None {
    print(time.strftime("%Y-%m-%d %H:%M:%S") + "  " + str(msg), flush=True);
    return None;
}

def _handle(channel: str, cfg: dict, m: dict) -> None {
    peer = str(m.get("peer") or "anon");
    text = str(m.get("text") or "");
    thread = str(m.get("thread_id") or "");
    _log("in  " + channel + "/" + peer + ": " + text[:120]);
    res = ask_agent(channel, peer, text, thread);
    if not res["ok"] {
        _log("agent failed: " + str(res["error"])[:200]);
        # Say something. Silence on a chat channel is indistinguishable from the
        # bot being dead, and the person is still waiting.
        deliver(str(cfg["kind"]), str(cfg["token"]), peer,
                "I hit an error handling that and could not finish it.", thread,
                str(cfg["target"]));
        return None;
    }
    reply = str(res["reply"]);
    if not reply { _log("out " + channel + "/" + peer + ": (empty reply, nothing sent)"); return None; }
    sent = deliver(str(cfg["kind"]), str(cfg["token"]), peer, reply, thread, str(cfg["target"]));
    if sent["ok"] { _log("out " + channel + "/" + peer + ": " + reply[:120]); }
    else { _log("DELIVERY FAILED to " + channel + "/" + peer + ": " + str(sent["error"])[:200]); }
    return None;
}

def bridge_poll(channel: str, cfg: dict, max_rounds: int = 0) -> dict {
    rounds = 0;
    offset = read_offset(channel);
    backoff = 1;
    while not _STOP["now"] {
        r = poll_telegram(str(cfg["token"]), offset, 25);
        if not r["ok"] {
            # A provider outage must not become a hot loop against their API.
            _log("poll error: " + str(r["error"])[:200] + " (retrying in " + str(backoff) + "s)");
            _nap(backoff);
            backoff = backoff * 2 if backoff < 60 else 60;
        } else {
            backoff = 1;
            if int(r["offset"]) != offset {
                offset = int(r["offset"]);
                write_offset(channel, offset);   # ack BEFORE answering: a crash
                                                 # mid-reply must not re-answer
            }
            for m in list(r["messages"]) {
                if _STOP["now"] { break; }
                _handle(channel, cfg, dict(m));
            }
        }
        rounds += 1;
        if (max_rounds > 0) and (rounds >= max_rounds) { break; }
    }
    return {"rounds": rounds};
}

def _nap(seconds: int) -> None {
    left = seconds;
    while (left > 0) and (not _STOP["now"]) {
        time.sleep(1 if left > 1 else left);
        left -= 1;
    }
    return None;
}

def bridge_webhook(channel: str, cfg: dict, port: int) -> dict {
    # For providers that push. Binds loopback by default: put a tunnel or a
    # reverse proxy in front rather than exposing the agent to the internet.
    import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }
    host = os.environ.get("SIGIL_BRIDGE_HOST", "127.0.0.1");
    kind = str(cfg["kind"]);

    class Handler(BaseHTTPRequestHandler) {
        def do_POST(self: Handler) -> None {
            length = int(self.headers.get("Content-Length") or "0");
            raw = self.rfile.read(length).decode("utf-8", errors="replace") if length else "{}";
            body: dict = {};
            try { body = dict(json.loads(raw or "{}")); } except Exception as e { body = {}; }
            m = normalize_inbound(kind, body);
            if m.get("challenge") {
                # Slack's endpoint-ownership handshake — echo it verbatim
                self._reply(200, {"challenge": str(m["challenge"])});
                return None;
            }
            # Acknowledge FIRST. Slack retries anything it does not hear back
            # from in 3 seconds, and the agent takes longer than that to think.
            self._reply(200, {"ok": True});
            if m.get("text") { _handle(channel, cfg, m); }
            return None;
        }
        def _reply(self: Handler, code: int, payload: dict) -> None {
            data = json.dumps(payload).encode("utf-8");
            self.send_response(code);
            self.send_header("Content-Type", "application/json");
            self.send_header("Content-Length", str(len(data)));
            self.end_headers();
            self.wfile.write(data);
            return None;
        }
        def log_message(self: Handler, fmt: str, *args: any) -> None {
            return None;   # the bridge's own log is the record, not access lines
        }
    }

    srv = ThreadingHTTPServer((host, port), Handler);
    srv.timeout = 1;
    _log("listening on http://" + host + ":" + str(port) + "/  (POST provider events here)");
    while not _STOP["now"] {
        srv.handle_request();
    }
    srv.server_close();
    return {"served": True};
}

def bridge_run(name: str, port: int = 0, max_rounds: int = 0) -> dict {
    # One channel's transport, in the foreground. `sigil channel run <name>`.
    cfg = channel_config(name);
    if not cfg["found"] {
        return {"ok": False, "error": "no such channel '" + name + "' — sigil channel connect <name> <kind>"};
    }
    if not cfg["enabled"] {
        return {"ok": False, "error": "channel '" + name + "' is disabled"};
    }
    kind = str(cfg["kind"]);
    if (not cfg["token"]) and supports_polling(kind) {
        return {"ok": False, "error": "channel '" + name + "' has no credential — its token env var is unset"};
    }
    _STOP["now"] = False;
    _install_stop_handlers();
    write_pidfile(bridge_pid_name(name));
    _log("bridge up — channel '" + name + "' [" + kind + "]");
    try {
        if supports_polling(kind) {
            bridge_poll(name, cfg, max_rounds);
        } else {
            bridge_webhook(name, cfg, port if port > 0 else 8390);
        }
    } except KeyboardInterrupt as e {
        _STOP["now"] = True;
    } finally {
        clear_pidfile(bridge_pid_name(name));
        _log("bridge stopped — channel '" + name + "'");
    }
    return {"ok": True};
}

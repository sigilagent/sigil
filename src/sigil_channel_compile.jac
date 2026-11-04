"""Compiling from a chat app: WhatsApp, Telegram, Slack, Discord.

A compile is several minutes of model calls. Run inside a channel turn, it held
the conversation (the bridge gives a turn 15 minutes, then answers "I hit an
error") and the graph for all of that time, and the web console's way to start
one, the Build button, does not exist on a phone. So from a channel a compile is
the console's background compile job: the turn answers at once, the job shows
in the Observatory's Compile view, and when it ends it messages the same chat
with the result, success or failure.

Slash commands are answered without the model:
  /build            compile the agent drafted in this chat
  /compile <path>   compile a SKILL.md (or its folder) on this machine
  /status           the latest compiles and how they went
  /stop             stop the turn that is running (the bridge handles it)
  /new              start the conversation over (/reset too)
  /help             these commands
"""

import os;
import re;
import json;
import time;
import hashlib;
import from .sigil_runtime { run_dir, checkpoint }

glob COMMANDS: list[str] = ["new", "reset", "stop", "build", "compile", "status", "help"];

def channel_command(text: str) -> dict[str, str] {
    # {cmd, arg} for a slash command this module answers, else cmd "". Anything
    # else that starts with "/" goes to the model like any other message.
    t = str(text or "").strip();
    if (not t.startswith("/")) or (len(t) < 2) { return {"cmd": "", "arg": ""}; }
    parts = t[1:].split(None, 1);
    if not parts { return {"cmd": "", "arg": ""}; }
    name = str(parts[0]).lower();
    # Telegram appends the bot's name to a command in a group: /build@my_bot
    if "@" in name { name = name.split("@", 1)[0]; }
    if name not in COMMANDS { return {"cmd": "", "arg": ""}; }
    if name == "reset" { name = "new"; }
    arg = str(parts[1]).strip() if len(parts) > 1 else "";
    return {"cmd": name, "arg": arg};
}

def help_text() -> str {
    return ("Commands:\n"
            + "/build: compile the agent we drafted in this chat\n"
            + "/compile <path>: compile a SKILL.md on this machine\n"
            + "/status: the latest compiles\n"
            + "/stop: stop what I'm working on\n"
            + "/new: start our conversation over\n"
            + "Anything else goes to the agent.");
}

def slug(name: str) -> str {
    s = re.sub(r"[^a-z0-9]+", "_", str(name or "").lower()).strip("_");
    return s[:48] if s else "agent";
}

def strip_fences(md: str) -> str {
    # A drafted SKILL.md sometimes arrives wrapped in ```markdown … ```.
    t = str(md or "").strip();
    if t.startswith("```") {
        nl = t.find("\n");
        t = t[nl + 1:] if nl >= 0 else "";
        if t.rstrip().endswith("```") { t = t.rstrip()[:-3]; }
    }
    return t.strip() + "\n";
}

def frontmatter_name(md: str, fallback: str) -> str {
    lines = str(md or "").splitlines();
    if lines and (lines[0].strip() == "---") {
        for ln in lines[1:40] {
            if ln.strip() == "---" { break; }
            if ln.strip().lower().startswith("name:") {
                v = ln.split(":", 1)[1].strip().strip("\"'");
                if v { return v; }
            }
        }
    }
    return fallback;
}

def write_skill_draft(base_dir: str, name: str, skill_md: str, unique: bool = False) -> str {
    # <root>/agents/<slug>/SKILL.md. A revision of a draft (same name) replaces
    # it; `unique` keeps an existing folder and writes beside it (_2, _3, …).
    base = os.path.join(base_dir, "agents", slug(name));
    d = base;
    if unique {
        n = 2;
        while os.path.exists(d) { d = base + "_" + str(n); n += 1; }
    }
    os.makedirs(d, exist_ok=True);
    path = os.path.join(d, "SKILL.md");
    with open(path, "w") as f { f.write(strip_fences(skill_md)); }
    return path;
}

# A chat's current draft, kept on disk rather than on the graph: it is a pointer
# to a file, and a graph write from a channel turn is exactly what races.
def _drafts_dir() -> str {
    d = os.path.join(run_dir(), "channel-drafts");
    os.makedirs(d, exist_ok=True);
    return d;
}

def _draft_file(channel: str, peer: str) -> str {
    key = hashlib.sha256((str(channel) + "\n" + str(peer)).encode("utf-8")).hexdigest()[:16];
    return os.path.join(_drafts_dir(), key + ".json");
}

def save_draft(channel: str, peer: str, name: str, skill_md: str, base_dir: str) -> str {
    path = write_skill_draft(base_dir, name, skill_md, False);
    rec = {"channel": str(channel), "peer": str(peer), "name": str(name), "path": path, "ts": time.time()};
    tmp = _draft_file(channel, peer) + ".tmp";
    with open(tmp, "w") as f { f.write(json.dumps(rec)); }
    os.replace(tmp, _draft_file(channel, peer));
    return path;
}

def pending_draft(channel: str, peer: str) -> dict[str, any] {
    try {
        with open(_draft_file(channel, peer)) as f { rec = json.loads(f.read() or "{}"); }
    } except Exception as e { return {}; }
    if (not isinstance(rec, dict)) or (not os.path.isfile(str(rec.get("path") or ""))) { return {}; }
    return rec;
}

def start_channel_compile(channel: str, peer: str, path: str) -> dict[str, any] {
    # Start the console's background compile for a SKILL.md, set to message this
    # chat when it ends. A file named SKILL.md brings its folder (references,
    # scripts beside it); any other file is compiled on its own, so pointing at
    # a note on the Desktop does not copy the Desktop.
    full = os.path.abspath(os.path.expanduser(str(path or "")));
    if os.path.isdir(full) {
        if not os.path.isfile(os.path.join(full, "SKILL.md")) {
            return {"ok": False, "error": "no SKILL.md in " + full};
        }
    } elif not os.path.isfile(full) {
        return {"ok": False, "error": "no such file: " + full};
    }
    import from .sigil_console { compile_start }
    note: dict[str, any] = {"channel": str(channel), "peer": str(peer)};
    if os.path.isdir(full) or (os.path.basename(full).lower() == "skill.md") {
        return compile_start([], "decide", full, note);
    }
    try {
        with open(full) as f { text = f.read(); }
    } except Exception as e {
        import from .sigil_runtime { cloud_file_hint }
        hint = cloud_file_hint(e, full);
        return {"ok": False, "error": "could not read " + full + ": " + str(e) + ((". " + hint) if hint else "")};
    }
    return compile_start([{"path": "SKILL.md", "text": text}], "decide", "", note);
}

def started_text(r: dict[str, any]) -> str {
    if not r.get("ok") { return "Couldn't start the compile: " + str(r.get("error") or "unknown error"); }
    return ("Compiling " + str(r.get("name") or "the agent") + " in the background. It takes a few "
            + "minutes; I'll message you here when it's done. /status shows how it's going.");
}

def compile_notice(meta: dict[str, any], out: dict[str, any]) -> str {
    # The message a finished compile sends to the chat that started it.
    name = str(meta.get("name") or "the agent");
    if out.get("ok") {
        sig = str(out.get("signature") or name);
        text = "✓ Compiled " + name + ((" as " + sig) if sig != name else "") + " (v" + str(out.get("version") or 1) + "). Ask me to run it, or tell me what to change.";
        if out.get("save_warning") {
            text += "\nBut it could not be saved to the agent's graph: " + str(out.get("save_warning"))[:300];
        }
        return text;
    }
    why = str(out.get("error") or "").strip();
    if not why {
        issues = [str(i) for i in list(out.get("issues") or [])][:3];
        why = "; ".join(issues) if issues else str(out.get("explain") or "").strip();
    }
    status = str(out.get("status") or "failed");
    return ("✗ The compile of " + name + " " + ("failed" if status == "failed" else ("ended " + status))
            + ((": " + why[:600]) if why else ".") + "\nThe full log is in the Observatory under Compile.");
}

def notify_compile_done(note: dict[str, any], meta: dict[str, any], out: dict[str, any]) -> dict[str, any] {
    import from .channels { message_send }
    r = message_send(str(note.get("channel") or ""), str(note.get("peer") or ""), compile_notice(meta, out));
    checkpoint("compile notify");
    return r;
}

def status_text() -> str {
    import from .sigil_console { compile_jobs }
    rows = compile_jobs()[:5];
    if not rows { return "No compiles yet."; }
    lines: list[str] = ["Latest compiles:"];
    for r in rows {
        st = str(r.get("state") or "");
        if st == "done" {
            res = str(r.get("status") or "done");
            v = int(r.get("version") or 0);
            st = res + ((" v" + str(v)) if v else "");
        }
        lines.append("• " + str(r.get("name") or r.get("job")) + ": " + st);
    }
    return "\n".join(lines);
}

def handle_command(channel: str, peer: str, cmd: str, arg: str, base_dir: str) -> str {
    # The reply to a slash command (other than /new, which the inbound loop owns).
    if cmd == "help" { return help_text(); }
    if cmd == "stop" { return "Nothing is running right now."; }
    if cmd == "status" { return status_text(); }
    if cmd == "build" {
        dr = pending_draft(channel, peer);
        if not dr {
            return ("There's no drafted agent in this chat yet. Tell me what you want it to do and "
                    + "I'll draft it with you first. To compile a SKILL.md that's already on this "
                    + "machine, send /compile <path>.");
        }
        return started_text(start_channel_compile(channel, peer, str(dr["path"])));
    }
    if cmd == "compile" {
        if not arg {
            return "Send /compile <path to a SKILL.md or its folder>. Relative paths start in " + base_dir + ".";
        }
        p = os.path.expanduser(arg.strip().strip("\"'"));
        if not os.path.isabs(p) { p = os.path.join(base_dir, p); }
        return started_text(start_channel_compile(channel, peer, p));
    }
    return help_text();
}

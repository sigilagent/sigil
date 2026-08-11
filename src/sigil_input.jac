"""Sigil input — the chat REPL's line editor, built on prompt_toolkit (a declared
dependency the runtime provisions, same as rich).

What every prompt gets in a real terminal:
  · multiline editing — Enter sends, Ctrl-J / Alt-Enter inserts a newline, and a
    pasted block with newlines is inserted, not submitted (bracketed paste)
  · a slash-command palette — type "/" and the commands pop up with descriptions;
    first arguments complete too (/model tiers, /sandbox modes, /docs topics)
  · fish-style history suggestions (→ accepts), Ctrl-R history search
  · a status toolbar (model · sandbox · skills) pinned under the input
  · Ctrl-X Ctrl-E to compose a long message in $EDITOR

Piped / non-TTY runs never touch any of it: make_session() returns None and
prompt_text() falls back to builtin input(), so chat stays scriptable.
"""

import sys;
import os;

import from prompt_toolkit.completion { Completer, Completion }

# ---------------------------------------------------------------------------
# the command table — the ONE list the /help screen and the palette both read,
# so a new command shows up in both by adding a row here.
# row: [usage, description, first-argument vocabulary ([word, meta]) or "DOCS"]
# ---------------------------------------------------------------------------
glob COMMANDS: list = [
    ["/help", "show this help", []],
    ["/soul", "identity, models, skills & memory", []],
    ["/config", "edit settings interactively", []],
    ["/tools", "the tool-belt the agent can use", []],
    ["/workspace", "workspace dir + running shell jobs", []],
    ["/sandbox <off|jail|docker>", "containment for the tools (default off)",
     [["off", "tools run on the real host"],
      ["jail", "file tools jailed to the workspace"],
      ["docker", "shell runs in a container"]]],
    ["/cron", "list scheduled jobs", []],
    ["/channels", "channels: supported + configured", []],
    ["/connect <kind>", "how to connect discord|telegram|whatsapp|slack",
     [["discord", ""], ["telegram", ""], ["whatsapp", ""], ["slack", ""]]],
    ["/docs [topic]", "Sigil's reference — how it works, config, tools", "DOCS"],
    ["/skills", "list compiled skills", []],
    ["/model <tier> <name>", "set frontier|small|router|chat model",
     [["chat", "the model you talk to here"],
      ["frontier", "expensive — compiles new skills"],
      ["small", "cheap — runs compiled skills"],
      ["router", "routes a task to a skill"]]],
    ["/remember <fact>", "store a durable memory", []],
    ["/recall <query>", "search memories", []],
    ["/reset", "clear the conversation (keeps graph)", []],
    ["/clear", "clear the screen", []],
    ["/exit", "quit (also Ctrl-D)", []]
];

# /docs topics are read from disk lazily — the palette only pays the directory
# scan when "/docs " is actually typed, not on every chat startup.
glob _DOCS: dict = {"loaded": False, "topics": []};

def _doc_args -> list {
    if not _DOCS["loaded"] {
        _DOCS["loaded"] = True;
        try {
            import from .sigil_docs { doc_topics }
            _DOCS["topics"] = [[str(t["slug"]), str(t["title"])] for t in doc_topics()];
        } except Exception { _DOCS["topics"] = []; }
    }
    return list(_DOCS["topics"]);
}

# prompt_toolkit's Completer is ABCMeta-driven, hence a `class` archetype with
# Python semantics (explicit self) rather than an obj — an obj's dataclass
# machinery never reaches the metaclass. Verb completions for arg-taking
# commands insert a trailing space so the argument menu opens immediately.
class SlashCompleter(Completer) {
    def get_completions(self: any, document: any, complete_event: any) -> any {
        _ = complete_event;
        txt = str(document.text_before_cursor);
        # only a single-line "/…" start is a command; anything else is prose
        if (not txt.startswith("/")) or (chr(10) in txt) { return; }
        if " " not in txt {
            for c in COMMANDS {
                usage = str(c[0]);
                verb = usage.split(" ")[0];
                if verb.startswith(txt) {
                    fill = (verb + " ") if " " in usage else verb;
                    yield Completion(fill, start_position=-len(txt),
                                     display=verb, display_meta=str(c[1]));
                }
            }
            return;
        }
        (verb, rest) = txt.split(" ", 1);
        if " " in rest { return; }   # only the first argument has a vocabulary
        for c in COMMANDS {
            if str(c[0]).split(" ")[0] != verb { continue; }
            vocab = _doc_args() if isinstance(c[2], str) else list(c[2]);
            for v in vocab {
                w = str(v[0]);
                if w.startswith(rest) {
                    yield Completion(w, start_position=-len(rest), display_meta=str(v[1]));
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# keys, style, toolbar
# ---------------------------------------------------------------------------
def _keybindings -> any {
    # multiline=True flips prompt_toolkit's default to "Enter = newline,
    # Esc-Enter = send" — exactly backwards for chat. Rebind: Enter sends
    # (or applies a menu selection), Ctrl-J / Alt-Enter make the newline.
    import from prompt_toolkit.key_binding { KeyBindings }
    kb = KeyBindings();
    @kb.add("enter")
    def submit_line(event: any) -> None {
        buf = event.current_buffer;
        st = buf.complete_state;
        if st and st.current_completion {
            buf.apply_completion(st.current_completion);
            # an applied verb ends in " " when it takes arguments — reopen the
            # menu so its argument vocabulary is on screen without a keypress
            if str(buf.text).endswith(" ") { buf.start_completion(select_first=False); }
            return;
        }
        # Empty Enter is a NO-OP, not a submission. An accepted-empty prompt is
        # finalized WITH its placeholder still rendered, so every stray \r that
        # reaches an idle terminal (a resting finger, multiplexer keepalives,
        # shell-integration chatter) minted one ghost
        #   sigil › plan, build, schedule — "/" for commands
        # line in scrollback and the REPL re-rendered a fresh prompt below it.
        if not str(buf.text).strip() { return; }
        buf.validate_and_handle();
    }
    @kb.add("c-j")
    @kb.add("escape", "enter")
    def insert_newline(event: any) {
        event.current_buffer.insert_text(chr(10));
    }
    return kb;
}

def _style -> any {
    # the same palette as the rich side: brand purple #a78bfa on a near-black
    # menu, dim chrome everywhere else. bottom-toolbar defaults to reverse
    # video (a full white bar) — noreverse turns it into a quiet status line.
    import from prompt_toolkit.styles { Style }
    return Style.from_dict({
        "completion-menu": "bg:#181822",
        "completion-menu.completion": "bg:#181822 #c9c9dc",
        "completion-menu.completion.current": "bg:#a78bfa #14141c bold",
        "completion-menu.meta.completion": "bg:#181822 #77778f",
        "completion-menu.meta.completion.current": "bg:#a78bfa #2a2438",
        "scrollbar.background": "bg:#23232f",
        "scrollbar.button": "bg:#a78bfa",
        "bottom-toolbar": "noreverse #70708a",
        "placeholder": "#5b5b74 italic",
        "auto-suggestion": "#4a4a60",
        "continuation": "#5b4a8a"
    });
}

# the dynamic half of the toolbar (model · sandbox · skills). The editor's render
# loop reads this glob on every keystroke, so it must stay a plain string —
# sigil_chat recomputes it (a graph read) only when config actually changes.
glob _TOOLBAR: dict[str, str] = {"s": ""};

def set_toolbar(text: str) { _TOOLBAR["s"] = text; }

def _toolbar_ft -> any {
    hints = "⏎ send · ^J newline · ^R history · ^C cancel · ^D quit";
    s = str(_TOOLBAR["s"]);
    return [("class:bottom-toolbar", (" " + s + "   " + hints) if s else (" " + hints))];
}

def _continuation(width: int, line_number: int, is_soft_wrap: bool) -> any {
    _ = line_number; _ = is_soft_wrap;
    # align the wrap marker under the "sigil › " prompt, whatever its width
    return [("class:continuation", (" " * max(0, width - 2)) + "┆ ")];
}

# ---------------------------------------------------------------------------
# sessions
# ---------------------------------------------------------------------------
def make_session -> any {
    # the full chat editor. None when piped — callers fall back to input().
    if not sys.stdin.isatty() { return None; }
    try {
        import from prompt_toolkit { PromptSession }
        import from prompt_toolkit.history { FileHistory }
        import from prompt_toolkit.auto_suggest { AutoSuggestFromHistory }
        import from prompt_toolkit.formatted_text { FormattedText }
        import from prompt_toolkit.shortcuts { CompleteStyle }
        import from prompt_toolkit.cursor_shapes { CursorShape }
        return PromptSession(
            history=FileHistory(os.path.expanduser("~/.sigil_chat_history")),
            multiline=True,
            key_bindings=_keybindings(),
            completer=SlashCompleter(),
            complete_while_typing=True,
            complete_style=CompleteStyle.COLUMN,
            reserve_space_for_menu=6,
            auto_suggest=AutoSuggestFromHistory(),
            style=_style(),
            placeholder=FormattedText([("class:placeholder", 'plan, build, schedule — "/" for commands')]),
            bottom_toolbar=_toolbar_ft,
            prompt_continuation=_continuation,
            enable_open_in_editor=True,
            cursor=CursorShape.BEAM
        );
    } except Exception { return None; }
}

def make_plain_session -> any {
    # bare single-line prompt for approvals, the config editor and the wizard —
    # no chat history (a "y" answered to an exec approval must never become a
    # history suggestion), no palette, no toolbar, Enter submits.
    if not sys.stdin.isatty() { return None; }
    try {
        import from prompt_toolkit { PromptSession }
        return PromptSession();
    } except Exception { return None; }
}

def prompt_text(session: any, msg: str) -> str {
    # one door for all input. EOFError / KeyboardInterrupt propagate — the REPL
    # loop owns what ^C and ^D mean, not this module.
    if session is None { return str(input(msg)); }
    m: any = msg;
    try {
        import from prompt_toolkit { ANSI }
        m = ANSI(msg);   # lets the prompt carry ANSI colour
    } except Exception { m = msg; }
    return str(session.prompt(m));
}

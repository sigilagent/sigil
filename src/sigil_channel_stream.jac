"""Channel streaming — a long answer arrives on the phone in parts, as it is written.

A chat turn on a channel can run for minutes (a compile, a web fetch, a dozen
tool calls), and a chat app shows nothing until the whole reply lands, if it
lands. So `channel inbound`, when the bridge asks for it (SIGIL_CHANNEL_STREAM=1),
cuts the reply into parts as the model streams it and prints each one as a
`<<<SIGIL_PART>>>` line the bridge delivers on the spot:

  - a part is the next N complete sentences (SIGIL_CHANNEL_CHUNK, default 3;
    0 sends the reply whole, as before), never split inside a ``` block;
  - a short note for each tool call that finished ("⚙ web_fetch · jayanaka.dev…",
    "✗" when it failed) rides with the next part (SIGIL_CHANNEL_TOOL_NOTES=0
    turns notes off);
  - parts are at least MIN_GAP_S apart, because WhatsApp allows an agent 12 sends
    a minute, and none is longer than a chat message may be.

Whatever is left when the turn ends is flushed before the final reply marker,
so the bridge knows that a turn which streamed has nothing more to send.
"""

import os;
import sys;
import json;
import time;

glob PART_MARKER: str = "<<<SIGIL_PART>>>";
glob MIN_GAP_S: float = 6.0;
glob PART_MAX: int = 3500;

def stream_requested() -> bool {
    return str(os.environ.get("SIGIL_CHANNEL_STREAM") or "") == "1";
}

def chunk_sentences() -> int {
    raw = str(os.environ.get("SIGIL_CHANNEL_CHUNK") or "").strip();
    if not raw { return 3; }
    try { return max(0, int(raw)); } except Exception as e { return 3; }
}

def tool_notes_on() -> bool {
    return str(os.environ.get("SIGIL_CHANNEL_TOOL_NOTES") or "").strip().lower() not in ["0", "false", "no", "off"];
}

def tool_note(tool: str, detail: str, ok: bool) -> str {
    # One line per tool call, short enough to read on a phone.
    d = " ".join(str(detail or "").split());
    if len(d) > 60 { d = d[:57] + "…"; }
    return ("⚙ " if ok else "✗ ") + str(tool) + ((" · " + d) if d else "");
}

def sentence_cut(text: str, n: int) -> int {
    # Where the first `n` complete sentences of `text` end (an index into it), or
    # -1 when there are fewer. A sentence ends at . ! ? followed by whitespace, or
    # at a blank line. A cut inside an open ``` block is no cut.
    if n <= 0 { return -1; }
    seen = 0;
    i = 0;
    L = len(text);
    while i < L {
        ch = text[i];
        end = -1;
        if (ch in ".!?") and (i + 1 < L) and (text[i + 1] in " \n\t") { end = i + 1; }
        elif (ch == "\n") and (i + 1 < L) and (text[i + 1] == "\n") { end = i + 2; }
        if end > 0 {
            if (text[:end].count("```") % 2) == 0 {
                seen += 1;
                if seen >= n { return end; }
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return -1;
}

def split_long(text: str, limit: int = 3500) -> list[str] {
    # A part no longer than a chat message: cut at a paragraph, then a line, then
    # a space, before falling back to a hard cut.
    out: list[str] = [];
    rest = str(text);
    while len(rest) > limit {
        # Search a slice, not rfind(sub, 0, limit): the bounded form is not
        # honoured under every jac backend (jac test ignored the end bound).
        window = rest[:limit];
        cut = window.rfind("\n\n");
        if cut < limit // 2 { cut = window.rfind("\n"); }
        if cut < limit // 2 { cut = window.rfind(" "); }
        if cut <= 0 { cut = limit; }
        out.append(rest[:cut].rstrip());
        rest = rest[cut:].lstrip();
    }
    if rest.strip() { out.append(rest); }
    return out;
}

obj ChannelStream {
    has n: int = 3;
    has notes_on: bool = True;
    has buf: str = "";
    has notes: list[str] = [];
    has streamed: str = "";
    has last_emit: float = 0.0;
    has parts: int = 0;
    has emit: any = None;   # callback(text); default prints a PART line
    has gap: float = 6.0;   # MIN_GAP_S; a test passes 0

    def _send(text: str) -> None {
        t = str(text).strip();
        if not t { return None; }
        for piece in split_long(t, PART_MAX) {
            if self.emit is not None { self.emit(piece); }
            else { print(PART_MARKER + json.dumps(piece), flush=True); }
            self.parts += 1;
        }
        self.last_emit = time.time();
        return None;
    }

    def _take_notes() -> str {
        if not self.notes { return ""; }
        out = "\n".join(self.notes);
        self.notes = [];
        return out;
    }

    def _pump() -> None {
        # Send what is ready, if the last part went out long enough ago.
        if (time.time() - self.last_emit) < self.gap { return None; }
        cut = sentence_cut(self.buf, self.n);
        if cut > 0 {
            head = self.buf[:cut];
            self.buf = self.buf[cut:].lstrip();
            notes = self._take_notes();
            self._send((notes + "\n\n" + head) if notes else head);
        } elif self.notes and (not self.buf.strip()) {
            # Tools are running and nothing has been said yet: show the work.
            self._send(self._take_notes());
        }
        return None;
    }

    def on_token(piece: str) -> None {
        self.buf += str(piece);
        self.streamed += str(piece);
        self._pump();
        return None;
    }

    def on_tool(tool: str, detail: str, ok: bool) -> None {
        if not self.notes_on { return None; }
        self.notes.append(tool_note(tool, detail, ok));
        self._pump();
        return None;
    }

    def finish(reply: str) -> int {
        # Flush everything not yet sent. `reply` is the turn's final text: what
        # streamed plus anything that never went through the token sink (an
        # error note, a /new acknowledgement). Returns the number of parts sent.
        r = str(reply or "");
        tail = self.buf;
        if r.startswith(self.streamed) { tail = tail + r[len(self.streamed):]; }
        elif not self.streamed { tail = r; }
        notes = self._take_notes();
        if notes and tail.strip() { tail = notes + "\n\n" + tail; }
        elif notes { tail = notes; }
        self.buf = "";
        self._send(tail);
        return self.parts;
    }
}

def start_channel_stream() -> any {
    # Wire a ChannelStream to the chat turn's token and tool sinks. None when the
    # caller did not ask for streaming or chunking is off.
    if not stream_requested() { return None; }
    n = chunk_sentences();
    if n <= 0 { return None; }
    import from .chat_agent { set_token_sink }
    import from .sigil_workspace { set_trace_sink }
    st = ChannelStream(n=n, notes_on=tool_notes_on(), gap=MIN_GAP_S);
    def _tok(piece: str) -> None { st.on_token(piece); }
    def _tool(tool: str, detail: str, ok: bool) -> None { st.on_tool(tool, detail, ok); }
    set_token_sink(_tok);
    set_trace_sink(_tool);
    return st;
}

def stop_channel_stream(st: any, reply: str) -> int {
    if st is None { return 0; }
    import from .chat_agent { set_token_sink }
    import from .sigil_workspace { set_trace_sink }
    set_token_sink(None);
    set_trace_sink(None);
    return st.finish(reply);
}

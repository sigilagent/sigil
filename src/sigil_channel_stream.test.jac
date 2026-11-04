# Tests for sigil_channel_stream — annex of sigil_channel_stream.jac.
# How a streamed reply is cut into chat-sized parts. No model, no network.

test "sentence_cut finds the end of the first n sentences, and not inside code" {
    t = "One. Two! Three? Four.";
    assert t[:sentence_cut(t, 2)] == "One. Two!", str(sentence_cut(t, 2));
    assert sentence_cut("One. Two", 2) == -1, "the second sentence is not finished";
    para = "A line with no stop\n\nNext";
    assert para[:sentence_cut(para, 1)] == "A line with no stop\n\n";
    code = "Run:\n```\nx = 1. y = 2. z = 3.\n```\nDone. Next.";
    # the stops inside the ``` block are not sentence ends
    assert code[:sentence_cut(code, 1)].endswith("```\nDone."), code[:sentence_cut(code, 1)];
}

test "split_long keeps each part under the limit, at a paragraph when it can" {
    text = ("a" * 30) + "\n\n" + ("b" * 30);
    parts = split_long(text, 40);
    assert parts == ["a" * 30, "b" * 30], str(parts);
    for piece in split_long("word " * 50, 40) { assert len(piece) <= 40, str(len(piece)); }
}

test "a stream sends n sentences at a time, notes ride along, finish flushes" {
    sent: list[str] = [];
    def _emit(t: str) -> None { sent.append(t); }
    st = ChannelStream(n=2, notes_on=True, emit=_emit, gap=0.0);
    st.on_tool("web_fetch", "https://jayanaka.dev/ " + ("x" * 80), True);
    assert len(sent) == 1 and sent[0].startswith("⚙ web_fetch · https://jayanaka.dev/"), str(sent);
    assert sent[0].endswith("…"), "a long detail is truncated";
    for tok in ["First. ", "Second. ", "Third. ", "Fourth"] { st.on_token(tok); }
    assert sent[1] == "First. Second.", str(sent);
    n = st.finish("First. Second. Third. Fourth");
    assert sent[-1] == "Third. Fourth", str(sent);
    assert n == 3;
}

test "a reply that never streamed (an error note, /new) goes out whole at finish" {
    sent: list[str] = [];
    def _emit(t: str) -> None { sent.append(t); }
    st = ChannelStream(n=3, emit=_emit, gap=0.0);
    st.finish("Started a new conversation.");
    assert sent == ["Started a new conversation."], str(sent);
}

test "tool notes can be turned off" {
    sent: list[str] = [];
    def _emit(t: str) -> None { sent.append(t); }
    st = ChannelStream(n=1, notes_on=False, emit=_emit, gap=0.0);
    st.on_tool("ws_read", "a.txt", False);
    st.finish("");
    assert sent == [], str(sent);
    assert tool_note("ws_read", "a.txt", False).startswith("✗ ws_read");
}

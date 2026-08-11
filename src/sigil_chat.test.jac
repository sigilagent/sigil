# Tests for sigil_chat — annex of sigil_chat.jac (`jac test src/sigil_chat.jac`).
# The reply renderer: the streamed answer is re-rendered as REAL markdown (rich's
# Markdown) each tick, gutter hung off every line — so these assert the rendered
# text, offline, with a headless console and no model or graph.

def _console(w: int) -> any {
    import from rich.console { Console }
    # a headless-but-styled console: render_lines computes layout, we read .plain
    return Console(force_terminal=True, width=w, color_system="truecolor");
}

def _rows(txt: any) -> list {
    return [ln for ln in str(txt.plain).split(chr(10))];
}

test "inline emphasis and code render as styling, not literal source characters" {
    c = _console(60);
    out = _guttered_markdown(c, "I'm **Sigil**, a *Claude* app. Run `sigil compile`.");
    p = str(out.plain);
    assert "Sigil" in p and "Claude" in p and "sigil compile" in p;
    assert "**" not in p;     # the markdown was consumed, not printed verbatim
    assert "`" not in p;
    for ln in _rows(out) { assert ln.startswith(chr(0x2502)); }   # gutter │ on every line
}

test "ordered and nested lists render as real markdown" {
    # the whole point of the rewrite: a line-at-a-time styler could never do these
    c = _console(60);
    p = str(_guttered_markdown(c, "1. First\n2. Second\n   - nested a\n   - nested b\n3. Third").plain);
    assert "First" in p and "Second" in p and "Third" in p;
    assert "nested a" in p and "nested b" in p;
    assert "1" in p and "2" in p and "3" in p;   # the numbers survived
}

test "a table renders as a table, not raw pipes" {
    c = _console(60);
    p = str(_guttered_markdown(c, "| Stage | Rows |\n|-------|------|\n| in | 100 |\n| out | 94 |").plain);
    assert "Stage" in p and "Rows" in p;
    assert "in" in p and "100" in p and "out" in p and "94" in p;
    assert chr(0x2500) in p;   # ─ box-drawing: it really drew a table
}

test "a blockquote renders as a quote, its source marker gone" {
    c = _console(60);
    p = str(_guttered_markdown(c, "> keep the header row").plain);
    assert "keep the header row" in p;
    assert ">" not in p;       # rendered as a quote bar, not a literal '>'
}

test "an unterminated fence still renders the code it has (mid-stream)" {
    # streaming robustness: the closing ``` has not arrived yet, but the partial
    # buffer must still show the code rather than swallowing it
    c = _console(60);
    p = str(_guttered_markdown(c, "here:\n```python\ndef run(x):\n    return x").plain);
    assert "def run" in p and "return x" in p;
}

test "model output cannot inject rich markup of its own" {
    # a reply containing [dim] must PRINT as text — rich's Markdown does not
    # interpret console markup, so the source can never style the terminal
    c = _console(60);
    p = str(_guttered_markdown(c, "a model writing [dim]markup[/dim] here").plain);
    assert "markup" in p;
    assert "[dim]" in p;       # printed verbatim, not applied as a style
}

test "an empty reply still yields a single gutter line" {
    c = _console(60);
    rows = _rows(_guttered_markdown(c, ""));
    assert len(rows) >= 1;
    assert rows[0].startswith(chr(0x2502));
}

test "a long line keeps the gutter on every wrapped row" {
    c = _console(40);
    rows = [r for r in _rows(_guttered_markdown(c, "word " * 30)) if r.strip()];
    assert len(rows) > 1;                            # it really did wrap
    for r in rows { assert r.startswith(chr(0x2502)); }   # …and none lost the border
}

test "a long tool detail wraps into the detail column, not back to the margin" {
    # the bug: `learn`'s one-sentence task ran off the line and continued at column 0,
    # so the trace read like the agent's own prose instead of a tool call.
    detail = ("Generate and edit PowerPoint (.pptx) presentations from a content outline, "
              + "following Anthropic's 'pptx' skill: create a deck with titled slides, "
              + "bullet points, and speaker notes using python-pptx, apply a consistent "
              + "theme, and write the resulting .pptx file into the workspace.");
    rows = _trace_rows(detail, 64);
    assert len(rows) > 1, str(len(rows));
    for r in rows { assert len(str(r)) <= 64, str(len(str(r))) + ": " + str(r); }
    # nothing is dropped on the way through the wrapper
    assert "Generate and edit" in str(rows[0]);
    assert "workspace" in str(rows[len(rows) - 1]);
    # continuation rows are padded to the gutter, so they sit under the detail column
    assert _TRACE_GUTTER == 16, str(_TRACE_GUTTER);
}

test "a short detail stays one row, and an empty one still renders" {
    assert _trace_rows("wrote notes/a.txt (12 chars)", 64) == ["wrote notes/a.txt (12 chars)"];
    assert _trace_rows("", 64) == [""];
    # an absurd width falls back rather than looping or emitting empty rows
    assert len(_trace_rows("some detail here", 3)) >= 1;
}

# Tests for sigil_chat — annex of sigil_chat.jac (`jac test src/sigil_chat.jac`).
# The reply renderer only: it is pure string work, so it tests offline with no
# console, no model and no graph.

def _fresh() -> None {
    _FENCE["in"] = False; _FENCE["lang"] = ""; _FENCE["buf"] = [];
    _LINEBUF["s"] = "";
}

test "inline markdown becomes styling instead of literal asterisks" {
    _fresh();
    # the bug this fixes: streamed replies printed `**Sigil**` verbatim, because
    # only the non-streaming fallback ever reached rich's Markdown
    out = _style_line("I'm **Sigil**, running on a *Claude* model.");
    assert "[bold]Sigil[/bold]" in out;
    assert "[italic]Claude[/italic]" in out;
    assert "**" not in out;
}

test "code spans are styled, and asterisks inside them are left alone" {
    _fresh();
    out = _style_line("run `sigil compile ./SKILL.md` first");
    assert "[cyan]sigil compile ./SKILL.md[/cyan]" in out;
    assert "`" not in out;
}

test "headings and bullets get structure, not their source characters" {
    _fresh();
    h = _style_line("## Two paths");
    assert "Two paths" in h;
    assert "##" not in h;   # the source markers, not the markup colour
    b = _style_line("- **From a file:** the gated pipeline");
    assert "•" in b;
    assert "[bold]From a file:[/bold]" in b;
    assert not b.lstrip().startswith("-");
    # indentation is structure too — a nested bullet must stay nested
    n = _style_line("    - nested");
    assert n.startswith("    ");
}


test "model output cannot inject rich markup of its own" {
    _fresh();
    # a reply containing [dim] must PRINT [dim], never dim the terminal — the
    # renderer escapes the source before adding any markup of its own
    out = _style_line("a model writing [dim]markup[/dim] must not style anything");
    assert "\\[dim]" in out;
    assert "\\[/dim]" in out;
}

test "an unmatched asterisk is left as written" {
    _fresh();
    out = _style_line("2 * 3 = 6, and a lone ** stays");
    assert "[italic]" not in out;
    assert "[bold]" not in out;
}

test "bold pairs with its own closing run, even when it contains an asterisk" {
    _fresh();
    # `[^*]+` could not cross the inner asterisk, so the opening ** went unmatched
    # and the NEXT two runs paired instead — bolding the prose between them.
    out = _style_line("Costs **2 * 3 = 6** dollars, and a lone ** stays.");
    assert "[bold]2 * 3 = 6[/bold]" in out;
    assert out.endswith("dollars, and a lone ** stays.");
}

test "a fenced block is collected whole, not styled line by line" {
    import from rich.console { Console }
    _fresh();
    c = Console(force_terminal=False, width=60);
    _emit_line(c, "```python");
    assert _FENCE["in"];
    assert str(_FENCE["lang"]) == "python";
    _emit_line(c, "x = '**not bold**'");     # inside a fence, markdown is just text
    assert len(_FENCE["buf"]) == 1;
    _emit_line(c, "```");
    assert not _FENCE["in"];
    assert _FENCE["buf"] == [];
    # prose styles again once the fence closes
    assert "[bold]x[/bold]" in _style_line("**x**");
}

test "an unterminated fence still prints what it collected" {
    import from rich.console { Console }
    _fresh();
    c = Console(force_terminal=False, width=60);
    _emit_line(c, "```");
    _emit_line(c, "half a snippet");
    _flush_reply(c);            # reply ended mid-fence
    assert not _FENCE["in"];
    assert _FENCE["buf"] == [];
}

test "a long line keeps the gutter on every wrapped row" {
    import from rich.console { Console }
    import io;
    _fresh();
    buf = io.StringIO();
    c = Console(file=buf, force_terminal=False, width=40, soft_wrap=False);
    _emit_line(c, "word " * 30);
    rows = [r for r in buf.getvalue().split(chr(10)) if r.strip()];
    assert len(rows) > 1;                 # it really did wrap
    for r in rows { assert r.startswith("│ "); }   # …and none lost the border
}

test "a wrapped bullet hangs under its text, not under the marker" {
    import from rich.console { Console }
    import io;
    _fresh();
    buf = io.StringIO();
    c = Console(file=buf, force_terminal=False, width=44, soft_wrap=False);
    _emit_line(c, "- " + ("item " * 20));
    rows = [r for r in buf.getvalue().split(chr(10)) if r.strip()];
    assert len(rows) > 1;
    assert rows[0].startswith("│ •");        # marker only on the first row
    for r in rows[1:] {
        assert r.startswith("│   ");         # …continuations indent past it
    }
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

# Tests for sigil_chat — annex of sigil_chat.jac (`jac test src/sigil_chat.jac`).
# The reply renderer only: it is pure string work, so it tests offline with no
# console, no model and no graph.

def _fresh() -> None {
    _FENCE["in"] = False;
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

test "a fenced block toggles and its contents are never re-styled as prose" {
    _fresh();
    open_line = _style_line("```bash");
    assert "bash" in open_line;
    assert _FENCE["in"];
    # **not bold** in here: it is code, and the fence is what says so
    body = _style_line("echo **not bold**");
    assert "[bold]" not in body;
    assert "**not bold**" in body;
    close_line = _style_line("```");
    assert not _FENCE["in"];
    # and prose after the fence styles again
    assert "[bold]x[/bold]" in _style_line("**x**");
    _fresh();
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

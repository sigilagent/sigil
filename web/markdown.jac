"""Markdown, rendered: Sigil's reference docs and the model's replies in the Studio.

On purpose small, and line by line: headings, fenced code, bullet and numbered
lists, tables, block quotes, rules and paragraphs, with `code`, **bold**,
*italic* and [links](other-doc.md) inline. Nothing is ever handed to the browser
as HTML, so whatever a model writes can only come out as text. A link to another
reference doc opens it in the console's Docs; a web link opens a new tab; any
other link is shown as its text.
"""

import from .ui { Icon, LINK }
import from "./console_interop.js" { copyText }

# ---------------------------------------------------------------------------
# Markdown, as blocks: [kind, payload]. kind is h1..h4 | p | ul | ol | quote |
# code | table | hr. Lists carry [[indent, text], ...], tables [[cell, ...], ...].
# ---------------------------------------------------------------------------
def _flush(out: list[any], cur: list[any]) -> list[any] {
    if cur { out.append(cur); }
    return [];
}

def _hlevel(s: str) -> int {
    n = 0;
    while (n < len(s)) and (s[n] == "#") { n += 1; }
    if (n > 0) and (n <= 6) and (len(s) > n) and (s[n] == " ") { return n; }
    return 0;
}

def _olnum(s: str) -> int {
    # The length of a "12. " prefix, or 0 when the line is not a numbered item.
    p = s.find(". ");
    if (p < 1) or (p > 3) { return 0; }
    for ch in s[:p] {
        if ch not in "0123456789" { return 0; }
    }
    return p + 2;
}

def _isSep(s: str) -> bool {
    return ("-" in s) and (s.replace("|", "").replace("-", "").replace(":", "").strip() == "");
}

def _cells(s: str) -> list[str] {
    t = s.replace("\\|", chr(1)).strip();
    if t.startswith("|") { t = t[1:]; }
    if t.endswith("|") { t = t[:len(t) - 1]; }
    return [c.strip().replace(chr(1), "|") for c in t.split("|")];
}

def:pub mdBlocks(text: str) -> list[any] {
    out: list[any] = [];
    cur: list[any] = [];
    code: list[str] = [];
    lang = "";
    incode = False;
    for raw in str(text or "").split(chr(10)) {
        line = raw.rstrip();
        s = line.strip();
        if incode {
            if s.startswith("```") {
                out.append(["code", chr(10).join(code), lang]);
                code = [];
                incode = False;
            } else { code.append(line); }
            continue;
        }
        if s.startswith("```") {
            cur = _flush(out, cur);
            incode = True;
            lang = s[3:].strip();
            code = [];
            continue;
        }
        if not s { cur = _flush(out, cur); continue; }
        lvl = _hlevel(s);
        if lvl > 0 {
            cur = _flush(out, cur);
            out.append(["h" + str(lvl if (lvl < 4) else 4), s[lvl:].strip()]);
            continue;
        }
        if (s == "---") or (s == "***") or (s == "___") {
            cur = _flush(out, cur);
            out.append(["hr", ""]);
            continue;
        }
        if s.startswith("|") {
            if (not cur) or (cur[0] != "table") {
                cur = _flush(out, cur);
                cur = ["table", []];
            }
            if not _isSep(s) { cur[1].append(_cells(s)); }
            continue;
        }
        indent = len(line) - len(line.lstrip());
        bullet = s.startswith("- ") or s.startswith("* ") or s.startswith("+ ");
        num = _olnum(s);
        if bullet or (num > 0) {
            kind = "ul" if bullet else "ol";
            body = s[2:].strip() if bullet else s[num:].strip();
            if cur and (cur[0] in ["ul", "ol"]) and ((cur[0] == kind) or (indent > 0)) {
                cur[1].append([1 if (indent > 0) else 0, body]);
            } else {
                cur = _flush(out, cur);
                cur = [kind, [[0, body]]];
            }
            continue;
        }
        if s.startswith(">") {
            qt = s[1:].strip();
            if cur and (cur[0] == "quote") { cur[1].append(qt); }
            else {
                cur = _flush(out, cur);
                cur = ["quote", [qt]];
            }
            continue;
        }
        if cur and (cur[0] in ["ul", "ol"]) and (indent > 0) {
            # A wrapped list item: the indented line continues the last one.
            items: list[any] = cur[1];
            last: list[any] = items[len(items) - 1];
            last[1] = str(last[1]) + " " + s;
            continue;
        }
        if cur and (cur[0] in ["p", "quote"]) { cur[1].append(s); continue; }
        cur = _flush(out, cur);
        cur = ["p", [s]];
    }
    if incode and code { out.append(["code", chr(10).join(code), lang]); }
    _flush(out, cur);
    return out;
}

# ---------------------------------------------------------------------------
# Inline: [kind, text, href, bold, italic] tokens. kind is t | code | a.
# ---------------------------------------------------------------------------
def _italics(t: str) -> list[any] {
    # [[text, italic], ...]: *emphasis*, but only where the asterisks hug words,
    # so "2 * 3" and a lone "*" stay as written. Underscores are left alone:
    # model replies are full of snake_case names.
    out: list[any] = [];
    rest = t;
    while True {
        a = rest.find("*");
        if (a < 0) or (a + 1 >= len(rest)) or (rest[a + 1] == " ") { break; }
        e = rest.find("*", a + 1);
        if (e < 0) or (rest[e - 1] == " ") { break; }
        if a > 0 { out.append([rest[:a], False]); }
        out.append([rest[a + 1:e], True]);
        rest = rest[e + 1:];
    }
    if rest { out.append([rest, False]); }
    return out;
}

def _links(t: str, bold: bool) -> list[any] {
    out: list[any] = [];
    for piece in _italics(t) {
        for tok in _linksIn(str(piece[0]), bold) {
            tok.append(bool(piece[1]));
            out.append(tok);
        }
    }
    return out;
}

def _linksIn(t: str, bold: bool) -> list[any] {
    out: list[any] = [];
    rest = t;
    while True {
        a = rest.find("[");
        if a < 0 { break; }
        m = rest.find("](", a);
        if m < 0 { break; }
        e = rest.find(")", m + 2);
        if e < 0 { break; }
        lbl = rest[a + 1:m];
        if "]" in lbl {
            # "[x] and ..." is a bracket, not a link: keep it as text and move on.
            out.append(["t", rest[:a + 1], "", bold]);
            rest = rest[a + 1:];
            continue;
        }
        if a > 0 { out.append(["t", rest[:a], "", bold]); }
        out.append(["a", lbl, rest[m + 2:e], bold]);
        rest = rest[e + 1:];
    }
    if rest { out.append(["t", rest, "", bold]); }
    return out;
}

def _inline(s: str) -> list[any] {
    toks: list[any] = [];
    bold = False;
    parts: list[str] = str(s or "").split("`");
    for (i, part) in enumerate(parts) {
        if (i % 2) == 1 {
            if i == (len(parts) - 1) {
                for x in _links("`" + part, bold) { toks.append(x); }
            }
            else { toks.append(["code", part, "", bold, False]); }
            continue;
        }
        for (j, b) in enumerate(part.split("**")) {
            if j > 0 { bold = not bold; }
            if b {
                for y in _links(b, bold) { toks.append(y); }
            }
        }
    }
    return toks;
}

def _href(h: str) -> str {
    # A web link as is; another reference doc as its console route; else nothing.
    if h.startswith("http://") or h.startswith("https://") { return h; }
    base = h.split("#")[0];
    if base.endswith(".md") {
        seg = base.split("/");
        name = seg[len(seg) - 1];
        return "#/docs/" + name[:len(name) - 3];
    }
    return "";
}

def _spans(s: str, kp: str) -> list[any] {
    out: list[any] = [];
    for (i, t) in enumerate(_inline(s)) {
        k = kp + "-" + str(i);
        cls = ("font-semibold text-fg" if t[3] else "") + (" italic" if t[4] else "");
        if t[0] == "code" {
            out.append(<code key={k} className={"font-mono text-[0.9em] px-1 py-px rounded bg-ink-3 text-fg break-words" + (" font-semibold" if t[3] else "")}>{t[1]}</code>);
        } elif t[0] == "a" {
            href = _href(str(t[2]));
            if not href {
                out.append(<span key={k} className={cls}>{t[1]}</span>);
            } elif href.startswith("#/") {
                out.append(<a key={k} href={href} className={LINK + " no-underline"}>{t[1]}</a>);
            } else {
                out.append(<a key={k} href={href} target="_blank" rel="noopener noreferrer" className={LINK + " no-underline"}>{t[1]}</a>);
            }
        } else {
            out.append(<span key={k} className={cls}>{t[1]}</span>);
        }
    }
    return out;
}

glob TEXT: str = "m-0 text-[13.5px] leading-relaxed text-fg-2";
glob CHAT_TEXT: str = "m-0 text-sm leading-relaxed text-fg";

def:pub mdBlock(b: any, i: int, chat: bool) -> JsxElement {
    # One block. `chat` is a reply in the Studio: tighter headings with no rules
    # between sections, body text at the conversation's size, and code with a
    # Copy button.
    k = "b" + str(i);
    kind = str(b[0]);
    if chat {
        if kind in ["h1", "h2"] { return <h3 key={k} className="m-0 mt-1 text-[15px] font-semibold text-fg">{_spans(str(b[1]), k)}</h3>; }
        if kind in ["h3", "h4"] { return <h4 key={k} className="m-0 mt-1 text-sm font-semibold text-fg">{_spans(str(b[1]), k)}</h4>; }
        if kind == "code" {
            return <div key={k} className="rounded-lg bg-ink-1 border border-line overflow-hidden">
                <div className="flex items-center gap-2 px-3 h-7 border-b border-line">
                    <span className="font-mono text-[11px] text-faint">{str(b[2]) if b[2] else "code"}</span>
                    <button type="button" className="ml-auto inline-flex items-center gap-1 text-[11px] text-muted hover:text-fg cursor-pointer bg-transparent border-0"
                        onClick={lambda (e: MouseEvent) { copyText(str(b[1])); }}>
                        <Icon name="copy" size={12}/>Copy
                    </button>
                </div>
                <pre className="m-0 px-3 py-2.5 overflow-x-auto text-[12.5px] leading-relaxed font-mono text-fg-2">{str(b[1])}</pre>
            </div>;
        }
        if kind == "p" { return <p key={k} className={CHAT_TEXT + " break-words"}>{_spans(" ".join(b[1]), k)}</p>; }
        if (kind == "ul") or (kind == "ol") {
            citems: list[any] = b[1];
            clis = [<li key={k + "-" + str(j)} className={"pl-1" + (" ml-5" if it[0] else "")}>{_spans(str(it[1]), k + "-" + str(j))}</li> for (j, it) in enumerate(citems)];
            if kind == "ol" { return <ol key={k} className={CHAT_TEXT + " pl-5 list-decimal flex flex-col gap-1"}>{clis}</ol>; }
            return <ul key={k} className={CHAT_TEXT + " pl-5 list-disc flex flex-col gap-1"}>{clis}</ul>;
        }
    }
    if kind == "h1" { return <h2 key={k} className="m-0 text-[22px] font-semibold tracking-tight text-fg">{_spans(str(b[1]), k)}</h2>; }
    if kind == "h2" { return <h3 key={k} className="m-0 mt-3 pt-3 border-t border-line text-[17px] font-semibold text-fg">{_spans(str(b[1]), k)}</h3>; }
    if kind == "h3" { return <h4 key={k} className="m-0 mt-2 text-[14.5px] font-semibold text-fg">{_spans(str(b[1]), k)}</h4>; }
    if kind == "h4" { return <h5 key={k} className="m-0 mt-1 text-[13.5px] font-semibold text-fg">{_spans(str(b[1]), k)}</h5>; }
    if kind == "hr" { return <hr key={k} className="m-0 border-0 border-t border-line"/>; }
    if kind == "code" {
        return <pre key={k} className="m-0 p-3.5 rounded-lg bg-ink-1 border border-line overflow-x-auto text-[12.5px] leading-relaxed font-mono text-fg-2"><code>{str(b[1])}</code></pre>;
    }
    if kind == "quote" {
        return <blockquote key={k} className="m-0 pl-3.5 border-l-2 border-line-2 text-[13.5px] leading-relaxed text-muted">{_spans(" ".join(b[1]), k)}</blockquote>;
    }
    if (kind == "ul") or (kind == "ol") {
        items: list[any] = b[1];
        lis = [<li key={k + "-" + str(j)} className={"pl-1" + (" ml-5" if it[0] else "")}>{_spans(str(it[1]), k + "-" + str(j))}</li> for (j, it) in enumerate(items)];
        if kind == "ol" { return <ol key={k} className={TEXT + " pl-5 list-decimal flex flex-col gap-1"}>{lis}</ol>; }
        return <ul key={k} className={TEXT + " pl-5 list-disc flex flex-col gap-1"}>{lis}</ul>;
    }
    if kind == "table" {
        rows: list[any] = b[1];
        head: list[any] = rows[0] if rows else [];
        body: list[any] = rows[1:] if (len(rows) > 1) else [];
        return <div key={k} className="overflow-x-auto rounded-lg border border-line">
            <table className="w-full border-collapse text-[12.5px] leading-relaxed">
                <thead>
                    <tr className="text-left text-muted bg-ink-1">
                        {[<th key={k + "h" + str(c)} scope="col" className="px-3 py-2 font-medium align-top">{_spans(str(cell), k + "h" + str(c))}</th> for (c, cell) in enumerate(head)]}
                    </tr>
                </thead>
                <tbody>
                    {[<tr key={k + "r" + str(r)} className="border-t border-line">
                        {[<td key={k + "r" + str(r) + "c" + str(c)} className="px-3 py-2 align-top text-fg-2">{_spans(str(cell), k + "r" + str(r) + "c" + str(c))}</td> for (c, cell) in enumerate(row)]}
                    </tr> for (r, row) in enumerate(body)]}
                </tbody>
            </table>
        </div>;
    }
    return <p key={k} className={TEXT}>{_spans(" ".join(b[1]), k)}</p>;
}

def:pub Markdown(text: str, chat: bool = True) -> JsxElement {
    blocks = mdBlocks(text);
    return <div className="flex flex-col gap-2.5 min-w-0">
        {[mdBlock(b, i, chat) for (i, b) in enumerate(blocks)]}
    </div>;
}

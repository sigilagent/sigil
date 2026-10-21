"""Docs: Sigil's own reference, the same markdown the chat agent reads.

Topics on the left (the `docs` op lists docs/reference/*.md), the open doc on the
right (the `doc` op reads one). #/docs/<slug> is that doc, so a page can be
linked to; plain #/docs opens the overview.

The markdown is rendered line by line, on purpose small: headings, fenced code,
bullet and numbered lists, tables, block quotes, rules and paragraphs, with
`code`, **bold** and [links](other-doc.md) inline. A link to another reference
doc opens it here; a web link opens a new tab.
"""

import from src.sigil_console { api_console }
import from .ui { PageHead, Icon, Note, Spinner, Empty, CARD, LINK }
import from "./console_interop.js" { navTo, seen, remember }
import from react { useEffect }

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

def _blocks(text: str) -> list[any] {
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
# Inline: [kind, text, href, bold] tokens. kind is t | code | a.
# ---------------------------------------------------------------------------
def _links(t: str, bold: bool) -> list[any] {
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
            else { toks.append(["code", part, "", bold]); }
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
        cls = "font-semibold text-fg" if t[3] else "";
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

def _block(b: any, i: int) -> JsxElement {
    k = "b" + str(i);
    kind = str(b[0]);
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

def:pub DocsPage(route: list[str], go: Callable[[str], None], ask: Callable[[str], None], refresh: Callable[[], None]) -> JsxElement {
    has topics: list[any] = [];
    has loaded: bool = False;
    has err: str = "";
    has q: str = "";
    has texts: dict[str, str] = {};
    has derr: str = "";

    async def call(op: str, args: dict[str, any]) -> any {
        r = root spawn api_console(op=op, args=args);
        if r.reports { return r.reports[0]; }
        return {"ok": False, "error": "no response from Sigil"};
    }

    async def loadTopics() {
        m: any = await call("docs", {});
        loaded = True;
        if m and (not m.error) { topics = remember("docs", list(m)); err = ""; }
        elif m { err = str(m.error); }
    }

    async def loadDoc(slug: str) {
        derr = "";
        m: any = await call("doc", {"topic": slug});
        if m and m.ok {
            remember("doc:" + slug, str(m.text or ""));
            texts = {**texts, (slug): str(m.text or "")};
        } elif m { derr = str(m.error); }
    }

    can with entry {
        prev: any = seen("docs");
        if prev { topics = prev; loaded = True; }
        loadTopics();
    }

    cur = str(route[1]) if (len(route) > 1) else "overview";

    # Docs are files in the repo, so one read per doc per tab is enough.
    useEffect(lambda {
        window.scrollTo(0, 0);
        if not seen("doc:" + cur) { loadDoc(cur); }
    }, [cur]);

    def openDoc(slug: str) { navTo("/docs/" + slug); }

    needle = q.strip().lower();
    shown = [t for t in topics if (not needle) or (needle in (str(t.slug) + " " + str(t.title) + " " + str(t.summary or "")).lower())];
    cached: any = seen("doc:" + cur);
    text = "";
    if cur in texts { text = str(texts[cur]); }
    elif cached { text = str(cached); }
    blocks = _blocks(text) if text else [];
    title = cur.replace("-", " ");
    for t in topics {
        if str(t.slug) == cur { title = str(t.title); }
    }

    return <div className="flex flex-col">
        <PageHead title="Docs" kicker="Reference · the same text the chat agent reads" onAsk={ask}
            askHint="Ask Sigil about its docs" tag={cur}/>

        <div className="px-7 pt-5 pb-10 flex flex-wrap gap-5 items-start">
            <nav aria-label="Doc topics" className={CARD + " flex-[1_1_240px] lg:max-w-[300px] min-w-0 overflow-hidden"}>
                <div className="p-3 border-b border-line">
                    <label className="flex items-center gap-2 h-9 px-3 rounded-lg bg-ink-1 border border-line-2">
                        <Icon name="search" size={15} cls="text-muted"/>
                        <span className="sr-only">Filter topics</span>
                        <input value={q} placeholder="Filter topics" onChange={lambda (e: ChangeEvent) { q = e.target.value; }}
                            className="flex-1 min-w-0 bg-transparent border-0 outline-none text-[13px] text-fg placeholder:text-faint"/>
                    </label>
                </div>
                {(<div className="px-4 py-4"><Spinner label="Listing topics…"/></div>) if (not loaded) else None}
                {(<div className="p-3"><Note text={err} tone="bad"/></div>) if err else None}
                {(<div className="px-4 py-4 text-[12.5px] text-muted">No topic matches.</div>) if (loaded and (not shown) and (not err)) else None}
                <ul className="list-none m-0 p-1.5 flex flex-col gap-0.5">
                    {for t in shown {
                        <li key={str(t.slug)}>
                            <a href={"#/docs/" + str(t.slug)} aria-current={"page" if (str(t.slug) == cur) else None}
                                onClick={lambda (e: MouseEvent) { e.preventDefault(); openDoc(str(t.slug)); }}
                                className={"flex flex-col gap-0.5 px-2.5 py-2 rounded-lg no-underline " + ("bg-violet-500/15 text-fg" if (str(t.slug) == cur) else "text-fg-2 hover:bg-ink-3 hover:text-fg")}>
                                <span className="text-[13px] font-medium">{str(t.title)}</span>
                                {(<span className="text-xs text-muted line-clamp-2">{str(t.summary)}</span>) if t.summary else None}
                            </a>
                        </li>
                    }}
                </ul>
            </nav>

            <article aria-label={title} className={CARD + " flex-[999_1_520px] min-w-0 px-7 py-6 flex flex-col gap-3.5"}>
                {[_block(b, i) for (i, b) in enumerate(blocks)]}
                {(<Note text={derr} tone="bad"/>) if ((not text) and derr) else None}
                {(<Spinner label={"Opening " + title + "…"}/>) if ((not text) and (not derr)) else None}
            </article>
        </div>
    </div>;
}

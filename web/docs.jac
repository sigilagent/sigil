"""Docs: Sigil's own reference, the same markdown the chat agent reads.

Topics on the left (the `docs` op lists docs/reference/*.md), the open doc on the
right (the `doc` op reads one). #/docs/<slug> is that doc, so a page can be
linked to; plain #/docs opens the overview.

The markdown is rendered by web/markdown.jac, the same renderer as the Studio's
chat replies. A link to another reference doc opens it here; a web link opens a
new tab.
"""

import from src.sigil_console { api_console }
import from .ui { PageHead, Icon, Note, Spinner, Empty, CARD, LINK }
import from .markdown { mdBlocks, mdBlock }
import from "./console_interop.js" { navTo, seen, remember }
import from react { useEffect }

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
    blocks = mdBlocks(text) if text else [];
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
                {[mdBlock(b, i, False) for (i, b) in enumerate(blocks)]}
                {(<Note text={derr} tone="bad"/>) if ((not text) and derr) else None}
                {(<Spinner label={"Opening " + title + "…"}/>) if ((not text) and (not derr)) else None}
            </article>
        </div>
    </div>;
}

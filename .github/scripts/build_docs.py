#!/usr/bin/env python3
"""Build the Pages site: copy docs/ to _site/ and render every reference doc
as its own styled HTML page (plus a reference index). The .md sources stay
served verbatim next to the HTML — they remain the agent's own self-docs.

Run from the repo root: python3 .github/scripts/build_docs.py
Requires: pip install markdown
"""
import re
import shutil
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
SITE = ROOT / "_site"
REF = DOCS / "reference"

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} · Sigil docs</title>
<meta name="description" content="Sigil reference — {title}">
<style>
:root{{
  --bg:#08080d; --bg-2:#0d0d16; --panel:#111119;
  --line:rgba(255,255,255,.07); --line-strong:rgba(255,255,255,.14);
  --text:#e8e8f0; --muted:#9a9aad; --faint:#63637a; --violet:#8b5cf6;
  --mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace;
  --sans:-apple-system,"Segoe UI",Inter,Roboto,sans-serif;
}}
*{{box-sizing:border-box;margin:0;padding:0}}
html{{scroll-behavior:smooth}}
body{{background:var(--bg);color:var(--text);font-family:var(--sans);line-height:1.65;font-size:16px}}
a{{color:var(--violet);text-decoration:none}} a:hover{{text-decoration:underline}}
nav{{position:sticky;top:0;background:rgba(8,8,13,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--line);z-index:5}}
.nav-inner{{max-width:1080px;margin:0 auto;padding:0 24px;display:flex;align-items:center;gap:18px;height:58px}}
.brand{{font-family:var(--mono);font-weight:700;color:var(--text);letter-spacing:.02em}}
.crumb{{color:var(--faint);font-size:14px}}
.nav-right{{margin-left:auto;display:flex;gap:18px}}
.nav-right a{{color:var(--muted);font-size:14px}} .nav-right a:hover{{color:var(--text)}}
.layout{{max-width:1080px;margin:0 auto;padding:36px 24px 90px;display:grid;grid-template-columns:220px 1fr;gap:44px}}
aside{{position:sticky;top:80px;align-self:start}}
aside .kicker{{font-family:var(--mono);font-size:11.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--violet);margin-bottom:12px}}
aside a{{display:block;color:var(--muted);font-size:14px;padding:5px 0}}
aside a:hover{{color:var(--text);text-decoration:none}}
aside a.here{{color:var(--text);font-weight:600}}
main{{min-width:0}}
main h1{{font-size:30px;letter-spacing:-.02em;margin-bottom:18px}}
main h2{{font-size:20px;margin:34px 0 12px;letter-spacing:-.01em}}
main h3{{font-size:16.5px;margin:24px 0 10px}}
main p,main li{{color:var(--muted)}} main strong{{color:var(--text)}} main em{{color:var(--text)}}
main ul,main ol{{padding-left:22px;margin:10px 0}}
main code{{font-family:var(--mono);font-size:.86em;background:var(--panel);border:1px solid var(--line);border-radius:5px;padding:1.5px 5px;color:var(--text)}}
main pre{{background:var(--bg-2);border:1px solid var(--line);border-radius:12px;padding:16px 18px;overflow-x:auto;margin:14px 0}}
main pre code{{background:none;border:none;padding:0;color:#c9c9e0;font-size:13px;line-height:1.55}}
main table{{border-collapse:collapse;width:100%;margin:14px 0;font-size:14.5px}}
main th,main td{{border:1px solid var(--line);padding:8px 12px;text-align:left;color:var(--muted)}}
main th{{color:var(--text);background:var(--bg-2);font-weight:600}}
main blockquote{{border-left:3px solid var(--violet);padding:2px 0 2px 16px;margin:14px 0;color:var(--faint)}}
@media(max-width:860px){{.layout{{grid-template-columns:1fr;gap:20px}} aside{{position:static;border-bottom:1px solid var(--line);padding-bottom:16px}}}}
</style>
</head>
<body>
<nav><div class="nav-inner">
  <a class="brand" href="../">sigil</a><span class="crumb">/ docs / {slug}</span>
  <div class="nav-right">
    <a href="index.html">All topics</a>
    <a href="https://github.com/sigilagent/sigil" target="_blank" rel="noopener">GitHub</a>
  </div>
</div></nav>
<div class="layout">
<aside><div class="kicker">Reference</div>{sidebar}</aside>
<main>{body}</main>
</div>
</body>
</html>
"""


def title_of(md_text: str, slug: str) -> str:
    m = re.search(r"^#\s+(.+)$", md_text, re.M)
    return m.group(1).strip() if m else slug


def render(md_text: str) -> str:
    return markdown.markdown(
        md_text, extensions=["fenced_code", "tables", "sane_lists"]
    )


def main() -> None:
    if SITE.exists():
        shutil.rmtree(SITE)
    shutil.copytree(DOCS, SITE)

    pages = sorted(p for p in REF.glob("*.md") if p.name != "README.md")
    # overview and the compiler first — the two front doors
    order = ["overview", "skill-compilation"]
    pages.sort(key=lambda p: (order.index(p.stem) if p.stem in order else 99, p.stem))

    entries = [(p.stem, title_of(p.read_text(), p.stem)) for p in pages]

    def sidebar(current: str) -> str:
        return "".join(
            f'<a class="{"here" if slug == current else ""}" href="{slug}.html">{title}</a>'
            for slug, title in entries
        )

    for p in pages:
        text = p.read_text()
        # intra-reference links: point at the rendered pages
        body = render(re.sub(r"\(([\w-]+)\.md\)", r"(\1.html)", text))
        out = SITE / "reference" / f"{p.stem}.html"
        out.write_text(
            PAGE.format(title=title_of(text, p.stem), slug=p.stem,
                        sidebar=sidebar(p.stem), body=body)
        )

    # the index page: rendered from the directory README
    idx_md = (REF / "README.md").read_text()
    idx_body = render(re.sub(r"\(([\w-]+)\.md\)", r"(\1.html)", idx_md))
    (SITE / "reference" / "index.html").write_text(
        PAGE.format(title="Reference", slug="index", sidebar=sidebar(""), body=idx_body)
    )
    print(f"built {len(pages) + 1} pages -> {SITE / 'reference'}")


if __name__ == "__main__":
    main()

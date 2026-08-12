#!/usr/bin/env python3
"""Build the Pages site: copy docs/ to _site/ and render every reference doc
as its own styled HTML page (plus a reference index), and every blog post in
docs/blog/ as a styled article (plus a blog index). The .md sources stay
served verbatim next to the HTML — they remain the agent's own self-docs.

Run from the repo root: python3 .github/scripts/build_docs.py
Requires: pip install markdown
"""
import html as html_mod
import re
import shutil
from datetime import date
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
SITE = ROOT / "_site"
REF = DOCS / "reference"
BLOG = DOCS / "blog"

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
main pre.mermaid{{background:var(--bg-2);border:1px solid var(--line);border-radius:12px;padding:18px;display:flex;justify-content:center}}
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
    <a href="../blog/">Blog</a>
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


# ---------------------------------------------------------------- blog ----
# Posts are docs/blog/*.md with a small frontmatter block (title, date,
# author, description, hero). Styled to match the landing page, not the
# reference: a single reading column, article typography, big images.

BLOG_CSS = """
:root{
  --bg:#08080d; --bg-2:#0d0d16; --panel:#12121d;
  --line:rgba(255,255,255,.08); --line-strong:rgba(255,255,255,.14);
  --text:#e9e7f3; --muted:#9d9ab4; --faint:#6f6c86;
  --violet:#a78bfa; --violet-strong:#8b5cf6; --cyan:#22d3ee;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
  --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
}
*{box-sizing:border-box;margin:0;padding:0}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
body{background:var(--bg);color:var(--text);font-family:var(--sans);font-size:16.5px;line-height:1.7;-webkit-font-smoothing:antialiased}
a{color:var(--violet);text-decoration:none} a:hover{color:var(--cyan)}
nav{position:sticky;top:0;z-index:50;backdrop-filter:blur(14px);background:rgba(8,8,13,.72);border-bottom:1px solid var(--line)}
.nav-inner{max-width:1080px;margin:0 auto;padding:0 24px;display:flex;align-items:center;gap:16px;height:58px}
.brand{font-family:var(--mono);font-weight:700;color:var(--text);letter-spacing:.02em}
.brand:hover{color:var(--text)}
.crumb{color:var(--faint);font-size:14px}
.nav-right{margin-left:auto;display:flex;gap:20px}
.nav-right a{color:var(--muted);font-size:14px} .nav-right a:hover{color:var(--text)}
.kicker{font-family:var(--mono);font-size:12.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--violet)}
footer{border-top:1px solid var(--line);margin-top:70px;padding:34px 24px 46px}
.foot-inner{max-width:1080px;margin:0 auto;display:flex;justify-content:space-between;gap:18px;flex-wrap:wrap;color:var(--muted);font-size:14px}
.foot-inner a{color:var(--muted)} .foot-inner a:hover{color:var(--text)}

/* in-article banner card: rendered natively (HTML/SVG) instead of a PNG,
   so it stays crisp, theme-matched, and the mark animates like the hero */
.post-banner-wrap{margin:28px 0}
.post-banner{
  display:flex;align-items:center;justify-content:space-between;gap:28px;
  border:1px solid rgba(139,92,246,.35);border-radius:16px;padding:28px 32px;
  background:
    radial-gradient(420px 260px at 85% 15%, rgba(139,92,246,.22), transparent 60%),
    radial-gradient(340px 240px at 8% 95%, rgba(34,211,238,.1), transparent 62%),
    linear-gradient(180deg,#12121d,#0d0d16);
  box-shadow:0 14px 50px -18px rgba(139,92,246,.45);
  transition:border-color .15s ease;
}
.post-banner:hover{border-color:var(--violet)}
.pb-copy{min-width:0}
.pb-logo{display:flex;align-items:center;gap:9px;font-family:var(--mono);font-weight:700;letter-spacing:.18em;font-size:13px;color:var(--text);margin-bottom:14px}
.pb-logo svg{width:22px;height:22px;display:block}
.pb-title{font-size:clamp(21px,3.4vw,29px);font-weight:700;letter-spacing:-.03em;color:var(--text);line-height:1.2}
.pb-title em{font-style:italic;background:linear-gradient(100deg,var(--violet) 10%,var(--cyan) 90%);-webkit-background-clip:text;background-clip:text;color:transparent}
.pb-pipeline{font-family:var(--mono);font-size:13px;color:var(--faint);margin-top:10px}
.pb-pill{display:inline-flex;align-items:center;margin-top:18px;font-family:var(--mono);font-size:12.5px;color:var(--violet);border:1px solid rgba(139,92,246,.4);background:rgba(139,92,246,.1);padding:6px 13px;border-radius:100px}
.post-banner:hover .pb-pill{color:var(--cyan);border-color:rgba(34,211,238,.5)}
.pb-mark{flex:0 0 auto}
.pb-mark svg{width:132px;height:132px;display:block;filter:drop-shadow(0 0 26px rgba(139,92,246,.4))}
.pb-mark .ring{animation:pbspin 60s linear infinite;transform-box:view-box;transform-origin:center}
.pb-mark .hex{animation:pbspin 42s linear infinite reverse;transform-box:view-box;transform-origin:center}
.pb-mark .tri{animation:pbspin 30s linear infinite;transform-box:view-box;transform-origin:center}
@keyframes pbspin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.pb-mark *{animation:none !important}}
@media (max-width:620px){
  .post-banner{flex-direction:column-reverse;align-items:flex-start;gap:18px;padding:22px 20px}
  .pb-mark svg{width:96px;height:96px}
}

/* fenced code blocks get the landing page's terminal-card chrome: dots,
   a label, a copy button, and light tinting for shell commands */
article .code{border:1px solid var(--line);border-radius:13px;background:#0a0a12;margin:0 0 18px;overflow:hidden}
article .code-head{display:flex;align-items:center;gap:8px;padding:9px 14px;border-bottom:1px solid var(--line);background:rgba(255,255,255,.02)}
article .code .dots{display:flex;gap:6px;margin-right:4px}
article .code .dots i{width:11px;height:11px;border-radius:50%;display:block}
article .code .dots i:nth-child(1){background:#ff5f57}
article .code .dots i:nth-child(2){background:#febc2e}
article .code .dots i:nth-child(3){background:#28c840}
article .code .lbl{font-family:var(--mono);font-size:12px;color:var(--faint);letter-spacing:.03em}
article .code .copy-btn{margin-left:auto;font-family:var(--mono);font-size:11.5px;color:var(--muted);background:rgba(255,255,255,.05);border:1px solid var(--line);border-radius:7px;padding:4px 10px;cursor:pointer;transition:.15s}
article .code .copy-btn:hover{color:var(--text);border-color:var(--violet)}
article .code pre{border:0;border-radius:0;margin:0;background:none}
article .code pre .c{color:var(--faint)}
article .code pre .k{color:var(--violet)}
article .code pre .s{color:#4ade80}
article .code pre .p{color:#f5c451}
"""

# copy-to-clipboard for the dressed code blocks; appended to post pages only
COPY_JS = """<script>
document.querySelectorAll('.code .copy-btn').forEach(function(btn){
  btn.addEventListener('click', function(){
    var code = btn.closest('.code').querySelector('pre').innerText;
    navigator.clipboard.writeText(code).then(function(){
      var t = btn.textContent; btn.textContent = 'Copied \\u2713';
      setTimeout(function(){ btn.textContent = t; }, 1400);
    });
  });
});
</script>"""

CODE_BLOCK_RE = re.compile(
    r'<pre><code(?: class="language-([\w-]+)")?>(.*?)</code></pre>', re.S
)
SHELL_LANGS = {"bash", "sh", "shell", "zsh", "console"}


def tint_shell(code: str) -> str:
    """Light, conservative tinting for shell snippets: comments, quoted
    strings, flags, and the leading command word. Operates on the already
    HTML-escaped code text."""
    lines = []
    for line in code.split("\n"):
        if line.lstrip().startswith("#"):
            lines.append(f'<span class="c">{line}</span>')
            continue
        line = re.sub(r"(&quot;.*?&quot;)", r'<span class="s">\1</span>', line)
        line = re.sub(r"(?<=[\s=])(--?[A-Za-z][\w-]*)", r'<span class="p">\1</span>', line)
        line = re.sub(r"^([A-Za-z./][\w./-]*)", r'<span class="k">\1</span>', line)
        lines.append(line)
    return "\n".join(lines)


def dress_code_blocks(body: str) -> str:
    """Wrap every fenced code block in the landing page's terminal-card
    chrome. Mermaid blocks were already rewritten by render() and don't
    match here."""
    def repl(m: re.Match) -> str:
        lang, code = m.group(1), m.group(2)
        if lang in SHELL_LANGS:
            label, code = "your terminal", tint_shell(code)
        else:
            label = lang or "code"
        return (
            '<div class="code"><div class="code-head">'
            '<div class="dots"><i></i><i></i><i></i></div>'
            f'<span class="lbl">{label}</span>'
            '<button class="copy-btn" type="button">Copy</button></div>'
            f"<pre><code>{code}</code></pre></div>"
        )

    return CODE_BLOCK_RE.sub(repl, body)

BLOG_POST_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} · Sigil blog</title>
<meta name="description" content="{description}">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:type" content="article">
<meta property="og:image" content="{og_image}">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cg fill='none' stroke='%23a78bfa' stroke-width='1.6'%3E%3Cpolygon points='16,3 28,10 28,22 16,29 4,22 4,10' /%3E%3Cpath d='M16 3 L16 16 M28 10 L16 16 M28 22 L16 16 M16 29 L16 16 M4 22 L16 16 M4 10 L16 16'/%3E%3C/g%3E%3Ccircle cx='16' cy='16' r='2.6' fill='%2322d3ee'/%3E%3C/svg%3E">
<style>
{css}
.article-wrap{{max-width:760px;margin:0 auto;padding:52px 24px 40px}}
.post-head .kicker{{margin-bottom:16px;display:block}}
h1.post-title{{font-size:clamp(30px,5vw,42px);font-weight:700;letter-spacing:-.03em;line-height:1.15;margin-bottom:16px}}
.post-meta{{font-family:var(--mono);font-size:13px;color:var(--faint);margin-bottom:36px}}
.post-meta b{{color:var(--muted);font-weight:600}}
article p{{color:var(--muted);margin:0 0 18px}}
article strong{{color:var(--text)}} article em{{color:var(--text)}}
article h2{{font-size:24px;letter-spacing:-.02em;margin:44px 0 14px}}
article h3{{font-size:18.5px;margin:30px 0 10px}}
article ul,article ol{{padding-left:24px;margin:0 0 18px;color:var(--muted)}}
article li{{margin:5px 0}}
article code{{font-family:var(--mono);font-size:.86em;background:var(--panel);border:1px solid var(--line);border-radius:5px;padding:1.5px 5px;color:var(--text)}}
article pre{{background:#0a0a12;border:1px solid var(--line);border-radius:12px;padding:16px 18px;overflow-x:auto;margin:0 0 18px}}
article pre code{{background:none;border:none;padding:0;color:#c9c9e0;font-size:13.3px;line-height:1.7}}
article img{{max-width:100%;height:auto;display:block;border:1px solid var(--line);border-radius:14px;margin:26px 0 10px}}
article p:has(> a > img) + blockquote,article p:has(> img) + blockquote{{border:0;padding:0 6px;margin:0 0 26px;font-size:14px;color:var(--faint);line-height:1.6}}
article blockquote{{border-left:3px solid var(--violet-strong);padding:2px 0 2px 18px;margin:0 0 18px;color:var(--muted)}}
article blockquote p{{margin:0 0 6px;color:inherit}} article blockquote p:last-child{{margin:0}}
article table{{border-collapse:collapse;width:100%;margin:0 0 18px;font-size:14.5px;display:block;overflow-x:auto}}
article th,article td{{border:1px solid var(--line);padding:9px 14px;text-align:left;color:var(--muted);white-space:nowrap}}
article th{{color:var(--text);background:var(--bg-2);font-weight:600}}
article hr{{border:0;border-top:1px solid var(--line);margin:34px 0}}
.post-end{{margin-top:52px;padding-top:26px;border-top:1px solid var(--line);display:flex;justify-content:space-between;gap:14px;flex-wrap:wrap;font-size:14.5px}}
</style>
</head>
<body>
<nav><div class="nav-inner">
  <a class="brand" href="../">sigil</a><span class="crumb">/ blog</span>
  <div class="nav-right">
    <a href="./">All posts</a>
    <a href="../reference/">Docs</a>
    <a href="https://github.com/sigilagent/sigil" target="_blank" rel="noopener">GitHub</a>
  </div>
</div></nav>
<div class="article-wrap">
  <header class="post-head">
    <span class="kicker">Blog</span>
    <h1 class="post-title">{title}</h1>
    <p class="post-meta">{date_display} · <b>{author}</b> · {readtime} min read</p>
  </header>
  <article>
{body}
  </article>
  <div class="post-end">
    <a href="./">← All posts</a>
    <a href="../">sigilagent.com</a>
  </div>
</div>
<footer><div class="foot-inner">
  <span><span style="color:var(--violet);font-weight:600">Sigil</span> · the skill compiler</span>
  <span><a href="../reference/">Docs</a> · <a href="https://arxiv.org/abs/2607.27309" target="_blank" rel="noopener">Paper</a> · <a href="https://github.com/sigilagent/sigil" target="_blank" rel="noopener">GitHub</a></span>
</div></footer>
</body>
</html>
"""

BLOG_INDEX_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Blog · Sigil</title>
<meta name="description" content="Notes from the Sigil project: compiling agent skills into typed harnesses.">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cg fill='none' stroke='%23a78bfa' stroke-width='1.6'%3E%3Cpolygon points='16,3 28,10 28,22 16,29 4,22 4,10' /%3E%3Cpath d='M16 3 L16 16 M28 10 L16 16 M28 22 L16 16 M16 29 L16 16 M4 22 L16 16 M4 10 L16 16'/%3E%3C/g%3E%3Ccircle cx='16' cy='16' r='2.6' fill='%2322d3ee'/%3E%3C/svg%3E">
<style>
{css}
.list-wrap{{max-width:1080px;margin:0 auto;padding:56px 24px 30px}}
.list-head{{margin-bottom:40px}}
.list-head .kicker{{display:block;margin-bottom:14px}}
.list-head h1{{font-size:clamp(30px,4.6vw,44px);font-weight:700;letter-spacing:-.03em;margin-bottom:12px}}
.list-head p{{color:var(--muted);font-size:17px;max-width:640px}}
.post-card{{display:grid;grid-template-columns:minmax(0,0.92fr) minmax(0,1.08fr);gap:0;border:1px solid var(--line);border-radius:18px;overflow:hidden;background:linear-gradient(180deg,var(--panel),var(--bg-2));margin-bottom:22px;transition:border-color .15s ease,transform .15s ease}}
.post-card:hover{{border-color:rgba(139,92,246,.5);transform:translateY(-2px)}}
.post-card .thumb{{background:#fdfdfe;border-right:1px solid var(--line);min-height:220px;display:flex;align-items:center;justify-content:center;padding:18px}}
.post-card .thumb img{{max-width:100%;max-height:100%;object-fit:contain;display:block}}
.post-card .body{{padding:28px 30px;display:flex;flex-direction:column;justify-content:center}}
.post-card .meta{{font-family:var(--mono);font-size:12.5px;color:var(--faint);margin-bottom:12px}}
.post-card h2{{font-size:23px;letter-spacing:-.02em;line-height:1.25;color:var(--text);margin-bottom:12px}}
.post-card p.desc{{color:var(--muted);font-size:15px;margin-bottom:16px}}
.post-card .read{{font-size:14.5px;font-weight:600;color:var(--violet)}}
.post-card:hover .read{{color:var(--cyan)}}
@media(max-width:760px){{.post-card{{grid-template-columns:1fr}}.post-card .thumb{{min-height:0;aspect-ratio:2.6/1}}.post-card .body{{padding:22px 20px}}}}
</style>
</head>
<body>
<nav><div class="nav-inner">
  <a class="brand" href="../">sigil</a><span class="crumb">/ blog</span>
  <div class="nav-right">
    <a href="../reference/">Docs</a>
    <a href="https://github.com/sigilagent/sigil" target="_blank" rel="noopener">GitHub</a>
  </div>
</div></nav>
<div class="list-wrap">
  <header class="list-head">
    <span class="kicker">Blog</span>
    <h1>Notes from the Sigil project</h1>
    <p>Skill compilation, typed agent harnesses, and what changes when an agent's procedure stops being a prompt and starts being a program.</p>
  </header>
{cards}
</div>
<footer><div class="foot-inner">
  <span><span style="color:var(--violet);font-weight:600">Sigil</span> · the skill compiler</span>
  <span><a href="../reference/">Docs</a> · <a href="https://arxiv.org/abs/2607.27309" target="_blank" rel="noopener">Paper</a> · <a href="https://github.com/sigilagent/sigil" target="_blank" rel="noopener">GitHub</a></span>
</div></footer>
</body>
</html>
"""

FRONT_MATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.S)


def parse_front_matter(text: str) -> tuple[dict, str]:
    m = FRONT_MATTER_RE.match(text)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip()
    return meta, text[m.end():]


def build_blog() -> int:
    posts = []
    for p in sorted(BLOG.glob("*.md")):
        meta, body_md = parse_front_matter(p.read_text())
        d = date.fromisoformat(meta.get("date", "1970-01-01"))
        posts.append({
            "slug": p.stem,
            "title": meta.get("title", p.stem),
            "description": meta.get("description", ""),
            "author": meta.get("author", "The Sigil project"),
            "hero": meta.get("hero", ""),
            "date": d,
            "date_display": f"{d:%B} {d.day}, {d.year}",
            "readtime": max(1, round(len(body_md.split()) / 200)),
            "body": dress_code_blocks(render(body_md)),
        })
    posts.sort(key=lambda x: x["date"], reverse=True)

    out_dir = SITE / "blog"
    out_dir.mkdir(exist_ok=True)
    esc = html_mod.escape
    for post in posts:
        hero_site_path = post["hero"].replace("../", "")
        page_html = BLOG_POST_PAGE.format(
            css=BLOG_CSS,
            title=esc(post["title"]),
            description=esc(post["description"]),
            og_image=f"https://sigilagent.com/{hero_site_path}" if hero_site_path else "https://sigilagent.com/assets/social-card.png",
            date_display=post["date_display"],
            author=esc(post["author"]),
            readtime=post["readtime"],
            body=post["body"],
        )
        (out_dir / f"{post['slug']}.html").write_text(
            page_html.replace("</body>", COPY_JS + "\n</body>")
        )

    cards = "\n".join(
        f'''  <a class="post-card" href="{post['slug']}.html">
    <div class="thumb"><img src="{esc(post['hero'])}" alt="" loading="lazy"></div>
    <div class="body">
      <div class="meta">{post['date_display']} · {post['readtime']} min read</div>
      <h2>{esc(post['title'])}</h2>
      <p class="desc">{esc(post['description'])}</p>
      <span class="read">Read the post →</span>
    </div>
  </a>'''
        for post in posts
    )
    (out_dir / "index.html").write_text(BLOG_INDEX_PAGE.format(css=BLOG_CSS, cards=cards))
    return len(posts)


def title_of(md_text: str, slug: str) -> str:
    m = re.search(r"^#\s+(.+)$", md_text, re.M)
    return m.group(1).strip() if m else slug


MERMAID_RE = re.compile(r'<pre><code class="language-mermaid">(.*?)</code></pre>', re.S)
MERMAID_JS = (
    '<script type="module">'
    'import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";'
    "mermaid.initialize({startOnLoad:true,theme:'dark',themeVariables:{"
    "primaryColor:'#1a1a26',primaryBorderColor:'#8b5cf6',primaryTextColor:'#e8e8f0',"
    "lineColor:'#63637a',fontFamily:'-apple-system,Segoe UI,Inter,sans-serif'}});"
    "</script>"
)


def render(md_text: str) -> str:
    html = markdown.markdown(
        md_text, extensions=["fenced_code", "tables", "sane_lists"]
    )
    # ```mermaid fences -> live diagrams (mermaid reads decoded textContent,
    # so the entity-escaped arrows inside <pre> are fine)
    return MERMAID_RE.sub(r'<pre class="mermaid">\1</pre>', html)


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
        if 'class="mermaid"' in body:
            body += MERMAID_JS
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

    if BLOG.is_dir():
        n = build_blog()
        print(f"built {n + 1} pages -> {SITE / 'blog'}")


if __name__ == "__main__":
    main()

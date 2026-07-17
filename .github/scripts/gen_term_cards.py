#!/usr/bin/env python3
"""Generate on-brand terminal-card SVGs for the README/site from REAL run output.

Content is transcribed from actual captured runs:
  - the brainstorming gpt-5 lift (superpowers-exp/brainstorming/lift.json timings)
  - the note-writer ejected-artifact run (the live TUI capture in PR #70)
"""
import pathlib

OUT = pathlib.Path(__file__).resolve().parents[2] / "docs" / "assets"

COLORS = {"plain": "#e8e8f0", "dim": "#63637a", "cyan": "#22d3ee", "violet": "#a78bfa"}

LINES_COMPILE = [
    [("dim", "$ "), ("plain", "sigil compile skills/brainstorming/SKILL.md")],
    [("plain", "")],
    [("plain", "  Compiling skills/brainstorming/SKILL.md")],
    [("cyan", "  ✔ "), ("plain", "spec loop       "), ("plain", "80 rules · 3 rounds · ok"), ("dim", "   17m 25s")],
    [("cyan", "  ✔ "), ("plain", "workflow spine  "), ("plain", "28 nodes · 37 edges · 3 rounds"), ("dim", "   10m 10s")],
    [("cyan", "  ✔ "), ("plain", "annotator flows "), ("plain", "34 carries · 17 knowledge · 4 HIL"), ("dim", "   2m 11s")],
    [("cyan", "  ✔ "), ("plain", "assemble        "), ("plain", "clean"), ("dim", "   1.8s")],
    [("violet", "  ⟳ "), ("plain", "repair  round 1: 3 issues → views")],
    [("cyan", "  ✔ "), ("plain", "gates           "), ("plain", "compile ✓"), ("dim", "   52s")],
    [("plain", "")],
    [("plain", "  compiled skill: "), ("cyan", "brainstorming"), ("plain", "  → "), ("plain", "brainstorming.jac")],
]

LINES_RUN = [
    [("dim", "$ "), ("plain", "./note_writer.jac \"write a haiku about compilers to haiku.txt\"")],
    [("plain", "")],
    [("violet", "  ◆ "), ("plain", "note-writer")],
    [("dim", "    write a haiku about compilers to haiku.txt")],
    [("plain", "")],
    [("violet", "  ◆ "), ("plain", "draft"), ("dim", "  1.3s")],
    [("violet", "  ◆ "), ("plain", "emit"), ("dim", "   0.0s")],
    [("violet", "  ◆ "), ("plain", "done"), ("dim", "   0.0s")],
    [("plain", "")],
    [("cyan", "  ✔"), ("dim", "  1.3s total")],
    [("dim", "  ──────────────────────────")],
    [("plain", "  Compilers translate,")],
    [("plain", "  code whispers to machine's heart.")],
    [("dim", "  ──────────────────────────")],
    [("dim", "  artifacts:")],
    [("cyan", "    haiku.txt")],
]


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def card(lines, title, width=780):
    lh, top = 24, 74
    h = top + len(lines) * lh + 16
    rows, y = [], top
    for segs in lines:
        spans = "".join(
            f'<tspan fill="{COLORS[k]}">{esc(txt)}</tspan>' for k, txt in segs
        )
        rows.append(
            f'<text x="26" y="{y}" font-family="SF Mono,Menlo,Consolas,monospace" '
            f'font-size="14.5" xml:space="preserve">{spans}</text>'
        )
        y += lh
    dots = "".join(
        f'<circle cx="{26 + i*22}" cy="24" r="6" fill="#3a3a4a"/>' for i in range(3)
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {h}" '
        f'width="{width}" height="{h}" role="img" aria-label="{esc(title)}">\n'
        f'  <rect x="1" y="1" width="{width-2}" height="{h-2}" rx="14" '
        f'fill="#0d0d16" stroke="rgba(255,255,255,.12)"/>\n'
        f'  {dots}\n'
        f'  <text x="{width/2}" y="29" text-anchor="middle" '
        f'font-family="SF Mono,Menlo,Consolas,monospace" font-size="12.5" '
        f'fill="#63637a">{esc(title)}</text>\n'
        f'  <line x1="1" y1="46" x2="{width-1}" y2="46" stroke="rgba(255,255,255,.07)"/>\n'
        + "\n".join(rows)
        + "\n</svg>\n"
    )


def main():
    (OUT / "term-compile.svg").write_text(
        card(LINES_COMPILE, "sigil compile — the live build view")
    )
    (OUT / "term-run.svg").write_text(
        card(LINES_RUN, "a compiled artifact, run in a terminal")
    )
    print("wrote term-compile.svg, term-run.svg to", OUT)


if __name__ == "__main__":
    main()

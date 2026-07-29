#!/usr/bin/env python3
"""Render ANSI truecolor lines to SVG, for previewing the status line.

Handles only what the status line emits: SGR 0 reset, 38;2;r;g;b foreground,
48;2;r;g;b background, plus 1/2 for bold/dim.
"""
import re
import sys
from html import escape

FONT = "DejaVuSansM Nerd Font Mono, DejaVu Sans Mono, monospace"
SIZE = 17.0
CW = SIZE * 0.60205  # DejaVu Sans Mono advance width
LH = SIZE * 1.65
PAD = 14.0
TERM_BG = "#1e1e1e"
TERM_FG = "#cccccc"

SGR = re.compile(r"\x1b\[([0-9;]*)m")


def parse(line):
    """-> [(text, fg, bg, bold, dim)]"""
    runs, pos = [], 0
    fg = bg = None
    bold = dim = False
    for m in SGR.finditer(line):
        if m.start() > pos:
            runs.append((line[pos:m.start()], fg, bg, bold, dim))
        parts = [p for p in m.group(1).split(";") if p != ""] or ["0"]
        i = 0
        while i < len(parts):
            c = int(parts[i])
            if c == 0:
                fg = bg = None
                bold = dim = False
            elif c == 1:
                bold = True
            elif c == 2:
                dim = True
            elif c == 22:
                bold = dim = False
            elif c == 39:
                fg = None
            elif c == 49:
                bg = None
            elif c in (38, 48) and i + 4 < len(parts) and parts[i + 1] == "2":
                col = "#%02x%02x%02x" % tuple(int(parts[i + j]) for j in (2, 3, 4))
                if c == 38:
                    fg = col
                else:
                    bg = col
                i += 4
            i += 1
        pos = m.end()
    if pos < len(line):
        runs.append((line[pos:], fg, bg, bold, dim))
    return runs


def main():
    lines = [l.rstrip("\n") for l in sys.stdin.read().split("\n")]
    while lines and not lines[-1].strip():
        lines.pop()

    parsed = [parse(l) for l in lines]
    cols = max((sum(len(t) for t, *_ in r) for r in parsed), default=0)
    w = PAD * 2 + cols * CW
    h = PAD * 2 + len(parsed) * LH

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
        f'viewBox="0 0 {w:.1f} {h:.1f}" font-family="{FONT}" font-size="{SIZE}">',
        f'<rect width="100%" height="100%" fill="{TERM_BG}" rx="6"/>',
    ]
    for row, runs in enumerate(parsed):
        y = PAD + row * LH
        col = 0
        for text, fg, bg, bold, dim in runs:
            n = len(text)
            if n == 0:
                continue
            x = PAD + col * CW
            if bg:
                # +0.5 overlap kills hairline seams between adjacent blocks
                out.append(
                    f'<rect x="{x:.2f}" y="{y:.2f}" width="{n * CW + 0.5:.2f}" '
                    f'height="{LH:.2f}" fill="{bg}"/>'
                )
            if text.strip():
                colour = fg or TERM_FG
                op = ' opacity="0.6"' if dim else ""
                wt = ' font-weight="bold"' if bold else ""
                out.append(
                    f'<text x="{x:.2f}" y="{y + LH * 0.72:.2f}" fill="{colour}"'
                    f'{wt}{op} xml:space="preserve">{escape(text)}</text>'
                )
            col += n
    out.append("</svg>")
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()

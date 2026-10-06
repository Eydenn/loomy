#!/usr/bin/env python3
"""Turns terminal captures (tmux capture-pane -e, one file per frame) into one animated SVG for the README.

    tools/ansi2svg.py out.svg frame1.ans frame2.ans … [--delay 0.27] [--title "loomy watch"]

Lines identical in every frame are drawn once; each frame only carries the lines that change, shown in turn by a
CSS animation (works in a GitHub README, no script). Colours: the 16 ANSI colours, the 256 palette, bold, dim.
"""
import re, sys, html

args = sys.argv[1:]
delay = 0.27; title = "loomy"
if '--delay' in args: i = args.index('--delay'); delay = float(args[i + 1]); del args[i:i + 2]
if '--title' in args: i = args.index('--title'); title = args[i + 1]; del args[i:i + 2]
out, files = args[0], args[1:]

BASE16 = ['#1d1f21', '#e5534b', '#57ab5a', '#c69026', '#539bf5', '#b083f0', '#39c5cf', '#c9d1d9',
          '#636e7b', '#ff938a', '#6bc46d', '#daaa3f', '#6cb6ff', '#dcbdfb', '#56d4dd', '#f0f6fc']
def c256(n):
    if n < 16: return BASE16[n]
    if n < 232:
        n -= 16; r, g, b = n // 36, (n // 6) % 6, n % 6
        lv = [0, 95, 135, 175, 215, 255]
        return '#%02x%02x%02x' % (lv[r], lv[g], lv[b])
    v = 8 + (n - 232) * 10
    return '#%02x%02x%02x' % (v, v, v)
FG = '#c9d1d9'; BG = '#0d1117'

def parse(line):
    """[(text, fg, bold, dim)] runs of a line with SGR codes."""
    runs = []; fg = None; bold = dim = False; pos = 0
    for m in re.finditer(r'\x1b\[([0-9;]*)m', line):
        if m.start() > pos: runs.append((line[pos:m.start()], fg, bold, dim))
        codes = [int(c) if c else 0 for c in m.group(1).split(';')] if m.group(1) else [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0: fg = None; bold = dim = False
            elif c == 1: bold = True
            elif c == 2: dim = True
            elif c == 22: bold = dim = False
            elif 30 <= c <= 37: fg = BASE16[c - 30]
            elif 90 <= c <= 97: fg = BASE16[c - 90 + 8]
            elif c == 39: fg = None
            elif c == 38 and i + 2 < len(codes) and codes[i + 1] == 5: fg = c256(codes[i + 2]); i += 2
            elif c == 38 and i + 4 < len(codes) and codes[i + 1] == 2: fg = '#%02x%02x%02x' % tuple(codes[i + 2:i + 5]); i += 4
            i += 1
        pos = m.end()
    if pos < len(line): runs.append((line[pos:], fg, bold, dim))
    return runs

frames = [open(f, encoding='utf-8').read().rstrip('\n').split('\n') for f in files]
rows = max(len(f) for f in frames)
for f in frames: f += [''] * (rows - len(f))
cols = max(len(re.sub(r'\x1b\[[0-9;]*m', '', l)) for f in frames for l in f)
CW, LH, FS, PAD, BAR = 8.4, 17.0, 14, 18, 34
W = int(cols * CW + 2 * PAD); H = int(rows * LH + 2 * PAD + BAR)

def split_box(runs):
    """Box-drawing characters always in normal weight (in bold, many fonts draw them shorter than the line)."""
    out = []
    for text, fg, bold, dim in runs:
        for chunk in re.findall(r'[\u2500-\u257f]+|[^\u2500-\u257f]+', text):
            out.append((chunk, fg, bold and not re.match(r'[\u2500-\u257f]', chunk), dim))
    return out

def line_svg(y, line):
    parts = []; col = 0
    for text, fg, bold, dim in split_box(parse(line)):
        if text.strip():
            # Each run takes exactly its columns, so box-drawing lines join whatever the font's advance width.
            attrs = ' x="%.1f" textLength="%.1f" lengthAdjust="spacingAndGlyphs"' % (PAD + col * CW, len(text) * CW)
            if fg and fg != FG: attrs += ' fill="%s"' % fg
            if bold: attrs += ' font-weight="bold"'
            if dim: attrs += ' opacity=".55"'
            parts.append('<tspan%s>%s</tspan>' % (attrs, html.escape(text)))
        col += len(text)
    if not parts: return ''
    return '<text y="%.1f">%s</text>' % (BAR + PAD + (y + 1) * LH - 4, ''.join(parts))

static, varying = [], []
for y in range(rows):
    if all(f[y] == frames[0][y] for f in frames): static.append(line_svg(y, frames[0][y]))
    else: varying.append(y)
n = len(frames); T = n * delay; p = 100.0 / n
svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, H, W, H, html.escape(title)),
       '<style>text{font-family:"SF Mono",Menlo,Consolas,"DejaVu Sans Mono",monospace;font-size:%dpx;fill:%s;white-space:pre}'
       '.f{opacity:0;animation:s %.2fs step-end infinite}@keyframes s{0%%{opacity:1}%.3f%%{opacity:0}100%%{opacity:0}}</style>' % (FS, FG, T, p),
       '<rect width="100%%" height="100%%" rx="10" fill="%s"/>' % BG,
       '<circle cx="20" cy="17" r="6" fill="#ff5f57"/><circle cx="40" cy="17" r="6" fill="#febc2e"/><circle cx="60" cy="17" r="6" fill="#28c840"/>',
       '<text x="%d" y="22" text-anchor="middle" fill="#8b949e" font-size="13">%s</text>' % (W // 2, html.escape(title)),
       '<g>' + ''.join(static) + '</g>']
for i, f in enumerate(frames):
    svg.append('<g class="f" style="animation-delay:%.2fs">%s</g>' % (i * delay, ''.join(line_svg(y, f[y]) for y in varying)))
svg.append('</svg>')
open(out, 'w', encoding='utf-8').write('\n'.join(svg))
print('%s: %d frames, %d static lines, %d changing, %d KB' % (out, n, len(static), len(varying), len('\n'.join(svg).encode()) // 1024))

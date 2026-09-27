#!/usr/bin/env python3
"""Aide à la migration : dans les fichiers donnés, entoure de $(t "…") les textes simples (sans variable) passés aux
fonctions d'affichage (ui_ok, ui_warn, ui_err, ui_info, ui_end, ui_section, ui_kv, ui_banner, ui_rail_head, ui_input,
ui_choose) et aux variables UI_LABEL / UI_HINT. Les phrases avec variables restent à convertir à la main (format %s)."""
import re, sys
FUNCS = r'(?:ui_ok|ui_warn|ui_err|ui_info|ui_end|ui_section|ui_kv|ui_banner|ui_rail_head|ui_input|ui_choose|ui_step_done)'
lit = r'"([^"$`\\]*[A-Za-zÀ-ÿ][^"$`\\]*)"'
def wrap_args(m):
    head, rest = m.group(1), m.group(2)
    rest = re.sub(r'(^|\s)' + lit, lambda a: a.group(1) + '"$(t "' + a.group(2) + '")"', rest)
    return head + rest
for f in sys.argv[1:]:
    out = []
    for line in open(f, encoding="utf-8").read().split("\n"):
        if line.lstrip().startswith("#"): out.append(line); continue
        line = re.sub(r'(\b' + FUNCS + r')((?:\s+(?:"[^"]*"|\S+))+)', lambda m: wrap_args(m), line)
        line = re.sub(r'\b(UI_LABEL|UI_HINT)=' + lit, lambda m: m.group(1) + '="$(t "' + m.group(2) + '")"', line)
        out.append(line)
    open(f, "w", encoding="utf-8").write("\n".join(out))
    print("ok", f)

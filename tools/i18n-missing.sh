#!/usr/bin/env bash
# Phrases passées à t "…" dans les scripts et absentes du dictionnaire anglais (scripts/lib/i18n/en.tsv).
# Sortie : une phrase par ligne (vide si tout est traduit). Code 1 s'il en manque.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, glob, sys
known = set()
for raw in open("scripts/lib/i18n/en.tsv", encoding="utf-8"):
    raw = raw.rstrip("\n")
    if raw and not raw.startswith("#") and "\t" in raw: known.add(raw.split("\t", 1)[0])
files = glob.glob("scripts/*.sh") + glob.glob("scripts/lib/*.sh") + ["bin/loomy"]
pat = re.compile(r'\bt "((?:[^"\\$]|\\.)*)"')
missing = []
for f in sorted(files):
    text = "\n".join(l for l in open(f, encoding="utf-8").read().split("\n") if not l.lstrip().startswith("#"))
    for m in pat.finditer(text):
        s = m.group(1).replace("\\\"", "\"").replace("\\$", "$").replace("\\\\", "\\")
        if s and s not in known and s not in missing: missing.append(s)
for s in missing: print(s)
sys.exit(1 if missing else 0)
PY

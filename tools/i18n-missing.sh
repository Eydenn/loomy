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
# Questions à choix du questionnaire : choose_coded VAR "question" "défaut" "aide" "code|libellé|description"…
qs = re.compile(r'"((?:[^"\\]|\\.)*)"')
for f in sorted(files):
    lines = open(f, encoding="utf-8").read().split("\n")
    k = 0
    while k < len(lines):
        if re.match(r'\s*choose_coded\s', lines[k]):
            stmt = lines[k]
            while stmt.rstrip().endswith("\\") and k + 1 < len(lines):
                k += 1; stmt = stmt.rstrip()[:-1] + " " + lines[k]
            args = [a.replace('\\"', '"') for a in qs.findall(stmt)]
            cands = []
            if len(args) > 0: cands.append(args[0])
            if len(args) > 2: cands.append(args[2])
            for o in args[3:]:
                parts = o.split("|")
                if len(parts) >= 2 and re.match(r'^[a-z0-9_-]+$', parts[0]):
                    cands += parts[1:3]
            for c in cands:
                if c and "$" not in c and re.search(r"[A-Za-zÀ-ÿ]{2,}", c) and c not in known and c not in missing: missing.append(c)
        k += 1
for s in missing: print(s)
sys.exit(1 if missing else 0)
PY

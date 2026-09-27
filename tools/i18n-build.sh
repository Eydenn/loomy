#!/usr/bin/env bash
# Compile scripts/lib/i18n/en.tsv (« français<TAB>anglais », une phrase par ligne) en scripts/lib/i18n/en.sh :
# une fonction _t_en faite d'un seul case, rapide même dans bash 3.2 (pas de tableaux associatifs).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import sys
src = "scripts/lib/i18n/en.tsv"; out = "scripts/lib/i18n/en.sh"
q = lambda s: "'" + s.replace("'", "'\\''") + "'"
seen = {}; lines = []
for n, raw in enumerate(open(src, encoding="utf-8"), 1):
    raw = raw.rstrip("\n")
    if not raw or raw.startswith("#"): continue
    if "\t" not in raw: sys.exit(f"{src}:{n}: tabulation manquante")
    fr, en = raw.split("\t", 1)
    if fr in seen: sys.exit(f"{src}:{n}: phrase en double (déjà ligne {seen[fr]})")
    seen[fr] = n; lines.append(f"    {q(fr)}) _T={q(en)} ;;")
open(out, "w", encoding="utf-8").write(
  "#!/usr/bin/env bash\n# Généré par tools/i18n-build.sh depuis en.tsv : ne pas modifier à la main.\n"
  "# shellcheck disable=SC2034\n_t_en() {\n  _T=\"\"\n  case \"$1\" in\n" + "\n".join(lines) + "\n  esac\n}\n")
print(f"{len(lines)} phrases → {out}")
PY

#!/usr/bin/env bash
# Indique quelles CLI IA sont disponibles. Code de sortie 1 si aucune n'est trouvée.
# Pour les versions, la disponibilité des modèles et les corrections, utilisez ai-doctor.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

found=0

if CODEX_BIN="$(ai_codex_bin)"; then
  echo "CODEX=disponible ($CODEX_BIN)"
  found=1
else
  echo "CODEX=absent"
fi

if command -v claude >/dev/null 2>&1; then
  echo "CLAUDE=disponible ($(command -v claude))"
  found=1
else
  echo "CLAUDE=absent"
fi

if [[ "$found" -eq 0 ]]; then
  exit 1
fi

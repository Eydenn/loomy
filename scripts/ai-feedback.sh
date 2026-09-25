#!/usr/bin/env bash
# Retour sur Loomy : prépare une issue GitHub avec le contexte utile, anonymisé. Compatible bash 3.2.
#   ai-feedback.sh ["message"]   décris le problème ou l'idée ; aperçu, puis envoi seulement après confirmation
#   ai-feedback.sh --print       affiche seulement le texte de l'issue (rien n'est envoyé)
#   ai-feedback.sh --root <dir>  projet dont joindre l'état (par défaut : le dossier courant, s'il est un projet Loomy)
# Joint : versions (Loomy, système, bash, git, Claude Code, Codex, gh), et pour un projet : type, stade, mode IA,
# profil, phase et derniers événements du journal SANS le texte des tâches. Jamais : nom, objectif, chemins, code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"

REPO="${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}"
ROOT=""; MSG=""; PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//; s/ai-feedback.sh/loomy feedback/'; exit 0 ;;
    *) MSG="${MSG:+$MSG }$1" ;;
  esac
  shift
done
[[ -z "$ROOT" ]] && ROOT="$(ai_project_root 2>/dev/null || pwd)"
IN_PROJECT=0; [[ -f "$ROOT/.loomy/brief.md" ]] && IN_PROJECT=1

ver() { "$@" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true; }
LOOMY_V="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "?")"

body() {
  echo "## Retour"
  echo
  echo "${MSG:-_(à compléter)_}"
  echo
  echo "## Contexte (joint par \`loomy feedback\`, anonymisé)"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Loomy | $LOOMY_V |"
  echo "| Système | $(uname -s) $(uname -r) $(uname -m) |"
  echo "| bash | ${BASH_VERSION%%(*} |"
  echo "| git | $(ver git --version) |"
  echo "| Claude Code | $(ver claude --version || true) |"
  echo "| Codex | $(ver "$(ai_codex_bin 2>/dev/null || echo codex)" --version || true) |"
  echo "| gh | $(ver gh --version) |"
  echo "| Terminal | ${TERM_PROGRAM:-?} · TERM=${TERM:-?}$( [[ -n "${TMUX:-}" ]] && echo " · tmux") |"
  if (( IN_PROJECT )); then
    local b="$ROOT/.loomy/brief.md" phase
    phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
    echo "| Projet | $(_ai_brief_get "$b" type) · $(_ai_brief_get "$b" stage) · $(_ai_brief_get "$b" ai_mode) · lead $(_ai_brief_get "$b" ai_lead) · profil $(_ai_brief_get "$b" budget) · fichiers IA $(_ai_brief_get "$b" ai_files) |"
    echo "| Loomy du projet | $(cat "$ROOT/.loomy/VERSION" 2>/dev/null || echo "?") · phase ${phase:-?} |"
    local j; j="$(ai_journal_file "$ROOT")"
    if [[ -s "$j" ]]; then
      echo
      echo "<details><summary>Derniers événements du journal (sans le texte des tâches)</summary>"
      echo
      echo '```'
      # ROOT pointe ici sur une copie du journal dont le texte des tâches a été vidé (voir plus bas).
      NO_COLOR=1 bash "$SCRIPT_DIR/ai-log.sh" --root "$ROOT" -n 15 2>/dev/null || true
      echo '```'
      echo
      echo "</details>"
    fi
  fi
}

# Journal : ai-log lit le fichier lui-même ; on lui passe une copie sans le texte des tâches.
if (( IN_PROJECT )) && [[ -s "$(ai_journal_file "$ROOT")" ]]; then
  SAFE="$(mktemp -d)"; mkdir -p "$SAFE/.loomy/logs"
  cp "$ROOT/.loomy/brief.md" "$SAFE/.loomy/brief.md"
  sed -E 's/"task":"([^"\\]|\\.)*"/"task":""/' "$(ai_journal_file "$ROOT")" >"$SAFE/.loomy/logs/events.jsonl"
  cp "$ROOT/.loomy/state" "$SAFE/.loomy/state" 2>/dev/null || true
  cp "$ROOT/.loomy/VERSION" "$SAFE/.loomy/VERSION" 2>/dev/null || true
  trap 'rm -rf "$SAFE"' EXIT
  ROOT="$SAFE"
fi

if (( PRINT )) || ! ui_is_interactive; then body; exit 0; fi

ui_clear
ui_banner "Retour sur Loomy" "issue GitHub sur $REPO · rien n'est envoyé sans ton accord"
if [[ -z "$MSG" ]]; then
  ui_print "${C_RAIL}│${C_RESET}"
  UI_LABEL="Retour"; UI_HINT="Un bug, une gêne, une idée : ce qui s'est passé, et ce que tu attendais."
  ui_input "Ton retour, en une ou deux phrases" "" "Ex. : loomy watch ne voit pas ma session Codex"
  MSG="$UI_VALUE"
  [[ -n "$MSG" ]] || { ui_end "rien à envoyer"; exit 0; }
fi
TITLE="Retour : $(printf '%s' "$MSG" | cut -c1-70)"
BODY_FILE="$(mktemp)"; body >"$BODY_FILE"
ui_section "APERÇU" "texte de l'issue"
while IFS= read -r l; do ui_rail "${C_DIM}${l}${C_RESET}"; done <"$BODY_FILE"
ui_print "${C_RAIL}│${C_RESET}"
opts=(); UI_DESCS=()
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  opts+=("Créer l'issue maintenant"); UI_DESCS+=("gh issue create sur $REPO, avec ce titre et ce texte.")
  opts+=("L'ouvrir dans le navigateur"); UI_DESCS+=("Formulaire GitHub pré-rempli : tu relis et tu envoies toi-même.")
fi
opts+=("Copier le texte"); UI_DESCS+=("Dans le presse-papiers, à coller où tu veux.")
opts+=("Annuler"); UI_DESCS+=("Rien n'est envoyé.")
UI_LABEL="Envoi"
ui_choose "Que faire de ce retour ?" 0 "${opts[@]}"
case "$UI_VALUE" in
  Créer*)
    if url="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" 2>&1)"; then ui_ok "Issue créée" "$url"
    else ui_warn "Issue non créée" "$(printf '%s' "$url" | tail -1)"; fi ;;
  L*ouvrir*) gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --web >/dev/null 2>&1 && ui_ok "Formulaire ouvert dans le navigateur" ;;
  Copier*) if ui_copy "$(cat "$BODY_FILE")"; then ui_ok "Texte copié" "titre : $TITLE"; else ui_warn "Presse-papiers indisponible" "loomy feedback --print"; fi ;;
  *) ui_end "rien n'a été envoyé"; rm -f "$BODY_FILE"; exit 0 ;;
esac
rm -f "$BODY_FILE"
ui_end "merci ! suivi des retours : https://github.com/$REPO/issues"

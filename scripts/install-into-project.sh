#!/usr/bin/env bash
# Crée ou initialise un projet Loomy, ou reprend un projet déjà initialisé. Compatible bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOMY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

usage() {
  cat <<'EOF'
Usage : loomy init [dossier] [options]

Sans dossier : propose le dossier courant, ou d'en créer un nouveau à partir du nom du projet.
Avec un dossier : le crée s'il n'existe pas.
Nouveau projet : copie START.md et .loomy/ dans le dossier, puis lance le questionnaire.
Projet déjà initialisé : propose de reprendre, mettre à jour, refaire le questionnaire ou réinitialiser.

Options :
  --update          Met à jour les fichiers Loomy du projet (scripts, modèles) ; garde brief, phase et journal
  --reset           Réinitialise le bootstrap : START.md recopié, phase remise à zéro, questionnaire relancé
  --no-wizard       Installer seulement, sans le questionnaire
  --yes             Remplir le brief sans questions, avec les valeurs par défaut
  --answers FICHIER Reprendre les réponses d'un brief.md existant
  -h, --help        Afficher cette aide
EOF
}

TARGET_INPUT=""; RUN_WIZARD=1; WIZARD_ARGS=(); ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wizard) RUN_WIZARD=0 ;;
    --update) ACTION="update" ;;
    --reset) ACTION="reset" ;;
    --yes|-y|--no-clipboard) WIZARD_ARGS+=("$1") ;;
    --answers) WIZARD_ARGS+=("$1" "${2:-}"); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Erreur : option inconnue $1" >&2; usage >&2; exit 2 ;;
    *) TARGET_INPUT="$1" ;;
  esac
  shift
done

# Dossier d'où la commande est lancée : le questionnaire rappellera d'y faire « cd » si le projet est ailleurs.
export LOOMY_INVOKED_FROM="$PWD"

is_home_or_root() { [[ "$(cd "$1" && pwd -P)" == "$(cd "$HOME" 2>/dev/null && pwd -P)" || "$(cd "$1" && pwd -P)" == "/" ]]; }
is_loomy_project() { [[ -d "$1/.loomy" && ( -f "$1/.loomy/VERSION" || -f "$1/.loomy/brief.md" ) ]]; }


# Dossier courant « de projet » : vide, dépôt Git, ou fichiers typiques d'un projet.
looks_like_project() {
  local d="$1" count
  [[ -e "$d/.git" ]] && return 0
  count="$(find "$d" -mindepth 1 -maxdepth 1 ! -name '.DS_Store' | wc -l | tr -d ' ')"
  [[ "$count" == "0" ]] && return 0
  local f
  for f in package.json pyproject.toml Cargo.toml go.mod composer.json Gemfile pom.xml build.gradle Makefile src README.md; do
    [[ -e "$d/$f" ]] && return 0
  done
  return 1
}

if [[ -z "$TARGET_INPUT" ]]; then
  CWD="$(pwd)"
  if is_loomy_project "$CWD" || { [[ -n "$ACTION" ]] && ! is_home_or_root "$CWD"; }; then
    TARGET_INPUT="$CWD"
  elif ui_is_interactive; then
    # Choix du dossier : ici, un nouveau dossier nommé d'après le projet, ou un autre emplacement.
    ui_clear
    ui_banner "Nouveau projet" "dossier courant : ${CWD/#$HOME/~}"
    ui_section "PROJET"
    here_ok=1; is_home_or_root "$CWD" && here_ok=0
    default_name="mon-projet"; if (( here_ok )) && looks_like_project "$CWD"; then default_name="$(basename "$CWD")"; fi
    UI_LABEL="Nom"; UI_HINT="Il sert de nom au projet et, si tu crées un dossier, de nom de dossier."
    ui_input "Nom du projet" "$default_name"
    PROJECT_NAME="$UI_VALUE"; slug="$(loomy_slug "$PROJECT_NAME")"
    opts=("Nouveau dossier ./$slug"); descs=("Crée ${CWD/#$HOME/~}/$slug et y installe Loomy.")
    if (( here_ok )); then
      opts+=("Dossier courant (${CWD/#$HOME/~})"); descs+=("Installe Loomy ici : pour un dossier vide ou un projet existant à standardiser.")
    fi
    opts+=("Autre emplacement…"); descs+=("Tu indiques le chemin du dossier ; il est créé s'il n'existe pas.")
    default=0; if (( here_ok )) && looks_like_project "$CWD"; then default=1; fi
    UI_DESCS=("${descs[@]}"); UI_LABEL="Dossier"
    ui_choose "Où créer le projet ?" "$default" "${opts[@]}"
    case "$UI_VALUE" in
      Nouveau*) TARGET_INPUT="$CWD/$slug" ;;
      Dossier*) TARGET_INPUT="$CWD" ;;
      *) UI_LABEL="Chemin"; ui_input "Chemin du dossier du projet" "${CWD/#$HOME/~}/$slug"; TARGET_INPUT="${UI_VALUE/#\~/$HOME}" ;;
    esac
    export LOOMY_PROJECT_NAME="$PROJECT_NAME"
    ui_end "installation de Loomy dans ${TARGET_INPUT/#$HOME/~}…"
  elif is_home_or_root "$CWD"; then
    echo "Erreur : ${CWD/#$HOME/~} n'est pas un dossier de projet. Indique le dossier à créer : loomy init mon-projet" >&2
    exit 1
  else
    TARGET_INPUT="$CWD"
  fi
fi

if [[ ! -d "$TARGET_INPUT" ]]; then
  if [[ "$ACTION" == "update" ]]; then echo "Erreur : le dossier n'existe pas : $TARGET_INPUT" >&2; exit 1; fi
  mkdir -p "$TARGET_INPUT" || { echo "Erreur : impossible de créer le dossier $TARGET_INPUT" >&2; exit 1; }
fi
TARGET="$(cd "$TARGET_INPUT" && pwd)"
if is_home_or_root "$TARGET"; then
  echo "Erreur : ${TARGET/#$HOME/~} n'est pas un dossier de projet. Indique le dossier à créer : loomy init mon-projet" >&2
  exit 1
fi
L="$TARGET/.loomy"
NEW_V="$(cat "$LOOMY_ROOT/VERSION")"

# Copie des fichiers gérés par Loomy. Brief, phase (state) et journal (logs) ne sont jamais touchés.
copy_loomy_files() {
  local d
  mkdir -p "$L"
  for d in templates agents skills scripts external-skills; do
    rm -rf "${L:?}/$d"
    cp -R "$LOOMY_ROOT/$d" "$L/"
  done
  cp "$LOOMY_ROOT/VERSION" "$L/VERSION"
  install_claude_hooks
  install_codex_hooks
  # Le journal d'activité contient le texte des tâches déléguées : il reste local.
  if ! grep -qxF '.loomy/logs/' "$TARGET/.gitignore" 2>/dev/null; then
    printf '\n# Loomy : journal d\x27activité local\n.loomy/logs/\n' >>"$TARGET/.gitignore"
  fi
}

# Hooks Claude Code du projet : à chaque ouverture de session, le contexte Loomy (phase, attentes, délégations) est
# ajouté d'office ; à la fermeture, la session est notée. Fusion avec un .claude/settings.json existant, sans rien écraser.
LOOMY_HOOK_START='bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook start'
LOOMY_HOOK_END='bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook end'

# _hooks_json : bloc « hooks » de Loomy, en JSON.
_hooks_json() {
  local s e
  s="$(printf '%s' "$LOOMY_HOOK_START" | sed 's/"/\\"/g')"; e="$(printf '%s' "$LOOMY_HOOK_END" | sed 's/"/\\"/g')"
  printf '{\n  "hooks": {\n    "SessionStart": [\n      { "hooks": [ { "type": "command", "command": "%s", "timeout": 20 } ] }\n    ],\n    "SessionEnd": [\n      { "hooks": [ { "type": "command", "command": "%s", "timeout": 3 } ] }\n    ]\n  }\n}\n' "$s" "$e"
}

# Codex lance ses hooks depuis le dossier de la session : la commande remonte jusqu'au projet Loomy.
codex_hook_cmd() {
  printf '%s' "sh -c 'd=\$PWD; while [ \"\$d\" != / ] && [ ! -f \"\$d/.loomy/scripts/ai-context.sh\" ]; do d=\$(dirname \"\$d\"); done; [ -f \"\$d/.loomy/scripts/ai-context.sh\" ] && exec bash \"\$d/.loomy/scripts/ai-context.sh\" --hook $1 --tool codex'"
}

# install_codex_hooks : .codex/hooks.json du projet (même format que Claude Code). Codex demande de les approuver au premier lancement.
install_codex_hooks() {
  local f="$TARGET/.codex/hooks.json" start end merger
  start="$(codex_hook_cmd start)"; end="$(codex_hook_cmd end)"
  mkdir -p "$TARGET/.codex"
  if [[ -f "$f" ]] && grep -q 'ai-context.sh' "$f"; then return 0; fi
  merger='import json, os, sys
path, start, end = sys.argv[1:4]
data = json.load(open(path)) if os.path.exists(path) else {}
hooks = data.setdefault("hooks", {})
hooks.setdefault("SessionStart", []).append({"hooks": [{"type": "command", "command": start, "timeout": 20}]})
hooks.setdefault("SessionEnd", []).append({"hooks": [{"type": "command", "command": end, "timeout": 3}]})
out = open(path, "w"); json.dump(data, out, indent=2, ensure_ascii=False); out.write("\n")'
  if command -v python3 >/dev/null 2>&1 && python3 -c "$merger" "$f" "$start" "$end" 2>/dev/null; then return 0; fi
  if [[ ! -f "$f" ]]; then
    local s e
    s="$(printf '%s' "$start" | sed 's/\\/\\\\/g; s/"/\\"/g')"; e="$(printf '%s' "$end" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{\n  "hooks": {\n    "SessionStart": [ { "hooks": [ { "type": "command", "command": "%s", "timeout": 20 } ] } ],\n    "SessionEnd": [ { "hooks": [ { "type": "command", "command": "%s", "timeout": 3 } ] } ]\n  }\n}\n' "$s" "$e" >"$f"
    return 0
  fi
  ui_warn ".codex/hooks.json existant non modifié" "ajoute-y les hooks Loomy à la main (voir .loomy/scripts/ai-context.sh)"
  return 0
}

install_claude_hooks() {
  local f="$TARGET/.claude/settings.json" merger
  mkdir -p "$TARGET/.claude"
  if [[ -f "$f" ]] && grep -q 'ai-context.sh' "$f"; then return 0; fi
  if [[ ! -f "$f" ]]; then _hooks_json >"$f"; return 0; fi
  merger='import json, sys
path, start, end = sys.argv[1:4]
data = json.load(open(path))
hooks = data.setdefault("hooks", {})
hooks.setdefault("SessionStart", []).append({"hooks": [{"type": "command", "command": start, "timeout": 20}]})
hooks.setdefault("SessionEnd", []).append({"hooks": [{"type": "command", "command": end, "timeout": 3}]})
out = open(path, "w"); json.dump(data, out, indent=2, ensure_ascii=False); out.write("\n")'
  if command -v python3 >/dev/null 2>&1 && python3 -c "$merger" "$f" "$LOOMY_HOOK_START" "$LOOMY_HOOK_END" 2>/dev/null; then return 0; fi
  _hooks_json >"$L/claude-hooks.json"
  ui_warn ".claude/settings.json existant non modifié" "ajoute-y les hooks de .loomy/claude-hooks.json"
  return 0
}

run_wizard() {
  local wants_yes=0 a
  for a in ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}; do [[ "$a" == "--yes" || "$a" == "-y" ]] && wants_yes=1; done
  if [[ -t 0 && -t 2 ]] || (( wants_yes )); then
    exec "$L/scripts/init-wizard.sh" "$TARGET" "$@" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}
  fi
  return 0
}

# ---------------------------------------------------------------- projet déjà initialisé
if [[ -e "$TARGET/START.md" && ! -d "$L" ]]; then
  echo "Erreur : $TARGET/START.md existe mais ne vient pas de Loomy (pas de dossier .loomy). Écrasement refusé." >&2
  exit 1
fi

if [[ -d "$L" && ( -f "$L/VERSION" || -f "$L/brief.md" ) ]]; then
  OLD_V="$(cat "$L/VERSION" 2>/dev/null || echo "?")"
  PHASE="$(sed -n 's/^phase=//p' "$L/state" 2>/dev/null | head -1 || true)"
  IN_PROGRESS=0; [[ -f "$TARGET/START.md" ]] && IN_PROGRESS=1
  if (( ! IN_PROGRESS )); then PHASE="done"; fi

  do_update() {
    copy_loomy_files
    if (( IN_PROGRESS )); then cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"; fi
    ui_ok "Loomy mis à jour dans le projet" "v$OLD_V → v$NEW_V · brief, phase et journal conservés"
  }
  do_reset() {
    copy_loomy_files
    cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"
    rm -f "$L/state"
    if [[ -f "$L/brief.md" ]]; then mv "$L/brief.md" "$L/brief.previous.md"; fi
    ui_ok "Bootstrap réinitialisé" "START.md recopié, phase remise à zéro ; ancien brief : .loomy/brief.previous.md"
    ui_warn "Fichiers déjà créés par l'agent conservés" "AGENTS.md, CLAUDE.md, PROJECT.md… l'orchestrateur les reprendra"
  }

  ui_clear
  ui_banner "Projet déjà initialisé" "${TARGET/#$HOME/~}"
  ui_section "ÉTAT"
  ui_kv "Loomy" "v$OLD_V dans le projet · v$NEW_V installé"
  ui_kv "Bootstrap" "$( (( IN_PROGRESS )) && echo "en cours · phase $(loomy_phase_label "$PHASE")" || echo "terminé")"
  if [[ "$OLD_V" != "$NEW_V" ]]; then ui_warn "Version du projet différente" "la mise à jour garde ton brief, ta phase et ton journal"; fi

  if [[ -z "$ACTION" ]]; then
    if ! ui_is_interactive; then
      ui_section "QUE FAIRE ?"
      ui_rail "${C_BOLD}loomy start${C_RESET}           ${C_DIM}reprendre la session de l'orchestrateur${C_RESET}"
      ui_rail "${C_BOLD}loomy init --update${C_RESET}   ${C_DIM}mettre à jour les fichiers Loomy du projet${C_RESET}"
      ui_rail "${C_BOLD}loomy brief${C_RESET}           ${C_DIM}refaire le questionnaire${C_RESET}"
      ui_rail "${C_BOLD}loomy init --reset${C_RESET}    ${C_DIM}réinitialiser le bootstrap${C_RESET}"
      ui_end "rien n'a été modifié"
      exit 1
    fi
    ui_print "${C_RAIL}│${C_RESET}"
    opts=("Reprendre la session de l'orchestrateur"); descs=("Ouvre loomy start : reprend la dernière session de ce dossier, ou en ouvre une nouvelle au bon endroit du projet.")
    if [[ "$OLD_V" != "$NEW_V" ]]; then
      opts+=("Mettre à jour Loomy dans ce projet (v$OLD_V → v$NEW_V)"); descs+=("Recopie scripts et modèles de la version installée. Brief, phase et journal conservés. Recommandé.")
    else
      opts+=("Réinstaller les fichiers Loomy du projet"); descs+=("Recopie scripts et modèles (même version), par exemple s'ils ont été modifiés. Brief, phase et journal conservés.")
    fi
    if (( IN_PROGRESS )); then opts+=("Refaire le questionnaire"); descs+=("Tes réponses actuelles servent de valeurs par défaut ; le brief n'est remplacé qu'après confirmation."); fi
    opts+=("Réinitialiser le projet"); descs+=("Repart du début du bootstrap : START.md recopié, phase remise à zéro, questionnaire relancé. Les fichiers déjà créés par l'agent restent.")
    opts+=("Annuler"); descs+=("Ne modifie rien.")
    UI_DESCS=("${descs[@]}"); UI_LABEL="Choix"
    default=0; [[ "$OLD_V" != "$NEW_V" ]] && default=1
    ui_choose "Que veux-tu faire ?" "$default" "${opts[@]}"
    case "$UI_VALUE" in
      Reprendre*) ui_end "ouverture de loomy start…"; exec bash "$SCRIPT_DIR/ai-start.sh" --root "$TARGET" ;;
      Mettre*|Réinstaller*) ACTION="update" ;;
      Refaire*) ACTION="brief" ;;
      Réinitialiser*)
        UI_DESCS=("Repart de la phase Brief. Rien n'est supprimé en dehors de .loomy/state." "Ne modifie rien.")
        UI_LABEL="Confirmation"
        ui_choose "Réinitialiser le bootstrap de ce projet ?" 1 "Oui, réinitialiser" "Non"
        if [[ "$UI_VALUE" == Oui* ]]; then ACTION="reset"; else ui_end "rien n'a été modifié"; exit 0; fi ;;
      *) ui_end "rien n'a été modifié"; exit 0 ;;
    esac
  fi

  case "$ACTION" in
    update)
      do_update
      ui_end "reprendre : loomy start · suivi : loomy watch"
      exit 0 ;;
    brief)
      ui_end "questionnaire…"
      exec "$L/scripts/init-wizard.sh" "$TARGET" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"} ;;
    reset)
      do_reset
      if (( RUN_WIZARD )); then
        answers=(); [[ -f "$L/brief.previous.md" ]] && answers=(--answers "$L/brief.previous.md")
        ui_end "questionnaire (tes anciennes réponses servent de valeurs par défaut)…"
        run_wizard ${answers[@]+"${answers[@]}"}
      fi
      ui_end "remplis le brief : loomy brief · puis : loomy start"
      exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- nouveau projet
if [[ "$ACTION" == "update" ]]; then
  echo "Erreur : pas de projet Loomy dans $TARGET à mettre à jour. Lancez loomy init pour le créer." >&2
  exit 1
fi
copy_loomy_files
cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"

if (( RUN_WIZARD )); then run_wizard; fi

brief_cmd=".loomy/scripts/init-wizard.sh"; command -v loomy >/dev/null 2>&1 && brief_cmd="loomy brief"
ui_banner "Loomy installé" "v$NEW_V · ${TARGET/#$HOME/~}"
if (( RUN_WIZARD )); then ui_warn "Terminal non interactif" "questionnaire ignoré"; fi
ui_section "ÉTAPE SUIVANTE"
ui_rail "${C_BRAND}1${C_RESET}  Remplis le brief du projet : ${C_BOLD}${brief_cmd}${C_RESET}"
ui_rail "${C_BRAND}2${C_RESET}  Lance l'orchestrateur : ${C_BOLD}loomy start${C_RESET}"
ui_end "START.md, .loomy/ et une ligne de .gitignore ajoutés ; rien d'autre n'est modifié"

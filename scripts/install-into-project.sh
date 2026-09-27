#!/usr/bin/env bash
# Creates or sets up a Loomy project, or resumes a project already set up. Bash 3.2 compatible.
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
  i18n_lines <<'EOF'
Usage: loomy init [folder] [options]

Without a folder: offers the current folder, or to create a new one from the project name.
With a folder: creates it if it doesn't exist.
New project: copies START.md and .loomy/ into the folder, then runs the questionnaire.
Project already set up: offers to resume, update, redo the questionnaire or reset.

Options:
  --update          Updates the project's Loomy files (scripts, templates); keeps brief, phase and log
  --reset           Resets the bootstrap: START.md copied again, phase reset, questionnaire run again
  --no-wizard       Install only, without the questionnaire
  --yes             Fill in the brief without questions, with default values
  --answers FILE    Reuse the answers of an existing brief.md
  --no-branch       Existing Git project: stay on the current branch instead of loomy/adopt
  -h, --help        Show this help
EOF
}

TARGET_INPUT=""; RUN_WIZARD=1; WIZARD_ARGS=(); ACTION=""; ADOPT_BRANCH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wizard) RUN_WIZARD=0 ;;
    --no-branch) ADOPT_BRANCH=0 ;;
    --update) ACTION="update" ;;
    --reset) ACTION="reset" ;;
    --yes|-y|--no-clipboard) WIZARD_ARGS+=("$1") ;;
    --answers) WIZARD_ARGS+=("$1" "${2:-}"); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) t "Error: unknown option %s" "$1" >&2; echo >&2; usage >&2; exit 2 ;;
    *) TARGET_INPUT="$1" ;;
  esac
  shift
done

# Folder the command is run from: the questionnaire will remind the user to "cd" if the project is elsewhere.
export LOOMY_INVOKED_FROM="$PWD"

is_home_or_root() { [[ "$(cd "$1" && pwd -P)" == "$(cd "$HOME" 2>/dev/null && pwd -P)" || "$(cd "$1" && pwd -P)" == "/" ]]; }
is_loomy_project() { [[ -d "$1/.loomy" && ( -f "$1/.loomy/VERSION" || -f "$1/.loomy/brief.md" ) ]]; }


# Current folder looks like a project: empty, Git repository, or typical project files.
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

INIT_NO_TARGET=0; [[ -z "$TARGET_INPUT" ]] && INIT_NO_TARGET=1
if [[ -z "$TARGET_INPUT" ]]; then
  CWD="$(pwd)"
  if is_loomy_project "$CWD" || { [[ -n "$ACTION" ]] && ! is_home_or_root "$CWD"; }; then
    TARGET_INPUT="$CWD"
  elif ui_is_interactive; then
    # Folder choice: here, a new folder named after the project, or another location.
    ui_clear
    ui_banner "$(t "New project")" "$(t "current folder: %s" "${CWD/#$HOME/~}")"
    ui_section "$(t "PROJECT")"
    here_ok=1; is_home_or_root "$CWD" && here_ok=0
    default_name="my-project"; if (( here_ok )) && looks_like_project "$CWD"; then default_name="$(basename "$CWD")"; fi
    UI_LABEL="$(t "Name")"; UI_HINT="$(t "It names the project and, if you create a folder, the folder too.")"
    ui_input "$(t "Project name")" "$default_name"
    PROJECT_NAME="$UI_VALUE"; slug="$(loomy_slug "$PROJECT_NAME")"
    opts=("$(t "New folder ./%s" "$slug")"); codes=(new); descs=("$(t "Creates %s and installs Loomy there." "${CWD/#$HOME/~}/$slug")")
    if (( here_ok )); then
      opts+=("$(t "Current folder (%s)" "${CWD/#$HOME/~}")"); codes+=(here); descs+=("$(t "Installs Loomy here: for an empty folder or an existing project to standardize.")")
    fi
    opts+=("$(t "Somewhere else…")"); codes+=(other); descs+=("$(t "You give the folder path; it's created if it doesn't exist.")")
    default=0; if (( here_ok )) && looks_like_project "$CWD"; then default=1; fi
    UI_DESCS=("${descs[@]}"); UI_LABEL="$(t "Folder")"
    ui_choose "$(t "Where to create the project?")" "$default" "${opts[@]}"
    case "${codes[$UI_INDEX]}" in
      new) TARGET_INPUT="$CWD/$slug" ;;
      here) TARGET_INPUT="$CWD" ;;
      *) UI_LABEL="$(t "Path")"; ui_input "$(t "Project folder path")" "${CWD/#$HOME/~}/$slug"; TARGET_INPUT="${UI_VALUE/#\~/$HOME}" ;;
    esac
    export LOOMY_PROJECT_NAME="$PROJECT_NAME"
    ui_end "$(t "installing Loomy in %s…" "${TARGET_INPUT/#$HOME/~}")"
  elif is_home_or_root "$CWD"; then
    t "Error: %s isn't a project folder. Give the folder to create: loomy init my-project" "${CWD/#$HOME/~}" >&2; echo >&2
    exit 1
  else
    TARGET_INPUT="$CWD"
  fi
fi

if [[ ! -d "$TARGET_INPUT" ]]; then
  if [[ "$ACTION" == "update" ]]; then t "Error: the folder doesn't exist: %s" "$TARGET_INPUT" >&2; echo >&2; exit 1; fi
  mkdir -p "$TARGET_INPUT" || { t "Error: can't create the folder %s" "$TARGET_INPUT" >&2; echo >&2; exit 1; }
fi
TARGET="$(cd "$TARGET_INPUT" && pwd)"
if is_home_or_root "$TARGET"; then
  t "Error: %s isn't a project folder. Give the folder to create: loomy init my-project" "${TARGET/#$HOME/~}" >&2; echo >&2
  exit 1
fi
L="$TARGET/.loomy"
# Agent-facing documents (START.md, templates, agents, skills) in the interface language: French copies live in fr/.
DOCS_ROOT="$LOOMY_ROOT"; [[ "$(ui_lang)" == "fr" && -d "$LOOMY_ROOT/fr" ]] && DOCS_ROOT="$LOOMY_ROOT/fr"
NEW_V="$(cat "$LOOMY_ROOT/VERSION")"

# Copy of the files managed by Loomy. Brief, phase (state) and log (logs) are never touched.
copy_loomy_files() {
  local d f
  mkdir -p "$L"
  # Document templates: copied, the agents read them in the project.
  for d in templates agents skills external-skills; do
    rm -rf "${L:?}/$d"
    cp -R "$DOCS_ROOT/$d" "$L/"
  done
  # Scripts: no more copies, relays to the Loomy installed on the machine (same names, same arguments).
  # A Loomy update therefore applies to every project, without loomy init --update.
  rm -rf "${L:?}/scripts"; mkdir -p "$L/scripts"
  cat >"$L/scripts/_loomy.sh" <<'RELAIS'
# Generated by Loomy: finds the Loomy installed on this machine, then runs the requested script for this project.
# Order: $LOOMY_HOME, the loomy command in the PATH, then the usual install locations.
_loomy_run() {
  local name="$1" here home="" c; shift
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -n "${LOOMY_HOME:-}" ] && [ -f "$LOOMY_HOME/scripts/$name" ]; then home="$LOOMY_HOME"; fi
  if [ -z "$home" ]; then
    # LOOMY_RELAY_PATHS replaces the list of usual locations (empty: none).
    for c in "$(command -v loomy 2>/dev/null)" ${LOOMY_RELAY_PATHS-/opt/homebrew/bin/loomy /usr/local/bin/loomy "$HOME/.local/bin/loomy" "$HOME/.bun/bin/loomy" "$HOME/.npm-global/bin/loomy"}; do
      [ -n "$c" ] && [ -x "$c" ] || continue
      home="$("$c" __home 2>/dev/null)" && [ -f "$home/scripts/$name" ] && break
      home=""
    done
  fi
  if [ -z "$home" ]; then
    echo "Loomy is not installed on this machine (or too old): install it, see the Loomy project README." >&2
    echo "Loomy n'est pas installé sur cette machine (ou trop ancien) : installe-le, voir le README du projet Loomy." >&2
    return 127
  fi
  LOOMY_PROJECT_ROOT="$(dirname "$(dirname "$here")")" LOOMY_HOME="$home" exec bash "$home/scripts/$name" "$@"
}
RELAIS
  for f in "$LOOMY_ROOT"/scripts/*.sh; do
    printf '#!/usr/bin/env bash\n# Loomy relay: runs %s from the installed Loomy (see _loomy.sh).\n. "$(dirname "$0")/_loomy.sh" && _loomy_run %s "$@"\n' \
      "$(basename "$f")" "$(basename "$f")" >"$L/scripts/$(basename "$f")"
    chmod +x "$L/scripts/$(basename "$f")"
  done
  cp "$LOOMY_ROOT/VERSION" "$L/VERSION"
  install_claude_hooks
  install_codex_hooks
  # The activity log contains the text of delegated tasks: it stays local.
  if ! grep -qxF '.loomy/logs/' "$TARGET/.gitignore" 2>/dev/null; then
    printf '\n# Loomy: local activity log\n.loomy/logs/\n' >>"$TARGET/.gitignore"
  fi
}

# Project Claude Code hooks: at each session opening, the Loomy context (phase, expectations, delegations) is
# added automatically; on closing, the session is recorded. Merged with an existing .claude/settings.json, overwriting nothing.
LOOMY_HOOK_START='bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook start'
LOOMY_HOOK_END='bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook end'
# End of a lead agent turn and end of a subagent: real cost read from the session transcript.
LOOMY_HOOK_STOP='bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook stop'
LOOMY_HOOK_SUB='bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook subagent'

# _hooks_json: Loomy's "hooks" block, as JSON.
_hooks_json() {
  local s e t u
  s="$(printf '%s' "$LOOMY_HOOK_START" | sed 's/"/\\"/g')"; e="$(printf '%s' "$LOOMY_HOOK_END" | sed 's/"/\\"/g')"
  t="$(printf '%s' "$LOOMY_HOOK_STOP" | sed 's/"/\\"/g')"; u="$(printf '%s' "$LOOMY_HOOK_SUB" | sed 's/"/\\"/g')"
  printf '{\n  "hooks": {\n    "SessionStart": [\n      { "hooks": [ { "type": "command", "command": "%s", "timeout": 20 } ] }\n    ],\n    "SessionEnd": [\n      { "hooks": [ { "type": "command", "command": "%s", "timeout": 3 } ] }\n    ],\n    "Stop": [\n      { "hooks": [ { "type": "command", "command": "%s", "timeout": 10 } ] }\n    ],\n    "SubagentStop": [\n      { "hooks": [ { "type": "command", "command": "%s", "timeout": 10 } ] }\n    ]\n  }\n}\n' "$s" "$e" "$t" "$u"
}

# Codex runs its hooks from the session folder: the command walks up to the Loomy project.
codex_hook_cmd() {
  printf '%s' "sh -c 'd=\$PWD; while [ \"\$d\" != / ] && [ ! -f \"\$d/.loomy/scripts/ai-context.sh\" ]; do d=\$(dirname \"\$d\"); done; [ -f \"\$d/.loomy/scripts/ai-context.sh\" ] && exec bash \"\$d/.loomy/scripts/ai-context.sh\" --hook $1 --tool codex'"
}

# install_codex_hooks: the project's .codex/hooks.json (same format as Claude Code). Codex asks to approve them on first launch.
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
  ui_warn "$(t "existing .codex/hooks.json left unchanged")" "$(t "add the Loomy hooks to it by hand (see .loomy/scripts/ai-context.sh)")"
  return 0
}

install_claude_hooks() {
  local f="$TARGET/.claude/settings.json" merger
  mkdir -p "$TARGET/.claude"
  if [[ -f "$f" ]] && grep -q 'ai-context.sh" --hook subagent' "$f"; then return 0; fi
  if [[ ! -f "$f" ]]; then _hooks_json >"$f"; return 0; fi
  # Merge: each missing Loomy hook is added (pre-0.3 projects: Stop and SubagentStop), nothing is removed.
  merger='import json, sys
path, start, end, stop, sub = sys.argv[1:6]
data = json.load(open(path))
hooks = data.setdefault("hooks", {})
for event, cmd, t in (("SessionStart", start, 20), ("SessionEnd", end, 3), ("Stop", stop, 10), ("SubagentStop", sub, 10)):
    groups = hooks.setdefault(event, [])
    if not any(h.get("command") == cmd for g in groups for h in g.get("hooks", [])):
        groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": t}]})
out = open(path, "w"); json.dump(data, out, indent=2, ensure_ascii=False); out.write("\n")'
  if command -v python3 >/dev/null 2>&1 && python3 -c "$merger" "$f" "$LOOMY_HOOK_START" "$LOOMY_HOOK_END" "$LOOMY_HOOK_STOP" "$LOOMY_HOOK_SUB" 2>/dev/null; then return 0; fi
  _hooks_json >"$L/claude-hooks.json"
  ui_warn "$(t "existing .claude/settings.json left unchanged")" "$(t "add the hooks from .loomy/claude-hooks.json to it")"
  return 0
}

run_wizard() {
  local wants_yes=0 a
  for a in ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}; do [[ "$a" == "--yes" || "$a" == "-y" ]] && wants_yes=1; done
  if [[ -t 0 && -t 2 ]] || (( wants_yes )); then
    ui_exec "$LOOMY_ROOT/scripts/init-wizard.sh" "$TARGET" "$@" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}
  fi
  return 0
}

# ---------------------------------------------------------------- project already set up
if [[ -e "$TARGET/START.md" && ! -d "$L" ]]; then
  t "Error: %s exists but doesn't come from Loomy (no .loomy folder). Refusing to overwrite." "$TARGET/START.md" >&2; echo >&2
  exit 1
fi

if [[ -d "$L" && ( -f "$L/VERSION" || -f "$L/brief.md" ) ]]; then
  OLD_V="$(cat "$L/VERSION" 2>/dev/null || echo "?")"
  PHASE="$(sed -n 's/^phase=//p' "$L/state" 2>/dev/null | head -1 || true)"
  IN_PROGRESS=0; [[ -f "$TARGET/START.md" ]] && IN_PROGRESS=1
  if (( ! IN_PROGRESS )); then PHASE="done"; fi

  do_update() {
    copy_loomy_files
    if (( IN_PROGRESS )); then cp "$DOCS_ROOT/START.md" "$TARGET/START.md"; fi
    ui_ok "$(t "Loomy updated in the project")" "v$OLD_V → v$NEW_V · $(t "brief, phase and log kept")"
  }
  do_reset() {
    copy_loomy_files
    cp "$DOCS_ROOT/START.md" "$TARGET/START.md"
    rm -f "$L/state"
    if [[ -f "$L/brief.md" ]]; then mv "$L/brief.md" "$L/brief.previous.md"; fi
    ui_ok "$(t "Bootstrap reset")" "$(t "START.md copied again, phase reset; previous brief: .loomy/brief.previous.md")"
    ui_warn "$(t "Files already created by the agent kept")" "$(t "AGENTS.md, CLAUDE.md, PROJECT.md… the lead agent will pick them up")"
  }

  ui_clear
  ui_banner "$(t "Project already set up")" "${TARGET/#$HOME/~}"
  ui_section "$(t "STATE")"
  ui_kv "Loomy" "$(t "v%s in the project · v%s installed" "$OLD_V" "$NEW_V")"
  ui_kv "Bootstrap" "$( (( IN_PROGRESS )) && t "in progress · phase %s" "$(loomy_phase_label "$PHASE")" || t "done")"
  if [[ "$OLD_V" != "$NEW_V" ]]; then ui_warn "$(t "Different project version")" "$(t "the update keeps your brief, phase and log")"; fi

  if [[ -z "$ACTION" ]]; then
    if ! ui_is_interactive; then
      ui_section "$(t "WHAT NOW?")"
      ui_rail "${C_BOLD}loomy start${C_RESET}           ${C_DIM}$(t "resume the lead agent session")${C_RESET}"
      ui_rail "${C_BOLD}loomy init --update${C_RESET}   ${C_DIM}$(t "update the project's Loomy files")${C_RESET}"
      ui_rail "${C_BOLD}loomy brief${C_RESET}           ${C_DIM}$(t "redo the questionnaire")${C_RESET}"
      ui_rail "${C_BOLD}loomy init --reset${C_RESET}    ${C_DIM}$(t "reset the bootstrap")${C_RESET}"
      ui_end "$(t "nothing was changed")"
      exit 1
    fi
    ui_print "${C_RAIL}│${C_RESET}"
    opts=("$(t "Resume the lead agent session")"); codes=(resume); descs=("$(t "Opens loomy start: resumes this folder's last session, or opens a new one at the right point of the project.")")
    if [[ "$OLD_V" != "$NEW_V" ]]; then
      opts+=("$(t "Update Loomy in this project (v%s → v%s)" "$OLD_V" "$NEW_V")"); codes+=(update); descs+=("$(t "Updates the document templates and the relays to Loomy. Brief, phase and log kept. Recommended.")")
    else
      opts+=("$(t "Reinstall the project's Loomy files")"); codes+=(update); descs+=("$(t "Copies scripts and templates again (same version), for instance if they were changed. Brief, phase and log kept.")")
    fi
    if (( IN_PROGRESS )); then opts+=("$(t "Redo the questionnaire")"); codes+=(brief); descs+=("$(t "Your current answers are the defaults; the brief is only replaced after confirmation.")"); fi
    opts+=("$(t "Reset the project")"); codes+=(reset); descs+=("$(t "Starts the bootstrap over: START.md copied again, phase reset, questionnaire run again. Files already created by the agent stay.")")
    if [[ "$INIT_NO_TARGET" == "1" ]]; then
      opts+=("$(t "Create a new project in a subfolder")"); codes+=(sub); descs+=("$(t "This folder is itself a Loomy project: creates a new project next to it, in ./<project-name>.")")
    fi
    opts+=("$(t "Cancel")"); codes+=(cancel); descs+=("$(t "Changes nothing.")")
    UI_DESCS=("${descs[@]}"); UI_LABEL="$(t "Choice")"
    default=0; [[ "$OLD_V" != "$NEW_V" ]] && default=1
    ui_choose "$(t "What do you want to do?")" "$default" "${opts[@]}"
    case "${codes[$UI_INDEX]}" in
      resume) ui_end "$(t "opening loomy start…")"; ui_exec bash "$SCRIPT_DIR/ai-start.sh" --root "$TARGET" ;;
      update) ACTION="update" ;;
      brief) ACTION="brief" ;;
      sub)
        UI_LABEL="$(t "Name")"; UI_HINT="$(t "It also names the folder created here.")"
        ui_input "$(t "New project name")" "$(t "my-project")"
        export LOOMY_PROJECT_NAME="$UI_VALUE"
        ui_end "$(t "creating ./%s…" "$(loomy_slug "$UI_VALUE")")"
        ui_exec bash "$0" "$TARGET/$(loomy_slug "$UI_VALUE")" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"} ;;
      reset)
        UI_DESCS=("$(t "Starts again from the Brief phase. Nothing is deleted apart from .loomy/state.")" "$(t "Changes nothing.")")
        UI_LABEL="$(t "Confirmation")"
        ui_choose "$(t "Reset this project's bootstrap?")" 1 "$(t "Yes, reset")" "$(t "No")"
        if [[ "$UI_INDEX" == "0" ]]; then ACTION="reset"; else ui_end "$(t "nothing was changed")"; exit 0; fi ;;
      *) ui_end "$(t "nothing was changed")"; exit 0 ;;
    esac
  fi

  case "$ACTION" in
    update)
      do_update
      ui_end "$(t "resume: loomy start · tracking: loomy watch")"
      exit 0 ;;
    brief)
      ui_end "$(t "questionnaire…")"
      ui_exec "$LOOMY_ROOT/scripts/init-wizard.sh" "$TARGET" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"} ;;
    reset)
      do_reset
      if (( RUN_WIZARD )); then
        answers=(); [[ -f "$L/brief.previous.md" ]] && answers=(--answers "$L/brief.previous.md")
        ui_end "$(t "questionnaire (your previous answers are the defaults)…")"
        run_wizard ${answers[@]+"${answers[@]}"}
      fi
      ui_end "$(t "fill in the brief: loomy brief · then: loomy start")"
      exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- nouveau projet
if [[ "$ACTION" == "update" ]]; then
  t "Error: no Loomy project in %s to update. Run loomy init to create it." "$TARGET" >&2; echo >&2
  exit 1
fi
# Existing project with a Git history: everything Loomy and the agents do goes to a dedicated branch, created from the
# current one. Switching to a new branch at HEAD changes no file (uncommitted changes stay as they are); the original
# branch is never touched, and merging back is the user's call.
adopt_branch() {
  (( ADOPT_BRANCH )) || return 0
  git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [[ "$(cd "$(git -C "$TARGET" rev-parse --show-toplevel)" && pwd -P)" == "$(cd "$TARGET" && pwd -P)" ]] || return 0
  git -C "$TARGET" rev-parse --verify -q HEAD >/dev/null || return 0
  local base; base="$(git -C "$TARGET" symbolic-ref --short -q HEAD)" || return 0
  local br="loomy/adopt"
  if [[ "$base" == "$br" ]]; then base="$(git -C "$TARGET" config --get "branch.$br.loomy-base" || echo main)"
  elif git -C "$TARGET" show-ref --verify -q "refs/heads/$br"; then git -C "$TARGET" checkout -q "$br" || return 0
  else git -C "$TARGET" checkout -q -b "$br" || return 0; git -C "$TARGET" config "branch.$br.loomy-base" "$base"; fi
  export LOOMY_ADOPT_BRANCH="$br" LOOMY_BASE_BRANCH="$base"
  ui_ok "$(t "Dedicated branch %s" "$br")" "$(t "created from %s, which stays untouched" "$base")"
}
if [[ -n "$(find "$TARGET" -mindepth 1 -maxdepth 1 ! -name '.git' ! -name '.DS_Store' 2>/dev/null | head -1)" ]]; then
  ADOPTING=1
  ui_banner "$(t "Existing project")" "${TARGET/#$HOME/~}"
  adopt_branch
else ADOPTING=0; fi
copy_loomy_files
cp "$DOCS_ROOT/START.md" "$TARGET/START.md"

if (( RUN_WIZARD )); then run_wizard; fi
if (( ADOPTING )) && [[ ! -f "$L/assessment.md" ]]; then bash "$LOOMY_ROOT/scripts/ai-assess.sh" --root "$TARGET" --quiet >/dev/null 2>&1 || true; fi

brief_cmd=".loomy/scripts/init-wizard.sh"; command -v loomy >/dev/null 2>&1 && brief_cmd="loomy brief"
ui_banner "$(t "Loomy installed")" "v$NEW_V · ${TARGET/#$HOME/~}"
if (( RUN_WIZARD )); then ui_warn "$(t "Non-interactive terminal")" "$(t "questionnaire skipped")"; fi
ui_section "$(t "NEXT STEP")"
ui_rail "${C_BRAND}1${C_RESET}  $(t "Fill in the project brief:") ${C_BOLD}${brief_cmd}${C_RESET}"
ui_rail "${C_BRAND}2${C_RESET}  $(t "Start the lead agent:") ${C_BOLD}loomy start${C_RESET}"
ui_end "$(t "START.md, .loomy/ and one .gitignore line added; nothing else is changed")"

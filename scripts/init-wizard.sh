#!/usr/bin/env bash
# shellcheck disable=SC2034  # les réponses A_* sont lues indirectement par ans() ; les UI_* par lib/ui.sh
# Questionnaire interactif du brief de projet pour Loomy.
# Écrit .loomy/brief.md, que START.md utilise comme entretien déjà mené.
# Compatible bash 3.2, sans dépendance. Rendu : scripts/lib/ui.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

usage() {
  cat >&2 <<'EOF'
Usage: init-wizard.sh [target-dir] [options]

Options:
  --yes             Pas de questions : valeurs par défaut (ou celles de --answers)
  --answers FILE    Reprendre les réponses d'un brief existant (front matter key: value)
  --no-clipboard    Ne pas copier le prompt de démarrage dans le presse-papiers
  -h, --help        Afficher cette aide

Touches : ↑↓ choisir, ⏎ valider, ← revenir à la question précédente.
Variable : NO_COLOR=1 désactive les couleurs.
EOF
}

TARGET_INPUT=""
ANSWERS_FILE=""
USE_CLIPBOARD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) UI_ASSUME_DEFAULTS=1 ;;
    --answers) ANSWERS_FILE="${2:-}"; [[ -z "$ANSWERS_FILE" ]] && { usage; exit 2; }; shift ;;
    --no-clipboard) USE_CLIPBOARD=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) t "Unknown option: %s" "$1" >&2; echo >&2; usage; exit 2 ;;
    *) TARGET_INPUT="$1" ;;
  esac
  shift
done

# Cible par défaut : le projet qui contient cette copie de .loomy, sinon le dossier courant.
if [[ -z "$TARGET_INPUT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then
    TARGET_INPUT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else
    TARGET_INPUT="."
  fi
fi
[[ -d "$TARGET_INPUT" ]] || { t "Error: folder not found: %s" "$TARGET_INPUT" >&2; echo >&2; exit 1; }
TARGET="$(cd "$TARGET_INPUT" && pwd)"
BRIEF="$TARGET/.loomy/brief.md"
mkdir -p "$TARGET/.loomy"

if [[ "$UI_ASSUME_DEFAULTS" != "1" ]] && ! ui_is_interactive; then
  t "Non-interactive terminal: run again with --yes (and optionally --answers FILE)." >&2; echo >&2
  exit 2
fi

LOOMY_VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "?")"

# ---------------------------------------------------------------- fichier de réponses
load_answers() {
  local file="$1" line key value in_fm=0
  [[ -f "$file" ]] || { t "Error: answers file not found: %s" "$file" >&2; echo >&2; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "---" ]]; then
      if (( in_fm )); then break; else in_fm=1; continue; fi
    fi
    (( in_fm )) || continue
    [[ "$line" =~ ^([a-z_]+):[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    if [[ "$value" == \"*\" ]]; then value="${value#\"}"; value="${value%\"}"; fi
    value="${value//\\\"/\"}"; value="${value//\\\\/\\}"
    printf -v "A_$key" '%s' "$value"
  done <"$file"
}
ans() { local v="A_$1"; printf '%s' "${!v:-${2:-}}"; }

if [[ -n "$ANSWERS_FILE" ]]; then
  load_answers "$ANSWERS_FILE"
elif [[ -f "$BRIEF" ]]; then
  load_answers "$BRIEF"
fi

# ---------------------------------------------------------------- utilitaires
# choose_coded <var> <question> <default-code> "code|Label"...
# Libellé sans la mention « (recommandé) », quelle que soit la langue.
no_rec() { local v="${1% (recommandé)}"; printf '%s' "${v% (recommended)}"; }
choose_coded() {
  local var="$1" q="$2" defcode="$3" hint="$4"; shift 4
  local labels=() codes=() descs=() i=0 defi=0 item rest
  # Question, aide, libellés et descriptions passent par t (langue de l'interface) ; les codes restent fixes.
  for item in "$@"; do
    codes[$i]="${item%%|*}"; rest="${item#*|}"
    labels[$i]="$(t "${rest%%|*}")"
    if [[ "$rest" == *"|"* ]]; then descs[$i]="$(t "${rest#*|}")"; else descs[$i]=""; fi
    if [[ "${codes[$i]}" == "$defcode" ]]; then defi=$i; fi
    i=$(( i + 1 ))
  done
  UI_HINT="$( [[ -n "$hint" ]] && t "$hint")"; UI_DESCS=("${descs[@]}")
  ui_choose "$(t "$q")" "$defi" "${labels[@]}"
  if [[ -n "${UI_INDEX:-}" && -n "${codes[$UI_INDEX]:-}" ]]; then
    printf -v "$var" '%s' "${codes[$UI_INDEX]}"; printf -v "${var}_LABEL" '%s' "${labels[$UI_INDEX]}"; return 0
  fi
  printf -v "$var" '%s' "$defcode"; printf -v "${var}_LABEL" '%s' "$defcode"
}

yaml_q() {
  local v="${1//$'\n'/ }"
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

# ---------------------------------------------------------------- environnement
HAS_GIT=0; IS_REPO=0; PARENT_REPO=""; PARENT_REMOTE=""; HAS_CLAUDE=0; HAS_CODEX=0; GIT_REMOTE=""; GH_USER=""; REMOTE_VIS=""

env_check() {
  # L'affichage, le contrôle des prérequis et les corrections guidées sont confiés à ai-doctor.sh.
  local doctor_args=(--root "$TARGET" --compact)
  ui_is_interactive && doctor_args+=(--fix)
  ui_run "$SCRIPT_DIR/ai-doctor.sh" "${doctor_args[@]}" || ui_warn "$(t "Minimum requirements not met")" "$(t "you can still write the brief; fix this before launching the agent")"

  if command -v git >/dev/null 2>&1; then
    HAS_GIT=1
    if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      local remote top
      remote="$(git -C "$TARGET" remote 2>/dev/null | head -1)"
      if [[ -n "$remote" ]]; then GIT_REMOTE="$remote $(git -C "$TARGET" remote get-url "$remote" 2>/dev/null)"; fi
      top="$(cd "$(git -C "$TARGET" rev-parse --show-toplevel)" && pwd -P)"
      if [[ "$top" == "$(cd "$TARGET" && pwd -P)" ]]; then IS_REPO=1
      else
        # Dossier à l'intérieur d'un dépôt parent : dépôt propre au projet, ou monorepo (question Git).
        PARENT_REPO="$top"; PARENT_REMOTE="$GIT_REMOTE"; GIT_REMOTE=""
      fi
    fi
  fi
  ai_has_claude && HAS_CLAUDE=1
  ai_has_codex && HAS_CODEX=1
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
    # Visibilité du dépôt GitHub existant : elle oriente le choix par défaut pour les fichiers IA.
    if [[ "$GIT_REMOTE" == *github.com* ]]; then
      REMOTE_VIS="$(cd "$TARGET" && gh repo view --json visibility --jq .visibility 2>/dev/null || true)"
    fi
  fi

  local count
  # Ce que Loomy vient d'ajouter (START.md, .loomy, .gitignore) ne fait pas un projet existant.
  count="$(find "$TARGET" -mindepth 1 -maxdepth 1 ! -name '.git' ! -name '.loomy' ! -name 'START.md' ! -name '.gitignore' ! -name '.claude' ! -name '.codex' ! -name '.DS_Store' | wc -l | tr -d ' ')"
  if [[ "$count" == "0" ]]; then DETECTED_REPO="new"; ui_end "$(t "detected: empty folder (new project)")"
  elif [[ "$count" == "1" ]]; then DETECTED_REPO="existing"; ui_end "$(t "detected: existing project (1 item at the root)")"
  else DETECTED_REPO="existing"; ui_end "$(t "detected: existing project (%s items at the root)" "$count")"; fi
}

# ---------------------------------------------------------------- questionnaire
TOTAL=12

# Forfaits Claude et Codex : demandés une seule fois, en mode interactif, pour un outil présent et pas encore renseigné.
ASK_PLAN_CLAUDE=0; ASK_PLAN_CODEX=0; PLAN_CLAUDE_NEW=""; PLAN_CODEX_NEW=""
plan_questions() {
  ui_is_interactive || return 0
  if (( HAS_CLAUDE )) && [[ -z "$(loomy_config_get plan_claude "")" ]]; then ASK_PLAN_CLAUDE=1; fi
  if (( HAS_CODEX )) && [[ -z "$(loomy_config_get plan_codex "")" ]]; then ASK_PLAN_CODEX=1; fi
  if (( ASK_PLAN_CLAUDE || ASK_PLAN_CODEX )); then TOTAL=13; fi
  return 0
}

ask_all() {
  local tbd="tbd|À décider|L'agent proposera une option argumentée pendant l'entretien."
  FORCE_AUTH=0

  ui_group "$(t "PROJECT")"
  ui_step 1 $TOTAL
  UI_LABEL="$(t "Name")"
  UI_HINT="$(t "Used as the project name in the generated documentation.")"
  ui_input "$(t "Project name")" "$(ans name "${LOOMY_PROJECT_NAME:-$(basename "$TARGET")}")"
  NAME="$UI_VALUE"
  SLUG="$(loomy_slug "$NAME")"

  ui_step 2 $TOTAL
  UI_LABEL="$(t "Goal")"
  UI_HINT="$(t "One sentence is enough: the agent reuses it in PROJECT.md and asks fewer questions. Enter to leave empty.")"
  ui_input "$(t "Goal in one sentence")" "$(ans goal "")" "$(t "E.g.: Help freelancers keep track of their invoices")"
  GOAL="$UI_VALUE"

  ui_step 3 $TOTAL
  UI_LABEL="$(t "Starting point")"
  choose_coded REPO "New project or existing project?" "$(ans repo "$DETECTED_REPO")" \
    "Oriente la découverte (détecté automatiquement, à confirmer)." \
    "new|New project|The agent proposes the stack and structure from scratch." \
    "existing|Existing project to standardise|The agent first analyses what exists and only proposes standardisation changes, without breaking the architecture."

  ui_step 4 $TOTAL
  UI_LABEL="$(t "Type")"
  choose_coded TYPE "What kind of project?" "$(ans type web)" \
    "Determines the next questions and the suggested checks (build, tests, deployment)." \
    "web|Web app / SaaS|Front end and optional back end, web deployment; accessibility and SEO to consider." \
    "api|API / backend service|Service without a UI: API contracts, validation and integration tests at the core." \
    "mobile|Mobile app|Store constraints, permissions, offline; iOS and/or Android builds." \
    "desktop|Desktop app|Packaging, signing and updates per operating system." \
    "cli|CLI / library|Stable public API, packaging and runtime compatibility." \
    "ai|AI / LLM app|Provider choice, data exposure, guardrails and answer evaluation." \
    "other|Other|You will describe the type; the agent will ask more questions."

  ui_step 5 $TOTAL
  local d1="" d2=""
  case "$TYPE" in
    web)
      UI_LABEL="$(t "Hosting")"
      choose_coded X1 "Target hosting?" "$(ans detail1 tbd)" "Influences the framework, runtime and deployment pipeline." \
        "vercel|Vercel / Netlify|Simple, serverless deployment, ideal for a modern front end." \
        "cloudflare|Cloudflare|Runs at the edge, very cheap, with runtime constraints." \
        "server|Server / VPS / Docker|Full control, but more operations to handle." "$tbd"
      UI_LABEL="$(t "Accounts")"
      choose_coded X2 "User accounts?" "$(ans detail2 tbd)" "Authentication increases risk and scope." \
        "yes|Yes|Authentication and sessions required: at least MEDIUM risk." \
        "no|No|No authentication required." "$tbd"
      d1="$(t "Hosting: %s" "$X1_LABEL")"; d2="$(t "User accounts: %s" "$X2_LABEL")"
      [[ "$X2" == "yes" ]] && FORCE_AUTH=1 ;;
    api)
      UI_LABEL="$(t "API style")"
      choose_coded X1 "API style?" "$(ans detail1 tbd)" "Shapes the contracts, documentation and tests." \
        "rest|REST|Standard, easy to consume and document (OpenAPI)." \
        "graphql|GraphQL|Flexible client queries, typed schema, more server complexity." \
        "rpc|RPC / gRPC|Fast between services, less suited to public web clients." "$tbd"
      UI_LABEL="$(t "Database")"
      choose_coded X2 "Database?" "$(ans detail2 tbd)" "Guides persistence and migrations." \
        "sql|SQL|Strong relations and integrity (PostgreSQL, SQLite…)." \
        "nosql|NoSQL|Flexible schema, horizontal scaling." \
        "none|None|No persistence required." "$tbd"
      d1="$(t "API style: %s" "$X1_LABEL")"; d2="$(t "Database: %s" "$X2_LABEL")" ;;
    mobile)
      UI_LABEL="$(t "Approach")"
      choose_coded X1 "Approach?" "$(ans detail1 tbd)" "Determines the language, tooling and number of codebases." \
        "expo|Expo / React Native|A single JS/TS codebase for iOS and Android, fast iterations." \
        "native|Native (Swift / Kotlin)|Best integration and performance, but two codebases." \
        "flutter|Flutter|A single cross-platform Dart codebase, with its own rendering." "$tbd"
      UI_LABEL="$(t "Platforms")"
      choose_coded X2 "Platforms?" "$(ans detail2 both)" "Each platform adds builds, tests and publishing." \
        "both|iOS and Android|Builds, tests and publishing on both stores." \
        "ios|iOS|A single platform: simpler to ship." \
        "android|Android|A single platform: simpler to ship."
      d1="$(t "Approach: %s" "$X1_LABEL")"; d2="$(t "Platforms: %s" "$X2_LABEL")" ;;
    desktop)
      UI_LABEL="$(t "Systems")"
      choose_coded X1 "Target systems?" "$(ans detail1 multi)" "Each OS adds packaging, signing and tests." \
        "macos|macOS|A single target: simpler signing and packaging." \
        "windows|Windows|A single target: simpler signing and packaging." \
        "linux|Linux|A single target: simpler packaging." \
        "multi|Cross-platform|Builds and tests needed for each OS."
      UI_LABEL="$(t "Technology")"
      choose_coded X2 "Technology?" "$(ans detail2 tbd)" "Trade-off between binary size, ecosystem and native integration." \
        "tauri|Tauri|Lightweight (Rust + webview), small binaries." \
        "electron|Electron|Mature ecosystem, heavy binaries." \
        "native|Native|Best integration, one codebase per OS." "$tbd"
      d1="$(t "Systems: %s" "$X1_LABEL")"; d2="$(t "Technology: %s" "$X2_LABEL")" ;;
    cli)
      UI_LABEL="$(t "Language")"
      choose_coded X1 "Language / runtime?" "$(ans detail1 tbd)" "Determines the ecosystem, packaging and distribution." \
        "node|Node.js|Distributed via npm, quick start." \
        "python|Python|Rich ecosystem, pip/uv packaging." \
        "go|Go|Single binary, no runtime to install." \
        "rust|Rust|Single fast binary, more demanding compilation." \
        "bash|Bash|Zero dependencies, limited to simple scripts." "$tbd"
      UI_LABEL="$(t "Distribution")"
      choose_coded X2 "Distribution?" "$(ans detail2 tbd)" "Sets how strict interface stability must be." \
        "registry|Public registry (npm, PyPI, crates…)|Semantic versioning and a public API to stabilise." \
        "binary|Binary|Multi-OS builds and releases to automate." \
        "internal|Internal use|Lighter compatibility constraints." "$tbd"
      d1="$(t "Runtime: %s" "$X1_LABEL")"; d2="$(t "Distribution: %s" "$X2_LABEL")" ;;
    ai)
      UI_LABEL="$(t "Provider")"
      choose_coded X1 "Model provider?" "$(ans detail1 tbd)" "Determines the SDK, costs and data usage terms." \
        "anthropic|Anthropic (Claude)|SDK and models from a single provider." \
        "openai|OpenAI|SDK and models from a single provider." \
        "multi|Several|An abstraction layer between providers is needed." \
        "local|Local models|No API cost, performance depends on hardware." "$tbd"
      UI_LABEL="$(t "Data exposed")"
      choose_coded X2 "Data sent to the models?" "$(ans detail2 internal)" "Determines the guardrails and risk level." \
        "public|Public|Few constraints." \
        "internal|Internal|Check the provider's data retention and usage." \
        "sensitive|Sensitive data|HIGH risk: anonymisation, guardrails and DEEP security reviews."
      d1="$(t "Provider: %s" "$X1_LABEL")"; d2="$(t "Data exposed: %s" "$X2_LABEL")" ;;
    *)
      UI_LABEL="$(t "Custom type")"
      UI_HINT="$(t "A few words are enough; the agent will fill in the rest during the interview.")"
      ui_input "$(t "Describe the project type")" "$(ans detail1 "")"
      X1="$UI_VALUE"; X2=""; d1="$(t "Custom type: %s" "$UI_VALUE")" ;;
  esac
  DETAIL1="${X1:-}"; DETAIL2="${X2:-}"
  DETAILS="$d1${d2:+ · $d2}"

  ui_group "$(t "REQUIREMENTS")"
  ui_step 6 $TOTAL
  UI_LABEL="$(t "Stage")"
  choose_coded STAGE "Target stage?" "$(ans stage mvp)" \
    "Sets the bar from the start: tests, CI, security." \
    "prototype|Prototype / exploration|Speed first: minimal tests, no mandatory CI." \
    "mvp|MVP|Targeted tests, simple CI, controlled technical debt." \
    "production|Production|Full tests, CI/CD and observability; at least MEDIUM risk."

  ui_step 7 $TOTAL
  local sens_def="" c
  # Libellés dans la langue de l'interface ; les codes (auth, payments…) restent fixes.
  local L_AUTH L_PAY L_PERS L_INFRA
  L_AUTH="$(t "Authentication / accounts")"; L_PAY="$(t "Payments")"; L_PERS="$(t "Personal data")"; L_INFRA="$(t "Secrets / production infra")"
  for c in $(printf '%s' "$(ans sensitive "")" | tr ',' ' '); do
    case "$c" in
      auth) sens_def="${sens_def:+$sens_def,}$L_AUTH" ;;
      payments) sens_def="${sens_def:+$sens_def,}$L_PAY" ;;
      personal) sens_def="${sens_def:+$sens_def,}$L_PERS" ;;
      infra) sens_def="${sens_def:+$sens_def,}$L_INFRA" ;;
    esac
  done
  if [[ "${FORCE_AUTH:-0}" == "1" && "$sens_def" != *"$L_AUTH"* ]]; then
    sens_def="${sens_def:+$sens_def,}$L_AUTH"
  fi
  UI_LABEL="$(t "Sensitive areas")"
  UI_HINT="$(t "Each checked item raises the risk and requires deeper reviews (DEEP models). Nothing checked = none.")"
  UI_DESCS=("$(t "MEDIUM risk: sessions, permissions, password storage.")" \
    "$(t "HIGH risk: compliance, idempotency, systematic security review.")" \
    "$(t "HIGH risk: GDPR, data minimisation and protection.")" \
    "$(t "HIGH risk: secrets management, irreversible operations.")")
  ui_multi "$(t "Sensitive areas?")" "$sens_def" "$L_AUTH" "$L_PAY" "$L_PERS" "$L_INFRA"
  SENSITIVE=""; SENSITIVE_LABEL="${UI_VALUE:-$(t "none")}"
  case "$UI_VALUE" in *"$L_AUTH"*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}auth" ;; esac
  case "$UI_VALUE" in *"$L_PAY"*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}payments" ;; esac
  case "$UI_VALUE" in *"$L_PERS"*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}personal" ;; esac
  case "$UI_VALUE" in *"$L_INFRA"*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}infra" ;; esac
  RISK="LOW"
  case ",$SENSITIVE," in *,auth,*) RISK="MEDIUM" ;; esac
  case ",$SENSITIVE," in *,payments,*|*,personal,*|*,infra,*) RISK="HIGH" ;; esac
  if [[ "$RISK" == "LOW" && "$STAGE" == "production" ]]; then RISK="MEDIUM"; fi
  if [[ "$TYPE" == "ai" && "$DETAIL2" == "sensitive" ]]; then RISK="HIGH"; fi
  ui_fact "$(t "Estimated risk")" "$(t "%s risk" "$RISK")"

  ui_group "$(t "AI TEAM")"
  ui_step 8 $TOTAL
  local mode_def="SOLO" lead_def="claude"
  if (( HAS_CODEX && HAS_CLAUDE )); then mode_def="ORCHESTRATED"
  elif (( HAS_CODEX )); then lead_def="codex"; fi
  UI_LABEL="$(t "Collaboration")"
  choose_coded MODE "AI collaboration mode?" "$(ans ai_mode "$mode_def")" \
    "Définit comment Codex et Claude Code se partagent le travail. Pré-sélection selon les outils détectés." \
    "SOLO|SOLO|Un seul outil à la fois : le plus simple et le moins coûteux." \
    "HYBRID|HYBRID|Les deux outils travaillent tour à tour, coordonnés par Git et .ai/HANDOFF.md." \
    "ORCHESTRATED|ORCHESTRATED|L'orchestrateur délègue chaque rôle au meilleur modèle des deux familles (exécution sur GPT-6-Luna, architecture et sécurité sur Opus 5.5, revue croisée) : meilleur rapport qualité/coût." \
    "PARALLEL|PARALLEL|Les deux en même temps sur des worktrees séparés : plus rapide, intégration à soigner."
  UI_LABEL="$(t "Main tool")"
  choose_coded LEAD "Main tool (lead)?" "$(ans ai_lead "$lead_def")" \
    "L'outil principal porte l'orchestrateur : il planifie, délègue, décide et vérifie. C'est lui qui mérite le meilleur raisonnement." \
    "claude|Claude Code|Orchestrator on Opus 5.5, top of the reasoning and agentic benchmarks; delegates to Codex via delegate-to-codex.sh (recommended)." \
    "codex|Codex|Orchestrator on GPT-6-Astra; delegates to Claude via delegate-to-claude.sh (read-only)."

  ui_step 9 $TOTAL
  UI_LABEL="$(t "Profile")"
  choose_coded BUDGET "Model cost / quality profile?" "$(ans budget equilibre)" \
    "The orchestrator always stays on the best model; the profile sets each role's effort and model (details: loomy route)." \
    "econome|Thrifty|Orchestrator and specialists at medium effort, execution on the fast models. Minimal cost, a few more retries on hard tasks." \
    "equilibre|Balanced (recommended)|Orchestrator at high; execution on GPT-6-Luna max or Sonnet 5; architecture, security and hard debugging on Opus 5.5 high. Best quality/cost ratio." \
    "qualite|Max quality|Orchestrator and specialists at xhigh, reviews on the top model, execution on Sol or Sonnet high. Much higher cost, fewer retries."
  ai_env_for "$MODE" "$LEAD"
  ROUTE_ENV="$AI_ENV"; ROUTE_NOTE="$AI_ENV_NOTE"
  ai_resolve lead "$ROUTE_ENV" "$BUDGET"; LEAD_LINE="$R_MODEL ($R_EFFORT)"
  ai_resolve executor "$ROUTE_ENV" "$BUDGET"; EXEC_LINE="$R_MODEL ($R_EFFORT)"
  ai_resolve architect "$ROUTE_ENV" "$BUDGET"; DEEP_LINE="$R_MODEL ($R_EFFORT)"
  ui_fact "$(t "Lead agent")" "$(t "orchestrator %s" "${LEAD_LINE}")"

  ui_group "$(t "DELIVERABLES")"
  ui_step 10 $TOTAL
  UI_LABEL="$(t "Docs language")"
  choose_coded DOCLANG "Project documentation language?" "$(ans doc_language "$(ui_lang)")" \
    "Language of the generated files (PROJECT.md, ADRs…). Code and identifiers stay in English." \
    "fr|Français|Documentation written in French." \
    "en|English|Documentation in English: better if the project is shared internationally."

  ui_step 11 $TOTAL
  UI_LABEL="$(t "START.md afterwards")"
  choose_coded HISTORY "After initialisation, what to do with START.md?" "$(ans bootstrap_history archive)" \
    "START.md no longer has authority once the project is initialised." \
    "archive|Archive it in .ai/bootstrap/ (recommended)|Keeps a record of the initialisation for later." \
    "delete|Delete it|Lighter repo; the history stays only in Git."

  ui_step 12 $TOTAL
  GIT_INIT="no"; COMMIT="no"; PUSH="no"
  if (( HAS_GIT )) && [[ -n "$PARENT_REPO" ]]; then
    UI_LABEL="$(t "Git repository")"
    git_def="yes"; [[ "$REPO" == "existing" ]] && git_def="no"
    choose_coded GIT_INIT "Create a dedicated Git repository for this project?" "$(ans git_init "$git_def")" \
      "Ce dossier est à l'intérieur du dépôt Git ${PARENT_REPO/#$HOME/~}." \
      "yes|Yes, dedicated repository (recommended for a new project)|The project has its own history, and can have its own GitHub repository." \
      "no|No, stay in the parent repository (monorepo)|Commits go to the parent repository; no GitHub repository of its own."
    if [[ "$GIT_INIT" == "no" ]]; then IS_REPO=1; GIT_REMOTE="$PARENT_REMOTE"; fi
  elif (( HAS_GIT )) && (( ! IS_REPO )); then
    UI_LABEL="$(t "Git repository")"
    choose_coded GIT_INIT "Initialise a Git repository (main branch) now?" "$(ans git_init yes)" \
      "Version control is required for commits, worktrees and handoffs." \
      "yes|Yes|Creates the local repository now; nothing is sent online." \
      "no|No|No version control: no commit or push possible."
  fi
  GITHUB_REPO="no"; REMOTE_NAME_NOTE=""; REPO_NAME="$SLUG"; AI_REPO_NAME=""
  if (( IS_REPO )) || [[ "$GIT_INIT" == "yes" ]]; then
    if [[ -n "$GIT_REMOTE" ]]; then
      # Le dépôt distant doit porter le nom du projet : sinon on le signale (sans rien renommer).
      remote_name="$(basename "${GIT_REMOTE#* }" .git)"
      [[ -n "$remote_name" ]] && REPO_NAME="$remote_name"
      if [[ -n "$remote_name" && "$remote_name" != "$SLUG" ]]; then
        REMOTE_NAME_NOTE="$(t "remote repository '%s', project name '%s'" "$remote_name" "$SLUG")"
        ui_warn "$(t "Repository name differs from the project")" "$remote_name ≠ $SLUG"
      fi
    elif [[ -n "$GH_USER" && ( -z "$PARENT_REPO" || "$GIT_INIT" == "yes" ) ]]; then
      UI_LABEL="$(t "GitHub repository")"
      # Jamais de création de dépôt en ligne sans question (mode --yes : non, sauf réponse explicite).
      gh_def="private"; [[ "$UI_ASSUME_DEFAULTS" == "1" ]] && gh_def="no"
      choose_coded GITHUB_REPO "Create a GitHub repository for this project?" "$(ans github_repo "$gh_def")" \
        "Il porte le nom du projet ; créé seulement une fois le brief enregistré." \
        "private|Yes, private|Visible only to you (and people you invite). Recommended." \
        "public|Yes, public|Visible to everyone: mind the AI files visibility, next question." \
        "no|No, later|No online repository for now; you can create it with gh repo create."
      if [[ "$GITHUB_REPO" != "no" ]]; then
        UI_LABEL="$(t "Repository name")"
        UI_HINT="$(t "Suggested from the project name; change it if needed (letters, digits, hyphens).")"
        ui_input "$(t "GitHub repository name (%s/…)" "$GH_USER")" "$(ans repo_name "$SLUG")"
        REPO_NAME="$(loomy_slug "$UI_VALUE")"
        GIT_REMOTE="origin https://github.com/$GH_USER/$REPO_NAME.git"
        REMOTE_VIS="$(printf '%s' "$GITHUB_REPO" | tr '[:lower:]' '[:upper:]')"
      fi
    fi
    UI_LABEL="$(t "Initial commit")"
    choose_coded COMMIT "Initial commit once the setup is verified?" "$(ans commit_after_setup yes)" \
      "Lets the agent finish the initialisation with a commit." \
      "yes|Yes, the agent commits|Commit 'chore: initialize project' only if all checks pass." \
      "no|No, I will commit myself|Changes stay uncommitted; you stay in control."
    if [[ "$COMMIT" == "yes" ]]; then
      if [[ -n "$GIT_REMOTE" ]]; then
        UI_LABEL="$(t "Push")"
        choose_coded PUSH "$(t "Push to %s after the commit?" "${GIT_REMOTE%% *}")" "$(ans push_after_commit no)" \
          "$(t "Remote detected: %s" "${GIT_REMOTE#* }")" \
          "no|No, I will push myself|Nothing leaves your machine without you." \
          "yes|Yes, push the current branch|The branch is pushed after the initial commit, never force-pushed."
      else
        ui_fact "Push" "$(t "no remote, no push")"
      fi
    fi
  else
    ui_fact "Git" "$(t "no Git repository: no commit, no push")"
  fi

  # Fichiers IA : GitHub règle la visibilité par dépôt, pas par fichier.
  local files_def="versioned" vis_txt=""
  case "$REMOTE_VIS" in
    PUBLIC) files_def="private"; [[ -z "$GH_USER" ]] && files_def="local"; vis_txt=" $(t "Your GitHub repository is public.")" ;;
    PRIVATE|INTERNAL) vis_txt=" $(t "Your GitHub repository is private.")" ;;
  esac
  UI_LABEL="$(t "AI files")"
  choose_coded AI_FILES "Where to keep the AI files (AGENTS.md, CLAUDE.md, .ai/, .loomy/…)?" "$(ans ai_files "$files_def")" \
    "$(t "These are your working rules with the agents. GitHub sets visibility per repository, not per file.")$vis_txt" \
    "versioned|Versioned with the project|Recommended for a private repository: you get them on all your machines, and agents working online on the repository can read them." \
    "local|Local only|Never sent to GitHub: excluded via .git/info/exclude, invisible in the repository. Lost if you change machines." \
    "private|\$(t "In a separate private repository")|$(t "Recommended for a public repository: excluded from the project and backed up in a private GitHub repository (%s), with loomy privacy sync." "$(basename "$TARGET")-ai")"
  if [[ "$AI_FILES" == "private" ]]; then
    while true; do
      UI_LABEL="$(t "Private AI repository")"
      UI_HINT="$(t "Private repository that will only hold the AI files; change the name if needed.")"
      ui_input "$(t "Name of the private AI files repository")${GH_USER:+ ($GH_USER/…)}" "$(ans ai_repo_name "${AI_REPO_NAME:-$REPO_NAME-ai}")"
      AI_REPO_NAME="$(loomy_slug "$UI_VALUE")"
      [[ "$GITHUB_REPO" == "no" ]] && break
      # Deux dépôts à créer : confirmation des deux noms ensemble.
      UI_LABEL="$(t "Two repositories")"
      UI_DESCS=("$(t "Creates %s (%s) for the project and %s (private) for the AI files." "$GH_USER/$REPO_NAME" "$( [[ "$GITHUB_REPO" == public ]] && t "public" || t "private")" "$GH_USER/$AI_REPO_NAME")" \
        "$(t "Ask for both names again.")")
      ui_choose "$(t "Create these two repositories: %s and %s?" "$REPO_NAME" "$AI_REPO_NAME")" 0 "$(t "Yes, create both")" "$(t "Change the names")"
      [[ "$UI_INDEX" == "0" ]] && break
      UI_LABEL="$(t "Repository name")"
      ui_input "$(t "GitHub repository name (%s/…)" "$GH_USER")" "$REPO_NAME"
      REPO_NAME="$(loomy_slug "$UI_VALUE")"; GIT_REMOTE="origin https://github.com/$GH_USER/$REPO_NAME.git"
    done
  fi

  if (( TOTAL == 13 )); then ui_group "$(t "PLANS")"; ui_step 13 $TOTAL; fi
  if (( ASK_PLAN_CLAUDE )); then
    UI_LABEL="$(t "Claude plan")"
    choose_coded PLAN_CLAUDE_NEW "What is your Claude plan?" "${PLAN_CLAUDE_NEW:-api}" \
      "Asked only once, saved in your Loomy configuration. Used to compare the value consumed with the plan price." \
      "api|API|Pay as you go: Loomy shows the actual cost." \
      "pro|Claude Pro (20 \$/mois)|Loomy affiche la valeur API consommée face à 20 \$ par mois." \
      "max5|Claude Max 5x (100 \$/mois)|Loomy affiche la valeur API consommée face à 100 \$ par mois." \
      "max20|Claude Max 20x (200 \$/mois)|Loomy affiche la valeur API consommée face à 200 \$ par mois." \
      "team|Claude Team or Enterprise|Price adjustable later with loomy config set plan_claude_price <price>."
  fi
  if (( ASK_PLAN_CODEX )); then
    UI_LABEL="$(t "Codex plan")"
    choose_coded PLAN_CODEX_NEW "What is your ChatGPT / Codex plan?" "${PLAN_CODEX_NEW:-api}" \
      "Asked only once, saved in your Loomy configuration." \
      "api|API|Pay as you go: Loomy shows the cost estimated from tokens." \
      "plus|ChatGPT Plus (20 \$/mois)|Loomy affiche la valeur API consommée face à 20 \$ par mois." \
      "pro100|ChatGPT Pro (100 \$/mois)|Loomy affiche la valeur API consommée face à 100 \$ par mois." \
      "pro200|ChatGPT Pro (200 \$/mois)|Loomy affiche la valeur API consommée face à 200 \$ par mois." \
      "business|ChatGPT Business or Enterprise|Price adjustable later with loomy config set plan_codex_price <price>."
  fi
}

show_recap() {
  local risk_c="$C_GREEN" goal_txt="$GOAL" parts=""
  [[ "$RISK" == "MEDIUM" ]] && risk_c="$C_YELLOW"
  [[ "$RISK" == "HIGH" ]] && risk_c="$C_RED"
  [[ -z "$goal_txt" ]] && goal_txt="${C_DIM}à préciser avec l'agent${C_RESET}"
  if [[ "$GIT_INIT" == "yes" ]]; then parts="git init"; fi
  if [[ "$COMMIT" == "yes" ]]; then parts="${parts:+$parts + }commit après vérification"; fi
  if [[ "$PUSH" == "yes" ]]; then parts="${parts:+$parts + }push vers ${GIT_REMOTE%% *}"; fi
  ui_rail_head "v$LOOMY_VERSION · $(t "startup brief") · $(basename "$TARGET")"
  ui_rail_group "$(t "Project brief")" ".loomy/brief.md"
  ui_rail_kv "$(t "Name")" "${C_BOLD}${NAME}${C_RESET}"
  ui_rail_kv "$(t "Goal")" "$goal_txt"
  ui_rail_kv "$(t "Project")" "$REPO_LABEL · $TYPE_LABEL · $STAGE_LABEL"
  ui_rail_kv "$(t "Details")" "$DETAILS"
  ui_rail_kv "$(t "Sensitive")" "$SENSITIVE_LABEL"
  ui_rail_kv "$(t "Risk")" "${risk_c}${RISK}${C_RESET}"
  ui_rail ""
  ui_rail_group "$(t "AI team")"
  ui_rail_kv "$(t "Mode")" "${C_BOLD}${MODE}${C_RESET} · $(t "lead %s" "${LEAD_LABEL}")"
  ui_rail_kv "$(t "Profile")" "$(no_rec "$BUDGET_LABEL")"
  if [[ "$BUDGET" == "econome" && "$RISK" == "HIGH" ]]; then
    ui_rail_kv "" "${C_YELLOW}! $(t "HIGH risk with the Frugal profile: use high effort for security on sensitive changes")${C_RESET}"
  fi
  ui_rail_kv "$(t "Routing")" "$(ai_env_label "$ROUTE_ENV")"
  if [[ -n "$ROUTE_NOTE" ]]; then ui_rail_kv "" "${C_YELLOW}! ${ROUTE_NOTE}${C_RESET}"; fi
  ui_rail_kv "$(t "Lead agent")" "${C_BRAND}${LEAD_LINE}${C_RESET}"
  ui_rail_kv "$(t "Execution")" "$EXEC_LINE"
  ui_rail_kv "$(t "Architecture")" "$DEEP_LINE"
  ui_rail ""
  ui_rail_group "$(t "Deliverables")"
  ui_rail_kv "$(t "Docs")" "$DOCLANG_LABEL · START.md : $(no_rec "$HISTORY_LABEL")"
  ui_rail_kv "$(t "Technical name")" "$SLUG ${C_DIM}($(t "folder, technical names"))${C_RESET}"
  if [[ "$GITHUB_REPO" != "no" ]]; then parts="${parts:+$parts + }$(t "GitHub repository %s %s" "$GITHUB_REPO" "$GH_USER/$REPO_NAME")"; fi
  ui_rail_kv "$(t "Git")" "${parts:-$(t "no action")}"
  if [[ -n "$REMOTE_NAME_NOTE" ]]; then
    ui_rail_kv "" "${C_YELLOW}! $REMOTE_NAME_NOTE${C_RESET} ${C_DIM}→ gh repo rename $SLUG${C_RESET}"
  fi
  ui_rail_kv "$(t "AI files")" "$AI_FILES_LABEL${AI_REPO_NAME:+ · $(t "private repository") ${GH_USER:+$GH_USER/}$AI_REPO_NAME}"
  if [[ "$COMMIT" == "yes" && -z "$GIT_REMOTE" ]]; then
    ui_rail_kv "" "${C_DIM}$(t "no remote: push later")${GH_USER:+ (gh repo create --private --source=. --push)}${C_RESET}"
  fi
  if [[ -n "$PLAN_CLAUDE_NEW$PLAN_CODEX_NEW" ]]; then
    ui_rail_kv "$(t "Plans")" "${PLAN_CLAUDE_NEW:+Claude : $PLAN_CLAUDE_NEW_LABEL}${PLAN_CLAUDE_NEW:+${PLAN_CODEX_NEW:+ · }}${PLAN_CODEX_NEW:+Codex : $PLAN_CODEX_NEW_LABEL}"
  fi
  ui_rail ""
}

write_brief() {
  local today commit_txt push_txt lang_txt
  today="$(date +%Y-%m-%d)"
  commit_txt="non — l'utilisateur committe"; [[ "$COMMIT" == "yes" ]] && commit_txt="autorisé après vérification"
  push_txt="non"; [[ "$PUSH" == "yes" ]] && push_txt="autorisé vers ${GIT_REMOTE%% *}"
  lang_txt="anglais"; [[ "$DOCLANG" == "fr" ]] && lang_txt="français"
  {
    echo "---"
    echo "loomy_version: $LOOMY_VERSION"
    echo "created: $today"
    echo "name: $(yaml_q "$NAME")"
    echo "slug: $SLUG"
    echo "goal: $(yaml_q "$GOAL")"
    echo "repo: $REPO"
    echo "type: $TYPE"
    echo "detail1: $(yaml_q "$DETAIL1")"
    echo "detail2: $(yaml_q "$DETAIL2")"
    echo "details: $(yaml_q "$DETAILS")"
    echo "stage: $STAGE"
    echo "sensitive: $(yaml_q "$SENSITIVE")"
    echo "risk: $RISK"
    echo "ai_mode: $MODE"
    echo "ai_lead: $LEAD"
    echo "budget: $BUDGET"
    echo "doc_language: $DOCLANG"
    echo "bootstrap_history: $HISTORY"
    echo "git_init: $GIT_INIT"
    echo "commit_after_setup: $COMMIT"
    echo "push_after_commit: $PUSH"
    echo "ai_files: $AI_FILES"
    echo "github_repo: $GITHUB_REPO"
    echo "repo_name: $REPO_NAME"
    echo "ai_repo_name: $AI_REPO_NAME"
    echo "---"
    echo
    echo "# Brief de démarrage — $NAME"
    echo
    echo "Rempli par \`init-wizard.sh\` le $today. Réponses de l'utilisateur à traiter comme un entretien déjà mené."
    echo
    echo "| Sujet | Réponse |"
    echo "|---|---|"
    echo "| Objectif | ${GOAL:-à préciser} |"
    echo "| Projet | $REPO_LABEL |"
    echo "| Type | $TYPE_LABEL |"
    echo "| Précisions | $DETAILS |"
    echo "| Stade | $STAGE_LABEL |"
    echo "| Éléments sensibles | $SENSITIVE_LABEL |"
    echo "| Risque estimé | $RISK |"
    echo "| Mode IA | $MODE (lead : $LEAD_LABEL) |"
    echo "| Profil modèles | $BUDGET_LABEL |"
    echo "| Langue des docs | $DOCLANG_LABEL |"
    echo "| START.md après init | $HISTORY_LABEL |"
    echo "| Commit initial | $commit_txt |"
    echo "| Push | $push_txt |"
    echo "| Fichiers IA | $AI_FILES_LABEL |"
    echo
    echo "## Consignes pour l'agent"
    echo
    echo "- Considère ces réponses comme acquises : confirme-les en une ligne, ne les redemande pas, et ne pose que les questions encore utiles."
    echo "- Le risque est une estimation : réévalue-le après la découverte et signale tout écart."
    echo "- Applique le profil modèles \`$BUDGET\` dans \`.ai/AI_MODEL_ROUTING.md\`."
    echo "- Rédige la documentation du projet en $lang_txt."
    if [[ "$COMMIT" == "yes" ]]; then
      echo "- Commit initial autorisé en phase 8 si toutes les vérifications passent, sinon arrête-toi et explique."
    else
      echo "- Ne committe pas : laisse les changements prêts et résume-les."
    fi
    if [[ "$PUSH" == "yes" ]]; then
      echo "- Push autorisé vers \`${GIT_REMOTE%% *}\` après le commit initial (jamais de force-push)."
    else
      echo "- Ne pousse rien vers un remote."
    fi
    case "$AI_FILES" in
      local) echo "- Fichiers IA locaux : ne versionne jamais AGENTS.md, CLAUDE.md, .ai/, .claude/, .codex/, .loomy/ ni START.md (jamais de git add -f) ; ils sont exclus via .git/info/exclude." ;;
      private)
        echo "- Fichiers IA dans un dépôt privé séparé : ne les versionne jamais dans le dépôt du projet (jamais de git add -f)."
        echo "- Après chaque étape importante et en fin de session, sauvegarde-les : \`.loomy/scripts/ai-privacy.sh sync\`." ;;
    esac
    echo "- Nom technique du projet : \`$SLUG\`. Utilise-le pour les noms de paquet, de dépôt et les identifiants techniques, pour que tout porte le même nom."
    if [[ -n "$REMOTE_NAME_NOTE" ]]; then echo "- Attention : $REMOTE_NAME_NOTE. Signale-le à l'utilisateur ; ne renomme rien sans son accord (gh repo rename $SLUG)."; fi
    echo "- Mets à jour l'avancement avec \`.loomy/scripts/ai-status.sh set <phase>\`."
  } >"$BRIEF"
}


# ---------------------------------------------------------------- programme principal
ui_clear
ui_banner "$(t "Startup brief")" "v$LOOMY_VERSION · Codex + Claude Code · $TARGET"
DETECTED_REPO="new"
env_check

if [[ -f "$BRIEF" && -z "$ANSWERS_FILE" ]] && ui_is_interactive; then
  ui_print ""
  UI_LABEL="$(t "Existing brief")"
  choose_coded REDO "A brief already exists. What now?" "redo" "Its answers become the defaults if you redo it." \
    "redo|Redo it|The file is only replaced at the end, after you confirm." \
    "keep|Keep it and quit|Nothing is changed."
  if [[ "$REDO" == "keep" ]]; then ui_ok "$(t "Brief kept")" "$BRIEF"; exit 0; fi
fi

plan_questions
FORM_GROUPS="$(t "PROJECT")|$(t "REQUIREMENTS")|$(t "AI TEAM")|$(t "DELIVERABLES")"
if (( TOTAL == 13 )); then FORM_GROUPS="$FORM_GROUPS|$(t "PLANS")"; fi
while true; do
  # Plein écran pendant les questions ; ← rejoue la passe jusqu'à la question précédente.
  ui_form_begin "v$LOOMY_VERSION · $(t "startup brief") · ${C_RESET}${C_TITLE}$(basename "$TARGET")${C_RESET}" "$FORM_GROUPS"
  while true; do
    ui_form_pass
    ask_all
    ui_form_again || break
  done
  ui_form_end
  show_recap
  save_desc="Écrit .loomy/brief.md."
  [[ "$GIT_INIT" == "yes" ]] && save_desc="Écrit .loomy/brief.md et initialise le dépôt Git (branche main)."
  [[ "$GITHUB_REPO" != "no" ]] && save_desc="$save_desc Crée le dépôt GitHub $GH_USER/$REPO_NAME ($GITHUB_REPO)."
  [[ "$AI_FILES" == "private" ]] && save_desc="$save_desc Crée le dépôt privé ${GH_USER:+$GH_USER/}$AI_REPO_NAME pour les fichiers IA."
  UI_LABEL="$(t "Brief")"
  choose_coded CONFIRM "Save this brief?" "save" "Nothing is written before you confirm." \
    "save|Yes, save|\$save_desc" \
    "again|Review the questions|Your current answers become the defaults." \
    "cancel|Cancel|No file written, no Git action."
  case "$CONFIRM" in
    save) break ;;
    cancel) ui_rail_end "Annulé : aucun fichier écrit."; exit 1 ;;
    again)
      A_name="$NAME"; A_goal="$GOAL"; A_repo="$REPO"; A_type="$TYPE"
      A_detail1="$DETAIL1"; A_detail2="$DETAIL2"; A_stage="$STAGE"; A_sensitive="$SENSITIVE"
      A_ai_mode="$MODE"; A_ai_lead="$LEAD"; A_budget="$BUDGET"; A_doc_language="$DOCLANG"
      A_bootstrap_history="$HISTORY"; A_git_init="$GIT_INIT"; A_commit_after_setup="$COMMIT"; A_push_after_commit="$PUSH"; A_ai_files="$AI_FILES"; A_github_repo="$GITHUB_REPO"; A_repo_name="$REPO_NAME"; A_ai_repo_name="$AI_REPO_NAME" ;;
  esac
done

# ---------------------------------------------------------------- mise en place, en direct
steps=()
[[ "$GIT_INIT" == "yes" ]] && steps+=("$(t "Initialising the Git repository")")
[[ "$GITHUB_REPO" != "no" && -n "$GH_USER" ]] && steps+=("$(t "Creating the GitHub repository")")
steps+=("$(t "Saving the brief")")
[[ "$AI_FILES" != "versioned" ]] && steps+=("$(t "Setting up AI files")")
[[ -n "$PLAN_CLAUDE_NEW$PLAN_CODEX_NEW" ]] && steps+=("$(t "Saving the plans")")
steps+=("$(t "Preparing the session")")
ui_steps_begin "$(t "SETUP")" "${steps[@]}"
st=0
if [[ "$GIT_INIT" == "yes" ]]; then
  ui_step_run $st
  if git -C "$TARGET" init -q -b main; then ui_step_done $st ok "$(t "Git repository initialised")" "$(t "main branch")"
  else ui_step_done $st fail "$(t "Git repository not initialised")" "$(t "git init failed")"; fi
  st=$(( st + 1 ))
fi
GH_FAIL=""
if [[ "$GITHUB_REPO" != "no" && -n "$GH_USER" ]]; then
  ui_step_run $st
  if gh_err="$(cd "$TARGET" && gh repo create "$REPO_NAME" "--$GITHUB_REPO" --source=. --remote=origin 2>&1 >/dev/null)"; then
    ui_step_done $st ok "$(t "GitHub repository created")" "$GH_USER/$REPO_NAME · $( [[ "$GITHUB_REPO" == "private" ]] && t "private" || t "public")"
  else
    GH_FAIL="$(printf '%s' "$gh_err" | tail -1)"
    ui_step_done $st warn "$(t "GitHub repository not created")" "$GH_FAIL"
    GITHUB_REPO="no"
  fi
  st=$(( st + 1 ))
fi
ui_step_run $st
write_brief
ui_step_done $st ok "$(t "Brief saved")" "${BRIEF#"$TARGET"/}"
st=$(( st + 1 ))
AI_FAIL=0
if [[ "$AI_FILES" != "versioned" ]]; then
  ui_step_run $st
  if bash "$SCRIPT_DIR/ai-privacy.sh" --root "$TARGET" apply --quiet </dev/null >/dev/null 2>&1; then
    ui_step_done $st ok "$(t "AI files set up")" "$( [[ "$AI_FILES" == "local" ]] && t "local, outside Git" || t "separate private repository")"
  else
    AI_FAIL=1; ui_step_done $st warn "$(t "AI files: setup incomplete")" "loomy privacy $AI_FILES"
  fi
  st=$(( st + 1 ))
fi
if [[ -n "$PLAN_CLAUDE_NEW$PLAN_CODEX_NEW" ]]; then
  ui_step_run $st
  [[ -n "$PLAN_CLAUDE_NEW" ]] && loomy_config_set plan_claude "$PLAN_CLAUDE_NEW"
  [[ -n "$PLAN_CODEX_NEW" ]] && loomy_config_set plan_codex "$PLAN_CODEX_NEW"
  ui_step_done $st ok "$(t "Plans saved")" "$(loomy_config_file | sed "s|^$HOME|~|")"
  st=$(( st + 1 ))
fi
ui_step_run $st
PROMPT="$(ai_start_prompt "$MODE" "$LEAD")"
if [[ -x "$SCRIPT_DIR/ai-status.sh" ]]; then
  # Premier brief : la phase passe à Découverte. Brief refait en cours de route : la phase en cours est conservée.
  current_phase="$(sed -n 's/^phase=//p' "$TARGET/.loomy/state" 2>/dev/null | head -1 || true)"
  if [[ -z "$current_phase" || "$current_phase" == "brief" ]]; then
    "$SCRIPT_DIR/ai-status.sh" --root "$TARGET" set discover >/dev/null 2>&1 || true
  fi
fi
ui_step_done $st ok "$(t "Session ready")" "$(t "Discovery phase")"
ui_steps_end
if [[ -n "$GH_FAIL" ]]; then ui_rail "   ${C_DIM}$(t "GitHub repository by hand:") gh repo create $REPO_NAME --private --source=. --remote=origin${C_RESET}"; fi

LEAD_CMD="$(ai_lead_command "$ROUTE_ENV" "$BUDGET")"
ui_rail ""
ui_rail_group "$(t "Next step")"
step=1
# Projet créé ailleurs que dans le dossier d'où loomy init a été lancé : il faut s'y rendre.
from="${LOOMY_INVOKED_FROM:-$TARGET}"
if [[ "$(cd "$from" 2>/dev/null && pwd -P)" != "$(cd "$TARGET" && pwd -P)" ]]; then
  rel="${TARGET#"$from"/}"; [[ "$rel" == "$TARGET" ]] && rel="${TARGET/#$HOME/~}"
  ui_rail "${C_BRAND}${step}${C_RESET}  $(t "Go to the project folder:") ${C_BOLD}cd $rel${C_RESET}"
  ui_rail ""
  step=$(( step + 1 ))
fi
if command -v loomy >/dev/null 2>&1; then
  ui_rail "${C_BRAND}${step}${C_RESET}  $(t "Open the orchestrator session:") ${C_BOLD}loomy start${C_RESET}"
  ui_rail "   ${C_DIM}$(t "or by hand: %s, then paste the startup prompt" "${LEAD_CMD}")${C_RESET}"
else
  ui_rail "${C_BRAND}${step}${C_RESET}  $(t "Launch the orchestrator at the project root:")"
  ui_rail "   ${C_BOLD}${LEAD_CMD}${C_RESET}"
  ui_rail "   $(t "then paste the startup prompt:")"
  _ui_term_size
  _ui_wrap "$PROMPT" $(( UI_W - 8 ))
  for line in ${UI_LINES[@]+"${UI_LINES[@]}"}; do ui_rail "   ${C_DIM}${line}${C_RESET}"; done
fi
if [[ "${ROUTE_ENV#hybrid-}" == "codex" ]]; then
  ui_rail "   ${C_DIM}($(t "or in the Codex app: model %s, effort %s" "${LEAD_LINE%% *}" "${LEAD_LINE##*(}"))${C_RESET}"
fi
if (( USE_CLIPBOARD )) && ui_is_interactive && ui_copy "$PROMPT"; then
  ui_rail "   ${C_GREEN}✓${C_RESET} ${C_DIM}$(t "startup prompt copied to the clipboard")${C_RESET}"
fi
step=$(( step + 1 ))
ui_rail ""
ui_rail "${C_BRAND}${step}${C_RESET}  $(t "Follow progress live in another terminal:")"
if command -v loomy >/dev/null 2>&1; then
  ui_rail "   ${C_BOLD}loomy watch${C_RESET}"
else
  ui_rail "   ${C_BOLD}.loomy/scripts/ai-status.sh --watch${C_RESET}"
fi

# Proposer d'ouvrir tout de suite la session, dans le dossier du projet (sans cd).
if ui_is_interactive && [[ -x "$SCRIPT_DIR/ai-start.sh" ]]; then
  ui_rail ""
  UI_LABEL="$(t "Session")"
  UI_DESCS=("$(t "Opens the orchestrator now, in the project folder, with the startup prompt.")" "$(t "You can start it later with loomy start, from the project folder.")")
  ui_choose "$(t "Open the orchestrator session now?")" 0 "$(t "Yes, now")" "$(t "Later")"
  if [[ "$UI_INDEX" == "0" ]]; then
    ui_exec bash "$SCRIPT_DIR/ai-start.sh" --root "$TARGET" --new
  fi
fi
ui_rail_end "$(t "routing: loomy route · diagnostics: loomy doctor --live · log: loomy log")"

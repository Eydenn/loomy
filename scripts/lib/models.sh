#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: AI_* and R_* are read by the scripts that source it
# Model catalog and role routing for Loomy.
# To be sourced, not executed. Bash 3.2 compatible.
#
# Catalog checked on 2026-09-23 (see docs/MODEL_CATALOG.md for the analysis and sources).
# When models change, update the AI_CHAIN_* values below and the minimum CLI versions;
# every script, generated agent and routing table follows automatically.
# Each value can be overridden per machine or per call through the environment.

# Numbers in C format (decimal point) whatever the system language: awk and printf read and write
# costs with a point. The rest of the locale (UTF-8, messages) is kept.
# Translated strings (t): the language layer is loaded if the script hasn't done it already.
if ! declare -F t >/dev/null 2>&1; then
  # shellcheck source=i18n.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
fi

if [[ -n "${LC_ALL:-}" ]]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C
# Text: without a UTF-8 locale, bash would split accented characters in two. We pick one if needed.
_ui_probe="é"
if [[ ${#_ui_probe} != 1 ]]; then
  # List read first: with pipefail, "locale -a | grep -q" would fail (grep closes the pipe as soon as it matches).
  _locs="$(locale -a 2>/dev/null || true)"
  for _l in C.UTF-8 en_US.UTF-8 fr_FR.UTF-8; do
    if grep -qixE "${_l/UTF-8/utf-?8}" <<<"$_locs"; then export LC_CTYPE="$_l"; break; fi
  done
fi
unset _ui_probe _l _locs

AI_CATALOG_DATE="2026-09-23"
AI_CATALOG_SOURCE="built-in"
AI_PRICES_EXTRA=""   # downloaded catalog prices: "model=input output cache;…"
AI_ROUTE_EXTRA=""    # downloaded catalog routing: "family:role=TIER effort;…"

# Model chains per tier: the first model available on this machine is used, the next ones are
# fallbacks (not everyone has access to the latest models). The downloaded catalog can replace them.
AI_CHAIN_CLAUDE_TOP="claude-opus-5-5"                # best reasoning, agentic coding, office work
AI_CHAIN_CLAUDE_MID="claude-sonnet-5"                # travail courant
AI_CHAIN_CLAUDE_FAST="claude-haiku-4-5"              # research, summaries
AI_CHAIN_CODEX_TOP="gpt-6-astra"                     # frontier reasoning, computer use
AI_CHAIN_CODEX_MID="gpt-6-sol"                       # workhorse, workflows
AI_CHAIN_CODEX_FAST="gpt-6-luna"                     # cheapest capable executor

# Downloaded catalog (loomy update --catalog): used when newer than the one shipped with Loomy.
# Read line by line, never executed. Recognised lines (see catalog/models.conf and docs/MODEL_CATALOG.md):
#   model.<claude|codex>.<top|mid|fast>=<model>[, <fallback>…]
#   price.<model>=<input> <output> <cache-read>
#   route.<claude|codex>.<role>=<TOP|MID|FAST> <effort>
ai_catalog_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/catalog.conf"; }
_ai_catalog_load() {
  local f="$1" line k v d
  [[ -f "$f" ]] || return 0
  d="$(sed -n 's/^date=\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)$/\1/p' "$f" | head -1)"
  [[ -n "$d" && "$d" > "$AI_CATALOG_DATE" ]] || return 0
  AI_CATALOG_DATE="$d"; AI_CATALOG_SOURCE="downloaded"
  while IFS= read -r line; do
    if [[ "$line" =~ ^model\.(claude|codex)\.(top|mid|fast)=([A-Za-z0-9][A-Za-z0-9._,\ -]*)$ ]]; then
      k="$(printf '%s' "${BASH_REMATCH[1]}_${BASH_REMATCH[2]}" | tr 'a-z' 'A-Z')"
      v="$(printf '%s' "${BASH_REMATCH[3]}" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
      # Every model id starts with a letter or digit (never an option for the CLIs).
      [[ " $v" == *" -"* ]] && continue
      [[ -n "$v" ]] && eval "AI_CHAIN_${k}=\"\$v\""
    elif [[ "$line" =~ ^price\.([A-Za-z0-9][A-Za-z0-9._-]*)=([0-9.]+\ [0-9.]+\ [0-9.]+)$ ]]; then
      AI_PRICES_EXTRA="${AI_PRICES_EXTRA}${BASH_REMATCH[1]}=${BASH_REMATCH[2]};"
    elif [[ "$line" =~ ^route\.(claude|codex)\.([a-z]+)=(TOP|MID|FAST)\ (low|medium|high|xhigh|max)$ ]]; then
      AI_ROUTE_EXTRA="${AI_ROUTE_EXTRA}${BASH_REMATCH[1]}:${BASH_REMATCH[2]}=${BASH_REMATCH[3]} ${BASH_REMATCH[4]};"
    fi
  done <"$f"
}
_ai_catalog_load "$(ai_catalog_file)"

# Model availability on this machine (~/.config/loomy/models.state, "model=ok|ko"): written by
# loomy doctor --live and by the bridges when a model is refused. Codex: its local model list is authoritative.
ai_models_state_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/models.state"; }
ai_model_mark() {
  local f; f="$(ai_models_state_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  { grep -v "^$1=" "$f" 2>/dev/null || true; echo "$1=$2"; } >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  return 0
}
ai_model_usable() {
  local m="$1" fam="$2" cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  grep -qx "$m=ko" "$(ai_models_state_file)" 2>/dev/null && return 1
  if [[ "$fam" == "codex" && -f "$cache" ]] && ! grep -qF "\"$m\"" "$cache"; then return 1; fi
  return 0
}
# ai_model_pick <family> <tier>: first available model of the chain (the chain's first when none is).
ai_model_pick() {
  local chain m fam="$1" k
  k="$(printf '%s' "${1}_${2}" | tr 'a-z' 'A-Z')"
  eval "chain=\"\${AI_CHAIN_${k}:-}\""
  for m in $chain; do ai_model_usable "$m" "$fam" && { echo "$m"; return 0; }; done
  echo "${chain%% *}"
}
# ai_model_next <family> <model>: next fallback in its chain (empty when there is none), for the bridges.
ai_model_next() {
  local fam="$1" m="$2" t chain seen c k
  for t in TOP MID FAST; do
    k="$(printf '%s' "$fam" | tr 'a-z' 'A-Z')_$t"
    eval "chain=\"\${AI_CHAIN_${k}:-}\""
    seen=0
    for c in $chain; do
      if (( seen )) && ai_model_usable "$c" "$fam"; then echo "$c"; return 0; fi
      [[ "$c" == "$m" ]] && seen=1
    done
    (( seen )) && return 0
  done
  return 0
}

# Model of each tier: AI_MODEL_* environment variable, otherwise the pinned model (loomy config set
# model.<family>.<tier> <model>), otherwise the first available model of the chain.
_ai_pin() {
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config"
  [[ -f "$f" ]] || return 0
  sed -n "s/^model\\.$1\\.$2=\\([A-Za-z0-9][A-Za-z0-9._-]*\\)$/\\1/p" "$f" 2>/dev/null | head -1 || true
}
for _f in claude codex; do
  for _t in top mid fast; do
    _k="$(printf '%s' "${_f}_${_t}" | tr 'a-z' 'A-Z')"
    eval "_cur=\"\${AI_MODEL_${_k}:-}\""
    [[ -z "$_cur" ]] && _cur="$(_ai_pin "$_f" "$_t")"
    [[ -z "$_cur" ]] && _cur="$(ai_model_pick "$_f" "$_t")"
    eval "AI_MODEL_${_k}=\"\$_cur\""
  done
done
unset _f _t _k _cur

AI_MIN_CLAUDE_VERSION="2.1.280"  # first Claude Code version accepting claude-opus-5-5
AI_MIN_CODEX_VERSION="0.155.0"   # Codex CLI version checked with the gpt-6-* models

# Public prices in $ per million tokens: "input output cache-read" (checked on 2026-09-23).
# Used to estimate the cost when the tool doesn't report it (Codex).
ai_price() {
  # Downloaded catalog prices first (model prefix, as below).
  local e
  local IFS=';'
  for e in $AI_PRICES_EXTRA; do
    [[ -n "$e" && "$1" == "${e%%=*}"* ]] && { echo "${e#*=}"; return 0; }
  done
  case "$1" in
    claude-opus-5-5*) echo "4 20 0.20" ;;
    claude-sonnet-5*) echo "2 10 0.20" ;;
    claude-haiku-4-5*) echo "1 5 0.10" ;;
    gpt-6-astra*) echo "10 50 1.00" ;;
    gpt-6-sol*) echo "2 10 0.20" ;;
    gpt-6-luna*) echo "0.10 0.50 0.01" ;;
    *) echo "" ;;
  esac
}

AI_ROLES="lead architect debugger security reviewer developer executor explorer documenter"
AI_EFFORTS="low medium high xhigh max ultra"

ai_role_label() {
  case "$1" in
    lead) t "Lead agent"; echo ;; architect) t "Architect"; echo ;; debugger) t "Debugger"; echo ;;
    security) t "Security"; echo ;; reviewer) t "Reviewer"; echo ;; developer) t "Developer"; echo ;;
    executor) t "Executor"; echo ;; explorer) t "Explorer"; echo ;; documenter) t "Documenter"; echo ;;
    *) echo "$1" ;;
  esac
}

ai_role_scope() {
  case "$1" in
    lead) t "plan, breakdown, delegation, decisions, integration, final check"; echo ;;
    architect) t "architecture, specs, ADRs, trade-offs"; echo ;;
    debugger) t "hard bugs, long terminal tasks, migrations"; echo ;;
    security) t "targeted security review (auth, payments, data, secrets)"; echo ;;
    reviewer) t "diff review: regressions, edge cases, missing tests"; echo ;;
    developer) t "everyday features and fixes within a given scope"; echo ;;
    executor) t "precise, bounded tickets, tests, bulk changes"; echo ;;
    explorer) t "code search, mapping, summaries, logs"; echo ;;
    documenter) t "README, docs, changelogs"; echo ;;
  esac
}

# Roles that modify files when delegated (the others are read-only).
ai_role_writes() {
  case "$1" in executor|developer|documenter) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- outils

# Resolves symlinks so that the helper programs next to the real binary stay reachable (bash 3.2, no readlink -f).
_ai_realpath() {
  local p="$1" link
  while [[ -L "$p" ]]; do
    link="$(readlink "$p")"
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
  done
  echo "$p"
}

# Codex CLI: the PATH first (links resolved), then the binaries shipped with the desktop apps.
ai_codex_bin() {
  # LOOMY_CODEX_BIN: explicit Codex CLI path (unusual install); if it isn't executable, Codex is considered missing.
  if [[ -n "${LOOMY_CODEX_BIN:-}" ]]; then
    if [[ -x "$LOOMY_CODEX_BIN" ]]; then echo "$LOOMY_CODEX_BIN"; return 0; fi
    return 1
  fi
  if command -v codex >/dev/null 2>&1; then _ai_realpath "$(command -v codex)"; return 0; fi
  local p
  for p in /Applications/Codex.app/Contents/Resources/codex /Applications/ChatGPT.app/Contents/Resources/codex; do
    if [[ -x "$p" ]]; then echo "$p"; return 0; fi
  done
  return 1
}

ai_has_claude() { command -v claude >/dev/null 2>&1; }
ai_has_codex() { ai_codex_bin >/dev/null 2>&1; }

ai_claude_version() { claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
ai_codex_version() { "$(ai_codex_bin)" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

# ai_version_ge <a> <b>: true when version a >= b (numeric x.y.z).
ai_version_ge() {
  local a="$1" b="$2" i x y
  local IFS=.
  # shellcheck disable=SC2206
  local va=($a) vb=($b)
  for i in 0 1 2; do
    x="${va[$i]:-0}"; y="${vb[$i]:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}

# Claude CLI alias used when an old CLI refuses an explicit model id.
ai_claude_alias() {
  case "$1" in *opus*) echo "opus" ;; *sonnet*) echo "sonnet" ;; *haiku*) echo "haiku" ;; *) echo "$1" ;; esac
}

# ---------------------------------------------------------------- routage

# ai_effort_shift <effort> <delta> <cap>
ai_effort_shift() {
  local effort="$1" delta="$2" cap="$3" idx=0 capidx=5 i=0 e
  for e in $AI_EFFORTS; do
    [[ "$e" == "$effort" ]] && idx=$i
    [[ "$e" == "$cap" ]] && capidx=$i
    i=$(( i + 1 ))
  done
  idx=$(( idx + delta ))
  (( idx < 0 )) && idx=0
  (( idx > capidx )) && idx=$capidx
  i=0
  for e in $AI_EFFORTS; do
    if (( i == idx )); then echo "$e"; return 0; fi
    i=$(( i + 1 ))
  done
}

# Tool family running a role in a given environment.
#   claude | codex                   : single tool, everything runs on it
#   hybrid-claude | hybrid-codex     : both tools, the main tool is named after "hybrid-"
ai_family_for_role() {
  local role="$1" env="$2" lead other
  case "$env" in
    claude|codex) echo "$env"; return 0 ;;
  esac
  lead="${env#hybrid-}"
  other="claude"; [[ "$lead" == "claude" ]] && other="codex"
  case "$role" in
    lead|explorer|developer|documenter) echo "$lead" ;;       # on the main tool: no bridge cost
    architect|security|debugger) echo "claude" ;;             # Opus 5.5 leads on reasoning, terminal and office work
    executor) echo "codex" ;;                                 # GPT-6-Luna max: best quality/price on bounded code tasks
    reviewer) echo "$other" ;;                                # cross-family review, for independence
  esac
}

# Matrice de base (profil "equilibre") : "<NIVEAU> <effort>".
_ai_base() {
  # Downloaded catalog routing first (rebalancing without a new Loomy version).
  local e
  local IFS=';'
  for e in $AI_ROUTE_EXTRA; do [[ "${e%%=*}" == "$1:$2" ]] && { echo "${e#*=}"; return 0; }; done
  case "$1:$2" in
    claude:lead|claude:architect|claude:debugger|claude:security) echo "TOP high" ;;
    claude:reviewer) echo "MID high" ;;
    claude:developer|claude:executor) echo "MID medium" ;;
    claude:explorer) echo "FAST low" ;;
    claude:documenter) echo "MID low" ;;
    codex:lead|codex:architect|codex:security) echo "TOP high" ;;
    codex:debugger) echo "MID xhigh" ;;
    codex:reviewer|codex:developer) echo "MID high" ;;
    codex:executor) echo "FAST max" ;;
    codex:explorer) echo "FAST low" ;;
    codex:documenter) echo "MID low" ;;
  esac
}

# ai_route <role> <family> <profile>
# Sets R_FAMILY R_TIER R_MODEL R_EFFORT for a role on a given tool family.
ai_route() {
  local role="$1" family="$2" profile="${3:-equilibre}" base tier effort cap
  base="$(_ai_base "$family" "$role")"
  tier="${base%% *}"; effort="${base##* }"
  case "$profile" in
    econome)
      case "$role" in
        lead|architect|security|debugger) effort="$(ai_effort_shift "$effort" -1 max)" ;;
        reviewer|developer) [[ "$effort" == "high" || "$effort" == "xhigh" ]] && effort="$(ai_effort_shift "$effort" -1 max)" ;;
      esac ;;
    qualite)
      case "$role" in
        lead|architect|security) effort="$(ai_effort_shift "$effort" 1 max)" ;;
        debugger)
          if [[ "$family" == "codex" ]]; then tier="TOP"; effort="xhigh"
          else effort="$(ai_effort_shift "$effort" 1 max)"; fi ;;
        reviewer) tier="TOP"; effort="high" ;;
        developer)
          if [[ "$family" == "claude" ]]; then tier="TOP"; effort="medium"
          else effort="$(ai_effort_shift "$effort" 1 max)"; fi ;;
        executor)
          if [[ "$family" == "claude" ]]; then effort="high"
          else tier="MID"; effort="high"; fi ;;
        explorer) effort="medium" ;;
      esac ;;
  esac
  cap="max"
  effort="$(ai_effort_shift "$effort" 0 "$cap")"
  # Effort set for this project (loomy effort): takes priority over the profile.
  R_EFFORT_SET=0
  local o
  for o in ${AI_OVERRIDES:-}; do
    if [[ "${o%%=*}" == "$role" ]]; then effort="${o#*=}"; R_EFFORT_SET=1; fi
  done
  case "$family:$tier" in
    claude:TOP) R_MODEL="$AI_MODEL_CLAUDE_TOP" ;;
    claude:MID) R_MODEL="$AI_MODEL_CLAUDE_MID" ;;
    claude:FAST) R_MODEL="$AI_MODEL_CLAUDE_FAST" ;;
    codex:TOP) R_MODEL="$AI_MODEL_CODEX_TOP" ;;
    codex:MID) R_MODEL="$AI_MODEL_CODEX_MID" ;;
    codex:FAST) R_MODEL="$AI_MODEL_CODEX_FAST" ;;
  esac
  R_FAMILY="$family"; R_TIER="$tier"; R_EFFORT="$effort"
}

# ai_resolve <role> <env> <profile>: routes a role in an environment. Also sets R_VIA.
ai_resolve() {
  local role="$1" env="$2" profile="$3" family lead
  family="$(ai_family_for_role "$role" "$env")"
  ai_route "$role" "$family" "$profile"
  lead="${env#hybrid-}"
  if [[ "$role" == "lead" ]]; then
    R_VIA="$(t "main session")"
  elif [[ "$family" == "claude" && "$lead" == "claude" ]]; then
    R_VIA="$(t "subagent %s" ".claude/agents/$role.md")"
  elif [[ "$family" == "claude" ]]; then
    R_VIA="delegate-to-claude.sh $role"
  else
    R_VIA="delegate-to-codex.sh $role"
  fi
}

# Launch command of the main session (lead agent).
ai_lead_command() {
  local env="$1" profile="$2"
  ai_resolve lead "$env" "$profile"
  if [[ "$R_FAMILY" == "claude" ]]; then
    echo "claude --model $R_MODEL --effort $R_EFFORT"
  else
    echo "codex -m $R_MODEL -c model_reasoning_effort=$R_EFFORT"
  fi
}

# ---------------------------------------------------------------- environment detection

_ai_brief_get() {
  local brief="$1" key="$2"
  [[ -f "$brief" ]] || return 0
  # Control characters removed: a brief can come from a cloned repository, its values must not drive the terminal.
  sed -n '/^---$/,/^---$/p' "$brief" | sed -n "s/^$key:[[:space:]]*//p" | head -1 | sed 's/^"//; s/"$//' | LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# ai_env_for <mode> <lead>: works out the environment from the mode, the requested main tool and the installed tools.
# Sets AI_ENV and AI_ENV_NOTE (explanation of the fallback, possibly empty).
ai_env_for() {
  local mode="${1:-SOLO}" lead="$2" has_c=0 has_x=0 other lead_ok other_ok
  ai_has_claude && has_c=1
  ai_has_codex && has_x=1
  if [[ -z "$lead" ]]; then
    if (( has_c )); then lead="claude"; elif (( has_x )); then lead="codex"; else lead="claude"; fi
  fi
  other="codex"; [[ "$lead" == "codex" ]] && other="claude"
  if [[ "$lead" == "claude" ]]; then lead_ok=$has_c; other_ok=$has_x; else lead_ok=$has_x; other_ok=$has_c; fi
  AI_ENV_NOTE=""
  case "$mode" in
    HYBRID|ORCHESTRATED|PARALLEL)
      if (( lead_ok && other_ok )); then AI_ENV="hybrid-$lead"
      elif (( lead_ok )); then AI_ENV="$lead"; AI_ENV_NOTE="$(t "%s mode requested but %s is missing: falling back to full %s" "$mode" "$other" "$lead")"
      elif (( other_ok )); then AI_ENV="$other"; AI_ENV_NOTE="$(t "%s lead missing: falling back to full %s" "$lead" "$other")"
      else AI_ENV="$lead"; AI_ENV_NOTE="$(t "no AI CLI detected: theoretical matrix")"; fi ;;
    *)
      if (( lead_ok )); then AI_ENV="$lead"
      elif (( other_ok )); then AI_ENV="$other"; AI_ENV_NOTE="$(t "%s lead missing: falling back to full %s" "$lead" "$other")"
      else AI_ENV="$lead"; AI_ENV_NOTE="$(t "no AI CLI detected: theoretical matrix")"; fi ;;
  esac
}

# ai_detect_env <racine-du-projet>
# Reads mode, main tool and budget from .loomy/brief.md and sets AI_ENV, AI_ENV_NOTE, AI_PROFILE, AI_MODE, AI_LEAD.
# Honours the AI_ROUTE_ENV / AI_ROUTE_PROFILE overrides.
ai_detect_env() {
  local root="$1" brief
  brief="$root/.loomy/brief.md"
  AI_MODE="$(_ai_brief_get "$brief" ai_mode)"; AI_MODE="${AI_MODE:-SOLO}"
  AI_LEAD="$(_ai_brief_get "$brief" ai_lead)"
  AI_PROFILE="${AI_ROUTE_PROFILE:-$(_ai_brief_get "$brief" budget)}"
  AI_PROFILE="${AI_PROFILE:-equilibre}"
  ai_env_for "$AI_MODE" "$AI_LEAD"
  if [[ -n "${AI_ROUTE_ENV:-}" ]]; then AI_ENV="$AI_ROUTE_ENV"; AI_ENV_NOTE=""; fi
  # Efforts set for this project (.loomy/efforts, one "role=effort" line): see loomy effort.
  AI_OVERRIDES="$(grep -E '^[a-z]+=(low|medium|high|xhigh|max)$' "$root/.loomy/efforts" 2>/dev/null | tr '\n' ' ' || true)"
}

ai_env_label() {
  case "$1" in
    claude) t "Full Claude Code"; echo ;; codex) t "Full Codex"; echo ;;
    hybrid-claude) t "Hybrid, Claude Code lead"; echo ;; hybrid-codex) t "Hybrid, Codex lead"; echo ;;
    *) echo "$1" ;;
  esac
}

ai_profile_label() {
  case "$1" in econome) t "Thrifty"; echo ;; equilibre) t "Balanced"; echo ;; qualite) t "Max quality"; echo ;; *) echo "$1" ;; esac
}

# ai_start_prompt <mode> <lead>: bootstrap startup prompt for the lead agent (questionnaire and loomy start).
ai_start_prompt() {
  local MODE="${1:-SOLO}" LEAD="${2:-claude}"
  local p
  p="$(t "Set up this project by strictly following START.md. The starting brief is in .loomy/brief.md: use it as answers already given, confirm it and only ask the missing questions. You are the lead agent: delegate each role according to .loomy/scripts/ai-route.sh. Stay in analysis/plan mode until I approve.")"
  case "$MODE" in
    ORCHESTRATED)
      if [[ "$LEAD" == "codex" ]]; then p="$p $(t "Codex leads; delegate architecture, security and hard debugging to Claude via delegate-to-claude.sh, only when it adds real value.")"
      else p="$p $(t "Claude Code leads; delegate bounded execution and cross review to Codex via delegate-to-codex.sh.")"; fi ;;
    HYBRID) p="$p $(t "Set up the HYBRID Codex + Claude Code mode without multiplying agents.")" ;;
    PARALLEL) p="$p $(t "Plan the PARALLEL mode with separate worktrees and a clear split of responsibilities.")" ;;
  esac
  printf '%s' "$p"
}

# ai_project_root: root of the nearest Loomy project (folder containing .loomy, walking up from the current folder),
# otherwise the Git root, otherwise the current folder. A Loomy project can thus live in a subfolder of a repository.
ai_project_root() {
  local d
  # Run by a project relay (.loomy/scripts/*.sh): the relay gives the project.
  if [[ -n "${LOOMY_PROJECT_ROOT:-}" && -d "$LOOMY_PROJECT_ROOT/.loomy" ]]; then echo "$LOOMY_PROJECT_ROOT"; return 0; fi
  d="$(pwd -P)"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.loomy" && ( -f "$d/.loomy/VERSION" || -f "$d/.loomy/brief.md" ) ]]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# loomy_slug <name>: technical id of the project (lowercase, no accents or spaces). It names the folder
# created by loomy init, the GitHub repository and the private AI files repository: one name everywhere.
loomy_slug() {
  local s=""
  # Accents removed: perl (Unicode::Normalize, shipped with perl), otherwise iconv, otherwise the text as is.
  if command -v perl >/dev/null 2>&1; then
    s="$(printf '%s' "$1" | perl -CS -MUnicode::Normalize -pe '$_ = NFD($_); s/\pM//g' 2>/dev/null || true)"
  fi
  if [[ -z "$s" ]] && command -v iconv >/dev/null 2>&1; then s="$(printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || true)"; fi
  [[ -n "$s" ]] || s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^[-.]+//; s/[-.]+$//')"
  echo "${s:-my-project}"
}

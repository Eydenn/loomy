#!/usr/bin/env bash
# shellcheck disable=SC2034  # bibliothèque : AI_* et R_* sont lus par les scripts qui la chargent
# Catalogue des modèles et routage des rôles pour Loomy.
# À charger (source), pas à exécuter. Compatible bash 3.2.
#
# Catalogue vérifié le 23/09/2026 (voir docs/MODEL_CATALOG.md pour l'analyse et les sources).
# Quand les modèles changent, mettez à jour les six valeurs AI_MODEL_* ci-dessous et les versions minimales des CLI ;
# tous les scripts, agents générés et tableaux de routage suivent automatiquement.
# Chaque valeur peut être surchargée par machine ou par appel via l'environnement.

# Nombres au format C (point décimal) quelle que soit la langue du système : awk et printf lisent et écrivent
# les coûts avec un point. Le reste de la locale (UTF-8, messages) est conservé.
if [[ -n "${LC_ALL:-}" ]]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C

AI_CATALOG_DATE="2026-09-23"

: "${AI_MODEL_CLAUDE_TOP:=claude-opus-5-5}"    # meilleur raisonnement, code agentique, travail de bureau
: "${AI_MODEL_CLAUDE_MID:=claude-sonnet-5}"    # travail courant
: "${AI_MODEL_CLAUDE_FAST:=claude-haiku-4-5}"  # recherche, résumés
: "${AI_MODEL_CODEX_TOP:=gpt-6-astra}"         # raisonnement de pointe, pilotage d'interfaces
: "${AI_MODEL_CODEX_MID:=gpt-6-sol}"           # cheval de trait, workflows
: "${AI_MODEL_CODEX_FAST:=gpt-6-luna}"         # exécutant capable le moins cher

AI_MIN_CLAUDE_VERSION="2.1.280"  # première version de Claude Code qui accepte claude-opus-5-5
AI_MIN_CODEX_VERSION="0.155.0"   # version de la CLI Codex vérifiée avec les modèles gpt-6-*

# Prix publics en $ par million de tokens : "entrée sortie lecture-cache" (vérifiés le 23/09/2026).
# Servent à estimer le coût quand l'outil ne le rapporte pas (Codex).
ai_price() {
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
    lead) echo "Orchestrateur (lead)" ;; architect) echo "Architecte" ;; debugger) echo "Débogueur" ;;
    security) echo "Sécurité" ;; reviewer) echo "Relecteur" ;; developer) echo "Développeur" ;;
    executor) echo "Exécutant" ;; explorer) echo "Explorateur" ;; documenter) echo "Documentaliste" ;;
    *) echo "$1" ;;
  esac
}

ai_role_scope() {
  case "$1" in
    lead) echo "plan, découpage, délégation, décisions, intégration, vérification finale" ;;
    architect) echo "architecture, specs, ADR, arbitrages" ;;
    debugger) echo "bugs difficiles, tâches longues en terminal, migrations" ;;
    security) echo "revue sécurité ciblée (auth, paiements, données, secrets)" ;;
    reviewer) echo "revue de diff : régressions, cas limites, tests manquants" ;;
    developer) echo "features et correctifs courants dans un périmètre donné" ;;
    executor) echo "tickets précis et bornés, tests, modifications en masse" ;;
    explorer) echo "recherche dans le code, cartographie, résumés, logs" ;;
    documenter) echo "README, docs, changelogs" ;;
  esac
}

# Rôles qui modifient des fichiers quand on les délègue (les autres sont en lecture seule).
ai_role_writes() {
  case "$1" in executor|developer|documenter) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- outils

# Résout les liens symboliques pour que les programmes auxiliaires voisins du vrai binaire restent accessibles (bash 3.2, sans readlink -f).
_ai_realpath() {
  local p="$1" link
  while [[ -L "$p" ]]; do
    link="$(readlink "$p")"
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
  done
  echo "$p"
}

# CLI Codex : d'abord le PATH (liens résolus), puis les binaires livrés avec les applications de bureau.
ai_codex_bin() {
  # LOOMY_CODEX_BIN : chemin explicite de la CLI Codex (installation atypique) ; s'il n'est pas exécutable, Codex est considéré absent.
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

# ai_version_ge <a> <b> : vrai si la version a >= b (x.y.z numérique).
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

# Alias de la CLI Claude utilisé quand une ancienne CLI refuse un identifiant de modèle explicite.
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

# Famille d'outils qui fait tourner un rôle dans un environnement donné.
#   claude | codex                   : repli sur un seul outil, tout tourne dessus
#   hybrid-claude | hybrid-codex     : les deux outils, l'outil principal est nommé après "hybrid-"
ai_family_for_role() {
  local role="$1" env="$2" lead other
  case "$env" in
    claude|codex) echo "$env"; return 0 ;;
  esac
  lead="${env#hybrid-}"
  other="claude"; [[ "$lead" == "claude" ]] && other="codex"
  case "$role" in
    lead|explorer|developer|documenter) echo "$lead" ;;       # sur l'outil principal : pas de coût de bridge
    architect|security|debugger) echo "claude" ;;             # Opus 5.5 domine le raisonnement, le terminal et le travail de bureau
    executor) echo "codex" ;;                                 # GPT-6-Luna max : meilleur rapport qualité/prix sur les tâches de code bornées
    reviewer) echo "$other" ;;                                # revue croisée entre familles, pour l'indépendance
  esac
}

# Matrice de base (profil "equilibre") : "<NIVEAU> <effort>".
_ai_base() {
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

# ai_route <rôle> <famille> <profil>
# Renseigne R_FAMILY R_TIER R_MODEL R_EFFORT pour un rôle sur une famille d'outils donnée.
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

# ai_resolve <rôle> <env> <profil> : route un rôle dans un environnement. Renseigne aussi R_VIA.
ai_resolve() {
  local role="$1" env="$2" profile="$3" family lead
  family="$(ai_family_for_role "$role" "$env")"
  ai_route "$role" "$family" "$profile"
  lead="${env#hybrid-}"
  if [[ "$role" == "lead" ]]; then
    R_VIA="session principale"
  elif [[ "$family" == "claude" && "$lead" == "claude" ]]; then
    R_VIA="sous-agent .claude/agents/$role.md"
  elif [[ "$family" == "claude" ]]; then
    R_VIA="delegate-to-claude.sh $role"
  else
    R_VIA="delegate-to-codex.sh $role"
  fi
}

# Commande de lancement de la session principale (orchestrateur).
ai_lead_command() {
  local env="$1" profile="$2"
  ai_resolve lead "$env" "$profile"
  if [[ "$R_FAMILY" == "claude" ]]; then
    echo "claude --model $R_MODEL --effort $R_EFFORT"
  else
    echo "codex -m $R_MODEL -c model_reasoning_effort=$R_EFFORT"
  fi
}

# ---------------------------------------------------------------- détection de l'environnement

_ai_brief_get() {
  local brief="$1" key="$2"
  [[ -f "$brief" ]] || return 0
  sed -n '/^---$/,/^---$/p' "$brief" | sed -n "s/^$key:[[:space:]]*//p" | head -1 | sed 's/^"//; s/"$//'
}

# ai_env_for <mode> <lead> : détermine l'environnement à partir du mode, de l'outil principal demandé et des outils installés.
# Renseigne AI_ENV et AI_ENV_NOTE (explication du repli, éventuellement vide).
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
      elif (( lead_ok )); then AI_ENV="$lead"; AI_ENV_NOTE="mode $mode demandé mais $other est absent : repli full $lead"
      elif (( other_ok )); then AI_ENV="$other"; AI_ENV_NOTE="lead $lead absent : repli full $other"
      else AI_ENV="$lead"; AI_ENV_NOTE="aucune CLI IA détectée : matrice théorique"; fi ;;
    *)
      if (( lead_ok )); then AI_ENV="$lead"
      elif (( other_ok )); then AI_ENV="$other"; AI_ENV_NOTE="lead $lead absent : repli full $other"
      else AI_ENV="$lead"; AI_ENV_NOTE="aucune CLI IA détectée : matrice théorique"; fi ;;
  esac
}

# ai_detect_env <racine-du-projet>
# Lit mode, outil principal et budget dans .loomy/brief.md et renseigne AI_ENV, AI_ENV_NOTE, AI_PROFILE, AI_MODE, AI_LEAD.
# Respecte les surcharges AI_ROUTE_ENV / AI_ROUTE_PROFILE.
ai_detect_env() {
  local root="$1" brief
  brief="$root/.loomy/brief.md"
  AI_MODE="$(_ai_brief_get "$brief" ai_mode)"; AI_MODE="${AI_MODE:-SOLO}"
  AI_LEAD="$(_ai_brief_get "$brief" ai_lead)"
  AI_PROFILE="${AI_ROUTE_PROFILE:-$(_ai_brief_get "$brief" budget)}"
  AI_PROFILE="${AI_PROFILE:-equilibre}"
  ai_env_for "$AI_MODE" "$AI_LEAD"
  if [[ -n "${AI_ROUTE_ENV:-}" ]]; then AI_ENV="$AI_ROUTE_ENV"; AI_ENV_NOTE=""; fi
}

ai_env_label() {
  case "$1" in
    claude) echo "Full Claude Code" ;; codex) echo "Full Codex" ;;
    hybrid-claude) echo "Hybride, lead Claude Code" ;; hybrid-codex) echo "Hybride, lead Codex" ;;
    *) echo "$1" ;;
  esac
}

ai_profile_label() {
  case "$1" in econome) echo "Économe" ;; equilibre) echo "Équilibré" ;; qualite) echo "Qualité max" ;; *) echo "$1" ;; esac
}

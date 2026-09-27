#!/usr/bin/env bash
# Routage modèle / effort par rôle pour ce projet. Compatible bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ai-route.sh [options] [command]

Commandes :
  (aucune)              Affiche la matrice rôle → modèle / effort / outil pour ce projet
  get <rôle>            Une ligne "famille modèle effort" (pour les scripts)
  markdown              Matrice au format Markdown (pour .ai/AI_MODEL_ROUTING.md)
  all                   Matrice des 4 environnements côte à côte (Markdown)
  claude-agents [DIR]   Génère les sous-agents Claude Code (défaut : <projet>/.claude/agents)
  codex-profiles        Extrait TOML des profils Codex par rôle (à ajouter à ~/.codex/config.toml)
  lead                  Commande de lancement de la session principale (orchestrateur)

Options :
  --root DIR            Projet (défaut : projet courant)
  --env ENV             claude | codex | hybrid-claude | hybrid-codex (défaut : détecté)
  --profile P           econome | equilibre | qualite (défaut : brief, sinon equilibre)

Rôles : lead architect debugger security reviewer developer executor explorer documenter
EOF
}

ROOT=""; ENV_OPT=""; PROFILE_OPT=""; CMD="show"; ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --env) ENV_OPT="${2:-}"; shift ;;
    --profile) PROFILE_OPT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    get|claude-agents) CMD="$1"; if [[ $# -ge 2 && "$2" != -* ]]; then ARG="$2"; shift; fi ;;
    markdown|all|codex-profiles|lead|show) CMD="$1" ;;
    *) t "Argument inconnu : %s" "$1" >&2; echo >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -z "$ROOT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else ROOT="$(ai_project_root)"; fi
fi
ROOT="$(cd "$ROOT" && pwd)"

[[ -n "$ENV_OPT" ]] && export AI_ROUTE_ENV="$ENV_OPT"
[[ -n "$PROFILE_OPT" ]] && export AI_ROUTE_PROFILE="$PROFILE_OPT"
ai_detect_env "$ROOT"
case "$AI_ENV" in claude|codex|hybrid-claude|hybrid-codex) ;; *) t "Environnement inconnu : %s" "$AI_ENV" >&2; echo >&2; exit 2 ;; esac
case "$AI_PROFILE" in econome|equilibre|qualite) ;; *) t "Profil inconnu : %s" "$AI_PROFILE" >&2; echo >&2; exit 2 ;; esac

valid_role() { case " $AI_ROLES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

case "$CMD" in
  get)
    valid_role "$ARG" || { t "Rôle inconnu : « %s »" "$ARG" >&2; echo >&2; exit 2; }
    ai_resolve "$ARG" "$AI_ENV" "$AI_PROFILE"
    echo "$R_FAMILY $R_MODEL $R_EFFORT"
    ;;

  lead)
    ai_lead_command "$AI_ENV" "$AI_PROFILE"
    ;;

  markdown)
    echo "Environnement : **$(ai_env_label "$AI_ENV")** · profil **$(ai_profile_label "$AI_PROFILE")** · catalogue du $AI_CATALOG_DATE"
    [[ -n "$AI_ENV_NOTE" ]] && echo "" && echo "> Repli : $AI_ENV_NOTE"
    echo ""
    echo "| Rôle | Périmètre | Outil | Modèle | Effort | Comment l'appeler |"
    echo "|---|---|---|---|---|---|"
    for r in $AI_ROLES; do
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      echo "| $(ai_role_label "$r") | $(ai_role_scope "$r") | $R_FAMILY | \`$R_MODEL\` | $R_EFFORT | \`$R_VIA\` |"
    done
    echo ""
    echo "Lancer l'orchestrateur : \`$(ai_lead_command "$AI_ENV" "$AI_PROFILE")\`"
    ;;

  all)
    echo "Profil **$(ai_profile_label "$AI_PROFILE")**"
    echo ""
    echo "| Rôle | Full Claude Code | Full Codex | Hybride, lead Claude | Hybride, lead Codex |"
    echo "|---|---|---|---|---|"
    for r in $AI_ROLES; do
      line="| $(ai_role_label "$r") |"
      for e in claude codex hybrid-claude hybrid-codex; do
        ai_resolve "$r" "$e" "$AI_PROFILE"
        line="$line \`$R_MODEL\` $R_EFFORT |"
      done
      echo "$line"
    done
    ;;

  claude-agents)
    dest="${ARG:-$ROOT/.claude/agents}"
    tpl_dir="$SCRIPT_DIR/../templates/claude-agents"
    [[ -d "$tpl_dir" ]] || { echo "Modèles d'agents introuvables : $tpl_dir" >&2; exit 1; }
    lead="${AI_ENV#hybrid-}"
    if [[ "$lead" != "claude" ]]; then
      echo "Lead Codex : pas de sous-agent Claude natif. Les rôles Claude passent par delegate-to-claude.sh." >&2
      exit 0
    fi
    mkdir -p "$dest"
    for r in $AI_ROLES; do
      [[ "$r" == "lead" ]] && continue
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      [[ "$R_FAMILY" == "claude" ]] || continue
      [[ -f "$tpl_dir/$r.md" ]] || continue
      sed -e "s/__MODEL__/$R_MODEL/" -e "s/__EFFORT__/$R_EFFORT/" "$tpl_dir/$r.md" >"$dest/$r.md"
      echo "$dest/$r.md  ($R_MODEL, $R_EFFORT)"
    done
    ;;

  codex-profiles)
    echo "# Loomy — profils Codex par rôle (profil $(ai_profile_label "$AI_PROFILE"), catalogue du $AI_CATALOG_DATE)"
    echo "# Usage : codex --profile ai-lead | ai-developer | …"
    for r in $AI_ROLES; do
      ai_route "$r" codex "$AI_PROFILE"
      echo ""
      echo "[profiles.ai-$r]"
      echo "model = \"$R_MODEL\""
      echo "model_reasoning_effort = \"$R_EFFORT\""
    done
    ;;

  show)
    ui_banner "$(t "Routage des modèles")" "$(ai_env_label "$AI_ENV") · $(t "profil %s" "$(ai_profile_label "$AI_PROFILE")") · $(t "catalogue du %s" "$AI_CATALOG_DATE")"
    [[ -n "$AI_ENV_NOTE" ]] && ui_warn "$(t "Repli")" "$AI_ENV_NOTE"
    ui_section "$(t "RÔLES")" "$(t "modèle · effort · comment l'appeler")"
    for r in $AI_ROLES; do
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      _ui_pad "$(ai_role_label "$r")" 22; label="$UI_PADDED"
      _ui_pad "$R_MODEL" 18; model="$UI_PADDED"
      _ui_pad "$R_EFFORT" 8; effort="$UI_PADDED"
      color="$C_CYAN"; [[ "$R_TIER" == "TOP" ]] && color="$C_MAGENTA"; [[ "$R_TIER" == "FAST" ]] && color="$C_GREEN"
      if [[ "$r" == "lead" ]]; then label="${C_BRAND}${label}${C_RESET}"; else label="${C_BOLD}${label}${C_RESET}"; fi
      ui_rail "${label}${color}${model}${C_RESET}${effort}${C_DIM}${R_VIA}${C_RESET}"
    done
    ui_rail ""
    ui_rail "${C_DIM}$(t "couleurs :")${C_RESET} ${C_MAGENTA}$(t "pointe")${C_RESET} ${C_DIM}·${C_RESET} ${C_CYAN}$(t "standard")${C_RESET} ${C_DIM}·${C_RESET} ${C_GREEN}$(t "rapide")${C_RESET}"
    ui_section "$(t "LANCER L'ORCHESTRATEUR")"
    ui_rail "${C_BOLD}$(ai_lead_command "$AI_ENV" "$AI_PROFILE")${C_RESET}"
    ui_end "$(t "comparer les environnements : loomy route all · autre profil : loomy route --profile qualite")"
    ;;
esac

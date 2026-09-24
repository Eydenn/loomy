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
    -*) echo "Option inconnue : $1" >&2; usage; exit 2 ;;
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
[[ -d "$TARGET_INPUT" ]] || { echo "Erreur : dossier introuvable : $TARGET_INPUT" >&2; exit 1; }
TARGET="$(cd "$TARGET_INPUT" && pwd)"
BRIEF="$TARGET/.loomy/brief.md"
mkdir -p "$TARGET/.loomy"

if [[ "$UI_ASSUME_DEFAULTS" != "1" ]] && ! ui_is_interactive; then
  echo "Terminal non interactif : relancez avec --yes (et éventuellement --answers FILE)." >&2
  exit 2
fi

LOOMY_VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "?")"

# ---------------------------------------------------------------- fichier de réponses
load_answers() {
  local file="$1" line key value in_fm=0
  [[ -f "$file" ]] || { echo "Erreur : fichier de réponses introuvable : $file" >&2; exit 1; }
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
choose_coded() {
  local var="$1" q="$2" defcode="$3" hint="$4"; shift 4
  local labels=() codes=() descs=() i=0 defi=0 item rest
  for item in "$@"; do
    codes[$i]="${item%%|*}"; rest="${item#*|}"
    labels[$i]="${rest%%|*}"
    if [[ "$rest" == *"|"* ]]; then descs[$i]="${rest#*|}"; else descs[$i]=""; fi
    if [[ "${codes[$i]}" == "$defcode" ]]; then defi=$i; fi
    i=$(( i + 1 ))
  done
  UI_HINT="$hint"; UI_DESCS=("${descs[@]}")
  ui_choose "$q" "$defi" "${labels[@]}"
  for (( i = 0; i < ${#labels[@]}; i++ )); do
    if [[ "${labels[$i]}" == "$UI_VALUE" ]]; then
      printf -v "$var" '%s' "${codes[$i]}"; printf -v "${var}_LABEL" '%s' "${labels[$i]}"; return 0
    fi
  done
  printf -v "$var" '%s' "$defcode"; printf -v "${var}_LABEL" '%s' "$defcode"
}

yaml_q() {
  local v="${1//$'\n'/ }"
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

# ---------------------------------------------------------------- environnement
HAS_GIT=0; IS_REPO=0; HAS_CLAUDE=0; HAS_CODEX=0; GIT_REMOTE=""; GH_USER=""; REMOTE_VIS=""

env_check() {
  # L'affichage, le contrôle des prérequis et les corrections guidées sont confiés à ai-doctor.sh.
  local doctor_args=(--root "$TARGET" --compact)
  ui_is_interactive && doctor_args+=(--fix)
  "$SCRIPT_DIR/ai-doctor.sh" "${doctor_args[@]}" || ui_warn "Prérequis minimum non atteints" "le brief reste possible, corrigez avant de lancer l'agent"

  if command -v git >/dev/null 2>&1; then
    HAS_GIT=1
    if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      IS_REPO=1
      local remote
      remote="$(git -C "$TARGET" remote 2>/dev/null | head -1)"
      if [[ -n "$remote" ]]; then GIT_REMOTE="$remote $(git -C "$TARGET" remote get-url "$remote" 2>/dev/null)"; fi
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
  if [[ "$count" == "0" ]]; then DETECTED_REPO="new"; ui_end "détecté : dossier vide (nouveau projet)"
  elif [[ "$count" == "1" ]]; then DETECTED_REPO="existing"; ui_end "détecté : projet existant (1 élément à la racine)"
  else DETECTED_REPO="existing"; ui_end "détecté : projet existant ($count éléments à la racine)"; fi
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

  ui_group "PROJET"
  ui_step 1 $TOTAL
  UI_LABEL="Nom"
  UI_HINT="Sert de nom au projet dans la documentation générée."
  ui_input "Nom du projet" "$(ans name "${LOOMY_PROJECT_NAME:-$(basename "$TARGET")}")"
  NAME="$UI_VALUE"
  SLUG="$(loomy_slug "$NAME")"

  ui_step 2 $TOTAL
  UI_LABEL="Objectif"
  UI_HINT="Une phrase suffit : l'agent la reprend dans PROJECT.md et pose moins de questions. Entrée pour laisser vide."
  ui_input "Objectif en une phrase" "$(ans goal "")" "Ex. : Permettre aux freelances de suivre leurs factures"
  GOAL="$UI_VALUE"

  ui_step 3 $TOTAL
  UI_LABEL="Point de départ"
  choose_coded REPO "Nouveau projet ou projet existant ?" "$(ans repo "$DETECTED_REPO")" \
    "Oriente la découverte (détecté automatiquement, à confirmer)." \
    "new|Nouveau projet|L'agent propose la stack et la structure à partir de zéro." \
    "existing|Projet existant à standardiser|L'agent analyse d'abord l'existant et ne propose que des changements de standardisation, sans casser l'architecture."

  ui_step 4 $TOTAL
  UI_LABEL="Type"
  choose_coded TYPE "Quel type de projet ?" "$(ans type web)" \
    "Détermine les questions suivantes et les vérifications proposées (build, tests, déploiement)." \
    "web|Application web / SaaS|Front et éventuel back, déploiement web ; accessibilité et SEO à considérer." \
    "api|API / service backend|Service sans interface : contrats d'API, validation et tests d'intégration au centre." \
    "mobile|Application mobile|Contraintes des stores, permissions, hors-ligne ; builds iOS et/ou Android." \
    "desktop|Application desktop|Packaging, signature et mises à jour par système d'exploitation." \
    "cli|CLI / bibliothèque|API publique stable, packaging et compatibilité des runtimes." \
    "ai|Application IA / LLM|Choix du fournisseur, exposition des données, garde-fous et évaluation des réponses." \
    "other|Autre|Vous décrirez le type ; l'agent posera davantage de questions."

  ui_step 5 $TOTAL
  local d1="" d2=""
  case "$TYPE" in
    web)
      UI_LABEL="Hébergement"
      choose_coded X1 "Hébergement cible ?" "$(ans detail1 tbd)" "Influence le framework, le runtime et la chaîne de déploiement." \
        "vercel|Vercel / Netlify|Déploiement simple et serverless, idéal pour un front moderne." \
        "cloudflare|Cloudflare|Exécution en edge, très économique, avec des contraintes de runtime." \
        "server|Serveur / VPS / Docker|Contrôle total, mais davantage d'exploitation à gérer." "$tbd"
      UI_LABEL="Comptes"
      choose_coded X2 "Comptes utilisateurs ?" "$(ans detail2 tbd)" "L'authentification augmente le risque et le périmètre." \
        "yes|Oui|Authentification et sessions à prévoir : risque au moins MEDIUM." \
        "no|Non|Pas d'authentification à prévoir." "$tbd"
      d1="Hébergement : $X1_LABEL"; d2="Comptes utilisateurs : $X2_LABEL"
      [[ "$X2" == "yes" ]] && FORCE_AUTH=1 ;;
    api)
      UI_LABEL="Style d'API"
      choose_coded X1 "Style d'API ?" "$(ans detail1 tbd)" "Structure les contrats, la documentation et les tests." \
        "rest|REST|Standard, simple à consommer et à documenter (OpenAPI)." \
        "graphql|GraphQL|Requêtes flexibles côté client, schéma typé, plus de complexité serveur." \
        "rpc|RPC / gRPC|Performant entre services, moins adapté aux clients web publics." "$tbd"
      UI_LABEL="Base de données"
      choose_coded X2 "Base de données ?" "$(ans detail2 tbd)" "Oriente la persistance et les migrations." \
        "sql|SQL|Relations et intégrité fortes (PostgreSQL, SQLite…)." \
        "nosql|NoSQL|Schéma souple, montée en charge horizontale." \
        "none|Aucune|Pas de persistance à prévoir." "$tbd"
      d1="Style d'API : $X1_LABEL"; d2="Base de données : $X2_LABEL" ;;
    mobile)
      UI_LABEL="Approche"
      choose_coded X1 "Approche ?" "$(ans detail1 tbd)" "Détermine le langage, l'outillage et le nombre de bases de code." \
        "expo|Expo / React Native|Un seul code JS/TS pour iOS et Android, itérations rapides." \
        "native|Natif (Swift / Kotlin)|Meilleure intégration et performance, mais deux bases de code." \
        "flutter|Flutter|Un seul code Dart multi-plateforme, rendu propre au framework." "$tbd"
      UI_LABEL="Plateformes"
      choose_coded X2 "Plateformes ?" "$(ans detail2 both)" "Chaque plateforme ajoute builds, tests et publication." \
        "both|iOS et Android|Builds, tests et publication sur les deux stores." \
        "ios|iOS|Une seule plateforme : plus simple à livrer." \
        "android|Android|Une seule plateforme : plus simple à livrer."
      d1="Approche : $X1_LABEL"; d2="Plateformes : $X2_LABEL" ;;
    desktop)
      UI_LABEL="Systèmes"
      choose_coded X1 "Systèmes cibles ?" "$(ans detail1 multi)" "Chaque OS ajoute packaging, signature et tests." \
        "macos|macOS|Une seule cible : signature et packaging simplifiés." \
        "windows|Windows|Une seule cible : signature et packaging simplifiés." \
        "linux|Linux|Une seule cible : packaging simplifié." \
        "multi|Multi-plateforme|Builds et tests à prévoir pour chaque OS."
      UI_LABEL="Technologie"
      choose_coded X2 "Technologie ?" "$(ans detail2 tbd)" "Arbitrage entre poids des binaires, écosystème et intégration native." \
        "tauri|Tauri|Léger (Rust + webview), binaires petits." \
        "electron|Electron|Écosystème mature, binaires lourds." \
        "native|Natif|Meilleure intégration, un code par OS." "$tbd"
      d1="Systèmes : $X1_LABEL"; d2="Technologie : $X2_LABEL" ;;
    cli)
      UI_LABEL="Langage"
      choose_coded X1 "Langage / runtime ?" "$(ans detail1 tbd)" "Détermine l'écosystème, le packaging et la distribution." \
        "node|Node.js|Distribution via npm, démarrage rapide." \
        "python|Python|Écosystème riche, packaging pip/uv." \
        "go|Go|Binaire unique, sans runtime à installer." \
        "rust|Rust|Binaire unique et rapide, compilation plus exigeante." \
        "bash|Bash|Zéro dépendance, limité aux scripts simples." "$tbd"
      UI_LABEL="Distribution"
      choose_coded X2 "Distribution ?" "$(ans detail2 tbd)" "Fixe le niveau d'exigence sur la stabilité de l'interface." \
        "registry|Registre public (npm, PyPI, crates…)|Versioning sémantique et API publique à stabiliser." \
        "binary|Binaire|Builds multi-OS et releases à automatiser." \
        "internal|Usage interne|Contraintes de compatibilité plus légères." "$tbd"
      d1="Runtime : $X1_LABEL"; d2="Distribution : $X2_LABEL" ;;
    ai)
      UI_LABEL="Fournisseur"
      choose_coded X1 "Fournisseur de modèles ?" "$(ans detail1 tbd)" "Détermine SDK, coûts et conditions d'usage des données." \
        "anthropic|Anthropic (Claude)|SDK et modèles d'un seul fournisseur." \
        "openai|OpenAI|SDK et modèles d'un seul fournisseur." \
        "multi|Plusieurs|Couche d'abstraction à prévoir entre fournisseurs." \
        "local|Modèles locaux|Pas de coût d'API, performances liées au matériel." "$tbd"
      UI_LABEL="Données exposées"
      choose_coded X2 "Données envoyées aux modèles ?" "$(ans detail2 internal)" "Conditionne les garde-fous et le niveau de risque." \
        "public|Publiques|Peu de contraintes." \
        "internal|Internes|Vérifier la rétention et l'usage des données chez le fournisseur." \
        "sensitive|Sensibles|Risque HIGH : anonymisation, garde-fous et revues de sécurité en DEEP."
      d1="Fournisseur : $X1_LABEL"; d2="Données exposées : $X2_LABEL" ;;
    *)
      UI_LABEL="Type précisé"
      UI_HINT="Quelques mots suffisent ; l'agent complétera pendant l'entretien."
      ui_input "Décrivez le type de projet" "$(ans detail1 "")"
      X1="$UI_VALUE"; X2=""; d1="Type précisé : $UI_VALUE" ;;
  esac
  DETAIL1="${X1:-}"; DETAIL2="${X2:-}"
  DETAILS="$d1${d2:+ · $d2}"

  ui_group "EXIGENCES"
  ui_step 6 $TOTAL
  UI_LABEL="Stade"
  choose_coded STAGE "Stade visé ?" "$(ans stage mvp)" \
    "Fixe dès le départ le niveau d'exigence : tests, CI, sécurité." \
    "prototype|Prototype / exploration|Vitesse avant tout : tests minimaux, pas de CI obligatoire." \
    "mvp|MVP|Tests ciblés, CI simple, dette technique maîtrisée." \
    "production|Production|Tests complets, CI/CD et observabilité ; risque au moins MEDIUM."

  ui_step 7 $TOTAL
  local sens_def="" c
  for c in $(printf '%s' "$(ans sensitive "")" | tr ',' ' '); do
    case "$c" in
      auth) sens_def="${sens_def:+$sens_def,}Authentification / comptes" ;;
      payments) sens_def="${sens_def:+$sens_def,}Paiements" ;;
      personal) sens_def="${sens_def:+$sens_def,}Données personnelles" ;;
      infra) sens_def="${sens_def:+$sens_def,}Secrets / infra de production" ;;
    esac
  done
  if [[ "${FORCE_AUTH:-0}" == "1" && "$sens_def" != *Authentification* ]]; then
    sens_def="${sens_def:+$sens_def,}Authentification / comptes"
  fi
  UI_LABEL="Éléments sensibles"
  UI_HINT="Chaque élément coché élève le risque et impose des revues plus poussées (modèles DEEP). Rien de coché = aucun."
  UI_DESCS=("Risque MEDIUM : sessions, permissions, stockage des mots de passe." \
    "Risque HIGH : conformité, idempotence, revue de sécurité systématique." \
    "Risque HIGH : RGPD, minimisation et protection des données." \
    "Risque HIGH : gestion des secrets, opérations irréversibles.")
  ui_multi "Éléments sensibles ?" "$sens_def" \
    "Authentification / comptes" "Paiements" "Données personnelles" "Secrets / infra de production"
  SENSITIVE=""; SENSITIVE_LABEL="${UI_VALUE:-aucun}"
  case "$UI_VALUE" in *Authentification*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}auth" ;; esac
  case "$UI_VALUE" in *Paiements*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}payments" ;; esac
  case "$UI_VALUE" in *personnelles*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}personal" ;; esac
  case "$UI_VALUE" in *infra*) SENSITIVE="${SENSITIVE:+$SENSITIVE,}infra" ;; esac
  RISK="LOW"
  case ",$SENSITIVE," in *,auth,*) RISK="MEDIUM" ;; esac
  case ",$SENSITIVE," in *,payments,*|*,personal,*|*,infra,*) RISK="HIGH" ;; esac
  if [[ "$RISK" == "LOW" && "$STAGE" == "production" ]]; then RISK="MEDIUM"; fi
  if [[ "$TYPE" == "ai" && "$DETAIL2" == "sensitive" ]]; then RISK="HIGH"; fi
  ui_fact "Risque estimé" "risque $RISK"

  ui_group "ÉQUIPE IA"
  ui_step 8 $TOTAL
  local mode_def="SOLO" lead_def="claude"
  if (( HAS_CODEX && HAS_CLAUDE )); then mode_def="ORCHESTRATED"
  elif (( HAS_CODEX )); then lead_def="codex"; fi
  UI_LABEL="Collaboration"
  choose_coded MODE "Mode de collaboration IA ?" "$(ans ai_mode "$mode_def")" \
    "Définit comment Codex et Claude Code se partagent le travail. Pré-sélection selon les outils détectés." \
    "SOLO|SOLO|Un seul outil à la fois : le plus simple et le moins coûteux." \
    "HYBRID|HYBRID|Les deux outils travaillent tour à tour, coordonnés par Git et .ai/HANDOFF.md." \
    "ORCHESTRATED|ORCHESTRATED|L'orchestrateur délègue chaque rôle au meilleur modèle des deux familles (exécution sur GPT-6-Luna, architecture et sécurité sur Opus 5.5, revue croisée) : meilleur rapport qualité/coût." \
    "PARALLEL|PARALLEL|Les deux en même temps sur des worktrees séparés : plus rapide, intégration à soigner."
  UI_LABEL="Outil principal"
  choose_coded LEAD "Outil principal (lead) ?" "$(ans ai_lead "$lead_def")" \
    "L'outil principal porte l'orchestrateur : il planifie, délègue, décide et vérifie. C'est lui qui mérite le meilleur raisonnement." \
    "claude|Claude Code|Orchestrateur sur Opus 5.5, en tête des benchmarks de raisonnement et de travail agentique ; délègue à Codex via delegate-to-codex.sh (recommandé)." \
    "codex|Codex|Orchestrateur sur GPT-6-Astra ; délègue à Claude via delegate-to-claude.sh (lecture seule)."

  ui_step 9 $TOTAL
  UI_LABEL="Profil"
  choose_coded BUDGET "Profil de coût / qualité des modèles ?" "$(ans budget equilibre)" \
    "L'orchestrateur reste toujours sur le meilleur modèle ; le profil règle les efforts et le modèle de chaque rôle (détail : loomy route)." \
    "econome|Économe|Orchestrateur et spécialistes en effort medium, exécution sur les modèles rapides. Coût minimal, un peu plus de reprises sur les tâches difficiles." \
    "equilibre|Équilibré (recommandé)|Orchestrateur en high ; exécution sur GPT-6-Luna max ou Sonnet 5 ; architecture, sécurité et debug difficile sur Opus 5.5 high. Meilleur rapport qualité/coût." \
    "qualite|Qualité max|Orchestrateur et spécialistes en xhigh, revues sur le modèle de pointe, exécution sur Sol ou Sonnet high. Coût nettement plus élevé, moins de reprises."
  ai_env_for "$MODE" "$LEAD"
  ROUTE_ENV="$AI_ENV"; ROUTE_NOTE="$AI_ENV_NOTE"
  ai_resolve lead "$ROUTE_ENV" "$BUDGET"; LEAD_LINE="$R_MODEL ($R_EFFORT)"
  ai_resolve executor "$ROUTE_ENV" "$BUDGET"; EXEC_LINE="$R_MODEL ($R_EFFORT)"
  ai_resolve architect "$ROUTE_ENV" "$BUDGET"; DEEP_LINE="$R_MODEL ($R_EFFORT)"
  ui_fact "Orchestrateur" "orchestrateur ${LEAD_LINE}"

  ui_group "LIVRABLES"
  ui_step 10 $TOTAL
  UI_LABEL="Langue des docs"
  choose_coded DOCLANG "Langue de la documentation du projet ?" "$(ans doc_language fr)" \
    "Langue des fichiers générés (PROJECT.md, ADR…). Le code et ses identifiants restent en anglais." \
    "fr|Français|Documentation rédigée en français." \
    "en|English|Documentation en anglais : préférable si le projet est partagé à l'international."

  ui_step 11 $TOTAL
  UI_LABEL="START.md ensuite"
  choose_coded HISTORY "Après l'initialisation, que faire de START.md ?" "$(ans bootstrap_history archive)" \
    "START.md n'a plus d'autorité une fois le projet initialisé." \
    "archive|L'archiver dans .ai/bootstrap/ (recommandé)|Garde une trace de l'initialisation, consultable plus tard." \
    "delete|Le supprimer|Repo plus léger ; l'historique ne reste que dans Git."

  ui_step 12 $TOTAL
  GIT_INIT="no"; COMMIT="no"; PUSH="no"
  if (( HAS_GIT )) && (( ! IS_REPO )); then
    UI_LABEL="Dépôt Git"
    choose_coded GIT_INIT "Initialiser un dépôt Git (branche main) maintenant ?" "$(ans git_init yes)" \
      "Le versionnement est nécessaire pour les commits, les worktrees et les handoffs." \
      "yes|Oui|Crée le dépôt local maintenant, rien n'est envoyé en ligne." \
      "no|Non|Pas de versionnement : ni commit ni push possibles."
  fi
  GITHUB_REPO="no"; REMOTE_NAME_NOTE=""; REPO_NAME="$SLUG"; AI_REPO_NAME=""
  if (( IS_REPO )) || [[ "$GIT_INIT" == "yes" ]]; then
    if [[ -n "$GIT_REMOTE" ]]; then
      # Le dépôt distant doit porter le nom du projet : sinon on le signale (sans rien renommer).
      remote_name="$(basename "${GIT_REMOTE#* }" .git)"
      [[ -n "$remote_name" ]] && REPO_NAME="$remote_name"
      if [[ -n "$remote_name" && "$remote_name" != "$SLUG" ]]; then
        REMOTE_NAME_NOTE="dépôt distant « $remote_name », nom du projet « $SLUG »"
        ui_warn "Nom du dépôt différent du projet" "$remote_name ≠ $SLUG"
      fi
    elif [[ -n "$GH_USER" ]]; then
      UI_LABEL="Dépôt GitHub"
      # Jamais de création de dépôt en ligne sans question (mode --yes : non, sauf réponse explicite).
      gh_def="private"; [[ "$UI_ASSUME_DEFAULTS" == "1" ]] && gh_def="no"
      choose_coded GITHUB_REPO "Créer un dépôt GitHub pour ce projet ?" "$(ans github_repo "$gh_def")" \
        "Il porte le nom du projet ; créé seulement une fois le brief enregistré." \
        "private|Oui, privé|Visible par toi seul (et les personnes que tu invites). Recommandé." \
        "public|Oui, public|Visible par tous : pense à la visibilité des fichiers IA, question suivante." \
        "no|Non, plus tard|Aucun dépôt en ligne pour l'instant ; tu pourras le créer avec gh repo create."
      if [[ "$GITHUB_REPO" != "no" ]]; then
        UI_LABEL="Nom du dépôt"
        UI_HINT="Proposé d'après le nom du projet ; modifie-le si besoin (lettres, chiffres, tirets)."
        ui_input "Nom du dépôt GitHub ($GH_USER/…)" "$(ans repo_name "$SLUG")"
        REPO_NAME="$(loomy_slug "$UI_VALUE")"
        GIT_REMOTE="origin https://github.com/$GH_USER/$REPO_NAME.git"
        REMOTE_VIS="$(printf '%s' "$GITHUB_REPO" | tr '[:lower:]' '[:upper:]')"
      fi
    fi
    UI_LABEL="Commit initial"
    choose_coded COMMIT "Commit initial une fois le setup vérifié ?" "$(ans commit_after_setup yes)" \
      "Autorise l'agent à clôturer l'initialisation par un commit." \
      "yes|Oui, l'agent committe|Commit « chore: initialize project » seulement si toutes les vérifications passent." \
      "no|Non, je committerai moi-même|Les changements restent non commités ; vous gardez la main."
    if [[ "$COMMIT" == "yes" ]]; then
      if [[ -n "$GIT_REMOTE" ]]; then
        UI_LABEL="Push"
        choose_coded PUSH "Pousser vers ${GIT_REMOTE%% *} après le commit ?" "$(ans push_after_commit no)" \
          "Remote détecté : ${GIT_REMOTE#* }" \
          "no|Non, je pousserai moi-même|Rien ne quitte votre machine sans vous." \
          "yes|Oui, push de la branche courante|La branche est poussée après le commit initial, jamais de force-push."
      else
        ui_fact "Push" "pas de remote, pas de push"
      fi
    fi
  else
    ui_fact "Git" "pas de dépôt Git : ni commit ni push"
  fi

  # Fichiers IA : GitHub règle la visibilité par dépôt, pas par fichier.
  local files_def="versioned" vis_txt=""
  case "$REMOTE_VIS" in
    PUBLIC) files_def="private"; [[ -z "$GH_USER" ]] && files_def="local"; vis_txt=" Ton dépôt GitHub est public." ;;
    PRIVATE|INTERNAL) vis_txt=" Ton dépôt GitHub est privé." ;;
  esac
  UI_LABEL="Fichiers IA"
  choose_coded AI_FILES "Où garder les fichiers IA (AGENTS.md, CLAUDE.md, .ai/, .loomy/…) ?" "$(ans ai_files "$files_def")" \
    "Ce sont tes règles de travail avec les agents. GitHub règle la visibilité par dépôt, pas par fichier.$vis_txt" \
    "versioned|Versionnés avec le projet|Recommandé pour un dépôt privé : tu les retrouves sur toutes tes machines, et les agents qui travaillent en ligne sur le dépôt les lisent." \
    "local|Locaux uniquement|Jamais envoyés sur GitHub : exclus via .git/info/exclude, invisible dans le dépôt. Perdus si tu changes de machine." \
    "private|Dans un dépôt privé séparé|Recommandé pour un dépôt public : exclus du projet et sauvegardés dans un dépôt GitHub privé ($(basename "$TARGET")-ai), avec loomy privacy sync."
  if [[ "$AI_FILES" == "private" ]]; then
    while true; do
      UI_LABEL="Dépôt privé IA"
      UI_HINT="Dépôt privé qui ne contiendra que les fichiers IA ; modifie le nom si besoin."
      ui_input "Nom du dépôt privé des fichiers IA${GH_USER:+ ($GH_USER/…)}" "$(ans ai_repo_name "${AI_REPO_NAME:-$REPO_NAME-ai}")"
      AI_REPO_NAME="$(loomy_slug "$UI_VALUE")"
      [[ "$GITHUB_REPO" == "no" ]] && break
      # Deux dépôts à créer : confirmation des deux noms ensemble.
      UI_LABEL="Deux dépôts"
      UI_DESCS=("Crée $GH_USER/$REPO_NAME ($(if [[ "$GITHUB_REPO" == public ]]; then echo public; else echo privé; fi)) pour le projet et $GH_USER/$AI_REPO_NAME (privé) pour les fichiers IA." \
        "Repose les deux noms.")
      ui_choose "Créer ces deux dépôts : $REPO_NAME et $AI_REPO_NAME ?" 0 "Oui, créer les deux" "Modifier les noms"
      [[ "$UI_VALUE" == Oui* ]] && break
      UI_LABEL="Nom du dépôt"
      ui_input "Nom du dépôt GitHub ($GH_USER/…)" "$REPO_NAME"
      REPO_NAME="$(loomy_slug "$UI_VALUE")"; GIT_REMOTE="origin https://github.com/$GH_USER/$REPO_NAME.git"
    done
  fi

  if (( TOTAL == 13 )); then ui_group "FORFAITS"; ui_step 13 $TOTAL; fi
  if (( ASK_PLAN_CLAUDE )); then
    UI_LABEL="Forfait Claude"
    choose_coded PLAN_CLAUDE_NEW "Quel est ton forfait Claude ?" "${PLAN_CLAUDE_NEW:-api}" \
      "Demandé une seule fois, mémorisé dans ta configuration Loomy. Sert à afficher la valeur consommée face au prix du forfait." \
      "api|API|Paiement à l'usage : Loomy affiche le coût réel." \
      "pro|Claude Pro (20 \$/mois)|Loomy affiche la valeur API consommée face à 20 \$ par mois." \
      "max5|Claude Max 5x (100 \$/mois)|Loomy affiche la valeur API consommée face à 100 \$ par mois." \
      "max20|Claude Max 20x (200 \$/mois)|Loomy affiche la valeur API consommée face à 200 \$ par mois." \
      "team|Claude Team ou Enterprise|Prix ajustable ensuite avec loomy config set plan_claude_price <prix>."
  fi
  if (( ASK_PLAN_CODEX )); then
    UI_LABEL="Forfait Codex"
    choose_coded PLAN_CODEX_NEW "Quel est ton forfait ChatGPT / Codex ?" "${PLAN_CODEX_NEW:-api}" \
      "Demandé une seule fois, mémorisé dans ta configuration Loomy." \
      "api|API|Paiement à l'usage : Loomy affiche le coût estimé à partir des tokens." \
      "plus|ChatGPT Plus (20 \$/mois)|Loomy affiche la valeur API consommée face à 20 \$ par mois." \
      "pro100|ChatGPT Pro (100 \$/mois)|Loomy affiche la valeur API consommée face à 100 \$ par mois." \
      "pro200|ChatGPT Pro (200 \$/mois)|Loomy affiche la valeur API consommée face à 200 \$ par mois." \
      "business|ChatGPT Business ou Enterprise|Prix ajustable ensuite avec loomy config set plan_codex_price <prix>."
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
  ui_rail_head "v$LOOMY_VERSION · brief de démarrage · $(basename "$TARGET")"
  ui_rail_group "Brief du projet" ".loomy/brief.md"
  ui_rail_kv "Nom" "${C_BOLD}${NAME}${C_RESET}"
  ui_rail_kv "Objectif" "$goal_txt"
  ui_rail_kv "Projet" "$REPO_LABEL · $TYPE_LABEL · $STAGE_LABEL"
  ui_rail_kv "Précisions" "$DETAILS"
  ui_rail_kv "Sensible" "$SENSITIVE_LABEL"
  ui_rail_kv "Risque" "${risk_c}${RISK}${C_RESET}"
  ui_rail ""
  ui_rail_group "Équipe IA"
  ui_rail_kv "Mode" "${C_BOLD}${MODE}${C_RESET} · lead ${LEAD_LABEL}"
  ui_rail_kv "Profil" "${BUDGET_LABEL% (recommandé)}"
  if [[ "$BUDGET" == "econome" && "$RISK" == "HIGH" ]]; then
    ui_rail_kv "" "${C_YELLOW}! risque HIGH en profil Économe : passe la sécurité en effort high sur les changements sensibles${C_RESET}"
  fi
  ui_rail_kv "Routage" "$(ai_env_label "$ROUTE_ENV")"
  if [[ -n "$ROUTE_NOTE" ]]; then ui_rail_kv "" "${C_YELLOW}! ${ROUTE_NOTE}${C_RESET}"; fi
  ui_rail_kv "Orchestrateur" "${C_BRAND}${LEAD_LINE}${C_RESET}"
  ui_rail_kv "Exécution" "$EXEC_LINE"
  ui_rail_kv "Architecture" "$DEEP_LINE"
  ui_rail ""
  ui_rail_group "Livrables"
  ui_rail_kv "Docs" "$DOCLANG_LABEL · START.md : ${HISTORY_LABEL% (recommandé)}"
  ui_rail_kv "Nom technique" "$SLUG ${C_DIM}(dossier, noms techniques)${C_RESET}"
  if [[ "$GITHUB_REPO" != "no" ]]; then parts="${parts:+$parts + }dépôt GitHub $GITHUB_REPO $GH_USER/$REPO_NAME"; fi
  ui_rail_kv "Git" "${parts:-aucune action}"
  if [[ -n "$REMOTE_NAME_NOTE" ]]; then
    ui_rail_kv "" "${C_YELLOW}! $REMOTE_NAME_NOTE${C_RESET} ${C_DIM}→ gh repo rename $SLUG${C_RESET}"
  fi
  ui_rail_kv "Fichiers IA" "$AI_FILES_LABEL${AI_REPO_NAME:+ · dépôt privé ${GH_USER:+$GH_USER/}$AI_REPO_NAME}"
  if [[ "$COMMIT" == "yes" && -z "$GIT_REMOTE" ]]; then
    ui_rail_kv "" "${C_DIM}pas de remote : push à faire plus tard${GH_USER:+ (gh repo create --private --source=. --push)}${C_RESET}"
  fi
  if [[ -n "$PLAN_CLAUDE_NEW$PLAN_CODEX_NEW" ]]; then
    ui_rail_kv "Forfaits" "${PLAN_CLAUDE_NEW:+Claude : $PLAN_CLAUDE_NEW_LABEL}${PLAN_CLAUDE_NEW:+${PLAN_CODEX_NEW:+ · }}${PLAN_CODEX_NEW:+Codex : $PLAN_CODEX_NEW_LABEL}"
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
ui_banner "Brief de démarrage" "v$LOOMY_VERSION · Codex + Claude Code · $TARGET"
DETECTED_REPO="new"
env_check

if [[ -f "$BRIEF" && -z "$ANSWERS_FILE" ]] && ui_is_interactive; then
  ui_print ""
  UI_LABEL="Brief existant"
  choose_coded REDO "Un brief existe déjà. Que faire ?" "redo" "Ses réponses servent de valeurs par défaut si tu le refais." \
    "redo|Le refaire|Le fichier n'est remplacé qu'à la fin, après ta confirmation." \
    "keep|Le garder et quitter|Rien n'est modifié."
  if [[ "$REDO" == "keep" ]]; then ui_ok "Brief conservé" "$BRIEF"; exit 0; fi
fi

plan_questions
FORM_GROUPS="PROJET|EXIGENCES|ÉQUIPE IA|LIVRABLES"
if (( TOTAL == 13 )); then FORM_GROUPS="$FORM_GROUPS|FORFAITS"; fi
while true; do
  # Plein écran pendant les questions ; ← rejoue la passe jusqu'à la question précédente.
  ui_form_begin "v$LOOMY_VERSION · brief de démarrage · $(basename "$TARGET")" "$FORM_GROUPS"
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
  UI_LABEL="Brief"
  choose_coded CONFIRM "Enregistrer ce brief ?" "save" "Rien n'est écrit avant ta confirmation." \
    "save|Oui, enregistrer|$save_desc" \
    "again|Revoir les questions|Tes réponses actuelles deviennent les valeurs par défaut." \
    "cancel|Annuler|Aucun fichier écrit, aucune action Git."
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

ui_rail ""
if [[ "$GIT_INIT" == "yes" ]]; then
  git -C "$TARGET" init -q -b main && ui_rail "${C_GREEN}✓${C_RESET} Dépôt Git initialisé ${C_DIM}branche main${C_RESET}"
fi
if [[ "$GITHUB_REPO" != "no" && -n "$GH_USER" ]]; then
  if (cd "$TARGET" && gh repo create "$REPO_NAME" "--$GITHUB_REPO" --source=. --remote=origin >/dev/null 2>&1); then
    ui_rail "${C_GREEN}✓${C_RESET} Dépôt GitHub créé ${C_DIM}$GH_USER/$REPO_NAME ($GITHUB_REPO) · remote origin${C_RESET}"
  else
    ui_rail "${C_YELLOW}!${C_RESET} Dépôt GitHub non créé ${C_DIM}→ gh repo create $REPO_NAME --$GITHUB_REPO --source=. --remote=origin${C_RESET}"
    GITHUB_REPO="no"
  fi
fi
write_brief
if [[ "$AI_FILES" != "versioned" ]]; then
  bash "$SCRIPT_DIR/ai-privacy.sh" --root "$TARGET" apply --quiet \
    || ui_rail "${C_YELLOW}!${C_RESET} Fichiers IA : réglage incomplet ${C_DIM}→ loomy privacy $AI_FILES${C_RESET}"
fi
[[ -n "$PLAN_CLAUDE_NEW" ]] && loomy_config_set plan_claude "$PLAN_CLAUDE_NEW"
[[ -n "$PLAN_CODEX_NEW" ]] && loomy_config_set plan_codex "$PLAN_CODEX_NEW"
if [[ -n "$PLAN_CLAUDE_NEW$PLAN_CODEX_NEW" ]]; then ui_rail "${C_GREEN}✓${C_RESET} Forfaits mémorisés ${C_DIM}$(loomy_config_file | sed "s|^$HOME|~|")${C_RESET}"; fi
ui_rail "${C_GREEN}✓${C_RESET} Brief enregistré ${C_DIM}${BRIEF#"$TARGET"/}${C_RESET}"

if [[ -x "$SCRIPT_DIR/ai-status.sh" ]]; then
  # Premier brief : la phase passe à Découverte. Brief refait en cours de route : la phase en cours est conservée.
  current_phase="$(sed -n 's/^phase=//p' "$TARGET/.loomy/state" 2>/dev/null | head -1 || true)"
  if [[ -z "$current_phase" || "$current_phase" == "brief" ]]; then
    "$SCRIPT_DIR/ai-status.sh" --root "$TARGET" set discover >/dev/null 2>&1 || true
  fi
fi

PROMPT="$(ai_start_prompt "$MODE" "$LEAD")"
LEAD_CMD="$(ai_lead_command "$ROUTE_ENV" "$BUDGET")"
ui_rail ""
ui_rail_group "Étape suivante"
step=1
# Projet créé ailleurs que dans le dossier d'où loomy init a été lancé : il faut s'y rendre.
from="${LOOMY_INVOKED_FROM:-$TARGET}"
if [[ "$(cd "$from" 2>/dev/null && pwd -P)" != "$(cd "$TARGET" && pwd -P)" ]]; then
  rel="${TARGET#"$from"/}"; [[ "$rel" == "$TARGET" ]] && rel="${TARGET/#$HOME/~}"
  ui_rail "${C_BRAND}${step}${C_RESET}  Va dans le dossier du projet : ${C_BOLD}cd $rel${C_RESET}"
  ui_rail ""
  step=$(( step + 1 ))
fi
if command -v loomy >/dev/null 2>&1; then
  ui_rail "${C_BRAND}${step}${C_RESET}  Ouvre la session de l'orchestrateur : ${C_BOLD}loomy start${C_RESET}"
  ui_rail "   ${C_DIM}ou à la main : ${LEAD_CMD}, puis colle le prompt de démarrage${C_RESET}"
else
  ui_rail "${C_BRAND}${step}${C_RESET}  Lance l'orchestrateur à la racine du projet :"
  ui_rail "   ${C_BOLD}${LEAD_CMD}${C_RESET}"
  ui_rail "   puis colle le prompt de démarrage :"
  _ui_term_size
  _ui_wrap "$PROMPT" $(( UI_W - 8 ))
  for line in ${UI_LINES[@]+"${UI_LINES[@]}"}; do ui_rail "   ${C_DIM}${line}${C_RESET}"; done
fi
if [[ "${ROUTE_ENV#hybrid-}" == "codex" ]]; then
  ui_rail "   ${C_DIM}(ou dans l'app Codex : modèle ${LEAD_LINE%% *}, effort ${LEAD_LINE##*(})${C_RESET}"
fi
if (( USE_CLIPBOARD )) && ui_is_interactive && ui_copy "$PROMPT"; then
  ui_rail "   ${C_GREEN}✓${C_RESET} ${C_DIM}prompt de démarrage copié dans le presse-papiers${C_RESET}"
fi
step=$(( step + 1 ))
ui_rail ""
ui_rail "${C_BRAND}${step}${C_RESET}  Suis l'avancement en direct dans un autre terminal :"
if command -v loomy >/dev/null 2>&1; then
  ui_rail "   ${C_BOLD}loomy watch${C_RESET}"
else
  ui_rail "   ${C_BOLD}.loomy/scripts/ai-status.sh --watch${C_RESET}"
fi

# Proposer d'ouvrir tout de suite la session, dans le dossier du projet (sans cd).
if ui_is_interactive && [[ -x "$SCRIPT_DIR/ai-start.sh" ]]; then
  ui_rail ""
  UI_LABEL="Session"
  UI_DESCS=("Ouvre l'orchestrateur maintenant, dans le dossier du projet, avec le prompt de démarrage." "Tu la lanceras plus tard avec loomy start, depuis le dossier du projet.")
  ui_choose "Ouvrir la session de l'orchestrateur maintenant ?" 0 "Oui, maintenant" "Plus tard"
  if [[ "$UI_VALUE" == Oui* ]]; then
    exec bash "$SCRIPT_DIR/ai-start.sh" --root "$TARGET" --new
  fi
fi
ui_rail_end "routage : loomy route · diagnostic : loomy doctor --live · journal : loomy log"

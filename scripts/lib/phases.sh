#!/usr/bin/env bash
# shellcheck disable=SC2034  # bibliothèque chargée par d'autres scripts
# Phases du bootstrap Loomy : libellé, ce que fait l'agent, ce que l'utilisateur doit faire.
# Source unique pour loomy status, loomy watch et loomy start. À charger (source). Compatible bash 3.2.

# Textes traduits (t) : la couche de langue est chargée si le script ne l'a pas déjà fait (hooks, contexte).
if ! declare -F t >/dev/null 2>&1; then
  # shellcheck source=i18n.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
fi

LOOMY_PHASES="brief discover interview propose approve build verify document commit retire"

loomy_phase_label() {
  case "$1" in
    brief) t "Brief"; echo ;; discover) t "Découverte"; echo ;; interview) t "Entretien"; echo ;;
    propose) t "Proposition"; echo ;; approve) t "Validation"; echo ;; build) t "Construction"; echo ;;
    verify) t "Vérification"; echo ;; document) t "Documentation"; echo ;; commit) t "Commit"; echo ;;
    retire) t "Clôture"; echo ;; done) t "Terminé"; echo ;; "") t "Non démarré"; echo ;; *) echo "$1" ;;
  esac
}

# loomy_phase_agent <phase> : ce que fait l'orchestrateur pendant cette phase.
loomy_phase_agent() {
  case "$1" in
    brief) t "Le questionnaire est rempli ; l'orchestrateur n'a pas encore démarré."; echo ;;
    discover) t "L'orchestrateur lit le brief et explore le dossier du projet."; echo ;;
    interview) t "L'orchestrateur pose les questions qui manquent encore au brief."; echo ;;
    propose) t "L'orchestrateur présente la stack, la structure du dépôt et le plan."; echo ;;
    approve) t "L'orchestrateur attend ton feu vert avant de créer quoi que ce soit."; echo ;;
    build) t "L'orchestrateur met en place le projet et délègue aux rôles dédiés."; echo ;;
    verify) t "Tests, relecture croisée et contrôles de sécurité du travail livré."; echo ;;
    document) t "Rédaction de PROJECT.md, ARCHITECTURE.md et des règles .ai/."; echo ;;
    commit) t "Commit initial, si tu l'as autorisé dans le questionnaire."; echo ;;
    retire) t "START.md est archivé ou supprimé : le bootstrap se termine."; echo ;;
    done) t "Le projet est initialisé ; l'orchestrateur suit maintenant AGENTS.md et CLAUDE.md."; echo ;;
    *) t "Aucune phase enregistrée pour l'instant."; echo ;;
  esac
}

# loomy_phase_you <phase> : ce que l'utilisateur doit faire (à afficher comme « À toi : … »).
loomy_phase_you() {
  case "$1" in
    ""|brief) t "lance l'orchestrateur avec loomy start."; echo ;;
    discover) t "rien pour l'instant ; garde sa session ouverte."; echo ;;
    interview) t "réponds à ses questions dans sa session."; echo ;;
    propose) t "lis la proposition, pose tes questions."; echo ;;
    approve) t "valide la proposition ou demande des changements dans sa session."; echo ;;
    build) t "suis les délégations ici ; l'agent te sollicite si un choix se présente."; echo ;;
    verify) t "regarde les constats de relecture qu'il te remonte."; echo ;;
    document) t "relis PROJECT.md et ARCHITECTURE.md quand il te les signale."; echo ;;
    commit) t "vérifie le commit proposé (git log, git show)."; echo ;;
    retire) t "rien ; le bootstrap est presque fini."; echo ;;
    done) t "demande tes évolutions à l'orchestrateur (loomy start ouvre sa session)."; echo ;;
    *) t "loomy start pour ouvrir la session de l'orchestrateur."; echo ;;
  esac
}

# loomy_phase_index <phase> : rang de la phase (1 à 10), 0 si inconnue, 11 si terminé.
loomy_phase_index() {
  local p i=0
  [[ "$1" == "done" ]] && { echo 11; return 0; }
  for p in $LOOMY_PHASES; do i=$(( i + 1 )); [[ "$p" == "$1" ]] && { echo "$i"; return 0; }; done
  echo 0
}

# loomy_you_now <phase> <état de session> : consigne pour l'utilisateur, adaptée à la session de l'orchestrateur.
# Tant qu'aucune session n'est ouverte, la seule chose utile est de l'ouvrir (ou de la rouvrir).
loomy_you_now() {
  case "$1" in done) loomy_phase_you "$1"; return 0 ;; esac
  case "$2" in
    open*) loomy_phase_you "$1" ;;
    closed*) t "rouvre la session de l'orchestrateur avec loomy start ; il reprendra à cette phase."; echo ;;
    *) t "ouvre la session de l'orchestrateur avec loomy start."; echo ;;
  esac
}

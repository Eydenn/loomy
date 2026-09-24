#!/usr/bin/env bash
# shellcheck disable=SC2034  # bibliothèque chargée par d'autres scripts
# Phases du bootstrap Loomy : libellé, ce que fait l'agent, ce que l'utilisateur doit faire.
# Source unique pour loomy status, loomy watch et loomy start. À charger (source). Compatible bash 3.2.

LOOMY_PHASES="brief discover interview propose approve build verify document commit retire"

loomy_phase_label() {
  case "$1" in
    brief) echo "Brief" ;; discover) echo "Découverte" ;; interview) echo "Entretien" ;;
    propose) echo "Proposition" ;; approve) echo "Validation" ;; build) echo "Construction" ;;
    verify) echo "Vérification" ;; document) echo "Documentation" ;; commit) echo "Commit" ;;
    retire) echo "Clôture" ;; done) echo "Terminé" ;; "") echo "Non démarré" ;; *) echo "$1" ;;
  esac
}

# loomy_phase_agent <phase> : ce que fait l'orchestrateur pendant cette phase.
loomy_phase_agent() {
  case "$1" in
    brief) echo "Le questionnaire est rempli ; l'orchestrateur n'a pas encore démarré." ;;
    discover) echo "L'orchestrateur lit le brief et explore le dossier du projet." ;;
    interview) echo "L'orchestrateur pose les questions qui manquent encore au brief." ;;
    propose) echo "L'orchestrateur présente la stack, la structure du dépôt et le plan." ;;
    approve) echo "L'orchestrateur attend ton feu vert avant de créer quoi que ce soit." ;;
    build) echo "L'orchestrateur met en place le projet et délègue aux rôles dédiés." ;;
    verify) echo "Tests, relecture croisée et contrôles de sécurité du travail livré." ;;
    document) echo "Rédaction de PROJECT.md, ARCHITECTURE.md et des règles .ai/." ;;
    commit) echo "Commit initial, si tu l'as autorisé dans le questionnaire." ;;
    retire) echo "START.md est archivé ou supprimé : le bootstrap se termine." ;;
    done) echo "Le projet est initialisé ; l'orchestrateur suit maintenant AGENTS.md et CLAUDE.md." ;;
    *) echo "Aucune phase enregistrée pour l'instant." ;;
  esac
}

# loomy_phase_you <phase> : ce que l'utilisateur doit faire (à afficher comme « À toi : … »).
loomy_phase_you() {
  case "$1" in
    ""|brief) echo "lance l'orchestrateur avec loomy start." ;;
    discover) echo "rien pour l'instant ; garde sa session ouverte." ;;
    interview) echo "réponds à ses questions dans sa session." ;;
    propose) echo "lis la proposition, pose tes questions." ;;
    approve) echo "valide la proposition ou demande des changements dans sa session." ;;
    build) echo "suis les délégations ici ; l'agent te sollicite si un choix se présente." ;;
    verify) echo "regarde les constats de relecture qu'il te remonte." ;;
    document) echo "relis PROJECT.md et ARCHITECTURE.md quand il te les signale." ;;
    commit) echo "vérifie le commit proposé (git log, git show)." ;;
    retire) echo "rien ; le bootstrap est presque fini." ;;
    done) echo "demande tes évolutions à l'orchestrateur (loomy start ouvre sa session)." ;;
    *) echo "loomy start pour ouvrir la session de l'orchestrateur." ;;
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
    closed*) echo "rouvre la session de l'orchestrateur avec loomy start ; il reprendra à cette phase." ;;
    *) echo "ouvre la session de l'orchestrateur avec loomy start." ;;
  esac
}

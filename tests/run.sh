#!/usr/bin/env bash
# Tests de Loomy : parcours complets en terminal, sans réseau ni token.
# Les CLI claude et codex sont remplacées par des doublures (tests/stubs), le reste est réel (git, bash, awk, sed).
#   tests/run.sh            lance tous les tests
#   tests/run.sh -v         affiche la sortie des commandes en échec
# Compatible bash 3.2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loomy-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Environnement isolé : configuration, HOME et PATH maîtrisés, sans couleurs.
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" NO_COLOR=1
export PATH="$HERE/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_CODEX_BIN="$HERE/stubs/codex"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
LOOMY="$REPO/bin/loomy"

PASS=0; FAIL=0; OUT="$WORK/out.txt"

ok() { PASS=$(( PASS + 1 )); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko() {
  FAIL=$(( FAIL + 1 )); printf '  \033[31m✗ %s\033[0m\n' "$1"
  if (( VERBOSE )) && [[ -f "$OUT" ]]; then sed 's/^/      │ /' "$OUT" | tail -25; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# run <description> <commande…> : la commande doit réussir.
run() { local d="$1"; shift; if "$@" >"$OUT" 2>&1; then ok "$d"; else ko "$d (code $?)"; fi; }
# fails <description> <code attendu> <commande…> : la commande doit échouer avec ce code.
fails() {
  local d="$1" want="$2"; shift 2
  "$@" >"$OUT" 2>&1; local got=$?
  if [[ "$got" == "$want" ]]; then ok "$d"; else ko "$d (code $got, attendu $want)"; fi
}
# has <description> <motif> : la dernière sortie contient le motif (grep -E).
has() { if grep -qE -- "$2" "$OUT"; then ok "$1"; else ko "$1 (motif absent : $2)"; fi; }
hasnt() { if grep -qE -- "$2" "$OUT"; then ko "$1 (motif présent : $2)"; else ok "$1"; fi; }
file_has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else ko "$1 (motif absent de ${2##*/} : $3)"; fi; }

# ------------------------------------------------------------------ syntaxe
section "Syntaxe et analyse statique"
SCRIPTS="$(cd "$REPO" && ls bin/loomy install.sh scripts/*.sh scripts/lib/*.sh tests/run.sh tests/stubs/*)"
bad=""
for f in $SCRIPTS; do
  case "$f" in install.sh) sh -n "$REPO/$f" || bad="$bad $f" ;; *) bash -n "$REPO/$f" || bad="$bad $f" ;; esac
done
if [[ -z "$bad" ]]; then ok "bash -n / sh -n sur $(echo "$SCRIPTS" | wc -l | tr -d ' ') scripts"; else ko "erreurs de syntaxe :$bad"; fi
SHELLCHECK="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v shellcheck || true)"
if [[ -n "$SHELLCHECK" ]]; then
  # shellcheck disable=SC2086
  if (cd "$REPO/scripts" && "$SHELLCHECK" -x -S warning ../bin/loomy ../install.sh ./*.sh lib/*.sh ../tests/run.sh ../tests/stubs/*) >"$OUT" 2>&1
  then ok "shellcheck (niveau warning)"; else ko "shellcheck (niveau warning)"; fi
else
  printf '  \033[2m○ shellcheck absent : analyse statique ignorée\033[0m\n'
fi

# ------------------------------------------------------------------ commande loomy
section "Commande loomy"
run "loomy version" "$LOOMY" version
has "version affichée depuis VERSION" "^loomy $(cat "$REPO/VERSION") "
run "loomy help" "$LOOMY" help
has "aide : section Suivi" "Suivi"
fails "commande inconnue refusée" 2 "$LOOMY" nimporte
fails "clé de configuration inconnue refusée" 2 "$LOOMY" config set couleur bleu
fails "delegate sans cible refusé" 2 "$LOOMY" delegate

# ------------------------------------------------------------------ configuration
section "Configuration"
run "config set plan_claude max20" "$LOOMY" config set plan_claude max20
run "config get plan_claude" "$LOOMY" config get plan_claude
has "valeur relue" "^max20$"
fails "valeur de forfait invalide refusée" 2 "$LOOMY" config set plan_claude gratuit
fails "prix non numérique refusé" 2 "$LOOMY" config set plan_codex_price beaucoup
run "config set écrase sans dupliquer" "$LOOMY" config set plan_claude pro
if [[ "$(grep -c '^plan_claude=' "$XDG_CONFIG_HOME/loomy/config")" == "1" ]]; then ok "une seule ligne plan_claude"; else ko "doublon plan_claude"; fi
run "config list" "$LOOMY" config list
has "liste : plan_claude=pro" "^plan_claude=pro$"
rm -f "$XDG_CONFIG_HOME/loomy/config"

# ------------------------------------------------------------------ routage
section "Routage"
P="$WORK/route"; mkdir -p "$P"
for env in claude codex hybrid-claude hybrid-codex; do
  for prof in econome equilibre qualite; do
    if "$LOOMY" route --root "$P" --env "$env" --profile "$prof" markdown >"$OUT" 2>&1 && grep -q '^| ' "$OUT"; then :; else ko "route $env / $prof"; continue 2; fi
  done
done
ok "matrice produite pour 4 environnements × 3 profils"
cd "$P" || exit 1
run "route all" "$LOOMY" route all
has "route all : 4 colonnes d'environnement" "Hybride, lead Codex"
run "route lead" "$LOOMY" route lead
has "orchestrateur sur le meilleur modèle" "opus|astra"
run "route get executor" "$LOOMY" route get executor
if [[ "$(wc -w <"$OUT" | tr -d ' ')" == "3" ]]; then ok "route get : famille modèle effort"; else ko "route get : format inattendu ($(cat "$OUT"))"; fi

# Repli : sans Codex, un mode hybride retombe sur Claude seul.
# Chaque environnement place bien l'orchestrateur et l'exécutant sur la bonne famille.
lead_of() { "$LOOMY" route --root "$P" --env "$1" get lead 2>/dev/null | cut -d' ' -f2; }
exec_of() { "$LOOMY" route --root "$P" --env "$1" get executor 2>/dev/null | cut -d' ' -f1; }
if [[ "$(lead_of claude)" == claude-opus* && "$(lead_of codex)" == gpt-6-astra && "$(lead_of hybrid-claude)" == claude-opus* && "$(lead_of hybrid-codex)" == gpt-6-astra ]]
then ok "orchestrateur : Opus côté Claude, Astra côté Codex"; else ko "orchestrateur mal routé ($(lead_of claude) / $(lead_of codex) / $(lead_of hybrid-claude) / $(lead_of hybrid-codex))"; fi
if [[ "$(exec_of claude)" == claude && "$(exec_of codex)" == codex && "$(exec_of hybrid-claude)" == codex ]]
then ok "exécutant : Luna en hybride lead Claude"; else ko "exécutant mal routé"; fi
if [[ "$("$LOOMY" route --root "$P" --env claude --profile econome get lead)" != "$("$LOOMY" route --root "$P" --env claude --profile qualite get lead)" ]]
then ok "les profils changent l'effort de l'orchestrateur"; else ko "profils sans effet sur l'orchestrateur"; fi

# Repli : un brief hybride sans Codex installé retombe sur Claude seul.
mkdir -p "$P/.loomy" && printf -- '---\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' >"$P/.loomy/brief.md"
if [[ "$("$LOOMY" route --root "$P" get executor | cut -d' ' -f1)" == codex ]]; then ok "brief hybride : exécutant sur Codex"; else ko "brief hybride : exécutant pas sur Codex"; fi
run "repli sans Codex" env LOOMY_CODEX_BIN=/inexistant "$LOOMY" route --root "$P" get executor
has "exécutant routé sur Claude" "^claude "
rm -rf "$P/.loomy"

# ------------------------------------------------------------------ installation dans un projet
section "loomy init (non interactif)"
PROJ="$WORK/projet"; mkdir -p "$PROJ"
run "init --yes dans un dossier vide" "$LOOMY" init "$PROJ" --yes --no-clipboard
for f in START.md .loomy/brief.md .loomy/state .loomy/VERSION .loomy/scripts/ai-status.sh .loomy/templates/AGENTS.md; do
  if [[ -e "$PROJ/$f" ]]; then :; else ko "fichier manquant après init : $f"; fi
done
ok "fichiers du plan de contrôle copiés"
file_has "brief : front matter complet" "$PROJ/.loomy/brief.md" "^push_after_commit: "
file_has "phase initiale : découverte" "$PROJ/.loomy/state" "^phase=discover$"
file_has ".gitignore : journal exclu" "$PROJ/.gitignore" "^\.loomy/logs/$"
has "étape suivante : suivi terminal" "loomy watch|ai-status.sh --watch"
if [[ ! -f "$XDG_CONFIG_HOME/loomy/config" ]] || ! grep -q '^plan_' "$XDG_CONFIG_HOME/loomy/config"; then ok "--yes ne mémorise aucun forfait"; else ko "--yes a mémorisé un forfait"; fi
fails "second init refusé (START.md existe)" 1 "$LOOMY" init "$PROJ" --no-wizard
fails "dossier cible absent refusé" 1 "$LOOMY" init "$WORK/absent" --no-wizard
PROJ2="$WORK/projet2"; mkdir -p "$PROJ2"
run "init --answers reprend un brief" "$LOOMY" init "$PROJ2" --answers "$PROJ/.loomy/brief.md" --yes --no-clipboard
file_has "brief repris : même nom" "$PROJ2/.loomy/brief.md" "^name: "

# ------------------------------------------------------------------ questionnaire interactif
section "loomy init (interactif, terminal réel via expect)"
if command -v expect >/dev/null 2>&1; then
  # Valide chaque question avec sa valeur par défaut (Entrée), dans un pseudo-terminal.
  wizard_expect() {
    cat >"$WORK/wizard.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {valider} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
    WIZ_DIR="$1" expect "$WORK/wizard.exp"
  }
  W1="$WORK/interactif1"; mkdir -p "$W1"
  run "questionnaire complet, forfaits non renseignés" wizard_expect "$W1"
  has "13 étapes quand les forfaits sont à demander" "question 13/13"
  has "question du forfait Claude" "forfait Claude"
  file_has "forfaits mémorisés" "$XDG_CONFIG_HOME/loomy/config" "^plan_codex=api$"
  file_has "brief écrit" "$W1/.loomy/brief.md" "^ai_mode: "
  W2="$WORK/interactif2"; mkdir -p "$W2"
  run "questionnaire complet, forfaits déjà connus" wizard_expect "$W2"
  has "12 étapes" "question 12/12"
  hasnt "forfaits pas redemandés" "forfait Claude|/13"
  # ← revient à la question précédente, qui garde la réponse déjà donnée.
  cat >"$WORK/retour.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
expect "question 1/" ; expect "valider" ; send "Projet Retour\r"
expect "question 2/" ; expect "valider" ; send "\033\[D"
expect "question 1/" ; expect "Projet Retour" ; exit 0
EXP
  W3="$WORK/interactif3"; mkdir -p "$W3"
  run "← revient à la question précédente avec sa réponse" env WIZ_DIR="$W3" expect "$WORK/retour.exp"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
else
  printf '  \033[2m○ expect absent : questionnaire interactif non testé\033[0m\n'
fi

# ------------------------------------------------------------------ statut et journal
section "loomy status (journal dans tous ses états)"
cd "$PROJ" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || git init -q .
git add -A && git commit -qm init
J="$PROJ/.loomy/logs/events.jsonl"
run "status : journal avec phases seulement" "$LOOMY" status
has "status : section Git atteinte" "branche main"
has "status : aucune délégation terminée" "aucune délégation terminée"
run "status : journal vide" sh -c ": > '$J' && '$LOOMY' status"
run "status : journal absent" sh -c "rm -f '$J' && '$LOOMY' status"
run "status : ligne corrompue tolérée" sh -c "printf '{pas du json\n' > '$J' && '$LOOMY' status"
rm -f "$J"

# Délégations réelles via les bridges et les doublures.
section "Bridges (doublures claude et codex)"
run "delegate claude explorer" "$LOOMY" delegate claude explorer "Où est validée la TVA ?"
has "résultat claude transmis" "réponse de la doublure claude"
run "delegate codex reviewer" "$LOOMY" delegate codex reviewer "Relis le dernier commit"
has "résultat codex transmis" "réponse de la doublure codex"
run "delegate codex executor (écrit)" env STUB_WRITE=1 "$LOOMY" delegate codex executor "Ajoute un fichier"
has "fichiers modifiés signalés" "a changé|fichier_doublure"
fails "rôle claude non pris en charge" 2 "$LOOMY" delegate claude executor "x"
fails "tâche manquante" 2 "$LOOMY" delegate codex reviewer
run "échec de la CLI journalisé" sh -c "STUB_FAIL=1 '$LOOMY' delegate codex reviewer 'x' || true"
starts="$(grep -c '"type":"delegation_start"' "$J")"; ends="$(grep -c '"type":"delegation",' "$J")"
if [[ "$starts" == "4" && "$ends" == "4" ]]; then ok "journal : 4 débuts, 4 fins"; else ko "journal : $starts débuts, $ends fins (4 attendus)"; fi
if awk -F'"id":"' '/"type":"delegation_start"/ { split($2, a, "\""); s[a[1]]++ } /"type":"delegation",/ { split($2, a, "\""); e[a[1]]++ } END { for (i in s) if (!(i in e)) exit 1; for (i in e) if (!(i in s)) exit 1 }' "$J"
then ok "journal : chaque début a sa fin (même id)"; else ko "journal : identifiants dépareillés"; fi
file_has "journal : coût rapporté par claude" "$J" '"bridge":"claude".*"cost_usd":0.0123'
file_has "journal : coût estimé pour codex" "$J" '"bridge":"codex".*"cost_source":"estimate"'
file_has "journal : échec enregistré" "$J" '"status":"error"'
if while IFS= read -r l; do printf '%s' "$l" | grep -qE '^\{"ts":"[0-9T:-]+Z",.*\}$' || exit 1; done <"$J"; then ok "journal : une ligne JSON par événement"; else ko "journal : ligne mal formée"; fi
run "LOOMY_JOURNAL_TASKS=0 masque la tâche" env LOOMY_JOURNAL_TASKS=0 "$LOOMY" delegate claude explorer "SECRET-TACHE"
if grep -q "SECRET-TACHE" "$J"; then ko "texte de tâche journalisé malgré LOOMY_JOURNAL_TASKS=0"; else ok "texte de tâche absent du journal"; fi
run "delegate codex avec une locale française" env LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 "$LOOMY" delegate codex explorer "locale"
if tail -1 "$J" | grep -qE '"cost_usd":[0-9]+\.[0-9]+,'; then ok "journal : coût écrit avec un point décimal"; else ko "journal : coût mal formé ($(tail -1 "$J" | grep -oE '"cost_usd":[^"]*'))"; fi
n_before="$(wc -l <"$J")"
run "LOOMY_JOURNAL=0 désactive le journal" env LOOMY_JOURNAL=0 "$LOOMY" delegate claude explorer "x"
[[ "$(wc -l <"$J")" == "$n_before" ]] && ok "rien d'écrit avec LOOMY_JOURNAL=0" || ko "journal écrit malgré LOOMY_JOURNAL=0"

section "Suivi en direct"
run "status avec délégations des deux familles" "$LOOMY" status
has "status : total des délégations" "Délégations +[0-9]+"
has "status : échecs signalés" "en échec"
has "status : dernières délégations" "Dernières délégations"
# Délégation en cours : la doublure dort, le statut doit la montrer, puis l'oublier une fois finie.
STUB_SLEEP=3 "$LOOMY" delegate claude architect "Tâche longue" >/dev/null 2>&1 &
bg=$!
sleep 1
run "status pendant une délégation" "$LOOMY" status
has "délégation en cours affichée" "en cours .*architect"
wait "$bg"
run "status après la délégation" "$LOOMY" status
hasnt "plus rien en cours" "en cours .*architect"
# Délégation interrompue (processus mort, pas d'événement de fin) : ignorée.
printf '{"ts":"2026-01-01T00:00:00Z","type":"delegation_start","id":"dmort","pid":999999,"bridge":"codex","role":"developer","model":"x","task":"interrompue"}\n' >>"$J"
run "status avec délégation interrompue" "$LOOMY" status
hasnt "délégation interrompue ignorée" "interrompue"
run "status avec une locale française" env LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 "$LOOMY" status
has "coûts lus avec le point décimal" 'Délégations +[0-9]+ · coût \$0\.[0-9]*[1-9]'
hasnt "aucune erreur awk ou printf" "division by zero|invalid number|nombre non valable"
run "status --watch démarre et s'arrête" sh -c "'$LOOMY' watch 1 >/dev/null 2>&1 & p=\$!; sleep 2; kill \$p; wait \$p; true"
run "loomy log -n 3" "$LOOMY" log -n 3
if [[ "$(wc -l <"$OUT" | tr -d ' ')" == "3" ]]; then ok "log : 3 lignes"; else ko "log : $(wc -l <"$OUT") lignes"; fi

section "Phases"
run "status set build" "$LOOMY" status set build
file_has "state : phase build" "$PROJ/.loomy/state" "^phase=build$"
if [[ "$(grep -c '^log=' "$PROJ/.loomy/state")" -ge 2 ]]; then ok "state : historique conservé"; else ko "state : historique perdu"; fi
fails "phase inconnue refusée" 2 "$LOOMY" status set nimporte
file_has "journal : événement de phase" "$J" '"type":"phase","phase":"build"'

# ------------------------------------------------------------------ diagnostic
section "loomy doctor"
run "doctor avec claude et codex" "$LOOMY" doctor
has "doctor : claude détecté" "claude 2\.[0-9]"
has "doctor : codex détecté" "codex 0\.[0-9]"
run "doctor --live (sondes)" "$LOOMY" doctor --live
fails "doctor sans aucune CLI IA : minimum non atteint" 1 env LOOMY_CODEX_BIN=/inexistant PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO/scripts/ai-doctor.sh" --root "$PROJ"
has "doctor : bilan explicite" "Minimum non atteint"
run "doctor avec une CLI claude cassée" env STUB_BROKEN_VERSION=1 "$LOOMY" doctor

# ------------------------------------------------------------------ worktrees
section "Worktrees parallèles"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "travail" || true
run "worktrees" "$LOOMY" worktrees demo
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "deux worktrees créés"; else ko "worktrees : $(git -C "$PROJ" worktree list | wc -l) entrées"; fi

# ------------------------------------------------------------------ install.sh
section "install.sh"
PREFIX="$WORK/prefix"
run "install.sh dans un préfixe" env LOOMY_PREFIX="$PREFIX" sh "$REPO/install.sh"
run "loomy installé fonctionne" "$PREFIX/bin/loomy" version
run "install.sh --uninstall" env LOOMY_PREFIX="$PREFIX" sh "$REPO/install.sh" --uninstall
[[ ! -e "$PREFIX/bin/loomy" ]] && ok "commande retirée" || ko "commande toujours présente"

# ------------------------------------------------------------------ bilan
printf '\n\033[1m%d réussi(s), %d échec(s)\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

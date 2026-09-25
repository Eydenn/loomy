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
# Relais des projets (.loomy/scripts/*.sh) : le Loomy « installé » est ce dépôt.
export LOOMY_HOME="$REPO"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
# GitHub simulé : la doublure gh crée les dépôts dans $GH_STUB_REMOTES, et Git y redirige https://github.com/.
export GH_STUB_REMOTES="$WORK/github"; mkdir -p "$GH_STUB_REMOTES"
git config --global url."$GH_STUB_REMOTES/".insteadOf "https://github.com/"
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

# Une variable suivie d'un caractère accentué (« $var… ») casse bash 3.2 hors locale UTF-8 : écrire ${var}.
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$REPO/bin/loomy" "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh >"$OUT"; then ko "variables collées à un caractère non ASCII : $(head -1 "$OUT")"; else ok "aucune variable collée à un caractère non ASCII"; fi

# ------------------------------------------------------------------ commande loomy
section "Commande loomy"
run "loomy version" "$LOOMY" version
has "version affichée depuis VERSION" "^loomy $(cat "$REPO/VERSION") "
run "loomy help" "$LOOMY" help
has "aide : sections structurées" "◇  SUIVI"
hasnt "aide : aucune couleur hors terminal" $'\033\\['
hasnt "aide : plus de route json" "json"
bad=""
for c in init brief route status watch log doctor config delegate worktrees; do
  "$LOOMY" "$c" --help >"$OUT" 2>&1 </dev/null || bad="$bad $c"
done
if [[ -z "$bad" ]]; then ok "--help répond pour chaque commande"; else ko "--help en échec :$bad"; fi
fails "commande inconnue refusée" 2 "$LOOMY" nimporte
fails "clé de configuration inconnue refusée" 2 "$LOOMY" config set couleur bleu
fails "delegate sans cible refusé" 2 "$LOOMY" delegate

# Méthode d'installation déduite de l'emplacement (elle choisit la commande de loomy update).
for spec in "npm:lib/node_modules/loomy" "npm:opt/homebrew/lib/node_modules/loomy" "bun:bunprefix/install/global/node_modules/loomy" "brew:Cellar/loomy/0.0.0/libexec" "brew:opt/homebrew/Cellar/loomy/0.0.0/libexec"; do
  want="${spec%%:*}"; dir="$WORK/methodes/${spec#*:}"
  mkdir -p "$dir" && (cd "$REPO" && tar cf - bin scripts VERSION) | (cd "$dir" && tar xf -)
  got="$(bash "$dir/bin/loomy" version | sed -n 's/^loomy [^ ]* (\([a-z]*\) .*/\1/p')"
  if [[ "$got" == "$want" ]]; then ok "méthode détectée : $want"; else ko "méthode $want détectée comme « $got »"; fi
done

# Plusieurs installations dans le PATH : chacune reconnue, avec sa commande de retrait.
IP="$WORK/installs"; mkdir -p "$IP/prefix" "$IP/npm/bin" "$IP/npm/lib/node_modules/loomy"
LOOMY_PREFIX="$IP/prefix" sh "$REPO/install.sh" >/dev/null 2>&1
(cd "$REPO" && tar cf - bin scripts VERSION) | (cd "$IP/npm/lib/node_modules/loomy" && tar xf -)
ln -s ../lib/node_modules/loomy/bin/loomy "$IP/npm/bin/loomy"
PATH="$IP/prefix/bin:$IP/npm/bin:$PATH" "$LOOMY" version --all >"$OUT" 2>&1
has "installations : celle d'install.sh reconnue (git)" "git v"
has "installations : celle de npm reconnue" "npm v"
has "installations : commande de retrait npm" "npm uninstall -g loomy"
PATH="$IP/prefix/bin:$IP/npm/bin:$PATH" "$LOOMY" version >"$OUT" 2>&1
has "version : signale plusieurs installations" "Plusieurs installations"
rm -rf "$IP"
# Démarrage hors locale UTF-8 (bash 3.2 de macOS en locale C).
PC="$WORK/projet-c"; mkdir -p "$PC/.loomy" && printf -- '---\nname: C\nai_mode: SOLO\nai_lead: claude\n---\n' >"$PC/.loomy/brief.md" && touch "$PC/START.md"
run "start --new en locale C" env LC_ALL=C LANG=C "$LOOMY" start --root "$PC" --new

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
fails "second init hors terminal : guide sans rien modifier" 1 "$LOOMY" init "$PROJ" --no-wizard
has "second init : propose de reprendre" "loomy start"
has "second init : propose la mise à jour" "loomy init --update"
# Mise à jour d'un projet : scripts recopiés, brief et phase conservés.
echo "0.0.1" >"$PROJ/.loomy/VERSION"; rm -f "$PROJ/.loomy/scripts/ai-start.sh"; cp "$PROJ/.loomy/brief.md" "$WORK/brief.avant"
run "init --update" "$LOOMY" init "$PROJ" --update
file_has "update : version du projet à jour" "$PROJ/.loomy/VERSION" "^$(cat "$REPO/VERSION")$"
[[ -f "$PROJ/.loomy/scripts/ai-start.sh" ]] && ok "update : nouveaux scripts copiés" || ko "update : scripts manquants"
cmp -s "$PROJ/.loomy/brief.md" "$WORK/brief.avant" && ok "update : brief conservé" || ko "update : brief modifié"
file_has "update : phase conservée" "$PROJ/.loomy/state" "^phase=discover$"
fails "update sans projet refusé" 1 "$LOOMY" init "$WORK/pas-un-projet-$$" --update
mkdir -p "$WORK/pas-un-projet-$$"
fails "update sans projet refusé" 1 "$LOOMY" init "$WORK/pas-un-projet-$$" --update
PR="$WORK/projet-reset"; mkdir -p "$PR"
run "init d'un projet à réinitialiser" "$LOOMY" init "$PR" --yes --no-clipboard
"$LOOMY" status --root "$PR" set build >/dev/null 2>&1
run "init --reset --no-wizard" "$LOOMY" init "$PR" --reset --no-wizard
[[ ! -f "$PR/.loomy/state" && -f "$PR/.loomy/brief.previous.md" && -f "$PR/START.md" ]] && ok "reset : phase remise à zéro, ancien brief gardé, START.md présent" || ko "reset incomplet"
FS="$WORK/start-etranger"; mkdir -p "$FS" && echo "autre" >"$FS/START.md"
fails "START.md étranger refusé" 1 "$LOOMY" init "$FS" --no-wizard
PROJ2="$WORK/projet2"; mkdir -p "$PROJ2"
run "init --answers reprend un brief" "$LOOMY" init "$PROJ2" --answers "$PROJ/.loomy/brief.md" --yes --no-clipboard
file_has "brief repris : même nom" "$PROJ2/.loomy/brief.md" "^name: "

# ------------------------------------------------------------------ démarrer ou reprendre
section "loomy start"
L="$WORK/start.log"
(cd "$PROJ" && "$LOOMY" start) >"$OUT" 2>&1; st=$?
if [[ $st == 0 ]]; then ok "start hors terminal : affiche les commandes"; else ko "start hors terminal (code $st)"; fi
has "start : commande de l'orchestrateur" "claude --model claude-opus"
has "start : prompt de démarrage du bootstrap" "Initialise ce projet en suivant strictement START.md"
hasnt "start : pas de reprise sans session" "reprendre :"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --new) >"$OUT" 2>&1
if grep -q $'^claude\t--model\tclaude-opus[^\t]*\t--effort\t[a-z]*\tInitialise ce projet' "$L" 2>/dev/null; then ok "start --new lance claude avec modèle, effort et prompt"; else ko "start --new : appel inattendu ($(cat "$L" 2>/dev/null))"; fi
: >"$L"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --resume) >"$OUT" 2>&1
if grep -q $'\tInitialise ce projet' "$L" && ! grep -q -- '--continue' "$L"; then ok "start --resume sans session : nouvelle session"; else ko "start --resume sans session ($(cat "$L"))"; fi
SESS="$HOME/.claude/projects/$(cd "$PROJ" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$SESS" && touch "$SESS/s.jsonl"
: >"$L"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --resume) >"$OUT" 2>&1
if grep -q $'^claude\t--continue\t--model' "$L"; then ok "start --resume reprend la session du dossier"; else ko "start --resume ($(cat "$L"))"; fi
(cd "$PROJ" && "$LOOMY" start --print) >"$OUT" 2>&1
has "start : reprise proposée quand une session existe" "reprendre : claude --continue"
rm -rf "$HOME/.claude/projects"
# Projet mené par Codex.
PX="$WORK/projet-codex"; mkdir -p "$PX/.loomy" && printf -- '---\nname: X\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\n---\n' >"$PX/.loomy/brief.md" && touch "$PX/START.md"
: >"$L"
(cd "$PX" && STUB_LOG="$L" "$LOOMY" start --new) >"$OUT" 2>&1
if grep -q $'^codex\t-m\tgpt-6-astra\t-c\tmodel_reasoning_effort=' "$L"; then ok "start --new lance codex quand Codex mène"; else ko "start codex ($(cat "$L"))"; fi
fails "start sans brief refusé" 1 "$LOOMY" start --root "$WORK/route-vide-$$"
mkdir -p "$WORK/route-vide-$$"
fails "start sans brief refusé" 1 "$LOOMY" start --root "$WORK/route-vide-$$"

# ------------------------------------------------------------------ cas de figure
section "Cas de figure"
# Projet Loomy dans un sous-dossier d'un dépôt Git : trouvé depuis n'importe quel sous-dossier.
MONO="$WORK/mono"; mkdir -p "$MONO/apps/site/src"
git -C "$MONO" init -q && git -C "$MONO" commit -q --allow-empty -m init
run "init dans un sous-dossier d'un dépôt" "$LOOMY" init "$MONO/apps/site" --yes --no-clipboard
(cd "$MONO/apps/site/src" && "$LOOMY" status) >"$OUT" 2>&1
has "status depuis un sous-dossier : projet trouvé" "Statut du projet +~?.*apps/site"
(cd "$MONO/apps/site/src" && "$LOOMY" delegate claude explorer "sous-dossier") >/dev/null 2>&1
[[ -s "$MONO/apps/site/.loomy/logs/events.jsonl" ]] && grep -q '"type":"delegation",' "$MONO/apps/site/.loomy/logs/events.jsonl" && ok "délégation journalisée dans le projet du sous-dossier" || ko "délégation non journalisée dans le sous-dossier"
(cd "$MONO/apps/site/src" && "$LOOMY" start --print) >"$OUT" 2>&1
has "start depuis un sous-dossier" "claude --model"
# loomy brief hors projet, et brief refait en cours de route.
(cd "$WORK" && mkdir -p hors-projet && cd hors-projet && "$LOOMY" brief) >"$OUT" 2>&1; st=$?
[[ $st == 1 ]] && grep -q "loomy init" "$OUT" && ok "brief hors projet : renvoie vers loomy init" || ko "brief hors projet (code $st)"
[[ ! -e "$WORK/hors-projet/.loomy" ]] && ok "brief hors projet : rien créé" || ko "brief hors projet : .loomy créé"
"$LOOMY" status --root "$MONO/apps/site" set build >/dev/null 2>&1
(cd "$MONO/apps/site" && "$LOOMY" brief --yes --no-clipboard) >/dev/null 2>&1
file_has "brief refait en cours de route : phase conservée" "$MONO/apps/site/.loomy/state" "^phase=build$"
# Dossiers qui ne sont pas des projets.
(cd "$HOME" && "$LOOMY" init --no-wizard) >"$OUT" 2>&1; st=$?
[[ $st == 1 && ! -e "$HOME/START.md" ]] && ok "init refusé dans le dossier personnel" || ko "init dans le dossier personnel (code $st)"
# loomy init crée le dossier indiqué, et guide hors terminal quand aucun dossier n'est donné au mauvais endroit.
run "init d'un dossier qui n'existe pas encore" "$LOOMY" init "$WORK/cree-par-init/app" --yes --no-clipboard
[[ -f "$WORK/cree-par-init/app/.loomy/brief.md" ]] && ok "init : dossier créé et projet initialisé" || ko "init : dossier non créé"
(cd "$HOME" && "$LOOMY" init --no-wizard) >"$OUT" 2>&1
has "init hors terminal dans le dossier personnel : propose loomy init <nom>" "loomy init mon-projet"
if command -v expect >/dev/null 2>&1; then
  PARENT="$WORK/parent"; mkdir -p "$PARENT/autre" "$PARENT/encore"
  cat >"$WORK/init-dossier.exp" <<EXP
set timeout 20
cd "$PARENT"
spawn "$LOOMY" init --no-clipboard
expect "Nom du projet" ; expect "valider" ; send "Projet Été 2026\r"
expect "Où créer le projet" ; expect "valider" ; send "\r"
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {Ouvrir la session} { expect "valider" ; send "\033\[B" ; after 300 ; send "\r" }
    -re {valider} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  run "init interactif depuis un dossier parent" expect "$WORK/init-dossier.exp"
  D="$PARENT/projet-ete-2026"
  [[ -n "$D" && -f "$D/.loomy/brief.md" ]] && ok "init : dossier créé d'après le nom du projet ($(basename "$D"))" || ko "init : dossier du projet absent ($(ls "$PARENT" | tr '\n' ' '))"
  [[ -n "$D" ]] && file_has "init : nom du projet repris dans le brief" "$D/.loomy/brief.md" '^name: "Projet Été 2026"$'
  has "init : rappel du cd vers le nouveau dossier" "cd projet-"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
fi

# Nouveau projet dans un dossier qui est lui-même dans un dépôt Git : dépôt propre proposé, puis dépôt GitHub.
if command -v expect >/dev/null 2>&1; then
  PARD="$WORK/parent-git"; mkdir -p "$PARD" && git -C "$PARD" init -q && git -C "$PARD" commit -q --allow-empty -m parent
  cat >"$WORK/dans-parent.exp" <<EXP
set timeout 20
cd "$PARD"
spawn "$LOOMY" init sous-projet --no-clipboard
for {set i 0} {\$i < 80} {incr i} {
  expect {
    -re {Ouvrir la session} { expect "valider" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {valider} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  run "init dans un sous-dossier d'un dépôt parent" expect "$WORK/dans-parent.exp"
  has "dépôt propre proposé" "Créer un dépôt Git propre à ce projet"
  [[ -d "$PARD/sous-projet/.git" ]] && ok "dépôt Git propre créé pour le projet" || ko "pas de dépôt propre"
  [[ "$(git -C "$PARD/sous-projet" config --get remote.origin.url)" == "https://github.com/testeur/sous-projet.git" ]] && ok "dépôt GitHub créé dans le dépôt propre" || ko "remote : $(git -C "$PARD/sous-projet" config --get remote.origin.url)"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
fi

# Écran plein : loomy watch se redessine sur place, sans rien empiler dans l'historique du terminal ; q quitte.
TMUX_BIN="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v tmux || true)"
tmux() { "$TMUX_BIN" "$@"; }
if [[ -n "$TMUX_BIN" && -d "${PARD:-}/sous-projet" ]]; then
  tmux -L loomy-test kill-server 2>/dev/null || true
  tmux -L loomy-test new-session -d -s w -x 100 -y 30 -c "$PARD/sous-projet" "bash '$LOOMY' watch 1; echo SORTIE_OK; sleep 30"
  sleep 4
  [[ "$(tmux -L loomy-test display -p -t w '#{history_size}')" == "0" ]] && ok "watch : rien ne s'empile dans l'historique" || ko "watch : historique $(tmux -L loomy-test display -p -t w '#{history_size}')"
  tmux -L loomy-test send-keys -t w q; sleep 1.5
  tmux -L loomy-test capture-pane -t w -p | grep -q SORTIE_OK && ok "watch : q quitte et rend l'écran normal" || ko "watch : q ne quitte pas"
  tmux -L loomy-test kill-server 2>/dev/null || true
  # loomy start --watch dans tmux : un panneau de suivi à côté de l'agent, fermé avec lui.
  mkdir -p "$WORK/lent"
  printf '#!/bin/bash\n[[ "$1" == "--version" ]] && { echo "2.1.300 (Claude Code)"; exit 0; }\nsleep 4\n' >"$WORK/lent/claude"; chmod +x "$WORK/lent/claude"
  tmux -L loomy-test new-session -d -s s -x 120 -y 50 -c "$PARD/sous-projet" "PATH='$WORK/lent':'$(dirname "$TMUX_BIN")':\$PATH bash '$LOOMY' start --new --watch; sleep 30"
  sleep 2.5
  [[ "$(tmux -L loomy-test list-panes -t s | wc -l | tr -d ' ')" == "2" ]] && ok "start --watch : panneau de suivi ouvert" || ko "start --watch : $(tmux -L loomy-test list-panes -t s | wc -l) panneau(x)"
  sleep 5
  [[ "$(tmux -L loomy-test list-panes -t s | wc -l | tr -d ' ')" == "1" ]] && ok "start --watch : suivi fermé avec la session" || ko "start --watch : suivi toujours ouvert"
  tmux -L loomy-test kill-server 2>/dev/null || true
fi

# Locale UTF-8 choisie même sous pipefail (sinon mesures de texte lentes et accents coupés).
loc="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'set -euo pipefail; source "$1/scripts/lib/models.sh"; p="é"; echo "${#p}"' _ "$REPO")"
[[ "$loc" == "1" ]] && ok "locale UTF-8 choisie sous pipefail" || ko "locale non choisie sous pipefail ($loc)"
fit="$(env -i PATH=/usr/bin:/bin LC_ALL=C bash -c 'source "$1/scripts/lib/ui.sh"; _ui_fit "prompt de démarrage prêt" 13; printf "%s" "$UI_FIT"' _ "$REPO")"
[[ "$fit" == "prompt de dé…" ]] && ok "troncature par caractères (accents intacts)" || ko "troncature : $fit"
steps="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'source "$1/scripts/lib/ui.sh"; ui_steps_begin "MISE EN PLACE" "Étape A" "Étape B"; ui_step_run 0; ui_step_done 0 ok "A faite" "détail"; ui_step_run 1; ui_step_done 1 warn "B partielle" "à revoir"; ui_steps_end' _ "$REPO" 2>&1)"
grep -q "✓ A faite détail" <<<"$steps" && grep -q "! B partielle à revoir" <<<"$steps" && ok "étapes : lignes finales hors écran plein" || ko "étapes : $steps"

# Journal lisible et vues de loomy watch.
if [[ -s "$PROJ/.loomy/logs/events.jsonl" ]]; then
  run "loomy log lisible" bash "$REPO/scripts/ai-log.sh" --root "$PROJ" -n 5
  if grep -q '^{' "$OUT"; then ko "loomy log : JSON brut au lieu du format lisible"; else ok "loomy log : format lisible"; fi
  run "loomy log --raw" bash "$REPO/scripts/ai-log.sh" --root "$PROJ" -n 1 --raw
  has "loomy log --raw : JSON" '^\{"ts"'
  run "vue journal de watch" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-status.sh" --root "$PROJ" --compact --journal
  has "vue journal : section JOURNAL" "JOURNAL"
fi
run "vue resserrée" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-status.sh" --root "$PROJ" --compact
if grep -q "FICHIERS IA" "$OUT"; then ko "vue resserrée : sections détaillées présentes"; else ok "vue resserrée : sections détaillées absentes"; fi

# Session reprise (claude --continue) : même identifiant, un nouveau début après une fin = session ouverte.
RS="$WORK/reprise"; mkdir -p "$RS/.loomy/logs"; : >"$RS/.loomy/brief.md"
sleep 60 & RPID=$!
printf '%s\n' '{"ts":"2026-09-25T00:00:00Z","type":"session","event":"start","tool":"claude","session":"abc","pid":1}' \
  '{"ts":"2026-09-25T00:10:00Z","type":"session","event":"end","tool":"claude","session":"abc","pid":1}' \
  "{\"ts\":\"2026-09-25T09:00:00Z\",\"type\":\"session\",\"event\":\"start\",\"tool\":\"claude\",\"session\":\"abc\",\"pid\":$RPID}" >"$RS/.loomy/logs/events.jsonl"
st="$(bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_session_state "$2"' _ "$REPO" "$RS")"
[[ "$st" == open* ]] && ok "session reprise vue ouverte" || ko "session reprise : $st"
kill "$RPID" 2>/dev/null || true

# loomy effort : effort réglé par projet, prioritaire sur le profil, pris en compte par loomy start.
if [[ -f "$PROJ/.loomy/brief.md" ]]; then
  run "effort de l'orchestrateur réglé" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-effort.sh" --root "$PROJ" low
  grep -qx "lead=low" "$PROJ/.loomy/efforts" && ok "effort enregistré dans .loomy/efforts" || ko "effort non enregistré"
  run "start --print avec l'effort réglé" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-start.sh" --root "$PROJ" --print
  has "start utilise l'effort réglé" "effort low"
  fails "effort : niveau inconnu refusé" 2 bash "$REPO/scripts/ai-effort.sh" --root "$PROJ" turbo
  run "effort --reset" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-effort.sh" --root "$PROJ" --reset
  [[ ! -f "$PROJ/.loomy/efforts" ]] && ok "effort revenu au profil" || ko "réglage toujours présent"
fi

# loomy feedback : texte de l'issue anonymisé (ni nom, ni objectif, ni texte des tâches), rien d'envoyé avec --print.
FB="$WORK/retour"; mkdir -p "$FB/.loomy/logs"
printf -- '---\nname: "NomSecret42"\ngoal: "ObjectifSecret42"\ntype: web\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' >"$FB/.loomy/brief.md"
printf 'phase=build\n' >"$FB/.loomy/state"
printf '%s\n' '{"ts":"2026-09-25T10:00:00Z","type":"delegation","id":"f1","role":"executor","family":"codex","model":"gpt-6-luna","status":"ok","duration_s":5,"cost_usd":0.001,"task":"TacheSecrete42"}' >"$FB/.loomy/logs/events.jsonl"
run "feedback --print" bash "$REPO/scripts/ai-feedback.sh" --root "$FB" --print "un retour de test"
has "feedback : message joint" "un retour de test"
has "feedback : versions jointes" "\| Loomy \|"
has "feedback : état du projet joint" "phase build"
if grep -qE "NomSecret42|ObjectifSecret42|TacheSecrete42|$FB" "$OUT"; then ko "feedback : données du projet divulguées"; else ok "feedback : ni nom, ni objectif, ni chemin, ni texte des tâches"; fi

# Relais des projets : plus de copie des scripts ; ils retrouvent Loomy par la commande loomy du PATH.
if [[ -d "$PROJ/.loomy/scripts" ]]; then
  [[ ! -d "$PROJ/.loomy/scripts/lib" ]] && ok "relais : plus de bibliothèque copiée dans le projet" || ko "relais : lib copiée"
  mkdir -p "$WORK/bin-loomy" && ln -sf "$REPO/bin/loomy" "$WORK/bin-loomy/loomy"
  run "relais sans LOOMY_HOME, via le PATH" env -u LOOMY_HOME PATH="$WORK/bin-loomy:$PATH" bash "$PROJ/.loomy/scripts/ai-route.sh" lead
  has "relais : routage de l'orchestrateur" "claude|codex"
  fails "relais : message clair sans Loomy" 127 env -u LOOMY_HOME LOOMY_RELAY_PATHS= PATH=/usr/bin:/bin bash "$PROJ/.loomy/scripts/ai-route.sh" lead
fi

# Catalogue : celui du dépôt reprend les valeurs intégrées ; un catalogue téléchargé plus récent les remplace,
# sans jamais exécuter son contenu.
cat_vals="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CATALOG_DATE $AI_MODEL_CLAUDE_TOP $AI_MODEL_CLAUDE_MID $AI_MODEL_CLAUDE_FAST $AI_MODEL_CODEX_TOP $AI_MODEL_CODEX_MID $AI_MODEL_CODEX_FAST"' _ "$REPO")"
file_vals="$(awk -F= '/^date=/{d=$2} /^model\.claude\.top=/{a=$2} /^model\.claude\.mid=/{b=$2} /^model\.claude\.fast=/{c=$2} /^model\.codex\.top=/{e=$2} /^model\.codex\.mid=/{f=$2} /^model\.codex\.fast=/{g=$2} END{print d, a, b, c, e, f, g}' "$REPO/catalog/models.conf")"
[[ "$cat_vals" == "$file_vals" ]] && ok "catalogue du dépôt = valeurs intégrées" || ko "catalogue : $cat_vals ≠ $file_vals"
mkdir -p "$XDG_CONFIG_HOME/loomy"
sed 's/^date=.*/date=2099-01-01/; s/^model.codex.fast=.*/model.codex.fast=luna-test/; s/^price.gpt-6-sol=.*/price.gpt-6-sol=9 9 9/' "$REPO/catalog/models.conf" >"$XDG_CONFIG_HOME/loomy/catalog.conf"
echo 'model.claude.top=$(touch '"$WORK"'/injecte)' >>"$XDG_CONFIG_HOME/loomy/catalog.conf"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CATALOG_SOURCE $AI_MODEL_CODEX_FAST $AI_MODEL_CLAUDE_TOP $(ai_price gpt-6-sol)"' _ "$REPO")"
[[ "$got" == "téléchargé luna-test claude-opus-5-5 9 9 9" ]] && ok "catalogue téléchargé pris en compte" || ko "catalogue téléchargé : $got"
[[ ! -e "$WORK/injecte" ]] && ok "catalogue : contenu jamais exécuté" || ko "catalogue : injection exécutée"
rm -f "$XDG_CONFIG_HOME/loomy/catalog.conf"

# Coût réel de Claude Code : hooks Stop et SubagentStop, lu dans la transcription (sans doublons, sans relecture).
US="$WORK/usage"; mkdir -p "$US/.loomy"; : >"$US/.loomy/brief.md"
TR="$WORK/transcript.jsonl"
for i in 1 1 2; do printf '{"type":"assistant","message":{"id":"msg_%s","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$i"; done >"$TR"
printf '{"session_id":"s","transcript_path":"%s"}' "$TR" | LOOMY_HOME="$REPO" bash "$REPO/scripts/ai-context.sh" --root "$US" --hook stop
printf '{"session_id":"s","transcript_path":"%s"}' "$TR" | LOOMY_HOME="$REPO" bash "$REPO/scripts/ai-context.sh" --root "$US" --hook stop
n_usage="$(grep -c '"type":"usage"' "$US/.loomy/logs/events.jsonl" 2>/dev/null || echo 0)"
[[ "$n_usage" == "1" ]] && ok "usage : un événement, transcription pas relue" || ko "usage : $n_usage événement(s)"
grep -q '"messages":2,.*"cost_usd":2.000000' "$US/.loomy/logs/events.jsonl" && ok "usage : doublons écartés, coût au prix public" || ko "usage : $(cat "$US/.loomy/logs/events.jsonl")"
printf '{"session_id":"s2","transcript_path":"%s"}' "$TR" | LOOMY_DELEGATION=1 bash "$REPO/scripts/ai-context.sh" --root "$US" --hook start
grep -q '"session":"s2"' "$US/.loomy/logs/events.jsonl" && ko "délégation Loomy comptée comme session" || ok "délégations Loomy ignorées par les hooks"
run "status : coût de l'orchestrateur" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-status.sh" --root "$US"
has "status : orchestrateur mesuré" "Orchestrateur .*2 réponse"
run "log --csv" bash "$REPO/scripts/ai-log.sh" --root "$US" --csv
has "csv : en-tête" "^date_utc,type,role"
has "csv : coût de l'orchestrateur" "usage,lead,,claude,claude-haiku-4-5-20251001,ok"

# Journal : archive mensuelle, historique complet pour --since.
AR="$WORK/archive"; mkdir -p "$AR/.loomy/logs"; : >"$AR/.loomy/brief.md"
printf '%s\n' '{"ts":"2000-01-05T10:00:00Z","type":"phase","phase":"build"}' >"$AR/.loomy/logs/events.jsonl"
bash "$REPO/scripts/ai-status.sh" --root "$AR" set verify >/dev/null
[[ -f "$AR/.loomy/logs/archive/events-2000-01.jsonl" ]] && ok "journal : mois précédent archivé" || ko "journal : pas d'archive"
run "log --since dans les archives" bash "$REPO/scripts/ai-log.sh" --root "$AR" --since 2000-01-01
has "log --since : événement archivé" "Construction"

# Hooks Claude Code : Stop et SubagentStop ajoutés à un settings.json existant, sans toucher aux hooks de l'utilisateur.
HK="$WORK/hooks"; mkdir -p "$HK/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo perso"}]}]}}\n' >"$HK/.claude/settings.json"
UI_ASSUME_DEFAULTS=1 bash "$LOOMY" init "$HK" --yes >/dev/null 2>&1 || true
grep -q 'echo perso' "$HK/.claude/settings.json" && grep -q -- '--hook stop' "$HK/.claude/settings.json" && grep -q -- '--hook subagent' "$HK/.claude/settings.json" \
  && ok "hooks Stop et SubagentStop ajoutés, hooks existants conservés" || ko "hooks : $(cat "$HK/.claude/settings.json")"

# Aides et commandes annexes.
run "help init" "$LOOMY" help init
has "help <commande> : aide de la commande" "Usage : loomy init"
run "update --help ne met rien à jour" "$LOOMY" update --help
has "update --help : aide" "Usage : loomy update"
run "uninstall" "$LOOMY" uninstall
has "uninstall : commande de retrait" "rm |uninstall"
has "uninstall : retrait d'un projet" "rm -rf .loomy START.md"

# ------------------------------------------------------------------ visibilité des fichiers IA
section "Visibilité des fichiers IA (loomy privacy)"
PV="$WORK/prive"; mkdir -p "$PV"
run "projet pour loomy privacy" "$LOOMY" init "$PV" --yes --no-clipboard
file_has "brief : ai_files versioned par défaut" "$PV/.loomy/brief.md" "^ai_files: versioned$"
mkdir -p "$PV/.ai" && echo "# agents" >"$PV/AGENTS.md" && echo "règles" >"$PV/.ai/AI_WORKFLOW.md" && echo "code" >"$PV/app.txt"
git -C "$PV" add -A && git -C "$PV" commit -qm "avec fichiers IA"
run "privacy local" "$LOOMY" privacy --root "$PV" local
file_has "local : mode enregistré dans le brief" "$PV/.loomy/brief.md" "^ai_files: local$"
file_has "local : exclusion posée dans .git/info/exclude" "$PV/.git/info/exclude" "^/AGENTS.md$"
has "local : fichiers déjà suivis signalés" "Encore suivis par le dépôt"
has "local : commande pour arrêter de les suivre" "git rm -r --cached"
git -C "$PV" rm -r -q --cached -- .loomy START.md AGENTS.md .ai .claude >/dev/null && git -C "$PV" commit -qm "fichiers IA hors du dépôt"
[[ -z "$(git -C "$PV" status --porcelain)" ]] && ok "local : les fichiers IA n'apparaissent plus dans git status" || ko "local : fichiers IA encore visibles ($(git -C "$PV" status --porcelain | head -3 | tr '\n' ' '))"
[[ -f "$PV/AGENTS.md" && -f "$PV/.loomy/brief.md" ]] && ok "local : fichiers conservés sur le disque" || ko "local : fichiers perdus"
if git -C "$PV" check-ignore -q .gitignore; then ko ".gitignore exclu par erreur"; else ok "le reste du projet reste versionné"; fi
# Dépôt privé séparé (dépôt local à la place de GitHub).
BARE="$WORK/prive-ai.git"; git init --bare -q -b main "$BARE"
run "privacy private --remote" "$LOOMY" privacy --root "$PV" private --remote "$BARE"
file_has "private : mode enregistré" "$PV/.loomy/brief.md" "^ai_files: private$"
git --git-dir="$BARE" ls-tree -r --name-only main >"$OUT" 2>&1
has "private : AGENTS.md sauvegardé" "^AGENTS.md$"
has "private : brief sauvegardé" "^.loomy/brief.md$"
hasnt "private : code du projet absent du dépôt privé" "^app.txt$"
hasnt "private : journal absent du dépôt privé" "^.loomy/logs/"
echo "nouvelle règle" >>"$PV/AGENTS.md"
"$LOOMY" status --root "$PV" >"$OUT" 2>&1
has "status : changements non sauvegardés signalés" "non sauvegardé"
run "privacy sync" "$LOOMY" privacy --root "$PV" sync
[[ "$(git --git-dir="$BARE" show main:AGENTS.md | tail -1)" == "nouvelle règle" ]] && ok "sync : modification envoyée" || ko "sync : modification absente"
# Seconde machine : clone du projet (sans fichiers IA), puis restauration.
M2="$WORK/machine2"; git clone -q "$PV" "$M2"
[[ ! -e "$M2/AGENTS.md" ]] && ok "clone : fichiers IA absents du dépôt du projet" || ko "clone : fichiers IA présents"
echo "version locale différente" >"$M2/AGENTS.md"
run "privacy restore" "$LOOMY" privacy --root "$M2" restore "$BARE"
[[ -f "$M2/AGENTS.md" && -f "$M2/.loomy/brief.md" && -f "$M2/.ai/AI_WORKFLOW.md" ]] && ok "restore : fichiers IA récupérés" || ko "restore : fichiers manquants"
has "restore : fichiers locaux différents mis de côté" "mis de côté"
file_has "restore : exclusion posée sur la nouvelle machine" "$M2/.git/info/exclude" "^/AGENTS.md$"
[[ -z "$(git -C "$M2" status --porcelain)" ]] && ok "restore : dépôt du projet propre" || ko "restore : dépôt du projet modifié"
echo "depuis la machine 2" >>"$M2/AGENTS.md"
run "sync depuis la seconde machine" "$LOOMY" privacy --root "$M2" sync
run "sync de la première machine après la seconde" "$LOOMY" privacy --root "$PV" sync
run "retour au mode versionné" "$LOOMY" privacy --root "$PV" versioned
if grep -q "loomy : fichiers IA" "$PV/.git/info/exclude"; then ko "versioned : exclusion encore présente"; else ok "versioned : exclusion retirée"; fi
fails "sync hors mode privé refusé" 1 "$LOOMY" privacy --root "$PV" sync
# Projet en sous-dossier : motifs ancrés sur le sous-dossier.
run "privacy local dans un sous-dossier" "$LOOMY" privacy --root "$MONO/apps/site" local
file_has "sous-dossier : motif préfixé" "$MONO/.git/info/exclude" "^/apps/site/AGENTS.md$"

# ------------------------------------------------------------------ continuité des sessions
section "Continuité (contexte, hooks, sessions, accueil)"
PC2="$WORK/continuite"
run "init pour la continuité" "$LOOMY" init "$PC2" --yes --no-clipboard
file_has "hooks Claude Code installés" "$PC2/.claude/settings.json" 'ai-context.sh\\" --hook start'
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PC2/.claude/settings.json" && ok "settings.json valide" || ko "settings.json invalide"
  PM="$WORK/fusion"; mkdir -p "$PM/.claude" && echo '{"permissions":{"allow":["Bash(ls:*)"]}}' >"$PM/.claude/settings.json"
  "$LOOMY" init "$PM" --yes --no-clipboard >/dev/null 2>&1
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['permissions']['allow']==['Bash(ls:*)'] and d['hooks']['SessionStart']" "$PM/.claude/settings.json" \
    && ok "settings.json existant : hooks ajoutés, réglages conservés" || ko "settings.json existant mal fusionné"
fi
file_has "hooks Codex installés" "$PC2/.codex/hooks.json" 'ai-context.sh.*--hook start --tool codex'
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PC2/.codex/hooks.json" && ok ".codex/hooks.json valide" || ko ".codex/hooks.json invalide"
  CX_CMD="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hooks']['SessionStart'][0]['hooks'][0]['command'])" "$PC2/.codex/hooks.json")"
  mkdir -p "$PC2/src/deep"
  (cd "$PC2/src/deep" && echo '{"session_id":"cx-test","source":"startup"}' | eval "$CX_CMD") >"$OUT" 2>&1
  has "hook Codex depuis un sous-dossier : contexte renvoyé" "Contexte de reprise"
  file_has "hook Codex : session notée avec l'outil codex" "$PC2/.loomy/logs/events.jsonl" '"tool":"codex","session":"cx-test"'
  echo '{"session_id":"cx-test"}' | (cd "$PC2" && bash .loomy/scripts/ai-context.sh --hook end --tool codex) >/dev/null 2>&1
fi
bash "$PC2/.loomy/scripts/ai-context.sh" >"$OUT" 2>&1
has "contexte : projet et phase" "Contexte de reprise du projet"
has "contexte : consigne de reprise" "Reprends START.md à partir de cette phase"
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status : aucune session → ouvrir la session" "ouvre la session de l'orchestrateur"
echo '{"session_id":"s-test","source":"startup"}' | bash "$PC2/.loomy/scripts/ai-context.sh" --hook start >"$OUT" 2>&1
has "hook start : contexte renvoyé à Claude" "Contexte de reprise"
file_has "hook start : session notée" "$PC2/.loomy/logs/events.jsonl" '"type":"session","event":"start"'
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status : session ouverte" "Session de l'orchestrateur ouverte depuis"
echo '{"session_id":"s-test"}' | bash "$PC2/.loomy/scripts/ai-context.sh" --hook end >/dev/null 2>&1
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status : session fermée" "fermée à"
has "status : consigne de reprise" "rouvre la session de l'orchestrateur"
(cd "$PC2" && "$LOOMY") >"$OUT" 2>&1
has "loomy seul hors terminal : aide" "◇  SUIVI"

# ------------------------------------------------------------------ nom du dépôt
section "Nom du dépôt cohérent avec le projet"
file_has "brief : nom technique" "$PC2/.loomy/brief.md" "^slug: continuite$"
file_has "brief : --yes ne crée aucun dépôt GitHub" "$PC2/.loomy/brief.md" "^github_repo: no$"
[[ -z "$(git -C "$PC2" remote)" ]] && ok "--yes : aucun remote ajouté" || ko "--yes : remote ajouté"
PR2="$WORK/nom-different"; mkdir -p "$PR2" && git -C "$PR2" init -q && git -C "$PR2" remote add origin "https://github.com/testeur/autre-nom.git"
run "init avec un dépôt distant au nom différent" "$LOOMY" init "$PR2" --yes --no-clipboard
file_has "écart de nom signalé dans le brief" "$PR2/.loomy/brief.md" "dépôt distant « autre-nom », nom du projet « nom-different »"
file_has "brief : nom du dépôt existant" "$PR2/.loomy/brief.md" "^repo_name: autre-nom$"
PV2="$WORK/prive-gh"
run "projet pour dépôt privé créé par gh" "$LOOMY" init "$PV2" --yes --no-clipboard
run "privacy private sans --remote (GitHub simulé)" "$LOOMY" privacy --root "$PV2" private
[[ -d "$GH_STUB_REMOTES/testeur/prive-gh-ai.git" ]] && ok "dépôt privé nommé d'après le projet (prive-gh-ai)" || ko "dépôt privé absent ou mal nommé ($(ls "$GH_STUB_REMOTES/testeur" 2>/dev/null | tr '\n' ' '))"
git --git-dir="$GH_STUB_REMOTES/testeur/prive-gh-ai.git" ls-tree -r --name-only main 2>/dev/null | grep -q '^.loomy/brief.md$' && ok "dépôt privé : fichiers IA envoyés" || ko "dépôt privé vide"
file_has "brief : nom du dépôt privé" "$PV2/.loomy/brief.md" "^ai_repo_name: prive-gh-ai$"

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
  [[ "$(git -C "$W1" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/interactif1.git" && -d "$GH_STUB_REMOTES/testeur/interactif1.git" ]] && ok "dépôt GitHub créé au nom du projet" || ko "remote inattendu : $(git -C "$W1" config --get remote.origin.url 2>&1)"
  file_has "brief : dépôt GitHub privé" "$W1/.loomy/brief.md" "^github_repo: private$"
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
  # Deux dépôts : projet public + fichiers IA dans un dépôt privé, noms confirmés ensemble.
  cat >"$WORK/deux-depots.exp" <<EXP
set timeout 20
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 80} {incr i} {
  expect {
    -re {Créer un dépôt GitHub pour ce projet} { expect "valider" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {Où garder les fichiers IA} { expect "valider" ; send "\033\[B" ; after 200 ; send "\033\[B" ; after 200 ; send "\r" }
    -re {Créer ces deux dépôts} { expect "valider" ; send "\r" }
    -re {Ouvrir la session} { expect "valider" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {valider} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W4="$WORK/deux-depots"; mkdir -p "$W4"
  run "questionnaire : deux dépôts confirmés" env WIZ_DIR="$W4" expect "$WORK/deux-depots.exp"
  has "confirmation des deux noms demandée" "Créer ces deux dépôts"
  [[ -d "$GH_STUB_REMOTES/testeur/deux-depots.git" && -d "$GH_STUB_REMOTES/testeur/deux-depots-ai.git" ]] && ok "deux dépôts créés : deux-depots (public) et deux-depots-ai (privé)" || ko "dépôts manquants ($(ls "$GH_STUB_REMOTES/testeur" | tr '\n' ' '))"
  file_has "brief : dépôt public" "$W4/.loomy/brief.md" "^github_repo: public$"
  file_has "brief : fichiers IA dans le dépôt privé" "$W4/.loomy/brief.md" "^ai_files: private$"
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
hasnt "doctor : pas de commande d'installation si tout est détecté" "install.sh"
run "doctor --live (sondes)" "$LOOMY" doctor --live
fails "doctor sans aucune CLI IA : minimum non atteint" 1 env LOOMY_CODEX_BIN=/inexistant PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO/scripts/ai-doctor.sh" --root "$PROJ"
has "doctor : bilan explicite" "Minimum non atteint"
has "doctor : commande d'installation de Claude Code" "curl -fsSL https://claude.ai/install.sh"
has "doctor : commande d'installation de Codex" "curl -fsSL https://chatgpt.com/codex/install.sh"
run "doctor avec une CLI claude cassée" env STUB_BROKEN_VERSION=1 "$LOOMY" doctor

# ------------------------------------------------------------------ worktrees
section "Worktrees parallèles"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "travail" || true
run "worktrees" "$LOOMY" worktrees demo
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "deux worktrees créés"; else ko "worktrees : $(git -C "$PROJ" worktree list | wc -l) entrées"; fi
run "worktrees --help n'a rien créé" "$LOOMY" worktrees --help
fails "nom de tâche commençant par un tiret refusé" 2 "$LOOMY" worktrees -x
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "toujours deux worktrees seulement"; else ko "worktrees créés par erreur"; fi

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

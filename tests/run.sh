#!/usr/bin/env bash
# Loomy tests: full terminal walkthroughs, without network or token.
# The claude and codex CLIs are replaced by test doubles (tests/stubs), the rest is real (git, bash, awk, sed).
#   tests/run.sh            runs every test
#   tests/run.sh -v         shows the output of failing commands
# Bash 3.2 compatible.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loomy-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Isolated environment: controlled configuration, HOME and PATH, no colours.
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" NO_COLOR=1
export PATH="$HERE/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_CODEX_BIN="$HERE/stubs/codex"
# Project relays (.loomy/scripts/*.sh): the "installed" Loomy is this repository.
export LOOMY_HOME="$REPO"
# No network check of the published catalog during tests.
export LOOMY_CATALOG_CHECK=0
# English interface for these tests (the language tests set it themselves).
export LOOMY_LANG=en
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
# Simulated GitHub: the gh double creates repositories in $GH_STUB_REMOTES, and Git redirects https://github.com/ there.
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

# run <description> <command…>: the command must succeed.
run() { local d="$1"; shift; if "$@" >"$OUT" 2>&1; then ok "$d"; else ko "$d (code $?)"; fi; }
# fails <description> <expected code> <command…>: the command must fail with this code.
fails() {
  local d="$1" want="$2"; shift 2
  "$@" >"$OUT" 2>&1; local got=$?
  if [[ "$got" == "$want" ]]; then ok "$d"; else ko "$d (code $got, expected $want)"; fi
}
# has <description> <pattern>: the last output contains the pattern (grep -E).
has() { if grep -qE -- "$2" "$OUT"; then ok "$1"; else ko "$1 (pattern missing: $2)"; fi; }
hasnt() { if grep -qE -- "$2" "$OUT"; then ko "$1 (pattern present: $2)"; else ok "$1"; fi; }
file_has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else ko "$1 (pattern missing from ${2##*/}: $3)"; fi; }

# ------------------------------------------------------------------ syntaxe
section "Syntax and static analysis"
SCRIPTS="$(cd "$REPO" && ls bin/loomy install.sh scripts/*.sh scripts/lib/*.sh tests/run.sh tests/stubs/*)"
bad=""
for f in $SCRIPTS; do
  case "$f" in install.sh) sh -n "$REPO/$f" || bad="$bad $f" ;; *) bash -n "$REPO/$f" || bad="$bad $f" ;; esac
done
if [[ -z "$bad" ]]; then ok "bash -n / sh -n on $(echo "$SCRIPTS" | wc -l | tr -d ' ') scripts"; else ko "syntax errors:$bad"; fi
SHELLCHECK="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v shellcheck || true)"
if [[ -n "$SHELLCHECK" ]]; then
  # shellcheck disable=SC2086
  if (cd "$REPO/scripts" && "$SHELLCHECK" -x -S warning ../bin/loomy ../install.sh ./*.sh lib/*.sh ../tests/run.sh ../tests/stubs/*) >"$OUT" 2>&1
  then ok "shellcheck (warning level)"; else ko "shellcheck (warning level)"; fi
else
  printf '  \033[2m○ shellcheck missing: static analysis skipped\033[0m\n'
fi

# A variable followed by an accented character ("$var…") breaks bash 3.2 outside a UTF-8 locale: write ${var}.
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$REPO/bin/loomy" "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh >"$OUT"; then ko "variables stuck to a non-ASCII character: $(head -1 "$OUT")"; else ok "no variable stuck to a non-ASCII character"; fi

# ------------------------------------------------------------------ commande loomy
section "loomy command"
run "loomy version" "$LOOMY" version
has "version shown from VERSION" "^loomy $(cat "$REPO/VERSION") "
V="$(cat "$REPO/VERSION")"
grep -q "\"version\": \"$V\"" "$REPO/package.json" && grep -q "badge/version-$V-" "$REPO/README.md" && grep -q "badge/version-$V-" "$REPO/README.fr.md" && grep -q "^## $V " "$REPO/CHANGELOG.md" \
  && ok "version consistent: VERSION, package.json, README badges, CHANGELOG" || ko "version mismatch around $V"
run "loomy help" "$LOOMY" help
has "help: structured sections" "◇  TRACKING"
hasnt "help: no colour outside a terminal" $'\033\\['
hasnt "help: no more route json" "json"
bad=""
for c in init brief assess stats route status watch log doctor config delegate worktrees; do
  "$LOOMY" "$c" --help >"$OUT" 2>&1 </dev/null || bad="$bad $c"
done
if [[ -z "$bad" ]]; then ok "--help answers for every command"; else ko "--help failing:$bad"; fi
fails "unknown command refused" 2 "$LOOMY" nimporte
fails "unknown configuration key refused" 2 "$LOOMY" config set couleur bleu
fails "delegate without target refused" 2 "$LOOMY" delegate

# Install method inferred from the location (it picks the loomy update command).
for spec in "npm:lib/node_modules/loomy" "npm:opt/homebrew/lib/node_modules/loomy" "bun:bunprefix/install/global/node_modules/loomy" "brew:Cellar/loomy/0.0.0/libexec" "brew:opt/homebrew/Cellar/loomy/0.0.0/libexec"; do
  want="${spec%%:*}"; dir="$WORK/methodes/${spec#*:}"
  mkdir -p "$dir" && (cd "$REPO" && tar cf - bin scripts VERSION) | (cd "$dir" && tar xf -)
  got="$(bash "$dir/bin/loomy" version | sed -n 's/^loomy [^ ]* (\([a-z]*\) .*/\1/p')"
  if [[ "$got" == "$want" ]]; then ok "method detected: $want"; else ko "method $want detected as \"$got\""; fi
done

# Several installs in the PATH: each one recognised, with its removal command.
IP="$WORK/installs"; mkdir -p "$IP/prefix" "$IP/npm/bin" "$IP/npm/lib/node_modules/loomy"
LOOMY_PREFIX="$IP/prefix" sh "$REPO/install.sh" >/dev/null 2>&1
(cd "$REPO" && tar cf - bin scripts VERSION) | (cd "$IP/npm/lib/node_modules/loomy" && tar xf -)
ln -s ../lib/node_modules/loomy/bin/loomy "$IP/npm/bin/loomy"
PATH="$IP/prefix/bin:$IP/npm/bin:$PATH" "$LOOMY" version --all >"$OUT" 2>&1
has "installs: the install.sh one recognised (git)" "git v"
has "installs: the npm one recognised" "npm v"
has "installs: npm removal command" "npm uninstall -g loomy"
PATH="$IP/prefix/bin:$IP/npm/bin:$PATH" "$LOOMY" version >"$OUT" 2>&1
has "version: flags several installs" "Several loomy installs"
rm -rf "$IP"
# Start outside a UTF-8 locale (macOS bash 3.2 in the C locale).
PC="$WORK/projet-c"; mkdir -p "$PC/.loomy" && printf -- '---\nname: C\nai_mode: SOLO\nai_lead: claude\n---\n' >"$PC/.loomy/brief.md" && touch "$PC/START.md"
run "start --new in the C locale" env LC_ALL=C LANG=C "$LOOMY" start --root "$PC" --new

# ------------------------------------------------------------------ configuration
section "Configuration"
run "config set plan_claude max20" "$LOOMY" config set plan_claude max20
run "config get plan_claude" "$LOOMY" config get plan_claude
has "value read back" "^max20$"
fails "invalid plan value refused" 2 "$LOOMY" config set plan_claude gratuit
fails "non-numeric price refused" 2 "$LOOMY" config set plan_codex_price beaucoup
run "config set overwrites without duplicating" "$LOOMY" config set plan_claude pro
if [[ "$(grep -c '^plan_claude=' "$XDG_CONFIG_HOME/loomy/config")" == "1" ]]; then ok "a single plan_claude line"; else ko "duplicate plan_claude"; fi
run "config list" "$LOOMY" config list
has "list: plan_claude=pro" "^plan_claude=pro$"
rm -f "$XDG_CONFIG_HOME/loomy/config"

# ------------------------------------------------------------------ routage
section "Routing"
P="$WORK/route"; mkdir -p "$P"
for env in claude codex hybrid-claude hybrid-codex; do
  for prof in econome equilibre qualite; do
    if "$LOOMY" route --root "$P" --env "$env" --profile "$prof" markdown >"$OUT" 2>&1 && grep -q '^| ' "$OUT"; then :; else ko "route $env / $prof"; continue 2; fi
  done
done
ok "matrix produced for 4 environments × 3 profiles"
cd "$P" || exit 1
run "route all" "$LOOMY" route all
has "route all: 4 environment columns" "Hybrid, Codex lead"
run "route lead" "$LOOMY" route lead
has "lead agent on the best model" "opus|astra"
run "route get executor" "$LOOMY" route get executor
if [[ "$(wc -w <"$OUT" | tr -d ' ')" == "3" ]]; then ok "route get: family model effort"; else ko "route get: unexpected format ($(cat "$OUT"))"; fi

# Fallback: without Codex, a hybrid mode falls back to Claude alone.
# Each environment puts the lead agent and the executor on the right family.
lead_of() { "$LOOMY" route --root "$P" --env "$1" get lead 2>/dev/null | cut -d' ' -f2; }
exec_of() { "$LOOMY" route --root "$P" --env "$1" get executor 2>/dev/null | cut -d' ' -f1; }
if [[ "$(lead_of claude)" == claude-opus* && "$(lead_of codex)" == gpt-6-astra && "$(lead_of hybrid-claude)" == claude-opus* && "$(lead_of hybrid-codex)" == gpt-6-astra ]]
then ok "lead agent: Opus on Claude, Astra on Codex"; else ko "lead agent misrouted ($(lead_of claude) / $(lead_of codex) / $(lead_of hybrid-claude) / $(lead_of hybrid-codex))"; fi
if [[ "$(exec_of claude)" == claude && "$(exec_of codex)" == codex && "$(exec_of hybrid-claude)" == codex ]]
then ok "executor: Luna in hybrid Claude lead"; else ko "executor misrouted"; fi
if [[ "$("$LOOMY" route --root "$P" --env claude --profile econome get lead)" != "$("$LOOMY" route --root "$P" --env claude --profile qualite get lead)" ]]
then ok "profiles change the lead agent effort"; else ko "profiles have no effect on the lead agent"; fi

# Fallback: a hybrid brief without Codex installed falls back to Claude alone.
mkdir -p "$P/.loomy" && printf -- '---\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' >"$P/.loomy/brief.md"
if [[ "$("$LOOMY" route --root "$P" get executor | cut -d' ' -f1)" == codex ]]; then ok "hybrid brief: executor on Codex"; else ko "hybrid brief: executor not on Codex"; fi
run "fallback without Codex" env LOOMY_CODEX_BIN=/inexistant "$LOOMY" route --root "$P" get executor
has "executor routed to Claude" "^claude "
rm -rf "$P/.loomy"

# ------------------------------------------------------------------ install into a project
section "loomy init (non-interactive)"
PROJ="$WORK/projet"; mkdir -p "$PROJ"
run "init --yes in an empty folder" "$LOOMY" init "$PROJ" --yes --no-clipboard
for f in START.md .loomy/brief.md .loomy/state .loomy/VERSION .loomy/scripts/ai-status.sh .loomy/templates/AGENTS.md; do
  if [[ -e "$PROJ/$f" ]]; then :; else ko "file missing after init: $f"; fi
done
ok "control plane files copied"
file_has "brief: complete front matter" "$PROJ/.loomy/brief.md" "^push_after_commit: "
file_has "initial phase: discovery" "$PROJ/.loomy/state" "^phase=discover$"
file_has ".gitignore: log excluded" "$PROJ/.gitignore" "^\.loomy/logs/$"
has "next step: terminal tracking" "loomy watch|ai-status.sh --watch"
if [[ ! -f "$XDG_CONFIG_HOME/loomy/config" ]] || ! grep -q '^plan_' "$XDG_CONFIG_HOME/loomy/config"; then ok "--yes saves no plan"; else ko "--yes saved a plan"; fi
fails "second init outside a terminal: guides without changing anything" 1 "$LOOMY" init "$PROJ" --no-wizard
has "second init: offers to resume" "loomy start"
has "second init: offers the update" "loomy init --update"
# Project update: scripts copied again, brief and phase kept.
echo "0.0.1" >"$PROJ/.loomy/VERSION"; rm -f "$PROJ/.loomy/scripts/ai-start.sh"; cp "$PROJ/.loomy/brief.md" "$WORK/brief.avant"
run "init --update" "$LOOMY" init "$PROJ" --update
file_has "update: project version up to date" "$PROJ/.loomy/VERSION" "^$(cat "$REPO/VERSION")$"
[[ -f "$PROJ/.loomy/scripts/ai-start.sh" ]] && ok "update: new scripts copied" || ko "update: scripts missing"
cmp -s "$PROJ/.loomy/brief.md" "$WORK/brief.avant" && ok "update: brief kept" || ko "update: brief modified"
file_has "update: phase kept" "$PROJ/.loomy/state" "^phase=discover$"
fails "update without project refused" 1 "$LOOMY" init "$WORK/pas-un-projet-$$" --update
mkdir -p "$WORK/pas-un-projet-$$"
fails "update without project refused" 1 "$LOOMY" init "$WORK/pas-un-projet-$$" --update
PR="$WORK/projet-reset"; mkdir -p "$PR"
run "init of a project to reset" "$LOOMY" init "$PR" --yes --no-clipboard
"$LOOMY" status --root "$PR" set build >/dev/null 2>&1
run "init --reset --no-wizard" "$LOOMY" init "$PR" --reset --no-wizard
[[ ! -f "$PR/.loomy/state" && -f "$PR/.loomy/brief.previous.md" && -f "$PR/START.md" ]] && ok "reset: phase reset, old brief kept, START.md present" || ko "reset incomplete"
FS="$WORK/start-etranger"; mkdir -p "$FS" && echo "autre" >"$FS/START.md"
fails "foreign START.md refused" 1 "$LOOMY" init "$FS" --no-wizard
PROJ2="$WORK/projet2"; mkdir -p "$PROJ2"
run "init --answers reuses a brief" "$LOOMY" init "$PROJ2" --answers "$PROJ/.loomy/brief.md" --yes --no-clipboard
file_has "brief reused: same name" "$PROJ2/.loomy/brief.md" "^name: "

# ------------------------------------------------------------------ start or resume
section "loomy start"
L="$WORK/start.log"
(cd "$PROJ" && "$LOOMY" start) >"$OUT" 2>&1; st=$?
if [[ $st == 0 ]]; then ok "start outside a terminal: shows the commands"; else ko "start outside a terminal (code $st)"; fi
has "start: lead agent command" "claude --model claude-opus"
has "start: bootstrap startup prompt" "Set up this project by strictly following START.md"
hasnt "start: no resume without a session" "resume:"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --new) >"$OUT" 2>&1
if grep -q $'^claude\t--model\tclaude-opus[^\t]*\t--effort\t[a-z]*\tSet up this project' "$L" 2>/dev/null; then ok "start --new runs claude with model, effort and prompt"; else ko "start --new: unexpected call ($(cat "$L" 2>/dev/null))"; fi
: >"$L"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --resume) >"$OUT" 2>&1
if grep -q $'\tSet up this project' "$L" && ! grep -q -- '--continue' "$L"; then ok "start --resume without a session: new session"; else ko "start --resume without a session ($(cat "$L"))"; fi
SESS="$HOME/.claude/projects/$(cd "$PROJ" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$SESS" && touch "$SESS/s.jsonl"
: >"$L"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --resume) >"$OUT" 2>&1
if grep -q $'^claude\t--continue\t--model' "$L"; then ok "start --resume resumes the folder session"; else ko "start --resume ($(cat "$L"))"; fi
(cd "$PROJ" && "$LOOMY" start --print) >"$OUT" 2>&1
has "start: resume offered when a session exists" "resume: claude --continue"
rm -rf "$HOME/.claude/projects"
# Project led by Codex.
PX="$WORK/projet-codex"; mkdir -p "$PX/.loomy" && printf -- '---\nname: X\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\n---\n' >"$PX/.loomy/brief.md" && touch "$PX/START.md"
: >"$L"
(cd "$PX" && STUB_LOG="$L" "$LOOMY" start --new) >"$OUT" 2>&1
if grep -q $'^codex\t-m\tgpt-6-astra\t-c\tmodel_reasoning_effort=' "$L"; then ok "start --new runs codex when Codex leads"; else ko "start codex ($(cat "$L"))"; fi
fails "start without brief refused" 1 "$LOOMY" start --root "$WORK/route-vide-$$"
mkdir -p "$WORK/route-vide-$$"
fails "start without brief refused" 1 "$LOOMY" start --root "$WORK/route-vide-$$"

# ------------------------------------------------------------------ scenarios
section "Scenarios"
# Loomy project in a subfolder of a Git repository: found from any subfolder.
MONO="$WORK/mono"; mkdir -p "$MONO/apps/site/src"
git -C "$MONO" init -q && git -C "$MONO" commit -q --allow-empty -m init
run "init in a subfolder of a repository" "$LOOMY" init "$MONO/apps/site" --yes --no-clipboard
(cd "$MONO/apps/site/src" && "$LOOMY" status) >"$OUT" 2>&1
has "status from a subfolder: project found" "Project status +~?.*apps/site"
(cd "$MONO/apps/site/src" && "$LOOMY" delegate claude explorer "sous-dossier") >/dev/null 2>&1
[[ -s "$MONO/apps/site/.loomy/logs/events.jsonl" ]] && grep -q '"type":"delegation",' "$MONO/apps/site/.loomy/logs/events.jsonl" && ok "delegation logged in the subfolder project" || ko "delegation not logged in the subfolder"
(cd "$MONO/apps/site/src" && "$LOOMY" start --print) >"$OUT" 2>&1
has "start from a subfolder" "claude --model"
# loomy brief outside a project, and brief redone midway.
(cd "$WORK" && mkdir -p hors-projet && cd hors-projet && "$LOOMY" brief) >"$OUT" 2>&1; st=$?
[[ $st == 1 ]] && grep -q "loomy init" "$OUT" && ok "brief outside a project: points to loomy init" || ko "brief outside a project (code $st)"
[[ ! -e "$WORK/hors-projet/.loomy" ]] && ok "brief outside a project: nothing created" || ko "brief outside a project: .loomy created"
"$LOOMY" status --root "$MONO/apps/site" set build >/dev/null 2>&1
(cd "$MONO/apps/site" && "$LOOMY" brief --yes --no-clipboard) >/dev/null 2>&1
file_has "brief redone midway: phase kept" "$MONO/apps/site/.loomy/state" "^phase=build$"
# Folders that aren't projects.
(cd "$HOME" && "$LOOMY" init --no-wizard) >"$OUT" 2>&1; st=$?
[[ $st == 1 && ! -e "$HOME/START.md" ]] && ok "init refused in the home folder" || ko "init in the home folder (code $st)"
# loomy init creates the given folder, and guides outside a terminal when no folder is given in the wrong place.
run "init of a folder that doesn't exist yet" "$LOOMY" init "$WORK/cree-par-init/app" --yes --no-clipboard
[[ -f "$WORK/cree-par-init/app/.loomy/brief.md" ]] && ok "init: folder created and project set up" || ko "init: folder not created"
(cd "$HOME" && "$LOOMY" init --no-wizard) >"$OUT" 2>&1
has "init outside a terminal in the home folder: suggests loomy init <name>" "loomy init my-project"
if command -v expect >/dev/null 2>&1; then
  PARENT="$WORK/parent"; mkdir -p "$PARENT/autre" "$PARENT/encore"
  cat >"$WORK/init-dossier.exp" <<EXP
set timeout 20
cd "$PARENT"
spawn "$LOOMY" init --no-clipboard
expect "Project name" ; expect "⏎ confirm" ; send "Projet Été 2026\r"
expect "Where to create the project" ; expect "⏎ confirm" ; send "\r"
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {Open the lead agent session} { expect "⏎ confirm" ; send "\033\[B" ; after 300 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  run "interactive init from a parent folder" expect "$WORK/init-dossier.exp"
  D="$PARENT/projet-ete-2026"
  [[ -n "$D" && -f "$D/.loomy/brief.md" ]] && ok "init: folder created from the project name ($(basename "$D"))" || ko "init: project folder missing ($(ls "$PARENT" | tr '\n' ' '))"
  [[ -n "$D" ]] && file_has "init: project name kept in the brief" "$D/.loomy/brief.md" '^name: "Projet Été 2026"$'
  has "init: reminder to cd into the new folder" "cd projet-"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
fi

# New project in a folder that is itself inside a Git repository: dedicated repository offered, then GitHub repository.
if command -v expect >/dev/null 2>&1; then
  PARD="$WORK/parent-git"; mkdir -p "$PARD" && git -C "$PARD" init -q && git -C "$PARD" commit -q --allow-empty -m parent
  cat >"$WORK/dans-parent.exp" <<EXP
set timeout 20
cd "$PARD"
spawn "$LOOMY" init sous-projet --no-clipboard
for {set i 0} {\$i < 80} {incr i} {
  expect {
    -re {Open the lead agent session} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  run "init in a subfolder of a parent repository" expect "$WORK/dans-parent.exp"
  has "dedicated repository offered" "Create a dedicated Git repository for this project"
  [[ -d "$PARD/sous-projet/.git" ]] && ok "dedicated Git repository created for the project" || ko "no dedicated repository"
  [[ "$(git -C "$PARD/sous-projet" config --get remote.origin.url)" == "https://github.com/testeur/sous-projet.git" ]] && ok "GitHub repository created in the dedicated repository" || ko "remote: $(git -C "$PARD/sous-projet" config --get remote.origin.url)"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
fi

# Full screen: loomy watch redraws in place, without piling anything into the terminal history; q quits.
TMUX_BIN="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v tmux || true)"
tmux() { "$TMUX_BIN" "$@"; }
if [[ -n "$TMUX_BIN" && -d "${PARD:-}/sous-projet" ]]; then
  tmux -L loomy-test kill-server 2>/dev/null || true
  tmux -L loomy-test new-session -d -s w -x 100 -y 30 -c "$PARD/sous-projet" "bash '$LOOMY' watch 1; echo SORTIE_OK; sleep 30"
  sleep 4
  [[ "$(tmux -L loomy-test display -p -t w '#{history_size}')" == "0" ]] && ok "watch: nothing piles up in the history" || ko "watch: history $(tmux -L loomy-test display -p -t w '#{history_size}')"
  tmux -L loomy-test send-keys -t w q; sleep 1.5
  tmux -L loomy-test capture-pane -t w -p | grep -q SORTIE_OK && ok "watch: q quits and restores the normal screen" || ko "watch: q doesn't quit"
  tmux -L loomy-test kill-server 2>/dev/null || true
  # Home: full-screen app with a fixed frame; views open inside the frame, q quits leaving nothing behind.
  # Active wait (slower continuous integration machines): up to 20 s for the expected text to show up.
  tw() { local k=0; until tmux -L loomy-test capture-pane -t h -p 2>/dev/null | grep -q "$1"; do sleep 0.25; k=$(( k + 1 )); (( k > 80 )) && return 1; done; return 0; }
  # The previous test's tmux server must be stopped before starting another one under the same name (otherwise "server exited
  # unexpectedly" on slow machines); launch retried if needed.
  tstart() {
    local k=0
    while tmux -L loomy-test ls >/dev/null 2>&1 && (( k < 20 )); do tmux -L loomy-test kill-server 2>/dev/null || true; sleep 0.25; k=$(( k + 1 )); done
    for k in 1 2 3; do tmux -L loomy-test new-session -d "$@" 2>/dev/null && return 0; sleep 0.5; done
    return 1
  }
  tstart -s h -x 100 -y 34 -c "$PARD/sous-projet" "bash '$LOOMY'; echo FIN_ACCUEIL; sleep 60"
  tw "What do you want to do" && tmux -L loomy-test capture-pane -t h -p | tail -1 | grep -q "loomy" \
    && ok "home: frame (menu in the body, version in the footer)" || ko "home: frame missing"
  tmux -L loomy-test send-keys -t h Down Down; sleep 0.5; tmux -L loomy-test send-keys -t h Enter
  tw "PHASES" && tmux -L loomy-test capture-pane -t h -p | grep -q "Detailed status" \
    && ok "home: status shown in the frame" || ko "home: status view missing"
  tmux -L loomy-test send-keys -t h Enter
  tw "What do you want to do" && ok "home: back from the view" || ko "home: no way back"
  tmux -L loomy-test send-keys -t h q
  if tw "FIN_ACCUEIL" && ! tmux -L loomy-test capture-pane -t h -p -S -200 | grep -q "What do you want to do"; then
    ok "home: q quits, nothing left in the terminal"
  else ko "home: exit"; fi
  tmux -L loomy-test kill-server 2>/dev/null || true
  # loomy start --watch in tmux: a tracking pane next to the agent, closed with it.
  mkdir -p "$WORK/lent"
  printf '#!/bin/bash\n[[ "$1" == "--version" ]] && { echo "2.1.300 (Claude Code)"; exit 0; }\nsleep 4\n' >"$WORK/lent/claude"; chmod +x "$WORK/lent/claude"
  tstart -s s -x 120 -y 50 -c "$PARD/sous-projet" "PATH='$WORK/lent':'$(dirname "$TMUX_BIN")':\$PATH bash '$LOOMY' start --new --watch; sleep 30"
  sleep 2.5
  [[ "$(tmux -L loomy-test list-panes -t s | wc -l | tr -d ' ')" == "2" ]] && ok "start --watch: tracking pane open" || ko "start --watch: $(tmux -L loomy-test list-panes -t s | wc -l) pane(s)"
  sleep 5
  [[ "$(tmux -L loomy-test list-panes -t s | wc -l | tr -d ' ')" == "1" ]] && ok "start --watch: tracking closed with the session" || ko "start --watch: tracking still open"
  tmux -L loomy-test kill-server 2>/dev/null || true
fi

# UTF-8 locale picked even under pipefail (otherwise slow text measuring and split accents).
loc="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'set -euo pipefail; source "$1/scripts/lib/models.sh"; p="é"; echo "${#p}"' _ "$REPO")"
[[ "$loc" == "1" ]] && ok "locale UTF-8 choisie sous pipefail" || ko "locale not picked under pipefail ($loc)"
fit="$(env -i PATH=/usr/bin:/bin LC_ALL=C bash -c 'source "$1/scripts/lib/ui.sh"; _ui_fit "prompt de démarrage prêt" 13; printf "%s" "$UI_FIT"' _ "$REPO")"
[[ "$fit" == "prompt de dé…" ]] && ok "truncation by characters (accents intact)" || ko "truncation: $fit"
steps="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'source "$1/scripts/lib/ui.sh"; ui_steps_begin "MISE EN PLACE" "Étape A" "Étape B"; ui_step_run 0; ui_step_done 0 ok "A faite" "détail"; ui_step_run 1; ui_step_done 1 warn "B partielle" "à revoir"; ui_steps_end' _ "$REPO" 2>&1)"
grep -q "✓ A faite détail" <<<"$steps" && grep -q "! B partielle à revoir" <<<"$steps" && ok "steps: final lines outside full screen" || ko "steps: $steps"

# Readable log and loomy watch views.
if [[ -s "$PROJ/.loomy/logs/events.jsonl" ]]; then
  run "readable loomy log" bash "$REPO/scripts/ai-log.sh" --root "$PROJ" -n 5
  if grep -q '^{' "$OUT"; then ko "loomy log: raw JSON instead of the readable format"; else ok "loomy log: readable format"; fi
  run "loomy log --raw" bash "$REPO/scripts/ai-log.sh" --root "$PROJ" -n 1 --raw
  has "loomy log --raw: JSON" '^\{"ts"'
  run "watch log view" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-status.sh" --root "$PROJ" --compact --journal
  has "log view: LOG section" "◇  LOG"
fi
run "compact view" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-status.sh" --root "$PROJ" --compact
if grep -q "FICHIERS IA" "$OUT"; then ko "compact view: detailed sections present"; else ok "compact view: detailed sections absent"; fi

# Resumed session (claude --continue): same id, a new start after an end = open session.
RS="$WORK/reprise"; mkdir -p "$RS/.loomy/logs"; : >"$RS/.loomy/brief.md"
sleep 60 & RPID=$!
printf '%s\n' '{"ts":"2026-09-25T00:00:00Z","type":"session","event":"start","tool":"claude","session":"abc","pid":1}' \
  '{"ts":"2026-09-25T00:10:00Z","type":"session","event":"end","tool":"claude","session":"abc","pid":1}' \
  "{\"ts\":\"2026-09-25T09:00:00Z\",\"type\":\"session\",\"event\":\"start\",\"tool\":\"claude\",\"session\":\"abc\",\"pid\":$RPID}" >"$RS/.loomy/logs/events.jsonl"
st="$(bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_session_state "$2"' _ "$REPO" "$RS")"
[[ "$st" == open* ]] && ok "resumed session seen as open" || ko "resumed session: $st"
kill "$RPID" 2>/dev/null || true

# loomy effort: effort set per project, over the profile, used by loomy start.
if [[ -f "$PROJ/.loomy/brief.md" ]]; then
  run "lead agent effort set" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-effort.sh" --root "$PROJ" low
  grep -qx "lead=low" "$PROJ/.loomy/efforts" && ok "effort saved in .loomy/efforts" || ko "effort not saved"
  run "start --print with the set effort" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-start.sh" --root "$PROJ" --print
  has "start uses the set effort" "effort low"
  fails "effort: unknown level refused" 2 bash "$REPO/scripts/ai-effort.sh" --root "$PROJ" turbo
  run "effort --reset" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-effort.sh" --root "$PROJ" --reset
  [[ ! -f "$PROJ/.loomy/efforts" ]] && ok "effort back to the profile" || ko "setting still present"
fi

# loomy feedback: anonymised issue text (no name, goal or task text), nothing sent with --print.
FB="$WORK/retour"; mkdir -p "$FB/.loomy/logs"
printf -- '---\nname: "NomSecret42"\ngoal: "ObjectifSecret42"\ntype: web\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' >"$FB/.loomy/brief.md"
printf 'phase=build\n' >"$FB/.loomy/state"
printf '%s\n' '{"ts":"2026-09-25T10:00:00Z","type":"delegation","id":"f1","role":"executor","family":"codex","model":"gpt-6-luna","status":"ok","duration_s":5,"cost_usd":0.001,"task":"TacheSecrete42"}' >"$FB/.loomy/logs/events.jsonl"
run "feedback --print" bash "$REPO/scripts/ai-feedback.sh" --root "$FB" --print "un retour de test"
has "feedback: message attached" "un retour de test"
has "feedback: versions attached" "\| Loomy \|"
has "feedback: project state attached" "phase build"
if grep -qE "NomSecret42|ObjectifSecret42|TacheSecrete42|$FB" "$OUT"; then ko "feedback: project data leaked"; else ok "feedback: no name, goal, path or task text"; fi

# Project relays: no more script copies; they find Loomy through the loomy command in the PATH.
if [[ -d "$PROJ/.loomy/scripts" ]]; then
  [[ ! -d "$PROJ/.loomy/scripts/lib" ]] && ok "relays: no more library copied into the project" || ko "relays: lib copied"
  mkdir -p "$WORK/bin-loomy" && ln -sf "$REPO/bin/loomy" "$WORK/bin-loomy/loomy"
  run "relays without LOOMY_HOME, through the PATH" env -u LOOMY_HOME PATH="$WORK/bin-loomy:$PATH" bash "$PROJ/.loomy/scripts/ai-route.sh" lead
  has "relays: lead agent routing" "claude|codex"
  fails "relays: clear message without Loomy" 127 env -u LOOMY_HOME LOOMY_RELAY_PATHS= PATH=/usr/bin:/bin bash "$PROJ/.loomy/scripts/ai-route.sh" lead
fi

# Catalog: the repository one matches the built-in values; a newer downloaded catalog replaces them,
# without ever running its content.
cat_vals="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CATALOG_DATE $AI_MODEL_CLAUDE_TOP $AI_MODEL_CLAUDE_MID $AI_MODEL_CLAUDE_FAST $AI_MODEL_CODEX_TOP $AI_MODEL_CODEX_MID $AI_MODEL_CODEX_FAST"' _ "$REPO")"
file_vals="$(awk -F= '/^date=/{d=$2} /^model\.claude\.top=/{a=$2} /^model\.claude\.mid=/{b=$2} /^model\.claude\.fast=/{c=$2} /^model\.codex\.top=/{e=$2} /^model\.codex\.mid=/{f=$2} /^model\.codex\.fast=/{g=$2} END{print d, a, b, c, e, f, g}' "$REPO/catalog/models.conf")"
[[ "$cat_vals" == "$file_vals" ]] && ok "repository catalog = built-in values" || ko "catalog: $cat_vals ≠ $file_vals"
mkdir -p "$XDG_CONFIG_HOME/loomy"
sed 's/^date=.*/date=2099-01-01/; s/^model.codex.fast=.*/model.codex.fast=luna-test/; s/^price.gpt-6-sol=.*/price.gpt-6-sol=9 9 9/' "$REPO/catalog/models.conf" >"$XDG_CONFIG_HOME/loomy/catalog.conf"
echo 'model.claude.top=$(touch '"$WORK"'/injecte)' >>"$XDG_CONFIG_HOME/loomy/catalog.conf"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CATALOG_SOURCE $AI_MODEL_CODEX_FAST $AI_MODEL_CLAUDE_TOP $(ai_price gpt-6-sol)"' _ "$REPO")"
[[ "$got" == "downloaded luna-test claude-opus-5-5 9 9 9" ]] && ok "downloaded catalog taken into account" || ko "downloaded catalog: $got"
[[ ! -e "$WORK/injecte" ]] && ok "catalog: content never executed" || ko "catalog: injection executed"
echo 'model.claude.mid=--dangerously-skip-permissions, claude-sonnet-5' >>"$XDG_CONFIG_HOME/loomy/catalog.conf"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_MODEL_CLAUDE_MID"' _ "$REPO")"
[[ "$got" != -* ]] && ok "catalog: a model id never starts with a hyphen" || ko "catalog: option injected ($got)"
rm -f "$XDG_CONFIG_HOME/loomy/catalog.conf"

# Fallback chains: first available model, fallback when refused or missing from Codex, pinning, rebalancing.
CH="$WORK/chaines"; mkdir -p "$CH/cfg/loomy" "$CH/codex"
printf '%s\n' 'date=2099-01-01' 'model.claude.mid=claude-sonnet-9, claude-sonnet-5' 'model.codex.top=gpt-9-astra, gpt-6-astra' 'route.claude.explorer=MID low' >"$CH/cfg/loomy/catalog.conf"
echo '{"models":[{"slug":"gpt-6-astra"}]}' >"$CH/codex/models_cache.json"
chq() { XDG_CONFIG_HOME="$CH/cfg" CODEX_HOME="$CH/codex" bash -c 'source "$1/scripts/lib/models.sh"; ai_route explorer claude equilibre; echo "$AI_MODEL_CLAUDE_MID $AI_MODEL_CODEX_TOP $R_MODEL $R_EFFORT"' _ "$REPO"; }
[[ "$(chq)" == "claude-sonnet-9 gpt-6-astra claude-sonnet-9 low" ]] && ok "chains: newest first, Codex limited to its models, role rebalanced" || ko "chains: $(chq)"
echo "claude-sonnet-9=ko" >"$CH/cfg/loomy/models.state"
[[ "$(chq)" == "claude-sonnet-5 gpt-6-astra claude-sonnet-5 low" ]] && ok "chains: fallback when the model is refused" || ko "fallback: $(chq)"
echo "model.claude.mid=claude-sonnet-4" >"$CH/cfg/loomy/config"
[[ "$(chq)" == "claude-sonnet-4 gpt-6-astra claude-sonnet-4 low" ]] && ok "chains: pinned model takes priority" || ko "pinning: $(chq)"

# Real Claude Code cost: Stop and SubagentStop hooks, read from the transcript (no duplicates, no rereading).
US="$WORK/usage"; mkdir -p "$US/.loomy"; : >"$US/.loomy/brief.md"
TR="$WORK/transcript.jsonl"
for i in 1 1 2; do printf '{"type":"assistant","message":{"id":"msg_%s","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$i"; done >"$TR"
printf '{"session_id":"s","transcript_path":"%s"}' "$TR" | LOOMY_HOME="$REPO" bash "$REPO/scripts/ai-context.sh" --root "$US" --hook stop
printf '{"session_id":"s","transcript_path":"%s"}' "$TR" | LOOMY_HOME="$REPO" bash "$REPO/scripts/ai-context.sh" --root "$US" --hook stop
n_usage="$(grep -c '"type":"usage"' "$US/.loomy/logs/events.jsonl" 2>/dev/null || echo 0)"
[[ "$n_usage" == "1" ]] && ok "usage: one event, transcript not reread" || ko "usage: $n_usage event(s)"
grep -q '"messages":2,.*"cost_usd":2.000000' "$US/.loomy/logs/events.jsonl" && ok "usage: duplicates discarded, cost at public price" || ko "usage: $(cat "$US/.loomy/logs/events.jsonl")"
printf '{"session_id":"s2","transcript_path":"%s"}' "$TR" | LOOMY_DELEGATION=1 bash "$REPO/scripts/ai-context.sh" --root "$US" --hook start
grep -q '"session":"s2"' "$US/.loomy/logs/events.jsonl" && ko "Loomy delegation counted as a session" || ok "Loomy delegations ignored by the hooks"
run "status: lead agent cost" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/ai-status.sh" --root "$US"
has "status: lead agent measured" "Lead agent .*2 repl"
run "log --csv" bash "$REPO/scripts/ai-log.sh" --root "$US" --csv
has "csv: header" "^date_utc,type,role"
has "csv: lead agent cost" "usage,lead,,claude,claude-haiku-4-5-20251001,ok"

# Log: monthly archive, full history for --since.
AR="$WORK/archive"; mkdir -p "$AR/.loomy/logs"; : >"$AR/.loomy/brief.md"
printf '%s\n' '{"ts":"2000-01-05T10:00:00Z","type":"phase","phase":"build"}' >"$AR/.loomy/logs/events.jsonl"
bash "$REPO/scripts/ai-status.sh" --root "$AR" set verify >/dev/null
[[ -f "$AR/.loomy/logs/archive/events-2000-01.jsonl" ]] && ok "log: previous month archived" || ko "log: no archive"
run "log --since in the archives" bash "$REPO/scripts/ai-log.sh" --root "$AR" --since 2000-01-01
has "log --since: archived event" "Build"

# Claude Code hooks: Stop and SubagentStop added to an existing settings.json, leaving the user's hooks alone.
HK="$WORK/hooks"; mkdir -p "$HK/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo perso"}]}]}}\n' >"$HK/.claude/settings.json"
UI_ASSUME_DEFAULTS=1 bash "$LOOMY" init "$HK" --yes >/dev/null 2>&1 || true
grep -q 'echo perso' "$HK/.claude/settings.json" && grep -q -- '--hook stop' "$HK/.claude/settings.json" && grep -q -- '--hook subagent' "$HK/.claude/settings.json" \
  && ok "Stop and SubagentStop hooks added, existing hooks kept" || ko "hooks: $(cat "$HK/.claude/settings.json")"

# Help and side commands.
run "help init" "$LOOMY" help init
has "help <command>: command help" "Usage: loomy init"
run "update --help updates nothing" "$LOOMY" update --help
has "update --help: help" "Usage: loomy update"
run "uninstall" "$LOOMY" uninstall
has "uninstall: removal command" "rm |uninstall"
has "uninstall: removing a project" "rm -rf .loomy START.md"

# ------------------------------------------------------------------ AI files visibility
section "AI files visibility (loomy privacy)"
PV="$WORK/prive"; mkdir -p "$PV"
run "project for loomy privacy" "$LOOMY" init "$PV" --yes --no-clipboard
file_has "brief: ai_files versioned by default" "$PV/.loomy/brief.md" "^ai_files: versioned$"
mkdir -p "$PV/.ai" && echo "# agents" >"$PV/AGENTS.md" && echo "rules" >"$PV/.ai/AI_WORKFLOW.md" && echo "code" >"$PV/app.txt"
git -C "$PV" add -A && git -C "$PV" commit -qm "with AI files"
run "privacy local" "$LOOMY" privacy --root "$PV" local
file_has "local: mode recorded in the brief" "$PV/.loomy/brief.md" "^ai_files: local$"
file_has "local: exclusion set in .git/info/exclude" "$PV/.git/info/exclude" "^/AGENTS.md$"
has "local: files already tracked flagged" "Still tracked by the project repository"
has "local: command to stop tracking them" "git rm -r --cached"
git -C "$PV" rm -r -q --cached -- .loomy START.md AGENTS.md .ai .claude >/dev/null && git -C "$PV" commit -qm "AI files out of the repository"
[[ -z "$(git -C "$PV" status --porcelain)" ]] && ok "local: AI files no longer show in git status" || ko "local: AI files still visible ($(git -C "$PV" status --porcelain | head -3 | tr '\n' ' '))"
[[ -f "$PV/AGENTS.md" && -f "$PV/.loomy/brief.md" ]] && ok "local: files kept on disk" || ko "local: files lost"
if git -C "$PV" check-ignore -q .gitignore; then ko ".gitignore excluded by mistake"; else ok "the rest of the project stays versioned"; fi
# Separate private repository (local repository instead of GitHub).
BARE="$WORK/prive-ai.git"; git init --bare -q -b main "$BARE"
run "privacy private --remote" "$LOOMY" privacy --root "$PV" private --remote "$BARE"
file_has "private: mode recorded" "$PV/.loomy/brief.md" "^ai_files: private$"
git --git-dir="$BARE" ls-tree -r --name-only main >"$OUT" 2>&1
has "private: AGENTS.md backed up" "^AGENTS.md$"
has "private: brief backed up" "^.loomy/brief.md$"
hasnt "private: project code absent from the private repository" "^app.txt$"
hasnt "private: log absent from the private repository" "^.loomy/logs/"
echo "new rule" >>"$PV/AGENTS.md"
"$LOOMY" status --root "$PV" >"$OUT" 2>&1
has "status: unsaved changes flagged" "unsaved change"
run "privacy sync" "$LOOMY" privacy --root "$PV" sync
[[ "$(git --git-dir="$BARE" show main:AGENTS.md | tail -1)" == "new rule" ]] && ok "sync: change pushed" || ko "sync: change missing"
# Second machine: project clone (without AI files), then restore.
M2="$WORK/machine2"; git clone -q "$PV" "$M2"
[[ ! -e "$M2/AGENTS.md" ]] && ok "clone: AI files absent from the project repository" || ko "clone: AI files present"
echo "different local version" >"$M2/AGENTS.md"
run "privacy restore" "$LOOMY" privacy --root "$M2" restore "$BARE"
[[ -f "$M2/AGENTS.md" && -f "$M2/.loomy/brief.md" && -f "$M2/.ai/AI_WORKFLOW.md" ]] && ok "restore: AI files recovered" || ko "restore: files missing"
has "restore: different local files set aside" "set aside"
file_has "restore: exclusion set on the new machine" "$M2/.git/info/exclude" "^/AGENTS.md$"
[[ -z "$(git -C "$M2" status --porcelain)" ]] && ok "restore: project repository clean" || ko "restore: project repository modified"
echo "depuis la machine 2" >>"$M2/AGENTS.md"
run "sync from the second machine" "$LOOMY" privacy --root "$M2" sync
run "sync of the first machine after the second" "$LOOMY" privacy --root "$PV" sync
run "back to versioned mode" "$LOOMY" privacy --root "$PV" versioned
if grep -q "loomy : fichiers IA" "$PV/.git/info/exclude"; then ko "versioned: exclusion still present"; else ok "versioned: exclusion removed"; fi
fails "sync outside private mode refused" 1 "$LOOMY" privacy --root "$PV" sync
# Project in a subfolder: patterns anchored on the subfolder.
run "privacy local in a subfolder" "$LOOMY" privacy --root "$MONO/apps/site" local
file_has "subfolder: prefixed pattern" "$MONO/.git/info/exclude" "^/apps/site/AGENTS.md$"

# ------------------------------------------------------------------ session continuity
section "Continuity (context, hooks, sessions, home)"
PC2="$WORK/continuite"
run "init for continuity" "$LOOMY" init "$PC2" --yes --no-clipboard
file_has "Claude Code hooks installed" "$PC2/.claude/settings.json" 'ai-context.sh\\" --hook start'
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PC2/.claude/settings.json" && ok "settings.json valide" || ko "settings.json invalide"
  PM="$WORK/fusion"; mkdir -p "$PM/.claude" && echo '{"permissions":{"allow":["Bash(ls:*)"]}}' >"$PM/.claude/settings.json"
  "$LOOMY" init "$PM" --yes --no-clipboard >/dev/null 2>&1
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['permissions']['allow']==['Bash(ls:*)'] and d['hooks']['SessionStart']" "$PM/.claude/settings.json" \
    && ok "existing settings.json: hooks added, settings kept" || ko "existing settings.json badly merged"
fi
file_has "Codex hooks installed" "$PC2/.codex/hooks.json" 'ai-context.sh.*--hook start --tool codex'
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PC2/.codex/hooks.json" && ok ".codex/hooks.json valide" || ko ".codex/hooks.json invalide"
  CX_CMD="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hooks']['SessionStart'][0]['hooks'][0]['command'])" "$PC2/.codex/hooks.json")"
  mkdir -p "$PC2/src/deep"
  (cd "$PC2/src/deep" && echo '{"session_id":"cx-test","source":"startup"}' | eval "$CX_CMD") >"$OUT" 2>&1
  has "Codex hook from a subfolder: context returned" "Resume context"
  file_has "Codex hook: session recorded with the codex tool" "$PC2/.loomy/logs/events.jsonl" '"tool":"codex","session":"cx-test"'
  echo '{"session_id":"cx-test"}' | (cd "$PC2" && bash .loomy/scripts/ai-context.sh --hook end --tool codex) >/dev/null 2>&1
fi
bash "$PC2/.loomy/scripts/ai-context.sh" >"$OUT" 2>&1
has "context: project and phase" "Resume context for project"
has "context: resume instruction" "Resume START.md from this phase"
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status: no session → open the session" "open the lead agent session"
echo '{"session_id":"s-test","source":"startup"}' | bash "$PC2/.loomy/scripts/ai-context.sh" --hook start >"$OUT" 2>&1
has "start hook: context returned to Claude" "Resume context"
file_has "start hook: session recorded" "$PC2/.loomy/logs/events.jsonl" '"type":"session","event":"start"'
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status: session open" "Lead agent session open since"
echo '{"session_id":"s-test"}' | bash "$PC2/.loomy/scripts/ai-context.sh" --hook end >/dev/null 2>&1
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status: session closed" "closed at"
has "status: resume instruction" "reopen the lead agent session"
(cd "$PC2" && "$LOOMY") >"$OUT" 2>&1
has "loomy alone outside a terminal: help" "◇  TRACKING"

# ------------------------------------------------------------------ repository name
section "Repository name consistent with the project"
file_has "brief: technical name" "$PC2/.loomy/brief.md" "^slug: continuite$"
file_has "brief: --yes creates no GitHub repository" "$PC2/.loomy/brief.md" "^github_repo: no$"
[[ -z "$(git -C "$PC2" remote)" ]] && ok "--yes: no remote added" || ko "--yes: remote added"
PR2="$WORK/nom-different"; mkdir -p "$PR2" && git -C "$PR2" init -q && git -C "$PR2" remote add origin "https://github.com/testeur/autre-nom.git"
run "init with a differently named remote repository" "$LOOMY" init "$PR2" --yes --no-clipboard
file_has "name mismatch flagged in the brief" "$PR2/.loomy/brief.md" "remote repository 'autre-nom', project name 'nom-different'"
file_has "brief: existing repository name" "$PR2/.loomy/brief.md" "^repo_name: autre-nom$"
PV2="$WORK/prive-gh"
run "project for a private repository created by gh" "$LOOMY" init "$PV2" --yes --no-clipboard
run "privacy private without --remote (simulated GitHub)" "$LOOMY" privacy --root "$PV2" private
[[ -d "$GH_STUB_REMOTES/testeur/prive-gh-ai.git" ]] && ok "private repository named after the project (prive-gh-ai)" || ko "private repository missing or misnamed ($(ls "$GH_STUB_REMOTES/testeur" 2>/dev/null | tr '\n' ' '))"
git --git-dir="$GH_STUB_REMOTES/testeur/prive-gh-ai.git" ls-tree -r --name-only main 2>/dev/null | grep -q '^.loomy/brief.md$' && ok "private repository: AI files pushed" || ko "private repository empty"
file_has "brief: private repository name" "$PV2/.loomy/brief.md" "^ai_repo_name: prive-gh-ai$"

# ------------------------------------------------------------------ questionnaire interactif
section "loomy init (interactive, real terminal via expect)"
if command -v expect >/dev/null 2>&1; then
  # Confirms each question with its default value (Enter), in a pseudo-terminal.
  wizard_expect() {
    cat >"$WORK/wizard.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
    WIZ_DIR="$1" expect "$WORK/wizard.exp"
  }
  W1="$WORK/interactif1"; mkdir -p "$W1"
  run "full questionnaire, plans not set" wizard_expect "$W1"
  has "14 steps when plans must be asked" "question 14/14"
  has "Claude plan question" "your Claude plan"
  file_has "plans saved" "$XDG_CONFIG_HOME/loomy/config" "^plan_codex=api$"
  file_has "brief written" "$W1/.loomy/brief.md" "^ai_mode: "
  [[ "$(git -C "$W1" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/interactif1.git" && -d "$GH_STUB_REMOTES/testeur/interactif1.git" ]] && ok "GitHub repository created with the project name" || ko "unexpected remote: $(git -C "$W1" config --get remote.origin.url 2>&1)"
  file_has "brief: private GitHub repository" "$W1/.loomy/brief.md" "^github_repo: private$"
  W2="$WORK/interactif2"; mkdir -p "$W2"
  run "full questionnaire, plans already known" wizard_expect "$W2"
  has "13 steps" "question 13/13"
  hasnt "questionnaire: no raw variable on screen" '\$save_desc|\$\(t '
  hasnt "plans not asked again" "your Claude plan|/14"
  # GitHub repository name already taken: never overwritten; another name (default) or the existing repository linked.
  mkdir -p "$GH_STUB_REMOTES/testeur" && git init --bare -q -b main "$GH_STUB_REMOTES/testeur/deja-pris.git"
  git clone -q "$GH_STUB_REMOTES/testeur/deja-pris.git" "$WORK/i3-seed" 2>/dev/null && git -C "$WORK/i3-seed" add -A 2>/dev/null; echo "# Initial specs" >"$WORK/i3-seed/SPECS.md"; git -C "$WORK/i3-seed" add SPECS.md && git -C "$WORK/i3-seed" -c user.name=t -c user.email=t@t commit -q -m seed && git -C "$WORK/i3-seed" push -q origin HEAD:main 2>/dev/null
  W5="$WORK/deja-pris"; mkdir -p "$W5"
  run "questionnaire, repository name already taken" wizard_expect "$W5"
  has "existing repository detected" "already exists"
  [[ "$(git -C "$W5" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/deja-pris-loomy.git" ]] && ok "taken name: another name suggested and created" || ko "taken name: remote $(git -C "$W5" config --get remote.origin.url 2>&1)"
  [[ "$(git --git-dir="$GH_STUB_REMOTES/testeur/deja-pris.git" rev-list --count main)" == "1" ]] && ok "existing repository left untouched" || ko "existing repository changed"
  cat >"$WORK/lier.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {already exists \\(} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W6="$WORK/deja-relie"; mkdir -p "$W6"; mv "$GH_STUB_REMOTES/testeur/deja-pris.git" "$GH_STUB_REMOTES/testeur/deja-relie.git"
  run "questionnaire, existing repository linked" env WIZ_DIR="$W6" expect "$WORK/lier.exp"
  [[ "$(git -C "$W6" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/deja-relie.git" ]] && ok "existing repository linked as origin" || ko "link: remote $(git -C "$W6" config --get remote.origin.url 2>&1)"
  file_has "brief: existing repository" "$W6/.loomy/brief.md" "^github_repo: existing$"
  [[ -f "$W6/SPECS.md" ]] && ok "existing repository content brought into the folder" || ko "existing content missing"
  [[ "$(git -C "$W6" symbolic-ref --short HEAD)" == "loomy/setup" ]] && ok "setup on the loomy/setup branch" || ko "branch: $(git -C "$W6" symbolic-ref --short HEAD)"
  file_has "agent told to read the existing content" "$W6/.loomy/brief.md" "already had content"
  file_has "agent told to reconcile through the branch" "$W6/.loomy/brief.md" "loomy/setup"
  [[ "$(git --git-dir="$GH_STUB_REMOTES/testeur/deja-relie.git" rev-list --count main)" == "1" ]] && ok "linked repository left untouched" || ko "linked repository changed"
  # Tab: the suggestion becomes editable text (here the repository name, completed rather than retyped).
  cat >"$WORK/tab.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {GitHub repository name \\(} { expect "edit the suggestion" ; send "\t" ; after 200 ; send -- "-edit\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W7="$WORK/tabulation"; mkdir -p "$W7"
  run "questionnaire, Tab edits the suggestion" env WIZ_DIR="$W7" expect "$WORK/tab.exp"
  [[ "$(git -C "$W7" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/tabulation-edit.git" ]] && ok "Tab: suggested name completed, not retyped" || ko "Tab: remote $(git -C "$W7" config --get remote.origin.url 2>&1)"
  # ← goes back to the previous question, which keeps the answer already given.
  cat >"$WORK/retour.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
expect "question 1/" ; expect "⏎ confirm" ; send "Projet Retour\r"
expect "question 2/" ; expect "⏎ confirm" ; send "\033\[D"
expect "question 1/" ; expect "Projet Retour" ; exit 0
EXP
  W3="$WORK/interactif3"; mkdir -p "$W3"
  run "← goes back to the previous question with its answer" env WIZ_DIR="$W3" expect "$WORK/retour.exp"
  # Two repositories: public project + AI files in a private repository, names confirmed together.
  cat >"$WORK/deux-depots.exp" <<EXP
set timeout 20
spawn bash "$REPO/scripts/init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 80} {incr i} {
  expect {
    -re {Create a GitHub repository for this project} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {Where to keep the AI files} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\033\[B" ; after 200 ; send "\r" }
    -re {Create these two repositories} { expect "⏎ confirm" ; send "\r" }
    -re {Open the lead agent session} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W4="$WORK/deux-depots"; mkdir -p "$W4"
  run "questionnaire: two repositories confirmed" env WIZ_DIR="$W4" expect "$WORK/deux-depots.exp"
  has "confirmation of both names asked" "Create these two repositories"
  hasnt "questionnaire: no raw code on screen" '\$\(t |\$save_desc|\$[A-Z_]+\b'
  [[ -d "$GH_STUB_REMOTES/testeur/deux-depots.git" && -d "$GH_STUB_REMOTES/testeur/deux-depots-ai.git" ]] && ok "two repositories created: deux-depots (public) and deux-depots-ai (private)" || ko "repositories missing ($(ls "$GH_STUB_REMOTES/testeur" | tr '\n' ' '))"
  file_has "brief: public repository" "$W4/.loomy/brief.md" "^github_repo: public$"
  file_has "brief: AI files in the private repository" "$W4/.loomy/brief.md" "^ai_files: private$"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
else
  printf '  \033[2m○ expect missing: interactive questionnaire not tested\033[0m\n'
fi

# ------------------------------------------------------------------ status and log
section "loomy status (log in every state)"
cd "$PROJ" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || git init -q .
git add -A && git commit -qm init
J="$PROJ/.loomy/logs/events.jsonl"
run "status: log with phases only" "$LOOMY" status
has "status: Git section reached" "branch main"
has "status: no finished delegation" "no finished delegation"
run "status: empty log" sh -c ": > '$J' && '$LOOMY' status"
run "status: no log" sh -c "rm -f '$J' && '$LOOMY' status"
run "status: corrupted line tolerated" sh -c "printf '{pas du json\n' > '$J' && '$LOOMY' status"
rm -f "$J"

# Real delegations through the bridges and the doubles.
section "Bridges (claude and codex doubles)"
run "delegate claude explorer" "$LOOMY" delegate claude explorer "Where is VAT validated?"
has "claude result passed on" "answer from the claude double"
run "delegate codex reviewer" "$LOOMY" delegate codex reviewer "Relis le dernier commit"
has "codex result passed on" "answer from the codex double"
run "delegate codex executor (writes)" env STUB_WRITE=1 "$LOOMY" delegate codex executor "Add a file"
has "modified files flagged" "changed|fichier_doublure"
fails "unsupported claude role" 2 "$LOOMY" delegate claude executor "x"
fails "tâche manquante" 2 "$LOOMY" delegate codex reviewer
run "CLI failure logged" sh -c "STUB_FAIL=1 '$LOOMY' delegate codex reviewer 'x' || true"
starts="$(grep -c '"type":"delegation_start"' "$J")"; ends="$(grep -c '"type":"delegation",' "$J")"
if [[ "$starts" == "4" && "$ends" == "4" ]]; then ok "log: 4 starts, 4 ends"; else ko "log: $starts starts, $ends ends (4 expected)"; fi
if awk -F'"id":"' '/"type":"delegation_start"/ { split($2, a, "\""); s[a[1]]++ } /"type":"delegation",/ { split($2, a, "\""); e[a[1]]++ } END { for (i in s) if (!(i in e)) exit 1; for (i in e) if (!(i in s)) exit 1 }' "$J"
then ok "log: each start has its end (same id)"; else ko "log: mismatched ids"; fi
file_has "log: cost reported by claude" "$J" '"bridge":"claude".*"cost_usd":0.0123'
file_has "log: estimated cost for codex" "$J" '"bridge":"codex".*"cost_source":"estimate"'
file_has "log: failure recorded" "$J" '"status":"error"'
if while IFS= read -r l; do printf '%s' "$l" | grep -qE '^\{"ts":"[0-9T:-]+Z",.*\}$' || exit 1; done <"$J"; then ok "log: one JSON line per event"; else ko "log: malformed line"; fi
run "LOOMY_JOURNAL_TASKS=0 hides the task" env LOOMY_JOURNAL_TASKS=0 "$LOOMY" delegate claude explorer "SECRET-TACHE"
if grep -q "SECRET-TACHE" "$J"; then ko "task text logged despite LOOMY_JOURNAL_TASKS=0"; else ok "task text absent from the log"; fi
run "delegate codex with a French locale" env LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 "$LOOMY" delegate codex explorer "locale"
if tail -1 "$J" | grep -qE '"cost_usd":[0-9]+\.[0-9]+,'; then ok "log: cost written with a decimal point"; else ko "log: malformed cost ($(tail -1 "$J" | grep -oE '"cost_usd":[^"]*'))"; fi
n_before="$(wc -l <"$J")"
run "LOOMY_JOURNAL=0 turns the log off" env LOOMY_JOURNAL=0 "$LOOMY" delegate claude explorer "x"
[[ "$(wc -l <"$J")" == "$n_before" ]] && ok "nothing written with LOOMY_JOURNAL=0" || ko "log written despite LOOMY_JOURNAL=0"

section "Live tracking"
run "status with delegations from both families" "$LOOMY" status
has "status: delegation total" "Delegations +[0-9]+"
has "status: failures flagged" "failed"
has "status: latest delegations" "Latest delegations"
# Running delegation: the double sleeps, the status must show it, then forget it once finished.
STUB_SLEEP=3 "$LOOMY" delegate claude architect "Tâche longue" >/dev/null 2>&1 &
bg=$!
sleep 1
run "status during a delegation" "$LOOMY" status
has "running delegation shown" "running .*architect"
wait "$bg"
run "status after the delegation" "$LOOMY" status
hasnt "nothing running anymore" "running .*architect"
# Interrupted delegation (dead process, no end event): ignored.
printf '{"ts":"2026-01-01T00:00:00Z","type":"delegation_start","id":"dmort","pid":999999,"bridge":"codex","role":"developer","model":"x","task":"interrompue"}\n' >>"$J"
run "status with an interrupted delegation" "$LOOMY" status
hasnt "interrupted delegation ignored" "interrompue"
run "status with a French locale" env LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 "$LOOMY" status
has "costs read with the decimal point" 'Delegations +[0-9]+ · \$0\.[0-9]*[1-9]'
hasnt "no awk or printf error" "division by zero|invalid number|nombre non valable"
run "status --watch starts and stops" sh -c "'$LOOMY' watch 1 >/dev/null 2>&1 & p=\$!; sleep 2; kill \$p; wait \$p; true"
run "loomy log -n 3" "$LOOMY" log -n 3
if [[ "$(wc -l <"$OUT" | tr -d ' ')" == "3" ]]; then ok "log: 3 lines"; else ko "log: $(wc -l <"$OUT") lines"; fi

section "Phases"
run "status set build" "$LOOMY" status set build
file_has "state: build phase" "$PROJ/.loomy/state" "^phase=build$"
if [[ "$(grep -c '^log=' "$PROJ/.loomy/state")" -ge 2 ]]; then ok "state: history kept"; else ko "state: history lost"; fi
fails "unknown phase refused" 2 "$LOOMY" status set nimporte
file_has "log: phase event" "$J" '"type":"phase","phase":"build"'

# ------------------------------------------------------------------ diagnostic
section "loomy doctor"
run "doctor with claude and codex" "$LOOMY" doctor
has "doctor: claude detected" "claude 2\.[0-9]"
has "doctor: codex detected" "codex 0\.[0-9]"
hasnt "doctor: no install command when everything is detected" "install.sh"
run "doctor --live (sondes)" "$LOOMY" doctor --live
fails "doctor without any AI CLI: minimum not met" 1 env LOOMY_CODEX_BIN=/inexistant PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO/scripts/ai-doctor.sh" --root "$PROJ"
has "doctor: explicit summary" "Minimum not met"
has "doctor: Claude Code install command" "curl -fsSL https://claude.ai/install.sh"
has "doctor: Codex install command" "curl -fsSL https://chatgpt.com/codex/install.sh"
run "doctor with a broken claude CLI" env STUB_BROKEN_VERSION=1 "$LOOMY" doctor

# ------------------------------------------------------------------ worktrees
section "Parallel worktrees"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "travail" || true
run "worktrees" "$LOOMY" worktrees demo
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "two worktrees created"; else ko "worktrees: $(git -C "$PROJ" worktree list | wc -l) entries"; fi
run "worktrees --help created nothing" "$LOOMY" worktrees --help
fails "task name starting with a hyphen refused" 2 "$LOOMY" worktrees -x
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "still only two worktrees"; else ko "worktrees created by mistake"; fi

# ------------------------------------------------------------------ existing project
section "Adopting an existing project (0.5)"
EX="$WORK/existing-app"; mkdir -p "$EX/src/auth" "$EX/tests" "$EX/.github/workflows"
cat >"$EX/package.json" <<'JSON'
{
  "name": "existing-app",
  "scripts": {
    "test": "vitest run",
    "lint": "eslint .",
    "build": "vite build"
  },
  "dependencies": {
    "react": "^19.0.0"
  },
  "devDependencies": {
    "vitest": "^3.0.0",
    "typescript": "^5.6.0"
  }
}
JSON
printf 'export function login() {\n  // TODO: rate limiting\n}\n' >"$EX/src/auth/login.ts"
printf 'export const app = 1;\n' >"$EX/src/app.tsx"
printf 'test("app", () => {});\n' >"$EX/tests/app.test.ts"
printf 'name: ci\non: push\njobs: {}\n' >"$EX/.github/workflows/ci.yml"
printf '# Existing app\n' >"$EX/README.md"
printf 'API_KEY=not-a-real-key\n' >"$EX/.env"
git -C "$EX" init -q -b main
git -C "$EX" add -A && GIT_AUTHOR_NAME=Alice GIT_AUTHOR_EMAIL=alice@example.com git -C "$EX" commit -qm "feat: first version"
printf 'export const more = 2;\n' >>"$EX/src/app.tsx"
git -C "$EX" add -A && GIT_AUTHOR_NAME=Bob GIT_AUTHOR_EMAIL=bob@example.com git -C "$EX" commit -qm "fix: more"
MAIN_BEFORE="$(git -C "$EX" rev-parse main)"
printf 'local work in progress\n' >>"$EX/README.md"
run "init on an existing project" "$LOOMY" init "$EX" --yes --no-clipboard
[[ "$(git -C "$EX" symbolic-ref --short HEAD)" == "loomy/adopt" ]] && ok "adoption: dedicated branch loomy/adopt" || ko "adoption: branch $(git -C "$EX" symbolic-ref --short HEAD)"
[[ "$(git -C "$EX" rev-parse main)" == "$MAIN_BEFORE" ]] && ok "adoption: main untouched" || ko "adoption: main moved"
git -C "$EX" diff --quiet -- README.md && ko "adoption: uncommitted work lost" || ok "adoption: uncommitted work kept"
file_has "brief: existing project" "$EX/.loomy/brief.md" "^repo: existing$"
file_has "brief: adoption branch" "$EX/.loomy/brief.md" "^adopt_branch: loomy/adopt$"
file_has "brief: base branch" "$EX/.loomy/brief.md" "^base_branch: main$"
file_has "brief: stay on the adoption branch" "$EX/.loomy/brief.md" "Work only on the \`loomy/adopt\` branch"
file_has "START.md: adoption section" "$EX/START.md" "Existing project \(adoption\)"
A="$EX/.loomy/assessment.md"
file_has "assessment: languages" "$A" "Languages: TypeScript"
file_has "assessment: frameworks" "$A" "Detected: .*react.*vitest"
file_has "assessment: test command" "$A" '`npm run test`'
file_has "assessment: lint and build commands" "$A" '`npm run build`'
file_has "assessment: CI" "$A" '\.github/workflows'
file_has "assessment: authors" "$A" "Authors: 2"
file_has "assessment: sensitive area" "$A" "src/auth/login.ts"
file_has "assessment: committed secret flagged" "$A" '`\.env`'
file_has "assessment: TODO markers" "$A" "TODO / FIXME / HACK markers: 1"
file_has "assessment: uncommitted work flagged" "$A" "uncommitted change"
file_has "assessment: high risk with a secret" "$A" "estimated risk: HIGH"
hasnt "assessment: Loomy's own files ignored" "START\.md \("
run "loomy assess --print" "$LOOMY" assess --root "$EX" --print
has "assess: report printed" "Assessment of the existing project"
run "loomy assess in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr "$LOOMY" assess --root "$EX" --print
has "assess: French headings" "État des lieux du projet existant"
EX2="$WORK/existing-nobranch"; mkdir -p "$EX2" && printf 'print(1)\n' >"$EX2/main.py" && git -C "$EX2" init -q -b main && git -C "$EX2" add -A && git -C "$EX2" commit -qm init
run "init --no-branch" "$LOOMY" init "$EX2" --yes --no-clipboard --no-branch
[[ "$(git -C "$EX2" symbolic-ref --short HEAD)" == "main" ]] && ok "--no-branch: stays on main" || ko "--no-branch: switched"
EX3="$WORK/existing-nogit"; mkdir -p "$EX3" && printf 'fn main() {}\n' >"$EX3/main.rs" && printf '[package]\nname = "x"\n[dependencies]\nserde = "1"\n' >"$EX3/Cargo.toml"
run "init on an existing project without Git" "$LOOMY" init "$EX3" --yes --no-clipboard
file_has "assessment without Git: Rust" "$EX3/.loomy/assessment.md" "Languages: Rust"
file_has "assessment without Git: cargo test" "$EX3/.loomy/assessment.md" '`cargo test`'
file_has "assessment without Git: no history" "$EX3/.loomy/assessment.md" "No Git history"
[[ ! -f "$PROJ/.loomy/assessment.md" ]] && ok "new project: no assessment" || ko "new project assessed"

section "Subscriptions, quotas and stats"
QD="$WORK/quota"; QC="$WORK/quota-cfg"; QX="$WORK/quota-codex"
mkdir -p "$QD/.loomy/logs" "$QC/loomy" "$QX/sessions/2026/09/28"
printf -- '---\nname: "Quota"\nai_mode: ORCHESTRATED\nai_lead: claude\nbudget: equilibre\n---\n' >"$QD/.loomy/brief.md"; printf 'phase=build\n' >"$QD/.loomy/state"
DQ="$(date -u +%Y-%m-%d)"; NQ="$(date +%s)"
cat >"$QD/.loomy/logs/events.jsonl" <<EOF
{"ts":"${DQ}T08:05:00Z","type":"delegation","id":"q1","bridge":"codex","role":"executor","family":"codex","model":"gpt-6-luna","status":"ok","duration_s":95,"tokens_in":120000,"tokens_cached":80000,"tokens_out":9000,"cost_usd":0.0215,"task":"Add tests"}
{"ts":"${DQ}T08:20:00Z","type":"delegation","id":"q2","bridge":"claude","role":"architect","family":"claude","model":"claude-opus-5-5","status":"ok","duration_s":140,"tokens_in":45000,"tokens_cached":30000,"tokens_out":6000,"cost_usd":0.31,"task":"Review design"}
{"ts":"${DQ}T08:40:00Z","type":"delegation","id":"q3","bridge":"codex","role":"reviewer","family":"codex","model":"gpt-6-sol","status":"error","duration_s":30,"tokens_in":10000,"tokens_cached":0,"tokens_out":500,"cost_usd":0.025,"task":"Review diff"}
{"ts":"${DQ}T09:00:00Z","type":"usage","tool":"claude","family":"claude","scope":"lead","agent":"","model":"claude-opus-5-5","messages":12,"tokens_in":300000,"tokens_cached":900000,"tokens_out":40000,"cost_usd":2.18}
EOF
printf '{"type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":%s},"secondary":{"used_percent":99.0,"window_minutes":300,"resets_at":%s},"plan_type":"team","rate_limit_reached_type":null}}}\n' $(( NQ + 200000 )) $(( NQ - 60 )) >"$QX/sessions/2026/09/28/r.jsonl"
qenv() { env XDG_CONFIG_HOME="$QC" CODEX_HOME="$QX" "$@"; }
got="$(qenv bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/usage.sh"; ai_quota codex' _ "$REPO")"
[[ "$got" == "10080 12 $(( NQ + 200000 ))" ]] && ok "codex quota read from its session log (expired window ignored)" || ko "codex quota: $got"
# Claude: the status line saves the documented rate_limits field.
run "init for the status line" "$LOOMY" init "$WORK/sl-proj" --yes --no-clipboard
SLC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$WORK/sl-proj/.claude/settings.json" 2>/dev/null)"
[[ "$SLC" == *ai-statusline.sh* ]] && ok "status line installed in .claude/settings.json" || ko "status line missing"
mkdir -p "$WORK/sl-proj/sub"
SLIN="{\"model\":{\"display_name\":\"Opus 5.5\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":42.4,\"resets_at\":$(( NQ + 3600 ))},\"seven_day\":{\"used_percentage\":86,\"resets_at\":$(( NQ + 300000 ))}}}"
(cd "$WORK/sl-proj/sub" && printf '%s' "$SLIN" | qenv sh -c "$SLC") >"$OUT" 2>&1
has "status line: Loomy line with the quota" "Loomy · Opus 5.5 · 5h 42% · 7d 86%"
file_has "status line: quota saved" "$QC/loomy/claude-limits" "^seven_day_pct=86$"
echo 'echo MY-OWN-LINE' >"$QC/loomy/statusline-user"
(cd "$WORK/sl-proj" && printf '%s' "$SLIN" | qenv sh -c "$SLC") >"$OUT" 2>&1
has "status line: the user's own status line is shown" "^MY-OWN-LINE$"
rm -f "$QC/loomy/statusline-user"
SLE="$WORK/sl-existing"; mkdir -p "$SLE/.claude"; printf '{"statusLine":{"type":"command","command":"echo mine"}}\n' >"$SLE/.claude/settings.json"
run "init keeps an existing status line" "$LOOMY" init "$SLE" --yes --no-clipboard
file_has "existing status line kept" "$SLE/.claude/settings.json" '"command": "echo mine"'
# Subscription: quota and tokens instead of dollars.
printf 'plan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
run "status with subscriptions" qenv "$LOOMY" status --root "$QD"
has "status: Claude quota" "Claude Pro · 5 h 42 %.*week 86 %"
has "status: Codex quota" "ChatGPT Business · week 12 %"
has "status: delegations in tokens" "Delegations +3 · 190.5k tokens"
hasnt "status: no dollar amount with subscriptions" '\$[0-9]'
run "log with subscriptions" qenv "$LOOMY" log --root "$QD"
has "log: tokens instead of cost" "129.0k tk"
run "stats" qenv "$LOOMY" stats --root "$QD"
has "stats: overview" "3 · 66 % succeeded · 1 failed"
has "stats: by role" "architect +1 +2 min 20 s"
has "stats: by model with cache share" "claude-opus-5-5 +1\+12r .* 72 %"
has "stats: API value covered by the plan" "API value ≈\\\$2.54, covered by your plan"
has "stats: month value next to the plan price" "this month: API value ≈\\\$2.49 for a \\\$20/month plan"
fails "stats: invalid --since refused" 2 "$LOOMY" stats --root "$QD" --since yesterday
run "stats --days" qenv "$LOOMY" stats --root "$QD" --days 7
# API: the real cost stays.
printf 'plan_claude=api\nplan_codex=api\n' >"$QC/loomy/config"
run "status with the API" qenv "$LOOMY" status --root "$QD"
has "status API: delegation cost" 'Delegations +3 · \$0.3565'
has "status API: monthly cost" "API · cost this month: \\\$2"
hasnt "status API: no quota" "week [0-9]+ %"
printf '{"type":"event_msg","payload":{"rate_limits":{"primary":null,"secondary":null,"rate_limit_reached_type":"workspace_member_credits_depleted"}}}\n' >>"$QX/sessions/2026/09/28/r.jsonl"; touch "$QX/sessions/2026/09/28/r.jsonl"
got="$(qenv bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/usage.sh"; ai_quota codex' _ "$REPO")"
[[ "$got" == "reached workspace_member_credits_depleted" ]] && ok "codex quota: limit reached reported" || ko "codex reached: $got"
# Failover: close to the end of a subscription quota, the role goes to the other tool.
printf 'plan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
FL="$WORK/failover.log"; : >"$FL"
(cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate codex executor "Add a test") >"$OUT" 2>&1
has "failover: announced" "Codex quota at limit reached .*executor handed to Claude"
has "failover: plain answer, as from Codex" "^answer from the claude double$"
grep -q $'^claude\t-p' "$FL" && ! grep -q '^codex' "$FL" && ok "failover: Codex role run by Claude" || ko "failover: calls $(cut -c1-60 "$FL" | tr '\n' ' ')"
grep -q 'acceptEdits' "$FL" && grep -q '"sandbox":{"enabled":true' "$FL" && ok "failover: writing role with accepted edits inside Claude's sandbox" || ko "failover: write mode missing"
grep -q -- '--model	claude-sonnet' "$FL" && ok "failover: model routed for that role on the Claude side" || ko "failover: model $(grep -o -- '--model	[^	]*' "$FL")"
file_has "failover: logged" "$QD/.loomy/logs/events.jsonl" '"role":"executor","family":"claude".*"sandbox":"workspace-write".*"failover_from":"codex"'
run "status after a failover" qenv "$LOOMY" status --root "$QD"
has "status: Codex roles go to Claude" "Codex's roles go to Claude until it resets"
has "status: switched delegation marked" "⇄ Add a test"
run "stats after a failover" qenv "$LOOMY" stats --root "$QD"
has "stats: switched delegations counted" "1 delegation\(s\) moved to the other tool"
: >"$FL"; printf 'quota_switch=off\nplan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
(cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate codex executor "x") >"$OUT" 2>&1
grep -q '^codex' "$FL" && ok "quota_switch off: no failover" || ko "quota_switch off ignored"
# Claude nearly exhausted: a read-only role goes to Codex, unless Codex has no room left either.
printf 'plan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' $(( NQ + 3600 )) >"$QC/loomy/claude-limits"
: >"$FL"; (cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate claude reviewer "Review") >"$OUT" 2>&1
grep -q '^claude' "$FL" && ok "both quotas exhausted: no ping-pong, Claude keeps the role" || ko "failover with both exhausted"
printf '{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":20.0,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' $(( NQ + 200000 )) >>"$QX/sessions/2026/09/28/r.jsonl"
: >"$FL"; (cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate claude reviewer "Review") >"$OUT" 2>&1
has "failover to Codex: announced" "Claude quota at 97 % .*reviewer handed to Codex"
grep -q '^codex' "$FL" && ! grep -q '^claude' "$FL" && grep -q 'read-only' "$FL" && ok "failover to Codex: read-only role stays read-only" || ko "failover to codex: $(cut -c1-80 "$FL")"
run "start with the lead tool nearly exhausted" qenv "$LOOMY" start --root "$QD" --print
has "start: lead agent session on the other tool" "Claude Code quota at 97 %: this session runs on Codex"
has "start: Codex command for the lead agent" "codex -m gpt-6-astra"
rm -f "$QC/loomy/claude-limits"

section "Codex CLI discovery"
CA="$WORK/apps/ChatGPT.app/Contents/Resources/codex-cli"; mkdir -p "$CA/bin" "$WORK/stalebin"
printf '{ "layoutVersion": 1, "entrypoint": "bin/codex" }\n' >"$CA/codex-package.json"
printf '#!/bin/sh\necho "codex-cli 0.158.0"\n' >"$CA/bin/codex"; chmod +x "$CA/bin/codex"
printf '#!/bin/sh\nexec "%s/gone/codex" "$@"\n' "$WORK" >"$WORK/stalebin/codex"; chmod +x "$WORK/stalebin/codex"
got="$(env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/apps/ChatGPT.app" PATH="$WORK/stalebin:/usr/bin:/bin" bash -c 'source "$1/scripts/lib/models.sh"; ai_codex_bin' _ "$REPO")"
[[ "$got" == "$CA/bin/codex" ]] && ok "codex: stale wrapper skipped, current app layout found" || ko "codex discovery: $got"
got="$(env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/apps/ChatGPT.app" PATH="$WORK/stalebin:/usr/bin:/bin" bash -c 'source "$1/scripts/lib/models.sh"; ai_codex_version' _ "$REPO")"
[[ "$got" == "0.158.0" ]] && ok "codex: version read from the bundled CLI" || ko "codex version: $got"
mkdir -p "$HOME/.local/bin" && cp "$WORK/stalebin/codex" "$HOME/.local/bin/codex"
env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/apps/ChatGPT.app" PATH="$HOME/.local/bin:$HERE/stubs:/usr/bin:/bin" bash "$REPO/scripts/ai-doctor.sh" --root "$PROJ" >"$OUT" 2>&1 || true
rm -f "$HOME/.local/bin/codex"
has "doctor: broken codex command flagged" "points to a Codex CLI that no longer exists"
has "doctor: readable fix" "fix: loomy doctor --fix"

section "Structured delegations"
SD="$WORK/structured"; mkdir -p "$SD"
run "init with the default delegation format" "$LOOMY" init "$SD" --yes --no-clipboard
file_has "brief: structured delegations by default" "$SD/.loomy/brief.md" "^delegation_format: structured$"
file_has "brief: instruction for the agent" "$SD/.loomy/brief.md" "Delegations in structured form"
SL="$WORK/structured.log"; : >"$SL"
(cd "$SD" && STUB_LOG="$SL" "$LOOMY" delegate codex reviewer "Review the diff") >"$OUT" 2>&1
grep -q 'STATUS: done | partial | blocked' "$SL" && ok "structured: contract added to the Codex prompt" || ko "structured: no contract in the prompt"
has "structured: fields returned" "^STATUS: partial$"
(cd "$SD" && STUB_LOG="$SL" "$LOOMY" delegate claude explorer "Map the code") >"$OUT" 2>&1
J2="$SD/.loomy/logs/events.jsonl"
file_has "structured: Codex outcome logged" "$J2" '"bridge":"codex".*"format":"structured","outcome":"partial"'
file_has "structured: Claude outcome logged" "$J2" '"bridge":"claude".*"format":"structured","outcome":"blocked"'
run "status with structured outcomes" "$LOOMY" status --root "$SD"
has "status: partial result marked" "◐ .*reviewer"
has "status: blocked result marked" "■ .*explorer"
run "log with structured outcomes" "$LOOMY" log --root "$SD"
has "log: partial result marked" "◐ reviewer"
run "stats with structured outcomes" "$LOOMY" stats --root "$SD"
has "stats: format compliance" "2 of 2 answers followed the format · 1 partial · 1 blocked"
run "context in structured mode" bash "$REPO/scripts/ai-context.sh" --root "$SD"
has "context: structured delegations explained" "Structured delegations: write each task as GOAL"
run "generated Claude subagents carry the contract" "$LOOMY" route --root "$SD" claude-agents "$WORK/sd-agents"
file_has "subagent: answer contract" "$WORK/sd-agents/explorer.md" "^STATUS: done \| partial \| blocked$"
: >"$SL"; (cd "$SD" && LOOMY_DELEGATION_FORMAT=free STUB_LOG="$SL" "$LOOMY" delegate codex reviewer "x") >"$OUT" 2>&1
grep -q 'STATUS: done' "$SL" && ko "free format: contract still added" || ok "free format: no contract"
run "config: delegation_format" "$LOOMY" config set delegation_format free
[[ "$(bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; ai_delegation_format "$2"' _ "$REPO" "$SD")" == free ]] && ok "config overrides the project's choice" || ko "config override ignored"
fails "config: invalid delegation_format refused" 2 "$LOOMY" config set delegation_format yaml
run "config: back to the project's choice" "$LOOMY" config set delegation_format auto
[[ "$(bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; ai_delegation_format "$2"' _ "$REPO" "$QD")" == free ]] && ok "older project without the option: free text" || ko "older project: format changed"

section "Screens without leftovers"
run "doctor for the installs listing" "$LOOMY" doctor
has "doctor: installs listed under LOOMY" "not in the PATH|used by the loomy command|other install"
run "route in English" "$LOOMY" route --root "$PROJ"
hasnt "route: no French left" "sous-agent|session principale|orchestrat"
run "route markdown" "$LOOMY" route --root "$PROJ" markdown
if awk 'prev == "" && $0 == "" { bad = 1 } { prev = $0 } END { exit !bad }' "$OUT"; then ko "route markdown: double blank line"; else ok "route markdown: no double blank line"; fi
run "every command help in English" bash -c 'for c in init brief assess start effort route privacy worktrees status log feedback doctor; do "$1" "$c" --help; done' _ "$LOOMY"
hasnt "help: no French left" "[éèàù]| : "

section "Hardening"
[[ "$(bash -c 'source "$1/scripts/lib/models.sh"; loomy_slug ".."; loomy_slug "../../etc"; loomy_slug "-rf"' _ "$REPO" | tr '\n' ' ')" == "my-project etc rf " ]] && ok "slug: no dots, slashes or leading hyphen" || ko "slug: $(bash -c 'source "$1/scripts/lib/models.sh"; loomy_slug ".."; loomy_slug "../../etc"' _ "$REPO" | tr '\n' ' ')"
HB="$WORK/hostile"; mkdir -p "$HB/.loomy"; touch "$HB/START.md"
printf -- '---\nname: "evil $(touch %s/pwned) `touch %s/pwned` \033[31mRED"\nai_mode: SOLO\nai_lead: claude\nai_repo_name: ../../etc\n---\n' "$WORK" "$WORK" >"$HB/.loomy/brief.md"
run "status on a hostile brief" "$LOOMY" status --root "$HB"
[[ ! -e "$WORK/pwned" ]] && ok "hostile brief: nothing executed" || ko "hostile brief: command executed"
if grep -q $'\033\\[31m' "$OUT"; then ko "hostile brief: escape sequence reached the terminal"; else ok "hostile brief: escape sequences removed"; fi
run "context on a hostile brief" bash "$REPO/scripts/ai-context.sh" --root "$HB"
[[ ! -e "$WORK/pwned" ]] && ok "hostile brief: context executes nothing" || ko "hostile brief: context executed a command"
mkdir -p "$WORK/clone/bin" && cp "$REPO/bin/loomy" "$WORK/clone/bin/" && cp "$REPO/VERSION" "$WORK/clone/" && ln -s "$REPO/scripts" "$WORK/clone/scripts"
PATH="$WORK/clone/bin:$PATH" "$WORK/clone/bin/loomy" uninstall >"$OUT" 2>&1
hasnt "uninstall: never suggests deleting the clone's own file" "rm .*/clone/bin/loomy"
has "uninstall: clone in the PATH" "from your PATH"
SP="$WORK/spaced repo"; mkdir -p "$SP/src dir" && printf '// TODO\n' >"$SP/src dir/a file.js" && git -C "$SP" init -q -b main && git -C "$SP" add -A && git -C "$SP" commit -qm x
run "assess with spaces in names" "$LOOMY" assess --root "$SP" --print
has "assess: file names with spaces kept whole" '`src dir/a file.js`'
if [[ -n "$TMUX_BIN" ]]; then
  tstart -s k -x 100 -y 30 -c "$PROJ" "bash"
  sleep 1; tmux -L loomy-test send-keys -t k "bash '$LOOMY'" Enter
  k=0; until tmux -L loomy-test capture-pane -t k -p | grep -q "What do you want to do"; do sleep 0.25; k=$(( k + 1 )); (( k > 80 )) && break; done
  tmux -L loomy-test send-keys -t k C-c; sleep 1
  tmux -L loomy-test send-keys -t k "stty -a | grep -oE ' -?icanon | -?echo ' | tr -d ' \n'; echo :STTY" Enter; sleep 1
  tmux -L loomy-test capture-pane -t k -p | grep -q '^icanonecho:STTY\|^echoicanon:STTY' && ok "Ctrl-C: terminal restored (echo, canonical mode)" || ko "Ctrl-C: terminal left in raw mode ($(tmux -L loomy-test capture-pane -t k -p | grep STTY | tail -1))"
  tmux -L loomy-test kill-server 2>/dev/null || true
fi

# ------------------------------------------------------------------ interface language
section "Interface language"
lang_of() {   # lang_of <environment variables…>: detected language, without LOOMY_LANG or configuration
  env -u LOOMY_LANG -u LOOMY_UI_LANG -u LC_ALL -u LC_MESSAGES -u LANG XDG_CONFIG_HOME="$WORK/cfg-lang" "$@" \
    bash -c 'source "$1/scripts/lib/i18n.sh"; echo "$LOOMY_UI_LANG"' _ "$REPO"
}
[[ "$(lang_of LANG=fr_FR.UTF-8)" == fr ]] && ok "LANG=fr_FR → French" || ko "LANG=fr_FR not detected"
[[ "$(lang_of LANG=en_US.UTF-8)" == en ]] && ok "LANG=en_US → English" || ko "LANG=en_US not detected"
[[ "$(lang_of LANG=de_DE.UTF-8)" == en ]] && ok "other language → English" || ko "de_DE should give English"
[[ "$(lang_of LC_ALL=fr_CA.UTF-8 LANG=en_US.UTF-8)" == fr ]] && ok "LC_ALL wins over LANG" || ko "LC_ALL ignored"
mkdir -p "$WORK/nouname"; printf '#!/bin/sh\necho Linux\n' >"$WORK/nouname/uname"; chmod +x "$WORK/nouname/uname"
[[ "$(lang_of LANG=C PATH="$WORK/nouname:$PATH")" == en ]] && ok "Linux without a detectable language → English" || ko "wrong Linux default"
mkdir -p "$WORK/cfg-lang/loomy"; echo "lang=fr" >"$WORK/cfg-lang/loomy/config"
[[ "$(lang_of LANG=en_US.UTF-8)" == fr ]] && ok "config lang=fr wins over the system" || ko "config lang ignored"
[[ "$(env -u LOOMY_UI_LANG LOOMY_LANG=en XDG_CONFIG_HOME="$WORK/cfg-lang" bash -c 'source "$1/scripts/lib/i18n.sh"; echo "$LOOMY_UI_LANG"' _ "$REPO")" == en ]] \
  && ok "LOOMY_LANG wins over the configuration" || ko "LOOMY_LANG ignored"
run "help in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr "$LOOMY" help
hasnt "help: no English section title left" "◇  TRACKING"
has "help: French titles" "<commande>|◇  PROJET"
run "status in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr bash "$REPO/scripts/ai-status.sh" --root "$PROJ"
has "status: French labels" "Statut du projet"
PFR="$WORK/projet-fr"; mkdir -p "$PFR"
run "init in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr "$LOOMY" init "$PFR" --yes --no-clipboard
file_has "French START.md installed" "$PFR/START.md" "BOOTSTRAP TEMPORAIRE"
file_has "French templates installed" "$PFR/.loomy/templates/AGENTS.md" "Autonomie et points d'arrêt"
file_has "French brief" "$PFR/.loomy/brief.md" "Consignes pour l'agent"
file_has "English START.md by default" "$PROJ/START.md" "TEMPORARY BOOTSTRAP"
run "compiled dictionary up to date" bash -c 'cd "$1" && tmp="$(mktemp)" && cp scripts/lib/i18n/fr.sh "$tmp" && bash tools/i18n-build.sh >/dev/null && cmp -s "$tmp" scripts/lib/i18n/fr.sh; r=$?; cp "$tmp" scripts/lib/i18n/fr.sh; rm -f "$tmp"; exit $r' _ "$REPO"
run "every interface sentence is translated" bash -c '[[ -z "$(bash "$1/tools/i18n-missing.sh")" ]]' _ "$REPO"

# ------------------------------------------------------------------ install.sh
section "install.sh"
PREFIX="$WORK/prefix"
run "install.sh into a prefix" env LOOMY_PREFIX="$PREFIX" sh "$REPO/install.sh"
run "installed loomy works" "$PREFIX/bin/loomy" version
run "install.sh --uninstall" env LOOMY_PREFIX="$PREFIX" sh "$REPO/install.sh" --uninstall
[[ ! -e "$PREFIX/bin/loomy" ]] && ok "command removed" || ko "command still present"

# ------------------------------------------------------------------ bilan
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

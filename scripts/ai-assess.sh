#!/usr/bin/env bash
# Assessment of an existing project, without AI: stack, structure, commands, tests, CI, conventions, docs,
# Git history, sensitive areas, debt and risks. Bash 3.2 compatible.
#   ai-assess.sh                 writes .loomy/assessment.md and prints a summary
#   ai-assess.sh --print         prints the assessment without writing it
#   ai-assess.sh --quiet         writes it, prints one summary line (used by the questionnaire)
#   ai-assess.sh --root <dir>    works on another project folder
# The lead agent reads it before the interview: facts to confirm by reading the code, not conclusions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

ROOT=""; MODE="write"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --print) MODE="print" ;;
    --quiet) MODE="quiet" ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/ai-assess.sh/loomy assess/' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy assess --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
[[ -d "$ROOT" ]] || { t "Error: folder not found: %s" "$ROOT" >&2; echo >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd -P)"
cd "$ROOT" || exit 1

# ---------------------------------------------------------------- file list
# Git's view when the folder is a repository (what is really versioned), otherwise a filtered walk.
IS_GIT=0; git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" == "$ROOT" ]] && IS_GIT=1
FILES="$(mktemp "${TMPDIR:-/tmp}/loomy-assess.XXXXXX")"; trap 'rm -f "$FILES"' EXIT
if (( IS_GIT )); then
  git ls-files -co --exclude-standard 2>/dev/null >"$FILES"
else
  find . -type f ! -path './.git/*' ! -path '*/node_modules/*' ! -path '*/.venv/*' ! -path '*/vendor/*' \
    ! -path '*/dist/*' ! -path '*/build/*' ! -path '*/target/*' 2>/dev/null | sed 's|^\./||' >"$FILES"
fi
# Loomy's own files don't describe the project.
grep -vE '^(\.loomy/|START\.md$|\.claude/settings\.json$|\.codex/hooks\.json$)' "$FILES" >"$FILES.f" 2>/dev/null; mv "$FILES.f" "$FILES"
N_FILES="$(wc -l <"$FILES" | tr -d ' ')"

has() { [[ -e "$ROOT/$1" ]]; }
count_re() { grep -cE "$1" "$FILES" 2>/dev/null || true; }
bullet() { printf -- '- %s\n' "$*"; }

# ---------------------------------------------------------------- languages
lang_of_ext() {
  case "$1" in
    ts|tsx) echo TypeScript ;; js|jsx|mjs|cjs) echo JavaScript ;; py) echo Python ;; rb) echo Ruby ;; go) echo Go ;;
    rs) echo Rust ;; java) echo Java ;; kt|kts) echo Kotlin ;; swift) echo Swift ;; m|mm) echo Objective-C ;;
    c|h) echo C ;; cc|cpp|cxx|hpp) echo C++ ;; cs) echo C# ;; php) echo PHP ;; dart) echo Dart ;; scala) echo Scala ;;
    ex|exs) echo Elixir ;; sh|bash|zsh) echo Shell ;; vue) echo Vue ;; svelte) echo Svelte ;; lua) echo Lua ;;
    sql) echo SQL ;; css|scss|sass|less) echo CSS ;; html|htm) echo HTML ;; *) echo "" ;;
  esac
}
LANGS="$(sed -n 's/.*\.\([A-Za-z0-9]*\)$/\1/p' "$FILES" | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn |
  while read -r n ext; do l="$(lang_of_ext "$ext")"; [[ -n "$l" ]] && echo "$n $l"; done |
  awk '{ c[$2] += $1 } END { for (k in c) print c[k], k }' | sort -rn | head -6)"
LANG_LINE="$(printf '%s\n' "$LANGS" | awk 'NF { printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1 }')"
MAIN_LANG="$(printf '%s\n' "$LANGS" | awk 'NF { print $2; exit }')"

# ---------------------------------------------------------------- stack, dependencies, commands
STACK=(); DEPS=(); CMDS=(); CONV=()
json_keys() {   # json_keys <file> <section>: keys of a top-level object in a package.json (no jq needed)
  awk -v sec="\"$2\"" '
    $0 ~ sec"[[:space:]]*:[[:space:]]*\\{" { on = 1; if ($0 ~ /\}/) on = 0; next }
    on && /^[[:space:]]*\}/ { on = 0 }
    on && match($0, /"[^"]+"[[:space:]]*:/) { k = substr($0, RSTART + 1, RLENGTH - 1); sub(/"[[:space:]]*:$/, "", k); print k }' "$1"
}
if has package.json; then
  deps="$(json_keys package.json dependencies)"; dev="$(json_keys package.json devDependencies)"
  DEPS+=("package.json: $(printf '%s\n' "$deps" | grep -c . | tr -d ' ') dependencies, $(printf '%s\n' "$dev" | grep -c . | tr -d ' ') devDependencies")
  for fw in next react vue svelte @angular/core nuxt astro express fastify @nestjs/core hono vite webpack typescript \
            jest vitest mocha playwright cypress eslint prettier @biomejs/biome tailwindcss prisma drizzle-orm electron @tauri-apps/api react-native expo; do
    printf '%s\n%s\n' "$deps" "$dev" | grep -qx "$fw" && STACK+=("$fw")
  done
  while IFS= read -r s; do
    case "$s" in test|test:*|lint|lint:*|build|typecheck|type-check|check|format|dev|start|e2e)
      CMDS+=("\`$(if has pnpm-lock.yaml; then echo pnpm; elif has yarn.lock; then echo yarn; elif has bun.lockb || has bun.lock; then echo bun; else echo npm; fi) run $s\`") ;;
    esac
  done < <(json_keys package.json scripts)
fi
for f in pyproject.toml requirements.txt setup.py Pipfile; do
  if has "$f"; then
    for fw in django flask fastapi pydantic sqlalchemy pytest ruff black mypy poetry uv; do grep -qi "\b$fw\b" "$f" 2>/dev/null && STACK+=("$fw"); done
    DEPS+=("$f")
  fi
done
has Cargo.toml && { STACK+=("Rust (Cargo)"); DEPS+=("Cargo.toml: $(awk '/^\[dependencies\]/{on=1;next} /^\[/{on=0} on && /=/' Cargo.toml | grep -c . | tr -d ' ') dependencies"); CMDS+=("\`cargo test\`" "\`cargo clippy\`"); }
has go.mod && { STACK+=("Go modules"); DEPS+=("go.mod: $(grep -cE '^\s+[a-z].* v[0-9]' go.mod | tr -d ' ') dependencies"); CMDS+=("\`go test ./...\`" "\`go vet ./...\`"); }
has Gemfile && { STACK+=("Ruby (Bundler)"); grep -q "rails" Gemfile && STACK+=("rails"); DEPS+=("Gemfile"); }
has composer.json && { STACK+=("PHP (Composer)"); grep -q "laravel" composer.json && STACK+=("laravel"); DEPS+=("composer.json"); }
{ has pom.xml && { STACK+=("Java (Maven)"); CMDS+=("\`mvn test\`"); }; } || true
{ has build.gradle || has build.gradle.kts; } && { STACK+=("JVM (Gradle)"); CMDS+=("\`./gradlew test\`"); }
has Package.swift && { STACK+=("Swift Package Manager"); CMDS+=("\`swift test\`"); }
has pubspec.yaml && { STACK+=("Dart/Flutter"); CMDS+=("\`flutter test\`"); }
has Dockerfile && STACK+=("Docker")
{ has docker-compose.yml || has compose.yaml || has docker-compose.yaml; } && STACK+=("Docker Compose")
if has Makefile; then
  targets="$(grep -oE '^[a-zA-Z][a-zA-Z0-9_-]*:' Makefile | tr -d ':' | grep -xE 'test|lint|build|check|fmt|format|typecheck|ci|dev|run' | sort -u | tr '\n' ' ')"
  for tg in $targets; do CMDS+=("\`make $tg\`"); done
fi
LOCKS=""; for f in package-lock.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock poetry.lock uv.lock Pipfile.lock Cargo.lock go.sum Gemfile.lock composer.lock; do has "$f" && LOCKS="${LOCKS:+$LOCKS, }$f"; done
for f in .editorconfig tsconfig.json .eslintrc .eslintrc.js .eslintrc.json .eslintrc.cjs eslint.config.js eslint.config.mjs .prettierrc .prettierrc.json prettier.config.js biome.json \
         ruff.toml .ruff.toml setup.cfg .flake8 mypy.ini .pre-commit-config.yaml .commitlintrc .commitlintrc.json rustfmt.toml .golangci.yml .rubocop.yml \
         AGENTS.md CLAUDE.md .cursorrules .github/copilot-instructions.md CONTRIBUTING.md; do
  has "$f" && CONV+=("\`$f\`")
done

# ---------------------------------------------------------------- tests, CI, docs
N_TESTS="$(count_re '(^|/)(tests?|__tests__|spec)/|[._-](test|spec)\.[a-z]+$|_test\.(go|py)$|^test_.*\.py$|/test_[^/]*\.py$')"
CI=""; for f in .github/workflows .gitlab-ci.yml .circleci Jenkinsfile azure-pipelines.yml .travis.yml bitbucket-pipelines.yml; do
  has "$f" && CI="${CI:+$CI, }\`$f\`"
done
[[ -d .github/workflows ]] && CI="$CI ($(find .github/workflows -name '*.y*ml' | wc -l | tr -d ' ') workflow(s))"
README=""; for f in README.md README.rst README.txt README; do has "$f" && { README="\`$f\` ($(wc -l <"$f" | tr -d ' ') lines)"; break; }; done
N_DOCS="$(count_re '^docs?/.*\.(md|mdx|rst|txt)$')"
ADRS="$(count_re '(adr|decisions?)/.*\.md$')"

# ---------------------------------------------------------------- Git history
GIT_LINES=()
if (( IS_GIT )) && git rev-parse HEAD >/dev/null 2>&1; then
  n_commits="$(git rev-list --count HEAD 2>/dev/null)"
  first="$(git log --reverse --format=%cs 2>/dev/null | head -1)"; last="$(git log -1 --format=%cs 2>/dev/null)"
  recent="$(git rev-list --count --since=90.days HEAD 2>/dev/null)"
  n_authors="$(git log --format='%aN' 2>/dev/null | sort -u | grep -c . | tr -d ' ')"
  GIT_LINES+=("$(t "Branch: %s · %s commits, from %s to %s · %s in the last 90 days" "$(git symbolic-ref --short HEAD 2>/dev/null || t "detached")" "$n_commits" "$first" "$last" "$recent")")
  GIT_LINES+=("$(t "Authors: %s (most active: %s)" "$n_authors" "$(git shortlog -sn --no-merges HEAD 2>/dev/null | head -5 | awk '{ n = $1; $1 = ""; sub(/^ /, ""); printf "%s%s (%s)", (NR > 1 ? ", " : ""), $0, n }')")")
  remotes="$(git remote -v 2>/dev/null | awk '$3 == "(fetch)" { printf "%s%s %s", (n++ ? ", " : ""), $1, $2 }')"
  [[ -n "$remotes" ]] && GIT_LINES+=("$(t "Remotes: %s" "$remotes")")
  n_branches="$(git branch -a 2>/dev/null | grep -vc 'HEAD ->' | tr -d ' ')"
  GIT_LINES+=("$(t "Branches: %s" "$n_branches")")
  conv="$(git log -200 --format=%s 2>/dev/null | grep -cE '^(feat|fix|chore|docs|refactor|test|ci|build|perf|style)(\(.+\))?!?:' | tr -d ' ')"
  tot="$(git log -200 --format=%s 2>/dev/null | grep -c . | tr -d ' ')"
  (( tot > 0 )) && GIT_LINES+=("$(t "Conventional commits: %s of the last %s messages" "$conv" "$tot")")
  HOT="$(git log --since=180.days --name-only --format= 2>/dev/null | grep -v '^$' | grep -vE '^(\.loomy/|START\.md$)' | sort | uniq -c | sort -rn | head -8 |
    awk '{ n = $1; sub(/^ *[0-9]+ /, ""); printf "%s`%s` (%s)", (NR > 1 ? ", " : ""), $0, n }')"
  [[ -n "$HOT" ]] && GIT_LINES+=("$(t "Most changed files (180 days): %s" "$HOT")")
  DIRTY="$(git status --porcelain 2>/dev/null | grep -v -E ' (\.loomy/|START\.md|\.gitignore|\.claude/|\.codex/)' | grep -c . | tr -d ' ')"
fi

# ---------------------------------------------------------------- sensitive areas, debt, risks
SENS="$(grep -iE '(auth|login|session|passw|payment|billing|stripe|checkout|secret|crypt|token|oauth|jwt|migration|admin|permission|rbac|acl)' "$FILES" |
  grep -vE '\.(png|jpe?g|gif|svg|lock)$' | head -12 | awk '{ printf "%s`%s`", (NR > 1 ? ", " : ""), $0 }')"
N_SENS="$(grep -ciE '(auth|login|session|passw|payment|billing|stripe|checkout|secret|crypt|token|oauth|jwt|migration|admin|permission|rbac|acl)' "$FILES" || true)"
SECRETS="$(grep -E '(^|/)(\.env(\..+)?|.*\.pem|id_rsa|id_ed25519|.*\.p12|.*\.key|credentials\.json|secrets?\.(ya?ml|json))$' "$FILES" | grep -vE '\.env\.(example|sample|template)$' | head -8 |
  awk '{ printf "%s`%s`", (NR > 1 ? ", " : ""), $0 }')"
if (( IS_GIT )); then
  TODO_N="$(git grep -I -c -w -E 'TODO|FIXME|HACK|XXX' -- . ':!.loomy' ':!START.md' 2>/dev/null | awk -F: '{ s += $NF } END { print s + 0 }')"
  TODO_TOP="$(git grep -I -c -w -E 'TODO|FIXME|HACK|XXX' -- . ':!.loomy' ':!START.md' 2>/dev/null | sort -t: -k2 -rn | head -5 | awk -F: '{ printf "%s`%s` (%s)", (NR > 1 ? ", " : ""), $1, $2 }')"
  # Sizes from Git's index (fast on large repositories, safe with spaces in names).
  BIG="$(git ls-tree -r -l HEAD 2>/dev/null | awk -F '\t' -v mb="$(t "MB")" '{ split($1, a, " "); if (a[4] + 0 > 1048576) printf "%s`%s` (%.1f %s)", (n++ ? ", " : ""), $2, a[4] / 1048576, mb }' | cut -c1-400)"
else
  TODO_N="$(tr '\n' '\0' <"$FILES" | xargs -0 grep -I -hc -w -E 'TODO|FIXME|HACK|XXX' 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')"; TODO_TOP=""; BIG=""
fi

SIZE="SMALL"; (( N_FILES > 200 )) && SIZE="MEDIUM"; (( N_FILES > 2000 )) && SIZE="LARGE"
RISK="LOW"; (( N_SENS > 0 )) && RISK="MEDIUM"; [[ -n "$SECRETS" ]] && RISK="HIGH"
grep -qiE '(payment|billing|stripe|checkout)' "$FILES" && RISK="HIGH"

# ---------------------------------------------------------------- report
report() {
  printf '# %s — %s\n\n' "$(t "Assessment of the existing project")" "$(basename "$ROOT")"
  t "Generated by \`loomy assess\` on %s, without AI. Facts gathered from the files and the Git history: confirm them by reading the code before relying on them." "$(date +%Y-%m-%d)"; printf '\n\n'
  printf '## %s\n\n' "$(t "Overview")"
  bullet "$(t "Files: %s · size: %s · estimated risk: %s" "$N_FILES" "$SIZE" "$RISK")"
  bullet "$(t "Languages: %s" "${LANG_LINE:-$(t "none detected")}")"
  printf '\n## %s\n\n' "$(t "Stack and dependencies")"
  if (( ${#STACK[@]} )); then bullet "$(t "Detected: %s" "$(printf '%s, ' "${STACK[@]}" | sed 's/, $//')")"; else bullet "$(t "No known framework detected")"; fi
  for d in ${DEPS[@]+"${DEPS[@]}"}; do bullet "$d"; done
  [[ -n "$LOCKS" ]] && bullet "$(t "Lock files: %s" "$LOCKS")"
  printf '\n## %s\n\n' "$(t "Structure")"
  awk -F/ 'NF > 1 { c[$1]++ } NF == 1 { top[$1] = 1 } END { for (d in c) printf "%d %s/\n", c[d], d }' "$FILES" | sort -rn | head -12 |
    while read -r n d; do bullet "$(t "\`%s\` (%s file(s))" "$d" "$n")"; done
  printf '\n## %s\n\n' "$(t "Commands found")"
  if (( ${#CMDS[@]} )); then for c in "${CMDS[@]}"; do bullet "$c"; done; else bullet "$(t "None found: ask the user, or read the README and the CI")"; fi
  printf '\n## %s\n\n' "$(t "Tests and CI")"
  bullet "$(t "Test files: %s" "$N_TESTS")"
  bullet "$(t "CI: %s" "${CI:-$(t "none")}")"
  printf '\n## %s\n\n' "$(t "Conventions and existing instructions")"
  if (( ${#CONV[@]} )); then bullet "$(printf '%s, ' "${CONV[@]}" | sed 's/, $//')"; else bullet "$(t "No configuration file found")"; fi
  printf '\n## %s\n\n' "$(t "Documentation")"
  bullet "$(t "README: %s" "${README:-$(t "none")}")"
  bullet "$(t "Documents in docs/: %s · ADRs: %s" "$N_DOCS" "$ADRS")"
  for f in CHANGELOG.md CONTRIBUTING.md LICENSE; do has "$f" && bullet "\`$f\`"; done
  printf '\n## %s\n\n' "$(t "Git history")"
  if (( ${#GIT_LINES[@]} )); then for l in "${GIT_LINES[@]}"; do bullet "$l"; done; else bullet "$(t "No Git history")"; fi
  printf '\n## %s\n\n' "$(t "Sensitive areas")"
  if [[ -n "$SENS" ]]; then bullet "$(t "Paths to review with the security role (%s): %s" "$N_SENS" "$SENS")"; else bullet "$(t "No path suggesting authentication, payments, secrets or migrations")"; fi
  printf '\n## %s\n\n' "$(t "Debt and risks")"
  [[ -n "$SECRETS" ]] && bullet "$(t "Files that look like secrets in the repository: %s — check them first, never copy their content" "$SECRETS")"
  bullet "$(t "TODO / FIXME / HACK markers: %s%s" "$TODO_N" "${TODO_TOP:+ ($TODO_TOP)}")"
  [[ -n "$BIG" ]] && bullet "$(t "Files over 1 MB: %s" "$BIG")"
  [[ "$N_TESTS" == "0" ]] && bullet "$(t "No tests found")"
  [[ -z "$CI" ]] && bullet "$(t "No CI found")"
  [[ -z "$README" ]] && bullet "$(t "No README")"
  [[ "${DIRTY:-0}" != "0" ]] && bullet "$(t "%s uncommitted change(s) were present when Loomy arrived: they belong to the user, never include them in a commit" "$DIRTY")"
  printf '\n## %s\n\n' "$(t "For the lead agent")"
  bullet "$(t "Confirm these facts by reading the code, then rebuild PROJECT.md, ARCHITECTURE.md and the ADRs from what exists.")"
  bullet "$(t "Align AGENTS.md and CLAUDE.md with the commands and conventions above; don't introduce new ones without approval.")"
  bullet "$(t "Size the team, routing and effort to a %s project with %s estimated risk." "$SIZE" "$RISK")"
}

case "$MODE" in
  print) report ;;
  *)
    mkdir -p "$ROOT/.loomy"
    report >"$ROOT/.loomy/assessment.md"
    summary="$(t "%s files · %s · tests: %s · CI: %s · risk %s" "$N_FILES" "${MAIN_LANG:-?}" "$N_TESTS" "$( [[ -n "$CI" ]] && t "yes" || t "no")" "$RISK")"
    if [[ "$MODE" == "quiet" ]]; then echo "$summary"
    else
      ui_banner "$(t "Assessment")" "$(basename "$ROOT")"
      ui_kv "$(t "Project")" "$summary"
      ui_kv "$(t "Written to")" ".loomy/assessment.md"
      ui_end "$(t "the lead agent reads it before the interview; run it again any time: loomy assess")"
    fi ;;
esac
exit 0

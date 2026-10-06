#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Shared memory of a Loomy project (.loomy/memory/), so that the thread of the work survives a new session, a
# compaction, another machine, or a switch between Claude Code and Codex:
#   delegations/<date>-<time>-<role>-<id>.md   the task and the full result of each delegation (bridges and native
#                                              Claude subagents), kept out of Git (findings can be sensitive);
#   STATE.md                                   the work state kept by the lead agent (done, in progress, decisions,
#                                              next), versioned with the AI files.
# The start of every session (and the end of a compaction) gives the lead agent STATE.md and the latest results in
# short. Bash 3.2.

LOOMY_MEMORY_KEEP="${LOOMY_MEMORY_KEEP:-200}"   # delegation results kept (the oldest are removed)

loomy_memory_dir() { printf '%s/.loomy/memory' "$1"; }

# loomy_memory_state_init <root>: STATE.md created when missing (sections only, in the project's language).
loomy_memory_state_init() {
  local d f
  d="$(loomy_memory_dir "$1")"; f="$d/STATE.md"
  [[ -e "$f" ]] && return 0
  mkdir -p "$d" 2>/dev/null || return 0
  # Written for the models, read by the user if they like: English (fewer tokens than other languages for every model)
  # and telegraphic, whatever the documentation language.
  printf '# Work state\n\n<!-- For the agents. English, telegraphic bullets, no prose; 40 lines max; replace what is outdated. Kept by the lead agent after each important step and before ending a session; given back at the start of every session, Claude Code or Codex. -->\n\n## Done\n\n## In progress\n\n## Decisions\n\n## Next\n\n## Open questions\n' >"$f"
  return 0
}

# loomy_memory_save <root> <id> <role> <model> <status> <task> <result>: one delegation result, then pruning.
# Never fails and never stops its caller (bridges and hooks run with set -e / set -u): everything runs in a subshell.
loomy_memory_save() { ( set +eu; set +o pipefail; _lm_save "$@" ) >/dev/null 2>&1 || true; return 0; }
_lm_save() {
  local r="$1" id="$2" role="$3" model="$4" status="$5" task="$6" result="$7" m d f n keep="$LOOMY_MEMORY_KEEP" old
  m="$(loomy_memory_dir "$r")"; d="$m/delegations"
  # Real folders only: a symbolic link could send the writes, and the pruning, elsewhere.
  [[ -L "$r/.loomy" || -L "$m" || -L "$d" ]] && return 0
  mkdir -p "$d" || return 0
  [[ -L "$d" ]] && return 0
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 )) || keep=200
  [[ -n "$result" ]] || result="(no result text)"
  role="$(printf '%s' "${role:-role}" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-32)"
  id="$(printf '%s' "${id:-x}" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-48)"
  # Unique name: two saves in the same second (same role, same id) never overwrite each other.
  f="$d/$(date +%Y%m%d-%H%M%S)-$role-$id-$$-${RANDOM}.md"
  {
    printf '# %s · %s · %s · %s\n\n' "$role" "${model:-?}" "${status:-?}" "$(date '+%Y-%m-%d %H:%M')"
    printf '## Task\n\n%s\n\n## Result\n\n%s\n' "$task" "$result"
  } >"$f" || return 0
  n="$(find "$d" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > keep )); then
    find "$d" -maxdepth 1 -type f -name '*.md' | sort | head -n "$(( n - keep ))" | while IFS= read -r old; do
      [[ "$(dirname "$old")" == "$d" ]] && rm -f -- "$old"
    done
  fi
  return 0
}

# _lm_field <file> <FIELD>: the text of a structured field of the result (first lines), on one line.
_lm_field() {
  awk -v k="$2" '
    BEGIN { k = tolower(k) }
    /^## Result/ { in_r = 1; next }
    !in_r { next }
    { line = $0; sub(/^[*_ -]+/, "", line); low = tolower(line) }
    !on && (index(low, k ":") == 1 || index(low, k " :") == 1 || index(low, k "**:") == 1) {
      on = 1; sub(/^[A-Za-z]+ ?[*_]*:[*_ ]*/, "", line); out = line; n = 1; next }
    on && line ~ /^[A-Za-z]+ ?[*_]*:/ { exit }
    on && n < 4 && line != "" { out = out " " line; n++ }
    END { gsub(/[[:space:]]+/, " ", out); print substr(out, 1, 260) }' "$1"
}

# loomy_memory_digest <root> [n] [new]: the latest n results in short (role, model, status, summary, next), oldest
# first. With "new", only the results the lead agent hasn't taken into STATE.md yet (newer than its last update):
# once the work state is up to date, nothing is repeated.
loomy_memory_digest() {
  local d f head s nx k=0 st
  d="$(loomy_memory_dir "$1")/delegations"; st="$(loomy_memory_dir "$1")/STATE.md"
  [[ -d "$d" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "${3:-}" == new && -f "$st" && ! "$d/$f" -nt "$st" ]] && continue
    head="$(sed -n '1s/^# //p' "$d/$f")"
    s="$(_lm_field "$d/$f" SUMMARY)"; nx="$(_lm_field "$d/$f" NEXT)"
    if [[ -z "$s" ]]; then
      s="$(sed -n '/^## Result/,$p' "$d/$f" | sed '1,2d' | tr '\n' ' ' | tr -s ' ' | cut -c1-260)"
    fi
    printf '  - %s: %s%s (.loomy/memory/delegations/%s)\n' "$head" "${s:0:160}" "${nx:+ · next: ${nx:0:100}}" "$f"
    k=$(( k + 1 ))
  done < <(ls "$d" 2>/dev/null | sort | tail -n "${2:-5}")
  return 0
}

# loomy_memory_state <root> [max lines]: STATE.md without its comment and empty sections, at most max lines.
loomy_memory_state() {
  local f; f="$(loomy_memory_dir "$1")/STATE.md"
  [[ -f "$f" ]] || return 0
  awk '/<!--/ { c = 1 } c { if (/-->/) c = 0; next } { print }' "$f" \
    | awk 'NF { if (h != "" && $0 !~ /^## /) { print h; h = "" } if ($0 ~ /^## /) { h = $0; next } if ($0 !~ /^# /) print }' \
    | head -n "${2:-60}"
}

# loomy_memory_from_transcript <transcript.jsonl>: "task<TAB>result" of a native subagent (first user message,
# last assistant text), through python3; nothing without it.
loomy_memory_from_transcript() {
  [[ -f "$1" ]] && command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
task = result = ""
def text(c):
    if isinstance(c, str): return c
    if isinstance(c, list): return "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return ""
for line in open(sys.argv[1], encoding="utf-8"):
    try: e = json.loads(line)
    except Exception: continue
    m = e.get("message") or {}
    role = m.get("role") or e.get("type")
    t = text(m.get("content"))
    if role == "user" and not task and t.strip(): task = t
    elif role == "assistant" and t.strip(): result = t
print(task.replace("\t", " ").replace("\n", "\x1f") + "\t" + result.replace("\t", " ").replace("\n", "\x1f"))
PY
}

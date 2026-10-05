#!/usr/bin/env bash
# Drafts text with a local model served by LM Studio: nothing leaves the machine. Bash 3.2 compatible.
#   loomy-local-writer.sh --check          prints the local model and exits 0 when a local server answers
#   loomy-local-writer.sh "<task>"         prints the draft (text only: no tools, no MCP, no plugins)
# Runs Claude Code against LM Studio's Anthropic-compatible API, stripped down (the light setup measured in
# docs/LOCAL_MODEL_TEST.md). Used by loomy audit as the writer only when Codex is not available.
# Server: LOOMY_LOCAL_URL (http://127.0.0.1:1234 by default); token: LM_API_TOKEN when the server requires one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"

ROOT=""; CHECK=0; TASK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TASK="$1" ;;
  esac
  shift
done
URL="${LOOMY_LOCAL_URL:-http://127.0.0.1:1234}"
# Local addresses only: the point is that nothing leaves the machine.
case "$URL" in http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;; *) echo "LOOMY_LOCAL_URL must be a local address" >&2; exit 2 ;; esac
TOKEN="${LM_API_TOKEN:-lmstudio}"

# First loaded chat model (embedding models skipped).
MODEL="$(curl -s -m 2 -H "Authorization: Bearer $TOKEN" "$URL/v1/models" 2>/dev/null \
  | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | grep -vi 'embed' | head -1)"
[[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || MODEL=""
if (( CHECK )); then [[ -n "$MODEL" ]] && { echo "$MODEL"; exit 0; }; exit 1; fi
[[ -n "$MODEL" ]] || { echo "no local model answering at $URL" >&2; exit 1; }
[[ -n "$TASK" ]] || { echo "usage: loomy-local-writer.sh \"<task>\"" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found" >&2; exit 1; }
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"

# Empty configuration folder: no plugins, hooks or memory sent to the local model (they slow it down a lot).
CFG="$(mktemp -d "${TMPDIR:-/tmp}/loomy-local.XXXXXX")" || exit 1
trap 'rm -rf "$CFG"' EXIT
start="$(date +%s)"
out="$(ANTHROPIC_BASE_URL="$URL" ANTHROPIC_AUTH_TOKEN="$TOKEN" ANTHROPIC_API_KEY="" CLAUDE_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_MAX_CONTEXT_TOKENS=60000 \
  claude -p --model "$MODEL" --tools "" --strict-mcp-config "$TASK" </dev/null 2>/dev/null)"
rc=$?
dur=$(( $(date +%s) - start ))
status="ok"; (( rc == 0 )) && [[ -n "$out" ]] || status="failed"
ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"l$(date +%s)$$\",\"bridge\":\"local\",\"role\":\"documenter\",\"family\":\"local\",\"model\":$(ai_json_str "$MODEL"),\"effort\":\"-\",\"profile\":\"-\",\"sandbox\":\"text-only\",\"status\":\"$status\",\"duration_s\":$dur,\"tokens_in\":0,\"tokens_out\":0,\"cost_usd\":0,\"cost_source\":\"local\",\"files_changed\":0"
[[ "$status" == "ok" ]] || { echo "local model failed (code $rc)" >&2; exit 1; }
printf '%s\n' "$out"

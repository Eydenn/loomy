#!/usr/bin/env bash
# Capture loomy watch views as animated README SVGs, using a disposable project.
set -euo pipefail

usage() {
  echo "Usage: tools/capture-watch.sh <en|fr> [live|tree] <out.svg>" >&2
}

if [[ $# == 2 ]]; then
  LANGUAGE="$1"
  VIEW=live
  OUTPUT="$2"
elif [[ $# == 3 ]]; then
  LANGUAGE="$1"
  VIEW="$2"
  OUTPUT="$3"
else
  usage
  exit 2
fi
case "$LANGUAGE" in en|fr) ;; *) usage; exit 2 ;; esac
case "$VIEW" in live|tree) ;; *) usage; exit 2 ;; esac
[[ -n "$OUTPUT" ]] || { usage; exit 2; }
[[ "$OUTPUT" == /* ]] || OUTPUT="$PWD/$OUTPUT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STUB_DIR="$REPO_ROOT/tests/stubs"
for required in python3 sleep; do
  command -v "$required" >/dev/null 2>&1 || { echo "Missing required command: $required" >&2; exit 1; }
done
for stub in claude codex gh; do
  [[ -x "$STUB_DIR/$stub" ]] || { echo "Missing executable test stub: $STUB_DIR/$stub" >&2; exit 1; }
done

mkdir -p "$(dirname "$OUTPUT")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loomy-watch-capture.XXXXXX")"
cleanup() {
  local pid
  for pid in ${DEMO_PIDS[@]+"${DEMO_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  for pid in ${DEMO_PIDS[@]+"${DEMO_PIDS[@]}"}; do wait "$pid" 2>/dev/null || true; done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

HOME_DIR="$WORK_DIR/home"
XDG_DIR="$WORK_DIR/config"
DEMO_ROOT="$WORK_DIR/demo-project"
FRAME_DIR="$WORK_DIR/frames"
mkdir -p "$HOME_DIR" "$XDG_DIR" "$DEMO_ROOT" "$FRAME_DIR"
DEMO_PIDS=()

export PATH="$STUB_DIR:$PATH"
export HOME="$HOME_DIR" XDG_CONFIG_HOME="$XDG_DIR"
export LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_LANG="$LANGUAGE"
export LOOMY_FORCE_COLOR=1 LOOMY_WATCH_GROUP=request
export TERM=xterm-256color COLORTERM=truecolor
unset NO_COLOR AI_ROUTE_ENV AI_ROUTE_PROFILE LOOMY_UI_LANG LOOMY_SCREEN_OWNER LOOMY_SCREEN LOOMY_PAGE_OUT

# The project defaults to an orchestrated Claude lead when both CLI stubs are on PATH.
(cd "$DEMO_ROOT" && "$REPO_ROOT/bin/loomy" init --yes --no-clipboard >/dev/null 2>&1)

# Persistent local processes make the synthetic session and running delegations genuinely live to the renderer.
sleep 3600 & LEAD_PID=$!; DEMO_PIDS+=("$LEAD_PID")
sleep 3600 & EXECUTOR_PID=$!; DEMO_PIDS+=("$EXECUTOR_PID")
sleep 3600 & DEVELOPER_PID=$!; DEMO_PIDS+=("$DEVELOPER_PID")
sleep 3600 & ARCHITECT_PID=$!; DEMO_PIDS+=("$ARCHITECT_PID")
export DEMO_ROOT LEAD_PID EXECUTOR_PID DEVELOPER_PID ARCHITECT_PID

python3 - <<'PY'
import datetime
import json
import os

root = os.environ["DEMO_ROOT"]
now = datetime.datetime.now(datetime.timezone.utc)
lead_pid = int(os.environ["LEAD_PID"])
executor_pid = int(os.environ["EXECUTOR_PID"])
developer_pid = int(os.environ["DEVELOPER_PID"])
architect_pid = int(os.environ["ARCHITECT_PID"])
session = "watch-demo"
events = []

def timestamp(seconds_ago):
    value = now - datetime.timedelta(seconds=seconds_ago)
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")

def add(seconds_ago, event_type, **fields):
    row = {"ts": timestamp(seconds_ago), "type": event_type}
    row.update(fields)
    events.append((seconds_ago, row))

def start(seconds_ago, id_, role, family, model, effort, task, pid, bridge,
          sandbox="read-only", requested=False, off_routing="", why=""):
    fields = {
        "id": id_, "session": session, "pid": pid, "bridge": bridge,
        "family": family, "role": role, "model": model, "effort": effort,
        "sandbox": sandbox, "requested": requested,
        "off_routing": off_routing, "why": why, "task": task,
    }
    if bridge == "subagent":
        fields["background"] = True
    add(seconds_ago, "delegation_start", **fields)

def finish(seconds_ago, id_, role, family, model, effort, task, bridge,
           duration, outcome="done", cost=0.0, sandbox="read-only"):
    fields = {
        "id": id_, "session": session, "pid": 1, "bridge": bridge,
        "family": family, "role": role, "model": model, "effort": effort,
        "sandbox": sandbox, "status": "ok", "duration_s": duration,
        "tokens_in": 18000, "tokens_cached": 8000, "tokens_out": 1400,
        "cost_usd": cost, "cost_source": "estimate", "files_changed": 0,
        "format": "structured", "outcome": outcome, "task": task,
    }
    add(seconds_ago, "delegation", **fields)

add(180, "session", event="start", tool="claude", family="claude",
    session=session, source="startup", pid=lead_pid,
    model="claude-opus-5-5", effort="high")
add(170, "phase", phase="build", session=session)
add(148, "request", id="request-1", session=session,
    excerpt="Tighten the search filters without changing existing URLs")

start(140, "explorer-1", "explorer", "claude", "claude-haiku-5-5", "low",
      "Map the current project filtering behavior", lead_pid, "subagent")
finish(109, "explorer-1", "explorer", "claude", "claude-haiku-5-5", "low",
       "Map the current project filtering behavior", "subagent", 31, cost=0.012)
start(102, "reviewer-1", "reviewer", "codex", "gpt-6.1-sol", "high",
      "Review URL state handling and edge cases", 1, "codex")
finish(73, "reviewer-1", "reviewer", "codex", "gpt-6.1-sol", "high",
       "Review URL state handling and edge cases", "codex", 29,
       outcome="partial", cost=0.18)

add(58, "request", id="request-2", session=session,
    excerpt="Add keyboard shortcuts and update the usage guide")
start(51, "documenter-1", "documenter", "claude", "claude-sonnet-5-5", "low",
      "Document the new filter shortcuts", lead_pid, "subagent")
finish(29, "documenter-1", "documenter", "claude", "claude-sonnet-5-5", "low",
       "Document the new filter shortcuts", "subagent", 22, cost=0.04)
add(24, "usage", session=session, scope="lead", tool="claude", family="claude",
    model="claude-opus-5-5", messages=2, tokens_in=52000,
    tokens_cached=39000, tokens_out=2800, cost_usd=0.25, cost_source="estimate")
start(19, "executor-2", "executor", "codex", "gpt-6-luna", "max",
      "Sync project filters with the URL query string", executor_pid, "codex",
      sandbox="workspace-write")
start(16, "developer-2", "developer", "claude", "claude-sonnet-5-5", "medium",
      "Keep filter controls accessible by keyboard", developer_pid, "subagent",
      sandbox="workspace-write")
start(11, "architect-2", "architect", "codex", "gpt-6.1-sol", "high",
      "Check the URL state design and edge cases", architect_pid, "codex",
      requested=True, off_routing="tool,model", why="user request")

events.sort(key=lambda item: -item[0])
journal = os.path.join(root, ".loomy", "logs", "events.jsonl")
os.makedirs(os.path.dirname(journal), exist_ok=True)
with open(journal, "w", encoding="utf-8") as output:
    for _, row in events:
        output.write(json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n")

state = os.path.join(root, ".loomy", "state")
lines = []
if os.path.exists(state):
    with open(state, encoding="utf-8") as source:
        lines = [line for line in source.read().splitlines()
                 if line and not line.startswith("phase=")]
with open(state, "w", encoding="utf-8") as output:
    output.write("phase=build\n" + "\n".join(lines) + "\n")
PY

append_midpoint_finish() {
  python3 - <<'PY'
import datetime
import json
import os

path = os.path.join(os.environ["DEMO_ROOT"], ".loomy", "logs", "events.jsonl")
started = None
with open(path, encoding="utf-8") as source:
    for line in source:
        row = json.loads(line)
        if row.get("type") == "delegation_start" and row.get("id") == "developer-2":
            started = datetime.datetime.strptime(row["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc)
            break
if started is None:
    raise SystemExit("Missing running developer event")
now = datetime.datetime.now(datetime.timezone.utc)
duration = max(0, int((now - started).total_seconds()))
row = {
    "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "type": "delegation",
    "id": "developer-2", "session": "watch-demo", "pid": int(os.environ["DEVELOPER_PID"]),
    "bridge": "subagent", "family": "claude", "role": "developer",
    "model": "claude-sonnet-5-5", "effort": "medium", "sandbox": "workspace-write",
    "status": "ok", "duration_s": duration, "tokens_in": 22000,
    "tokens_cached": 16000, "tokens_out": 1900, "cost_usd": 0.06,
    "cost_source": "estimate", "files_changed": 2, "format": "structured",
    "outcome": "done", "task": "Keep filter controls accessible by keyboard",
}
with open(path, "a", encoding="utf-8") as output:
    output.write(json.dumps(row, separators=(",", ":"), ensure_ascii=False) + "\n")
PY
}

FRAME_COUNT=24
FINISH_AT=12
if [[ "$VIEW" == tree ]]; then
  FRAME_COUNT=12
  FINISH_AT=6
fi
for (( frame_index = 0; frame_index < FRAME_COUNT; frame_index++ )); do
  if (( frame_index == FINISH_AT )); then append_midpoint_finish; fi
  frame_path="$FRAME_DIR/frame-$(printf '%02d' "$frame_index").ans"
  if [[ "$VIEW" == tree ]]; then
    COLUMNS=150 LINES=44 LOOMY_TREE=diagram LOOMY_TICK="$frame_index" \
      "$REPO_ROOT/scripts/loomy-tree.sh" --root "$DEMO_ROOT" >"$frame_path"
  else
    COLUMNS=110 LINES=34 LOOMY_TICK="$frame_index" \
      "$REPO_ROOT/scripts/loomy-tree.sh" --root "$DEMO_ROOT" --once >"$frame_path"
  fi
  if (( frame_index + 1 < FRAME_COUNT )); then sleep 1; fi
done

if [[ "$VIEW" == tree ]]; then SVG_TITLE="loomy agent tree"; else SVG_TITLE="loomy watch"; fi
python3 "$SCRIPT_DIR/ansi2svg.py" "$OUTPUT" "$FRAME_DIR"/frame-*.ans \
  --delay 0.27 --title "$SVG_TITLE"

if [[ "$VIEW" == tree ]]; then
  if [[ "$LANGUAGE" == fr ]]; then HEADING="ARBRE DES AGENTS LOOMY"; else HEADING="LOOMY AGENT TREE"; fi
elif [[ "$LANGUAGE" == fr ]]; then HEADING="EN COURS"; else HEADING="IN PROGRESS"; fi
grep -Fq "$HEADING" "$OUTPUT" || { echo "Generated SVG is missing: $HEADING" >&2; exit 1; }
if LC_ALL=C grep -Eq '/Users/|/var/folders|/tmp(/|$)' "$OUTPUT"; then
  echo "Generated SVG contains a local path" >&2
  exit 1
fi
SIZE_BYTES="$(wc -c <"$OUTPUT" | tr -d ' ')"
if (( SIZE_BYTES >= 300 * 1024 )); then
  echo "Generated SVG exceeds 300 KB: $SIZE_BYTES bytes" >&2
  exit 1
fi

if [[ "${LOOMY_CAPTURE_PREVIEW:-0}" == 1 ]]; then
  echo "First rendered frame (ANSI stripped):"
  python3 - "$FRAME_DIR/frame-00.ans" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    frame = source.read()
print("\n".join(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", frame).splitlines()[:40]))
PY
fi

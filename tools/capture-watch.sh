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
for required in perl python3 sleep; do
  command -v "$required" >/dev/null 2>&1 || { echo "Missing required command: $required" >&2; exit 1; }
done
for stub in claude codex gh; do
  [[ -x "$STUB_DIR/$stub" ]] || { echo "Missing executable test stub: $STUB_DIR/$stub" >&2; exit 1; }
done

mkdir -p "$(dirname "$OUTPUT")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loomy-watch-capture.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
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
CODEX_HOME="$HOME_DIR/.codex"
CLAUDE_CONFIG_DIR="$HOME_DIR/.claude"
mkdir -p "$HOME_DIR" "$XDG_DIR" "$DEMO_ROOT" "$FRAME_DIR" "$CODEX_HOME/sessions" "$CLAUDE_CONFIG_DIR/projects"
DEMO_PIDS=()

export PATH="$STUB_DIR:$PATH"
export HOME="$HOME_DIR" XDG_CONFIG_HOME="$XDG_DIR" CODEX_HOME CLAUDE_CONFIG_DIR
export LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_LANG="$LANGUAGE"
export LOOMY_FORCE_COLOR=1 LOOMY_WATCH_GROUP=request
export TERM=xterm-256color COLORTERM=truecolor
unset NO_COLOR AI_ROUTE_ENV AI_ROUTE_PROFILE LOOMY_UI_LANG LOOMY_SCREEN_OWNER LOOMY_SCREEN LOOMY_PAGE_OUT

# The project defaults to an orchestrated Claude lead when both CLI stubs are on PATH.
(cd "$DEMO_ROOT" && "$REPO_ROOT/bin/loomy" init --yes --no-clipboard >/dev/null 2>&1)

# A persistent local process keeps the synthetic native owner session live to the renderer.
sleep 3600 & LEAD_PID=$!; DEMO_PIDS+=("$LEAD_PID")
perl "$REPO_ROOT/tests/fixtures/capture-native.pl" seed "$DEMO_ROOT" "$LEAD_PID"

append_midpoint_finish() {
  perl "$REPO_ROOT/tests/fixtures/capture-native.pl" finish "$DEMO_ROOT" "$LEAD_PID"
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

if [[ "$LANGUAGE" == fr ]]; then
  LIVE_LABEL="en direct"; FOLD_LABEL="+4 plus anciens · 2 perdus"; RECAP_LABEL="récapitulatif"
else
  LIVE_LABEL=live; FOLD_LABEL="+4 earlier · 2 lost"; RECAP_LABEL=recap
fi
for marker in demo1234 "$LIVE_LABEL" "$FOLD_LABEL" "$RECAP_LABEL"; do
  grep -Fq "$marker" "$OUTPUT" || { echo "Generated SVG is missing native heading: $marker" >&2; exit 1; }
done
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

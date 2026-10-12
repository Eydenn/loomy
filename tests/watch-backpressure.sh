#!/usr/bin/env bash
# Deterministic queue semantics and real PTY under a 1.4-second synthetic renderer.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loomy-watch-backpressure.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
  (( BASH_SUBSHELL == 0 )) || return 0
  if [[ -n "${LOOMY_BACKPRESSURE_OUT:-}" ]]; then
    mkdir -p "$LOOMY_BACKPRESSURE_OUT"
    for file in watch.log render.trace; do [[ ! -f "$WORK/$file" ]] || cp "$WORK/$file" "$LOOMY_BACKPRESSURE_OUT/"; done
  fi
  if [[ -f "$WORK/sampler.pid" ]]; then kill "$(<"$WORK/sampler.pid")" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
if [[ -z "${LOOMY_BACKPRESSURE_STATUS:-}" ]]; then
  eval "$(sed -n '/^loomy_watch_coalesce()/,/^}/p' "$REPO/scripts/loomy-status.sh")"
  exec 8< <(printf '11|1||clock11\n12|0||clock12\n13|0|t|clock13\n14|1||clock14\n15|0|q|clock15\n16|0|a|clock16\n')
  sleep 0.1
  row="$(loomy_watch_coalesce 10 0 '' clock10)"
  check 'queued timers use latest timestamp and OR dirty until the first key' test "$row" = '13|1|t|clock13'
  row="$(loomy_watch_coalesce 13 1 t clock13)"
  check 'an existing key is never consumed or reordered' test "$row" = '13|1|t|clock13'
  IFS='|' read -r now dirty key clock <&8
  row="$(loomy_watch_coalesce "$now" "$dirty" "$key" "$clock")"
  check 'quit stays ahead of later keys and retains prior dirty evidence' test "$row" = '15|1|q|clock15'
  IFS='|' read -r now dirty key clock <&8
  check 'key after quit remains unread by coalescing' test "$key" = a
  exec 8<&-
fi
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export LOOMY_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
export PATH="$WORK/bin:$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export WATCH_BACKPRESSURE_RUNTIME="$WORK/runtime" WATCH_BACKPRESSURE_ROOT="$WORK/project"
export WATCH_BACKPRESSURE_TRACE="$WORK/render.trace" WATCH_BACKPRESSURE_TRANSCRIPT="$WORK/watch.log" WATCH_BACKPRESSURE_SAMPLER="$WORK/sampler.pid"
unset CODEX_THREAD_ID LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT AI_ROUTE_ENV LOOMY_WATCH_TOOL LOOMY_JOURNAL LOOMY_JOURNAL_TASKS TMUX
mkdir -p "$HOME" "$XDG_CONFIG_HOME/loomy" "$WORK/bin" "$WATCH_BACKPRESSURE_RUNTIME"
printf 'notify=no\nwatch_view=tree\n' >"$XDG_CONFIG_HOME/loomy/config"
cp -R "$REPO/scripts" "$WATCH_BACKPRESSURE_RUNTIME/scripts"
if [[ -n "${LOOMY_BACKPRESSURE_STATUS:-}" ]]; then cp "$LOOMY_BACKPRESSURE_STATUS" "$WATCH_BACKPRESSURE_RUNTIME/scripts/loomy-status.sh"; fi
mv "$WATCH_BACKPRESSURE_RUNTIME/scripts/loomy-tree.sh" "$WATCH_BACKPRESSURE_RUNTIME/scripts/loomy-tree-real.sh"
cp "$REPO/tests/fixtures/watch-backpressure-tree.sh" "$WATCH_BACKPRESSURE_RUNTIME/scripts/loomy-tree.sh"
cp "$REPO/tests/fixtures/watch-backpressure-perl.sh" "$WORK/bin/perl"
chmod +x "$WORK/bin/perl"
export LOOMY_HOME="$WATCH_BACKPRESSURE_RUNTIME"
perl "$REPO/tests/fixtures/codex-native.pl" compact-seed "$WATCH_BACKPRESSURE_ROOT" "$CODEX_HOME/sessions" "$$"
check 'slow renderer watch quits promptly and restores its terminal' expect "$REPO/tests/fixtures/watch-backpressure.exp"
check 'coalesced slow frames start on recent sampler timestamps' perl -e 'my @rows; while(<>){my ($start,$tick)=split /\|/; push @rows,[$start,$tick]; die "stale frame: ".($start-$tick)." seconds\n" if $start-$tick>2.5} die "too few slow frames\n" unless @rows>=6;' "$WATCH_BACKPRESSURE_TRACE"
check 'watch cleanup terminates its own persistent sampler' perl -e 'my $pid=<>; chomp $pid; die "sampler still running\n" if kill(0,$pid);' "$WATCH_BACKPRESSURE_SAMPLER"
check 'watch cleanup restores cursor visibility' perl -0777 -e 'my $s=<>; die unless rindex($s,"\e[?25h")>rindex($s,"\e[?25l");' "$WATCH_BACKPRESSURE_TRANSCRIPT"
if [[ -n "${LOOMY_BACKPRESSURE_OUT:-}" ]]; then mkdir -p "$LOOMY_BACKPRESSURE_OUT"; cp "$WORK/watch.log" "$WORK/render.trace" "$LOOMY_BACKPRESSURE_OUT/"; fi
printf '%s watch backpressure checks passed\n' "$PASS"

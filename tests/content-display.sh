#!/usr/bin/env bash
# Structural display-context parity; synthetic data, isolated accounts, no providers.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-content-display.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
# Every command is synchronous. The follow probe owns and reaps its isolated
# process group, so this read-only suite needs no machine-wide process scan.
cleanup() {
  local rc=$?; [[ ! -s "$LOOMY_TEST_GUARD_LOG" ]] || rc=1
  if (( rc )) && [[ -n "${LOOMY_CONTENT_DISPLAY_OUT:-}" ]]; then mkdir -p "$LOOMY_CONTENT_DISPLAY_OUT"; cp -R "$WORK/." "$LOOMY_CONTENT_DISPLAY_OUT/"; fi
  rm -rf "$WORK"; exit "$rc"
}
trap cleanup EXIT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/loomy" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR/projects"
export LOOMY_HOME="$REPO" LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
export LOOMY_WATCH_ID=content-display
unset CODEX_THREAD_ID LOOMY_JOURNAL_CONTENT LOOMY_CONTENT_PROJECT LOOMY_JOURNAL_TASKS LOOMY_WATCH_TOOL LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT LOOMY_TREE
PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$((PASS+1)); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
# shellcheck source=../scripts/lib/journal.sh
source "$REPO/scripts/lib/journal.sh"
# shellcheck source=../scripts/lib/sessionlog.sh
source "$REPO/scripts/lib/sessionlog.sh"
check 'resolver boundaries, legacy bytes, streaming and export accounting' python3 "$REPO/tests/fixtures/content-display-check.py" "$REPO" "$WORK/unit"

for setup in claude-solo codex-solo hybrid-claude hybrid-codex; do
  for grants in 0 1; do
    ROOT="$WORK/$setup-$grants"
    perl "$REPO/tests/fixtures/content-display.pl" "$REPO" "$ROOT" "$setup" "$grants" "$$"
    J="$ROOT/.loomy/logs/events.jsonl"; cp "$J" "$ROOT/original-journal"
    for lang in en fr; do
      export LOOMY_LANG="$lang" LOOMY_UI_LANG="$lang"
      # Language state is per shell; loading the dictionaries again is deliberate.
      source "$REPO/scripts/lib/i18n.sh"
      ai_display_context_init "$ROOT"
      ai_journal_display_events "$J" >"$ROOT/enhanced-$lang"
      _ai_session_events "$J" >"$ROOT/session-$lang"
      bash "$REPO/scripts/loomy-log.sh" --root "$ROOT" -n 100 >"$ROOT/pretty-$lang"
      for terminal in plain ascii; do
        export NO_COLOR=1 TERM=xterm-256color
        unset LC_ALL
        [[ "$terminal" != ascii ]] || export LC_ALL=C TERM=dumb
        for size in 80x24 80x30 200x65; do
          export COLUMNS="${size%x*}" LINES="${size#*x}"
          tag="$lang-$terminal-$size"
          LOOMY_WATCH_VIEW=tree bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$ROOT/tree-$tag" 2>&1
          LOOMY_WATCH_VIEW=list bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$ROOT/list-$tag" 2>&1
          LOOMY_TREE=diagram bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$ROOT/diagram-$tag" 2>&1
          bash "$REPO/scripts/loomy-status.sh" --root "$ROOT" >"$ROOT/status-$tag" 2>&1
          check "$setup grants=$grants $tag six surfaces retain context and facts" perl -MJSON::PP -MEncode=decode -e '
            my ($root,$grants,$lang,$tag,$width)=@ARGV;
            open my $h,"<","$root/expected.json" or die $!; my $e=decode_json(do{local $/;<$h>});
            for my $surface ("tree-$tag","list-$tag","diagram-$tag","status-$tag","enhanced-$lang","session-$lang","pretty-$lang") {
              open my $f,"<","$root/$surface" or die $!; my $s=decode("UTF-8",do{local $/;<$f>});
              die "private payload on $surface\n" if $s =~ /PRIVATE_|HASH\(|ARRAY\(/;
              die "missing model on $surface\n" unless $s =~ /(?:6-luna|claude-sonnet-5-5|SONNET)/i;
              if ($grants) {
                my $label=$surface =~ /^(?:status|pretty)/ ? "Recover paused task" : $e->{first};
                die "missing authorized label $label on $surface\n" unless index($s,$label)>=0;
                die "same-role task lost on $surface\n" if $surface =~ /^(?:tree|list|diagram|enhanced|session)/ && index($s,$e->{second})<0;
              } else {
                die "missing named fallback on $surface\n" unless $s =~ /(?:Role:|R\x{f4}le :|context unavailable|contexte indisponible)/;
              }
              if ($surface =~ /^(?:tree|list)-/) {
                for (split /\n/,$s) { die "line wider than $width on $surface\n" if length($_)>$width }
                die "missing effort on $surface\n" unless $s =~ /max/;
                die "missing running state on $surface\n" unless $s =~ /running|en cours/;
              }
              die "missing pause facts on $surface\n" if $surface =~ /^status/ && $s !~ /(?:paused|pause|en pause)/i;
              die "missing error/duration on $surface\n" if $surface =~ /^enhanced/ && $s !~ /\|failed\|0:15/;
            }
          ' "$ROOT" "$grants" "$lang" "$tag" "$COLUMNS"
        done
      done
    done
    check "$setup grants=$grants display never rewrites the journal" cmp "$J" "$ROOT/original-journal"
  done
done
for setup in claude-solo codex-solo hybrid-claude hybrid-codex; do
  ROOT="$WORK/empty-$setup"; mkdir -p "$ROOT/.loomy/logs"
  lead=claude; [[ "$setup" != codex-solo && "$setup" != hybrid-codex ]] || lead=codex
  mode=SOLO; [[ "$setup" != hybrid-* ]] || mode=HYBRID
  printf -- '---\nname: Empty fixture\nai_mode: %s\nai_lead: %s\nbudget: equilibre\n---\n' "$mode" "$lead" >"$ROOT/.loomy/brief.md"
  : >"$ROOT/.loomy/logs/events.jsonl"
  for lang in en fr; do
    export LOOMY_LANG="$lang" LOOMY_UI_LANG="$lang" COLUMNS=80 LINES=24 NO_COLOR=1 TERM=dumb
    bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$ROOT/tree-$lang" 2>&1
    bash "$REPO/scripts/loomy-status.sh" --root "$ROOT" >"$ROOT/status-$lang" 2>&1
    bash "$REPO/scripts/loomy-log.sh" --root "$ROOT" >"$ROOT/log-$lang" 2>&1
    check "$setup $lang empty journal produces no phantom task" perl -0777 -e '
      my $root=shift; for my $file (@ARGV) {open my $h,"<","$root/$file" or die $!; my $s=do{local $/;<$h>} // "";
        die "phantom task/error\n" if $s =~ /PRIVATE_|Wide character|Undefined subroutine|unbound variable|syntax error/;
        die "empty pretty output expected\n" if $file =~ /^log-/ && length($s);
        die "missing empty view\n" if $file !~ /^log-/ && !length($s);
      }
    ' "$ROOT" "tree-$lang" "status-$lang" "log-$lang"
  done
done
printf '%s content display checks passed\n' "$PASS"

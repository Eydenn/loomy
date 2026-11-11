#!/usr/bin/env bash
# Feedback on Loomy: prepares a GitHub issue with the useful, anonymised context. Bash 3.2 compatible.
#   loomy-feedback.sh ["message"]   describe the problem or idea; preview, then sent only after confirmation
#   loomy-feedback.sh --print       only prints the issue text (nothing is sent)
#   loomy-feedback.sh --root <dir>  project whose state to attach (default: current folder, if it is a Loomy project)
#   loomy-feedback.sh list          your feedback and where it stands (received, being handled, fixed in X.Y.Z)
#   loomy-feedback.sh triage        maintainer: open feedback grouped by cause, priority and reply proposed; each reply
#                                   posted only after your approval
#   loomy-feedback.sh mark <n> <v>  maintainer: feedback #n fixed in version v (label fixed-in:v)
#   loomy-feedback.sh close <v>     maintainer: comments and closes the feedback fixed in v, after your approval
# Attached: versions (Loomy, system, bash, git, Claude Code, Codex, gh), and for a project: type, stage, AI mode,
# profile, phase and latest log events WITHOUT the task text. Never: name, goal, paths, code.
# shellcheck disable=SC2034  # UI_* variables are consumed by ui.sh.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

REPO="${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}"
ROOT=""; MSG=""; PRINT=0; SUB=""
SUB_ARGS=()
# --print is offline even when combined with a follow-up subcommand by mistake.
for arg in "$@"; do [[ "$arg" != --print ]] || PRINT=1; done
case "${1:-}" in list|triage|mark|close|--check-fixed) SUB="$1"; shift; SUB_ARGS=("$@"); set -- ;; esac
LOOMY_V="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "?")"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//; s/loomy-feedback.sh/loomy feedback/' | i18n_lines; exit 0 ;;
    *) MSG="${MSG:+$MSG }$1" ;;
  esac
  shift
done
[[ -z "$ROOT" ]] && ROOT="$(ai_project_root 2>/dev/null || pwd)"

# ---------------------------------------------------------------- follow-up and triage (gh)
# Feedback issues: title "Feedback: …" (any author), label "feedback" when the maintainer has set it.
FB_JQ='.[] | "\(.number)|\(.state)|\([.labels[].name] | join(","))|\(.title)"'
need_gh() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && return 0
  ui_err "$(t "GitHub CLI not ready")" "$(t "gh auth login, then try again")"; exit 1
}
fixed_of() { printf '%s' "$1" | tr ',' '\n' | sed -n 's/^fixed-in://p' | head -1; }
is_maintainer() { [[ "$(gh api "repos/$REPO" --jq .permissions.push 2>/dev/null)" == "true" ]]; }
if [[ -n "$SUB" ]]; then
  if (( PRINT )); then
    ui_err "$(t "--print is only available when preparing feedback")" "loomy feedback --print"
    exit 2
  fi
  case "$SUB" in
    list)
      need_gh
      rows="$(gh issue list -R "$REPO" --author @me --state all --search "Feedback in:title" --limit 50 --json number,title,state,labels --jq "$FB_JQ" 2>/dev/null || true)"
      ui_section "$(t "YOUR FEEDBACK")" "$REPO"
      if [[ -z "$rows" ]]; then ui_kv "$(t "Feedback")" "${C_DIM}$(t "none yet: loomy feedback \"…\"")${C_RESET}"
      else
        while IFS='|' read -r n st labels title; do
          [[ -n "$n" ]] || continue
          v="$(fixed_of "$labels")"
          if [[ -n "$v" ]]; then s="${C_GREEN}$(t "fixed in %s" "$v")${C_RESET}"; ai_version_ge "$LOOMY_V" "$v" 2>/dev/null && s="$s ${C_DIM}($(t "you have it"))${C_RESET}" || s="$s ${C_DIM}(loomy update)${C_RESET}"
          elif [[ "$st" == CLOSED ]]; then s="${C_DIM}$(t "closed")${C_RESET}"
          elif [[ ",$labels," == *",triaged,"* ]]; then s="${C_YELLOW}$(t "being handled")${C_RESET}"
          else s="$(t "received")"; fi
          ui_kv "#$n" "${title#Feedback: } · $s"
        done <<<"$rows"
      fi
      ui_rail_end "https://github.com/$REPO/issues" ;;
    --check-fixed)
      # At launch (once a day, in the background): the user's feedback fixed in the installed version, not yet announced.
      command -v gh >/dev/null 2>&1 || exit 0
      cfg="${XDG_CONFIG_HOME:-$HOME/.config}/loomy"; seen="$(cat "$cfg/feedback-seen" 2>/dev/null || true)"; out=""
      rows="$(gh issue list -R "$REPO" --author @me --state all --search "Feedback in:title label:fixed-in" --limit 30 --json number,title,state,labels --jq "$FB_JQ" 2>/dev/null || true)"
      while IFS='|' read -r n _ labels title; do
        [[ -n "$n" ]] || continue
        v="$(fixed_of "$labels")"; [[ -n "$v" ]] || continue
        case " $seen " in *" $n "*) continue ;; esac
        ai_version_ge "$LOOMY_V" "$v" 2>/dev/null || continue
        out="${out:+$out · }#$n ${title#Feedback: }"; seen="$seen $n"
      done <<<"$rows"
      mkdir -p "$cfg" && printf '%s\n' "$seen" >"$cfg/feedback-seen"
      [[ -n "$out" ]] && printf '%s\n' "$out" >"$cfg/feedback-fixed"
      exit 0 ;;
    mark)
      need_gh; is_maintainer || { ui_err "$(t "Maintainers only")" "$REPO"; exit 1; }
      n="${SUB_ARGS[0]:-}"; v="${SUB_ARGS[1]:-}"; [[ "$n" =~ ^[0-9]+$ && "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { t "Usage: loomy feedback mark <number> <version>" >&2; echo >&2; exit 2; }
      gh label create "fixed-in:$v" -R "$REPO" --color 0E8A16 --description "Fixed in Loomy $v" >/dev/null 2>&1 || true
      if gh issue edit "$n" -R "$REPO" --add-label "fixed-in:$v" >/dev/null 2>&1; then ui_ok "$(t "Feedback #%s marked fixed in %s" "$n" "$v")" "$(t "closed with loomy feedback close %s at release" "$v")"
      else ui_err "$(t "Not marked")" "#$n"; exit 1; fi ;;
    close)
      need_gh; is_maintainer || { ui_err "$(t "Maintainers only")" "$REPO"; exit 1; }
      v="${SUB_ARGS[0]:-}"; [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { t "Usage: loomy feedback close <version>" >&2; echo >&2; exit 2; }
      rows="$(gh issue list -R "$REPO" --state open --label "fixed-in:$v" --limit 100 --json number,title,state,labels --jq "$FB_JQ" 2>/dev/null || true)"
      [[ -n "$rows" ]] || { ui_ok "$(t "Nothing to close for %s" "$v")" ""; exit 0; }
      ui_section "$(t "FEEDBACK FIXED IN %s" "$v")"
      while IFS='|' read -r n _ _ title; do [[ -n "$n" ]] && ui_kv "#$n" "$title"; done <<<"$rows"
      msg="$(t "Fixed in Loomy %s, thanks for the feedback! Update with: loomy update" "$v")"
      ui_rail "   ${C_DIM}$(t "comment: %s" "$msg")${C_RESET}"
      # Posted only after an explicit yes (LOOMY_FEEDBACK_YES=1: already approved, for scripts).
      if [[ "${LOOMY_FEEDBACK_YES:-}" != 1 ]]; then
        ui_is_interactive || { ui_end "$(t "nothing was posted (run it in a terminal to approve)")"; exit 0; }
        UI_LABEL="$(t "Close")"; ui_choose "$(t "Comment and close these issues?")" 1 "$(t "Yes, comment and close")" "$(t "No")"
        [[ "${UI_INDEX:-1}" == 0 ]] || { ui_end "$(t "nothing was posted")"; exit 0; }
      fi
      while IFS='|' read -r n _ _ _; do
        [[ -n "$n" ]] || continue
        gh issue close "$n" -R "$REPO" --comment "$msg" >/dev/null 2>&1 && ui_ok "$(t "Closed")" "#$n" || ui_warn "$(t "Not closed")" "#$n"
      done <<<"$rows"
      ui_end "" ;;
    triage)
      need_gh; is_maintainer || { ui_err "$(t "Maintainers only")" "$REPO"; exit 1; }
      # shellcheck source=lib/feedback-triage.sh
      source "$SCRIPT_DIR/lib/feedback-triage.sh"
      fb_triage ;;
  esac
  exit 0
fi
IN_PROJECT=0; [[ -f "$ROOT/.loomy/brief.md" ]] && IN_PROJECT=1

ver() {
  {
    case "$1" in
      claude|codex) _loomy_launch_load; loomy_cli_meta "$@" ;;
      *) "$@" ;;
    esac
  } 2>/dev/null | perl -e '
    sysread STDIN,my $raw,4096;
    $raw //= ""; $raw =~ s/\r?\n.*\z//s;
    print $1 if $raw =~ /(?<![A-Za-z0-9.])([0-9]{1,6}(?:\.[0-9]{1,6}){1,3})(?![A-Za-z0-9.])/;
  ' || true
}

# Reads only bounded metadata and projects historical events in RAM. In particular,
# effective_policy no longer creates project-id (readers derive it without storing it); feedback still
# uses project_with_policy with an explicitly structural policy so that it never reads stored grants.
context() {
  perl -MFcntl=O_RDONLY,O_NOFOLLOW,O_NONBLOCK,S_ISREG -MJSON::PP -MDigest::SHA=sha256_hex -e '
    use strict; use warnings;
    my ($lib,$version_file,$root,$bash,$git,$claude,$codex,$gh,$os,$release,$arch,$project,
        $system_label,$project_label,$version_label,$profile_label,$files_label,$journal_label,$events_label)=@ARGV;
    require $lib;
    binmode STDOUT, ":raw";
    my $json=JSON::PP->new->utf8->canonical->max_depth(32);
    sub regular {
      my ($path)=@_;
      sysopen my $fh,$path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or return;
      my @st=stat($fh); return unless @st && S_ISREG($st[2]);
      return $fh;
    }
    sub prefix {
      my ($path,$cap)=@_; my $fh=regular($path) or return "";
      my $n=sysread($fh,my $raw,$cap); return defined($n) ? $raw : "";
    }
    sub version {
      my ($v)=@_; $v //= ""; $v =~ s/\r?\n\z//;
      return $v =~ /\A[0-9]{1,6}(?:\.[0-9]{1,6}){1,3}(?:[-+][A-Za-z0-9][A-Za-z0-9.-]{0,31})?\z/
        && length($v)<=64 ? $v : "?";
    }
    sub token {
      my ($v)=@_; return defined($v) && $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,99}\z/ ? $v : "?";
    }
    sub choice {
      my ($v,@allowed)=@_; return "unknown" unless defined($v) && !ref($v);
      return (grep {$_ eq $v} @allowed) ? $v : "unknown";
    }
    print "| Loomy | ",version(prefix($version_file,65))," |\n";
    print "| $system_label | ",join(" ",map {token($_)} ($os,$release,$arch))," |\n";
    print "| bash | ",version($bash)," |\n";
    print "| git | ",version($git)," |\n";
    print "| Claude Code | ",version($claude)," |\n";
    print "| Codex | ",version($codex)," |\n";
    print "| gh | ",version($gh)," |\n";
    print "| Terminal | ",token($ENV{TERM_PROGRAM})," · TERM=",token($ENV{TERM}),
      (length($ENV{TMUX}//"") ? " · tmux" : "")," |\n";
    exit unless $project;

    # Parse only the closed front-matter fields, never the authored brief body.
    my %brief; my $raw=prefix("$root/.loomy/brief.md",65536);
    if ($raw =~ /\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/s) {
      for (split /\r?\n/,$1) {
        next unless /\A(type|stage|ai_mode|ai_lead|budget|ai_files):[ \t]*(.{0,128})\z/;
        my ($k,$v)=($1,$2); next if exists $brief{$k};
        $v =~ s/[ \t]+\z//; $v =~ s/\A"(.*)"\z/$1/; $v =~ s/\A\x27(.*)\x27\z/$1/;
        $brief{$k}=$v;
      }
    }
    my $type=choice($brief{type},qw(web site api data ai mobile desktop cli emails custom other));
    my $stage=choice($brief{stage},qw(prototype mvp production));
    my $mode=choice($brief{ai_mode},qw(SOLO HYBRID ORCHESTRATED PARALLEL));
    my $lead=choice($brief{ai_lead},qw(claude codex));
    my $profile=choice($brief{budget},qw(econome equilibre qualite));
    my $files=choice($brief{ai_files},qw(versioned local private));
    my ($phase)=prefix("$root/.loomy/state",4096) =~ /^phase=([^\r\n]{0,128})\r?$/m;
    $phase=choice($phase,qw(brief discover interview propose approve build verify document commit retire done plan review audit report scope analyze validate fix));
    print "| $project_label | $type · $stage · $mode · lead $lead · $profile_label $profile · $files_label $files |\n";
    print "| $version_label | ",version(prefix("$root/.loomy/VERSION",65))," · phase $phase |\n";

    # The attachment is structural regardless of project grants or environment.
    my $policy=Loomy::ContentPolicy::defaults();
    # The real project identity never leaves the machine: a per-bundle random salt replaces it, so the hashes in a
    # public issue cannot be checked against dictionaries or linked across issues.
    $policy->{project_id}="p".sha256_hex(join("\0",time,$$,rand,rand));
    print "| $journal_label | $policy->{journal_content} |\n";

    # Last complete, valid events, not the raw log reader or its legacy display.
    # Bound total input to 8 MiB and each JSON line to 64 KiB before decoding.
    my $fh=regular("$root/.loomy/logs/events.jsonl") or exit;
    my $size=-s $fh; my $start=$size>8388608 ? $size-8388608 : 0;
    seek($fh,$start,0) or exit;
    my $n=sysread($fh,$raw,8388608); exit unless defined($n) && $n;
    $raw =~ s/\A[^\n]*\n// if $start;
    my $end=rindex($raw,"\n"); exit if $end<0;
    my @events;
    for my $line (reverse split /\n/,substr($raw,0,$end+1)) {
      next if length($line)>65536;
      my $event=eval {$json->decode($line)}; next unless ref($event) eq "HASH";
      my $safe=eval {Loomy::ContentPolicy::project_with_policy($policy,$event)};
      next unless $safe;
      delete @{$safe}{qw(task_ref label_ref)};
      push @events,$json->encode($safe); last if @events==15;
    }
    exit unless @events;
    print "\n<details><summary>$events_label</summary>\n\n```json\n";
    print "$_\n" for reverse @events;
    print "```\n\n</details>\n";
  ' "$SCRIPT_DIR/lib/content-policy.pl" "$SCRIPT_DIR/../VERSION" "$ROOT" \
    "${BASH_VERSION%%(*}" "$(ver git --version)" "$(ver claude --version)" \
    "$(ver codex --version)" "$(ver gh --version)" "$(uname -s 2>/dev/null || true)" \
    "$(uname -r 2>/dev/null || true)" "$(uname -m 2>/dev/null || true)" "$IN_PROJECT" \
    "$(t "System")" "$(t "Project")" "$(t "Project's Loomy")" "$(t "profile")" "$(t "ai_files")" \
    "$(t "Journal content attached")" "$(t "Latest log events (structure only)")"
}

body() {
  echo "## $(t "Feedback")"
  echo
  echo "${MSG:-_($(t "to be completed"))_}"
  echo
  echo "## $(t "Context (attached by loomy feedback, anonymized)")"
  echo
  echo "| | |"
  echo "|---|---|"
  context
}

if (( PRINT )) || ! ui_is_interactive; then body; exit 0; fi

# The parent owns cleanup: ui.sh installs its own EXIT/signal traps while prompting.
# Keep those inside a subshell so an interrupted prompt cannot discard this trap.
FEEDBACK_TMP=""
FEEDBACK_CHILD=""
# shellcheck disable=SC2329  # Invoked by the EXIT trap, including signal exits.
feedback_cleanup() {
  if [[ -n "$FEEDBACK_CHILD" ]]; then
    kill -TERM "$FEEDBACK_CHILD" 2>/dev/null || true
    wait "$FEEDBACK_CHILD" 2>/dev/null || true
  fi
  [[ -z "$FEEDBACK_TMP" ]] || rm -rf -- "$FEEDBACK_TMP"
}
trap feedback_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
FEEDBACK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/loomy-feedback.XXXXXX")"
BODY_FILE="$FEEDBACK_TMP/issue.md"
(
ui_clear
ui_banner "$(t "Feedback on Loomy")" "$(t "GitHub issue on %s · nothing is sent without your approval" "$REPO")"
if [[ -z "$MSG" ]]; then
  ui_print "${C_RAIL}│${C_RESET}"
  UI_LABEL="$(t "Feedback")"; UI_HINT="$(t "A bug, an annoyance, an idea: what happened, and what you expected.")"
  ui_input "$(t "Your feedback, in one or two sentences")" "" "$(t "E.g.: loomy watch doesn't see my Codex session")"
  MSG="$UI_VALUE"
  [[ -n "$MSG" ]] || { ui_end "$(t "nothing to send")"; exit 0; }
fi
TITLE="$(t "Feedback:") $(printf '%s' "$MSG" | cut -c1-70)"
body >"$BODY_FILE"
ui_section "$(t "PREVIEW")" "$(t "issue text")"
while IFS= read -r l; do ui_rail "${C_DIM}${l}${C_RESET}"; done <"$BODY_FILE"
ui_print "${C_RAIL}│${C_RESET}"
opts=(); UI_DESCS=(); codes=()
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  opts+=("$(t "Create the issue now")"); codes+=(create); UI_DESCS+=("$(t "gh issue create on %s, with this title and text." "$REPO")")
  opts+=("$(t "Open it in the browser")"); codes+=(web); UI_DESCS+=("$(t "Prefilled GitHub form: you review and submit it yourself.")")
fi
opts+=("$(t "Copy the text")"); codes+=(copy); UI_DESCS+=("$(t "To the clipboard, to paste wherever you want.")")
opts+=("$(t "Cancel")"); codes+=(cancel); UI_DESCS+=("$(t "Nothing is sent.")")
UI_LABEL="$(t "Sending")"
ui_choose "$(t "What to do with this feedback?")" 0 "${opts[@]}"
case "${codes[$UI_INDEX]}" in
  create)
    lbl=(); gh label list -R "$REPO" --limit 100 2>/dev/null | cut -f1 | grep -qx feedback && lbl=(--label feedback)
    if url="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" ${lbl[@]+"${lbl[@]}"} 2>&1)"; then ui_ok "$(t "Issue created")" "$url"
    else ui_warn "$(t "Issue not created")" "$(printf '%s' "$url" | tail -1)"; fi ;;
  web) gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --web >/dev/null 2>&1 && ui_ok "$(t "Form opened in the browser")" ;;
  copy) if ui_copy "$(cat "$BODY_FILE")"; then ui_ok "$(t "Text copied")" "$(t "title: %s" "$TITLE")"; else ui_warn "$(t "Clipboard unavailable")" "loomy feedback --print"; fi ;;
  *) ui_end "$(t "nothing was sent")"; rm -f "$BODY_FILE"; exit 0 ;;
esac
rm -f "$BODY_FILE"
ui_end "$(t "thanks! feedback tracking: %s" "https://github.com/$REPO/issues")"
) <&0 &
FEEDBACK_CHILD=$!
feedback_status=0
wait "$FEEDBACK_CHILD" || feedback_status=$?
FEEDBACK_CHILD=""
exit "$feedback_status"

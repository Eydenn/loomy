#!/usr/bin/env bash
# Project-local content policy. Bash 3.2; interactive transactions live in Perl so
# prompts use a separate screen lock; the policy lock protects only the commit.
# shellcheck source=i18n.sh
declare -F t >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
LOOMY_CONTENT_POLICY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/content-policy.pl"

# These markers supplement the backend's provider/managed checks. In particular a
# hook's local HOOK variable need not have been exported by its caller.
loomy_content_human_tty() {
  [[ -t 0 && -t 1 && -z "${HOOK:-}${LOOMY_HOOK:-}" ]] || return 1
  perl -e 'require $ARGV[0]; exit(Loomy::ContentPolicy::human_tty() ? 0 : 1)' "$LOOMY_CONTENT_POLICY_LIB"
}

_loomy_content_ui() {
  tv LOOMY_CONTENT_UI_TITLE "Task labels & private results — project %s"
  tv LOOMY_CONTENT_UI_CLARITY "Keep today's task clarity with bounded local labels; prompts stay out of the journal."
  tv LOOMY_CONTENT_UI_CLARITY_LEGACY "Keep today's task clarity with bounded local labels; the existing excerpt grant is separate."
  tv LOOMY_CONTENT_UI_SOURCES "Recommended labels: explicit-user, explicit-lead, claude-description,"
  tv LOOMY_CONTENT_UI_SOURCES_CODEX "                    codex-path-slug, codex-nickname, codex-role"
  tv LOOMY_CONTENT_UI_LABEL_CAPS "Caps: 96 graphemes / 384 UTF-8 bytes; Codex 40 ASCII each; label store 1 MiB."
  tv LOOMY_CONTENT_UI_LOWER_LABEL_CAPS "Selected limits: %s graphemes / %s UTF-8 bytes; Codex %s ASCII each; label store %s bytes."
  tv LOOMY_CONTENT_UI_KEEP_LABELS "Keep task labels? [Y/n]"
  tv LOOMY_CONTENT_UI_RESULT_CAPS "Private results save full tasks/results locally: 200 records, 1 MiB each,"
  tv LOOMY_CONTENT_UI_RESULT_RETENTION "16 MiB total, 30 days; active/paused records pinned; capture fails if full."
  tv LOOMY_CONTENT_UI_LOWER_RESULT_CAPS "Selected result limits: %s records / %s bytes each / %s bytes total / %s days."
  tv LOOMY_CONTENT_UI_HUMAN_REQUIRED "Human confirmation required: run this command directly in your terminal."
  tv LOOMY_CONTENT_UI_AGENT_ANCESTOR "Agent ancestor detected: %s. Run this command from a plain terminal."
  tv LOOMY_CONTENT_UI_CONFIRMATION_ABORTED "Content confirmation declined or aborted; no new grant saved."
  tv LOOMY_CONTENT_UI_OPERATION_FAILED "Content operation failed."
  tv LOOMY_CONTENT_UI_KEEP_RESULTS "Also save private tasks/results? [Y/n]"
  tv LOOMY_CONTENT_UI_EXCLUDED "Labels/results are excluded from sync/export; journal stays structural."
  tv LOOMY_CONTENT_UI_EXCLUDED_LEGACY "Labels/results are excluded from sync/export; the existing project excerpt grant is unchanged."
  tv LOOMY_CONTENT_UI_CONFIRM "Allow these exact fields and limits for this project? [y/N]"
  tv LOOMY_CONTENT_UI_HINT "Task labels off · run loomy privacy labels recommended"
  tv LOOMY_CONTENT_UI_LABEL_FULL "display context full; label not saved"
  tv LOOMY_CONTENT_UI_PRIVACY "Journal: %s · task labels: %s · private results: %s · checkpoint/scratch repair pending"
  tv LOOMY_CONTENT_UI_OLD_COPIES "Old copies may contain text · loomy privacy inventory"
  tv LOOMY_CONTENT_UI_RESULT_FACTS "Existing results are unchanged; this command changes future capture only."
  tv LOOMY_CONTENT_UI_ACK_DONE "First-use choices: completed for this project"
  tv LOOMY_CONTENT_UI_ACK_PENDING "First-use choices: pending human confirmation"
  tv LOOMY_CONTENT_UI_STRUCTURE "structure only"
  tv LOOMY_CONTENT_UI_LEGACY "legacy excerpts (project scope)"
  tv LOOMY_CONTENT_UI_ON "on"; tv LOOMY_CONTENT_UI_OFF "off"
  tv LOOMY_CONTENT_UI_SELECTED_SOURCES "Selected label sources: %s"
  tv LOOMY_CONTENT_UI_POLICY_STATE "Policy source: %s · scope: project · generation: %s"
  tv LOOMY_CONTENT_UI_DEFAULT_SOURCE "project defaults"
  tv LOOMY_CONTENT_UI_PROJECT_SOURCE "project policy file"
  tv LOOMY_CONTENT_UI_ENV_SOURCE "project-bound environment"
  tv LOOMY_CONTENT_UI_DENIED_SOURCE "environment request refused"
  tv LOOMY_CONTENT_UI_VETO_SOURCE "LOOMY_JOURNAL_TASKS=0 restriction"
  tv LOOMY_CONTENT_UI_INVALID_POLICY "Invalid content policy: %s. Fix or remove this file before changing the policy."
  tv LOOMY_CONTENT_UI_TASKS_VETO "Task labels disabled by LOOMY_JOURNAL_TASKS=0; project grants are unchanged."
  tv LOOMY_CONTENT_UI_POLICY_CHANGED "Content policy changed while awaiting confirmation; run the command again."
  export LOOMY_CONTENT_UI_TITLE LOOMY_CONTENT_UI_CLARITY LOOMY_CONTENT_UI_SOURCES LOOMY_CONTENT_UI_SOURCES_CODEX
  export LOOMY_CONTENT_UI_LABEL_CAPS LOOMY_CONTENT_UI_KEEP_LABELS LOOMY_CONTENT_UI_RESULT_CAPS LOOMY_CONTENT_UI_RESULT_RETENTION
  export LOOMY_CONTENT_UI_KEEP_RESULTS LOOMY_CONTENT_UI_EXCLUDED LOOMY_CONTENT_UI_CONFIRM LOOMY_CONTENT_UI_HINT LOOMY_CONTENT_UI_LABEL_FULL
  export LOOMY_CONTENT_UI_PRIVACY LOOMY_CONTENT_UI_OLD_COPIES LOOMY_CONTENT_UI_RESULT_FACTS LOOMY_CONTENT_UI_ACK_DONE LOOMY_CONTENT_UI_ACK_PENDING
  export LOOMY_CONTENT_UI_STRUCTURE LOOMY_CONTENT_UI_LEGACY LOOMY_CONTENT_UI_ON LOOMY_CONTENT_UI_OFF
  export LOOMY_CONTENT_UI_LOWER_LABEL_CAPS LOOMY_CONTENT_UI_LOWER_RESULT_CAPS
  export LOOMY_CONTENT_UI_HUMAN_REQUIRED LOOMY_CONTENT_UI_CONFIRMATION_ABORTED LOOMY_CONTENT_UI_OPERATION_FAILED
  export LOOMY_CONTENT_UI_AGENT_ANCESTOR
  export LOOMY_CONTENT_UI_CLARITY_LEGACY LOOMY_CONTENT_UI_EXCLUDED_LEGACY
  export LOOMY_CONTENT_UI_SELECTED_SOURCES LOOMY_CONTENT_UI_POLICY_STATE LOOMY_CONTENT_UI_DEFAULT_SOURCE
  export LOOMY_CONTENT_UI_PROJECT_SOURCE LOOMY_CONTENT_UI_ENV_SOURCE LOOMY_CONTENT_UI_DENIED_SOURCE LOOMY_CONTENT_UI_VETO_SOURCE
  export LOOMY_CONTENT_UI_INVALID_POLICY LOOMY_CONTENT_UI_TASKS_VETO LOOMY_CONTENT_UI_POLICY_CHANGED
}

# No caller-supplied confirmation token: the backend rechecks origin and reads
# stdin itself. Restrictive commands remain available without a terminal.
loomy_content_command() (
  [[ -z "${HOOK:-}" ]] || export LOOMY_HOOK_CONTEXT=1
  _loomy_content_ui
  perl "$LOOMY_CONTENT_POLICY_LIB" "$@"
)
loomy_content_first_use() {
  # A completed screen must not start Perl or load its translations again.
  [[ -t 0 && -t 1 ]] || return 0
  local row
  if [[ -f "$1/.loomy/logs/content-policy.conf" && ! -L "$1/.loomy/logs/content-policy.conf" && -r "$1/.loomy/logs/content-policy.conf" ]]; then
    while IFS= read -r row || [[ -n "$row" ]]; do [[ "$row" != grant_prompt_version=1 ]] || return 0; done <"$1/.loomy/logs/content-policy.conf"
  fi
  loomy_content_human_tty || return 0
  loomy_content_command first-use "$1" || return 0
}
_loomy_content_hint_load() {
  local flags="hint" flag row grant_prompt=0 label_granted=0 fast_empty=0
  # The common missing/default case needs no interpreter; only existing state
  # needs the closed backend parser. Load each translation only if displayed.
  LOOMY_CONTENT_HINT_SIGNATURE='-|-'
  if [[ -f "$1/.loomy/logs/content-policy.conf" && ! -L "$1/.loomy/logs/content-policy.conf" \
      && -r "$1/.loomy/logs/content-policy.conf" && ! -e "$1/.loomy/logs/display-context-full" \
      && ! -L "$1/.loomy/logs/display-context-full" ]]; then
    while IFS= read -r row || [[ -n "$row" ]]; do
      [[ "$row" != grant_prompt_version=1 ]] || grant_prompt=1
      case "$row" in
        label_sources=*) [[ "${row#label_sources=}" == none || -z "${row#label_sources=}" ]] || label_granted=1 ;;
      esac
    done <"$1/.loomy/logs/content-policy.conf"
    if (( grant_prompt && label_granted )); then
      fast_empty=1; flags=""
      [[ -z "${2:-}" ]] || LOOMY_CONTENT_HINT_SIGNATURE="$2"
    fi
  fi
  if (( ! fast_empty )) && [[ -e "$1/.loomy/logs/content-policy.conf" || -L "$1/.loomy/logs/content-policy.conf" || -e "$1/.loomy/logs/display-context-full" || -L "$1/.loomy/logs/display-context-full" ]]; then
    flags="$(perl -e 'require $ARGV[0];
      print "C|",join("|",map {(Time::HiRes::stat("$ARGV[1]/.loomy/logs/$_"))[9] // "-"}
        qw(content-policy.conf display-context-full)),"\n";
      my $p=Loomy::ContentPolicy::effective_policy($ARGV[1]);
      print "full\n" if Loomy::ContentPolicy::label_health($ARGV[1]) eq "full";
      print "hint\n" if !$p->{grant_prompt_version} || $p->{label_sources} eq "none"' "$LOOMY_CONTENT_POLICY_LIB" "$1")" || return 0
  fi
  LOOMY_CONTENT_HINT=""
  for flag in $flags; do
    case "$flag" in
      C\|*) LOOMY_CONTENT_HINT_SIGNATURE="${flag#C|}" ;;
      full) tv flag "display context full; label not saved" ;;
      hint) tv flag "Task labels off · run loomy privacy labels recommended" ;;
    esac
    [[ "$flag" != C\|* ]] || continue
    LOOMY_CONTENT_HINT="${LOOMY_CONTENT_HINT:+$LOOMY_CONTENT_HINT$'\n'}$flag"
  done
  # shellcheck disable=SC2034  # consumed by the watch footer
  LOOMY_CONTENT_HINT_LINE="${LOOMY_CONTENT_HINT//$'\n'/ · }"
}
loomy_content_status_hint() {
  _loomy_content_hint_load "$1"
  [[ -z "$LOOMY_CONTENT_HINT" ]] || printf '%s\n' "$LOOMY_CONTENT_HINT"
}

# The existing sampler supplies mtimes (including subsecond changes). An idle
# notification only compares strings; no stat, shell, interpreter or i18n call.
loomy_content_hint_refresh() {
  [[ "$2" != "${LOOMY_CONTENT_HINT_SIGNATURE:-}" ]] || return 0
  _loomy_content_hint_load "$1" "$2"
}
loomy_content_policy() { loomy_content_command show "$1"; }

# Read-only machine API: no UI initialization, identity creation or grant prompt.
# Exporters use the explicitly structural export snapshot with project_with_policy.
loomy_content_policy_snapshot() {
  perl -e 'require $ARGV[0]; print JSON::PP->new->utf8->canonical->encode(Loomy::ContentPolicy::policy_snapshot($ARGV[1])),"\n"' "$LOOMY_CONTENT_POLICY_LIB" "$1"
}
loomy_content_export_policy_snapshot() {
  perl -e 'require $ARGV[0]; print JSON::PP->new->utf8->canonical->encode(Loomy::ContentPolicy::export_policy_snapshot($ARGV[1],$ARGV[2])),"\n"' "$LOOMY_CONTENT_POLICY_LIB" "$1" "${2:-structural}"
}

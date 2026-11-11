#!/usr/bin/env bash
# Scoped hook registration: no project upkeep, content grant or provider call.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/i18n.sh
source "$SCRIPT_DIR/lib/i18n.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/hooks.sh
source "$SCRIPT_DIR/lib/hooks.sh"

hooks_help() {
  t "Usage: loomy hooks [status | repair [--shell]] [--root DIR]"; echo
  t "status is read-only; repair fills missing bindings and keeps recognized active bindings and custom settings."; echo
  t "repair --shell restores recognized shell bindings without changing other project files."; echo
  t "Native hook registration is not available in this release."; echo
}

ACTION=status; ROOT=""; SHELL_TARGET=0; ACTION_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ -n "${2:-}" ]] || { t "--root requires a directory" >&2; echo >&2; exit 2; }
      ROOT="$2"; shift ;;
    status|repair)
      if (( ACTION_SET )); then hooks_help >&2; exit 2; fi
      ACTION="$1"; ACTION_SET=1 ;;
    --shell) SHELL_TARGET=1 ;;
    --native|native)
      t "Native hook registration is not available in this release." >&2; echo >&2; exit 2 ;;
    -h|--help) hooks_help; exit 0 ;;
    *) hooks_help >&2; exit 2 ;;
  esac
  shift
done
if (( SHELL_TARGET )) && [[ "$ACTION" != repair ]]; then hooks_help >&2; exit 2; fi
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"

# Only catalog event names, bounded counters and fixed codes cross into shell.
# Even a helper failure must never turn an error payload into interface text.
hooks_rows() {
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($helper,$provider)=@ARGV; require $helper;
    local $/; my $r=decode_json(<STDIN>);
    die "invalid hook result\n" unless ref($r) eq "HASH";
    my %states=map {$_=>1} qw(shell native mixed custom missing invalid ambiguous unavailable);
    my %codes=map {$_=>1} qw(updated unchanged missing invalid_settings unsafe_project unsafe_parent
      unsafe_settings busy conflict parent_changed applied_unconfirmed unsupported_number gid_preservation_failed);
    my $num=sub {defined($_[0]) && !ref($_[0]) && $_[0]=~/\A[0-9]{1,9}\z/ ? 0+$_[0] : 0};
    my $state=sub {defined($_[0]) && !ref($_[0]) && $states{$_[0]} ? $_[0] : "unavailable"};
    my $ok=$num->($r->{ok})==1 ? 1 : 0;
    my $code=defined($r->{code}) && !ref($r->{code}) && $codes{$r->{code}} ? $r->{code} : "operation_failed";
    my $f=ref($r->{facts}) eq "HASH" ? $r->{facts} : {};
    my $fallback=$code eq "invalid_settings" ? "invalid" : "unavailable";
    my %slots=map {ref($_) eq "HASH" && defined($_->{event}) && !ref($_->{event}) ? ($_->{event}=>$_) : ()}
      @{ref($f->{slots}) eq "ARRAY" ? $f->{slots} : []};
    my @events=map {$_->{event}} @{Loomy::Hooks::catalog($provider)};
    push @events,"statusLine" if $provider eq "claude";
    print join("\t","file",$ok,$code,$ok ? $state->($f->{state}) : $fallback,
      $num->($f->{ready}),$num->($r->{changed}),$num->($f->{unknown_event_count})),"\n";
    for my $event (@events) {
      my $slot=$event eq "statusLine" ? $f->{status_line} : $slots{$event};
      $slot={} unless ref($slot) eq "HASH";
      print join("\t","slot",$event,$ok ? $state->($slot->{state}) : $fallback,
        $num->($slot->{owned}),$num->($slot->{custom}),$num->($slot->{ambiguous})),"\n";
    }
  ' "$SCRIPT_DIR/lib/hooks.pl" "$1" 2>/dev/null
}

hooks_state() {
  case "$1" in
    shell) t "shell" ;; native) t "native" ;; mixed) t "mixed" ;;
    custom) t "custom" ;; missing) t "missing" ;; invalid) t "invalid" ;;
    ambiguous) t "ambiguous" ;; *) t "unavailable" ;;
  esac
}

hooks_error() {
  case "$1" in
    invalid_settings) t "Invalid hook settings; correct the JSON structure, then retry." ;;
    unsafe_project) t "Project directory could not be verified; check ownership and permissions, then retry." ;;
    unsafe_parent) t "Hook settings directory could not be verified; check its type, ownership and permissions, then retry." ;;
    unsafe_settings) t "Hook settings file could not be verified; use a regular file owned by you, then retry." ;;
    busy) t "Another process holds the hook settings lock; retry after it finishes." ;;
    conflict|parent_changed) t "Hook settings changed during inspection or repair; run loomy hooks status, then retry." ;;
    applied_unconfirmed) t "Hook settings were applied, but their placement or durability could not be confirmed; run loomy hooks status before retrying." ;;
    unsupported_number) t "Hook settings contain a number that cannot be preserved exactly; correct it, then retry." ;;
    gid_preservation_failed) t "Hook settings could not retain their group; check directory permissions, then retry." ;;
    *) t "Hook settings operation failed; run loomy hooks status, then retry." ;;
  esac
}

FAILED=0; CUSTOM=0; AMBIGUOUS=0
for PROVIDER in claude codex; do
  if [[ "$PROVIDER" == claude ]]; then LABEL="$(t "Claude Code hooks")"; FILE=.claude/settings.json
  else LABEL="$(t "Codex hooks")"; FILE=.codex/hooks.json; fi
  RESULT=""; ENGINE_RC=0
  if [[ "$ACTION" == status ]]; then
    RESULT="$(loomy_hooks_inspect "$ROOT" "$PROVIDER" 2>/dev/null)" || ENGINE_RC=$?
  elif (( SHELL_TARGET )); then
    RESULT="$(loomy_hooks_repair "$ROOT" "$PROVIDER" --shell 2>/dev/null)" || ENGINE_RC=$?
  else
    RESULT="$(loomy_hooks_repair "$ROOT" "$PROVIDER" 2>/dev/null)" || ENGINE_RC=$?
  fi
  if ! ROWS="$(printf '%s' "$RESULT" | hooks_rows "$PROVIDER")"; then
    FAILED=1
    printf '%s (%s): %s\n  %s\n' "$LABEL" "$FILE" "$(t "failed")" "$(hooks_error operation_failed)"
    continue
  fi
  FILE_OK=0
  while IFS=$'\t' read -r KIND A B C D E F; do
    if [[ "$KIND" == file ]]; then
      FILE_OK="$A"
      if (( ! FILE_OK || ENGINE_RC )); then
        FAILED=1; FILE_OK=0
        printf '%s (%s): %s\n  %s\n' "$LABEL" "$FILE" "$(t "failed")" "$(hooks_error "$B")"
      elif [[ "$ACTION" == repair ]]; then
        if (( E )); then CHANGE="$(t "changed")"; else CHANGE="$(t "unchanged")"; fi
        printf '%s (%s): %s; %s\n' "$LABEL" "$FILE" "$CHANGE" "$(hooks_state "$C")"
        (( D )) || FAILED=1
      else
        printf '%s (%s): %s\n' "$LABEL" "$FILE" "$(hooks_state "$C")"
      fi
      if (( F )); then
        CUSTOM=1
        printf '  %s\n' "$(t "Other events: custom settings kept.")"
      fi
      continue
    fi
    [[ "$KIND" == slot ]] || continue
    if (( ! FILE_OK )); then NEXT="$(t "inspect this file before retrying")"
    elif (( E )); then NEXT="$(t "review this event before switching versions")"; AMBIGUOUS=1
    elif [[ "$A" == statusLine && "$B" == custom ]]; then NEXT="$(t "custom settings kept")"
    elif (( ! C )); then NEXT="$(t "run loomy hooks repair")"
    else NEXT="$(t "no action required")"; fi
    if (( D )); then
      CUSTOM=1
      if [[ "$A" != statusLine || "$B" != custom ]]; then NEXT="$NEXT; $(t "custom settings kept")"; fi
    fi
    printf '  %s: %s — %s\n' "$A" "$(hooks_state "$B")" "$NEXT"
  done <<<"$ROWS"
done

if (( AMBIGUOUS )); then t "Loomy hooks: conflicting registrations; review the listed events before switching."; echo; fi
if [[ "$ACTION" == repair ]]; then
  if (( FAILED )); then t "Loomy hooks: repair incomplete; run loomy hooks status."; echo
  elif (( SHELL_TARGET )); then t "Loomy hooks: shell registration restored."; echo
  else t "Loomy hooks: registration checked."; echo; fi
  if (( CUSTOM )); then t "Loomy hooks: custom settings kept."; echo; fi
fi
t "Native hook registration is not available in this release."; echo
exit "$FAILED"

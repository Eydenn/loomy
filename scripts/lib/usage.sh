#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Subscription quotas and usage display for Loomy. To be sourced. Bash 3.2 compatible.
#
# With a subscription (plan other than "api" in loomy config), a dollar cost means little: Loomy shows the share of the
# plan's quota in use instead, and tokens for each piece of work. With the API, the real cost stays.
#
# Where the quotas come from (no network, no credentials read):
#   Codex   the "rate_limits" events Codex writes into its own session logs (${CODEX_HOME:-~/.codex}/sessions)
#   Claude  the documented "rate_limits" field Claude Code gives the status line command; Loomy's status line
#           (scripts/loomy-statusline.sh) saves it to ${XDG_CONFIG_HOME:-~/.config}/loomy/claude-limits
if ! declare -F t >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"; fi
if ! declare -F loomy_plan >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/config.sh"; fi

# loomy_on_plan <claude|codex>: true when that tool is used through a subscription.
loomy_on_plan() { [[ "$(loomy_plan "$1")" != "api" ]]; }

ai_claude_limits_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/claude-limits"; }

# ai_quota <claude|codex>: one line per quota window still running: "<window_minutes> <used_percent> <resets_at epoch>",
# then possibly "reached <reason>" when the tool reports the limit as reached. Nothing when no reading exists yet.
ai_quota() {
  local now; now="$(date +%s)"
  case "$1" in
    claude)
      local f; f="$(ai_claude_limits_file)"
      [[ -f "$f" ]] || return 0
      awk -F= -v now="$now" '
        /^(five_hour|seven_day)_pct=/ { split($1, a, "_pct"); pct[a[1]] = $2 }
        /^(five_hour|seven_day)_reset=/ { split($1, a, "_reset"); rst[a[1]] = $2 }
        END { if (("five_hour" in pct) && rst["five_hour"] > now) print 300, pct["five_hour"], rst["five_hour"]
              if (("seven_day" in pct) && rst["seven_day"] > now) print 10080, pct["seven_day"], rst["seven_day"] }' "$f"
      ;;
    codex)
      local dir="${CODEX_HOME:-$HOME/.codex}/sessions" f mt cache line
      [[ -d "$dir" ]] || return 0
      # Most recent session log; its last reading is the freshest.
      f="$(find "$dir" -name '*.jsonl' -type f -mtime -14 2>/dev/null | while IFS= read -r p; do printf '%s\t%s\n' "$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null)" "$p"; done | sort -rn | head -1)"
      [[ -n "$f" ]] || return 0
      mt="${f%%$'\t'*}"; f="${f#*$'\t'}"
      # Modification time to the second is not enough (a log can grow twice within a second): the size is in the key.
      mt="$mt $(wc -c <"$f" | tr -d ' ')"
      # Cache: the reading only changes when that log changes (loomy watch asks every few seconds).
      cache="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/codex-limits"
      if [[ "$(head -1 "$cache" 2>/dev/null)" == "$mt $f" ]]; then line="$(sed -n '2p' "$cache")"
      else
        # Only the end of the log: readings are frequent, logs can be large.
        line="$(tail -c 400000 "$f" 2>/dev/null | grep -o '"rate_limits":{[^{}]*\({[^{}]*}[^{}]*\)*}' | tail -1 || true)"
        if [[ "${AI_QUOTA_READ_ONLY:-0}" != 1 ]]; then
          mkdir -p "${cache%/*}" 2>/dev/null && printf '%s\n%s\n' "$mt $f" "$line" >"$cache" 2>/dev/null || true
        fi
      fi
      [[ -n "$line" ]] || return 0
      printf '%s\n' "$line" | awk -v now="$now" -v fresh="${mt%% *}" '
        function win(name,   s, w, p, r) {
          if (!match($0, "\"" name "\":\\{[^}]*\\}")) return
          s = substr($0, RSTART, RLENGTH)
          w = s; sub(/.*"window_minutes":/, "", w); sub(/[,}].*/, "", w)
          p = s; sub(/.*"used_percent":/, "", p); sub(/[,}].*/, "", p)
          r = s; sub(/.*"resets_at":/, "", r); sub(/[,}].*/, "", r)
          rst[name] = r + 0; if (r + 0 > 0) known_reset = 1
          if (r + 0 > now) active = 1
          if (r + 0 > now) printf "%d %d %d\n", w, p + 0, r }
        { win("primary"); win("secondary")
          if (match($0, /"rate_limit_reached_type":"[a-z_]+"/)) {
            reason=substr($0, RSTART + 27, RLENGTH - 28)
            if (rst[reason] > now || (reason != "primary" && reason != "secondary" && active) || (!known_reset && now-fresh < 300)) print "reached", reason } }'
      ;;
  esac
}

# _ai_window_label <minutes>: "5 h", "week", "N h" or "N d".
_ai_window_label() {
  case "$1" in
    300) t "5 h" ;; 10080) t "week" ;; 1440) t "day" ;;
    *) if (( $1 % 1440 == 0 )); then printf '%s d' "$(( $1 / 1440 ))"; else printf '%s h' "$(( $1 / 60 ))"; fi ;;
  esac
}

# _ai_reset_label <epoch>: local time today, otherwise weekday and time.
_ai_reset_label() {
  local now; now="$(date +%s)"
  local hm dow
  hm="$(date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M)"
  if (( $1 - now < 86400 )); then printf '%s' "$hm"; return 0; fi
  # Weekday through the dictionary (the system locale may not match the interface language).
  dow="$(date -r "$1" +%u 2>/dev/null || date -d "@$1" +%u)"
  case "$dow" in 1) t "Mon" ;; 2) t "Tue" ;; 3) t "Wed" ;; 4) t "Thu" ;; 5) t "Fri" ;; 6) t "Sat" ;; *) t "Sun" ;; esac
  printf ' %s' "$hm"
}

# ai_quota_line <claude|codex>: "5 h 42 % (resets 14:30) · week 18 % (resets Mon 09:00)", coloured from 80 % on;
# empty when there is no reading yet.
ai_quota_line() {
  local out="" w p r c
  while read -r w p r; do
    [[ -n "$w" ]] || continue
    if [[ "$w" == "reached" ]]; then out="${out:+$out · }${C_RED}$(t "limit reached (%s)" "$p")${C_RESET}"; continue; fi
    c=""; (( p >= 80 )) && c="$C_YELLOW"; (( p >= 95 )) && c="$C_RED"
    out="${out:+$out · }$(_ai_window_label "$w") ${c}${C_BOLD}${p} %${C_RESET} ${C_DIM}($(t "resets %s" "$(_ai_reset_label "$r")"))${C_RESET}"
  done < <(ai_quota "$1")
  printf '%s' "$out"
}

# ai_quota_max <claude|codex>: highest share in use across the running windows (empty without a reading).
ai_quota_max() { ai_quota "$1" | awk '$1 != "reached" { if ($2 > m) m = $2; seen = 1 } END { if (seen) print m + 0 }'; }

# ai_tokens_label <n>: 950, 12.3k, 4.1M.
ai_tokens_label() { awk -v n="${1:-0}" 'BEGIN { if (n >= 1e6) printf "%.1fM", n / 1e6; else if (n >= 1e3) printf "%.1fk", n / 1e3; else printf "%d", n }'; }

# ai_quota_hint <claude|codex>: why there is no reading yet.
ai_quota_hint() {
  case "$1" in
    claude) t "quota shown once a Claude Code session has answered in a Loomy project (status line)" ;;
    codex) t "quota shown once a Codex session has run on this machine" ;;
  esac
}

# ---------------------------------------------------------------- quota failover
# Close to the end of a subscription quota, work moves to the other tool when it is installed and has room left.
# Threshold: loomy config set quota_switch <percent> (95 by default), or "off" to never switch.

# ai_switch_threshold: the percentage from which a quota counts as nearly exhausted (empty when switching is off).
ai_switch_threshold() {
  local v; v="$(loomy_config_get quota_switch 2>/dev/null || true)"
  [[ "$v" == "off" ]] && return 0
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 100 )) || v=95
  echo "$v"
}

# Proactive lead relay keeps its configured threshold; it is not evidence for pausing a bridge.
ai_quota_saturated() {
  ai_provider_refused "$1" && return 0
  local th q; th="$(ai_switch_threshold)"
  [[ -n "$th" ]] || return 1
  loomy_on_plan "$1" || return 1
  q="$(ai_quota "$1")"; [[ -n "$q" ]] || return 1
  printf '%s\n' "$q" | awk -v th="$th" '$1 == "reached" || $2 + 0 >= th {hit=1} END {exit !hit}'
}

# Delegations may still serve at 95-99 percent: pause only on a refusal or exhausted quota.
ai_provider_saturated() {
  ai_provider_refused "$1" && return 0
  loomy_on_plan "$1" || return 1
  ai_quota "$1" | awk '$1 == "reached" || $2 + 0 >= 100 {hit=1} END {exit !hit}'
}

# ai_switch_family <claude|codex>: the tool to use instead when this one is saturated (installed, not saturated
# itself); empty otherwise.
ai_switch_family() {
  local other="codex" check=ai_quota_saturated; [[ "${2:-}" != strict ]] || check=ai_provider_saturated
  [[ "$1" == "codex" ]] && other="claude"
  "$check" "$1" || return 0
  if [[ "$other" == "claude" ]]; then ai_has_claude || return 0; else ai_has_codex || return 0; fi
  "$check" "$other" && return 0
  echo "$other"
}

# ai_quota_state <claude|codex>: "limit reached" or "N %" for messages.
ai_quota_state() {
  local q; q="$(ai_quota "$1")"
  if grep -q '^reached' <<<"$q"; then t "limit reached"; else printf '%s %%' "$(ai_quota_max "$1")"; fi
}

# Provider refusals outlive a bridge process; an absent reset means a five-minute estimated recheck.
ai_provider_state_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/$1-availability"; }
ai_provider_reset() {
  local now reset f
  now="$(date +%s)"; f="$(ai_provider_state_file "$1")"
  reset="$(ai_quota "$1" | awk '$1 != "reached" && $2 >= 100 && $3 > r {r=$3} END {if (r) print r}')"
  if [[ -f "$f" ]]; then
    local saved; saved="$(sed -n 's/^resume_at=\([0-9]*\)$/\1/p' "$f")"
    if [[ "$saved" =~ ^[0-9]+$ ]] && (( saved > now && saved > ${reset:-0} )); then reset="$saved"; fi
  fi
  echo "${reset:-$(( now + 300 ))}"
}
ai_provider_refusal() {
  local f reset parsed now tmp
  f="$(ai_provider_state_file "$1")"; now="$(date +%s)"; reset="$(ai_provider_reset "$1")"
  # Prefer a known reset over an estimate, but never shorten an existing refusal.
  parsed="$(printf '%s' "$2" | perl -MTime::Local -e '
    my $now=shift; local $/; my $s=<STDIN>; my $epoch;
    if ($s =~ /(?:resets_at|reset_at|resume_at)["\s:=]+([0-9]{10})/i || $s =~ /\|([0-9]{10})(?:\D|$)/) { $epoch=$1 }
    elsif ($s =~ /(?:retry_after|retry-after|resets_in_seconds)["\s:=]+([0-9]+)/i) { $epoch=$now+$1 }
    elsif ($s =~ /resets?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b/i) {
      my ($h,$m,$ap)=($1,$2//0,lc $3); my @t=localtime($now);
      if ($h>=1 && $h<=12 && $m<60) { $h=$h%12+($ap eq "pm" ? 12 : 0); $epoch=eval {timelocal(0,$m,$h,$t[3],$t[4],$t[5])}; $epoch+=86400 if defined($epoch) && $epoch<=$now }
    } elsif ($s =~ /resets?\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\b/i) {
      my ($mon,$day)=(lc $1,$2); my %mon=map { (qw(jan feb mar apr may jun jul aug sep oct nov dec))[$_]=>$_ } 0..11;
      my @t=localtime($now); $epoch=eval {timelocal(0,0,0,$day,$mon{$mon},$t[5])};
      $epoch=eval {timelocal(0,0,0,$day,$mon{$mon},$t[5]+1)} if defined($epoch) && $epoch<=$now;
    }
    print $epoch if defined($epoch) && $epoch>$now;
  ' "$now")"
  if [[ "$parsed" =~ ^[0-9]+$ ]]; then
    reset="$parsed"
    local known saved
    known="$(ai_quota "$1" | awk '$1 != "reached" && $2 >= 100 && $3 > r {r=$3} END {if (r) print r}')"
    saved="$(sed -n 's/^resume_at=\([0-9]*\)$/\1/p' "$f" 2>/dev/null || true)"
    [[ ! "$known" =~ ^[0-9]+$ ]] || { (( known <= reset )) || reset="$known"; }
    [[ ! "$saved" =~ ^[0-9]+$ ]] || { (( saved <= reset )) || reset="$saved"; }
  fi
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  tmp="$(mktemp "$f.XXXXXX")" || return 0
  printf 'reason=provider refusal (quota, credits or rate limit)\nresume_at=%s\n' "$reset" >"$tmp"
  mv "$tmp" "$f"
}
ai_provider_refused() {
  local f reset; f="$(ai_provider_state_file "$1")"
  [[ -f "$f" ]] || return 1
  reset="$(sed -n 's/^resume_at=\([0-9]*\)$/\1/p' "$f")"
  [[ "$reset" =~ ^[0-9]+$ ]] && (( reset > $(date +%s) ))
}
ai_provider_reason() {
  if ai_provider_refused "$1"; then t "provider refusal (quota, credits or rate limit)"
  else ai_quota_state "$1"; fi
}

# Fingerprint only dirty paths, including untracked files, without reading ignored private files.
ai_delegate_file_snapshot() {
  git -C "$ROOT" status --porcelain=v1 -z --untracked-files=all | perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    my $root=shift; local $/; my @entries=split /\0/,<STDIN>; my %files;
    while (@entries) {
      my $entry=shift @entries; my $status=substr($entry,0,2); my $path=substr($entry,3);
      shift @entries if $status =~ /[RC]/;
      my $hash="missing";
      if (-l "$root/$path") { $hash=sha256_hex(readlink "$root/$path") }
      elsif (-f "$root/$path" && open my $f,"<","$root/$path") { binmode $f; $hash=sha256_hex(<$f>//"") }
      $files{$path}="$status:$hash";
    }
    print encode_json(\%files);
  ' "$ROOT"
}
ai_delegate_changed_files() {
  CHANGED=0; CHANGED_FILES_JSON='[]'
  [[ "$SANDBOX" == "workspace-write" ]] || return 0
  [[ -f "$TMP/before-files.json" ]] || return 0
  ai_delegate_file_snapshot >"$TMP/after-files.json"
  CHANGED_FILES_JSON="$(perl -MJSON::PP -e '
    sub read_json { open my $f,"<",shift or die $!; local $/; return decode_json(<$f>) }
    my ($before,$after)=map {read_json($_)} @ARGV; my %paths=(%$before,%$after);
    my @changed=sort grep {($before->{$_}//"") ne ($after->{$_}//"")} keys %paths;
    print encode_json(\@changed);
  ' "$TMP/before-files.json" "$TMP/after-files.json")"
  CHANGED="$(printf '%s' "$CHANGED_FILES_JSON" | perl -MJSON::PP -0777 -ne 'print scalar @{decode_json($_)}')"
}

# Called after delegation_start: one cross-provider handover, or a final paused event.
# Uses the bridge's task/options and journal fields so signal cleanup cannot report an interruption afterwards.
ai_delegate_provider_guard() {
  local family="$1" reason="${2:-}" other="codex" can_switch=1 resume other_reset id duration model
  [[ "$family" != "codex" ]] || other=claude
  if [[ -z "$reason" ]]; then
    if ai_provider_saturated "$family"; then reason=saturated
    elif ! ai_model_usable "$MODEL" "$family"; then reason=model
    else return 0; fi
  fi
  [[ -z "${LOOMY_FAILOVER_FROM:-}" ]] || can_switch=0
  if [[ "$other" == "claude" ]]; then ai_has_claude || can_switch=0; else ai_has_codex || can_switch=0; fi
  ai_provider_saturated "$other" && can_switch=0
  model="$(ai_route "$ROLE" "$other" "$AI_PROFILE"; printf '%s' "$R_MODEL")"
  ai_model_usable "$model" "$other" || can_switch=0
  duration=$(( $(date +%s) - STARTED ))
  ai_delegate_changed_files
  if (( can_switch )); then
    t "Provider %s unavailable (%s): %s handed to %s once." "$family" "$reason" "$ROLE" "$other" >&2; echo >&2
    ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$DELEG_ID\",\"bridge\":\"$family\",\"family\":\"$family\",\"role\":\"$ROLE\",\"model\":\"$MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"$SANDBOX\",\"status\":\"handed_over\",\"outcome\":\"handed_over\",\"files_changed\":$CHANGED,\"changed_files\":$CHANGED_FILES_JSON,\"duration_s\":$duration$FAILOVER_JSON$WHY_JSON,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"
    FINAL_WRITTEN=1
    local fwd=()
    [[ -z "$O_EFFORT" ]] || fwd+=(--effort "$O_EFFORT")
    [[ "$SANDBOX" != "workspace-write" ]] || fwd+=(--write)
    [[ "$SANDBOX" != "read-only" ]] || fwd+=(--read-only)
    [[ -z "$O_WHY" ]] || fwd+=(--why "$O_WHY")
    # Replace the bridge after closing its event so the destination owns signal cleanup.
    rm -rf "$TMP"
    trap - EXIT INT TERM HUP
    LOOMY_REQUESTED_MODEL="${LOOMY_REQUESTED_MODEL:-$O_MODEL}" LOOMY_FAILOVER_FROM="$family" \
      exec bash "$SCRIPT_DIR/loomy-delegate-$other.sh" "$ROLE" ${fwd[@]+"${fwd[@]}"} "$TASK"
  fi
  resume="$(ai_provider_reset "$family")"
  [[ "$reason" != "model" ]] || resume=$(( $(date +%s) + 3600 ))
  if ai_provider_saturated "$other"; then
    other_reset="$(ai_provider_reset "$other")"
    (( other_reset >= resume )) || resume="$other_reset"
  fi
  id="$DELEG_ID"
  ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$id\",\"bridge\":\"$family\",\"family\":\"$family\",\"role\":\"$ROLE\",\"model\":\"$MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"$SANDBOX\",\"status\":\"paused\",\"outcome\":\"waiting_for_reset\",\"resume_at\":$resume,\"files_changed\":$CHANGED,\"changed_files\":$CHANGED_FILES_JSON,\"duration_s\":$duration$FAILOVER_JSON$WHY_JSON,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"
  FINAL_WRITTEN=1
  # A resumed handover starts a fresh attempt on its original bridge (including writer permissions).
  local relaunch resume_family="${LOOMY_FAILOVER_FROM:-$family}" resume_model="${LOOMY_REQUESTED_MODEL:-$O_MODEL}"
  printf -v relaunch '%q ' bash "$ROOT/.loomy/scripts/loomy-delegate-$resume_family.sh" "$ROLE"
  [[ -z "$resume_model" ]] || { printf -v id '%q ' --model "$resume_model"; relaunch="$relaunch$id"; }
  printf -v id '%q ' --effort "$EFFORT"; relaunch="$relaunch$id"
  [[ "$SANDBOX" != workspace-write ]] || relaunch="$relaunch--write "
  [[ "$SANDBOX" != read-only ]] || relaunch="$relaunch--read-only "
  [[ -z "$O_WHY" ]] || { printf -v id '%q ' --why "$O_WHY"; relaunch="$relaunch$id"; }
  printf -v id '%q' "$TASK"; relaunch="$relaunch$id"
  loomy_memory_save "$ROOT" "$DELEG_ID" "$ROLE" "$MODEL" paused "$TASK" "waiting_for_reset resume_at=$resume
Resume: $relaunch"
  t "PAUSED: provider %s unavailable (%s); no provider has room. Expected reset/recheck: %s (epoch %s)." "$family" "$reason" "$(_ai_reset_label "$resume")" "$resume" >&2; echo >&2
  exit 75
}

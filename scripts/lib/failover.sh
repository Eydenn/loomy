#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Temporary lead relay: when the lead tool's subscription quota runs out, the other tool leads until the first one has
# room again. The lead set in the brief (the "master") never changes; the relay is a state file. To be sourced.
# Bash 3.2 compatible; nothing here fails its caller.
#
# State: <root>/.loomy/failover, key=value lines: master, acting, since (ISO UTC), reason, resume_at (epoch, may be empty), manual (1 for a user-selected relay).
# Settings: loomy config lead_failover (auto|off), quota_switch (95: hand over), quota_room (80: master takes back below).
if ! declare -F t >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"; fi
if ! declare -F ai_quota >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/usage.sh"; fi
if ! declare -F ai_journal_write >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/journal.sh"; fi

lf_file() { echo "$1/.loomy/failover"; }

# lf_get <root> <key>
lf_get() { sed -n "s/^$2=//p" "$(lf_file "$1")" 2>/dev/null | head -1 || true; }

# lf_active <root>: a relay is running (state present, acting tool differs from the master).
lf_active() {
  local m a
  [[ -f "$(lf_file "$1")" ]] || return 1
  m="$(lf_get "$1" master)"; a="$(lf_get "$1" acting)"
  [[ -n "$m" && -n "$a" && "$a" != "$m" ]]
}

# lf_enabled: lead_failover is not off and LOOMY_NO_SWITCH is not 1.
lf_enabled() {
  [[ "${LOOMY_NO_SWITCH:-}" != "1" ]] || return 1
  [[ "$(loomy_config_get lead_failover 2>/dev/null || true)" != "off" ]]
}

# lf_room_threshold: share below which a tool counts as having room (quota_room, 80 by default).
lf_room_threshold() {
  local v; v="$(loomy_config_get quota_room 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 100 )) || v=80
  echo "$v"
}

# lf_prepare_threshold: the share from which the relay is announced (switch threshold minus 5); empty when switching is off.
lf_prepare_threshold() {
  local s; s="$(ai_switch_threshold)"
  [[ -n "$s" ]] || return 0
  echo $(( s > 5 ? s - 5 : 1 ))
}

# lf_has_room <tool>: on a subscription, below quota_room (no reading counts as room, a reached limit does not);
# a tool used through the API always has room.
lf_has_room() {
  local q m room
  loomy_on_plan "$1" || return 0
  q="$(ai_quota "$1")"
  if printf '%s\n' "$q" | grep -q '^reached'; then return 1; fi
  m="$(ai_quota_max "$1")"
  [[ -n "$m" ]] || return 0
  room="$(lf_room_threshold)"
  (( m < room ))
}

# _lf_other <tool> / _lf_installed <tool>
_lf_other() { if [[ "$1" == "codex" ]]; then echo claude; else echo codex; fi; }
_lf_installed() { if [[ "$1" == "claude" ]]; then ai_has_claude; else ai_has_codex; fi; }

# _lf_reason <tool>: sets LF_REASON ("5 h 96 %" for the highest window at or above the threshold, or "limit reached")
# and LF_RESUME_AT (reset of the latest saturated window: all must reset; empty when unknown).
_lf_reason() {
  local th w p r bw="" bp=0 reset="" reached=0
  th="$(ai_switch_threshold)"; th="${th:-95}"
  while read -r w p r; do
    [[ -n "$w" ]] || continue
    if [[ "$w" == "reached" ]]; then reached=1; continue; fi
    if (( p >= th )); then
      if [[ -z "$bw" ]] || (( p > bp )); then bw="$w"; bp="$p"; fi
      if [[ -z "$reset" ]] || (( r > reset )); then reset="$r"; fi
    fi
  done < <(ai_quota "$1")
  LF_RESUME_AT="$reset"
  if (( ! reached )) && [[ -n "$bw" ]]; then LF_REASON="$(_ai_window_label "$bw") $bp %"
  else
    LF_REASON="$(t "limit reached")"
    # Reached without a saturated window: the latest running reset is when it can end.
    if [[ -z "$reset" ]]; then LF_RESUME_AT="$(ai_quota "$1" | awk '$1 != "reached" { if ($3 > m) m = $3 } END { if (m) print m }')"; fi
  fi
}

# lf_start <root> <master> <acting> <reason> <resume_at> [manual]: records the relay and journals it.
lf_start() {
  local f manual="${6:-0}" extra="" manual_line=""; f="$(lf_file "$1")"
  [[ -d "$1/.loomy" ]] || return 0
  if [[ "$manual" == 1 ]]; then manual_line=$'manual=1\n'; extra=',"manual":true'; fi
  printf 'master=%s\nacting=%s\nsince=%s\nreason=%s\nresume_at=%s\n%s' "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$4" "${5:-}" "$manual_line" >"$f" 2>/dev/null || return 0
  ai_journal_write "$1" "\"type\":\"lead_failover\",\"master\":\"$2\",\"acting\":\"$3\",\"reason\":$(ai_json_str "$4"),\"resume_at\":\"${5:-}\"$extra" || true
  return 0
}

# lf_clear <root>: removes the state, no event.
lf_clear() { rm -f "$(lf_file "$1")" 2>/dev/null || true; return 0; }

# lf_mark_manual <root>: marks an existing relay as user-selected without journaling another handover.
lf_mark_manual() {
  local f tmp
  f="$(lf_file "$1")"
  [[ -f "$f" ]] || return 0
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 0
  if awk -F= '$1 == "manual" { if (!seen) print "manual=1"; seen=1; next } { print } END { if (!seen) print "manual=1" }' "$f" >"$tmp"; then
    mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 0; }
  else rm -f "$tmp"; fi
  return 0
}

# lf_end <root> [manual]: the master takes the lead back: journals lead_return with the duration, then clears the state.
lf_end() {
  local m a s since_ep dur=0 extra=""
  [[ "${2:-$(lf_get "$1" manual)}" != 1 ]] || extra=',"manual":true'
  m="$(lf_get "$1" master)"; a="$(lf_get "$1" acting)"; s="$(lf_get "$1" since)"
  since_ep="$(ai_ts_epoch "$s")"
  [[ -n "$since_ep" ]] && dur=$(( $(date +%s) - since_ep ))
  ai_journal_write "$1" "\"type\":\"lead_return\",\"master\":\"$m\",\"acting\":\"$a\",\"duration_s\":$dur$extra" || true
  lf_clear "$1"
}

# lf_master_ready <root>: the master has room again, or its saturated window has reset.
lf_master_ready() {
  local m r now
  m="$(lf_get "$1" master)"; r="$(lf_get "$1" resume_at)"; now="$(date +%s)"
  [[ -n "$m" ]] || return 0
  if [[ "$r" =~ ^[0-9]+$ ]] && (( now >= r )); then return 0; fi
  lf_has_room "$m"
}

# lf_time <epoch>: HH:MM local.
lf_time() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || true; }

# lf_decide <root> <master> [--dry] [codex|claude|auto]: prints "<lead tool> <normal|handover|continue|return>" and sets LF_LEAD, LF_KIND,
# LF_MASTER, LF_ACTING, LF_REASON, LF_RESUME_AT, LF_SINCE, LF_MANUAL and LF_NOTE ("no other tool with room left" when the master is
# saturated and nothing can take over). Without --dry the decision is recorded (state and journal).
lf_decide() {
  local root="$1" master="$2" dry="${3:-}" requested="${4:-}" other active=0
  LF_LEAD="$master"; LF_KIND="normal"; LF_MASTER="$master"; LF_ACTING=""; LF_REASON=""; LF_RESUME_AT=""; LF_SINCE=""; LF_NOTE=""; LF_MANUAL=0
  if lf_active "$root" && [[ "$(lf_get "$root" master)" == "$master" ]]; then
    active=1
    LF_ACTING="$(lf_get "$root" acting)"; LF_REASON="$(lf_get "$root" reason)"; LF_RESUME_AT="$(lf_get "$root" resume_at)"; LF_SINCE="$(lf_get "$root" since)"
    LF_MANUAL="$(lf_get "$root" manual)"; LF_MANUAL="${LF_MANUAL:-0}"
  fi
  # An explicit choice overrides quota decisions for this launch; the chain protects it afterwards.
  if [[ -n "$requested" ]]; then
    [[ "$requested" != auto ]] || requested="$master"
    if [[ "$requested" == "$master" ]]; then
      if (( active )); then
        LF_KIND="return"; LF_MANUAL=1
        [[ "$dry" == "--dry" ]] || lf_end "$root" 1
      elif [[ "$dry" != "--dry" ]]; then lf_clear "$root"; fi
    elif (( active )) && [[ "$requested" == "$LF_ACTING" ]]; then
      LF_KIND="continue"; LF_LEAD="$LF_ACTING"; LF_MANUAL=1
      [[ "$dry" == "--dry" ]] || lf_mark_manual "$root"
    else
      LF_KIND="handover"; LF_LEAD="$requested"; LF_ACTING="$requested"; LF_REASON="manual"; LF_RESUME_AT=""; LF_MANUAL=1
      [[ "$dry" == "--dry" ]] || lf_start "$root" "$master" "$requested" manual "" 1
    fi
    echo "$LF_LEAD $LF_KIND"; return 0
  fi
  if (( active )) && { [[ "$LF_MANUAL" == 1 ]] || lf_enabled; }; then
    if { [[ "$LF_MANUAL" != 1 ]] && lf_master_ready "$root"; } ||
      { lf_enabled && ai_quota_saturated "$LF_ACTING" && _lf_installed "$master" && lf_has_room "$master"; }; then
      LF_KIND="return"; LF_LEAD="$master"
      [[ "$dry" == "--dry" ]] || lf_end "$root"
    else LF_KIND="continue"; LF_LEAD="$LF_ACTING"; fi
    echo "$LF_LEAD $LF_KIND"; return 0
  fi
  [[ "$dry" == "--dry" ]] || lf_clear "$root"
  if lf_enabled && ai_quota_saturated "$master"; then
    other="$(_lf_other "$master")"
    if _lf_installed "$other"; then
      if ! loomy_on_plan "$other"; then
        LF_NOTE="$(t "the other tool is on a pay-per-use plan")"
      elif ! ai_quota_saturated "$other" && lf_has_room "$other"; then
        _lf_reason "$master"
        LF_KIND="handover"; LF_LEAD="$other"; LF_ACTING="$other"
        [[ "$dry" == "--dry" ]] || lf_start "$root" "$master" "$other" "$LF_REASON" "$LF_RESUME_AT"
      else LF_NOTE="$(t "no other tool with room left")"; fi
    else LF_NOTE="$(t "no other tool with room left")"; fi
  fi
  echo "$LF_LEAD $LF_KIND"
  return 0
}

# _lf_lock_acquire <path>: wait for the project relay lock, removing a lock older than 30 seconds. Gives up after about
# 40 s (an unwritable .loomy/ must not hang loomy start): the decision then runs unlocked, and the caller removes nothing.
_lf_lock_acquire() {
  local lock="$1" now created mtime age tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$(( tries + 1 )); (( tries > 40 )) && return 1
    [[ -d "$lock" ]] || { sleep 1 || true; continue; }
    now="$(date +%s)"
    created="$(sed -n '1p' "$lock/created" 2>/dev/null || true)"
    if [[ "$created" =~ ^[0-9]+$ ]]; then age=$(( now - created ))
    else
      mtime="$(date -r "$lock" +%s 2>/dev/null || true)"
      if [[ "$mtime" =~ ^[0-9]+$ ]]; then age=$(( now - mtime )); else age=0; fi
    fi
    if (( age > 30 )); then rm -rf "$lock" 2>/dev/null || true
    else sleep 1 || true; fi
  done
  printf '%s\n' "$(date +%s)" >"$lock/created" 2>/dev/null || true
}

# lf_apply <root> [codex|claude|auto]: serialize and re-run the decision; the lock is removed when this call exits.
lf_apply() {
  local root="$1" master="${LF_MASTER:-}" lock="$1/.loomy/failover.lock"
  [[ -d "$root/.loomy" && -n "$master" ]] || return 0
  if _lf_lock_acquire "$lock"; then
    lf_decide "$root" "$master" "" "${2:-}" >/dev/null
    rm -rf "$lock" 2>/dev/null || true
  else
    lf_decide "$root" "$master" "" "${2:-}" >/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------- notices (hook, session context, display)

# lf_tool_name <tool>: the name shown to the user.
lf_tool_name() { if [[ "$1" == "codex" ]]; then echo "Codex"; else echo "Claude Code"; fi; }

# lf_since_time <root>: HH:MM (local) the active relay started, empty when unknown.
lf_since_time() {
  local e; e="$(ai_ts_epoch "$(lf_get "$1" since)")"
  [[ -n "$e" ]] && lf_time "$e"
  return 0
}

# lf_status_text <root>: one line for loomy status/watch while a relay is active ("" otherwise).
lf_status_text() {
  local m a r at
  lf_active "$1" || return 0
  m="$(lf_get "$1" master)"; a="$(lf_get "$1" acting)"; r="$(lf_get "$1" reason)"; at="$(lf_get "$1" resume_at)"
  if [[ "$(lf_get "$1" manual)" == 1 ]]; then
    t "Lead: %s in place of %s (manual)" "$(lf_tool_name "$a")" "$(lf_tool_name "$m")"
  elif [[ "$at" =~ ^[0-9]+$ ]]; then
    t "Lead: %s in place of %s (quota %s, back around %s)" "$(lf_tool_name "$a")" "$(lf_tool_name "$m")" "$r" "$(lf_time "$at")"
  else
    t "Lead: %s in place of %s (quota %s)" "$(lf_tool_name "$a")" "$(lf_tool_name "$m")" "$r"
  fi
}

# Throttle of the in-session notices: <root>/.loomy/relay.notice, one "<kind> <epoch>" line per kind.
# lf_notice_due <root> <kind>: no notice of that kind in the last 10 minutes.
lf_notice_due() {
  local last now; now="$(date +%s)"
  last="$(awk -v k="$2" '$1 == k { print $2 }' "$1/.loomy/relay.notice" 2>/dev/null | tail -1 || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  (( now - last >= 600 ))
}
lf_notice_mark() {
  local f="$1/.loomy/relay.notice" keep=""
  [[ -f "$f" ]] && keep="$(grep -v "^$2 " "$f" 2>/dev/null || true)"
  { [[ -n "$keep" ]] && printf '%s\n' "$keep"; printf '%s %s\n' "$2" "$(date +%s)"; } >"$f" 2>/dev/null || true
  return 0
}

# lf_prompt_notice <root> <tool>: for the prompt hook of <tool> (a message, or nothing). Claude Code only: Codex has no
# per-prompt hook, so its session only learns about the relay at its start (lf_context_lines).
#   prepare  <tool> is the lead and the master, its quota is close to the switch and the other tool can take over
#   return   <tool> is the acting lead and the master has room again
# At most once per 10 minutes per kind and project; never when the tool is used through the API.
lf_prompt_notice() {
  local root="$1" tool="$2" master other max pt name oname
  lf_enabled || return 0
  loomy_on_plan "$tool" || return 0
  name="$(lf_tool_name "$tool")"
  if lf_active "$root"; then
    [[ "$(lf_get "$root" manual)" != 1 ]] || return 0
    [[ "$(lf_get "$root" acting)" == "$tool" ]] || return 0
    lf_master_ready "$root" || return 0
    lf_notice_due "$root" return || return 0
    lf_notice_mark "$root" return
    t "[Loomy] %s has quota again and takes the lead back: finish the current step, write .loomy/docs/HANDOFF.md and update STATE.md for it, commit if allowed, then tell the user to end this session (/exit): Loomy hands back automatically." "$(lf_tool_name "$(lf_get "$root" master)")"
    return 0
  fi
  ai_detect_env "$root" 2>/dev/null || true
  ai_resolve lead "${AI_ENV:-}" "${AI_PROFILE:-}" 2>/dev/null || true
  master="${R_FAMILY:-}"
  [[ "$master" == "$tool" ]] || return 0
  pt="$(lf_prepare_threshold)"; [[ -n "$pt" ]] || return 0
  max="$(ai_quota_max "$tool")"; [[ "$max" =~ ^[0-9]+$ ]] || return 0
  (( max >= pt )) || return 0
  other="$(_lf_other "$tool")"; oname="$(lf_tool_name "$other")"
  _lf_installed "$other" && lf_has_room "$other" || return 0
  lf_notice_due "$root" prepare || return 0
  lf_notice_mark "$root" prepare
  t "[Loomy] %s quota at %s %%: finish the current step, write .loomy/docs/HANDOFF.md (From, To, Done, Next) and update .loomy/memory/STATE.md, commit if the brief allows it, then tell the user to end this session (/exit): Loomy continues on %s automatically, and %s takes the lead back once its quota allows." "$name" "$max" "$oname" "$name"
  return 0
}

# lf_context_lines <root> <tool>: lines for the session-start context (hook start, Codex), possibly none.
lf_context_lines() {
  local root="$1" tool="$2" m a r at since ev ts ep J
  if lf_active "$root"; then
    m="$(lf_get "$root" master)"; a="$(lf_get "$root" acting)"; r="$(lf_get "$root" reason)"; at="$(lf_get "$root" resume_at)"
    since="$(lf_since_time "$root")"
    if [[ "$(lf_get "$root" manual)" == 1 ]]; then
      t "- Temporary lead: %s in place of %s (manual). Read .loomy/docs/HANDOFF.md if present and .loomy/memory/STATE.md first. Keep this lead until the user selects --lead auto or --lead %s, or its quota requires a relay." "$(lf_tool_name "$a")" "$(lf_tool_name "$m")" "$m"
    elif [[ "$at" =~ ^[0-9]+$ ]]; then
      t "- Temporary lead: %s in place of %s since %s (quota %s); %s takes the lead back once its quota allows (around %s). Read .loomy/docs/HANDOFF.md first." "$(lf_tool_name "$a")" "$(lf_tool_name "$m")" "${since:-?}" "$r" "$(lf_tool_name "$m")" "$(lf_time "$at")"
    else
      t "- Temporary lead: %s in place of %s since %s (quota %s); %s takes the lead back once its quota allows. Read .loomy/docs/HANDOFF.md first." "$(lf_tool_name "$a")" "$(lf_tool_name "$m")" "${since:-?}" "$r" "$(lf_tool_name "$m")"
    fi
    echo
    return 0
  fi
  # No relay: the master back as lead (the last relay event is a lead_return of the last 10 minutes).
  J="$(ai_journal_file "$root")"
  [[ -s "$J" ]] || return 0
  ev="$(grep -E '"type":"lead_(failover|return)"' "$J" 2>/dev/null | tail -1 || true)"
  case "$ev" in *'"type":"lead_return"'*) ;; *) return 0 ;; esac
  ts="$(printf '%s' "$ev" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"; ep="$(ai_ts_epoch "$ts")"
  [[ -n "$ep" ]] && (( $(date +%s) - ep <= 600 )) || return 0
  m="$(printf '%s' "$ev" | sed -n 's/.*"master":"\([^"]*\)".*/\1/p')"; a="$(printf '%s' "$ev" | sed -n 's/.*"acting":"\([^"]*\)".*/\1/p')"
  [[ "$m" == "$tool" && -n "$a" ]] || return 0
  if [[ "$ev" == *'"manual":true'* ]]; then
    t "- Back as lead agent after a manual relay: %s led; read .loomy/docs/HANDOFF.md and .loomy/memory/STATE.md and check its commits." "$(lf_tool_name "$a")"
    echo; return 0
  fi
  t "- Back as lead agent: %s led during your quota pause; read .loomy/docs/HANDOFF.md and check its commits." "$(lf_tool_name "$a")"
  echo
  return 0
}

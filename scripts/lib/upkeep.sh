#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Upkeep at launch (loomy, start, init, task, audit): Loomy, its model catalog and the AI CLIs kept up to date without
# extra commands. Never slows anything down: remote versions are read from caches refreshed in the background at most once
# a day. When something needs updating, one question, then everything is done in one go and the command goes on.
# Off: loomy config set auto_update no, or LOOMY_NO_AUTOUPDATE=1 (one command). Bash 3.2 compatible.
# To be sourced after ui.sh, config.sh, models.sh and repair.sh.

# _up_remote_loomy: latest published Loomy version (cache ~/.config/loomy/loomy.remote, refreshed in the background daily).
_up_remote_loomy() {
  local cache today checked remote repo="${LOOMY_REPO:-Eydenn/loomy}"
  cache="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/loomy.remote"; today="$(date +%Y-%m-%d)"
  checked="$(sed -n 's/^checked=//p' "$cache" 2>/dev/null | head -1)"; remote="$(sed -n 's/^remote=//p' "$cache" 2>/dev/null | head -1)"
  if [[ "$checked" != "$today" ]] && command -v gh >/dev/null 2>&1; then
    mkdir -p "$(dirname "$cache")" 2>/dev/null || true
    (
      v="$(gh release view -R "$repo" --json tagName -q .tagName 2>/dev/null | sed 's/^v//')"
      [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || v="$remote"
      printf 'checked=%s\nremote=%s\n' "$today" "$v" >"$cache"
    ) >/dev/null 2>&1 &
  fi
  echo "$remote"
}

# loomy_relays_sync <project root>: adds the relays a project created with an older Loomy lacks (.loomy/scripts/),
# so new commands work there without loomy init --update.
loomy_relays_sync() {
  local r="$1" f n
  [[ -f "$r/.loomy/scripts/_loomy.sh" ]] || return 0
  for f in "$LOOMY_HOME"/scripts/*.sh; do
    n="$(basename "$f")"; [[ -e "$r/.loomy/scripts/$n" ]] && continue
    printf '#!/usr/bin/env bash\n# Loomy relay: runs %s from the installed Loomy (see _loomy.sh).\n. "$(dirname "$0")/_loomy.sh" && _loomy_run %s "$@"\n' "$n" "$n" >"$r/.loomy/scripts/$n" 2>/dev/null \
      && chmod +x "$r/.loomy/scripts/$n" 2>/dev/null
  done
  return 0
}

# loomy_upkeep: returns 0 when nothing was updated, 10 when Loomy itself was updated (the caller runs the command again).
loomy_upkeep() {
  [[ "${LOOMY_NO_AUTOUPDATE:-}" == "1" ]] && return 0
  [[ "$(loomy_config_get auto_update 2>/dev/null || true)" == "no" ]] && return 0
  local snooze today items=() st v remote tool cat_new
  today="$(date +%Y-%m-%d)"
  # The catalog is data only: updated silently.
  cat_new="$(bash "$LOOMY_HOME/scripts/ai-catalog-check.sh" 2>/dev/null || true)"
  [[ -n "$cat_new" ]] && "$LOOMY_HOME/bin/loomy" update --catalog >/dev/null 2>&1 || true
  ui_is_interactive || return 0
  snooze="$(loomy_config_get auto_update_snooze 2>/dev/null || true)"
  [[ "$snooze" == "$today" ]] && return 0
  remote="$(_up_remote_loomy)"
  if [[ -n "$remote" && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! ai_version_ge "$VERSION" "$remote"; then items+=("loomy|$(t "Loomy %s → %s" "$VERSION" "$remote")"); fi
  for tool in claude codex; do
    st="$(ai_tool_state "$tool")"
    case "$st" in
      old*) read -r _ v _ <<<"$st"; items+=("$tool|$(t "%s %s too old for the routed models (%s needed)" "$( [[ $tool == claude ]] && echo "Claude Code" || echo Codex)" "$v" "$(ai_tool_min "$tool")")") ;;
      broken*) items+=("$tool|$(t "%s does not start" "$( [[ $tool == claude ]] && echo "Claude Code" || echo Codex)")") ;;
    esac
  done
  (( ${#items[@]} )) || return 0
  local lines="" it
  for it in "${items[@]}"; do lines="${lines:+$lines · }${it#*|}"; done
  UI_DESCS=("$(t "Done now, in one go (each step checked; settings and conversations kept), then the command goes on.")" \
    "$(t "Asked again tomorrow.")" \
    "$(t "No more automatic updates (loomy config set auto_update yes to turn them back on).")")
  ui_choose "$(t "Updates needed: %s. Update now?" "$lines")" 0 "$(t "Yes, update (recommended)")" "$(t "Later")" "$(t "Never ask")"
  case "$UI_INDEX" in
    1) loomy_config_set auto_update_snooze "$today"; return 0 ;;
    2) loomy_config_set auto_update no; return 0 ;;
  esac
  local updated_self=0
  for it in "${items[@]}"; do
    case "${it%%|*}" in
      claude|codex) LOOMY_REPAIR_YES=1 ai_repair_tool "${it%%|*}" && ui_ok "$(t "%s ready" "$( [[ "${it%%|*}" == claude ]] && echo "Claude Code" || echo Codex)")" "$(ai_tool_state "${it%%|*}" | cut -d' ' -f2)" ;;
      loomy) if "$LOOMY_HOME/bin/loomy" update; then updated_self=1; else ui_warn "$(t "Loomy not updated")" "loomy update"; fi ;;
    esac
  done
  (( updated_self )) && return 10
  return 0
}

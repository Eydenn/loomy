#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Loomy activity log: <project>/.loomy/logs/events.jsonl, one JSON line per event.
# Feeds "loomy status" and "loomy watch". To be sourced. Bash 3.2 compatible.
#
# The log is only written inside a Loomy project (.loomy folder present).
# LOOMY_JOURNAL=0 turns it off; LOOMY_JOURNAL_TASKS=0 doesn't record the task text.

ai_journal_file() { echo "$1/.loomy/logs/events.jsonl"; }

ai_journal_enabled() {
  [[ "${LOOMY_JOURNAL:-1}" != "0" && -d "$1/.loomy" ]]
}

# Escapes a string for JSON (quotes, backslash, newlines, tabs, control characters).
ai_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"
  printf '"%s"' "$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
}

# ai_journal_write <root> <JSON pairs without braces, e.g. "type":"phase","phase":"build">
# Monthly archive: on the first event of a new month, the previous month's log moves to
# .loomy/logs/archive/events-YYYY-MM.jsonl. The latest session events follow into the new log
# (open / closed state of the current session). Reading the whole history: ai_journal_all.
_ai_journal_rotate() {
  local file="$1" month now dir mfile
  [[ -s "$file" ]] || return 0
  # Month of the current log: recorded separately (copied session events keep their original date).
  mfile="$(dirname "$file")/month"; now="$(date -u +%Y-%m)"
  month="$(cat "$mfile" 2>/dev/null || true)"
  [[ -n "$month" ]] || month="$(head -1 "$file" | sed -n 's/^{"ts":"\([0-9]\{4\}-[0-9]\{2\}\).*/\1/p')"
  if [[ -z "$month" || "$month" == "$now" ]]; then printf '%s\n' "$now" >"$mfile"; return 0; fi
  dir="$(dirname "$file")/archive"; mkdir -p "$dir" 2>/dev/null || return 0
  cat "$file" >>"$dir/events-$month.jsonl" && { grep '"type":"session"' "$file" | tail -4 >"$file.tmp" || true; } && mv "$file.tmp" "$file"
  printf '%s\n' "$now" >"$mfile"
}

# ai_journal_all <root>: the whole log, archives included, in order.
ai_journal_all() {
  local f d="$1/.loomy/logs"
  for f in "$d"/archive/events-*.jsonl; do [[ -f "$f" ]] && cat "$f"; done
  [[ -f "$d/events.jsonl" ]] && cat "$d/events.jsonl"
  return 0
}

ai_journal_write() {
  local root="$1" body="$2" file
  ai_journal_enabled "$root" || return 0
  file="$(ai_journal_file "$root")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  _ai_journal_rotate "$file" 2>/dev/null || true
  printf '{"ts":"%s",%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$body" >>"$file" 2>/dev/null || true
}

# ai_usage_record <racine> <transcription .jsonl> <lead|subagent> [type d'agent]
# Real cost of Claude Code turns (lead agent, native subagents), read from the session transcript:
# only lines new since the last pass are read (index .loomy/logs/usage.idx), each message is
# counted once (id), one "usage" event is written per model.
# Prices: input, cache write (5 min: 1.25 × input; 1 h: 2 ×), cache read, output. Checked: identical
# to the cost Claude Code reports (claude -p --output-format json) on a session with a subagent.
# A model with a long-prompt rate (Haiku 5.5 above 100K tokens) has those messages counted apart, at that rate.
ai_usage_record() {
  local root="$1" tr="$2" scope="$3" agent="${4:-}" idx done_n total line model tin tcw tcr tout n price cost
  [[ -f "$tr" ]] || return 0
  ai_journal_enabled "$root" || return 0
  idx="$root/.loomy/logs/usage.idx"; mkdir -p "$(dirname "$idx")" 2>/dev/null || return 0
  done_n="$(awk -F '\t' -v p="$tr" '$1 == p { n = $2 } END { print n + 0 }' "$idx" 2>/dev/null || echo 0)"
  total="$(wc -l <"$tr" | tr -d ' ')"
  (( total > done_n )) || return 0
  tail -n +"$(( done_n + 1 ))" "$tr" | head -n "$(( total - done_n ))" | awk -v long="$(ai_price_long_list)" '
    BEGIN { nl = split(long, ll, " "); for (k = 1; k <= nl; k++) { lp[k] = ll[k]; sub(/=.*/, "", lp[k]); lt[k] = ll[k]; sub(/.*=/, "", lt[k]) } }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    index($0, "\"type\":\"assistant\"") && index($0, "\"usage\"") {
      id = ""; if (match($0, /"id":"msg_[^"]*"/)) id = substr($0, RSTART, RLENGTH)
      if (id != "" && (id in seen)) next; seen[id] = 1
      m = ""; if (match($0, /"model":"[^"]*"/)) { m = substr($0, RSTART + 9, RLENGTH - 10) }
      if (m == "" || m == "<synthetic>") next
      # Cache write: 5 min (1.25 × input) or 1 h (2 ×); without detail: 1 h (main session).
      cw = num("cache_creation_input_tokens"); w5 = num("ephemeral_5m_input_tokens"); w1 = num("ephemeral_1h_input_tokens")
      if (w5 + w1 == 0) w1 = cw
      for (k = 1; k <= nl; k++) if (index(m, lp[k]) == 1 && num("input_tokens") + cw + num("cache_read_input_tokens") > lt[k] + 0) { m = m "@long"; break }
      i[m] += num("input_tokens"); f[m] += w5; h[m] += w1; r[m] += num("cache_read_input_tokens"); o[m] += num("output_tokens"); c[m]++
      # Advisor consultations (the Claude Code advisor tool): one advisor_message iteration each, with its own model.
      rest = $0
      while (match(rest, /\{"input_tokens":[0-9]+,"output_tokens":[0-9]+[^{}]*(\{[^{}]*\}[^{}]*)*"type":"advisor_message","model":"[^"]+"\}/)) {
        it = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        am = it; sub(/.*"model":"/, "", am); sub(/".*/, "", am)
        ai_ = it; sub(/^\{"input_tokens":/, "", ai_); sub(/,.*/, "", ai_)
        ao = it; sub(/^\{"input_tokens":[0-9]+,"output_tokens":/, "", ao); sub(/,.*/, "", ao)
        an[am]++; ain[am] += ai_; aout[am] += ao
      }
    }
    END { for (m in c) print m, i[m], f[m], h[m], r[m], o[m], c[m]
          for (m in an) print "ADVISOR", m, ain[m], aout[m], an[m] }' | while read -r model tin tw5 tw1 tcr tout n; do
      if [[ "$model" == "ADVISOR" ]]; then
        # here: tin = advisor model, tw5 = input tokens, tw1 = output tokens, tcr = consultations
        price="$(ai_price "$tin")"; cost=""
        [[ -n "$price" ]] && cost="$(awk -v p="$price" -v a="$tw5" -v o="$tw1" 'BEGIN { split(p, q, " "); printf "%.6f", (a * q[1] + o * q[2]) / 1000000 }')"
        ai_journal_write "$root" "\"type\":\"advisor\",\"tool\":\"claude\",\"family\":\"claude\",\"scope\":\"$scope\",\"model\":\"$tin\",\"calls\":$tcr,\"tokens_in\":$tw5,\"tokens_cached\":0,\"tokens_out\":$tw1,\"cost_usd\":${cost:-0},\"cost_source\":\"estimate\""
        continue
      fi
      price=""
      if [[ "$model" == *@long ]]; then model="${model%@long}"; price="$(ai_price_long "$model" | cut -d' ' -f2-)"; fi
      [[ -n "$price" ]] || price="$(ai_price "$model")"
      cost=""; tcw=$(( tw5 + tw1 ))
      [[ -n "$price" ]] && cost="$(awk -v p="$price" -v a="$tin" -v f="$tw5" -v h="$tw1" -v r="$tcr" -v o="$tout" 'BEGIN { split(p, q, " "); printf "%.6f", (a * q[1] + f * q[1] * 1.25 + h * q[1] * 2 + r * q[3] + o * q[2]) / 1000000 }')"
      ai_journal_write "$root" "\"type\":\"usage\",\"tool\":\"claude\",\"family\":\"claude\",\"scope\":\"$scope\",\"agent\":$(ai_json_str "$agent"),\"model\":\"$model\",\"messages\":$n,\"tokens_in\":$(( tin + tcw )),\"tokens_cached\":$tcr,\"tokens_out\":$tout,\"cost_usd\":${cost:-0},\"cost_source\":\"estimate\""
    done
  { awk -F '\t' -v p="$tr" '$1 != p' "$idx" 2>/dev/null || true; printf '%s\t%s\n' "$tr" "$total"; } >"$idx.tmp" && mv "$idx.tmp" "$idx"
  return 0
}

# ai_cost_estimate <model> <uncached input tokens> <cached tokens> <output tokens>: estimated cost in $.
ai_cost_estimate() {
  local price
  price="$(ai_price "$1")"
  [[ -z "$price" ]] && { echo ""; return 0; }
  # shellcheck disable=SC2086
  set -- $price "$2" "$3" "$4"
  awk -v pin="$1" -v pout="$2" -v pcache="$3" -v tin="$4" -v tcache="$5" -v tout="$6" \
    'BEGIN { printf "%.6f", (tin*pin + tcache*pcache + tout*pout) / 1000000 }'
}

# ai_json_num <json> <key>: first numeric value of the key (0 when missing).
ai_json_num() {
  local v
  v="$(printf '%s' "$1" | grep -oE "\"$2\":[0-9.]+" | head -1 | sed 's/.*://')"
  echo "${v:-0}"
}

# ai_task_excerpt <text>: task excerpt for the log (200 characters), empty when LOOMY_JOURNAL_TASKS=0.
ai_task_excerpt() {
  if [[ "${LOOMY_JOURNAL_TASKS:-1}" == "0" ]]; then echo ""; return 0; fi
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-200
}

# ai_session_state <root>: "open|<local time>|<tool>", "closed|<time>|<tool>" or "none".
# A session is open when it started, hasn't ended, and its process (Claude Code or Codex) is still running.
# ai_ts_epoch <ISO UTC timestamp>: seconds since 1970 (macOS or GNU date), empty when unreadable.
ai_ts_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || true
}

ai_session_state() {
  local j line pid ts tool state="none" s hhmm
  j="$(ai_journal_file "$1")"
  [[ -s "$j" ]] || { echo "none"; return 0; }
  while IFS='|' read -r kind pid ts tool; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == "open" ]]; then
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then state="open|$ts|$tool"; break; fi
    elif [[ "$state" == "none" ]]; then state="closed|$ts|$tool"; fi
  done < <(awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    /"type":"session"/ {
      key = field("session"); if (key == "") key = "pid" num("pid")
      # A resumed session (claude --continue) keeps its id: a new start cancels the previous end.
      if (index($0, "\"event\":\"start\"")) { n++; order[n] = key; start[key] = num("pid") "|" field("ts") "|" field("tool"); delete ended[key] }
      else { ended[key] = field("ts") "|" field("tool"); last_end = field("ts") "|" field("tool") }
    }
    END {
      for (i = n; i >= 1 && i > n - 10; i--) if (!(order[i] in ended)) print "open|" start[order[i]]
      if (last_end != "") print "end||" last_end
    }' "$j" 2>/dev/null)
  [[ "$state" == "none" ]] && { echo "none"; return 0; }
  ts="$(printf '%s' "$state" | cut -d'|' -f2)"
  s="$(ai_ts_epoch "$ts")"
  hhmm="$( [[ -n "$s" ]] && { date -r "$s" +%H:%M 2>/dev/null || date -d "@$s" +%H:%M 2>/dev/null; } )"
  echo "$(printf '%s' "$state" | cut -d'|' -f1)|${hhmm:-?}|$(printf '%s' "$state" | cut -d'|' -f3)"
}

# ai_delegation_id: short delegation id, links its start event to its end event.
ai_delegation_id() { printf 'd%s%05d' "$(date +%s)" "$$"; }

# ai_journal_start <root> <id> <bridge> <role> <family> <model> <effort> <sandbox> <task>
# Flags a running delegation. The pid lets "loomy status" discard an interrupted delegation.
ai_journal_start() {
  ai_journal_write "$1" "\"type\":\"delegation_start\",\"id\":\"$2\",\"pid\":$$,\"bridge\":\"$3\",\"role\":\"$4\",\"family\":\"$5\",\"model\":\"$6\",\"effort\":\"$7\",\"sandbox\":\"$8\",\"task\":$(ai_json_str "$(ai_task_excerpt "$9")")"
}

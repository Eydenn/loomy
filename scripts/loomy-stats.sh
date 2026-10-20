#!/usr/bin/env bash
# Detailed usage statistics of a Loomy project. Bash 3.2 compatible.
#   loomy-stats.sh                     the whole history (monthly archives included)
#   loomy-stats.sh --since YYYY-MM-DD  from that date
#   loomy-stats.sh --days N            the last N days
#   loomy-stats.sh --root <dir>        works on another project folder
# Delegations (role, model, duration, tokens, success) and Claude Code's own work (lead agent, sub-agents).
# Subscription: amounts are the API value of the work, covered by the plan, next to the quota; API: the real cost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"

ROOT=""; SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --since) SINCE="${2:-}"; shift ;;
    --days) [[ "${2:-}" =~ ^[0-9]+$ ]] || { t "--days: a number of days" >&2; echo >&2; exit 2; }
            SINCE="$(date -v-"$2"d +%Y-%m-%d 2>/dev/null || date -d "-$2 days" +%Y-%m-%d)"; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/loomy-stats.sh/loomy stats/' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy stats --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ -z "$SINCE" || "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { t "--since: a date YYYY-MM-DD" >&2; echo >&2; exit 2; }
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
[[ -f "$ROOT/.loomy/brief.md" || -d "$ROOT/.loomy/logs" ]] || { t "No Loomy project here: run loomy init." >&2; echo >&2; exit 1; }

PC=0; loomy_on_plan claude && PC=1
PX=0; loomy_on_plan codex && PX=1
NAME="$(_ai_brief_get "$ROOT/.loomy/brief.md" name)"

# One pass over the log: every figure the report needs, as tagged lines.
DATA="$(ai_journal_all "$ROOT" | ai_journal_canonical | awk -v since="$SINCE" -v pc="$PC" -v px="$PX" '
  function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
  function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
  {
    ts = field("ts"); if (ts == "" || (since != "" && substr(ts, 1, 10) < since)) next
    ty = field("type"); if (ty != "delegation" && ty != "usage") next
    if (field("bridge") == "codex-native") { native++; next }
    if (first == "" || ts < first) first = ts; if (ts > last) last = ts
    f = field("family"); plan = (f == "codex" ? px : pc) + 0
    ti = num("tokens_in"); tc = num("tokens_cached"); to = num("tokens_out"); c = num("cost_usd"); day = substr(ts, 1, 10)
    if (ty == "delegation" && (field("bridge") == "subagent" || field("cost_in") == "usage")) { ti=0; tc=0; to=0; c=0 }
    m = field("model"); md[m] = plan
    mi[m] += ti; mc[m] += tc; mo[m] += to; mv[m] += c
    dt[day] += ti + to; if (plan) dp[day] += c; else da[day] += c
    if (plan) pv += c; else ac += c
    ti_all += ti; tc_all += tc; to_all += to
    if (ty == "delegation") {
      r = field("role"); n++; d = num("duration_s"); dur += d
      ok = (field("status") == "ok"); availability = (field("status") == "paused" || field("status") == "handed_over"); if (!ok && !availability) err++; if (field("status") == "paused") paused++; if (field("status") == "handed_over") handed++; if (field("failover_from") != "") fo++
      if (field("format") == "structured") { sf++; oc = field("outcome"); if (oc == "unformatted") suf++; else if (oc == "partial") sp++; else if (oc == "blocked") sb++ }
      if (field("review") == "incomplete") ri++
      rn[r]++; rd[r] += d; rt[r] += ti + to; rv[r] += c; rp[r] = (rp[r] == "" ? plan : (rp[r] == plan ? plan : 2)); if (!ok && !availability) re[r]++
      mn[m]++; dn[day]++
    } else {
      if (field("scope") == "lead") { lr += num("messages"); lt += ti + to; lv += c } else { sn++; st += ti + to; sv += c }
      mu[m] += num("messages")
    }
  }
  END {
    printf "NATIVE|%d\n", native
    printf "ALL|%s|%s|%d|%d|%d|%d|%d|%d|%.4f|%.4f|%d|%d|%.4f|%d|%d|%.4f|%d|%d|%d|%d|%d|%d|%d|%d\n", first, last, n, err, dur, ti_all, tc_all, to_all, ac, pv, lr, lt, lv, sn, st, sv, fo, sf, suf, sp, sb, paused, handed, ri
    for (r in rn) printf "ROLE|%s|%d|%d|%d|%.4f|%d|%d\n", r, rn[r], rd[r], rt[r], rv[r], rp[r], re[r]
    for (m in md) printf "MODEL|%s|%d|%d|%d|%d|%d|%.4f|%d\n", m, mn[m], mu[m], mi[m], mc[m], mo[m], mv[m], md[m]
    for (d in dt) printf "DAY|%s|%d|%d|%.4f|%.4f\n", d, dn[d], dt[d], da[d], dp[d]
  }')"

IFS='|' read -r _ FIRST LAST N ERR DUR TI TC TO API_COST PLAN_VAL LR LT LV SN ST SV FO SF SUF SP SB PAUSED HANDED RI <<<"$(printf '%s\n' "$DATA" | grep '^ALL|')"
IFS='|' read -r _ NATIVE <<<"$(printf '%s\n' "$DATA" | grep '^NATIVE|')"

# Only timestamps and lifecycle metadata leave this reader; never request text.
METRICS="$(ai_journal_all "$ROOT" | ai_journal_canonical | perl -MJSON::PP -MTime::Local=timegm -MCwd=realpath -MFile::Find -e '
  use strict; use warnings;
  my ($root,$sessions,$since)=@ARGV; my (@requests,@workers,%hook,%closed,%seen);
  sub epoch {
    my ($s)=@_; return unless defined($s) && $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$/;
    return eval { timegm($6,$5,$4,$3,$2-1,$1) + ($7//0) };
  }
  sub included { defined($_[0]) && (!$since || substr($_[0],0,10) ge $since) }
  sub record { my $d=eval {decode_json($_[0])}; ref($d) eq "HASH" ? $d : undef }
  while (<STDIN>) {
    my $d=record($_) or next; my $ts=epoch($d->{ts}); next unless defined $ts;
    my $sid=$d->{session}//""; my $ty=$d->{type}//"";
    if ($ty eq "request" && included($d->{ts})) { push @{$hook{$sid}},$ts }
    if ($ty eq "session_activity" && ($d->{state}//"") eq "idle" || $ty eq "session" && ($d->{event}//"") eq "end") { push @{$closed{$sid}},$ts }
    if ($ty eq "delegation" && included($d->{ts}) && ($d->{duration_s}//0)>0) {
      my $key=join "|",$sid,$d->{turn_id}//$d->{id}//"",$d->{bridge}//"";
      push @workers,[$ts-$d->{duration_s},$ts] unless $seen{$key}++;
    }
  }
  for my $sid (keys %hook) {
    my @starts=sort {$a<=>$b} @{$hook{$sid}}; my @ends=sort {$a<=>$b} @{$closed{$sid}//[]};
    for my $i (0..$#starts) {
      my ($end)=grep {$_ >= $starts[$i] && ($i==$#starts || $_ <= $starts[$i+1])} @ends;
      push @requests,[$starts[$i],$end] if defined $end;
    }
  }
  # Codex has no prompt hook. Read lead rollouts and one user record per turn.
  my $project=realpath($root); my $shared=realpath("$root/.loomy"); my @files;
  if (-d $sessions) { find({no_chdir=>1,wanted=>sub {push @files,$File::Find::name if /\.jsonl$/ && -f $_ && !-l $_}},$sessions) }
  for my $file (@files) {
    open my $fh,"<",$file or next; my $meta=record(scalar <$fh>) or next;
    next unless ($meta->{type}//"") eq "session_meta";
    my $p=$meta->{payload}//{}; my $src=$p->{source}//""; next if ref($src) || $src eq "exec";
    my $cwd=realpath($p->{cwd}//""); next unless defined($cwd) && ($cwd eq $project || index($cwd,"$project/")==0 || defined($shared) && (realpath("$cwd/.loomy")//"") eq $shared);
    my ($user,$turn); my %turns;
    while (<$fh>) {
      my $d=record($_) or next; my $v=$d->{payload}//{}; next unless ref($v) eq "HASH";
      my $ts=epoch($d->{timestamp}); next unless defined $ts;
      my $type=$v->{type}//"";
      if (($d->{type}//"") eq "event_msg" && $type eq "task_started") { $turn=$v->{turn_id}//$ts; $user=undef }
      if (($d->{type}//"") eq "event_msg" && $type eq "user_message" || ($d->{type}//"") eq "response_item" && ($v->{role}//"") eq "user") {
        $user=$ts unless defined $user;
      }
      if (($d->{type}//"") eq "event_msg" && ($type eq "task_complete" || $type eq "task_completed" || $type eq "turn_aborted")) {
        if (defined($user) && included($d->{timestamp}) && (!$since || $user>=epoch("${since}T00:00:00Z")) && !$turns{$turn//$user}++) {
          push @requests,[$user,$ts] if $ts >= $user;
        }
        $user=$turn=undef;
      }
    }
    close $fh;
  }
  my $duration=0; $duration += $_->[1]-$_->[0] for @requests;
  my ($sum,$wall,$lo,$hi)=(0,0);
  for my $w (sort {$a->[0]<=>$b->[0]} @workers) {
    $sum += $w->[1]-$w->[0];
    if (!defined($lo)) { ($lo,$hi)=@$w }
    elsif ($w->[0] <= $hi) { $hi=$w->[1] if $w->[1]>$hi }
    else { $wall += $hi-$lo; ($lo,$hi)=@$w }
  }
  $wall += $hi-$lo if defined $lo;
  printf "%d|%.0f|%.0f|%.2f",scalar(@requests),$duration,@requests ? $duration/@requests : 0,$wall>0 ? $sum/$wall : 0;
' "$ROOT" "${CODEX_HOME:-$HOME/.codex}/sessions" "$SINCE")"
IFS='|' read -r REQUESTS REQUEST_TIME REQUEST_MEAN PARALLEL <<<"$METRICS"

day_of() { local ep; ep="$(ai_ts_epoch "$1")"; [[ -n "$ep" ]] && { date -r "$ep" +%Y-%m-%d 2>/dev/null || date -d "@$ep" +%Y-%m-%d; }; }
money() {   # money <amount> <on plan: 0|1|2>: real cost, or "≈ API value" when covered by a subscription
  case "$2" in
    0) printf '$%.2f' "$1" ;;
    1) printf '%s≈$%.2f%s' "$C_DIM" "$1" "$C_RESET" ;;
    *) printf '$%.2f*' "$1" ;;
  esac
}
dur_label() { _ui_dur $(( ${1:-0} * 1000 )); printf '%s' "$UI_DUR"; }

ui_banner "$(t "Statistics")" "${NAME:-$(basename "$ROOT")} · ${SINCE:+$(t "since %s" "$SINCE") · }${ROOT/#$HOME/~}"
(( NATIVE == 0 )) || ui_info "$(t 'native usage unknown') · $(t '%s finished' "$NATIVE")"

if (( REQUESTS > 0 )); then
  ui_kv "$(t 'Completed requests')" "$(t '%s requests · %s total · %s average' "$REQUESTS" "$(dur_label "$REQUEST_TIME")" "$(dur_label "$REQUEST_MEAN")")"
fi
if [[ "$PARALLEL" != 0.00 ]]; then ui_kv "$(t 'Parallelism')" "$(t '%sx (worker time / active wall time)' "$PARALLEL")"; fi

if [[ -z "$FIRST" ]]; then
  if (( NATIVE == 0 )); then
  ui_info "$(t "nothing logged yet%s" "${SINCE:+ $(t "since %s" "$SINCE")}")"
  ui_rail "${C_DIM}  $(t "figures show up as soon as the lead agent works or delegates")${C_RESET}"
  fi
else
  ui_section "$(t "OVERVIEW")" "$(t "from %s to %s" "$(day_of "$FIRST")" "$(day_of "$LAST")")"
  if (( N > 0 )); then
    ok_pct=$(( (N - ERR - PAUSED - HANDED) * 100 / N ))
    ui_kv "$(t "Delegations")" "${C_BOLD}${N}${C_RESET} · $(t "%s %% succeeded" "$ok_pct")$( (( ERR > 0 )) && printf ' · %s%s%s' "$C_RED" "$(t "%s failed" "$ERR")" "$C_RESET")"
    (( PAUSED == 0 && HANDED == 0 )) || ui_kv "$(t 'Availability')" "$(t '%s paused' "$PAUSED") · $(t '%s handed over' "$HANDED")"
    (( FO > 0 )) && ui_kv "$(t "Switched")" "$(t "%s delegation(s) moved to the other tool (quota nearly exhausted)" "$FO")"
    if (( SF > 0 )); then
      ui_kv "$(t "Structured")" "$(t "%s of %s answers followed the format" "$(( SF - SUF ))" "$SF")$( (( SP > 0 )) && printf ' · %s' "$(t "%s partial" "$SP")")$( (( SB > 0 )) && printf ' · %s' "$(t "%s blocked" "$SB")")$( (( RI > 0 )) && printf ' · %s' "$(t "%s review(s) without TRIED" "$RI")")"
    fi
    ui_kv "$(t "Duration")" "$(t "%s in total · %s on average" "$(dur_label "$DUR")" "$(dur_label $(( DUR / N )))")"
  fi
  (( LR > 0 )) && ui_kv "$(t "Lead agent")" "$(t "%s reply(ies)" "$LR") · $(ai_tokens_label "$LT") $(t "tokens") · $(money "$LV" "$PC")"
  (( SN > 0 )) && ui_kv "$(t "Sub-agents")" "$SN · $(ai_tokens_label "$ST") $(t "tokens") · $(money "$SV" "$PC")"
  ui_kv "$(t "Tokens")" "$(t "%s in · %s from cache · %s out" "${C_BOLD}$(ai_tokens_label "$TI")${C_RESET}" "$(ai_tokens_label "$TC")" "${C_BOLD}$(ai_tokens_label "$TO")${C_RESET}")"
  if (( ! PC || ! PX )); then ui_kv "$(t "API cost")" "${C_BOLD}$(printf '$%.2f' "$API_COST")${C_RESET}"; fi
  if (( PC || PX )); then ui_kv "$(t "Subscriptions")" "$(t "API value %s, covered by your plan(s)" "$(printf '≈$%.2f' "$PLAN_VAL")")"; fi

  if (( N > 0 )); then
    ui_section "$(t "BY ROLE")" "$(t "calls · average time · tokens · cost")"
    printf '%s\n' "$DATA" | grep '^ROLE|' | sort -t'|' -k4 -rn | while IFS='|' read -r _ r n d tk v p e; do
      ui_rail "$(printf '%-11s %4s  %9s  %8s  ' "$r" "$n" "$(dur_label $(( d / n )))" "$(ai_tokens_label "$tk")")$(money "$v" "$p")$( (( e > 0 )) && printf '  %s%s%s' "$C_RED" "$(t "%s failed" "$e")" "$C_RESET")"
    done
  fi

  ui_section "$(t "BY MODEL")" "$(t "calls · tokens in / cache / out · cache share · cost")"
  printf '%s\n' "$DATA" | grep '^MODEL|' | sort -t'|' -k8 -rn | while IFS='|' read -r _ m n u ti tc to v p; do
    calls="$n"; (( u > 0 )) && calls="${n}+${u}r"
    cache=0; if (( ti + tc > 0 )); then cache=$(( tc * 100 / (ti + tc) )); fi
    ui_rail "$(printf '%-17s %6s  %7s / %7s / %7s  %3s %%  ' "$m" "$calls" "$(ai_tokens_label "$ti")" "$(ai_tokens_label "$tc")" "$(ai_tokens_label "$to")" "$cache")$(money "$v" "$p")"
  done
  ui_info "$(t "calls: delegations, +Nr: Claude Code replies on that model")"

  ui_section "$(t "BY DAY")" "$(t "last 14 days with activity")"
  printf '%s\n' "$DATA" | grep '^DAY|' | sort -t'|' -k2 -r | head -14 | while IFS='|' read -r _ d n tk va vp; do
    amount=""
    (( ! PC || ! PX )) && amount="$(money "$va" 0)"
    (( PC || PX )) && amount="${amount:+$amount  }$(money "$vp" 1)"
    ui_rail "$(printf '%s  %3s %-14s %8s %s  ' "$d" "$n" "$(t "delegation(s)")" "$(ai_tokens_label "$tk")" "$(t "tokens")")${amount}"
  done
fi

ui_section "$(t "PLANS")"
for fam in claude codex; do
  plan="$(loomy_plan "$fam")"; name="Claude"; [[ "$fam" == "codex" ]] && name="Codex"
  if [[ "$plan" == "api" ]]; then ui_kv "$name" "API · $(t "pay as you go")"
  else
    q="$(ai_quota_line "$fam")"
    ui_kv "$name" "$(ai_plan_label "$fam" "$plan") · ${q:-${C_DIM}$(ai_quota_hint "$fam")${C_RESET}}"
    # What this month's work would have cost through the API, next to the plan's price.
    month_val="$(ai_journal_all "$ROOT" | ai_journal_canonical | awk -v fam="\"family\":\"$fam\"" -v ts="\"ts\":\"$(date -u +%Y-%m)" '
      (index($0, "\"type\":\"delegation\",") || index($0, "\"type\":\"usage\"")) && index($0, fam) && index($0, ts) && !/"bridge":"subagent"|"bridge":"codex-native"|"cost_in":"usage"/ {
        if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART + 11, RLENGTH - 11) }
      END { printf "%.2f", c }')"
    monthly="$(loomy_plan_monthly "$fam")"
    ui_rail "                  ${C_DIM}$(t "this month: API value ≈\$%s%s" "$month_val" "${monthly:+ $(t "for a \$%s/month plan" "$monthly")}")${C_RESET}"
  fi
done
if (( PC || PX )); then ui_info "$(t "≈ amounts: what the work would cost through the API, covered by your subscription")"; fi
ui_end "$(t "other period: loomy stats --days 7 · --since YYYY-MM-DD · raw figures: loomy log --csv")"

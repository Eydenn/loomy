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

# The sampler loads the same Perl module in-process; one-shot commands collect through
# loomy_native_collect_once (tree.sh): one transient election, one poll of each source, then
# the pure reducer, in a single Perl process (see AI_NATIVE_COLLECT_PL below).
AI_CODEX_NATIVE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-native.pl"
AI_LIVE_STATE_LIB="${AI_CODEX_NATIVE_LIB%/*}/live-state.pl"
AI_CLAUDE_NATIVE_LIB="${AI_CODEX_NATIVE_LIB%/*}/claude-native.pl"
# Strict schema for events read from the journal (see event-schema.pl); the Perl readers load it from here.
AI_EVENT_SCHEMA_LIB="${AI_CODEX_NATIVE_LIB%/*}/event-schema.pl"; export AI_EVENT_SCHEMA_LIB

# A Stop hook proves the lead turn is idle; it does not close the reusable session.
ai_journal_claude_idle() {
  local sid ts
  # One process for the session id and the timestamp: "<id> <ts>" (the id never holds a space).
  read -r sid ts < <(printf '%s' "$2" | perl -MJSON::PP -MTime::HiRes=time -MPOSIX=strftime -e '
    local $/; my $d=eval {decode_json(<STDIN>)}; exit unless ref($d) eq "HASH";
    my $id=$d->{session_id}; exit unless defined($id) && !ref($id) && $id =~ /\A[A-Za-z0-9_.:-]{1,100}\z/;
    my $n=time; print "$id ",strftime("%Y-%m-%dT%H:%M:%S",gmtime($n)).sprintf(".%03dZ",int(($n-int($n))*1000));
  ' 2>/dev/null) || true
  [[ -n "$sid" && -n "$ts" ]] || return 0
  ai_journal_write "$1" "\"type\":\"session_activity\",\"tool\":\"claude\",\"session\":$(ai_json_str "$sid"),\"state\":\"idle\"" "$ts"
}
# Private logs, including older files. Descriptor chmod never follows a symbolic link.
# The Perl is a sub shared by ai_journal_prepare and ai_journal_write (one process for both).
AI_JOURNAL_PREPARE_PL='
  # Leak barrier: journal-gate.pl answers (cached, fail closed; see there) before anything is created. The same check
  # guards the single append in live-state.pl, so every .loomy/logs journal writer is covered, not only this one.
  # When this preparation creates .loomy/logs nothing was cached for the absent directory: the gate is asked again.
  sub journal_prepare {
    my ($dir,$module,$gated)=@_; my $old=umask 0077; my $ok=0; my $existed=-d $dir; my $allowed=1;
    unless ($gated) {
      my $lib=defined $module ? $module : ""; $allowed=0 unless $lib =~ s{/[^/]+\z}{};
      $allowed=eval { require "$lib/journal-gate.pl"; Loomy::JournalGate::check($dir) } ? 1 : 0 if $allowed;
    }
    if ($allowed) {
      $ok=_journal_prepare($dir);
      if ($ok && !$existed && !$gated) {
        my ($again,$s)=eval { Loomy::JournalGate::verdict($dir,1) }; Loomy::JournalGate::store($dir,$s) if $again && $s; $ok=0 unless $again;
      }
    }
    umask $old; return $ok;
  }
  sub _journal_prepare {
    my $dir=shift;
    mkdir $dir,0700 unless -e $dir; return 0 unless -d $dir && !-l $dir;
    my @dirs=($dir); my @files;
    if (-e "$dir/archive" || -l "$dir/archive") {
      return 0 unless -d "$dir/archive" && !-l "$dir/archive"; push @dirs,"$dir/archive";
    }
    for my $d (@dirs) {
      opendir my $dh,$d or return 0;
      for my $n (readdir $dh) {
        next if $n eq "." || $n eq ".." || ($d eq $dir && $n eq "archive");
        my $p="$d/$n"; return 0 if -l $p; push @files,$p if -f $p;
      }
    }
    for my $d (@dirs) { sysopen my $f,$d,O_RDONLY|O_NOFOLLOW or return 0; chmod 0700,$f or return 0 }
    push @files,"$dir/events.jsonl" unless -e "$dir/events.jsonl";
    # chmod only when the mode differs: even a same-mode chmod moves the change time, which the consent record of
    # content-policy.conf is bound to (ADR-0012).
    for my $p (@files) { sysopen my $f,$p,O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return 0; my @m=stat($f); chmod 0600,$f or return 0 unless @m && ($m[2]&07777)==0600 }
    return 1;
  }
'
_ai_journal_guard() { [[ ! -L "$1/.loomy" && -d "$1/.loomy" && ! -L "$1/.loomy/logs" ]]; }
# True when .loomy/logs may be written (the leak barrier verdict, cached): for the small log writers outside the journal.
ai_journal_gate() {
  perl -e 'require "$ARGV[0]/journal-gate.pl"; exit(Loomy::JournalGate::check($ARGV[1]) ? 0 : 1)' "${AI_LIVE_STATE_LIB%/*}" "$1/.loomy/logs" 2>/dev/null
}
ai_journal_prepare() {
  _ai_journal_guard "$1" || return 1
  perl -MFcntl=O_RDONLY,O_RDWR,O_CREAT,O_NOFOLLOW -e "$AI_JOURNAL_PREPARE_PL"'exit(journal_prepare(@ARGV) ? 0 : 1);' "$1/.loomy/logs" "$AI_LIVE_STATE_LIB" 2>/dev/null
}

# LOCK L3: the only elector. One compound collection per command: a free slot is won for the
# call (transient guard), the logs are prepared only then, each source is polled once with the
# guard, the guard is released, and the returned checkpoints feed the pure reducer. A contended
# slot is never an error: the caller follows (peeked checkpoints, no preparation, no mutation).
# The Perl prints nothing itself; callers read the facts line and the two states.
AI_NATIVE_COLLECT_PL='
package Loomy::NativeCollect;
use strict; use warnings;
our $lib;
# Fixed machine codes only: the lock/record file the primitive names, never a free-form path.
sub clean { my $v=shift; $v=defined($v) && !ref($v) ? "$v" : ""; $v =~ s/[^A-Za-z0-9_.\/-]/_/g; return substr($v,0,80) }
sub load {
    my $dir=shift; return 1 if $lib;
    # The adapters load their siblings by canonical path: the same spelling here, or a symlinked
    # install would load the guard module twice and invalidate every guard it issues.
    require Cwd; $dir=Cwd::abs_path($dir)//$dir; $lib=$dir;
    require "$dir/live-state.pl"; require "$dir/codex-native.pl"; require "$dir/claude-native.pl";
    require "$dir/runtime-paths.pl"; require "$dir/journal-gate.pl"; require "$dir/collector-owner.pl";
    Loomy::LiveState::require_owner(1);   # a lost election can never take the legacy unguarded path
    return 1;
}
# Clone-shipped runtime state tracked in the repository index (see Loomy::RuntimePaths::tracked_runtime):
# returns ($path,$why) with $why tracked or timeout. This only NAMES a refusal for the user, after Loomy::JournalGate::check
# (the barrier, never memoized beyond its own 2 s) said no; it is not the verdict. Memo bounds: an answer is reused for 30 s of wall clock, so a
# watch that keeps retrying a lost election asks the index at most every 30 s (while git is unresponsive each
# question can cost the 2 s bound, so at most 2 s of freeze per 30 s); a clock that moves backwards keeps the
# last answer until it catches up; a watch that already OWNS the collector does not ask again (it is rechecked only
# when it re-elects, after a fence or promotion). Not a security boundary against a hostile same-user process.
my %tracked_memo;
sub tracked_runtime {
    my $root=shift; return ("","") unless defined $root && $root =~ m{\A/};
    my $m=$tracked_memo{$root}; my $d=$m ? time-$m->[0] : -1;
    return @{$m->[1]} if $m && $d<30 && $d>=-30 && ($m->[1][1]//"") ne "";   # only a refusal is reused: it is a reason, never the verdict
    my @r=Loomy::RuntimePaths::tracked_runtime($root); $tracked_memo{$root}=[time,\@r]; return @r;
}
# One election. busy/bootstrap-busy means retry (a follower inspecting holds the gate briefly),
# never "another owner": it is retried a few times, then followed.
sub elect {
    my ($dir,$root,$retries)=@_; $retries||=3; load($dir);
    my %r=(role=>"off",status=>"unavailable",reason=>"disabled",file=>"",state=>"",fenced=>"",refusal=>"");
    return \%r if ($ENV{LOOMY_JOURNAL}//"1") eq "0" || !-d "$root/.loomy";
    my $ctx=eval {Loomy::RuntimePaths::resolve($root)};
    unless (ref($ctx) eq "HASH") { @r{qw(role status reason)}=("follower","unsafe","invalid-context"); return \%r }
    # A clone can ship checkpoints, shards or markers: they would be trusted (and chmod 0600 by the
    # preparation, erasing the signal). Refuse before any preparation; mode is deliberately not a criterion.
    # The barrier decides (cached, fail closed); the index is asked again only to name the refusal.
    my ($t,$why)=("","");
    unless (eval { Loomy::JournalGate::check(($ctx->{root}//$root)."/.loomy/logs",1) }) { ($t,$why)=tracked_runtime($ctx->{root}//$root); $why="index-error" if $why eq "" }
    # A path that cannot be shown as is (altered characters, too long) is reported without a name.
    if ($why eq "tracked") { @r{qw(role status reason file)}=("follower","unsafe","tracked-runtime",$t =~ m{\A[A-Za-z0-9._/-]{1,120}\z} ? $t : ""); return \%r }
    if ($why eq "timeout" || $why eq "index-error") { @r{qw(role status reason)}=("follower","unsafe",($why eq "timeout" ? "index-timeout" : "index-error")); return \%r }
    my $f;
    for my $try (1..$retries) {
        $f=eval {Loomy::CollectorOwner::try_acquire($ctx,Loomy::CodexNative::build_id())};
        last unless ref($f) eq "HASH" && ($f->{reason}//"") eq "bootstrap-busy" && $try<$retries;
        select undef,undef,undef,0.02;
    }
    $f={status=>"unavailable",reason=>"io-error"} unless ref($f) eq "HASH";
    $r{status}=clean($f->{status}); $r{reason}=clean($f->{reason}); $r{file}=clean($f->{file});
    $r{state}=clean(ref($f->{record}) eq "HASH" ? $f->{record}{state} : "");
    $r{ctx}=$ctx; $r{role}="follower";
    if ($r{status} eq "owned") {
        # A first bootstrap created logs after the context was resolved: pin the new directory.
        $ctx=eval {Loomy::RuntimePaths::resolve($root)} unless ref($ctx) eq "HASH" && $ctx->{logs};
        if (ref($ctx) eq "HASH" && $ctx->{logs}) { @r{qw(role guard ctx)}=("owner",$f->{guard},$ctx); $r{scope}=$f->{scope_set} }
        else { eval {Loomy::CollectorOwner::release($f->{guard})}; @r{qw(status reason)}=("unsafe","unsafe-runtime") }
    }
    return \%r;
}
# Pure follower evidence from the peeked manifests: the last valid snapshot, or the stale backup.
sub peek_state {
    my ($logs,$tool,$e)=@_;
    my $p=Loomy::LiveState::checkpoint_peek("$logs/$tool-native.idx");
    $e->{refusal}||=$p->{reason} if ($p->{status}//"") eq "unsupported";
    return unless ref($p->{checkpoint}) eq "HASH" && ($p->{status}//"") =~ /^(?:valid|stale|unsupported)$/;
    Loomy::LiveState::stat_evidence($tool,$p->{checkpoint});
    return $p->{checkpoint};
}
sub collect {
    my ($dir,$root,$sessions,$projects)=@_;
    my $e=elect($dir,$root); my ($native,$claude);
    if ($e->{role} eq "owner") {
        my $o={owner=>$e->{guard},context=>$e->{ctx}}; my $logs="$e->{ctx}{root}/.loomy/logs";
        if (main::journal_prepare($logs,undef,1)) {   # the election just ran the same gate
            for my $tool ($sessions ne "" && -d $sessions ? "codex" : (),"claude") {
                my $s=eval {$tool eq "codex" ? Loomy::CodexNative::poll($root,$sessions,$o) : Loomy::ClaudeNative::poll($root,$projects,$o)};
                if (($@//"") =~ /\Acollector owner ([A-Z_]+)\n\z/) { $e->{fenced}=$1; last }
                if (($Loomy::CodexNative::refusal//"") =~ /\Aunsupported-/) { $e->{refusal}=$Loomy::CodexNative::refusal; $s=peek_state($logs,$tool,$e) }
                if ($tool eq "codex") { $native=$s } else { $claude=$s }
            }
        } else { @$e{qw(status reason)}=("unsafe","unsafe-runtime") }
        eval {Loomy::CollectorOwner::release($e->{guard})}; $e->{guard}=undef;
    } elsif ($e->{role} eq "follower" && ref($e->{ctx}) eq "HASH" && $e->{ctx}{loomy}) {
        my $logs=($e->{ctx}{root}//$root)."/.loomy/logs";
        $native=peek_state($logs,"codex",$e); $claude=peek_state($logs,"claude",$e);
    }
    $e->{ctx}=undef;
    return ($native,$claude,$e);
}
sub facts_line { my $e=shift; return join("|","F",map {clean($e->{$_})} qw(role status reason file state fenced refusal)) }
package main;
'
# ai_owner_note <role> <status> <reason> <file> <state> <fenced> <refusal>: the one place that turns
# collector facts into text. Sets AI_OWNER_NOTE and AI_OWNER_KIND (problem|drain|follow|"").
# busy/bootstrap-busy mean "retry", never "another owner"; files come from the frozen L0 table.
ai_owner_note() {
  local role="${1:-}" status="${2:-}" reason="${3:-}" file="${4:-}" state="${5:-}" fenced="${6:-}" refusal="${7:-}" a b
  AI_OWNER_NOTE=""; AI_OWNER_SHORT=""; AI_OWNER_KIND=""
  # Footer notes are short and lead with the action (at most 70 characters); AI_OWNER_LONG=1
  # (status, tree, doctor: they have room) names the files to delete.
  if [[ -n "$fenced" ]]; then
    tv AI_OWNER_NOTE "Tracking stopped: storage changed · run loomy doctor"; AI_OWNER_KIND=problem; return 0
  fi
  case "$status:$reason" in
    owned:*|off:*|unavailable:disabled|unavailable:free|unavailable:missing-runtime|busy:bootstrap-busy|:*) ;;
    busy:locked)
      if [[ "$state" == draining ]]; then tv AI_OWNER_NOTE "Owner is finishing its batch · showing stored data"; AI_OWNER_KIND=drain; return 0; fi
      # A compatible owner is active: this view is current. A future checkpoint still deserves its note.
      if [[ -z "$refusal" ]]; then
        tv a "Following another watch"; tv b "q closes this view"
        AI_OWNER_SHORT="$a"; AI_OWNER_NOTE="$a · $b"; AI_OWNER_KIND=follow; return 0
      fi ;;
    *)
      AI_OWNER_KIND=problem
      case "$reason" in
        tracked-runtime)
          if [[ "${AI_OWNER_LONG:-0}" == 1 && -n "$file" ]]; then tv AI_OWNER_NOTE "Live tracking is unavailable: %s is tracked by Git. Run loomy doctor --fix, then reopen this view." "$file"   # never git rm --cached: that leaves the shipped file in place and trusted (doctor --fix quarantines it first)
          elif [[ "${AI_OWNER_LONG:-0}" == 1 ]]; then tv AI_OWNER_NOTE "Live tracking is unavailable: a tracked file under .loomy/logs. Run loomy doctor --fix, then reopen this view."
          else tv AI_OWNER_NOTE "Tracked runtime file · run loomy doctor"; fi ;;
        unsafe-lock)
          if [[ "${AI_OWNER_LONG:-0}" == 1 ]]; then tv AI_OWNER_NOTE "Live tracking is unavailable: %s is unsafe. Close any older watch, delete it and %s, then reopen this view." ".loomy/logs/collector.lock" ".loomy/logs/collector-owner-v1.json"
          else tv AI_OWNER_NOTE "Tracking unavailable · run loomy doctor"; fi ;;
        invalid-record|unsafe-record|unsupported-schema|unsupported-protocol|missing-lock)
          if [[ -z "$file" ]]; then tv AI_OWNER_NOTE "Older watch is running · close it, reopen this one"
          elif [[ "${AI_OWNER_LONG:-0}" == 1 ]]; then tv AI_OWNER_NOTE "Live tracking is unavailable: %s cannot be used. Close any older watch, delete that file, then reopen this view." ".loomy/$file"
          else tv AI_OWNER_NOTE "Tracking unavailable · run loomy doctor"; fi ;;
        *) if [[ "$status" == incompatible ]]; then tv AI_OWNER_NOTE "Older watch is running · close it, reopen this one"
           else tv AI_OWNER_NOTE "Storage not verified · run loomy doctor"; fi ;;
      esac
      return 0 ;;
  esac
  if [[ -n "$refusal" ]]; then
    tv AI_OWNER_NOTE "Newer checkpoints · showing stored data · update Loomy"; AI_OWNER_KIND=problem
  fi
  return 0
}

# Legacy/untrusted logs can contain huge lines: bound bytes before splitting or canonicalizing.
ai_journal_tail() {
  perl -MFcntl=O_RDONLY,O_NOFOLLOW -e '
    my ($path,$limit)=@ARGV; $limit=4000 unless defined($limit) && $limit =~ /^\d+$/;
    exit if -l $path || !-f $path;
    sysopen my $f,$path,O_RDONLY|O_NOFOLLOW or exit;
    my $size=-s $f; my $start=$size>8388608 ? $size-8388608 : 0;
    seek $f,$start,0 or exit; sysread($f,my $raw,8388608);
    $raw =~ s/^[^\n]*\n// if $start;
    my $end=rindex($raw,"\n"); exit if $end<0;
    my @rows=grep {length($_)<=65536} split /\n/,substr($raw,0,$end+1);
    splice @rows,0,@rows-$limit if @rows>$limit; print "$_\n" for @rows;
  ' "$1" "${2:-4000}"
}

# Escapes a string for JSON (quotes, backslash, newlines, tabs, control characters).
ai_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"
  printf '"%s"' "$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
}

# ai_journal_write <root> <JSON pairs without braces, e.g. "type":"phase","phase":"build">
# Monthly or 8 MiB rotation uses immutable inode-named archive segments. All open sessions
# and agents carry structural snapshots, without usage. Reading full history: ai_journal_all.
_ai_journal_rotate() {
  perl -e '
    my ($module,$path)=@ARGV; require $module;
    my $dir=$path; $dir =~ s{/[^/]+$}{};
    my $lock=Loomy::LiveState::journal_lock($dir,1) or exit;
    eval {Loomy::LiveState::journal_rotate($path); 1} or warn "journal rotation unavailable\n" if -s $path;
  ' "$AI_LIVE_STATE_LIB" "$1"
}

# ai_journal_all <root>: the whole log, archives included, in order.
ai_journal_all() {
  local f d="$1/.loomy/logs"
  for f in "$d"/archive/events-*.jsonl; do [[ -f "$f" ]] && cat "$f"; done
  [[ -f "$d/events.jsonl" ]] && cat "$d/events.jsonl"
  return 0
}

ai_journal_write() { _ai_journal_write_checked "$@" || true; }
_ai_journal_write_checked() {
  local root="$1" body="$2" file
  ai_journal_enabled "$root" || return 0
  file="$(ai_journal_file "$root")"
  _ai_journal_guard "$root" || return 1
  printf '%s' "$body" | perl -MFcntl=O_RDONLY,O_RDWR,O_CREAT,O_NOFOLLOW -e "$AI_JOURNAL_PREPARE_PL"'
    my ($module,$path,$ts)=@ARGV; my $dir=$path; $dir =~ s{/[^/]+\z}{};
    exit 2 unless journal_prepare($dir,$module);
    require $module;
    local $/; my $body=<STDIN>;
    exit(Loomy::LiveState::journal_append($path,$body,$ts) ? 0 : 1);
  ' "$AI_LIVE_STATE_LIB" "$file" "${3:-}"
}

# Canonical hook/transcript lifecycle; snapshots preserve state without new usage.
ai_journal_canonical() {
  perl -MJSON::PP -e '
    require $ENV{AI_EVENT_SCHEMA_LIB};
    my (@events,%native,%alias,%seen,%terminal,%owners,%lifetimes);
    # Every event leaves here with schema-valid identifiers, timestamps and numbers (changed ones are re-encoded).
    while (<STDIN>) {my $e=eval {decode_json($_)}; next unless ref($e) eq "HASH"; my $raw=$_; $raw=Loomy::EventSchema::encode($e)."\n" if Loomy::EventSchema::clean_event($e); push @events,[$raw,$e];
      my $pid=$e->{owner_pid}//$e->{pid};
      $owners{$e->{id}}=($e->{tool}//$e->{family}//"")."|$pid" if $e->{id} && defined($pid) && !ref($pid) && $pid =~ /^\d+$/ && $pid>1;
      $native{($e->{session}//"")."|".($e->{turn_id}//"")}=1 if ($e->{bridge}//"") eq "claude-native" && $e->{turn_id};
      $alias{$e->{alias_id}}=1 if ($e->{type}//"") eq "agent_alias" && $e->{alias_id};
      $terminal{($e->{session}//"")."|".($e->{id}//"")}=$#events if ($e->{bridge}//"") eq "claude-native" && ($e->{type}//"") eq "delegation";
    }
    for my $i (0..$#events) {my ($raw,$e)=@{$events[$i]};
      my $pid=$e->{owner_pid}//$e->{pid};
      my $owner=defined($pid) && !ref($pid) && $pid =~ /^\d+$/ && $pid>1 ? ($e->{tool}//$e->{family}//"")."|$pid" : $owners{$e->{id}//""}//"";
      # Only this owners observations cross the close barrier; unrelated rows and terminals stay deduplicated.
      ++$lifetimes{$owner} if $owner ne "" && ($e->{type}//"") eq "session" && ($e->{event}//"") eq "end";
      next if ($e->{bridge}//"") eq "subagent" && $native{($e->{session}//"")."|".($e->{id}//"")};
      next if $alias{$e->{id}//""};
      next if ($e->{bridge}//"") eq "claude-native" && ($e->{type}//"") eq "delegation" && $terminal{($e->{session}//"")."|".($e->{id}//"")}!=$i;
      if (($e->{type}//"") =~ /^(?:delegation(?:_start|_activity)?|session(?:_observed|_context|_activity)?)$/) {
        my %identity=%$e; delete $identity{snapshot};
        $identity{owner_lifetime}=$lifetimes{$owner}//0 if $owner ne "" && ($e->{type}//"") =~ /^(delegation_start|delegation_activity|session)$/;
        my $key=JSON::PP->new->canonical->encode(\%identity); next if $seen{$key}++;
      }
      print $raw;
    }
  '
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
  ai_journal_prepare "$root" || return 0
  idx="$root/.loomy/logs/usage.idx"
  done_n=0
  [[ ! -f "$idx" ]] || done_n="$(awk -F '\t' -v p="$tr" '$1 == p { n = $2 } END { print n + 0 }' "$idx" 2>/dev/null || echo 0)"
  total="$(wc -l <"$tr" | tr -d ' ')"
  (( total > done_n )) || return 0
  local usage_events
  usage_events="$(
    ai_journal_write() { printf '{%s}\n' "$2"; }
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
      # Transcript lines are data: a model name with a space would shift the columns into arithmetic.
      if [[ "$model" == "ADVISOR" ]]; then
        [[ "$tw5" =~ ^[0-9]+$ && "$tw1" =~ ^[0-9]+$ && "$tcr" =~ ^[0-9]+$ ]] || continue
        # here: tin = advisor model, tw5 = input tokens, tw1 = output tokens, tcr = consultations
        price="$(ai_price "$tin")"; cost=""
        [[ -n "$price" ]] && cost="$(awk -v p="$price" -v a="$tw5" -v o="$tw1" 'BEGIN { split(p, q, " "); printf "%.6f", (a * q[1] + o * q[2]) / 1000000 }')"
        ai_journal_write "$root" "\"type\":\"advisor\",\"tool\":\"claude\",\"family\":\"claude\",\"scope\":\"$scope\",\"model\":\"$tin\",\"calls\":$tcr,\"tokens_in\":$tw5,\"tokens_cached\":0,\"tokens_out\":$tw1,\"cost_usd\":${cost:-0},\"cost_source\":\"estimate\""
        continue
      fi
      [[ "$tin" =~ ^[0-9]+$ && "$tw5" =~ ^[0-9]+$ && "$tw1" =~ ^[0-9]+$ && "$tcr" =~ ^[0-9]+$ && "$tout" =~ ^[0-9]+$ && "$n" =~ ^[0-9]+$ ]] || continue
      price=""
      if [[ "$model" == *@long ]]; then model="${model%@long}"; price="$(ai_price_long "$model" | cut -d' ' -f2-)"; fi
      [[ -n "$price" ]] || price="$(ai_price "$model")"
      cost=""; tcw=$(( tw5 + tw1 ))
      [[ -n "$price" ]] && cost="$(awk -v p="$price" -v a="$tin" -v f="$tw5" -v h="$tw1" -v r="$tcr" -v o="$tout" 'BEGIN { split(p, q, " "); printf "%.6f", (a * q[1] + f * q[1] * 1.25 + h * q[1] * 2 + r * q[3] + o * q[2]) / 1000000 }')"
      ai_journal_write "$root" "\"type\":\"usage\",\"tool\":\"claude\",\"family\":\"claude\",\"scope\":\"$scope\",\"agent\":$(ai_json_str "$agent"),\"model\":\"$model\",\"messages\":$n,\"tokens_in\":$(( tin + tcw )),\"tokens_cached\":$tcr,\"tokens_out\":$tout,\"cost_usd\":${cost:-0},\"cost_source\":\"estimate\""
    done
  )"
  [[ -n "$usage_events" ]] || usage_events=''
  printf '%s' "$usage_events" | perl -MJSON::PP -MFcntl=O_RDWR,O_APPEND,O_CREAT,O_NOFOLLOW -e '
    my ($module,$file,$idx,$tr,$before,$total)=@ARGV; require $module;
    my $dir=$file; $dir =~ s{/[^/]+$}{};
    my $lock=Loomy::LiveState::journal_lock($dir,1) or exit 1;
    my $writer=Loomy::LiveState::content_writer(Loomy::LiveState::content_root($file)); exit 1 unless $writer;
    exit 1 unless Loomy::LiveState::safe_path($idx);
    my (@index,$current); $current=0;
    if (-f $idx) {open my $in,"<",$idx or exit 1; while (<$in>) {
      my ($path,$n)=split /\t/; if ($path eq $tr) {$current=0+$n} else {push @index,$_}
    }}
    exit 0 if $current>=$total; exit 1 unless $current==$before;
    my @lines; my $ts=POSIX::strftime("%Y-%m-%dT%H:%M:%SZ",gmtime);
    while (<STDIN>) {
      my $e=eval {decode_json($_)}; exit 1 unless ref($e) eq "HASH";
      my $line=Loomy::LiveState::journal_event_line($writer,{%$e,ts=>$ts}); exit 1 unless defined $line;
      push @lines,$line;
    }
    my $ok=eval {
      Loomy::LiveState::journal_rotate($file,$writer);
      sysopen my $out,$file,O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or die;
      chmod 0600,$out or die; my $offset=-s $out;
      my $bytes=join("",@lines); my $written=0;
      my $committed=eval {
        while ($written<length($bytes)) {my $n=syswrite($out,$bytes,length($bytes)-$written,$written); die unless $n; $written+=$n}
        $out->sync or die;
        Loomy::LiveState::atomic_file($idx,join("",@index)."$tr\t$total\n"); 1;
      };
      unless ($committed) {truncate $out,$offset; $out->sync; die}
      1;
    };
    warn "usage batch deferred; cursor unchanged\n" unless $ok;
    exit($ok ? 0 : 1);
  ' "$AI_LIVE_STATE_LIB" "$root/.loomy/logs/events.jsonl" "$idx" "$tr" "$done_n" "$total" || true
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
  local excerpt_root="${2:-${ROOT:-${root:-}}}"
  [[ "${LOOMY_JOURNAL_TASKS:-1}" != 0 && -n "$excerpt_root" ]] || return 0
  printf '%s' "$1" | perl -e '
    my ($module,$root)=@ARGV; require $module;
    exit unless Loomy::ContentPolicy::effective_policy($root)->{journal_content} eq "legacy-excerpts";
    local $/; my $text=Loomy::ContentPolicy::_decode_utf8(scalar(<STDIN>));
    $text =~ s/\n/ /g; print Loomy::ContentPolicy::_encode_utf8(substr($text,0,200));
  ' "${AI_LIVE_STATE_LIB%/*}/content-policy.pl" "$excerpt_root"
}

# Read-side titles shared by the live reducer and the session log; journal entries stay untouched.
AI_TITLE_PERL='use utf8;
  sub ai_title {
    my ($s)=@_; $s = "" unless defined $s && !ref($s);
    $s =~ s/^\s*(?:GOAL|TASK|OBJECTIF)\s*:\s*//i;
    $s =~ s/\bSCOPE\s*:.*//is;
    $s =~ s/[\r\n].*//s;
    $s =~ s/([.!?])(?:\s|$).*/$1/s;
    $s =~ s/\s+/ /g; $s =~ s/^\s+|\s+$//g;
    return $s;
  }
'

# JSON labels are already sanitized and clipped in Perl. Decode only this new
# field for awk consumers, preserving the historical parser for legacy tasks.
AI_DISPLAY_FIELD_AWK='
function ctl(v) { gsub(/[[:cntrl:]]/, " ", v); gsub(/\302[\200-\237]/, " ", v); return v }
function display_task(   v,i,c,out) {
  if (!match($0, /"display_task":"([^"\\]|\\.)*"/)) return ""
  v=substr($0,RSTART+16,RLENGTH-17); out=""
  for (i=1;i<=length(v);i++) {
    c=substr(v,i,1)
    if (c=="\\") {i++; c=substr(v,i,1); if (c ~ /^[nrtbf]$/) c=" "}
    out=out c
  }
  return ctl(out)
}
'

# Display-only context. Never pass prepared rows to a journal/checkpoint writer.
# Keeping the resolver here lets one-shot commands and the persistent sampler use
# the same policy API without loading another interpreter on timer-only frames.
ai_display_context_init() {
  declare -F tv >/dev/null || source "${AI_LIVE_STATE_LIB%/*}/i18n.sh"
  export LOOMY_DISPLAY_ROOT="$1" LOOMY_DISPLAY_POLICY_LIB="${AI_LIVE_STATE_LIB%/*}/content-policy.pl"
  tv LOOMY_DISPLAY_ROLE "Role: %s"
  tv LOOMY_DISPLAY_UNAVAILABLE "context unavailable"
  tv LOOMY_DISPLAY_architect "designs the plan"
  tv LOOMY_DISPLAY_debugger "finds the cause"
  tv LOOMY_DISPLAY_security "checks the risks"
  tv LOOMY_DISPLAY_reviewer "reviews the diff"
  tv LOOMY_DISPLAY_developer "edits + runs tests"
  tv LOOMY_DISPLAY_executor "runs bounded tasks"
  tv LOOMY_DISPLAY_explorer "reads the code"
  tv LOOMY_DISPLAY_documenter "writes the docs"
  tv LOOMY_DISPLAY_installed "Skill installed"
  tv LOOMY_DISPLAY_removed "Skill removed"
  tv LOOMY_DISPLAY_updated "Skill updated"
  tv LOOMY_DISPLAY_selected "Skill added"
  tv LOOMY_DISPLAY_manual "added by the user"
  tv LOOMY_DISPLAY_relay_manual "manual"
  tv LOOMY_DISPLAY_returned "returned"
  tv LOOMY_DISPLAY_reset "quota back"
  tv LOOMY_DISPLAY_unknown "unknown"
  export LOOMY_DISPLAY_ROLE LOOMY_DISPLAY_UNAVAILABLE LOOMY_DISPLAY_architect LOOMY_DISPLAY_debugger
  export LOOMY_DISPLAY_security LOOMY_DISPLAY_reviewer LOOMY_DISPLAY_developer LOOMY_DISPLAY_executor
  export LOOMY_DISPLAY_explorer LOOMY_DISPLAY_documenter LOOMY_DISPLAY_installed LOOMY_DISPLAY_removed
  export LOOMY_DISPLAY_updated LOOMY_DISPLAY_selected LOOMY_DISPLAY_manual LOOMY_DISPLAY_reset LOOMY_DISPLAY_unknown
  export LOOMY_DISPLAY_relay_manual LOOMY_DISPLAY_returned
}

read -r -d '' AI_DISPLAY_CONTEXT_PERL <<'PERL' || true
use utf8;
package Loomy::DisplayContext;
use Encode ();
my (%labels,%users,%starts,@start_order,$loaded,$label_signature);
sub text { defined($_[0]) && !ref($_[0]) ? "$_[0]" : "" }
sub structural { text($_[0]{content_policy}) eq "structural-v1" }
sub managed { structural($_[0]) || ref($_[0]{label_ref}) eq "HASH" || ref($_[0]{label_refs}) eq "HASH" }
sub refresh { %labels=(); %users=(); $loaded=0; $label_signature=undef }
sub ui {
  my ($key,$fallback)=@_; my $v=$ENV{"LOOMY_DISPLAY_$key"}; return $fallback unless defined($v);
  return Encode::is_utf8($v) ? $v : Encode::decode("UTF-8",$v,Encode::FB_DEFAULT());
}
sub key {
  my ($e)=@_; return join("|",map {text($_)} ($e->{tool}//$e->{family}//"",$e->{session}//"",$e->{id}//""));
}
sub clean {
  my $s=text($_[0]); $s =~ s/[\x00-\x1f\x7f|]/ /g; if (utf8::is_utf8($s)) { $s =~ s/[\x{80}-\x{9f}]/ /g } else { $s =~ s/\xc2[\x80-\x9f]/ /g }; return $s;
}
sub scope_key { join("|",map {text($_[0]{$_})} qw(project_id target_kind target_id attempt_id)) }
sub load_labels {
  # A bounded validated index is shared by all rows in one frame/sampler. Only
  # new input checks the signature; idle frames do no store work.
  my @s=stat(($ENV{LOOMY_DISPLAY_ROOT}//"")."/.loomy/logs/display-context-v1.jsonl");
  my $sig=join(":",@s ? @s[0,1,7,9,10] : ("-"));
  return if $loaded && defined($label_signature) && $sig eq $label_signature;
  %labels=(); %users=(); $loaded=1; $label_signature=$sig;
  return unless @s;
  eval {
    require $ENV{LOOMY_DISPLAY_POLICY_LIB};
    my $ctx=Loomy::ContentPolicy::_context($ENV{LOOMY_DISPLAY_ROOT},0); return unless $ctx && $ctx->{logs};
    my $rows=Loomy::ContentPolicy::_in_context($ctx,sub {
      my ($raw)=Loomy::ContentPolicy::_read("display-context-v1.jsonl",1048576);
      Loomy::ContentPolicy::_rows($raw,$ctx->{project_id});
    });
    for my $r (@$rows) {
      $labels{$r->{label_id}}=$r;
      $users{scope_key($r)}=$r if $r->{source} eq "explicit-user";
    }
    1;
  } or do { %labels=(); %users=() };
}
sub label {
  my ($ref)=@_; return unless ref($ref) eq "HASH" && keys(%$ref)==6 && text($ref->{version}) eq "1";
  load_labels(); my $r=$labels{text($ref->{label_id})}; return unless $r;
  return if grep {text($ref->{$_}) ne text($r->{$_})} qw(version project_id target_kind target_id attempt_id label_id);
  return $r;
}
sub role {
  my ($e,$start)=@_; $start//={};
  my $role=text($e->{role}) || text($start->{role});
  return $role unless managed($e) || managed($start);
  my $agent_type=text($e->{agent_type}) || text($start->{agent_type});
  return $role if $agent_type eq "loomy-$role";
  return $agent_type if $agent_type =~ /\A[A-Za-z0-9_.-]{1,40}\z/;
  return $role;
}
sub scoped_label {
  my ($e,$ref)=@_; return unless ref($ref) eq "HASH";
  my $kind=text($ref->{target_kind}); my $target=text($ref->{target_id});
  my @ids=$kind eq "agent" ? ($e->{agent_id},$e->{id})
    : $kind eq "delegation" ? ($e->{id},$e->{turn_id})
    : $kind eq "session" ? ($e->{session})
    : $kind eq "task" && ref($e->{task_ref}) eq "HASH" ? ($e->{task_ref}{target_id}) : ();
  return unless grep {length(text($_)) && text($_) eq $target} @ids;
  my @attempts;
  if (length(text($e->{attempt_id}))) { @attempts=($e->{attempt_id}) }
  elsif ($kind eq "agent") { @attempts=($target) }
  elsif ($kind eq "session") { @attempts=($e->{session}) }
  elsif ($kind eq "task") { @attempts=($e->{task_ref}{attempt_id}) }
  else { @attempts=($e->{session},$e->{id},$e->{turn_id}) }
  return unless grep {length(text($_)) && text($_) eq text($ref->{attempt_id})} @attempts;
  return label($ref);
}
sub user_label {
  my ($e,$start)=@_; load_labels(); return unless keys %users;
  my $scope={%$start,%$e};
  for my $row ($e,$start) {
    for my $ref ($row->{label_ref},ref($row->{label_refs}) eq "HASH" ? values %{$row->{label_refs}} : ()) {
      my $r=scoped_label($scope,$ref); next unless $r;
      return $users{scope_key($r)} if $users{scope_key($r)};
    }
    my $agent=text($row->{agent_id}); my $id=text($row->{id});
    for my $r (values %users) {
      next unless ($r->{target_kind} eq "agent" && $r->{target_id} eq ($agent||$id) && $r->{attempt_id} eq ($agent||$id))
        || ($r->{target_kind} eq "delegation" && $r->{target_id} eq $id && $r->{attempt_id} eq (text($row->{attempt_id})||text($row->{session})||$id));
      my %ref=map {$_=>$r->{$_}} qw(version project_id target_kind target_id attempt_id label_id);
      return $r if scoped_label($scope,\%ref);
    }
  }
  return;
}
sub label_title {
  my ($e,$start)=@_; $start//=$starts{key($e)}//{};
  return unless managed($e) || managed($start);
  my $scope={%$start,%$e};
  my $user=user_label($e,$start); return clean($user->{text}) if $user;
  # A deliberately supplied title wins over automatic native identity parts.
  for my $row ($e,$start) {
    my $r=scoped_label($scope,$row->{label_ref});
    return clean($r->{text}) if $r && $r->{source} =~ /\A(?:explicit-user|explicit-lead|claude-description)\z/;
  }
  my @parts;
  for my $part (qw(nickname role slug)) {
    my $source=$part eq "slug" ? "codex-path-slug" : "codex-$part";
    for my $row ($e,$start) {
      my $refs=$row->{label_refs}; next unless ref($refs) eq "HASH";
      my $r=scoped_label($scope,$refs->{$part}); next unless $r && $r->{source} eq $source;
      push @parts,clean($r->{text}); last;
    }
  }
  return join(" ",@parts) if @parts;
  for my $row ($e,$start) { my $r=scoped_label($scope,$row->{label_ref}); return clean($r->{text}) if $r }
  return;
}
sub has_label { my $title=label_title(@_); return defined($title) && length($title) ? 1 : 0 }
sub fallback { (managed($_[0]) || managed($_[1]//{})) && !has_label(@_) ? 1 : 0 }
sub title {
  my ($e,$start)=@_; $start//=$starts{key($e)}//{};
  return text(defined($e->{task}) && !ref($e->{task}) ? $e->{task} : $start->{task})
    unless managed($e) || managed($start);
  my $label=label_title($e,$start); return $label if defined($label) && length($label);
  # Legacy excerpts remain readable; a structural event never trusts a stray task.
  return text($e->{task}//$start->{task}) unless structural($e) || structural($start);
  my $role=text($e->{role}) || text($start->{role});
  my $mission=$role =~ /\A(?:architect|debugger|security|reviewer|developer|executor|explorer|documenter)\z/
    ? ui($role,undef) : undef;
  return sprintf(ui("ROLE","Role: %s"),$mission) if defined($mission) && length($mission);
  return ui("UNAVAILABLE","context unavailable");
}
sub reason {
  my ($e)=@_; return text($e->{reason}) unless managed($e);
  my $code=text($e->{reason_code});
  if (text($e->{type}) =~ /\Alead_(?:failover|return)\z/) {
    my ($w,$p)=(text($e->{quota_window}),text($e->{used_percent}));
    return "$w $p %" if $w =~ /\A(?:5h|7d|daily|weekly|session)\z/
      && $p =~ /\A\d+(?:\.\d+)?\z/ && $p<=100;
    return ui("reset","quota back") if $code =~ /\A(?:reset|available)\z/;
    return $code eq "manual" ? ui("relay_manual","manual") : (ui("UNAVAILABLE","context unavailable"));
  }
  $code="selected" if $code eq "catalog";
  $code="unknown" unless $code =~ /\A(?:installed|removed|updated|selected|manual)\z/;
  return ui($code,ui("unknown","unknown"));
}
sub cells {
  my ($g,$w)=(shift,0);
  for my $c (split //,$g) { next if $c=~/[\p{M}\p{Cf}\p{Emoji_Modifier}]/; $w+=$c=~/[\p{East_Asian_Width=Wide}\p{East_Asian_Width=Fullwidth}]/ ? 2 : 1 }
  $w=2 if $w && $g=~/[\p{Emoji_Presentation}\p{Regional_Indicator}\x{fe0f}\x{20e3}]/;
  return $w;
}
# Width is terminal cells (wide = 2, combining = 0), cut on whole graphemes; ASCII is unchanged.
sub clip {
  my ($s,$width,$ellipsis)=@_; $s=text($s); my @g=$s=~/\X/g; my ($total,$used,$out)=(0,0,"");
  $total+=cells($_) for @g;
  return $s if $total<=$width;
  my $room=$width-($ellipsis ? 1 : 0);
  for my $g (@g) { my $w=cells($g); last if $used+$w>$room; $out.=$g; $used+=$w }
  return $out.($ellipsis ? "…" : "");
}
sub prepare {
  my ($e)=@_; return $e unless ref($e) eq "HASH";
  my $key=key($e); my $type=text($e->{type});
  if ($type eq "delegation_start") {
    push @start_order,$key unless exists $starts{$key}; $starts{$key}=$e;
    delete $starts{shift @start_order} while @start_order>4096;
  }
  return $e unless managed($e);
  my %v=%$e;
  if ($type =~ /\A(?:delegation(?:_start|_activity)?|agent_(?:link|alias|closed)|session_observed)\z/) {
    $v{task}=title($e); $v{role}=role($e,$starts{$key});
    if (($ENV{LOOMY_DISPLAY_FORMAT}//"") =~ /\A(?:pretty|status)\z/) {
      my $width=$ENV{LOOMY_DISPLAY_FORMAT} eq "pretty" ? ($type eq "delegation_start" ? 48 : 36) : ($type eq "delegation_start" ? 60 : 40);
      $v{display_task}=clip($v{task},$width,1);
    }
  }
  if ($type eq "request") {
    $v{excerpt}=title($e);
    $v{excerpt}=clean($e->{id})." · ".$v{excerpt} if $v{excerpt} eq (ui("UNAVAILABLE","context unavailable"));
  }
  $v{reason}=reason($e) if $type =~ /\A(?:skill|lead_failover|lead_return)\z/;
  return \%v;
}
# The old session-log path and the persistent sampler share this formatter.
# Enhanced native log coalescing stays in ai_journal_display_events below.
sub session_row {
  my ($raw)=@_; my $e=prepare($raw); my $ty=text($e->{type});
  my ($who,$what,$extra)=("","","");
  my $model=text($e->{model}); my $task=text($e->{task});
  my $duration=text($e->{duration_s}); $duration=0 unless $duration =~ /\A\d+(?:\.\d+)?\z/;
  if ($ty eq "delegation_start") {($who,$what,$extra)=(text($e->{role}),"start","$model · ".(managed($raw) ? clip($task,52,0) : substr($task,0,52)))}
  elsif ($ty eq "delegation") {
    my $oc=text($e->{outcome}); my $status=text($e->{status});
    $what=$status eq "ok" ? ($oc =~ /\A(?:partial|blocked)\z/ ? $oc : "done") : "failed";
    $what=$status if managed($raw) && $status =~ /\A(?:paused|handed_over|interrupted)\z/;
    $what="handed over" if $what eq "handed_over";
    $extra=($duration>=60 ? int($duration/60)." min ".($duration%60)." s" : "$duration s")." · $model";
    $extra.=" · ⇄ ".text($e->{failover_from}) if text($e->{failover_from}) ne "";
    $extra.=" · $task" if managed($raw) && length($task);
    $who=text($e->{role});
  }
  elsif ($ty eq "request" && managed($raw)) {($who,$what,$extra)=("lead","request",text($e->{excerpt}))}
  elsif ($ty eq "advisor") {($who,$what,$extra)=("advisor","consulted",(text($e->{calls})||0)." × $model · ".int((text($e->{tokens_in})||0)/1000)."k")}
  elsif ($ty =~ /\A(?:phase|task_phase|audit_phase)\z/) {my $mode=$ty; $mode =~ s/_?phase$//; ($who,$what,$extra)=("phase",text($e->{phase}),$mode)}
  elsif ($ty eq "session") {($who,$what,$extra)=("session",text($e->{event}),text($e->{tool}))}
  elsif ($ty eq "skill") {($who,$what,$extra)=("skills",text($e->{event}),text($e->{name})." · ".substr(text($e->{reason}),0,52))}
  elsif ($ty eq "usage" && text($e->{scope}) eq "lead") {($who,$what,$extra)=("lead","replied",(text($e->{messages})||0)." msg · $model")}
  elsif ($ty =~ /\Alead_(failover|return)\z/ && managed($raw)) {($who,$what,$extra)=("lead",$1 eq "failover" ? "handed over" : ui("returned","returned"),text($e->{master})." → ".text($e->{acting})." · ".reason($raw))}
  return unless length($who); return [map {clean($_)} (text($e->{ts}),$who,$what,$extra)];
}
# Preserve the historical awk parser byte-for-byte for unmarked journals,
# including its escaped-string cuts. New structural rows use decoded JSON above.
sub legacy_session_row {
  my ($raw)=@_; my $field=sub {my $k=shift; return $raw =~ /"\Q$k\E":"([^"]*)"/ ? $1 : ""};
  my $num=sub {my $k=shift; return $raw =~ /"\Q$k\E":([0-9.]+)/ ? $1 : "0"};
  my ($who,$what,$extra)=("","",""); my $dot=Encode::encode("UTF-8"," · ");
  if ($raw =~ /"type":"delegation_start"/) {($who,$what,$extra)=($field->("role"),"start",$field->("model").$dot.substr($field->("task"),0,52))}
  elsif ($raw =~ /"type":"delegation",/) {
    my ($st,$oc)=($field->("status"),$field->("outcome")); my $d=0+$num->("duration_s");
    ($who,$what)=($field->("role"),$st eq "ok" ? ($oc =~ /\A(?:partial|blocked)\z/ ? $oc : "done") : "failed");
    $extra=($d>=60 ? int($d/60)." min ".($d%60)." s" : "$d s").$dot.$field->("model");
    $extra.=$dot.Encode::encode("UTF-8","⇄ ").$field->("failover_from") if length($field->("failover_from"));
  }
  elsif ($raw =~ /"type":"advisor"/) {($who,$what,$extra)=("advisor","consulted",$num->("calls").Encode::encode("UTF-8"," × ").$field->("model").$dot.int($num->("tokens_in")/1000)."k")}
  elsif ($raw =~ /"type":"(?:phase|task_phase|audit_phase)"/) {my $ty=$field->("type"); $ty =~ s/_?phase$//; ($who,$what,$extra)=("phase",$field->("phase"),$ty)}
  elsif ($raw =~ /"type":"session"/) {($who,$what,$extra)=("session",$field->("event"),$field->("tool"))}
  elsif ($raw =~ /"type":"skill"/) {($who,$what,$extra)=("skills",$field->("event"),$field->("name").$dot.substr($field->("reason"),0,52))}
  elsif ($raw =~ /"type":"usage"/ && $field->("scope") eq "lead") {($who,$what,$extra)=("lead","replied",$num->("messages")." msg".$dot.$field->("model"))}
  else { return }
  return [$field->("ts"),$who,$what,$extra];
}
package main;
PERL

ai_display_context_events() {
  ai_display_context_init "$1"
  LOOMY_DISPLAY_FORMAT="${2:-}" perl -MJSON::PP -e "$AI_DISPLAY_CONTEXT_PERL"'
    $|=1; my $json=JSON::PP->new->canonical->utf8;
    while (<STDIN>) {
      my $raw=$_; my $e=eval {decode_json($raw)};
      next unless ref($e) eq "HASH";
      my $v=Loomy::DisplayContext::prepare($e);
      print $v==$e ? $raw : $json->encode($v)."\n";
    }
  '
}

# ai_task_title <normalized title> <columns>: truncate only at a word boundary.
ai_task_title() {
  local title="$1" width="$2" cut
  AI_TASK_TITLE="$title"
  if (( width < 2 )); then AI_TASK_TITLE=""; return 0; fi
  if (( ${#title} > width )); then
    cut="${title:0:$(( width - 1 ))}"
    # A space just beyond the cut already completes the last word.
    if [[ "${title:$(( width - 1 )):1}" != ' ' ]]; then
      if [[ "$cut" == *' '* ]]; then cut="${cut% *}"; else cut=""; fi
    fi
    cut="${cut% }"; AI_TASK_TITLE="${cut}…"
  fi
}

ai_display_duration() {
  local d="${1%.*}"
  [[ "$d" =~ ^[0-9]+$ ]] || d=0
  if (( d >= 3600 )); then printf -v AI_DURATION '%d h %02d' $(( d / 3600 )) $(( d % 3600 / 60 ))
  else printf -v AI_DURATION '%d:%02d' $(( d / 60 )) $(( d % 60 )); fi
}

# Turn lifecycle labels do not confer review approval or change stored outcomes.
ai_native_end_label() {
  case "$1" in ok) AI_NATIVE_END="done" ;; interrupted) AI_NATIVE_END=interrupted ;; error) AI_NATIVE_END=failed ;; *) AI_NATIVE_END=idle ;; esac
}

# Tree/watch opt into this formatter; ai_session_log_rows keeps its existing reveal cursor.
ai_journal_display_events() {
  local display_root="${2:-${LOOMY_DISPLAY_ROOT:-}}"
  [[ "$1" != */.loomy/logs/* ]] || display_root="${1%/.loomy/logs/*}"
  ai_display_context_init "$display_root"
  ai_journal_tail "$1" 4000 | ai_journal_canonical | tail -n 400 | perl -MJSON::PP -MErrno=EPERM -MPOSIX=strftime -e "$AI_TITLE_PERL$AI_DISPLAY_CONTEXT_PERL"'
    binmode STDOUT, ":encoding(UTF-8)";
    my %display_suffix;
    sub duration { my $d=text($_[0]); return "—" unless $d =~ /^\d+(?:\.\d+)?$/; $d=int($d); return $d>=3600 ? sprintf("%d h %02d",$d/3600,$d%3600/60) : sprintf("%d:%02d",$d/60,$d%60) }
    sub alive { my $p=$_[0]//0; return $p =~ /^\d+$/ && $p>1 && (kill(0,$p) || $! == EPERM) }
    sub text { defined $_[0] && !ref($_[0]) ? "$_[0]" : "" }
    sub task_title {
      my ($e,$start)=@_; $start//={}; my $title=Loomy::DisplayContext::title($e,$start);
      return ai_title($title) unless Loomy::DisplayContext::managed($e) || Loomy::DisplayContext::managed($start);
      if ((native($e) || native($start)) && Loomy::DisplayContext::fallback($e,$start)) {
        my $identity=text($e->{agent_id}) || text($start->{agent_id}) || text($e->{id});
        $title.=" · ".($display_suffix{$identity}//$identity) if length($identity);
      }
      return $title;
    }
    sub session_key { my $e=$_[0]; return text($e->{tool}//$e->{family})."|".(text($e->{session}) || "pid".text($e->{owner_pid}//$e->{pid}//0)) }
    sub agent_key { my $e=$_[0]; return session_key($e)."|".text($e->{parent_session})."|".(text($e->{agent_id}) || text($e->{id})) }
    sub native { text($_[0]{bridge}) =~ /^(codex|claude)-native$/ }
    sub owner_key {
      my $e=$_[0]; my $pid=text($e->{owner_pid}//$e->{pid});
      return "" unless $pid =~ /^\d+$/ && $pid>1;
      return text($e->{tool}//$e->{family})."|$pid";
    }
    sub owner_closed {
      my ($e,$ends,$opens,$index)=@_; my $key=owner_key($e); return 0 if $key eq "";
      my $session=text($e->{session}); my $slot="$key|$session";
      my $end=$ends->{"$key|"}//0; $end=$ends->{$slot} if ($ends->{$slot}//0)>$end;
      return 0 unless $end;
      my $open=$opens->{$slot}; return 1 unless $open && $open->{index}>$end;
      # Reopening does not revive observations from the preceding owner lifetime.
      return 1 if $index<$open->{index};
      return text($e->{ts}) lt $open->{ts};
    }
    my (@events,%done,%sessions,%starts,%activity,%agents,%owner_ends,%owner_opens);
    while (<STDIN>) { my $e=eval { decode_json($_) }; push @events,$e if ref($e) eq "HASH" }
    # Raw Claude hooks and normalized transcript evidence describe the same execution.
    my (%normalized,%aliased);
    for my $e (@events) {
      next unless text($e->{bridge}) eq "claude-native";
      $normalized{text($e->{session})."|".text($e->{turn_id})}=1 if text($e->{turn_id}) ne "";
      $aliased{text($e->{alias_id})}=1 if text($e->{type}) eq "agent_alias";
    }
    @events=grep { !(text($_->{bridge}) eq "subagent" && $normalized{text($_->{session})."|".text($_->{id})}) && !$aliased{text($_->{id})} } @events;
    my %identities=map {(text($_->{agent_id}) || text($_->{id}))=>1} @events;
    delete $identities{""}; my @identities=keys %identities;
    for my $id (@identities) {
      my $n=8;
      ++$n while $n<length($id) && grep {$_ ne $id && substr($_,-$n) eq substr($id,-$n)} @identities;
      $display_suffix{$id}=substr($id,-$n);
    }
    for my $i (0..$#events) {
      my $e=$events[$i]; my $id=text($e->{id}); my $ts=text($e->{ts});
      if (($e->{type}//"") eq "session") {
        my $key=session_key($e);
        if (($e->{event}//"") eq "start") { $sessions{$key}={%$e,ended=>0} }
        elsif ($sessions{$key}) { $sessions{$key}{ended}=1 }
        my $owner=owner_key($e);
        if ($owner ne "") {
          my $slot=$owner."|".text($e->{session});
          $owner_opens{$slot}={index=>$i+1,ts=>$ts} if text($e->{event}) eq "start";
          $owner_ends{$slot}=$i+1 if text($e->{event}) eq "end";
        }
      }
      $done{$id}=1 if ($e->{type}//"") eq "delegation" && $id ne "";
      $starts{$id}=$e if ($e->{type}//"") eq "delegation_start" && $id ne "";
      if (native($e) && $id ne "" && text($e->{type}) =~ /^(delegation_start|delegation_activity)$/) {
        if (text($e->{type}) eq "delegation_activity") {
          $activity{$id}=$i if !exists $activity{$id} || $ts ge text($events[$activity{$id}]{ts});
        }
      }
    }
    # Closed turns must not hide the same agents newer active turn, even if stale activity was appended late.
    for my $e (@events) {
      my $id=text($e->{id}); my $ts=text($e->{ts});
      next unless native($e) && $id ne "" && !$done{$id} && text($e->{type}) =~ /^(delegation_start|delegation_activity)$/;
      my $key=agent_key($e);
      $agents{$key}={id=>$id,ts=>$ts} if !$agents{$key} || $ts ge $agents{$key}{ts};
    }
    for my $i (0..$#events) {
      my $e=$events[$i];
      next unless ref($e) eq "HASH";
      my ($ty,$who,$what,$extra)=(text($e->{type}),"","","");
      my $id=text($e->{id}); my $start=$starts{$id}//{};
      my $model=text($e->{model}); my $role=Loomy::DisplayContext::role($e,$start);
      if ($ty eq "delegation_start") {
        next if native($e) && ($done{$id} || exists $activity{$id});
        my $bridge=$e->{bridge}//""; my $interrupted=0;
        if (!($e->{id}//"") || !$done{$e->{id}}) {
          if ($bridge eq "subagent") { my $session=$sessions{session_key($e)}; $interrupted=($session && $session->{ended}) || !alive($e->{pid}) }
          else { $interrupted=(native($e) && ($e->{schema}//0)==2 && !text($e->{owner_pid})) ? 0 : !alive(native($e) ? $e->{owner_pid} : $e->{pid}) }
        }
        $who=$role; $what=$interrupted ? "interrupted" : (native($e) ? "running" : "start"); $extra="$model · ".task_title($e,$start)
      }
      elsif ($ty eq "delegation") {
        $who=$role || text($start->{role}); $model ||= text($start->{model}); my $oc=text($e->{outcome});
        $what=$oc eq "unknown" ? "unknown" : (($e->{status}//"") eq "ok" ? ($oc =~ /^(partial|blocked)$/ ? $oc : "done") : "failed");
        $what=(text($e->{status}) eq "ok" ? "done" : text($e->{status}) eq "error" ? "failed" : "idle") if $oc eq "unknown" && native($e);
        $what="handed over" if text($e->{status}) eq "handed_over";
        $what="paused" if text($e->{status}) eq "paused";
        $what="interrupted" if $oc eq "interrupted" || text($e->{status}) eq "interrupted";
        $extra=duration($e->{duration_s})." · $model";
        $extra.=" · until ".strftime("%H:%M",localtime($e->{resume_at})) if text($e->{status}) eq "paused" && ($e->{resume_at}//"") =~ /^\d+$/; $extra.=" · ⇄ $e->{failover_from}" if $e->{failover_from};
        my $task=task_title($e,$start); $extra.=" · $task" if $task ne "";
      }
      elsif ($ty eq "delegation_activity" && native($e)) {
        next if $done{$id} || !exists $activity{$id} || $activity{$id}!=$i || $agents{agent_key($e)}{id} ne $id;
        my $owner=$e->{owner_pid}//$start->{owner_pid};
        my $observed={%$start,%$e,owner_pid=>$owner,session=>($e->{session}//$start->{session}),tool=>($e->{tool}//$e->{family}//$start->{tool}//$start->{family})};
        next if (!alive($owner) && !(($e->{schema}//0)==2 && !text($owner))) || owner_closed($observed,\%owner_ends,\%owner_opens,$i+1);
        next unless text($e->{ts}) =~ /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/;
        $what=text($e->{state}//$e->{activity}); next unless $what eq "running" || $what eq "waiting";
        $who=$role || text($start->{role}) || "agent";
        $model ||= text($start->{model});
        my $task=task_title($e,$start);
        $task="$who ".substr(text($e->{agent_id}) || $id,-8) if $task eq "";
        $extra="$model · $task";
      }
      elsif ($ty eq "agent_closed" && text($e->{bridge}) eq "codex-native") {
        $who=$role || "agent"; $what="done"; $extra=task_title($e,$start);
      }
      elsif ($ty eq "session_observed") { $who="session"; $what=text($e->{state}) || "unknown"; $extra=text($e->{tool})." ".text($e->{surface})." ".substr(text($e->{session}),-8) }
      elsif ($ty eq "request") { $who="lead"; $what="request"; $extra=Loomy::DisplayContext::managed($e) ? Loomy::DisplayContext::prepare($e)->{excerpt} : ai_title($e->{excerpt}) }
      elsif ($ty eq "advisor") { $who="advisor"; $what="consulted"; $extra=($e->{calls}//0)." × $model · ".int(($e->{tokens_in}//0)/1000)."k" }
      elsif ($ty =~ /^(task_|audit_)?phase$/) { $who="phase"; $what=$e->{phase}//""; ($extra=$ty)=~s/_?phase$// }
      elsif ($ty eq "session") { $who="session"; $what=$e->{event}//""; $extra=$e->{tool}//"" }
      elsif ($ty eq "skill") { $who="skills"; $what=$e->{event}//""; $extra=($e->{name}//"")." · ".substr(Loomy::DisplayContext::reason($e),0,52) }
      elsif ($ty =~ /^lead_(failover|return)$/ && Loomy::DisplayContext::managed($e)) { $who="lead"; $what=$1 eq "failover" ? "handed over" : Loomy::DisplayContext::ui("returned","returned"); $extra=text($e->{master})." → ".text($e->{acting})." · ".Loomy::DisplayContext::reason($e) }
      elsif ($ty eq "usage" && ($e->{scope}//"") eq "lead") { $who="lead"; $what="replied"; $extra=($e->{messages}//0)." msg · $model" }
      else { next }
      my @row=(text($e->{ts}),$who,$what,$extra); for (@row) { s/[\x00-\x1f\x7f|]/ /g; if (utf8::is_utf8($_)) { s/[\x{80}-\x{9f}]/ /g } else { s/\xc2[\x80-\x9f]/ /g } } print join("|",@row),"\n";
    }
  '
}

# ai_session_state <root>: "open|<local time>|<tool>", "closed|<time>|<tool>" or "none".
# A session is open when it started, hasn't ended, and its process (Claude Code or Codex) is still running.
# ai_ts_epoch <ISO UTC timestamp>: seconds since 1970 (macOS or GNU date), empty when unreadable.
ai_ts_epoch() {
  local stamp="${1%%.*}"; [[ "$1" != *.* ]] || stamp="${stamp}Z"
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null || date -u -d "$stamp" +%s 2>/dev/null || true
}

ai_session_state() {
  local j line pid ts tool state="none" s hhmm
  j="$(ai_journal_file "$1")"
  [[ -s "$j" ]] || { echo "none"; return 0; }
  # US (0x1f) separates the fields and the awk keeps only plain characters in the text ones: journal text can
  # neither shift the columns nor reach arithmetic or the terminal; the pid is validated here.
  while IFS=$'\037' read -r kind pid ts tool; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == "open" ]]; then
      if ai_pid_ok "$pid" && kill -0 "$pid" 2>/dev/null; then state="open|$ts|$tool"; break; fi
    elif [[ "$state" == "none" ]]; then state="closed|$ts|$tool"; fi
  done < <(awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/[^A-Za-z0-9_.:+ -]/, "", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    BEGIN { US = "\037" }
    /"type":"session"/ {
      key = field("session"); if (key == "") key = "pid" num("pid")
      # A resumed session (claude --continue) keeps its id: a new start cancels the previous end.
      if (index($0, "\"event\":\"start\"")) { n++; order[n] = key; start[key] = num("pid") US field("ts") US field("tool"); delete ended[key] }
      else { ended[key] = field("ts") US field("tool"); last_end = field("ts") US field("tool") }
    }
    END {
      for (i = n; i >= 1 && i > n - 10; i--) if (!(order[i] in ended)) print "open" US start[order[i]]
      if (last_end != "") print "end" US US last_end
    }' "$j" 2>/dev/null)
  [[ "$state" == "none" ]] && { echo "none"; return 0; }
  ts="$(printf '%s' "$state" | cut -d'|' -f2)"
  s="$(ai_ts_epoch "$ts")"
  hhmm="$( [[ -n "$s" ]] && { date -r "$s" +%H:%M 2>/dev/null || date -d "@$s" +%H:%M 2>/dev/null; } )"
  echo "$(printf '%s' "$state" | cut -d'|' -f1)|${hhmm:-?}|$(printf '%s' "$state" | cut -d'|' -f3)"
}

# ai_delegation_id: short delegation id, links its start event to its end event.
ai_delegation_id() { printf 'd%s%05d' "$(date +%s)" "$$"; }

# Native Claude agents share the lead's lifetime; Claude supplies no child pid at PreToolUse.
ai_journal_agent_start() {
  local root="$1" input="$2" pid="$3" role id sid bg model effort explicit_model requested=false sandbox offroute p i comm line n
  ai_journal_enabled "$root" || return 0
  IFS='|' read -r role id sid bg explicit_model < <(printf '%s' "$input" | perl -MJSON::PP -e '
    local $/; my $d=eval { decode_json(<STDIN>) }; exit unless ref($d) eq "HASH";
    my $t=$d->{tool_input} // {};
    my $m=$t->{model}; $m="" if !defined($m) || ref($m);
    my @v=($t->{subagent_type}, $d->{tool_use_id}, $d->{session_id}, $t->{run_in_background}?"true":"false", $m);
    for (@v) { $_="" if !defined($_) || ref($_); s/[\x00-\x1f|]/ /g } print join("|", @v), "\n";' 2>/dev/null)
  [[ -n "$id" && -n "$role" ]] || return 0
  case " $AI_ROLES " in *" ${role#loomy-} "*) role="${role#loomy-}" ;; esac
  ai_detect_env "$root"; ai_resolve lead "$AI_ENV" "$AI_PROFILE"
  model="$R_MODEL"; effort="$R_EFFORT"
  # Only a basename can select a front matter file, never a hook-supplied path.
  if [[ "$role" =~ ^[a-zA-Z0-9_-]+$ && -f "$root/.claude/agents/$role.md" ]]; then
    n=0
    while IFS= read -r line; do
      if [[ "$line" == --- ]]; then n=$(( n + 1 )); (( n == 2 )) && break; continue; fi
      (( n == 1 )) || break
      case "$line" in model:*) model="${line#model:}" ;; effort:*) effort="${line#effort:}" ;; esac
    done <"$root/.claude/agents/$role.md"
    model="${model#"${model%%[![:space:]]*}"}"; model="${model//\"/}"; model="${model//\'/}"
    effort="${effort#"${effort%%[![:space:]]*}"}"; effort="${effort//\"/}"; effort="${effort//\'/}"
  fi
  if [[ -n "$explicit_model" ]]; then model="$explicit_model"; requested=true; fi
  sandbox="read-only"; ai_role_writes "$role" && sandbox="workspace-write"
  offroute="$(ai_delegate_off_routing "$role" claude "$model" "$effort" "$sandbox")"
  p="$pid"; i=0
  while (( i < 16 )) && [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )); do
    comm="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "${comm##*/}" in claude|claude\ *) pid="$p"; break ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; i=$(( i + 1 ))
  done
  printf '%s' "$input" | perl -MJSON::PP -e '
    my ($module,$file,$body)=@ARGV; require $module;
    local $/; my $d=eval {decode_json(<STDIN>)}; exit unless ref($d) eq "HASH";
    my $e=decode_json("{$body}"); my $in=$d->{tool_input};
    my $description=ref($in) eq "HASH" ? $in->{description} : undef;
    $description=undef if ref($description);
    $e->{agent_type}=$in->{subagent_type} if ref($in) eq "HASH";
    Loomy::LiveState::journal_append($file,$e,undef,
      ["delegation",$e->{id},$e->{session},"claude-description",$description]);
  ' "$AI_LIVE_STATE_LIB" "$root/.loomy/logs/events.jsonl" "\"type\":\"delegation_start\",\"id\":$(ai_json_str "$id"),\"session\":$(ai_json_str "$sid"),\"pid\":$pid,\"bridge\":\"subagent\",\"role\":$(ai_json_str "$role"),\"family\":\"claude\",\"model\":$(ai_json_str "$model"),\"effort\":$(ai_json_str "$effort"),\"background\":$bg,\"requested\":$requested,\"off_routing\":$(ai_json_str "$offroute"),\"why\":\"\"" 2>/dev/null || true
}

# Tool returns give the stable tool-use/agent identity pair. A stop arriving first waits for that pair.
# No role-only matching: parallel agents of one role can finish in any order.
ai_journal_agent_stop() { ai_journal_agent_finish "$1" "$2" stop "$3" "${4:-}"; }
ai_journal_agent_return() { ai_journal_agent_finish "$1" "$2" "${3:-return}" 0 ""; }
ai_journal_agent_finish() {
  local root="$1" input="$2" mode="$3" offset="$4" result="$5"
  ai_journal_enabled "$root" || return 0
  printf '%s\0%s' "$input" "$result" | perl -MJSON::PP -MFcntl=O_RDWR,O_APPEND,O_NOFOLLOW -MPOSIX=strftime -MTime::Local=timegm -MIO::Handle -e '
    my ($module,$file,$mode,$offset)=@ARGV; require $module;
    local $/; my ($input,$result)=split /\0/,scalar(<STDIN>),2;
    my $d=eval { decode_json($input) }; exit unless ref($d) eq "HASH";
    my $sid=$d->{session_id}//""; my $id=$d->{tool_use_id}//"";
    my $r=ref($d->{tool_response}) eq "HASH" ? $d->{tool_response} : {};
    my $aid=$mode eq "stop" ? ($d->{agent_id}//"") : ($r->{agentId}//$r->{agent_id}//"");
    exit if ref($aid) || ref($sid) || ref($id);
    exit if $mode eq "stop" ? $aid eq "" : $id eq "";
    my $dir=$file; $dir =~ s{/[^/]+$}{};
    my $lock=Loomy::LiveState::journal_lock($dir,1) or exit;
    my $writer=Loomy::LiveState::content_writer(Loomy::LiveState::content_root($file)); exit unless $writer;
    sysopen my $f,$file,O_RDWR|O_APPEND|O_NOFOLLOW or exit; chmod 0600,$f or exit; seek $f,0,0 or exit;
    $/="\n"; my (%starts,%done,%links,%stops); my $actual_model;
    while (my $l=<$f>) {
      my $e=eval { decode_json($l) }; next unless ref($e) eq "HASH" && ($e->{session}//"") eq $sid;
      my $type=$e->{type}//"";
      $starts{$e->{id}}=$e if $type eq "delegation_start" && ($e->{bridge}//"") eq "subagent";
      $done{$e->{id}}=1 if $type eq "delegation";
      $links{$e->{agent_id}}=$e->{id} if $type eq "subagent_link";
      $stops{$e->{agent_id}}=$e if $type eq "subagent_stop";
    }
    # Usage has no session field; read only the just-recorded usage for this stop.
    if ($mode eq "stop") {
      seek $f,$offset,0;
      my $agent=eval {Loomy::ContentPolicy::_value("agent",$d->{agent_type},$writer->{policy}{project_id})};
      while (my $l=<$f>) { my $e=eval { decode_json($l) }; next unless ref($e) eq "HASH";
        $actual_model=$e->{model} if ($e->{type}//"") eq "usage" && ($e->{scope}//"") eq "subagent" && ($e->{agent}//"") eq ($agent//"");
      }
    }
    my $now=time; my $ts=strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($now));
    sub emit {
      my ($e)=@_;
      my $ok=eval {
        my $line=Loomy::LiveState::journal_event_line($writer,{ts=>$ts,session=>$sid,%$e}); return unless defined $line;
        print $f $line or die; $f->flush && $f->sync or die; 1;
      };
      warn "journal event skipped; hook append unavailable\n" unless $ok;
      return $ok;
    }
    sub outcome { my ($s)=@_; return $s =~ /(?:^|\n|\x1f)STATUS:\s*(done|partial|blocked)\b/ ? $1 : "" }
    my $stop;
    if ($mode eq "stop") {
      $id=$links{$aid}//"";
      exit if $id ne "" && $done{$id};
      $stop=$stops{$aid};
      unless ($stop) {
        $stop={type=>"subagent_stop",agent_id=>$aid,ended_at=>$now,outcome=>outcome($result || $d->{last_assistant_message}//""),model=>$actual_model};
        exit unless emit($stop);
      }
      exit if $id eq "";
    } else {
      exit unless $starts{$id};
      if ($aid ne "" && !exists $links{$aid}) { exit unless emit({type=>"subagent_link",agent_id=>$aid,id=>$id}); $links{$aid}=$id }
      exit if $done{$id};
      $stop=$stops{$aid} if $aid ne "";
      # A background launch returns before its agent finishes, including when Claude chose async execution.
      exit if $mode ne "failure" && !$stop && ($starts{$id}{background} || $r->{isAsync} || ($r->{status}//"") eq "async_launched");
    }
    my $s=$starts{$id}; exit unless $s;
    my @t=($s->{ts}//"") =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$/;
    my $started=@t ? eval {timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0])+($t[6]//0)} : undef;
    my $dur=defined($started) ? ($stop ? $stop->{ended_at} : $now)-$started : 0; $dur=0 if $dur<0;
    my $text=ref($r->{content}) eq "ARRAY" ? join("\n",map { ref($_) eq "HASH" ? ($_->{text}//"") : "" } @{$r->{content}}) : ($r->{content}//"");
    emit({type=>"delegation",id=>$id,agent_id=>$aid,bridge=>"subagent",family=>"claude",role=>$s->{role},agent_type=>$s->{agent_type},model=>($stop && $stop->{model} ? $stop->{model} : $s->{model}),effort=>$s->{effort},status=>($mode eq "failure" ? "error" : "ok"),duration_s=>$dur,task=>$s->{task},(exists($s->{label_ref}) ? (label_ref=>$s->{label_ref}) : ()),tokens_in=>0,tokens_cached=>0,tokens_out=>0,cost_usd=>0,cost_in=>"usage",outcome=>($stop ? $stop->{outcome} : outcome($text))});
  ' "$AI_LIVE_STATE_LIB" "$root/.loomy/logs/events.jsonl" "$mode" "$offset" 2>/dev/null || true
}

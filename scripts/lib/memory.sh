#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Authored STATE/Dead ends are independent of automatic delegation receipts.
# Automatic text lives only in the opted-in, bounded private-results-v1 store.
# Historical delegations are read-only and never migrated, chmodded or pruned.
# shellcheck source=content-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/content-policy.sh"

loomy_memory_dir() { printf '%s/.loomy/memory' "$1"; }

# Group launcher/hook starts for the current tool within five minutes. Journal
# projections and legacy rows have different key orders; only JSON values count.
loomy_memory_previous_tool() {
  [[ -s "$1/.loomy/logs/events.jsonl" ]] || return 0
  perl -e '
    require shift @ARGV;
    my @starts;
    while (<>) {
      my $e=eval {JSON::PP::decode_json($_)};
      next unless ref($e) eq "HASH" && ($e->{type}//"") eq "session" && ($e->{event}//"") eq "start";
      next unless ($e->{tool}//"") =~ /\A(?:claude|codex)\z/;
      my $at=Loomy::LiveState::epoch($e->{ts}); next unless $at;
      push @starts, [$at,$e->{tool}];
    }
    exit unless @starts>1;
    my $last=pop @starts;
    pop @starts while @starts && $starts[-1][1] eq $last->[1] && $last->[0]-$starts[-1][0]<=300;
    print $starts[-1][1] if @starts;
  ' "$(dirname "${BASH_SOURCE[0]}")/live-state.pl" "$1/.loomy/logs/events.jsonl" 2>/dev/null || true
}

# loomy_memory_state_init <root>: create STATE.md, or append its missing Dead ends section without rewriting it.
loomy_memory_state_init() {
  local d f
  d="$(loomy_memory_dir "$1")"; f="$d/STATE.md"
  [[ -L "$d" || -L "$f" ]] && return 0
  mkdir -p "$d" 2>/dev/null || return 0
  # Written for the models, read by the user if they like: English (fewer tokens than other languages for every model)
  # and telegraphic, whatever the documentation language.
  if [[ ! -e "$f" ]]; then
    printf '# Work state\n\n<!-- For the agents. English, telegraphic bullets, no prose; aim for 40 lines, keeping the latest three dead ends even over budget; replace what is outdated. Kept by the lead agent after each important step and before ending a session; given back at the start of every session, Claude Code or Codex. -->\n\n## Done\n\n## In progress\n\n## Decisions\n\n## Dead ends\n\n## Next\n\n## Open questions\n' >"$f" || return 0
  fi
  loomy_memory_state_migrate "$1"
  return 0
}

# loomy_memory_state_migrate <root>: readers may migrate and archive an existing STATE, never create one.
loomy_memory_state_migrate() {
  local d f
  d="$(loomy_memory_dir "$1")"; f="$d/STATE.md"
  [[ -f "$f" && ! -L "$d" && ! -L "$f" ]] || return 0
  # Append only. Preserve the existing bytes, including CRLF and a missing final newline.
  perl -MFcntl=:flock -MTime::HiRes=stat,utime -e '
    open my $f, "+<", $ARGV[0] or exit; flock($f, LOCK_EX) or exit;
    my @stat = stat($f);
    local $/; my $text = <$f> // "";
    exit if $text =~ /^## Dead ends[ \t]*\r?$/m;
    my $eol = $text =~ /\r\n/ ? "\r\n" : "\n";
    seek($f, 0, 2) or exit;
    print $f ($text eq "" || $text =~ /\n\z/ ? "" : $eol), $eol, "## Dead ends", $eol or exit;
    close($f) or exit; utime($stat[8], $stat[9], $ARGV[0]);
  ' "$f" 2>/dev/null || true
  loomy_memory_state_budget "$1"
  return 0
}

# loomy_memory_state_budget <root>: archive oldest dead ends until STATE fits 40 lines, keeping the latest three.
# Never discard other content; the lead must condense any remaining overflow. Save the archive before changing STATE.
loomy_memory_state_budget() {
  local d; d="$(loomy_memory_dir "$1")"
  [[ -L "$d" || -L "$d/STATE.md" || -L "$d/DEAD-ENDS.md" ]] && return 0
  perl -MFcntl=:flock -MTime::HiRes=stat,utime -e '
    my ($state, $archive) = @ARGV;
    open my $f, "+<", $state or exit; flock($f, LOCK_EX) or exit;
    my @stat = stat($f);
    my @lines = <$f>; exit if @lines <= 40;
    my ($dead, $entry, @entries);
    for my $i (0 .. $#lines) {
      if ($lines[$i] =~ /^## /) { $dead = $lines[$i] =~ /^## Dead ends[ \t]*\r?\n?$/; undef $entry; next }
      if ($dead && $lines[$i] =~ /^- \S/) { push @entries, [$i]; $entry = $#entries }
      elsif ($dead && defined($entry) && $lines[$i] =~ /^[ \t]+\S/) { push @{$entries[$entry]}, $i }
      else { undef $entry }
    }
    my (%move, $left); $left = @lines;
    for my $i (0 .. $#entries - 3) {
      last if $left <= 40;
      $move{$_} = 1 for @{$entries[$i]}; $left -= @{$entries[$i]};
    }
    exit unless %move;
    open my $a, "+>>", $archive or exit; flock($a, LOCK_EX) or exit;
    if (-s $a) { seek($a, -1, 2) or exit; read($a, my $last, 1) == 1 or exit; print $a "\n" if $last ne "\n" }
    else { print $a "# Archived dead ends\n\n" or exit }
    for my $i (0 .. $#lines) { next unless $move{$i}; print $a $lines[$i], ($lines[$i] =~ /\n\z/ ? "" : "\n") or exit }
    close($a) or exit;
    seek($f, 0, 0) or exit;
    for my $i (0 .. $#lines) { next if $move{$i}; print $f $lines[$i] or exit }
    truncate($f, tell($f)) or exit;
    close($f) or exit; utime($stat[8], $stat[9], $state);
  ' "$d/STATE.md" "$d/DEAD-ENDS.md" 2>/dev/null || true
  return 0
}

# Compatibility entry point for native subagent hooks. The backend rechecks the
# policy while holding T1's lock; task/result travel on stdin, never Perl argv.
loomy_memory_save() { ( set +eu; set +o pipefail; _lm_save "$@" ) >/dev/null; return 0; }
_lm_save() {
  local root="$1" format=""; shift
  # Native hooks already load the shared result classifier. Retain its typed
  # verdict even with capture off, without copying the answer into the receipt.
  if [[ "${4:-}" == ok ]] && declare -F ai_result_json >/dev/null && declare -F ai_delegation_format >/dev/null \
      && [[ "$(ai_delegation_format "$root")" == structured ]]; then
    format="$(ai_result_json "${2:-}" "${6:-}")"
  fi
  ( umask 077; printf '%s\0' "$@" "$format" | _lm_backend save-native "$root" "$$" ) >/dev/null || {
    t "result not saved / original task required" >&2; echo >&2
  }
  return 0
}
loomy_memory_capture_enabled() { _lm_backend enabled "$1"; }
loomy_memory_digest() { _lm_backend digest "$1" "${2:-5}" "${3:-}"; }
loomy_memory_count() { _lm_backend count "$1"; }
loomy_memory_unavailable_count() { _lm_backend unavailable-count "$1"; }
loomy_memory_show() { _lm_backend show "$1" "${2:-1}"; }
loomy_memory_legacy() { _lm_backend legacy "$1" "${2:-}"; }

# All new files use 0600/exclusive no-follow opens under umask 077. Existing
# historical directories keep their permissions; insecure new stores are refused.
_lm_backend() {
  local LM_NOT_RETAINED LM_OFF LM_ORIGINAL LM_FAILED LM_PRIVATE LM_ERROR LM_FULL LM_PAUSED LM_RUNNING
  tv LM_NOT_RETAINED "result not retained; consult authorized task artifact"
  tv LM_OFF "Private results: off · receipts available; new summaries not retained"
  tv LM_ORIGINAL "original task required to resume"
  tv LM_FAILED "result not saved / original task required"
  tv LM_PRIVATE "private result available"
  tv LM_ERROR "Content operation failed."
  tv LM_FULL "Private result store full: wait for active tasks or resume paused tasks; review loomy memory show N, then retry."
  tv LM_PAUSED "paused until %s · resumable: loomy memory show %s"
  tv LM_RUNNING "running"
  export LM_NOT_RETAINED LM_OFF LM_ORIGINAL LM_FAILED LM_PRIVATE LM_ERROR LM_FULL LM_PAUSED LM_RUNNING
  perl /dev/fd/3 "$LOOMY_CONTENT_POLICY_LIB" "$@" 3<<'PERL'
use strict;
use warnings;
use utf8;
binmode STDOUT, ':encoding(UTF-8)';
use Fcntl qw(:DEFAULT :mode O_NOFOLLOW O_NONBLOCK);
use JSON::PP ();
use POSIX qw(strftime);
use Encode qw(decode FB_CROAK);
use Time::HiRes qw(stat lstat);
require shift @ARGV;
my ($op,$root,@args)=@ARGV;
my $json=JSON::PP->new->utf8->canonical;
my $text_json=JSON::PP->new->canonical;
my ($ctx,$memory,$ms,$dir,$ds,$kind);
our $locked;
my %foreign;
my %message=map {$_=>decode('UTF-8',$ENV{$_})} grep {/\ALM_/} keys %ENV;
sub id { Loomy::ContentPolicy::_id($_[0]) }
sub scalar_text { defined($_[0]) && !ref($_[0]) }
sub ui { return $message{$_[0]} }
sub clean_text {
    my ($text,$limit)=@_;
    # Reuse the policy's complete ANSI/OSC, Cc/Cf and bidi removal. Collapsing
    # whitespace afterwards also handles Unicode separators and repeated spaces.
    $text=eval {Loomy::ContentPolicy::sanitize_label($text,1048576,4194304)} // '';
    $text=~s/\s+/ /g; return substr($text,0,$limit);
}
sub display_result {
    my ($text)=@_;
    $text=~s{(^[ \t]*[*_ -]*(?:SUMMARY|NEXT)[ \t]*[*_]*:[ \t]*)(.*?)(?=\r?\n[ \t]*[*_ -]*[A-Z]+[ \t]*[*_]*:|\z)}
        {$1.clean_text($2,1048576).($2=~/\n\z/ ? "\n" : '')}egims;
    return $text;
}
my $input_oversize=0;
sub read_input {
    my (@parts,%large); my $i=0; $parts[0]='';
    while (1) {
        my $n=sysread(STDIN,my $buffer,65536); die "memory input unavailable\n" unless defined $n;
        last unless $n;
        while (length($buffer)) {
            my $end=index($buffer,"\0");
            my $chunk=$end<0 ? $buffer : substr($buffer,0,$end);
            if (!$large{$i}) {
                if (length($parts[$i])+length($chunk)>1048576) {
                    $large{$i}=1; $input_oversize=1; $parts[$i]='';
                } else {$parts[$i].=$chunk}
            }
            last if $end<0;
            $buffer=substr($buffer,$end+1); die "invalid memory input\n" if ++$i>20; $parts[$i]='';
        }
    }
    return map {decode('UTF-8',$_,FB_CROAK)} @parts;
}
sub assert_dirs {
    Loomy::ContentPolicy::_assert_context($ctx);
    for my $pair (["$ctx->{root}/.loomy/memory",$ms,0],
                  ["$ctx->{root}/.loomy/memory/$kind",$ds,1]) {
        my @s=lstat($pair->[0]); my $old=$pair->[1];
        die "unsafe memory directory\n" unless @s && S_ISDIR($s[2]) && $s[4]==$<
            && $s[0]==$old->[0] && $s[1]==$old->[1] && !($s[2]&022)
            && (!$pair->[2] || ($s[2]&0777)==0700);
    }
}
sub in_store {
    my ($name,$create,$code)=@_; $kind=$name;
    my $cwd; sysopen $cwd,'.',O_RDONLY or die "memory unavailable\n";
    chdir $ctx->{loomy} or die "memory unavailable\n";
    if (!lstat('memory')) {return chdir($cwd) && undef unless $create; mkdir 'memory',0700 or die "memory unavailable\n"}
    ($memory,$ms)=Loomy::ContentPolicy::_dir('memory');
    chdir $memory or die "memory unavailable\n";
    if (!lstat($name)) {return chdir($cwd) && undef unless $create; mkdir $name,0700 or die "memory unavailable\n"}
    ($dir,$ds)=Loomy::ContentPolicy::_dir($name);
    die "unsafe memory directory\n" unless ($ds->[2]&0777)==0700;
    chdir $dir or die "memory unavailable\n";
    assert_dirs(); my $r=$code->(); assert_dirs();
    chdir $cwd or die "memory unavailable\n"; return $r;
}
sub atomic {
    my ($name,$raw,$before)=@_; assert_dirs();
    die "memory file changed\n" unless Loomy::ContentPolicy::_same_or_absent($before,Loomy::ContentPolicy::_private_stat($name));
    my $tmp=".$name.$$-".unpack('H*',Loomy::ContentPolicy::_random(8));
    sysopen my $h,$tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600 or die "memory write failed\n";
    my $ok=eval {
        print {$h} $raw or die "memory write failed\n";
        $h->flush && $h->sync or die "memory write failed\n";
        my $written=[stat($h)]; close $h or die "memory write failed\n";
        assert_dirs();
        die "memory file changed\n" unless Loomy::ContentPolicy::_same($written,Loomy::ContentPolicy::_private_stat($tmp))
            && Loomy::ContentPolicy::_same_or_absent($before,Loomy::ContentPolicy::_private_stat($name));
        rename $tmp,$name or die "memory write failed\n"; 1;
    }; my $err=$@; close $h if defined(fileno($h)); unlink $tmp unless $ok; die $err unless $ok;
}
sub ref_for {
    my ($r)=@_; return {version=>1,project_id=>$ctx->{project_id},target_kind=>'delegation',target_id=>$r->{id},attempt_id=>$r->{attempt_id}};
}
sub valid_ref {
    my ($v,$r,$label,$task)=@_;
    return ref($v) eq 'HASH' && keys(%$v)==($label ? 6 : 5)
        && Loomy::ContentPolicy::_scope($v,$ctx->{project_id}) && ($v->{version}//'') eq '1'
        && $v->{target_kind} eq 'delegation' && id($v->{target_id}) && id($v->{attempt_id})
        && ($task || ($v->{target_id} eq $r->{id} && $v->{attempt_id} eq $r->{attempt_id}))
        && (!$label || id($v->{label_id}));
}
sub out_of_scope {
    my ($r)=@_; return 0 unless ref($r) eq 'HASH';
    return scalar grep {ref($r->{$_}) eq 'HASH' && ($r->{$_}{project_id}//'') ne $ctx->{project_id}}
        qw(task_ref label_ref result_ref);
}
sub receipt {
    my ($r)=@_; die "invalid memory receipt\n" unless ref($r) eq 'HASH';
    my %keys=map {$_=>1} qw(version id attempt_id session_key role model effort sandbox status outcome started_at ended_at resume_at files_changed task_ref label_ref result_ref format review);
    die "invalid memory receipt\n" if grep {!$keys{$_}} keys %$r;
    die "invalid memory receipt\n" unless ($r->{version}//'') eq '1' && id($r->{id}) && id($r->{attempt_id});
    for (qw(role model effort sandbox status outcome format review)) {
        die "invalid memory receipt\n" unless scalar_text($r->{$_}) && length($r->{$_})<=128;
        die "invalid memory receipt\n" unless Loomy::ContentPolicy::_value($_,$r->{$_},$ctx->{project_id}) eq $r->{$_};
    }
    for (qw(started_at ended_at resume_at files_changed)) {
        die "invalid memory receipt\n" unless scalar_text($r->{$_}) && $r->{$_}=~/\A[0-9]{1,16}\z/; $r->{$_}=0+$r->{$_};
    }
    die "invalid memory receipt\n" if defined($r->{session_key}) && !id($r->{session_key});
    for (qw(task_ref label_ref result_ref)) {
        die "invalid memory receipt\n" if defined($r->{$_}) && !valid_ref($r->{$_},$r,$_ eq 'label_ref',$_ eq 'task_ref');
    }
    return $r;
}
sub resume_descriptor {
    my ($d)=@_;
    die "invalid resume descriptor\n" unless ref($d) eq 'HASH' && keys(%$d)==6
        && scalar_text($d->{provider}) && $d->{provider}=~/\A(?:claude|codex)\z/;
    for (qw(role model effort sandbox)) {
        die "invalid resume descriptor\n" unless scalar_text($d->{$_})
            && Loomy::ContentPolicy::_value($_,$d->{$_},$ctx->{project_id}) eq $d->{$_};
    }
    die "invalid resume descriptor\n" unless $d->{role}=~/\A(?:architect|debugger|security|reviewer|explorer|executor|developer|documenter)\z/
        && $d->{sandbox}=~/\A(?:read-only|workspace-write)\z/
        && $d->{effort}=~/\A(?:low|medium|high|xhigh|max)\z/ && $d->{model} ne 'unknown';
    my $o=$d->{options};
    die "invalid resume descriptor\n" unless ref($o) eq 'HASH' && keys(%$o)==5;
    for (qw(profile why task_label max_turns isolation)) {die "invalid resume descriptor\n" unless scalar_text($o->{$_})}
    die "invalid resume descriptor\n" unless $o->{profile}=~/\A(?:econome|equilibre|qualite)\z/
        && length($o->{why})<=200 && length($o->{task_label})<=384
        && $o->{max_turns}=~/\A(?:|[1-9][0-9]{0,8})\z/ && $o->{isolation}=~/\A(?:|off|bare|strict)\z/;
    die "invalid resume descriptor\n" unless $o->{task_label} eq ''
        || Loomy::ContentPolicy::sanitize_label($o->{task_label},96,384) eq $o->{task_label};
    die "invalid resume descriptor\n" if $d->{provider} eq 'codex' && length($o->{max_turns}.$o->{isolation});
    die "invalid resume descriptor\n" if $d->{provider} eq 'claude' && (!length($o->{max_turns}) || !length($o->{isolation}));
    return $d;
}
sub names {
    opendir my $dh,'.' or die "memory unavailable\n";
    my @all=sort readdir $dh; closedir $dh;
    # Readers ignore all hidden entries, including a writer's in-flight atomic
    # file. Only our own old scratch names may be removed, under the policy lock.
    if ($locked) {
        for my $name (grep {/\A\.[.]?[A-Za-z0-9][A-Za-z0-9_.:-]{0,99}\.json\.[0-9]+-[0-9a-f]+\z/} @all) {
            my $st=eval {Loomy::ContentPolicy::_private_stat($name)};
            next unless $st && @$st && time-$st->[9]>600;
            assert_dirs();
            unlink $name or die "memory retention failed\n"
                if Loomy::ContentPolicy::_same($st,Loomy::ContentPolicy::_private_stat($name));
        }
    }
    my @names=grep {!/^\./} @all;
    die "unexpected memory file\n" if grep {!/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,99}\.json\z/} @names;
    return @names;
}
sub rows {
    my @rows;
    in_store('receipts-v1',0,sub {
        my @names=names();
        die "memory index too large\n" if @names>100000;
        for my $name (@names) {
            my ($raw,$st)=Loomy::ContentPolicy::_read($name,16384);
            my $r=$json->decode($raw);
            if (out_of_scope($r)) {$foreign{$name}=1; next} $r=receipt($r);
            die "invalid memory identity\n" unless $name eq "$r->{id}.json";
            push @rows,[$r,$st];
        }
    });
    return [sort {$a->[1][9]<=>$b->[1][9] || $a->[0]{started_at}<=>$b->[0]{started_at} || $a->[0]{id} cmp $b->[0]{id}} @rows];
}
sub body {
    my ($r,$key)=@_; $key//='result_ref'; return unless valid_ref($r->{$key},$r,0,$key eq 'task_ref');
    my $ref=$r->{$key};
    my $b;
    in_store('private-results-v1',0,sub {
        my ($raw)=Loomy::ContentPolicy::_read("$ref->{target_id}.json",1048576); return unless defined $raw;
        my $v=$json->decode($raw);
        return if ref($v) eq 'HASH' && ($v->{project_id}//'') ne $ctx->{project_id};
        die "invalid private result\n" unless ref($v) eq 'HASH' && keys(%$v)==9
            && ($v->{version}//'') eq '1' && ($v->{project_id}//'') eq $ctx->{project_id}
            && ($v->{id}//'') eq $ref->{target_id} && ($v->{attempt_id}//'') eq $ref->{attempt_id}
            && scalar_text($v->{task}) && scalar_text($v->{result})
            && scalar_text($v->{saved_at}) && $v->{saved_at}=~/\A[0-9]{1,16}\z/
            && ($v->{status}//'')=~/\A(?:running|paused|ok|error|interrupted|handed_over|done|cancelled)\z/;
        resume_descriptor($v->{resume}) if defined $v->{resume}; $b=$v;
    }); return $b;
}
# The small typed manifest carries pin ownership/supersession only. Body size and
# age come from validated stat data; saving never decodes the full result store.
sub manifest {
    my ($raw,$st)=Loomy::ContentPolicy::_read('.retention-v1.json',262144);
    my $m=defined($raw) ? $json->decode($raw) : {version=>1,records=>{}};
    die "invalid retention manifest\n" unless ref($m) eq 'HASH' && keys(%$m)==2
        && ($m->{version}//'') eq '1' && ref($m->{records}) eq 'HASH' && keys(%{$m->{records}})<=1000;
    for my $id (keys %{$m->{records}}) {
        my $v=$m->{records}{$id};
        die "invalid retention manifest\n" unless id($id) && ref($v) eq 'HASH' && keys(%$v)==5
            && scalar_text($v->{project_id}) && $v->{project_id}=~/\Ap[0-9a-f]{64}\z/
            && scalar_text($v->{owner_pid}) && $v->{owner_pid}=~/\A[0-9]{1,10}\z/
            && scalar_text($v->{resume_at}) && $v->{resume_at}=~/\A[0-9]{1,16}\z/
            && scalar_text($v->{status}) && $v->{status}=~/\A(?:running|paused|ok|error|interrupted|handed_over|done|cancelled)\z/
            && scalar_text($v->{superseded_by}) && ($v->{superseded_by} eq '' || id($v->{superseded_by}));
    }
    return ($m,$st);
}
sub reference_receipt {
    my ($ref)=@_; my $source;
    in_store('receipts-v1',0,sub {
        my ($raw)=Loomy::ContentPolicy::_read("$ref->{target_id}.json",16384); return unless defined $raw;
        my $r=$json->decode($raw); return if out_of_scope($r); $r=receipt($r);
        $source=$r if $r->{id} eq $ref->{target_id} && $r->{attempt_id} eq $ref->{attempt_id};
    }); return $source;
}
sub supersede {
    my ($r)=@_; my $ref=$r->{task_ref}; return unless $ref && $ref->{target_id} ne $r->{id};
    return unless reference_receipt($ref);
    in_store('private-results-v1',0,sub {
        my ($m,$st)=manifest(); my $v=$m->{records}{$ref->{target_id}};
        return unless $v && $v->{project_id} eq $ctx->{project_id};
        $v->{superseded_by}=$r->{id}; atomic('.retention-v1.json',$json->encode($m)."\n",$st);
    });
}
sub save_body {
    my ($p,$r,$task,$result,$descriptor)=@_;
    my $record={version=>1,project_id=>$ctx->{project_id},id=>$r->{id},attempt_id=>$r->{attempt_id},
        saved_at=>time,status=>$r->{status},task=>$task,result=>$result,resume=>$descriptor};
    my $raw=$json->encode($record)."\n";
    die "private result too large\n" if length($raw)>$p->{results_max_record_bytes};
    my $receipts=rows(); my %receipts=map {$_->[0]{id}=>$_->[0]} @$receipts;
    in_store('private-results-v1',1,sub {
        my $before=Loomy::ContentPolicy::_private_stat("$r->{id}.json");
        my @names=names(); my ($m,$manifest_stat)=manifest();
        die "private result store full\n" if @names>1000;
        my (@items,@remove); my ($total,$count)=(length($raw),1); my %present;
        for my $name (@names) {
            (my $id=$name)=~s/\.json\z//; $present{$id}=1;
            next if $id eq $r->{id};
            my $st=Loomy::ContentPolicy::_private_stat($name);
            my $v=$m->{records}{$id}//{}; my $rr=$receipts{$id}//{};
            my $status=$rr->{status}//$v->{status}//'paused';
            my $age=time-($rr->{started_at} || $st->[9]);
            my $pinned=0;
            if ($foreign{$name} || ($v->{project_id}//$ctx->{project_id}) ne $ctx->{project_id}) {$pinned=1}
            elsif (!length($v->{superseded_by}//'')) {
                if ($status eq 'running') {
                    my $pid=$v->{owner_pid}//0;
                    $pinned=$age<86400 && $pid>0 && (kill(0,$pid) || $!{EPERM});
                } elsif ($status eq 'paused') {
                    $pinned=time<=($rr->{resume_at} || $v->{resume_at} || $st->[9])+30*86400;
                }
            }
            my $item=[$name,$st,$st->[9],$pinned,$id];
            if (!$pinned && time-$st->[9]>$p->{results_max_age_days}*86400) {push @remove,$item}
            else {push @items,$item; $count++; $total+=$st->[7]}
        }
        for my $i (sort {$a->[2]<=>$b->[2] || $a->[0] cmp $b->[0]} @items) {
            last if $count<=$p->{results_max_records} && $total<=$p->{results_max_total_bytes};
            next if $i->[3]; push @remove,$i; $count--; $total-=$i->[1][7];
        }
        die "private result store full\n" if $count>$p->{results_max_records} || $total>$p->{results_max_total_bytes};
        assert_dirs();
        for (@remove) {die "memory file changed\n" unless Loomy::ContentPolicy::_same($_->[1],Loomy::ContentPolicy::_private_stat($_->[0]))}
        for (@remove) {unlink $_->[0] or die "memory retention failed\n"; delete $present{$_->[4]}}
        delete $m->{records}{$_} for grep {!$present{$_}} keys %{$m->{records}};
        $m->{records}{$r->{id}}={project_id=>$ctx->{project_id},owner_pid=>0+($args[0]//getppid()),
            status=>$r->{status},resume_at=>$r->{resume_at},superseded_by=>''};
        # Write metadata first: a crash leaves at worst a conservative stale pin;
        # it never exposes a newly saved running body without its owner metadata.
        atomic('.retention-v1.json',$json->encode($m)."\n",$manifest_stat);
        atomic("$r->{id}.json",$raw,$before);
    }); return ref_for($r);
}
sub save {
    my ($p,$r,$task,$result,$d)=@_; receipt($r); resume_descriptor($d) if defined $d;
    if ($d) {
        my %sources=map {$_=>1} split /,/,$p->{label_sources};
        $d->{options}{task_label}='' unless $sources{'explicit-lead'};
    }
    supersede($r);
    # A previous authorized task remains usable when future capture is disabled
    # or refused. Reference that task only; never present its old result as new.
    my ($previous,$fallback_task);
    in_store('receipts-v1',0,sub {
        my ($raw)=Loomy::ContentPolicy::_read("$r->{id}.json",16384);
        $previous=$json->decode($raw) if defined $raw;
        $previous=out_of_scope($previous) ? undef : receipt($previous) if $previous;
    });
    if ($previous && $previous->{attempt_id} eq $r->{attempt_id}) {
        my $old=body($previous);
        $fallback_task=$old ? $previous->{result_ref} : $previous->{task_ref};
        $old//=body($previous,'task_ref');
        $fallback_task=undef unless $old && defined($old->{resume});
        $r->{task_ref}//=$fallback_task if $fallback_task;
    }
    if ($p->{private_results} eq 'on' && !$input_oversize && ($op ne 'save' || defined($d))) {
        my $ok=eval {$r->{result_ref}=save_body($p,$r,$task,$result,$d); 1};
        if (!$ok) {my $err=$@; delete $r->{result_ref}; print STDERR ui("LM_FAILED"),"\n";
            print STDERR ui("LM_FULL"),"\n" if $err eq "private result store full\n"}
    } else {delete $r->{result_ref}; print STDERR "$message{LM_FAILED}\n" if $p->{private_results} eq 'on' && ($input_oversize || ($op eq 'save' && !defined($d)))}
    # If a prior relaunch source was evicted, retain this attempt's already
    # authorized task when its new capture is disabled or refused.
    $r->{task_ref}=$fallback_task if !$r->{result_ref} && $fallback_task && !body($r,'task_ref');
    in_store('receipts-v1',1,sub {
        my (undef,$before)=Loomy::ContentPolicy::_read("$r->{id}.json",16384);
        atomic("$r->{id}.json",$json->encode(receipt($r))."\n",$before);
    });
    my $ref=$r->{result_ref}//$r->{task_ref};
    print decode('UTF-8',$json->encode($ref)) if $ref;
}

my $ok=eval {
    umask 0077;
    if ($op eq 'enabled') {
        exit(Loomy::ContentPolicy::effective_policy($root)->{private_results} eq 'on' ? 0 : 1);
    }
    if ($op eq 'label') {
        my ($text)=read_input(); my $p=Loomy::ContentPolicy::effective_policy($root);
        my %sources=map {$_=>1} split /,/,$p->{label_sources}; exit 3 unless $sources{'explicit-lead'};
        my $ref=Loomy::ContentPolicy::save_label($root,{project_id=>$p->{project_id},target_kind=>'delegation',
            target_id=>$args[0],attempt_id=>$args[0],source=>'explicit-lead',text=>$text});
        print decode('UTF-8',$json->encode($ref)); exit 0;
    }
    if ($op eq 'descriptor-env') {
        my ($raw,$role,$provider)=read_input(); $ctx={project_id=>''};
        my $d=resume_descriptor($text_json->decode($raw));
        die "invalid resume descriptor\n" unless $d->{role} eq $role && $d->{provider} eq $provider;
        print decode('UTF-8',$json->encode($d)); exit 0;
    }
    if ($op eq 'task-ref') {
        my ($raw)=read_input(); $ctx=Loomy::ContentPolicy::_context($root,0);
        my $ref=$text_json->decode($raw);
        die "invalid task reference\n" unless valid_ref($ref,{},0,1) && reference_receipt($ref);
        print decode('UTF-8',$json->encode($ref)); exit 0;
    }
    if ($op eq 'descriptor') {
        my ($role,$provider,$model,$effort,$sandbox,$profile,$why,$label,$turns,$isolation)=read_input();
        $ctx={project_id=>''};
        $why=clean_text($why,200);
        my $p=Loomy::ContentPolicy::effective_policy($root);
        my %sources=map {$_=>1} split /,/,$p->{label_sources};
        $label=$sources{'explicit-lead'} && length($label) ? Loomy::ContentPolicy::sanitize_label($label,96,384) : '';
        print decode('UTF-8',$json->encode(resume_descriptor({role=>$role,provider=>$provider,model=>$model,effort=>$effort,sandbox=>$sandbox,
            options=>{profile=>$profile,why=>$why,task_label=>$label,max_turns=>$turns,isolation=>$isolation}}))); exit 0;
    }
    if ($op eq 'save' || $op eq 'save-native') {
        my @v=read_input();
        # Bridges wait up to five seconds, then retry once. Native hooks keep
        # T1's one-second bound. Resolve policy under the acquired lock.
        my $c=Loomy::ContentPolicy::_context($root,1);
        Loomy::ContentPolicy::_in_context($c,sub {
            my $lock;
            for (1..($op eq 'save' ? 2 : 1)) {
                $lock=eval {Loomy::ContentPolicy::_lock($c,undef,$op eq 'save' ? 500 : 100)};
                last if $lock; die $@ unless $@ eq "content lock busy\n";
            }
            die "content lock busy\n" unless $lock;
            local $locked=1;
            my $p=Loomy::ContentPolicy::_effective($c,Loomy::ContentPolicy::_stored($c));
            $ctx=Loomy::ContentPolicy::_context($root,0);
            if ($op eq 'save') {save($p,$text_json->decode($v[0]),$v[1],$v[2],length($v[3]) ? $text_json->decode($v[3]) : undef)}
            else {
                my ($id,$role,$model,$status,$task,$result,$format)=@v;
                my $extra=length($format) ? $text_json->decode('{'.substr($format,1).'}') : {};
                my $r={version=>1,id=>$id,attempt_id=>$id,session_key=>undef,role=>$role,model=>$model,effort=>'unknown',
                    sandbox=>'unknown',status=>$status,outcome=>($status eq 'running' ? 'unknown' : $status eq 'paused' ? 'waiting_for_reset' : $status),started_at=>time,ended_at=>time,resume_at=>0,
                    files_changed=>0,format=>$extra->{format}//'unknown',review=>$extra->{review}//'unknown'};
                $r->{outcome}=$extra->{outcome} if $status eq 'ok' && defined($extra->{outcome});
                $r->{role}=Loomy::ContentPolicy::_value('role',$role,$p->{project_id});
                save($p,$r,$task,$result,undef);
            }
        }); exit 0;
    }
    $ctx=Loomy::ContentPolicy::_context($root,0);
    if ($op eq 'legacy') {
        my $path="$ctx->{root}/.loomy/memory";
        exit 0 unless lstat($path);
        my ($parent)=Loomy::ContentPolicy::_dir($path); chdir $parent or die "legacy memory unavailable\n";
        exit 0 unless lstat('delegations');
        my ($legacy)=Loomy::ContentPolicy::_dir('delegations'); chdir $legacy or die "legacy memory unavailable\n";
        opendir my $dh,'.' or die "legacy memory unavailable\n";
        my @names=sort grep {!/^\./ && /\A[^\x00-\x1f\x7f\/]+\.md\z/ && -f $_ && !-l $_} readdir $dh;
        if (length($args[0]//'')) {
            die "invalid legacy rank\n" unless $args[0]=~/\A[1-9][0-9]{0,5}\z/ && $args[0]<=@names;
            sysopen my $h,$names[-$args[0]],O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die "legacy memory unavailable\n";
            my @f=stat($h); die "unsafe legacy result\n" unless S_ISREG($f[2]) && $f[3]==1 && $f[4]==$<;
            binmode STDOUT, ':raw';
            while (1) {
                my $n=sysread($h,my $b,65536); die "legacy memory unavailable\n" unless defined $n;
                last unless $n; print $b;
            }
        } else {print "  - .loomy/memory/delegations/",Loomy::ContentPolicy::display_path($_),"\n" for reverse @names} exit 0;
    }
    my $rows=rows();
    if ($op eq 'count') {print scalar @$rows; exit 0}
    if ($op eq 'unavailable-count') {print scalar keys %foreign; exit 0}
    if ($op eq 'show') {
        my $n=$args[0]; die "invalid result rank\n" unless $n=~/\A[1-9][0-9]{0,5}\z/ && $n<=@$rows;
        my $r=$rows->[-$n][0]; my $b=body($r);
        my $date=strftime('%Y-%m-%d %H:%M',localtime($r->{ended_at} || $r->{started_at}));
        print '# ',join(' · ',@$r{qw(role model effort status)})," · $date · $r->{id}","\n\n",decode('UTF-8',$json->encode($r)),"\n\n";
        if ($b) {print "$message{LM_PRIVATE} · local · private-results-v1\n\n## Task\n\n$b->{task}\n\n## Result\n\n",display_result($b->{result}),"\n";
            print "\n## Resume descriptor\n\n",decode('UTF-8',$json->encode($b->{resume})),"\n" if $b->{resume};
            print "$message{LM_ORIGINAL}\n" if !$b->{resume} && $r->{status} eq 'paused'}
        else {
            my $task=body($r,'task_ref');
            print "$message{LM_NOT_RETAINED}\n";
            print "$message{LM_OFF}\n" if Loomy::ContentPolicy::effective_policy($root)->{private_results} eq 'off';
            if ($task) {print "\n## Task\n\n$task->{task}\n\n## Resume descriptor\n\n",decode('UTF-8',$json->encode($task->{resume})),"\n"}
            print "$message{LM_ORIGINAL}\n" if !$task && $r->{status} eq 'paused';
        }
        exit 0;
    }
    die "invalid memory operation\n" unless $op eq 'digest';
    my $n=$args[0]; die "invalid result count\n" unless $n=~/\A[1-9][0-9]{0,5}\z/;
    my %rank; my $rank=0; $rank{$_->[0]{id}}=++$rank for reverse @$rows;
    if (($args[1]//'') eq 'new') {
        my @s=lstat("$ctx->{root}/.loomy/memory/STATE.md");
        $rows=[grep {!@s || $_->[1][9]>$s[9]} @$rows];
    }
    splice @$rows,0,@$rows-$n if @$rows>$n;
    for my $pair (reverse @$rows) {
        my $r=$pair->[0]; my $b=body($r); my $verdict='';
        $verdict.=" · outcome=$r->{outcome}" if $r->{outcome} ne $r->{status} && $r->{outcome} ne 'unknown';
        $verdict.=" · review=$r->{review}" if $r->{review} ne 'unknown';
        my $summary=$message{LM_NOT_RETAINED}; my $next='';
        if ($b) {
            $summary=$b->{result};
            if ($summary=~/^\s*[*_ -]*summary\s*[*_]*:\s*(.*?)(?=\n\s*[*_ -]*[A-Z]+\s*[*_]*:|\z)/ims) {$summary=$1}
            if ($b->{result}=~/^\s*[*_ -]*next\s*[*_]*:\s*(.*)/im) {$next=$1}
            $summary=clean_text($summary,160); $next=clean_text($next,100);
        }
        if ($r->{status} eq 'running') {$summary=ui('LM_RUNNING'); $next=''}
        if ($r->{status} eq 'paused') {
            my $until=strftime('%Y-%m-%d %H:%M',localtime($r->{resume_at}));
            $summary=sprintf(ui('LM_PAUSED'),$until,$rank{$r->{id}}); $next='';
        }
        my $date=strftime('%Y-%m-%d %H:%M',localtime($r->{ended_at} || $r->{started_at}));
        print '  - ',join(' · ',@$r{qw(role model effort status)})," · $date · $r->{id}: $summary",length($next) ? " · next: $next" : '',$verdict,
            ' (.loomy/memory/receipts-v1/',$r->{id},".json)\n";
        print "    $message{LM_ORIGINAL}\n" if $r->{status} eq 'paused' && !($b && $b->{resume}) && !body($r,'task_ref');
    }
    1;
};
if (!$ok) {print STDERR "$message{LM_ERROR}\n"; exit 1}
PERL
}

# loomy_memory_state <root> [max lines]: no comments or empty sections; latest three dead ends first (320 chars each),
# joined with their indented continuations, then the rest of STATE within the line budget. Fall back to the archive
# if STATE has no dead ends. The files retain the full entries and any free text.
loomy_memory_state() {
  local d f
  d="$(loomy_memory_dir "$1")"; f="$d/STATE.md"
  loomy_memory_state_migrate "$1"
  { [[ ! -f "$f" ]] || cat "$f"; } | awk -v max="${2:-40}" -v archive="$d/DEAD-ENDS.md" '
      function dead_line(line) {
        if (line ~ /^- [^[:space:]]/) {
          ends[++n] = substr(line, 1, 320); active = n
          if (n > 3) delete ends[n - 3]
        } else if (active && line ~ /^[ \t]+[^[:space:]]/) {
          sub(/^[ \t]+/, "", line); ends[active] = substr(ends[active] " " line, 1, 320)
        } else active = 0
      }
      /<!--/ { c = 1 }
      c { if (/-->/) c = 0; active = 0; next }
      { sub(/\r$/, "") }
      /^## / { dead = ($0 ~ /^## Dead ends[ \t]*$/); h = dead ? "" : $0; active = 0; next }
      dead { dead_line($0); next }
      NF && !/^# / { if (h != "") { rest[++r] = h; h = "" } rest[++r] = $0 }
      END {
        if (!n) {
          active = 0; c = 0
          while ((getline line < archive) > 0) {
            if (line ~ /<!--/) c = 1
            if (c) { if (line ~ /-->/) c = 0; active = 0; continue }
            sub(/\r$/, "", line); dead_line(line)
          }
          close(archive)
        }
        if (n) {
          out[++k] = "## Dead ends"
          if (n > 3) out[++k] = "(Latest 3; full ledger in .loomy/memory/STATE.md and .loomy/memory/DEAD-ENDS.md.)"
          for (i = (n > 3 ? n - 2 : 1); i <= n; i++) out[++k] = ends[i]
        }
        for (i = 1; i <= r; i++) out[++k] = rest[i]
        for (i = 1; i <= k && i <= max; i++) print out[i]
      }'
}

# loomy_memory_from_transcript <transcript.jsonl>: "task<TAB>result" of a native subagent (first user message,
# last assistant text), through python3; nothing without it.
loomy_memory_from_transcript() {
  [[ -f "$1" ]] && command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
task = result = ""
def text(c):
    if isinstance(c, str): return c
    if isinstance(c, list): return "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return ""
for line in open(sys.argv[1], encoding="utf-8"):
    try: e = json.loads(line)
    except Exception: continue
    m = e.get("message") or {}
    role = m.get("role") or e.get("type")
    t = text(m.get("content"))
    if role == "user" and not task and t.strip(): task = t
    elif role == "assistant" and t.strip(): result = t
print(task.replace("\t", " ").replace("\n", "\x1f") + "\t" + result.replace("\t", " ").replace("\n", "\x1f"))
PY
}

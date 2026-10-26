#!/usr/bin/env bash
# Public writer contract, synthetic sources only; no provider, tmux or ps needed.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-content-writers.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS="$REPO/tests/stubs" LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1
export LOOMY_NATIVE_NOW=1792972807 LOOMY_FIXTURE_NOW=1792972800 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
unset LOOMY_JOURNAL LOOMY_JOURNAL_CONTENT LOOMY_CONTENT_PROJECT LOOMY_JOURNAL_TASKS LOOMY_PROJECT_ROOT LOOMY_FIXTURE_CONTENT
unset LOOMY_DELEGATION LOOMY_PARENT_ID LOOMY_ATTEMPT LOOMY_UI_LANG
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
perl - "$REPO" "$WORK" <<'PERL'
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time);
my ($repo,$work)=@ARGV;
require "$repo/scripts/lib/claude-native.pl";
my $json=JSON::PP->new->utf8->canonical;
my $allow=Loomy::ContentPolicy::check_allowlist("$repo/scripts/lib/content-allowlist.tsv");
sub put {my ($p,$s)=@_; open my $h,'>',$p or die $!; binmode $h; print $h $s; close $h; chmod 0600,$p or die}
sub bytes {my $p=shift; return '' unless -f $p; open my $h,'<',$p or die; local $/; return <$h>}
sub root {my $r="$work/$_[0]"; make_path("$r/.loomy/logs",{mode=>0700}); return $r}
sub conf {my ($r,%v)=@_; my $p={%{Loomy::ContentPolicy::defaults()},%v}; put("$r/.loomy/logs/content-policy.conf",join('',map {"$_=$p->{$_}\n"} sort keys %$p))}
sub events {my $r=shift; return map {decode_json($_)} grep {length} split /\n/,bytes("$r/.loomy/logs/events.jsonl")}
sub append {my ($r,$e,$label)=@_; Loomy::LiveState::journal_append("$r/.loomy/logs/events.jsonl",$e,'2026-10-26T00:00:00Z',$label)}
sub extras {
 my $t=shift; my %x=map {$_=>1} qw(content_policy policy_generation);
 @x{qw(task_ref label_ref)}=(1,1) if $t =~ /^(request|session_observed|delegation_start|delegation_activity|delegation|agent_link|agent_alias|agent_closed)$/;
 @x{qw(reason_code analysis_codes)}=(1,1) if $t eq 'skill';
 @x{qw(reason_code quota_window used_percent)}=(1,1,1) if $t =~ /^lead_(failover|return)$/;
 return \%x;
}
sub drift {
 my ($e,$output)=@_; my $t=$e->{type}; die "uncensused event $t" unless $allow->{$t}; my $x=extras($t);
 for my $k (keys %$e) {
  die "uncensused key $t.$k" unless exists($allow->{$t}{$k}) || $x->{$k};
  die "omitted key escaped $t.$k" if $output && ($allow->{$t}{$k}//'') eq 'omit' && ($e->{content_policy}//'') eq 'structural-v1';
 }
 if ($output) {
  die 'missing policy envelope' unless $e->{content_policy} =~ /^(structural|legacy-excerpts)-v1$/ && defined($e->{policy_generation});
  die 'serialized body escaped' if exists($e->{checkpoint_value}) && $e->{checkpoint_value} !~ /^(?:1|sha256:[0-9a-f]{64}|.+Z:(?:ok|error|interrupted|unknown|done|paused|handed_over|running|cancelled))$/;
 }
 return 1;
}
# The identical comparison checks actual producer input and emitted keys. These
# four mutations must fail it, independently of the manifest hash canaries.
my $sample={type=>'usage',ts=>'2026-10-26T00:00:00Z',cost_usd=>0,content_policy=>'structural-v1',policy_generation=>0};
ok(drift($sample,1),'P19 public drift gate accepts its fixture');
for my $mutation ({%$sample,unknown_key=>1},{%$sample,type=>'new_type'}) {
 ok(!eval {drift($mutation,1)},'P19 unknown key/type fails the producer drift comparison');
}
{ local $allow->{usage}{cost_usd}; delete $allow->{usage}{cost_usd}; ok(!eval {drift($sample,1)},'P19 missing key fails same comparison') }
{ local $allow->{usage}{cost_usd}='omit'; ok(!eval {drift($sample,1)},'P19 disposition mutation fails same comparison') }
my $first_root="$work/first-hook"; make_path("$first_root/.loomy",{mode=>0700});
ok(append($first_root,{type=>'delegation_start',id=>'first'}),'first native hook bootstraps a missing logs directory before taking events.lock');
is((events($first_root))[0]{id},'first','first hook event is retained');
is((stat("$first_root/.loomy/logs"))[2]&0777,0700,'first hook creates a private logs directory');
my $r=root('append');
append($r,{type=>'delegation',id=>'d1',role=>'reviewer',model=>'gpt-6.1-sol',status=>'ok',outcome=>'partial',format=>'structured',review=>'incomplete',
 cost_in=>'usage',cost_usd=>0.25,tokens_in=>12,multi_agent_version=>'v2',task=>'PRIVATE_TASK',why=>'PRIVATE_WHY',changed_files=>['PRIVATE_PATH'],result=>'PRIVATE_RESULT',extension=>{prompt=>'PRIVATE_PROMPT'}});
my ($e)=events($r);
is($e->{content_policy},'structural-v1','P02 generic appender is structural');
is($e->{policy_generation},0,'P02 every writer adds the generation');
ok(bytes("$r/.loomy/logs/events.jsonl") !~ /PRIVATE_|extension|changed_files/, 'P02 no content/extension object survives');
is_deeply([@$e{qw(cost_in cost_usd tokens_in multi_agent_version format outcome review)}],['usage',0.25,12,'v2','structured','partial','incomplete'],'P12/P19 accounting and review facts preserved');
for my $signal ([INT=>2],[TERM=>15],[HUP=>1],[EXIT=>undef]) {
 append($r,{type=>'delegation',id=>'signal',status=>'interrupted',signal=>$signal->[0]});
 my @signals=events($r); is($signals[-1]{signal},$signal->[1],"P02 $signal->[0] uses T1 numeric/unknown signal contract");
}
conf($r,journal_content=>'legacy-excerpts',policy_generation=>4);
for my $n (59,60,61,199,200,201) {
 append($r,{type=>'request',id=>"r$n",excerpt=>'日'x$n});
 my @e=events($r); is(length($e[-1]{excerpt}),$n>60 ? 60 : $n,"P04 request $n Unicode characters bounded");
 append($r,{type=>'delegation',id=>"d$n",task=>'語'x$n,why=>'w'x$n,changed_files=>['PRIVATE_PATH'],result=>'PRIVATE_RESULT'});
 @e=events($r); is(length($e[-1]{task}),$n>200 ? 200 : $n,"P04 task $n bounded");
 is(length($e[-1]{why}),$n>200 ? 200 : $n,"P04 why $n bounded");
}
append($r,{type=>'delegation_start',id=>'bounded-native',nickname=>'N'x41,task=>'t'x201,why=>'w'x201});
my @bounded=events($r); is(length($bounded[-1]{nickname}),40,'P04 nickname bounded');
append($r,{type=>'session_observed',session=>'s',cwd_relative=>'../PRIVATE_PATH'});
@bounded=events($r); ok(!exists($bounded[-1]{cwd_relative}),'P04 escaping relative path rejected');
# Live policy reads and TASKS veto: no inherited excerpt survives a generation change.
conf($r,policy_generation=>5);
append($r,{type=>'delegation',id=>'d2',task=>'PRIVATE_TASK',why=>'PRIVATE_WHY'});
@bounded=events($r); is($bounded[-1]{policy_generation},5,'P03 writer observes restriction on its next append');
ok(!exists($bounded[-1]{task}) && !exists($bounded[-1]{why}),'P03 stale payload cannot bypass new policy');
conf($r,journal_content=>'legacy-excerpts',policy_generation=>6);
{local $ENV{LOOMY_JOURNAL_TASKS}=0; append($r,{type=>'delegation',id=>'d3',task=>'PRIVATE_TASK'})}
@bounded=events($r); is($bounded[-1]{content_policy},'structural-v1','P03 TASKS veto wins over compatibility');
# A held policy lock never makes a hook wait for human input or a busy writer.
my ($ready,$send); pipe($ready,$send) or die; my $pid=fork(); die unless defined $pid;
if (!$pid) {close $ready; my $c=Loomy::ContentPolicy::_context($r,1); Loomy::ContentPolicy::_in_context($c,sub {my $lock=Loomy::ContentPolicy::_lock($c); syswrite $send,"R"; select undef,undef,undef,0.7; }); POSIX::_exit(0)}
close $send; sysread($ready,my $go,1); my $begin=time;
append($r,{type=>'request',id=>'busy',excerpt=>'PRIVATE_PROMPT'});
ok(time-$begin<0.2,'P03 contended policy lock degrades without waiting');
@bounded=events($r); is($bounded[-1]{content_policy},'structural-v1','P03 contended policy cannot grant excerpts');
waitpid($pid,0); is($?,0,'policy lock holder finished');
my $excluded=root('excluded-source'); conf($excluded,label_sources=>'codex-nickname');
{
 my $writer=Loomy::LiveState::content_writer($excluded);
 no warnings 'redefine'; local *Loomy::ContentPolicy::_find_label=sub {die 'excluded source read label store'};
 ok(!defined(Loomy::LiveState::content_label($writer,'delegation','call','session','claude-description','Private title')),
    'P03 excluded label source skips all label-store work');
}
# Monthly/size rotation preserves original archives, projects all fresh snapshots.
my $rotation=root('rotation'); conf($rotation,journal_content=>'legacy-excerpts',policy_generation=>8);
my $old=join('',map {encode_json($_)."\n"}
 {type=>'session',ts=>'2026-09-01T00:00:00Z',session=>'s',tool=>'claude',event=>'start',pid=>0,task=>'PRIVATE_TASK'},
 {type=>'delegation_start',ts=>'2026-09-01T00:00:01Z',session=>'s',id=>'open',role=>'reviewer',task=>'PRIVATE_TASK',why=>'PRIVATE_WHY',cwd_relative=>'PRIVATE_PATH'},
 {type=>'usage',ts=>'2026-09-01T00:00:02Z',cost_usd=>0.25});
put("$rotation/.loomy/logs/events.jsonl",$old);
Loomy::LiveState::journal_rotate("$rotation/.loomy/logs/events.jsonl");
my @snap=events($rotation); is(scalar(@snap),2,'P06 rotation snapshots only open work and sessions');
ok(!grep({!$_->{snapshot} || $_->{content_policy} ne 'structural-v1'} @snap),'P06 snapshots structural even under compatibility');
like(bytes("$rotation/.loomy/logs/events.jsonl"),qr/"type":"delegation_start","id":"open"/,'rotation snapshots retain bridge type/id lookup order');
ok(bytes("$rotation/.loomy/logs/events.jsonl") !~ /PRIVATE_|task|why|cwd_relative/, 'P06 fresh snapshots never copy legacy content');
my @archive=glob "$rotation/.loomy/logs/archive/events-*.jsonl";
is(bytes($archive[0]),$old,'P06 archive bytes unchanged');
put("$rotation/.loomy/logs/events.jsonl",bytes("$rotation/.loomy/logs/events.jsonl").('x'x8388608)."\n");
Loomy::LiveState::journal_rotate("$rotation/.loomy/logs/events.jsonl");
ok(-s "$rotation/.loomy/logs/events.jsonl"<8388608,'P06 size rotation bounded');
# Project only emitted signatures. Old checkpoint map bytes and identity format
# stay available for the R2 migration; content changes cannot cause context loops.
my $w=Loomy::LiveState::content_writer($r);
my $sig1=Loomy::LiveState::content_signature($w,'delegation_activity',encode_json({session=>'s',task=>'PRIVATE_A',role=>'reviewer',model=>''}));
my $sig2=Loomy::LiveState::content_signature($w,'delegation_activity',encode_json({session=>'s',task=>'PRIVATE_B',role=>'reviewer',model=>''}));
is($sig1,$sig2,'P05 signature ignores prose and normalizes unknown models');
like($sig1,qr/^sha256:[0-9a-f]{64}$/,'P05 emitted signature is opaque');
undef $w;
my $label_root=root('label-cliff'); conf($label_root,label_sources=>'claude-description');
{
 my $writer=Loomy::LiveState::content_writer($label_root);
 my $ref=Loomy::LiveState::content_label($writer,'delegation','call','session','claude-description','Original title');
 ok($ref,'P23 first automatic label saved');
 my $size=-s "$label_root/.loomy/logs/display-context-v1.jsonl";
 undef $writer;
 conf($label_root,label_sources=>'claude-description',label_store_max_bytes=>$size+1);
 $writer=Loomy::LiveState::content_writer($label_root);
 my $retained=Loomy::LiveState::content_label($writer,'delegation','call','session','claude-description','Replacement title');
 is_deeply($retained,$ref,'P23 full label store preserves prior scoped reference');
 is(-s "$label_root/.loomy/logs/display-context-v1.jsonl",$size,'P23 failed label save preserves prior bytes');
 ok(-e "$label_root/.loomy/logs/display-context-full",'P23 full label store has persistent health fact');
}
# Capture real native constructors, not a test projector reimplementation.
my ($input_count,$output_count)=(0,0); my %types;
my $project=\&Loomy::LiveState::project_journal_event;
{
 no warnings 'redefine'; local *Loomy::LiveState::project_journal_event=sub {
  my ($w,$e)=@_; drift($e,0); $input_count++; my $p=$project->(@_); drift($p,1); $output_count++; $types{$p->{type}}++; return $p;
 };
 for my $tool (qw(claude codex)) {
  my %metadata_reads; my $read_metadata=\&Loomy::CodexNative::metadata;
  local *Loomy::CodexNative::metadata=sub {my @st=stat($_[0]); $metadata_reads{"$_[0]:$st[0]:$st[1]"}++; $read_metadata->(@_)};
  my $native=root("native-$tool"); my $sources="$work/$tool-sources";
  my @args=$tool eq 'claude' ? ('app',1) : ($$);
  system($^X,"$repo/tests/fixtures/$tool-native.pl",'seed',$native,$sources,@args)==0 or die;
  my $poll=$tool eq 'claude' ? sub {Loomy::ClaudeNative::poll($native,$sources)} : sub {Loomy::CodexNative::poll($native,$sources)};
  $poll->(); my $prior=bytes("$native/.loomy/logs/events.jsonl");
  my $sent_before=$tool eq 'claude' ? decode_json(bytes("$native/.loomy/logs/claude-native.idx"))->{sent} : undef;
  system($^X,"$repo/scripts/lib/$tool-native.pl",$native,$sources)==0 or die;
  is(bytes("$native/.loomy/logs/events.jsonl"),$prior,"P05 $tool cold restart emits no duplicate start/context");
  if ($tool eq 'claude') {
   my $sent_after=decode_json(bytes("$native/.loomy/logs/claude-native.idx"))->{sent};
   is_deeply($sent_after,$sent_before,'P05 replay does not change persisted sent representation');
   ok(!grep({/^sha256:/} values %$sent_after),'P05 checkpoint sent bodies stay in original R1 format');
   unlink "$native/.loomy/logs/claude-native.idx"; unlink "$native/.loomy/logs/claude-native.idx.bak";
   system($^X,"$repo/scripts/lib/claude-native.pl",$native,$sources)==0 or die;
   is(bytes("$native/.loomy/logs/events.jsonl"),$prior,'P05 lost checkpoint reconstructs without re-emitting start/context');
   system($^X,"$repo/scripts/lib/claude-native.pl",$native,$sources)==0 or die;
   is(bytes("$native/.loomy/logs/events.jsonl"),$prior,'P05 reconstructed checkpoint has no repeated context loop');
  }
  # All labels are denied before a matching project grant.
  ok(!-e "$native/.loomy/logs/display-context-v1.jsonl","P23 $tool labels need a grant");
  conf($native,label_sources=>Loomy::ContentPolicy::recommended_sources(),policy_generation=>1);
  # Fresh source evidence activates the already-running collector.
  my $action=$tool eq 'claude' ? 'activity' : 'finish';
  system($^X,"$repo/tests/fixtures/$tool-native.pl",$action,$native,$sources,@args)==0 or die;
  $poll->();
  my @labels=map {decode_json($_)} grep {length} split /\n/,bytes("$native/.loomy/logs/display-context-v1.jsonl");
  if ($tool eq 'codex') {
   ok(grep({$_->{source} eq 'codex-path-slug'} @labels),'P23 Codex slug separately stored');
   ok(grep({$_->{source} eq 'codex-nickname'} @labels),'P23 Codex nickname separately stored');
   ok(grep({$_->{source} eq 'codex-role'} @labels),'P23 Codex role separately stored');
   ok(grep({exists($_->{label_ref})} events($native)),'P23 Codex emits a scoped label reference');
   my ($named)=grep {exists($_->{label_refs})} events($native);
   is_deeply([sort keys %{$named->{label_refs}}],[qw(nickname role slug)],'Codex carries all three granted label references');
   my @parts=map {Loomy::ContentPolicy::resolve_label($native,$named->{label_refs}{$_})->{text}} qw(nickname role slug);
   like(join(' ',@parts),qr/^Native[234] (?:worker|default) (?:consolidation|enrichment|review)$/,'all three display components reconstruct from scoped refs');
  }
  ok(!grep({$_>1} values %metadata_reads),'Codex approved child metadata read at most once per file identity') if $tool eq 'codex';
  my $before=bytes("$native/.loomy/logs/events.jsonl");
  system($^X,"$repo/scripts/lib/$tool-native.pl",$native,$sources)==0 or die;
  is(bytes("$native/.loomy/logs/events.jsonl"),$before,"P05 $tool restart after policy change remains deduplicated");
  for my $event (events($native)) {drift($event,1) if exists $event->{content_policy}}
 }
}
ok($input_count>10 && $input_count==$output_count,'P19 real native constructor and output keys pass manifest comparison');
for my $type (qw(delegation_start delegation_activity delegation session_observed session_context)) {ok($types{$type},"P19 native fixture covers $type")}
for my $bad ("Bad\e[31m",'x'x41,' has leading space','has/slash',"日本語") {is(Loomy::CodexNative::strict_label($bad),'','P23 unsafe/overlong Codex metadata rejected, not repaired')}
for my $good ('worker','custom role','Lyra','inventory') {is(Loomy::CodexNative::strict_label($good),$good,'P23 exact valid Codex component preserved')}
# Adversarial stored/provider values never poison a later event or rotation.
my $poison=root('poison'); conf($poison);
put("$poison/.loomy/logs/events.jsonl",join('',map {encode_json($_)."\n"}
 {type=>'session',ts=>'2026-09-01T00:00:00Z',session=>'s 1 with space',tool=>'claude',event=>'start'},
 {type=>'delegation_start',ts=>'2026-09-01T00:00:01Z',id=>'old',session=>'s',model=>'opus[1m]',label_ref=>{bad=>1}},
 {type=>'delegation_activity',ts=>'2026-09-01T00:00:02Z',id=>'old',session=>'s',model=>'Qwen3 30B'}));
ok(append($poison,{type=>'request',id=>'after-poison'}),'one invalid rotation value cannot block the next append');
my @poisoned=events($poison);
is(scalar(grep {$_->{snapshot}} @poisoned),3,'all classifiable snapshot events survive malformed values');
ok(!defined((grep {$_->{type} eq 'delegation_start'} @poisoned)[0]{model}),'invalid old model degrades to null');
ok(append($poison,'"type":"delegation_start","id":"utf8","task":"'.('a'x199)."\xe7".'"'),'byte-cut UTF-8 still writes structural event');
ok(append($poison,{type=>'request',id=>'next'}),'append after byte-cut succeeds');
is((events($poison))[-2]{id},'utf8','multibyte-cut event is retained');
ok(!append($poison,{type=>'unregistered',id=>'bad'}),'uncensused event skipped without dying');
ok(append($poison,{type=>'request',id=>'after-unknown'}),'event after rejected type still writes');
like(bytes("$poison/.loomy/logs/events.jsonl"),qr/"type":"delegation_start","id":"utf8"/,'bridge literal type/id lookup preserved');
for my $status (qw(ok error interrupted unknown done paused handed_over running cancelled), '') {
 my $value="2026-10-26T00:00:00Z:$status";
 my $w=Loomy::LiveState::content_writer($poison);
 my $sig=Loomy::LiveState::content_signature($w,'delegation',$value);
 ok($status eq '' ? $sig =~ /^sha256:[0-9a-f]{64}$/ : $sig eq $value,"signature accepts terminal domain or digests empty status [$status]");
}
{
 my $w=Loomy::LiveState::content_writer($poison);
 no warnings 'redefine'; my $project=\&Loomy::LiveState::project_journal_event;
 local *Loomy::LiveState::project_journal_event=sub {die 'simulated projection fault' if ($_[1]{id}//'') eq 'fault'; $project->(@_)};
 ok(!append($poison,{type=>'request',id=>'fault'}),'unexpected projection exception isolated');
 ok(append($poison,{type=>'request',id=>'recovery'}),'writer continues after unexpected projection exception');
}
my $held=root('snapshot-only'); conf($held,label_sources=>'claude-description');
my $snapshot=Loomy::LiveState::content_writer($held);
my $child=fork(); die unless defined $child;
if (!$child) {my $other=Loomy::LiveState::content_writer($held); my $ref=Loomy::LiveState::content_label($other,'delegation','during-poll','s','claude-description','Visible title'); POSIX::_exit($ref ? 0 : 1)}
waitpid($child,0); is($?,0,'holding a poll snapshot never drops a concurrent hook label');
my $lazy=Loomy::LiveState::content_writer($held);
{
 no warnings 'redefine'; local *Loomy::ContentPolicy::_rows=sub {die 'full store validation'};
 my $ref=Loomy::LiveState::content_label($lazy,'delegation','during-poll','s','claude-description','Visible title');
 ok($ref,'labelled append finds exact existing label without full revalidation');
}
my $health=decode_json(bytes("$r/.loomy/logs/content-health.json"));
is($health->{policy_lock_misses},1,'bounded policy lock miss is counted persistently');
my $label_busy=root('label-lock'); conf($label_busy,label_sources=>'claude-description');
my ($label_ready,$label_send); pipe($label_ready,$label_send) or die;
my $label_pid=fork(); die unless defined $label_pid;
if (!$label_pid) {close $label_ready; my $c=Loomy::ContentPolicy::_context($label_busy,1);
 Loomy::ContentPolicy::_in_context($c,sub {my $lock=Loomy::ContentPolicy::_lock($c,'display-context.lock'); syswrite $label_send,"R"; select undef,undef,undef,0.4}); POSIX::_exit(0)}
close $label_send; sysread($label_ready,my $label_go,1);
my $snapshot_started=time; my $label_writer=Loomy::LiveState::content_writer($label_busy);
ok(time-$snapshot_started<0.2,'policy snapshot is available while the label store is busy');
ok(!Loomy::LiveState::content_label($label_writer,'delegation','call','s','claude-description','Allowed title'),'busy label store has bounded fallback');
is(decode_json(bytes("$label_busy/.loomy/logs/content-health.json"))->{label_lock_misses},1,'label lock miss counted separately');
waitpid($label_pid,0);
ok(Loomy::LiveState::content_label($label_writer,'delegation','call','s','claude-description','Allowed title'),'label capture recovers after store lock release');
done_testing;
PERL
python3 - "$REPO" "$WORK" <<'PY'
import collections, json, os, pathlib, re, subprocess, sys
repo, work = map(pathlib.Path, sys.argv[1:])
manifest = {}
for line in (repo/'scripts/lib/content-allowlist.tsv').read_text().splitlines():
    if line.startswith('#') or line.startswith('event_type') or not line: continue
    kind, key, disposition = line.split('\t'); manifest.setdefault(kind, {})[key] = disposition
extra_common = {'content_policy', 'policy_generation'}
extra_refs = {'request','session_observed','delegation_start','delegation_activity','delegation','agent_link','agent_alias','agent_closed'}
def drift(row, emitted):
    kind = row['type']; assert kind in manifest, ('uncensused event', kind)
    extra = extra_common | ({'label_ref','task_ref'} if kind in extra_refs else set())
    if kind == 'skill': extra |= {'reason_code','analysis_codes'}
    if kind in ('lead_failover','lead_return'): extra |= {'reason_code','quota_window','used_percent'}
    assert not set(row)-set(manifest[kind])-extra, ('uncensused keys', kind, set(row)-set(manifest[kind])-extra)
    if emitted:
        assert row['content_policy'] in ('structural-v1','legacy-excerpts-v1')
        assert isinstance(row['policy_generation'], int)
        if row['content_policy'] == 'structural-v1':
            assert not {k for k in row if manifest[kind].get(k) == 'omit'}, row
    return True
def run(argv, **kwargs):
    p = subprocess.run(argv, text=True, capture_output=True, **kwargs)
    if p.returncode: raise AssertionError(f'{argv[0]} exited {p.returncode}: {p.stderr[-2000:]}')
    return p.stdout
def rows(root):
    p = root/'.loomy/logs/events.jsonl'
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
def seed_policy(root, **changes):
    directory = root/'.loomy/logs'; directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    raw = run(['perl', '-e', 'require $ARGV[0]; my $p=Loomy::ContentPolicy::defaults(); print "$_=$p->{$_}\\n" for sort keys %$p;', str(repo/'scripts/lib/content-policy.pl')])
    policy = dict(x.split('=',1) for x in raw.splitlines()); policy.update({k:str(v) for k,v in changes.items()})
    path = directory/'content-policy.conf'; path.write_text(''.join(f'{k}={v}\n' for k,v in policy.items())); path.chmod(0o600)
# Keep structural hooks cheap without caching a grant: the next transaction must
# still read the live policy, while the Unicode codec is only needed for text.
codec_root=work/'codec'; seed_policy(codec_root)
run(['perl','-e','require $ARGV[0]; Loomy::LiveState::journal_append("$ARGV[1]/.loomy/logs/events.jsonl",{type=>"request",id=>"r"}); die "eager Unicode codec" if exists $INC{"Encode.pm"};',str(repo/'scripts/lib/live-state.pl'),str(codec_root)])
# Compare semantic facts as well as keys. Missing enum members must fail the
# public drift gate even when the projector safely converts them to unknown.
semantic_keys={'tool','family','bridge','effort','status','outcome','state','surface','context_freshness',
               'cost_source','cost_in','activity','source','evidence','event','reason_code','phase','format','review','requested','requested_model','off_routing'}
def preserve(raw, projected):
    for key in semantic_keys & set(raw):
        if raw[key] not in ('',None): assert projected.get(key)==raw[key], ('producer value lost',raw['type'],key,raw[key],projected.get(key))
# Discover all current shell templates at the same capture boundary as the private
# design census. This public gate has no dependency on .loomy or private sources.
setup = r'''
set -euo pipefail
source "$REPO/scripts/lib/journal.sh"
ai_codex_bin() { :; }; source "$REPO/scripts/lib/launch.sh"
ai_journal_write() { printf '{"ts":"2026-10-26T00:00:00Z",%s}\n' "$2" >>"$CAPTURE"; }
ROOT="$WORK/templates"; root="$ROOT"; r="$ROOT"; sid=fixture-session
id=d179297280012345; DELEG_ID="$id"; role=reviewer; ROLE="$role"; parent=d179297270012345
model=gpt-6-luna; MODEL="$model"; START_MODEL="$model"; effort=max; EFFORT=max
AI_PROFILE=equilibre; SANDBOX=read-only; task=PRIVATE_DESCRIPTION; TASK=PRIVATE_TASK
bg=true; requested=true; req=true; offroute=model; tool=codex; TOOL=codex; src=startup
pid=12345; child=12345; scope=subagent; agent=reviewer; signal=TERM; signal_json=',"signal":15'
duration=12; DURATION=12; T_IN=10; T_CACHED=2; T_CWRITE=1; T_OUT=4
COST=0.01; COST_SRC=reported; CHANGED=2; CHANGED_FILES_JSON='["PRIVATE_PATH"]'
family=codex; resume=1792972860; RESULT=ok; result=ok; started=1792972788
tin=10; tcw=1; tcr=2; tout=4; n=1; cost=0.01; tw5=3; tw1=2
quota_window=5h; used_percent=92; name=fixture-skill; fromlock=1; an=PRIVATE_ANALYSIS; reason=PRIVATE_REASON; reason_code=quota
ts=2026-10-26T00:00:00Z; launcher=desktop; rc=0; m=claude; a=codex; dur=12
FAILOVER_JSON=',"failover_from":"claude"'
WHY_JSON=',"requested":true,"requested_model":"gpt-6-luna","why":"PRIVATE_WHY","off_routing":"model"'
FORMAT_JSON=',"format":"structured","outcome":"partial","review":"incomplete"'
LOOMY_PARENT_ID=d179297270012345; LOOMY_PARENT_SESSION=fixture-parent
LOOMY_PARENT_AGENT=fixture-agent; LOOMY_ATTEMPT=d179297280012345; LOOMY_REQUESTED_MODEL=gpt-6-luna
body='"id":"d179297280012345","bridge":"codex","family":"codex","role":"reviewer","model":"gpt-6-luna","effort":"max"'
set -- "$ROOT" "$id" codex reviewer codex "$model" max read-only PRIVATE_TASK 1 model PRIVATE_WHY
'''
chunks, templates = [setup], []
phase_source=(repo/'scripts/lib/phases.sh').read_text()
phase_domains={'phase':'LOOMY_PHASES','task_phase':'LOOMY_TASK_PHASES','audit_phase':'LOOMY_AUDIT_PHASES'}
for path in sorted((repo/'scripts').rglob('*.sh')):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = re.search(r'\b(ai_journal_write|loomy_cli_end) ("[^\n]+)', line)
        if not match or 'type\\"' not in line or '() {' in line: continue
        expression = re.sub(r'\s*;;\s*$', '', match.group(0).strip())
        expression = re.sub(r';\s*fi\s*$', '', expression)
        templates.append((str(path.relative_to(repo)), number))
        for phase in (['phase','task_phase','audit_phase'] if '$PH_TYPE' in expression else ['phase']):
            extra = '''extra=',"manual":true' '''
            if path.name == 'launch.sh': extra = '''extra=',"profile":"-","sandbox":"text-only","tokens_in":0,"tokens_out":0,"cost_usd":0,"cost_source":"local","files_changed":0' '''
            phase_values=re.search(r'^'+phase_domains[phase]+r'="([^"]+)"',phase_source,re.M)[1].split()+['done'] if '$PH_TYPE' in expression else ['done']
            skill_values=[('anthropic',''),('anthropic','1'),('openai',''),('openai','1')] if path.name=='skills.sh' else [('startup','1')]
            for value in phase_values:
                for source,fromlock in skill_values:
                    chunks += [f'PH_TYPE={phase}; PHASE_ARG={value}; src={source}; fromlock="{fromlock}"\n{extra}\n{expression}\n']
assert collections.Counter(path for path,line in templates)=={
    'scripts/lib/failover.sh':2,'scripts/lib/journal.sh':3,'scripts/lib/launch.sh':5,
    'scripts/lib/skills.sh':2,'scripts/lib/usage.sh':3,'scripts/loomy-context.sh':2,
    'scripts/loomy-delegate-claude.sh':2,'scripts/loomy-delegate-codex.sh':2,
    'scripts/loomy-start.sh':2,'scripts/loomy-status.sh':1}, 'shell constructor census drift (addition/removal)'
chunks.append('loomy_cli_bridge_start "$ROOT" "$id" codex reviewer codex "$model" max read-only PRIVATE_TASK 1 model PRIVATE_WHY')
capture = work/'templates.jsonl'
run(['/bin/bash','-c','\n'.join(chunks)], env=dict(os.environ,REPO=str(repo),WORK=str(work),CAPTURE=str(capture)))
inputs = [json.loads(x) for x in capture.read_text().splitlines()]
for row in inputs: drift(row, False)
root = work/'template-projection'; seed_policy(root)
projector = '''require $ARGV[0]; my $w=Loomy::LiveState::content_writer($ARGV[1]); while (<STDIN>) {my $e=JSON::PP::decode_json($_); print Loomy::LiveState::journal_line(Loomy::LiveState::project_journal_event($w,$e))}'''
projected = run(['perl','-e',projector,str(repo/'scripts/lib/live-state.pl'),str(root)],input=capture.read_text())
outputs = [json.loads(x) for x in projected.splitlines()]
for row in outputs: drift(row, True)
for raw,row in zip(inputs,outputs): preserve(raw,row)
assert len(outputs) == len(inputs) and 'PRIVATE_' not in projected
print(f'PASS P19 {len(templates)} discovered shell templates: raw keys and projected output match public allowlist')
# The role and catalog declarations feed the real producers; a new role/source
# requires a deliberate domain update instead of becoming unknown silently.
roles=re.search(r'^AI_ROLES="([^"]+)"',(repo/'scripts/lib/models.sh').read_text(),re.M)[1].split()
sources={line.split('|')[1] for line in (repo/'catalog/skills.conf').read_text().splitlines() if line and not line.startswith(('#','date='))}
domain_rows=[{'type':'delegation_start','role':role} for role in roles]+[{'type':'skill','source':source} for source in sorted(sources)]
domain_output=run(['perl','-e',projector,str(repo/'scripts/lib/live-state.pl'),str(root)],input=''.join(json.dumps(e)+'\n' for e in domain_rows))
for raw,line in zip(domain_rows,domain_output.splitlines()):
    row=json.loads(line)
    for key,value in raw.items(): assert row[key]==value, ('declared producer domain lost',key,value,row[key])
print('PASS P19 declared routing roles, audit/task/project phases and skill repositories retain exact values')
# Real hook boundary: description only, actual usage dedup/model matching and
# result handoff on stdin. A Perl launch guard rejects the result in any argv.
hook_script = r'''
set -euo pipefail
source "$REPO/scripts/lib/journal.sh"
perl() { for arg in "$@"; do case "$arg" in *SENSITIVE_RESULT_SENTINEL*) exit 93 ;; esac; done; command perl "$@"; }
ai_detect_env() { AI_ENV=claude; AI_PROFILE=equilibre; }; ai_resolve() { R_MODEL=claude-opus-4-6; R_EFFORT=max; }
ai_role_writes() { return 1; }; ai_delegate_off_routing() { printf ''; }; AI_ROLES='developer reviewer'
ai_price_long_list() { printf ''; }; ai_price() { printf '1 2 0.1'; }
ai_journal_agent_start "$PROJECT" "$START" 0
# The exact same transcript consumed twice must produce only one usage event.
ai_usage_record "$PROJECT" "$TRANSCRIPT" subagent "$AGENT_TYPE"
ai_usage_record "$PROJECT" "$TRANSCRIPT" subagent "$AGENT_TYPE"
# Finishing an older start still repairs its journal mode without the expensive
# directory-wide preparation pass that generic writes already perform.
chmod 0644 "$PROJECT/.loomy/logs/events.jsonl"
ai_journal_agent_stop "$PROJECT" "$STOP" 0 $'SENSITIVE_RESULT_SENTINEL\nSTATUS: partial'
ai_journal_agent_return "$PROJECT" "$RETURN"
ai_journal_agent_stop "$PROJECT" "$STOP" 0 $'SENSITIVE_RESULT_SENTINEL\nSTATUS: partial'
'''
for agent_type in ('developer','Explore','custom private agent type'):
    root = work/('hooks-'+agent_type.split()[0]); seed_policy(root,label_sources='claude-description',policy_generation=3)
    transcript = root/'transcript.jsonl'
    transcript.write_text(''.join(json.dumps({'type':'assistant','message':{'id':f'msg_{i}','model':'claude-haiku-4-5-20251001','usage':{'input_tokens':1000000,'cache_creation_input_tokens':0,'cache_read_input_tokens':0,'output_tokens':0}}},separators=(',',':'))+'\n' for i in (1,1,2)))
    start = {'session_id':'hook-session','tool_use_id':'call1','tool_input':{'subagent_type':agent_type,'description':'Approved title','prompt':'PRIVATE_PROMPT','run_in_background':True}}
    env = dict(os.environ, REPO=str(repo),PROJECT=str(root),TRANSCRIPT=str(transcript),AGENT_TYPE=agent_type,
               START=json.dumps(start),STOP=json.dumps({'session_id':'hook-session','agent_id':'agent1','agent_type':agent_type}),
               RETURN=json.dumps({'session_id':'hook-session','tool_use_id':'call1','tool_response':{'agentId':'agent1'}}))
    run(['/bin/bash','-c',hook_script],env=env)
    events = rows(root)
    assert (root/'.loomy/logs/events.jsonl').stat().st_mode & 0o777 == 0o600
    for e in events: drift(e,True)
    usage = [e for e in events if e['type']=='usage']; ends = [e for e in events if e['type']=='delegation']
    assert len(usage)==1 and usage[0]['messages']==2 and usage[0]['cost_usd']==2
    assert len(ends)==1 and ends[0]['model']=='claude-haiku-4-5-20251001' and ends[0]['outcome']=='partial' and ends[0]['cost_in']=='usage' and ends[0]['cost_usd']==0
    starts = [e for e in events if e['type']=='delegation_start']
    assert len(starts)==1 and starts[0]['label_ref']==ends[0]['label_ref']
    assert ends[0]['id']==starts[0]['id'] and ends[0]['agent_id']=='agent1' and ends[0]['duration_s']>=0
    assert all(ends[0][key]==0 for key in ('tokens_in','tokens_cached','tokens_out'))
    assert usage[0]['agent']==agent_type if re.fullmatch(r'[A-Za-z0-9_.:-]{1,100}',agent_type) else re.fullmatch(r'sha256:[a-f0-9]{64}',usage[0]['agent'])
    assert starts[0]['agent_type']==ends[0]['agent_type']==(agent_type if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,39}',agent_type) else 'unknown')
    assert all(e['policy_generation']==3 for e in events)
    labels = [json.loads(x) for x in (root/'.loomy/logs/display-context-v1.jsonl').read_text().splitlines()]
    assert len(labels)==1 and labels[0]['text']=='Approved title' and labels[0]['source']=='claude-description'
    assert 'PRIVATE_PROMPT' not in json.dumps(events+labels) and 'SENSITIVE_RESULT_SENTINEL' not in json.dumps(events+labels)
    print(f'PASS P02/P12/P23 {agent_type}: stdin result, one usage count, exact cost/model and scoped start/end reference')
# Truncation happens on the original description, preserving whole graphemes.
start_only = hook_script[:hook_script.index('# The exact same transcript')]
for i, description in enumerate(['a'*n for n in (95,96,97,199,200,201)]+['界'*129,'a'+'\u0301'*400, '\x1b[31mTitle\x1b[0m\n\u202e safe']):
    root = work/f'labels-{i}'; seed_policy(root,label_sources='claude-description')
    run(['/bin/bash','-c',start_only],env=dict(os.environ,REPO=str(repo),PROJECT=str(root),START=json.dumps({'session_id':'s','tool_use_id':'c','tool_input':{'subagent_type':'developer','description':description,'prompt':'PRIVATE_PROMPT'}})))
    events = rows(root); labels_path=root/'.loomy/logs/display-context-v1.jsonl'
    if i==7: assert not labels_path.exists() and 'label_ref' not in events[0] # first grapheme exceeds byte cap
    else:
        label=json.loads(labels_path.read_text()); text=label['text']
        assert len(text.encode())<=384 and '\x1b' not in text and '\u202e' not in text
        if i<6: assert text=='a'*min(len(description),96)
        if i==6: assert text=='界'*96
    assert 'PRIVATE_PROMPT' not in json.dumps(events) and 'task' not in events[0]
print('PASS P23 hook descriptions 95/96/97/199/200/201, Unicode byte/grapheme caps and control stripping')
for description in (None,'','\x1b[31m\x1b[0m\u202e'):
    root=work/('empty-description-'+str(len(list(work.glob('empty-description-*'))))); seed_policy(root,label_sources='claude-description')
    run(['/bin/bash','-c',start_only],env=dict(os.environ,REPO=str(repo),PROJECT=str(root),START=json.dumps({'session_id':'s','tool_use_id':'c','tool_input':{'subagent_type':'developer','description':description,'prompt':'PRIVATE_PROMPT'}})))
    assert not (root/'.loomy/logs/display-context-v1.jsonl').exists() and 'label_ref' not in rows(root)[0]
native_label_root=work/'native-description'; seed_policy(native_label_root,label_sources='claude-description')
native_label_sources=work/'native-description-sources'
run(['perl',str(repo/'tests/fixtures/claude-native.pl'),'seed',str(native_label_root),str(native_label_sources),'app','1'])
run(['perl',str(repo/'scripts/lib/claude-native.pl'),str(native_label_root),str(native_label_sources)])
label_file=native_label_root/'.loomy/logs/display-context-v1.jsonl'; original_labels=label_file.read_bytes()
native_label=json.loads(original_labels); assert native_label['text']=='PRIVATE_DESCRIPTION' and native_label['source']=='claude-description'
assert any(e.get('label_ref') for e in rows(native_label_root))
assert 'PRIVATE_' not in json.dumps(rows(native_label_root))
assert 'PRIVATE_DESCRIPTION' not in (native_label_root/'.loomy/logs/claude-native.idx').read_text()
run(['perl',str(repo/'scripts/lib/claude-native.pl'),str(native_label_root),str(native_label_sources)])
assert label_file.read_bytes()==original_labels
print('PASS P23 no-hook Claude description has one scoped label, no prompt/checkpoint copy, empty descriptions remain unavailable')
restricted=work/'hooks-restrict'; seed_policy(restricted,journal_content='legacy-excerpts',label_sources='claude-description',policy_generation=4)
env=dict(os.environ,REPO=str(repo),PROJECT=str(restricted),START=json.dumps({'session_id':'s','tool_use_id':'c','tool_input':{'subagent_type':'developer','description':'Approved title','prompt':'PRIVATE_PROMPT','run_in_background':True}}))
run(['/bin/bash','-c',start_only],env=env)
assert rows(restricted)[0]['task']=='Approved title'
seed_policy(restricted,policy_generation=5)
header=hook_script[:hook_script.index('ai_journal_agent_start')]
finish='''ai_journal_agent_stop "$PROJECT" '{"session_id":"s","agent_id":"a","agent_type":"developer"}' 0 'STATUS: blocked'
ai_journal_agent_return "$PROJECT" '{"session_id":"s","tool_use_id":"c","tool_response":{"agentId":"a"}}' '''
run(['/bin/bash','-c',header+finish],env=env)
fresh=rows(restricted)[1:]
assert any(e['type']=='delegation' and e['outcome']=='blocked' for e in fresh)
assert all(e['policy_generation']==5 and e['content_policy']=='structural-v1' and 'task' not in e and 'why' not in e for e in fresh)
print('PASS P03 hook stop/return rechecks restrictive generation instead of copying an old start excerpt')
# Stream relay bytes/exit status stay intact while links use the shared appender.
stream_root=work/'stream'; seed_policy(stream_root)
stream='''source "$REPO/scripts/lib/journal.sh"; ai_codex_bin() { :; }; source "$REPO/scripts/lib/launch.sh"; _loomy_cli_stream "$PROJECT/.loomy/logs/events.jsonl" d1 d1 /usr/bin/printf '%s\\n' '{"type":"thread.started","thread_id":"thread1"}' '{"item":{"type":"collab_tool_call","tool":"spawn_agent","sender_thread_id":"thread1","receiver_thread_ids":["thread2"]}}' '''
stream_output=run(['/bin/bash','-c',stream],env=dict(os.environ,REPO=str(repo),PROJECT=str(stream_root)))
assert [json.loads(x) for x in stream_output.splitlines()][0]['thread_id']=='thread1'
assert len(rows(stream_root))==2 and all(e['type']=='bridge_link' and drift(e,True) for e in rows(stream_root))
print('PASS P02 stream relay preserves provider bytes and projects exact nested session links')
# The public drift corpus includes CLI/app, both Codex protocols, late aliasing,
# owner closure, metadata relinking, terminal states and descendant activity.
poll_script = r'''
my ($module,$tool,$root,$sources)=@ARGV; require $module;
my $project=\&Loomy::LiveState::project_journal_event;
my $signature=\&Loomy::LiveState::content_signature;
{no warnings "redefine"; local *Loomy::LiveState::project_journal_event=sub {
    my $row=$project->(@_); print JSON::PP::encode_json([$_[1],$row]),"\n"; return $row;
};
 local *Loomy::LiveState::content_signature=sub {
    my ($w,$type,$value)=@_;
    my $body=ref($value) eq "HASH" ? $value : eval {JSON::PP::decode_json($value)};
    print JSON::PP::encode_json({nested_type=>"$type/checkpoint_value",body=>$body}),"\n" if ref($body) eq "HASH";
    return $signature->(@_);
 };
 for (1..3) {
    if ($tool eq "claude") {Loomy::ClaudeNative::poll($root,$sources)}
    else {Loomy::CodexNative::poll($root,$sources)}
 }
}
'''
native_inputs, native_outputs, nested_inputs = [], [], []
def nested_drift(kind,body):
    assert kind in manifest and '/' in kind, ('uncensused signature type',kind)
    assert not set(body)-set(manifest[kind]), ('uncensused signature keys',kind,set(body)-set(manifest[kind]))
cases = [('codex-native.pl','codex',['compact-seed','root-context','second-lead','wait','finish','end-owner'],[]),
         ('codex-v2-sessions.pl','codex',['seed','legacy-index','census-close','finish','midflight'],[])]
cases += [('claude-native.pl','claude',['seed','return','stop','idle'],[surface,background]) for surface in ('cli','app') for background in ('0','1')]
for number,(fixture,tool,actions,args) in enumerate(cases):
    root=work/f'public-native-{number}'; sources=root/'provider'; seed_policy(root)
    for action in actions:
        fixture_args=args if tool=='claude' else [str(os.getpid())]
        run(['perl',str(repo/'tests/fixtures'/fixture),action,str(root),str(sources),*fixture_args])
        raw=run(['perl','-e',poll_script,str(repo/f'scripts/lib/{tool}-native.pl'),tool,str(root),str(sources)])
        for captured in (json.loads(x) for x in raw.splitlines()):
            if isinstance(captured,dict):
                nested_drift(captured['nested_type'],captured['body']); nested_inputs.append(captured)
            else:
                original,projected=captured; preserve(original,projected); native_inputs.append(original)
    native_outputs.extend(rows(root))
for row in native_inputs: drift(row,False)
for row in native_outputs: drift(row,True)
assert {e['nested_type'] for e in nested_inputs}=={t for t in manifest if '/' in t}, 'missing nested signature constructor coverage'
try: nested_drift(nested_inputs[0]['nested_type'],dict(nested_inputs[0]['body'],unknown_key=1))
except AssertionError: pass
else: raise AssertionError('nested drift mutation survived')
print(f'PASS P19 {len(nested_inputs)} real signature bodies match every nested allowlist and reject an injected key')
assert any(e.get('multi_agent_version')=='v2' and e.get('cost_in')=='unknown' for e in native_outputs)
assert any(e.get('bridge')=='claude-native' and e.get('cost_in')=='usage' and e.get('cost_usd')==0 for e in native_outputs)
seen={e['type'] for e in outputs+native_outputs}
for root in work.glob('hooks-*'): seen.update(e['type'] for e in rows(root))
seen.update(e['type'] for e in rows(stream_root))
prompt_root=work/'prompt-hook'; seed_policy(prompt_root)
(prompt_root/'.loomy/brief.md').write_text('---\nai_mode: SOLO\nai_lead: codex\n---\n')
run(['/bin/bash',str(repo/'scripts/loomy-context.sh'),'--hook','prompt','--root',str(prompt_root)],input=json.dumps({'session_id':'prompt-session','prompt':'PRIVATE_PROMPT'}))
for row in rows(prompt_root): drift(row,True); seen.add(row['type'])
assert 'PRIVATE_PROMPT' not in json.dumps(rows(prompt_root))
expected={kind for kind in manifest if '/' not in kind}
assert seen==expected, ('missing/unreviewed event coverage',expected-seen,seen-expected)
print(f'PASS P19 all {len(seen)} event types, {len(native_inputs)} real native constructors and {len(native_outputs)} native emitted rows match public manifest')
# Enumerate every journal append boundary; diagnostic appenders have separate sinks.
appenders=set(); append_counts={}
for path in (repo/'scripts').rglob('*'):
    if path.suffix not in ('.sh','.pl'): continue
    text=path.read_text()
    if path.name=='content-policy.pl':
        assert re.search(r'sysopen[^\n]+\$LABELS[^\n]+O_APPEND',text), 'uncensused content-policy sink'
        assert 'events.jsonl' not in text
        continue
    if re.search(r'sysopen[^\n]+O_APPEND',text) and path.name!='watch-errors.pl':
        relative=str(path.relative_to(repo)); appenders.add(relative)
        append_counts[relative]=len(re.findall(r'sysopen[^\n]+O_APPEND',text))
assert appenders=={'scripts/lib/live-state.pl','scripts/lib/claude-native.pl','scripts/lib/codex-native.pl','scripts/lib/journal.sh'}, appenders
assert append_counts=={'scripts/lib/live-state.pl':1,'scripts/lib/claude-native.pl':1,'scripts/lib/codex-native.pl':1,'scripts/lib/journal.sh':2}, append_counts
print('PASS P19 journal O_APPEND census: shared appender, two native collectors and projected hook finisher only')
strict_module=work/'StrictJSON.pm'
strict_module.write_text("package StrictJSON; use JSON::PP (); my $new=\\&JSON::PP::new; no warnings 'redefine'; *JSON::PP::new=sub {$new->(@_)->allow_nonref(0)}; 1;\n")
strict_root=work/'strict-json'; seed_policy(strict_root,label_sources='claude-description')
run(['perl','-e','require $ARGV[0]; die unless Loomy::LiveState::journal_append("$ARGV[1]/.loomy/logs/events.jsonl",{type=>"delegation_start",id=>"strict",session=>"s"},undef,["delegation","strict","s","claude-description","Safe title"]);',str(repo/'scripts/lib/live-state.pl'),str(strict_root)],env=dict(os.environ,PERL5OPT='-I'+str(work)+' -MStrictJSON'))
assert rows(strict_root)[0]['id']=='strict' and rows(strict_root)[0]['label_ref']
print('PASS strict JSON::PP scalar contract retains journal rows and labels')

# The exact three-part UX example is recoverable from references alone.
name_root=work/'codex-three-names'; seed_policy(name_root,label_sources='explicit-user,explicit-lead,claude-description,codex-path-slug,codex-nickname,codex-role')
name_sources=work/'codex-name-sources'
run(['perl',str(repo/'tests/fixtures/codex-native.pl'),'compact-seed',str(name_root),str(name_sources),str(os.getpid())])
child=next(p for p in name_sources.rglob('rollout-*.jsonl') if p.name.endswith('000000000002.jsonl'))
source_lines=child.read_text().splitlines(); meta=json.loads(source_lines[0]); payload=meta['payload']
payload.update(agent_nickname='Lyra',agent_role='explorer'); payload['source']['subagent']['thread_spawn'].update(agent_nickname='Lyra',agent_role='explorer',agent_path='/root/inventory')
source_lines[0]=json.dumps(meta,separators=(',',':')); child.write_text('\n'.join(source_lines)+'\n')
run(['perl',str(repo/'scripts/lib/codex-native.pl'),str(name_root),str(name_sources)])
e=next(e for e in rows(name_root) if e.get('agent_id','').endswith('000000000002') and e.get('label_refs'))
labels={r['label_id']:r for r in map(json.loads,(name_root/'.loomy/logs/display-context-v1.jsonl').read_text().splitlines())}
assert ' '.join(labels[e['label_refs'][key]['label_id']]['text'] for key in ('nickname','role','slug'))=='Lyra explorer inventory'
assert all(labels[ref['label_id']]['project_id']==ref['project_id'] for ref in e['label_refs'].values())
assert 'Lyra' not in json.dumps(rows(name_root)) and 'inventory' not in json.dumps(rows(name_root))
print('PASS three scoped references rebuild exactly Lyra explorer inventory without journal text')
# Explicit native legacy descriptions retain prior excerpt behavior. Structural
# no-hook tests above still assert no description text in events/checkpoints.
legacy_native=work/'native-legacy-title'; seed_policy(legacy_native,journal_content='legacy-excerpts')
legacy_sources=work/'native-legacy-sources'
run(['perl',str(repo/'tests/fixtures/claude-native.pl'),'seed',str(legacy_native),str(legacy_sources),'app','1'])
run(['perl',str(repo/'scripts/lib/claude-native.pl'),str(legacy_native),str(legacy_sources)])
assert any(e.get('task')=='PRIVATE_DESCRIPTION' for e in rows(legacy_native) if e['type']=='delegation_start')
assert 'PRIVATE_PROMPT' not in json.dumps(rows(legacy_native))
print('PASS explicit native legacy description excerpt restored; prompt remains excluded')

# Injection at the public append boundary must never cut provider bytes/status.
fault_module=work/'WriterFault.pm'
fault_module.write_text('''package WriterFault;
BEGIN {
 require "'''+str(repo/'scripts/lib/live-state.pl')+'''";
 no warnings 'redefine';
 my $project=\\&Loomy::LiveState::project_journal_event; my $skipped=0;
 *Loomy::LiveState::project_journal_event=sub {die "injected native event failure" if ($ENV{WRITER_FAULT}//"") eq "native" && !$skipped++; $project->(@_)};
 my $append=\\&Loomy::LiveState::journal_append;
 *Loomy::LiveState::journal_append=sub {die "injected append failure" if ($ENV{WRITER_FAULT}//"") eq "relay"; $append->(@_)};
 my $line=\\&Loomy::LiveState::journal_event_line;
 *Loomy::LiveState::journal_event_line=sub {return if ($ENV{WRITER_FAULT}//"") eq "usage" && ($_[1]{model}//"") =~ /sonnet/; $line->(@_)};
 my $atomic=\\&Loomy::LiveState::atomic_file;
 *Loomy::LiveState::atomic_file=sub {die "injected cursor failure" if ($ENV{WRITER_FAULT}//"") eq "cursor" && $_[0] =~ /usage[.]idx$/; $atomic->(@_)};
}
1;
''')
fault_env=dict(os.environ,PERL5OPT='-I'+str(work)+' -MWriterFault',REPO=str(repo))
for tool in ('claude','codex'):
    root=work/('native-fault-'+tool); seed_policy(root)
    sources=work/('native-fault-'+tool+'-sources')
    args=['app','1'] if tool=='claude' else [str(os.getpid())]
    run(['perl',str(repo/f'tests/fixtures/{tool}-native.pl'),'seed',str(root),str(sources),*args])
    p=subprocess.run(['perl',str(repo/f'scripts/lib/{tool}-native.pl'),str(root),str(sources)],env=dict(fault_env,WRITER_FAULT='native'),text=True,capture_output=True)
    assert p.returncode==0 and 'event skipped' in p.stderr,(tool,p.returncode,p.stderr)
    assert any(e['type']=='delegation_start' for e in rows(root)),(tool,rows(root))
print('PASS both native collectors continue to later events after a per-event projection exception')
relay_root=work/'relay-fault'; seed_policy(relay_root)
provider_bytes='{"type":"thread.started","thread_id":"ok"}\n{"type":"turn.completed"}\nlast provider line\n'
provider=work/'relay-provider.sh'; provider.write_text("#!/bin/sh\nprintf '%s' '"+provider_bytes+"'\nexit 7\n")
relay_script='''source "$REPO/scripts/lib/journal.sh"; ai_codex_bin() { :; }; source "$REPO/scripts/lib/launch.sh"; _loomy_cli_stream "$PROJECT/.loomy/logs/events.jsonl" 'invalid parent prose' d1 /bin/sh "$PROVIDER"'''
p=subprocess.run(['/bin/bash','-c',relay_script],env=dict(fault_env,WRITER_FAULT='relay',PROJECT=str(relay_root),PROVIDER=str(provider)),text=True,capture_output=True)
assert p.returncode==7 and p.stdout==provider_bytes and 'relay continues' in p.stderr,(p.returncode,p.stdout,p.stderr)
print('PASS relay append exception preserves every provider byte and exit code 7')
# Two models form one accounting batch: a dropped event OR failed cursor commit
# leaves both the journal and cursor unadvanced; retry counts each model once.
for fault in ('usage','cursor'):
    root=work/('usage-fault-'+fault); seed_policy(root)
    tr=root/'usage.jsonl'
    tr.write_text(''.join(json.dumps({'type':'assistant','message':{'id':f'msg_{i}','model':model,'usage':{'input_tokens':10,'output_tokens':2}}},separators=(',',':'))+'\n' for i,model in enumerate(('claude-haiku-5-5','claude-sonnet-5-5'))))
    script='''source "$REPO/scripts/lib/journal.sh"; ai_price_long_list() { :; }; ai_price() { printf '1 2 .1'; }; ai_usage_record "$PROJECT" "$TRANSCRIPT" lead'''
    env=dict(fault_env,WRITER_FAULT=fault,PROJECT=str(root),TRANSCRIPT=str(tr))
    run(['/bin/bash','-c',script],env=env)
    assert not rows(root) and not (root/'.loomy/logs/usage.idx').exists(),fault
    env.pop('WRITER_FAULT')
    run(['/bin/bash','-c',script],env=env); run(['/bin/bash','-c',script],env=env)
    assert len(rows(root))==2 and sum(e['messages'] for e in rows(root))==2
    assert (root/'.loomy/logs/usage.idx').read_text().endswith('\t2\n')
print('PASS usage cursor never crosses a dropped event or failed commit; retry has no partial-batch double count')
# C-locale Unicode inputs never reach an external Perl argv as excerpts.
utf_root=work/'shell-utf8'; seed_policy(utf_root)
utf_script='''source "$REPO/scripts/lib/journal.sh"; ai_codex_bin() { :; }; source "$REPO/scripts/lib/launch.sh";
perl() { for arg in "$@"; do case "$arg" in *"$SECRET"*) exit 93 ;; esac; done; command perl "$@"; }
loomy_cli_bridge_start "$PROJECT" utf8 codex reviewer codex gpt-6-luna max read-only "$SECRET" 1 model "$SECRET"
'''
run(['/bin/bash','-c',utf_script],env=dict(os.environ,REPO=str(repo),PROJECT=str(utf_root),LC_ALL='C',SECRET='a'*199+'界秘密'))
assert len(rows(utf_root))==1 and 'task' not in rows(utf_root)[0]
# Real prompt path repairs permissions, retaining a structural request.
(root_dir:=prompt_root/'.loomy/logs').chmod(0o755); (root_dir/'events.jsonl').chmod(0o644)
run(['/bin/bash',str(repo/'scripts/loomy-context.sh'),'--hook','prompt','--root',str(prompt_root)],input=json.dumps({'session_id':'permissions','prompt':'SECRET_EXCERPT'}))
assert root_dir.stat().st_mode & 0o777 == 0o700 and (root_dir/'events.jsonl').stat().st_mode & 0o777 == 0o600
assert rows(prompt_root)[-1]['type']=='request' and 'SECRET_EXCERPT' not in json.dumps(rows(prompt_root))
print('PASS C-locale excerpt argv privacy, complete Unicode start, and real prompt mode tightening')
seed_policy(prompt_root,journal_content='legacy-excerpts')
prompt_json=json.dumps({'session_id':'unicode-prompt','prompt':'界'*61+'PRIVATE_PROMPT'})
run(['/bin/bash',str(repo/'scripts/loomy-context.sh'),'--hook','prompt','--root',str(prompt_root)],input=prompt_json)
assert rows(prompt_root)[-1]['excerpt']=='界'*60 and rows(prompt_root)[-1]['content_policy']=='legacy-excerpts-v1'
run(['/bin/bash',str(repo/'scripts/loomy-context.sh'),'--hook','prompt','--root',str(prompt_root)],input=prompt_json,env=dict(os.environ,LOOMY_JOURNAL_TASKS='0'))
assert 'excerpt' not in rows(prompt_root)[-1] and rows(prompt_root)[-1]['content_policy']=='structural-v1'
print('PASS real prompt callback: Unicode legacy excerpt bounded to 60 characters, TASKS veto builds none')

# Structural failover keeps the exact quota facts through start AND return.
quota_root=work/'quota-fields'; seed_policy(quota_root)
quota_script='''source "$REPO/scripts/lib/journal.sh"; source "$REPO/scripts/lib/failover.sh";
ai_switch_threshold() { printf 90; }; ai_quota() { printf '300 92 1999999999\\n'; }; _ai_window_label() { printf '5 h'; }
ai_ts_epoch() { printf 0; }; _lf_reason claude; lf_start "$PROJECT" claude codex "$LF_REASON" "$LF_RESUME_AT"; lf_end "$PROJECT"
'''
run(['/bin/bash','-c',quota_script],env=dict(os.environ,REPO=str(repo),PROJECT=str(quota_root)))
assert len(rows(quota_root))==2 and all(e['quota_window']=='5h' and e['used_percent']==92 for e in rows(quota_root))
print('PASS failover and return preserve quota_window=5h and used_percent=92')
# Native front matter facts survive independently of serialized key order.
front_root=work/'front-matter'; seed_policy(front_root)
(front_root/'.loomy/brief.md').write_text('---\nai_mode: SOLO\nai_lead: claude\nbudget: equilibre\n---\n')
(front_root/'.claude/agents').mkdir(parents=True)
(front_root/'.claude/agents/developer.md').write_text('---\nmodel: claude-sonnet-5-5\neffort: high\n---\n')
front_input=json.dumps({'session_id':'live','tool_use_id':'native-1','tool_input':{'subagent_type':'loomy-developer','description':'Approved description'}})
front_script='''source "$REPO/scripts/lib/models.sh"; source "$REPO/scripts/lib/journal.sh"; ai_journal_agent_start "$PROJECT" "$INPUT" 0'''
run(['/bin/bash','-c',front_script],env=dict(os.environ,REPO=str(repo),PROJECT=str(front_root),INPUT=front_input))
e=rows(front_root)[0]
assert (e['bridge'],e['role'],e['family'],e['model'],e['effort'],e['session'],e['id'])==('subagent','developer','claude','claude-sonnet-5-5','high','live','native-1')
print('PASS native front matter role/family/model/effort/session/id are retained')
# Parallel same-role completions preserve identity, duration, and both labels.
reverse_root=work/'reverse-hook'; seed_policy(reverse_root,label_sources='claude-description')
reverse_script='''source "$REPO/scripts/lib/models.sh"; source "$REPO/scripts/lib/journal.sh"
for id in t1 t2; do
 ai_journal_agent_start "$PROJECT" "{\\"session_id\\":\\"reverse\\",\\"tool_use_id\\":\\"$id\\",\\"tool_input\\":{\\"subagent_type\\":\\"developer\\",\\"description\\":\\"title $id\\",\\"run_in_background\\":true}}" 0
done
perl -MJSON::PP -MPOSIX=strftime -i -pe 'my $d=decode_json($_); $d->{ts}=strftime("%Y-%m-%dT%H:%M:%SZ",gmtime(time-($d->{id} eq "t1" ? 100 : 30))); $_=encode_json($d)."\\n"' "$PROJECT/.loomy/logs/events.jsonl"
for id in t1 t2; do ai_journal_agent_return "$PROJECT" "{\\"session_id\\":\\"reverse\\",\\"tool_use_id\\":\\"$id\\",\\"tool_response\\":{\\"agentId\\":\\"a$id\\",\\"isAsync\\":true}}"; done
for i in 1 2; do ai_journal_agent_stop "$PROJECT" '{"session_id":"reverse","agent_id":"at2","agent_type":"developer"}' 0 'STATUS: done' & done
wait
for id in t2 t1 t2; do ai_journal_agent_stop "$PROJECT" "{\\"session_id\\":\\"reverse\\",\\"agent_id\\":\\"a$id\\",\\"agent_type\\":\\"developer\\"}" 0 'STATUS: done'; done
'''
run(['/bin/bash','-c',reverse_script],env=dict(os.environ,REPO=str(repo),PROJECT=str(reverse_root)))
ends=[e for e in rows(reverse_root) if e['type']=='delegation']
assert [e['id'] for e in ends]==['t2','t1']
labels={e['label_id']:e for e in map(json.loads,(reverse_root/'.loomy/logs/display-context-v1.jsonl').read_text().splitlines())}
for e in ends:
    duration=100 if e['id']=='t1' else 30
    assert duration<=e['duration_s']<duration+10 and e['outcome']=='done' and 'task' not in e
    assert labels[e['label_ref']['label_id']]['text']=='title '+e['id']
print('PASS same-role reverse concurrent finish: two unique ends, exact labels/outcomes and source durations')
# Real pricing fixtures compare numeric JSON facts, independent of float spelling.
price_root=work/'prices'; seed_policy(price_root)
tr=price_root/'prices.jsonl'
tr.write_text(''.join(json.dumps({'type':'assistant','message':{'id':'msg_'+str(i),'model':'claude-haiku-5-5','usage':{'input_tokens':tin,'output_tokens':tout,'cache_creation_input_tokens':0,'cache_read_input_tokens':0}}},separators=(',',':'))+'\n' for i,(tin,tout) in enumerate(((50000,1000000),(1000000,0)))))
price_script='''source "$REPO/scripts/lib/models.sh"; source "$REPO/scripts/lib/journal.sh"; ai_usage_record "$PROJECT" "$TRANSCRIPT" lead'''
run(['/bin/bash','-c',price_script],env=dict(os.environ,REPO=str(repo),PROJECT=str(price_root),TRANSCRIPT=str(tr)))
assert sorted(e['cost_usd'] for e in rows(price_root))==[.5,.505]
advisor_root=work/'advisor-prices'; seed_policy(advisor_root)
tr=advisor_root/'advisor.jsonl'
tr.write_text(json.dumps({'type':'assistant','message':{'id':'msg_1','model':'claude-sonnet-5-5','usage':{'input_tokens':2,'cache_creation_input_tokens':100,'cache_read_input_tokens':1000,'output_tokens':50,'iterations':[{'input_tokens':2,'output_tokens':26,'type':'message'},{'input_tokens':35648,'output_tokens':476,'cache_read_input_tokens':0,'cache_creation_input_tokens':0,'cache_creation':{'ephemeral_5m_input_tokens':0,'ephemeral_1h_input_tokens':0},'type':'advisor_message','model':'claude-opus-5-5'}]}}},separators=(',',':'))+'\n')
run(['/bin/bash','-c',price_script],env=dict(os.environ,REPO=str(repo),PROJECT=str(advisor_root),TRANSCRIPT=str(tr)))
a=[e for e in rows(advisor_root) if e['type']=='advisor']
assert len(a)==1 and (a[0]['model'],a[0]['calls'],a[0]['tokens_in'])==('claude-opus-5-5',1,35648)
u=[e for e in rows(advisor_root) if e['type']=='usage']
assert len(u)==1 and u[0]['scope']=='lead' and u[0]['tool']=='claude' and u[0]['agent'] is None
assert u[0]['model']=='claude-sonnet-5-5' and u[0]['tokens_in']==102 and u[0]['tokens_cached']==1000 and u[0]['tokens_out']==50
assert a[0]['scope']=='lead' and a[0]['tool']=='claude' and a[0]['tokens_out']==476 and 'agent' not in a[0]
print('PASS Haiku long/base numeric costs [0.5, 0.505] and real advisor model/calls/tokens retained')

# Real bridge traps, without relying on removed task excerpts to locate a start.
import signal, time
for tool in ('codex','claude'):
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):
        root=work/f'bridge-{tool}-{sig.name}'; seed_policy(root)
        (root/'.loomy/brief.md').write_text('---\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\n---\n')
        pidfile=root/'stub.pid'
        env=dict(os.environ,LOOMY_PROJECT_ROOT=str(root),LOOMY_BRIDGE_OK='1',STUB_SLEEP='30',STUB_PID_FILE=str(pidfile))
        env.pop('LOOMY_NATIVE_NOW',None)
        output=root/'bridge-output'
        with output.open('w') as capture:
            process=subprocess.Popen(['/bin/bash',str(repo/f'scripts/loomy-delegate-{tool}.sh'),'architect','--effort','low','Interrupted Unicode 界 task'],cwd=root,env=env,stdout=capture,stderr=capture,start_new_session=True)
            try:
                deadline=time.monotonic()+12
                while time.monotonic()<deadline:
                    start=[e for e in rows(root) if e['type']=='delegation_start']
                    if start and pidfile.exists(): break
                    if process.poll() is not None: raise AssertionError(output.read_text()[-1600:])
                    time.sleep(.025)
                else: raise AssertionError('bridge did not start: '+output.read_text()[-1600:])
                process.send_signal(sig)
                assert process.wait(timeout=15)==128+sig.value
                ends=[e for e in rows(root) if e['type']=='delegation' and e['id']==start[0]['id']]
                assert len(ends)==1 and ends[0]['signal']==sig.value and ends[0]['status']=='interrupted',(tool,sig,ends)
                for key in ('id','role','family','model','effort','requested','requested_model','off_routing','sandbox'):
                    assert ends[0].get(key)==start[0].get(key),(tool,sig,key)
                assert 'task' not in ends[0] and 'why' not in ends[0]
            finally:
                if process.poll() is None: os.killpg(process.pid,signal.SIGKILL); process.wait()
                if pidfile.exists():
                    try: os.kill(int(pidfile.read_text()),signal.SIGKILL)
                    except ProcessLookupError: pass
        print(f'PASS {tool} {sig.name}: exactly one interrupted terminal event with start metadata')

PY

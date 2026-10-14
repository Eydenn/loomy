# Synthetic journal shaped like long-lived real projects: a live Claude app lead with finished/blocked/partial/
# running children and model aliases, a stale Codex session with a finished agent, empty stale sessions, and
# pre-schema bridge delegations that never recorded an end. No copied prompts, projects or transcripts.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
my ($root)=@ARGV;
my $now=1791853200;
sub ts { my @t=gmtime($_[0]); sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',$t[5]+1900,$t[4]+1,@t[3,2,1,0] }
make_path("$root/.loomy/logs");
open my $j,'>',"$root/.loomy/logs/events.jsonl" or die $!;
sub put { my ($at,$type,%f)=@_; print $j encode_json({ts=>ts($at),type=>$type,%f}),"\n" }
open my $b,'>',"$root/.loomy/brief.md" or die $!; print $b "---\nai_mode: SOLO\nai_lead: claude\n---\n\n# Fixture\n"; close $b;
open my $s,'>',"$root/.loomy/state" or die $!; print $s "phase=done\n"; close $s;

# Live Claude app lead: observed seconds ago.
my %live=(schema=>2,tool=>'claude',family=>'claude',session_key=>'claude:applead1',session=>'applead1',surface=>'app',agent_id=>'applead1',source=>'transcript');
put($now-3,'session_observed',%live,state=>'running',source_active=>1,cwd_relative=>'.',evidence=>'source lease');
sub child {
    my ($n,$task,$model,$start,$end,$status,$outcome)=@_;
    my %b=(%live,id=>"cl:applead1:call$n",turn_id=>"call$n",agent_id=>"applead1:call$n",parent_agent_id=>'claude:applead1',role=>'reviewer',task=>$task,model=>$model,effort=>'high');
    put($now-$start,'delegation_start',%b,bridge=>'claude-native');
    if (defined $end) { put($now-$end,'delegation',%b,bridge=>'claude-native',status=>$status,outcome=>$outcome,duration_s=>$start-$end) }
    else { put($now-2,'delegation_activity',%b,bridge=>'claude-native',state=>'running') }
}
child(1,'Alpha review','claude-sonnet-5-5',900,600,'ok','unknown');
child(2,'Beta review','sonnet',800,500,'ok','blocked');
child(3,'Gamma review','haiku',700,400,'ok','partial');
child(4,'Delta review','claude-opus-5-5',60,undef);

# Stale Codex session (hours old) with one finished native agent and nothing running.
my %old=(schema=>2,tool=>'codex',family=>'codex',session_key=>'codex:oldlead01',session=>'oldlead01',agent_id=>'oldlead01',source=>'rollout');
put($now-400000,'session_observed',%old,surface=>'cli',state=>'idle',source_active=>1,cwd_relative=>'.',evidence=>'source lease');
put($now-400000,'session_context',%old,model=>'gpt-6-luna',effort=>'medium');
my %oc=(%old,id=>'old-turn-1',agent_id=>'child-old',parent_agent_id=>'codex:oldlead01',role=>'executor',task=>'Old finished task',model=>'gpt-6-luna',effort=>'max',bridge=>'codex-native');
put($now-399000,'delegation_start',%oc);
put($now-398000,'delegation',%oc,status=>'ok',outcome=>'unknown',duration_s=>1000);

# Empty stale sessions: a hook-only start without any agent, and an observed session without agents.
put($now-300000,'session',event=>'start',tool=>'codex',pid=>4194001);
my %empty=(schema=>2,tool=>'codex',family=>'codex',session_key=>'codex:emptylead',session=>'emptylead',agent_id=>'emptylead',source=>'rollout');
put($now-350000,'session_observed',%empty,surface=>'cli',state=>'idle',source_active=>1,cwd_relative=>'.',evidence=>'source lease');
put($now-350000,'session_context',%empty,model=>'gpt-6-luna',effort=>'medium');

# Pre-schema bridge delegations without a session: one never ended (its launcher is long gone), one finished.
put($now-370000,'delegation_start',id=>'dlegacy001',pid=>4194002,bridge=>'codex',role=>'developer',family=>'codex',model=>'gpt-6.1-sol',effort=>'high',task=>'Legacy bridge run never ended');
put($now-371000,'delegation_start',id=>'dlegacy002',pid=>4194003,bridge=>'codex',role=>'executor',family=>'codex',model=>'gpt-6-luna',effort=>'max',task=>'Legacy bridge run finished');
put($now-370500,'delegation',id=>'dlegacy002',bridge=>'codex',family=>'codex',status=>'ok',outcome=>'unknown',duration_s=>500);
close $j or die $!;

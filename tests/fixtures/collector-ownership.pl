# LOCK LR cross-entrypoint ownership matrix (design section 8: L01, L02, L05, L09, L10) and the
# supported-pair adoption/rollback evidence (design section 5). Real entrypoints against synthetic
# roots; the collector guard is the L0 primitive, only a command lifetime elects.
#
# Matrix: every entrypoint (row) in every owner state (column).
#   F  free slot         : an electing entrypoint takes a transient guard once and releases it;
#                          a read-only one never elects.
#   O  owner collecting  : a compatible owner (another process) holds the slot: follow, mutate nothing.
#   D  owner draining    : same, and the entrypoint never takes the slot from a finishing owner.
#   U  unsafe lock       : collector.lock has an unsafe mode: refuse, mutate nothing, exit 0 for views.
# Proved here, with a complete-manifest check in O, D and U and a late (never polled) source so a leaking poll shows:
#   direct Codex CLI, direct Claude CLI, reducer CLI, reducer --migrate, loomy log --raw/--csv, loomy context,
#   status, tree, doctor                                           : F O D U
#   status/tree/doctor D also assert the draining owner is named (note text, doctor owner line).
# Proved in collector-views.sh (not repeated; text and counters, manifest-checked where noted):
#   status F (election count, release) and O (manifest) and U (manifest); status D (text only: the manifest is checked here)
#   tree F O; tree U; watch F O D U in a real pseudo-terminal (owner, drain, stall, follower, promotion, footers)
#   doctor O U and worktree layouts; project migrate F O refused (done / deferred / refused)
# Also here: mixed concurrent entrypoints, the release security gates (S1 tracked checkpoints, S2 oversize v2, S3 hardened
# git and escape-run warning) and the supported-pair evidence (E8: synthetic pre-LOCK writer always; real 0.17.9 build,
# four legs and an old watch beside a new one, when the history has the release).
use strict;
use warnings;
no warnings 'once';
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :mode :flock);
use File::Find qw(find);
use File::Path qw(make_path);
use IO::Select;
use IPC::Open3;
use JSON::PP ();
use POSIX qw(strftime WNOHANG);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes ();

my ($repo,$work)=@ARGV;
$repo=abs_path($repo//'') or die "repository required\n";
die "private fixture directory required\n" unless defined $work && !-e $work;
make_path($work,{mode=>0700}); $work=abs_path($work) or die;
$ENV{LOOMY_NATIVE_NOW}=1791853207;
delete @ENV{qw(LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_WATCH_ID)};
require "$repo/scripts/lib/runtime-paths.pl";
require "$repo/scripts/lib/collector-owner.pl";
require "$repo/scripts/lib/codex-native.pl";
require "$repo/scripts/lib/claude-native.pl";
my $json=JSON::PP->new->utf8->canonical;
local $SIG{ALRM}=sub {die "views fixture deadline\n"}; alarm 420;
my $NOW=$ENV{LOOMY_NATIVE_NOW};
my ($sessions,$projects)=("$ENV{CODEX_HOME}/sessions","$ENV{CLAUDE_CONFIG_DIR}/projects");
make_path($sessions,$projects);

sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($NOW+$_[0])).'.250Z'}
sub put {my ($p,$b)=@_; make_path(($p =~ m{^(.*)/[^/]+$})[0]); open my $h,'>',$p or die "write $p"; binmode $h; print {$h} $b; close $h or die}
sub rows {my $p=shift; make_path(($p =~ m{^(.*)/[^/]+$})[0]); open my $h,'>>',$p or die; print {$h} $json->encode($_),"\n" for @_; close $h or die}
sub bytes {open my $h,'<',$_[0] or return ''; binmode $h; local $/; return <$h>//''}
sub git {
    my ($root,@a)=@_; local @ENV{qw(GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT)}=(1,'/dev/null',0);
    system('git','-C',$root,'-c','core.hooksPath=/dev/null',@a)==0 or die "git failed\n";
}
# Name, mode, owner, size, mtime, inode and content of every entry: any change shows.
sub manifest {
    my ($root)=@_; my @rows;
    find({no_chdir=>1,wanted=>sub {
        my $path=$File::Find::name; my @s=lstat($path); return unless @s;
        push @rows,join('|',substr($path,length($root)),@s[0,1,2,3,4,5,7,9],S_ISREG($s[2]) ? sha256_hex(bytes($path)) : '');
    }},$root);
    return [sort @rows];
}
sub unchanged {
    my ($name,$root,$code)=@_; my $before=manifest($root); my @value=$code->();
    is_deeply(manifest($root),$before,"$name leaves the complete manifest unchanged"); return wantarray ? @value : $value[0];
}
my $pn=0;
sub project {
    my ($git,$logs)=@_; my $root="$work/p".++$pn; make_path($root,{mode=>0755}); mkdir "$root/.loomy",0700 or die;
    make_path("$root/.loomy/logs",{mode=>0700}) if $logs//1;
    if ($git) { git($root,'init','--quiet'); git($root,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','--allow-empty','-m','fixture') }
    return $root;
}
sub slug {my $p=$_[0]; $p =~ s/[^A-Za-z0-9]/-/g; return $p}
my $seq=0;
sub codex_source {
    my ($cwd)=@_; my $id=sprintf('00000000-0000-4000-8000-%012d',++$seq);
    my $day=strftime('%Y/%m/%d',gmtime($NOW)); my $path="$sessions/$day/rollout-fixture-$id.jsonl";
    rows($path,{timestamp=>ts(-59),type=>'session_meta',payload=>{id=>$id,cwd=>$cwd,timestamp=>ts(-59),source=>'cli'}},
        {timestamp=>ts(-30),type=>'turn_context',payload=>{turn_id=>"t$seq",model=>'gpt-6-luna',effort=>'max'}},
        {timestamp=>ts(-30),type=>'event_msg',payload=>{type=>'task_started',turn_id=>"t$seq"}},
        {timestamp=>ts(-29),type=>'response_item',payload=>{type=>'message',role=>'user',content=>'PRIVATE_PROMPT_CANARY'}});
    return {id=>$id,path=>$path};
}
sub claude_source {
    my ($cwd,$sid,$agent)=@_; my $path="$projects/".slug($cwd)."/$sid.jsonl";
    rows($path,{type=>'user',sessionId=>$sid,cwd=>$cwd,timestamp=>ts(-20),entrypoint=>'cli',uuid=>"u$sid",message=>{role=>'user',content=>'PRIVATE_PROMPT_CANARY'}},
        {type=>'assistant',sessionId=>$sid,cwd=>$cwd,timestamp=>ts(-19),uuid=>"a$sid",message=>{role=>'assistant',model=>'claude-sonnet-5-5',stop_reason=>undef,
            content=>[($agent ? {type=>'tool_use',id=>"call-$sid",name=>'Agent',input=>{subagent_type=>'developer',run_in_background=>JSON::PP::true}} : ())]}});
    return {id=>$sid,path=>$path};
}
sub journal {
    my ($root)=@_; open my $h,'<',"$root/.loomy/logs/events.jsonl" or return (); my @e=map {my $d=eval {$json->decode($_)}; $d ? $d : ()} <$h>; return @e;
}
sub seen {my ($root)=@_; return {map {($_->{session}//'')=>$_} grep {($_->{type}//'') eq 'session_observed' && ($_->{session}//'') ne ''} journal($root)}}
sub inspect_root {my ($root)=@_; return Loomy::CollectorOwner::inspect(Loomy::RuntimePaths::resolve($root))}

# ---------------------------------------------------------------- process helpers
sub run {
    my ($cmd,%o)=@_; local %ENV=(%ENV,%{$o{env}||{}}); delete @ENV{grep {!defined $ENV{$_}} keys %ENV};
    open my $null,'<','/dev/null' or die; my $err=gensym; my $pid=open3('<&'.fileno($null),my $out,$err,@$cmd); close $null;
    my ($o,$e)=('',''); my $sel=IO::Select->new($out,$err); my $end=Time::HiRes::time+($o{timeout}//90);
    while ($sel->count) {
        if (Time::HiRes::time>$end) {kill 'KILL',$pid; waitpid($pid,0); die "timeout: @$cmd\n"}
        for my $h ($sel->can_read(0.2)) {my $n=sysread($h,my $b,65536); if ($n) {($h==$out ? $o : $e).=$b} else {$sel->remove($h)}}
    }
    waitpid($pid,0); return {rc=>$?>>8,out=>$o,err=>$e,all=>$o.$e};
}
sub status {run(['bash',"$repo/scripts/loomy-status.sh",'--root',shift],@_)}
sub tree {run(['bash',"$repo/scripts/loomy-tree.sh",'--once','--root',shift],@_)}
sub doctor {run(['bash',"$repo/scripts/loomy-doctor.sh",'--root',shift],@_)}
sub loomy_log {run(['bash',"$repo/scripts/loomy-log.sh",'--root',shift,@_[0..$#_]])}
# A child that elects and keeps the slot until released. mode drain: it publishes draining first.
sub hold {
    my ($root,$mode)=@_; pipe(my $r,my $w) or die; pipe(my $rr,my $rw) or die;
    my $pid=fork; die unless defined $pid;
    if (!$pid) {
        close $w; close $rr;
        my $ctx=Loomy::RuntimePaths::resolve($root); my $a=Loomy::CollectorOwner::try_acquire($ctx,'fixture-build',1);
        print {$rw} ($a->{status} eq 'owned' ? "ok\n" : "no $a->{status} $a->{reason}\n"); close $rw;
        Loomy::CollectorOwner::begin_drain($a->{guard}) if ($mode//'') eq 'drain' && $a->{guard};
        <$r>; eval {Loomy::CollectorOwner::release($a->{guard})} if $a->{guard}; POSIX::_exit(0);
    }
    close $r; close $rw; my $line=<$rr>; die "holder failed: $line" unless defined $line && $line eq "ok\n";
    return {pid=>$pid,pipe=>$w};
}
sub drop {my $h=shift; close $h->{pipe}; waitpid($h->{pid},0)}
# One watch, driven through pipes as the exit regressions do.
sub start_watch {
    my ($root,%o)=@_; local %ENV=(%ENV,%{$o{env}||{}});
    my $err=gensym; my $pid=open3(my $in,my $out,$err,'bash',"$repo/scripts/loomy-status.sh",'--root',$root,'--watch');
    return {pid=>$pid,in=>$in,out=>$out,err=>$err,sel=>IO::Select->new($out,$err),o=>'',e=>''};
}
sub pump {
    my ($w,$secs)=@_; my $end=Time::HiRes::time+$secs;
    while (Time::HiRes::time<$end && $w->{sel}->count) {
        for my $h ($w->{sel}->can_read(0.05)) {my $n=sysread($h,my $b,65536); if ($n) {($h==$w->{out} ? $w->{o} : $w->{e}).=$b} else {$w->{sel}->remove($h)}}
    }
}
sub wait_for {my ($w,$code,$secs)=@_; my $end=Time::HiRes::time+$secs; while (Time::HiRes::time<$end) {return 1 if $code->(); $w ? pump($w,0.1) : Time::HiRes::sleep(0.1)} return $code->()}
sub finish_watch {
    my ($w,$secs)=@_; my $t0=Time::HiRes::time; my $done=0;
    while (Time::HiRes::time<$t0+$secs) { if (waitpid($w->{pid},WNOHANG)==$w->{pid}) {$done=1; last} pump($w,0.05) }
    pump($w,0.3); return {done=>$done,elapsed=>Time::HiRes::time-$t0,rc=>$?>>8};
}
sub children_of {my ($pid)=@_; open my $ps,'-|','ps','-axo','pid=,ppid=,command=' or return (); my @r=grep {/^\s*\d+\s+$pid\s+/} <$ps>; close $ps; return @r}
sub sampler_pid {my ($w)=@_; my ($row)=grep {/perl -MIO::Select -MTime::HiRes/} children_of($w->{pid}); return $row && $row =~ /^\s*(\d+)/ ? $1 : undef}
END {for my $h (@main::ZOMBIE) {kill 'KILL',$h}}

# Counts calls of the collector entry points in every perl a command starts.
make_path("$work/lib");
put("$work/lib/CountCalls.pm",<<'PM');
package CountCalls;
use strict; use warnings;
my %targets=('collector-owner.pl'=>[qw(Loomy::CollectorOwner::try_acquire)],'codex-native.pl'=>[qw(Loomy::CodexNative::poll)],
    'claude-native.pl'=>[qw(Loomy::ClaudeNative::poll)],'live-state.pl'=>[qw(Loomy::LiveState::checkpoint_peek Loomy::LiveState::follower_read Loomy::LiveState::migrate_checkpoints)]);
my %done;
BEGIN {
    *CORE::GLOBAL::require=sub {
        my ($f)=@_; my $r=CORE::require($f);
        if (!ref($f) && $f =~ m{([^/]+\.pl)\z} && $targets{$1} && !$done{$f}++) {
            for my $name (@{$targets{$1}}) {
                no strict 'refs'; no warnings 'redefine'; my $orig=\&{$name}; my $short=$name; $short =~ s/.*:://;
                *{$name}=sub { if (defined $ENV{COUNT_LOG} && open my $h,'>>',$ENV{COUNT_LOG}) {print {$h} "$short\n"; close $h} goto &$orig };
            }
        }
        return $r;
    };
}
1;
PM
sub counted {
    my ($code)=@_; my $log="$work/count.".++$pn; unlink $log;
    local $ENV{COUNT_LOG}=$log; local $ENV{PERL5OPT}="-I$work/lib -MCountCalls";
    my $r=$code->(); my %c; if (open my $h,'<',$log) {$c{$_}++ for map {chomp; $_} <$h>}
    return ($r,\%c);
}


# ---------------------------------------------------------------- entrypoint table
sub script_run {my ($lib,@a)=@_; return run(['perl',"$repo/scripts/lib/$lib",@a],timeout=>120)}
my %E=(
    codex  =>{elect=>1,run=>sub {script_run('codex-native.pl',$_[0],$sessions)}},
    claude =>{elect=>1,run=>sub {script_run('claude-native.pl',$_[0],$projects)}},
    reducer=>{elect=>1,run=>sub {script_run('live-state.pl',$_[0],$sessions)}},
    migrate=>{elect=>1,run=>sub {script_run('live-state.pl','--migrate',$_[0])},marker=>1},
    lograw =>{elect=>0,run=>sub {run(['bash',"$repo/scripts/loomy-log.sh",'--root',$_[0],'--raw'])}},
    logcsv =>{elect=>0,run=>sub {run(['bash',"$repo/scripts/loomy-log.sh",'--root',$_[0],'--csv'])}},
    context=>{elect=>0,run=>sub {run(['bash',"$repo/scripts/loomy-context.sh",'--root',$_[0]])}},
    status =>{elect=>1,run=>sub {status($_[0])},drain=>qr/Owner is finishing its batch/},
    tree   =>{elect=>1,run=>sub {tree($_[0])},drain=>qr/Owner is finishing its batch/},
    doctor =>{elect=>0,run=>sub {doctor($_[0])},drain=>qr/Live tracking owner: draining/},
);
sub fresh {
    my ($e)=@_; my $p=project(1); codex_source($p); claude_source($p,'claude-'.(++$seq),1);
    status($p);   # one owned command first: identity, checkpoints and marker exist
    claude_source($p,'claude-late-'.(++$seq),1);   # a source nobody has polled yet: a non-owner that polls would journal it
    unlink "$p/.loomy/logs/checkpoint-v2" if $e->{marker};
    return $p;
}
sub observed {my ($p)=@_; scalar grep {($_->{type}//'') eq 'session_observed'} journal($p)}

# ---------------------------------------------------------------- E1-E6: entrypoint x owner state
for my $name (qw(codex claude reducer migrate lograw logcsv context status tree doctor)) {
    my $e=$E{$name};
    # F: a free slot.
    {
        my $p=fresh($e); my $obs0=observed($p);
        my ($r,$c)=counted(sub {$e->{run}->($p)});
        is($r->{rc},0,"E-$name F: exits 0");
        if ($e->{elect}) {
            cmp_ok($c->{try_acquire}//0,'>=',1,"E-$name F: elects through the guard (".($c->{try_acquire}//0).' attempt(s))');
            is(inspect_root($p)->{reason},'free',"E-$name F: the transient guard is released");
            ok(-f "$p/.loomy/logs/checkpoint-v2","E-$name F: the migration marker is written under the guard") if $e->{marker};
        } else {
            ok(!$c->{try_acquire},"E-$name F: a read-only entrypoint never elects");
        }
    }
    # O: a compatible owner collecting. D: the same owner draining.
    for my $state (qw(O D)) {
        my $p=fresh($e); my $obs0=observed($p); my $h=hold($p,$state eq 'D' ? 'drain' : undef);
        ok(wait_for(undef,sub {($state eq 'D' ? (inspect_root($p)->{record}{state}//'') eq 'draining' : inspect_root($p)->{status} eq 'busy')},10),"E-$name $state: the holder is published before the manifest is taken");
        my $r; unchanged("E-$name $state",$p.'/.loomy',sub {$r=$e->{run}->($p)});
        is($r->{rc},0,"E-$name $state: exits 0 as a follower");
        is(observed($p),$obs0,"E-$name $state: the late source was not journaled by a non-owner");
        like($r->{all},$e->{drain},"E-$name D: the draining owner is named") if $state eq 'D' && $e->{drain};
        ok(!-f "$p/.loomy/logs/checkpoint-v2","E-$name $state: no migration marker was written by a non-owner") if $e->{marker};
        is(inspect_root($p)->{reason},'locked',"E-$name $state: the real owner still holds the lock");
        drop($h);
    }
    # U: an unsafe lock mode is refused, never repaired.
    {
        my $p=fresh($e); my $lock="$p/.loomy/logs/collector.lock"; chmod 0644,$lock or die;
        my $r; unchanged("E-$name U",$p.'/.loomy',sub {$r=$e->{run}->($p)});
        is($r->{rc},0,"E-$name U: exits 0 under an unsafe lock");
        ok(!-f "$p/.loomy/logs/checkpoint-v2","E-$name U: no migration marker under an unsafe lock") if $e->{marker};
        is(((stat $lock)[2] & 07777),0644,"E-$name U: the lock is left exactly as found");
    }
}

# A real v1 index under the transient guard (the guarded migration must write it, not only mark a v2 store).
{
    my $p=fresh($E{migrate}); my $idx="$p/.loomy/logs/codex-native.idx"; put($idx,$json->encode({version=>1,files=>{},seen=>{}})); chmod 0600,$idx;
    my $r=$E{migrate}{run}->($p); is($r->{rc},0,'E-migrate F v1: exits 0'); unlike($r->{all},qr/uninitialized|INVALID_GUARD|Use of/,'E-migrate F v1: no Perl diagnostics');
    is($json->decode(bytes($idx))->{version},2,'E-migrate F v1: the index was upgraded under the guard'); ok(-f "$p/.loomy/logs/checkpoint-v2",'E-migrate F v1: the marker is written');
    is(inspect_root($p)->{reason},'free','E-migrate F v1: the slot is free again');
}

# The reducer follower still prints the stored projection (it reads the journal, nothing else).
{
    my $p=fresh({}); my $own=run(['perl',"$repo/scripts/lib/live-state.pl",$p,$sessions]); my $h=hold($p);
    my $fol=run(['perl',"$repo/scripts/lib/live-state.pl",$p,$sessions]); drop($h);
    is($fol->{rc},0,'E-reducer O: the follower reducer exits 0'); ok(length($fol->{out}),'E-reducer O: the follower reducer still prints the stored projection');
    my $nrm=sub {join "\n",grep {!/^S\|/} split /\n/,shift}; is($nrm->($fol->{out}),$nrm->($own->{out}),'E-reducer O: and it equals the owner reducer projection');
}
# The direct adapters with a held bare compat entry keep their documented signature (no guard needed): not elected here.
{
    my $p=fresh({}); my $r=run(['perl','-e','require "$ARGV[0]/scripts/lib/codex-native.pl"; my $x=Loomy::CodexNative::poll($ARGV[1],$ARGV[2]); print defined($x)?"ok":"undef"',$repo,$p,$sessions]);
    is($r->{out},'ok','E-codex compat: a bare library call keeps its pre-LOCK single-root entry (no election, no guard)');
    ok(!-e "$p/.loomy/logs/collector.lock.new",'E-codex compat: and creates no ownership artifact');
}

# ---------------------------------------------------------------- E7: every electing entrypoint at once
{
    my $ref=fresh({}); my $conc=project(1); codex_source($conc); claude_source($conc,'claude-e7',1); status($conc);
    my @jobs; for my $i (1..2) {for my $k (qw(codex claude reducer status tree)) {
        my $pid=fork; die unless defined $pid;
        if (!$pid) {my $r=$k eq 'status' ? status($conc) : $k eq 'tree' ? tree($conc) : $E{$k}{run}->($conc); POSIX::_exit($r->{rc}==0 ? 0 : 1)}
        push @jobs,$pid;
    }}
    my $bad=0; for my $pid (@jobs) {waitpid($pid,0); $bad++ if $?}
    is($bad,0,'E7 ten simultaneous entrypoints (direct Codex, Claude, reducer, status, tree) all succeed');
    my %key; $key{$_->{native_key}}++ for grep {defined $_->{native_key}} journal($conc);
    ok(!grep({$_>1} values %key),'E7 no duplicate native key across mixed entrypoints');
    is(inspect_root($conc)->{reason},'free','E7 every transient guard was released');
}


# ---------------------------------------------------------------- S1-S3: release security gates
{
    # S1: a clone-shipped checkpoint (tracked in the index) is refused before any preparation; mode is not a criterion.
    my $p=project(1); codex_source($p); claude_source($p,'claude-s1',1); status($p);
    my $idx="$p/.loomy/logs/codex-native.idx"; chmod 0644,$idx or die;
    git($p,'add','-f','.loomy/logs/codex-native.idx'); git($p,'-c','user.name=F','-c','user.email=f@example.invalid','commit','--quiet','-m','ships a checkpoint');
    my $gl="$work/git-calls"; unlink $gl; make_path("$work/fakegit");
    put("$work/fakegit/git","#!/bin/sh\necho \"\$*\" >> '$gl'\nexec /usr/bin/git \"\$@\"\n"); chmod 0755,"$work/fakegit/git";
    my ($r,$c)=counted(sub {unchanged('S1 status over a tracked checkpoint',"$p/.loomy",sub {run(['bash',"$repo/scripts/loomy-status.sh",'--root',$p],env=>{PATH=>"$work/fakegit:$ENV{PATH}"})})});
    is($r->{rc},0,'S1 status exits 0'); like($r->{all},qr{codex-native\.idx cannot be used.*delete that file},'S1 status names the tracked checkpoint with the clone-shipped remedy');
    ok(!$c->{try_acquire},'S1 no election, hence no preparation, was attempted');
    is(((stat $idx)[2] & 07777),0644,'S1 the tracked checkpoint keeps its mode (not chmod-ed to 0600, so the signal survives)');
    my $t=unchanged('S1 tree over a tracked checkpoint',"$p/.loomy",sub {tree($p)}); like($t->{all},qr{codex-native\.idx cannot be used},'S1 tree names it too');
    my $d=unchanged('S1 doctor over a tracked checkpoint',"$p/.loomy",sub {doctor($p)}); like($d->{all},qr{\.loomy/logs/codex-native\.idx.*shipped with this clone},'S1 doctor names it');
    my @ls=grep {/ls-files/} split /\n/,bytes($gl);
    ok(@ls && !grep({!/core\.fsmonitor=false/ || !/core\.hooksPath=\/dev\/null/} @ls),'S1 every index read runs with fsmonitor and hooks disabled ('.scalar(@ls).' call(s))');
    # A tracked marker is refused as well; an untracked 0644 index still upgrades (the plain-mode refusal was rejected).
    my $q=project(1); codex_source($q); status($q); my $qi="$q/.loomy/logs/codex-native.idx"; chmod 0644,$qi or die;
    $r=status($q); is($r->{rc},0,'S1 an untracked 0644 checkpoint is still accepted'); is(((stat $qi)[2] & 07777),0600,'S1 and upgraded to 0600 by the preparation');
    unlike($r->{all},qr/cannot be used/,'S1 with no refusal note');
    my $m=project(1); status($m); put("$m/.loomy/logs/checkpoint-v2","2\n"); git($m,'add','-f','.loomy/logs/checkpoint-v2'); git($m,'-c','user.name=F','-c','user.email=f@example.invalid','commit','--quiet','-m','marker');
    like(status($m)->{all},qr{checkpoint-v2 cannot be used},'S1 a tracked migration marker is refused');
    # The one-shot adapter command line stays git-free.
    my $ctr; { my $g="$work/git-trace"; unlink $g; my $fp=fresh({});
        put("$work/fakegit/git","#!/bin/sh\necho called >> '$g'\nexec /usr/bin/git \"\$@\"\n"); chmod 0755,"$work/fakegit/git";
        local $ENV{PATH}="$work/fakegit:$ENV{PATH}"; $E{codex}{run}->($fp); $ctr=-e $g ? 1 : 0 }
    is($ctr,0,'S1 the direct adapter command line never runs git');
}
{
    # S2: an oversize v2 manifest is refused fast and cheaply.
    my $p=project(1); status($p); my $idx="$p/.loomy/logs/codex-native.idx";
    put($idx,'{"version":2,"files":{'.join(',',map {"\"/s/$_\":{\"o\":1,\"pad\":\"".('x' x 200)."\"}"} 1..30000).'}}'); chmod 0600,$idx;
    my $size=-s $idx; cmp_ok($size,'>',4*1024*1024,"S2 the crafted manifest is $size bytes");
    my $r=run(['perl','-e',q{
        require "$ARGV[0]/scripts/lib/live-state.pl"; my $t=Time::HiRes::time();
        my $k=Loomy::LiveState::checkpoint_peek($ARGV[1]); my $ms=1000*(Time::HiRes::time()-$t);
        my $rss=`ps -o rss= -p $$`; $rss =~ s/\D//g; printf "%s %.0f %d\n",($k->{status}//'?'),$ms,$rss/1024;
    },$repo,$idx]); my ($st,$ms,$mb)=split ' ',$r->{out};
    isnt($st,'valid','S2 an oversize v2 manifest is not read as valid'); cmp_ok($ms,'<',500,"S2 refused fast ($ms ms)"); cmp_ok($mb,'<',120,"S2 low RSS ($mb MB)");
    # A legacy v1 index larger than 2 MiB still migrates (the 32 MiB bound is kept only there).
    my $q=project(1); status($q); my $qi="$q/.loomy/logs/codex-native.idx"; unlink "$q/.loomy/logs/checkpoint-v2";
    put($qi,'{"version":1,"files":{},"seen":{'.join(',',map {"\"k$_\":1"} 1..250000).'}}'); chmod 0600,$qi; cmp_ok(-s $qi,'>',2*1024*1024,'S2 the legacy index is above the v2 cap');
    $r=$E{migrate}{run}->($q); is($r->{rc},0,'S2 the legacy migration exits 0'); is($json->decode(bytes($qi))->{version},2,'S2 and upgrades a v1 index above 2 MiB');
}
{
    # S3: hardened git for the runtime-path helper, and no warning from the escape-run fallback.
    my $p=project(1); my $sentinel="$work/rp-sentinel"; git($p,'config','core.fsmonitor',"touch $sentinel");
    my $plain=run(['git','-C',$p,'status','--porcelain']); my $sens=-e $sentinel; unlink $sentinel;
    run(['perl','-e','require "$ARGV[0]/scripts/lib/runtime-paths.pl"; Loomy::RuntimePaths::_git($ARGV[1],"status","--porcelain")',$repo,$p]);
    ok(!-e $sentinel,'S3 runtime-paths git calls disable fsmonitor'.($sens ? '' : ' (sensitivity not reproducible with this git)'));
    my $w=run(['perl','-e',q{require "$ARGV[0]/scripts/lib/live-state.pl"; my @w; local $SIG{__WARN__}=sub{push @w,@_};
        my $d=Loomy::LiveState::checkpoint_decode('{"a":"'.("\\\\n" x 70000).'"}'); print length($d->{a})," ",scalar(@w),"\n"},$repo]);
    is($w->{out},"70000 0\n",'S3 a 70000-escape run decodes with no warning that could set the sampler failure flag');
}

# ---------------------------------------------------------------- E8: supported pairs, adoption and rollback (design 5)
# The pre-LOCK writer is the unguarded compatibility entry the adapters still keep: idx.lock-serialized,
# single root, no collector.lock, no record. It is the same call SHAPE a pre-LOCK sampler makes (unguarded poll of
# each source), run through the CURRENT adapter code: it models "a writer that ignores the lock", not the 0.17.9 code
# itself. The real 0.17.9 build is exercised separately below when the repository history has it.
sub legacy_poll {
    my ($root)=@_; return run(['perl','-e',q{
        my ($repo,$root,$sessions,$projects)=@ARGV; require "$repo/scripts/lib/codex-native.pl"; require "$repo/scripts/lib/claude-native.pl";
        Loomy::CodexNative::poll($root,$sessions); Loomy::ClaudeNative::poll($root,$projects); print "legacy ok\n";
    },$repo,$root,$sessions,$projects]);
}
sub dup_keys {my ($p)=@_; my %key; $key{$_->{native_key}}++ for grep {defined $_->{native_key}} journal($p); return scalar grep {$_>1} values %key}
{
    # Quiescent sequential pair: legacy (0.17.9 shape) -> new -> legacy -> new, one store, nothing lost or doubled.
    my $p=project(1); codex_source($p); claude_source($p,'claude-e8',1);
    my $r=legacy_poll($p); is($r->{out},"legacy ok\n",'E8 the pre-LOCK entry runs (0.17.9 shape)');
    ok(!-e "$p/.loomy/logs/collector.lock",'E8 the pre-LOCK entry leaves no collector.lock: an empty new lock is no proof of adoption');
    my $n1=observed($p); cmp_ok($n1,'>=',1,'E8 the pre-LOCK writer journaled the sources');
    $r=status($p); is($r->{rc},0,'E8 the new build reads and continues over a pre-LOCK store'); is(observed($p),$n1,'E8 no source is observed twice after the upgrade');
    is(dup_keys($p),0,'E8 no duplicate native key after the upgrade'); is(inspect_root($p)->{reason},'free','E8 the new command released its guard');
    $r=legacy_poll($p); is($r->{out},"legacy ok\n",'E8 rollback: the pre-LOCK entry runs over the upgraded store');
    is(observed($p),$n1,'E8 rollback: no source is observed twice after the rollback'); is(dup_keys($p),0,'E8 rollback: no duplicate native key');
    $r=tree($p); is($r->{rc},0,'E8 re-upgrade: the new build runs again'); is(dup_keys($p),0,'E8 re-upgrade: still no duplicate'); is(observed($p),$n1,'E8 re-upgrade: still one observation per source');
}
{
    # An old writer that ignores collector.lock is not fenced: the documented limit (design 5.2). The new
    # owner is not disturbed and nothing is claimed about the old one; the supported path is quiescence.
    my $p=project(1); codex_source($p); claude_source($p,'claude-e8b',1); status($p);
    my $h=hold($p); my $rec=bytes("$p/.loomy/logs/collector-owner-v1.json");
    my $r=legacy_poll($p); is($r->{out},"legacy ok\n",'E8 limit: an old writer still runs while a new owner holds the lock (it cannot be fenced)');
    is(bytes("$p/.loomy/logs/collector-owner-v1.json"),$rec,'E8 limit: the old writer never touches the owner record');
    is(inspect_root($p)->{reason},'locked','E8 limit: the new owner keeps its lock and its epoch'); drop($h);
    is(dup_keys($p),0,'E8 limit: the idx.lock-serialized old writer does not duplicate native keys');
    is(inspect_root($p)->{reason},'free','E8 limit: the slot is free once the new owner is gone');
}
{
    # Rollback of an unsupported pair, from the user side: a newer protocol record is refused, never rewritten (L10).
    my $p=project(1); status($p); my $rec="$p/.loomy/logs/collector-owner-v1.json"; put($rec,'{"schema":1,"protocol":2}'."\n"); chmod 0600,$rec;
    my $before=manifest("$p/.loomy"); my $r=status($p);
    is($r->{rc},0,'E8 a newer protocol record keeps the view usable'); is_deeply(manifest("$p/.loomy"),$before,'E8 and is preserved untouched');
}
# The real 0.17.9 build (the release this one replaces), found by history: the release tag when present, else the newest
# commit whose VERSION is 0.17.9 and that predates the collector guard (the LOCK work also carried 0.17.9 on its branch).
sub baseline_commit {
    return undef unless -e "$repo/.git";
    my $t=`git -C '$repo' rev-parse --verify --quiet 'v0.17.9^{commit}' 2>/dev/null`; chomp $t; return $t if $t =~ /\A[0-9a-f]{40}\z/;
    open my $l,'-|','git','-C',$repo,'log','--format=%H','-n','600','--','VERSION' or return undef;
    while (my $c=<$l>) {
        chomp $c; my $v=`git -C '$repo' show '$c:VERSION' 2>/dev/null`; chomp $v; next unless $v eq '0.17.9';
        next if system("git -C '$repo' cat-file -e '$c:scripts/lib/collector-owner.pl' 2>/dev/null")==0;
        return $c;
    }
    return undef;
}
{
    my $base=baseline_commit(); my $old="$work/old-0.17.9"; my $have=0;
    if ($base) { make_path($old); $have=system("git -C '$repo' archive '$base' | tar -x -C '$old'")==0 && -f "$old/VERSION" }
    my $N=20;   # assertions in this block when the baseline exists
    SKIP: {
        if (!$have) {
            fail('E8 the 0.17.9 baseline is required (LOOMY_REQUIRE_BASELINE=1) but the history has none') if $ENV{LOOMY_REQUIRE_BASELINE};
            diag('E8 SKIPPED: no 0.17.9 release in this checkout history (shallow clone or exported archive): real-build pair evidence not run');
            skip 'no 0.17.9 release in the checkout history (shallow clone or export): real-build pair evidence skipped',$N;
        }
        chomp(my $v=bytes("$old/VERSION")); is($v,'0.17.9','E8 the comparison build is 0.17.9 ('.substr($base,0,7).')');
        my $p=project(1); my @ids; my $leg=0; codex_source($p); push @ids,claude_source($p,'claude-e8c',1)->{id};
        my $oldst=sub {run(['bash',"$old/scripts/loomy-status.sh",'--root',$p],env=>{LOOMY_HOME=>$old})};
        my $oldtree=sub {run(['bash',"$old/scripts/loomy-tree.sh",'--once','--root',$p],env=>{LOOMY_HOME=>$old})};
        # Four legs, one new Claude source before each: 0.17.9 -> 0.17.10 -> 0.17.9 -> 0.17.10 over one store.
        for my $who (qw(old new old new)) {
            push @ids,claude_source($p,'claude-e8c-'.$leg,1)->{id} if $leg++>0;
            my $r=$who eq 'old' ? $oldst->() : status($p); is($r->{rc},0,"E8 leg $leg ($who build) runs under quiescence");
            is(observed($p),scalar(@ids),"E8 leg $leg: every source added so far is observed once in the shared journal ($who build)");
        }
        is(dup_keys($p),0,'E8 four legs: no duplicate native key');
        # Readable both ways: each build shows the checkpoints and journal the other one wrote.
        my $nt=tree($p); my $ot=$oldtree->(); is($nt->{rc},0,'E8 the new tree reads the store the old build wrote'); is($ot->{rc},0,'E8 the old tree reads the store the new build wrote');
        my $shape=sub {my $t=shift; $t =~ s/\d\d:\d\d:\d\d//g; $t =~ s/[^\w\n ]//g; scalar(grep {/developer/i} split /\n/,$t)};
        is($shape->($ot->{all}),$shape->($nt->{all}),'E8 both builds show the same agent rows (readable both ways)');
        is(inspect_root($p)->{reason},'free','E8 the slot is free after the pair');
        # An old watch beside a new one: both run, the old one is not fenced, the new owner is undisturbed.
        my $ow; { local %ENV=(%ENV,LOOMY_HOME=>$old); my $err=gensym; my $pid=open3(my $in,my $out,$err,'bash',"$old/scripts/loomy-status.sh",'--root',$p,'--watch'); $ow={pid=>$pid,in=>$in,out=>$out,err=>$err,sel=>IO::Select->new($out,$err),o=>'',e=>''} }
        pump($ow,2); my $nw=start_watch($p);
        ok(wait_for($nw,sub {my $i=inspect_root($p); $i->{status} eq 'busy' && ($i->{record}{state}//'') eq 'collecting'},20),'E8 beside an old watch: the new watch still elects (the old one holds no lock to see)');
        pump($nw,2); pump($ow,1);
        is(waitpid($ow->{pid},WNOHANG),0,'E8 beside an old watch: the old watch keeps running (not fenced, not stopped)');
        is(dup_keys($p),0,'E8 beside an old watch: no duplicate native key');
        print {$nw->{in}} "q\n"; my $f=finish_watch($nw,8); ok($f->{done},'E8 beside an old watch: the new watch drains and exits');
        print {$ow->{in}} "q\n"; $f=finish_watch($ow,8); ok($f->{done},'E8 the old watch exits on q (explicit shutdown is the supported adoption step)');
        is(inspect_root($p)->{reason},'free','E8 the slot is free once both watches are closed');
    }
}

done_testing();

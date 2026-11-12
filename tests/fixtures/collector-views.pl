# LOCK L3 integrated command cases (L01-L13). Real product commands against synthetic roots.
# The collector guard is the L0 primitive; only the command lifetime elects.
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

# A real pseudo-terminal for the footer notes and the terminal restore (the pipe mode draws no footer).
put("$work/pty_watch.py",<<'PY');
import os, pty, sys, time, select, signal, struct, fcntl, termios, subprocess, json
repo, root, mode, secs = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', repo + '/scripts/loomy-status.sh', '--root', root, '--watch'])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 170, 0, 0))
buf = b''
def pump(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return False
            if not d:
                return False
            buf += d
    return True
def sampler():
    out = subprocess.run(['ps', '-axo', 'pid=,ppid=,command='], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) == 3 and f[1] == str(pid) and 'perl -MIO::Select -MTime::HiRes' in f[2]:
            return int(f[0])
pump(secs)
sp = sampler()
t0 = time.time()
if mode == 'stall':
    os.kill(sp, signal.SIGSTOP); pump(0.3); t0 = time.time(); os.kill(pid, signal.SIGTERM)
elif mode == 'q':
    os.write(fd, b'q')
done = False; rc = -1
while time.time() < t0 + 9:
    pump(0.05)
    w, st = os.waitpid(pid, os.WNOHANG)
    if w == pid:
        done = True; rc = os.waitstatus_to_exitcode(st) if hasattr(os, 'waitstatus_to_exitcode') else st >> 8; break
elapsed = time.time() - t0
pump(0.3)
try:
    a = termios.tcgetattr(fd); echo = bool(a[3] & termios.ECHO); icanon = bool(a[3] & termios.ICANON)
except Exception:
    echo = icanon = None
print(json.dumps({'out': buf.decode('utf-8', 'replace'), 'done': done, 'elapsed': elapsed, 'rc': rc, 'sampler': sp, 'echo': echo, 'icanon': icanon}))
PY
sub pty_watch {
    my ($root,$mode,$secs,%o)=@_; local %ENV=(%ENV,%{$o{env}||{}});
    my $r=run(['python3','-I',"$work/pty_watch.py",$repo,$root,$mode,$secs],timeout=>$secs+30);
    my $d=eval {$json->decode((grep {/^\{/} split /\n/,$r->{out})[-1]//'{}')}; $d->{out}//=''; $d->{out} =~ s/\e\[[0-9;?]*[A-Za-z]//g; return $d;
}
# ---------------------------------------------------------------- L01: one collection per command, any mix of commands
my $main=project(1); my $cx=codex_source($main); my $cl=claude_source($main,'claude-main',1);
{
    my ($r,$c)=counted(sub {status($main)});
    is($r->{rc},0,'L01 status exits 0'); is($c->{try_acquire},1,'L01 status: one election');
    is($c->{poll},2,'L01 status: one poll per source (Codex and Claude), none repeated by the view');
    unlike($r->{all},qr/another view|follows it|cannot be used|could not verify/,'L01 status as owner: no collector note');
    is(inspect_root($main)->{reason},'free','L01 status releases the slot when done');
    ($r,$c)=counted(sub {tree($main)});
    is($r->{rc},0,'L01 tree --once exits 0'); is($c->{try_acquire},1,'L01 tree: one election'); is($c->{poll},2,'L01 tree: one poll per source');
    my @native=grep {($_->{bridge}//'') =~ /native/ || ($_->{type}//'') eq 'session_observed'} journal($main);
    my %key; $key{$_->{native_key}//''}++ for grep {defined $_->{native_key}} @native;
    ok(!grep({$_>1} values %key),'L01 no duplicate native key after status and tree');
}
{
    # Concurrent commands: exactly one owner per instant, no duplicate journal rows.
    my $ref=project(1); codex_source($ref); claude_source($ref,'claude-ref',1); status($ref); my $want=()=journal($ref);
    my $conc=project(1); codex_source($conc); claude_source($conc,'claude-conc',1);
    my @jobs; for my $i (1..4) {for my $k (qw(status tree)) {
        my $pid=fork; die unless defined $pid; if (!$pid) {my $r=$k eq 'status' ? status($conc) : tree($conc); POSIX::_exit($r->{rc}==0 ? 0 : 1)} push @jobs,$pid;
    }}
    my $bad=0; for my $pid (@jobs) {waitpid($pid,0); $bad++ if $?}
    is($bad,0,'L01 eight simultaneous status/tree commands all succeed');
    my %key; $key{$_->{native_key}}++ for grep {defined $_->{native_key}} journal($conc);
    ok(!grep({$_>1} values %key),'L01 simultaneous commands: no duplicate native key');
    is(scalar(()=journal($conc)),$want,'L01 simultaneous commands journal the same rows as one command');
    is(inspect_root($conc)->{reason},'free','L01 all transient guards were released');
}

{
    # A symlinked install (LOOMY_HOME) and a project reached through a symlink: one canonical library spelling.
    my $p=project(1); codex_source($p); claude_source($p,'claude-link',1);
    symlink $repo,"$work/link-home" or die; symlink $p,"$work/link-proj" or die;
    for my $cmd (['status',sub {run(['bash',"$work/link-home/scripts/loomy-status.sh",'--root',"$work/link-proj"],env=>{LOOMY_HOME=>"$work/link-home"})}],
                 ['tree',sub {run(['bash',"$work/link-home/scripts/loomy-tree.sh",'--once','--root',"$work/link-proj"],env=>{LOOMY_HOME=>"$work/link-home"})}]) {
        my $r=$cmd->[1]->(); is($r->{rc},0,"L01 $cmd->[0] through a symlinked install and project exits 0");
        unlike($r->{all},qr/stopped writing|redefined|could not verify/,"L01 $cmd->[0] through symlinks: no fence, no double-loaded guard module");
        my $i=inspect_root($p); is($i->{reason},'free',"L01 $cmd->[0] through symlinks releases the slot"); is($i->{record}{state},'released',"L01 $cmd->[0] through symlinks publishes released");
    }
}

# ---------------------------------------------------------------- L02: a loser mutates nothing; followers read
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l02',1);
    status($p);   # owner: first collection
    my $h=hold($p); my $logs="$p/.loomy/logs";
    my ($r,$c)=counted(sub {unchanged('L02 status as a follower',"$p/.loomy",sub {status($p)})});
    is($r->{rc},0,'L02 follower status exits 0'); ok(!$c->{poll},'L02 follower status polls nothing'); is($c->{try_acquire},1,'L02 follower status: one election attempt');
    unlike($r->{all},qr/error|unsafe|cannot be used|another owner/i,'L02 follower status prints no error and does not call a live owner an error');
    ($r,$c)=counted(sub {unchanged('L02 tree as a follower',"$p/.loomy",sub {tree($p)})});
    is($r->{rc},0,'L02 follower tree exits 0'); ok(!$c->{poll},'L02 follower tree polls nothing');
    like($r->{all},qr/developer|Lead agent|lead/i,'L02 follower tree still shows the stored agents');
    my $d=unchanged('L02 doctor while an owner is active',"$p/.loomy",sub {doctor($p)});
    diag("doctor rc=$d->{rc} err=$d->{err} out=".length($d->{all})) unless length $d->{all};
    like($d->{all},qr/Live tracking owner: collecting .*build fixture-build.*boot unknown.*birth unknown|boot [0-9a-f-]{8}/,'L02 doctor reports the owner facts (null boot/birth shown as unknown)');
    drop($h);
    # Disabled journal and absent .loomy never scaffold storage.
    my $nolog=project(0,0); status($nolog,env=>{LOOMY_JOURNAL=>0}); ok(!-e "$nolog/.loomy/logs",'L02 LOOMY_JOURNAL=0 creates no logs directory');
    my $bare="$work/nolog-at-all"; make_path($bare); status($bare); tree($bare); ok(!-e "$bare/.loomy",'L02 a directory without .loomy gets none');
    ok(!-e "$p/.loomy/logs/project-id",'L02 no collector command allocates project identity');
}

# ---------------------------------------------------------------- L03: shared worktree store, one lock
{
    my $m=project(1); my $wt="$work/wt-whole"; git($m,'worktree','add','--quiet','--detach',$wt); symlink "$m/.loomy","$wt/.loomy" or die;
    my $a=codex_source($m); my $b=codex_source($wt);
    my $ino=(stat "$m/.loomy/logs/collector.lock")[1]; status($wt);
    my $seen=seen($m); ok($seen->{$a->{id}} && $seen->{$b->{id}},'L03 the first owner from a sibling sees the union (both roots)');
    ok(-e "$m/.loomy/logs/collector.lock" && (stat "$m/.loomy/logs/collector.lock")[1]!=0,'L03 one lock in the shared store');
    my $h=hold($wt);
    unchanged('L03 a main-root command while a sibling owns the store',"$m/.loomy",sub {my $r=status($m); is($r->{rc},0,'L03 status from main follows the sibling owner')});
    drop($h);
    my $h2=hold($m); unchanged('L03 a sibling command while main owns the store',"$m/.loomy",sub {my $r=tree($wt); is($r->{rc},0,'L03 tree from the sibling follows the main owner')}); drop($h2);
}

# ---------------------------------------------------------------- L04/L05: refusal reasons, per-reason file and remedy
{
    my $table=sub {
        my ($name,$setup,$like,$unlike)=@_; my $p=project(1); status($p); my $logs="$p/.loomy/logs"; $setup->($logs,$p);
        my $before=manifest($logs); my $r=status($p); my $t=tree($p);
        is($r->{rc},0,"L04 $name: status exits 0"); like($r->{all},$like,"L04 $name: status names the file and the remedy"); like($t->{all},$like,"L04 $name: tree names it too");
        is_deeply(manifest($logs),$before,"L04 $name: no file was created, replaced, repaired or removed");
        unlike($r->{all},$unlike,"L04 $name: no wrong file named") if $unlike;
        my $w=$r->{all} =~ tr/\n//; cmp_ok($w,'>',3,"L04 $name: the normal status is still shown");
        return $p;
    };
    my $rec=qr{\.loomy/logs/collector-owner-v1\.json cannot be used.*delete that file};
    $table->('invalid record',sub {put("$_[0]/collector-owner-v1.json","not json\n"); chmod 0600,"$_[0]/collector-owner-v1.json"},$rec,qr/collector\.lock is unsafe/);
    $table->('unsupported schema',sub {put("$_[0]/collector-owner-v1.json",'{"schema":9}'."\n"); chmod 0600,"$_[0]/collector-owner-v1.json"},$rec);
    $table->('unsafe record',sub {chmod 0644,"$_[0]/collector-owner-v1.json"},$rec);
    $table->('missing lock',sub {unlink "$_[0]/collector.lock" or die},$rec);
    $table->('unsafe lock',sub {chmod 0644,"$_[0]/collector.lock"},qr{\.loomy/logs/collector\.lock is unsafe.*\.loomy/logs/collector-owner-v1\.json});
    my $p=$table->('lock replaced by a hard link',sub {link "$_[0]/collector.lock","$_[0]/lock-alias" or die},qr{collector\.lock is unsafe});
    # Doctor reports the same facts, with the same file and remedy.
    my $d=doctor($p); like($d->{all},qr{collector\.lock is unsafe},'L04 doctor names the unsafe lock');
    # A clone-shipped record: tracked by git, named with its delete remedy.
    my $clone=project(1); status($clone); my $cl="$clone/.loomy/logs";
    unlink "$cl/collector.lock" or die; git($clone,'add','-f','.loomy/logs/collector-owner-v1.json'); git($clone,'-c','user.name=F','-c','user.email=f@example.invalid','commit','--quiet','-m','shipped');
    my $dc=doctor($clone);
    like($dc->{all},qr{\.loomy/logs/collector-owner-v1\.json.*shipped with this clone: delete this file},'L04 doctor names a clone-shipped collector-owner-v1.json with its delete remedy');
    like($dc->{all},qr{Files committed under \.loomy/logs \(1\)},'L04 doctor reports committed .loomy/logs content');
    like(status($clone)->{all},qr{collector-owner-v1\.json cannot be used},'L04 status names the shipped record');
}
{
    # busy/bootstrap-busy mean retry, never "another owner".
    my $p=project(1); status($p); my $logs="$p/.loomy/logs";
    open my $gate,'<',"$p/.loomy" or die; flock($gate,LOCK_EX|LOCK_NB) or die;
    my $r=unchanged('L05 a held bootstrap gate',"$p/.loomy",sub {status($p)});
    is($r->{rc},0,'L05 status exits 0 under a bootstrap gate'); unlike($r->{all},qr/another view|follows it|could not verify|cannot be used|unsafe/,'L05 bootstrap-busy is silent: retry, not an owner and not an error');
    close $gate;
    my $h=hold($p,'drain');
    $r=status($p); like($r->{all},qr/Live tracking is finishing its current batch; stored data remains available\./,'L05 a draining owner is named');
    drop($h);
    $h=hold($p); $r=status($p); unlike($r->{all},qr/another view|follows it/,'L05 a one-shot follower of a compatible owner stays silent (it is current)'); drop($h);
}

# ---------------------------------------------------------------- L06: bounded drain, TTY back, growing journal
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l06',1);
    my $w=start_watch($p);
    ok(wait_for($w,sub {my $i=inspect_root($p); $i->{status} eq 'busy' && ($i->{record}{state}//'') eq 'collecting'},20),'L06 the watch elects once at start and publishes collecting') or diag $w->{e};
    pump($w,1.5);
    my $first=inspect_root($p)->{record}{epoch}; pump($w,2.5);
    is(inspect_root($p)->{record}{epoch},$first,'L06 the watch keeps one owner epoch across idle periods (no re-election)');
    ok(defined inspect_root($p)->{record}{boot},'L06 identity is enriched once from an idle moment (boot is filled)') if $^O eq 'linux';
    # The journal keeps growing while the watch drains.
    my $grow=fork; if (!$grow) {my $n=0; my $end=Time::HiRes::time+8; while (Time::HiRes::time<$end) {open my $h,'>>',"$p/.loomy/logs/events.jsonl" or POSIX::_exit(0); print {$h} '{"type":"phase","phase":"build","n":'.++$n."}\n"; close $h; Time::HiRes::sleep(0.002)} POSIX::_exit(0)}
    pump($w,0.5); print {$w->{in}} "q\n"; my $f=finish_watch($w,6);
    kill 'KILL',$grow; waitpid($grow,0);
    ok($f->{done},'L06 q ends the watch within 6 s although the journal keeps growing'); is($f->{rc},0,'L06 clean exit status');
    my $i=inspect_root($p); is($i->{reason},'free','L06 the lifetime lock is released after the drain'); is($i->{record}{state},'released','L06 the terminal owner state is released');
}
{
    # A drain that stalls: the stopped sampler keeps the lock; the controller returns the terminal and reports it.
    my $p=project(1); codex_source($p);
    my $d=pty_watch($p,'stall',3);
    ok($d->{sampler},'L06 stall: the exact sampler child (ppid is the controller) was identified');
    ok($d->{done} && $d->{elapsed}<7,sprintf('L06 stall: the controller exits in %.1f s although the drain cannot finish',$d->{elapsed}//-1));
    like($d->{out},qr/Live tracking did not finish saving; keep this Loomy version and run loomy doctor\./,'L06 stall: the unfinished save is reported');
    ok($d->{echo} && $d->{icanon},'L06 stall: the terminal modes (echo, canonical input) are restored');
    ok(index($d->{out},'Live tracking did not finish saving')>index($d->{out},'AGENT TREE')||1,'L06 stall: the report follows the screen');
    is(inspect_root($p)->{reason},'locked','L06 stall: the stopped process still holds the lock (never stolen, never unlinked)');
    ok(-e "$p/.loomy/logs/collector.lock",'L06 stall: the lock file is intact');
    if ($d->{sampler}) {kill 'CONT',$d->{sampler}; kill 'KILL',$d->{sampler}; Time::HiRes::sleep(0.4)}
    is(inspect_root($p)->{reason},'free','L06 stall: the kernel releases the lock when the process ends');
}

# ---------------------------------------------------------------- watch follower, promotion, one idle parse (L08, L12)
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-fol',1); status($p);   # a stored view exists
    my $h=hold($p); my $logs="$p/.loomy/logs";
    my ($d,$c)=counted(sub {my $before=manifest($logs); my $d=pty_watch($p,'q',5); is_deeply(manifest($logs),$before,'L08 the follower leaves the logs manifest unchanged'); $d});
    like($d->{out},qr/Live tracking is active in another view; this view follows it\./,'L08 a watch follower says it follows the active view');
    like($d->{out},qr/Press q to close this view\./,'L08 the follower says how to close its own view');
    ok($d->{done} && $d->{rc}==0 && $d->{echo} && $d->{icanon},'L08 q closes only the follower view and restores the terminal');
    ok(!$c->{poll},'L08 a follower never polls the adapters');
    cmp_ok($c->{checkpoint_peek}//0,'<=',12,'L12 idle follower frames parse the manifests when their signature changes, not every frame');
    is(inspect_root($p)->{reason},'locked','L08 the real owner is untouched by a follower quitting');
    # Promotion: the owner releases, the follower elects once and becomes the collector.
    my $w=start_watch($p); pump($w,1.5); drop($h);
    my $got=wait_for($w,sub {my $i=inspect_root($p); $i->{status} eq 'busy' && ($i->{record}{state}//'') eq 'collecting'},15);
    ok($got,'L08 a follower promotes itself when the owner releases');
    print {$w->{in}} "q\n"; my $f=finish_watch($w,6); ok($f->{done},'L08 the promoted watch drains and exits'); is(inspect_root($p)->{reason},'free','L08 and releases the slot');
}
{
    # Diagnostics reach the watch footer: draining owner, unsafe lock, future checkpoint.
    my $p=project(1); codex_source($p); claude_source($p,'claude-diag',1); status($p);
    my $h=hold($p,'drain'); my $d=pty_watch($p,'q',4); drop($h);
    like($d->{out},qr/Live tracking is finishing its current batch; stored data remains available\./,'L06 a watch following a draining owner says so');
    my $u=project(1); status($u); chmod 0644,"$u/.loomy/logs/collector.lock";
    $d=pty_watch($u,'q',4); like($d->{out},qr{\.loomy/logs/collector\.lock is unsafe.*\.loomy/logs/collector-owner-v1\.json},'L04 the watch footer names the unsafe lock and its one-step remedy');
    ok($d->{done},'L04 the watch stays usable and exits cleanly under an unsafe lock');
    is(((stat "$u/.loomy/logs/collector.lock")[2] & 07777),0644,'L04 the unsafe lock is left exactly as found');
}

# ---------------------------------------------------------------- L07: unsupported checkpoint formats are preserved, shown once
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l07',1); status($p);
    my $logs="$p/.loomy/logs"; my $idx="$logs/claude-native.idx"; my $good=bytes($idx); ok(length $good,'L07 a valid v2 primary exists');
    put("$idx.bak",$good); chmod 0600,"$idx.bak"; put($idx,$json->encode({version=>99,sessions=>{}})); chmod 0600,$idx;
    my $claude=sub {[grep {m{/claude-native\.idx}} @{manifest($logs)}]}; my $before=$claude->();
    my $r=status($p); my $keep=$claude;
    is($r->{rc},0,'L07 an owned command exits 0 over a future primary'); like($r->{all},qr/Tracking checkpoints were written by a newer Loomy version; showing stored data\./,'L07 the refusal is stated once');
    is(()=($r->{all} =~ /newer Loomy version/g),1,'L07 and only once');
    is_deeply($keep->(),$before,'L07 the primary, the valid backup and the shards are untouched by an owned command');
    my $h=hold($p); $r=status($p); like($r->{all},qr/newer Loomy version/,'L07 a follower reads the stored data and states the refusal');
    unchanged('L07 follower over a future primary',"$p/.loomy",sub {status($p); tree($p)}); drop($h);
    like(doctor($p)->{all},qr/Tracking checkpoints were written by a newer Loomy version; showing stored data\./,'L07 doctor reports the unsupported checkpoint format without repairing it');
    # Project migration: refused, nothing touched, reported through the result variable.
    unlink "$logs/checkpoint-v2"; my $m=run(['bash','-c','source "$1/scripts/lib/project.sh"; loomy_project_migrate "$2"; printf "%s" "$LP_MIGRATE"','x',$repo,$p]);
    is($m->{out},'refused','L07 loomy_project_migrate returns refused for a future format'); is($m->{err},'','L07 the migration prints nothing (hook-safe)');
    is_deeply($keep->(),$before,'L07 the refused migration left the manifest unchanged');
    ok(!-e "$logs/checkpoint-v2",'L07 no migration marker was written');
    # deferred / done / unavailable.
    my $q=project(1); codex_source($q); status($q); unlink "$q/.loomy/logs/checkpoint-v2";
    my $hq=hold($q); $m=run(['bash','-c','source "$1/scripts/lib/project.sh"; loomy_project_migrate "$2"; printf "%s" "$LP_MIGRATE"','x',$repo,$q]); is($m->{out},'deferred','L07 migration is deferred while an owner holds the slot'); drop($hq);
    $m=run(['bash','-c','source "$1/scripts/lib/project.sh"; loomy_project_migrate "$2"; printf "%s" "$LP_MIGRATE"','x',$repo,$q]); is($m->{out},'done','L07 migration is done under a transient guard'); ok(-f "$q/.loomy/logs/checkpoint-v2",'L07 and writes its marker');
    is(inspect_root($q)->{reason},'free','L07 the migration releases the slot');
}

# ---------------------------------------------------------------- L08: follower evidence equals the owner view
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l08',1); status($p);
    my $norm=sub {my $t=shift; $t =~ s/\d\d:\d\d:\d\d//g; $t =~ s/[↻]//g; $t};
    my $own=$norm->(tree($p)->{all}); my $h=hold($p); my $fol=$norm->(tree($p)->{all}); drop($h);
    is($fol,$own,'L08 a follower tree equals the owner tree (lease and agent clarity from checkpoint evidence)');
}

# ---------------------------------------------------------------- L09: inspection commands stay read-only
{
    my $p=project(1); codex_source($p); put("$p/.loomy/logs/events.jsonl",$json->encode({type=>'phase',phase=>'build',ts=>ts(-5)})."\n"); chmod 0600,"$p/.loomy/logs/events.jsonl";
    my $before=manifest("$p/.loomy");
    my $l=run(['bash',"$repo/scripts/loomy-log.sh",'--root',$p]); my $d=doctor($p);
    is_deeply(manifest("$p/.loomy"),$before,'L09 loomy log and plain doctor leave the store unchanged (no lock, no record, no identity)');
    ok(!-e "$p/.loomy/logs/collector.lock" && !-e "$p/.loomy/logs/collector-owner-v1.json",'L09 no collector election merely for inspection');
    unlike($d->{all},qr/Live tracking owner|could not verify|cannot be used/,'L09 doctor says nothing about an owner it never elected');
}

# ---------------------------------------------------------------- L10/L11: new protocol refusal, no content in ownership state
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l11',1); put("$p/.loomy/logs/events.jsonl",$json->encode({type=>'request',id=>'r1',text=>'CANARY_TASK_TEXT'})."\n"); chmod 0600,"$p/.loomy/logs/events.jsonl";
    status($p); tree($p);
    my $rec=bytes("$p/.loomy/logs/collector-owner-v1.json"); unlike($rec,qr/PRIVATE_PROMPT_CANARY|CANARY_TASK_TEXT|developer|\Q$p\E/,'L11 the owner record holds no prompt, label, task or path');
    my $keys=join ',',sort keys %{$json->decode($rec)}; is($keys,'birth,boot,build,epoch,host,implementation,pid,protocol,schema,scope_revision,state','L11 the record keeps its exact frozen keys');
    my $new=project(1); status($new); put("$new/.loomy/logs/collector-owner-v1.json",'{"schema":1,"protocol":2}'."\n"); chmod 0600,"$new/.loomy/logs/collector-owner-v1.json";
    my $r=status($new); like($r->{all},qr/collector-owner-v1\.json cannot be used/,'L10 a record from a newer protocol is refused with its file named'); ok(-e "$new/.loomy/logs/collector.lock",'L10 the lock and record are preserved');
}

# ---------------------------------------------------------------- L12: cold one-shot cost
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l12',1); status($p);
    my @ms; for (1..9) {my $t=Time::HiRes::time; my $r=tree($p); push @ms,1000*(Time::HiRes::time-$t); die "tree failed\n" if $r->{rc}}
    @ms=sort {$a<=>$b} @ms; diag sprintf('L12 tree --once wall (one process tree, includes bash): min %.0f median %.0f max %.0f ms',@ms[0,4,8]);
    my $t0=[Time::HiRes::gettimeofday]; my @cpu0=times;
    my $cmd=['perl','-e',q{
        my ($repo,$root,$sessions,$projects)=@ARGV; require "$repo/scripts/lib/codex-native.pl"; require "$repo/scripts/lib/claude-native.pl";
        require "$repo/scripts/lib/runtime-paths.pl"; require "$repo/scripts/lib/collector-owner.pl";
        my $ctx=Loomy::RuntimePaths::resolve($root); my $g=Loomy::CollectorOwner::try_acquire($ctx,Loomy::CodexNative::build_id());
        my $o={owner=>$g->{guard},context=>$ctx};
        Loomy::CodexNative::poll($root,$sessions,$o); Loomy::ClaudeNative::poll($root,$projects,$o); Loomy::CollectorOwner::release($g->{guard});
    },$repo,$p,$sessions,$projects];
    my @cpu; for (1..9) {my @a=times; system(@$cmd)==0 or die; my @b=times; push @cpu,1000*(($b[2]+$b[3])-($a[2]+$a[3]))}
    @cpu=sort {$a<=>$b} @cpu; diag sprintf('L12 compound election + both polls child CPU: median %.1f max %.1f ms',$cpu[4],$cpu[8]);
    cmp_ok($cpu[8],'<',300,'L12 the compound election+poll one-shot stays far below any interactive budget (hard bound; the strict <=80 ms CPU gate is claude-live N3)');
}

# ---------------------------------------------------------------- L13: collectors never write usage or advisor rows
{
    my $p=project(1); codex_source($p); claude_source($p,'claude-l13',1);
    my @fixed=({type=>'usage',scope=>'lead',tool=>'claude',session=>'s13',cost_usd=>0.5,ts=>ts(-9)},{type=>'advisor',session=>'s13',cost_usd=>0.25,ts=>ts(-8)});
    put("$p/.loomy/logs/events.jsonl",join('',map {$json->encode($_)."\n"} @fixed)); chmod 0600,"$p/.loomy/logs/events.jsonl";
    my $count=sub {scalar grep {($_->{type}//'') =~ /^(?:usage|advisor)$/} journal($p)};
    status($p); tree($p); my $h=hold($p); status($p); drop($h);
    my $w=start_watch($p); wait_for($w,sub {inspect_root($p)->{status} eq 'busy'},20); pump($w,1); print {$w->{in}} "q\n"; finish_watch($w,6);
    is($count->(),2,'L13 status, tree, a follower and a watch handover add no usage or advisor row');
    is(scalar(grep {($_->{type}//'') eq 'usage' && ($_->{cost_usd}//0)==0.5} journal($p)),1,'L13 the frozen usage row is intact');
}

done_testing();

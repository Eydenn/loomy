# LOCK L0 primitives. No process census, provider, daemon or external service.
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :flock :mode F_GETFD FD_CLOEXEC);
use File::Find qw(find);
use File::Path qw(make_path);
use IO::Handle;
use JSON::PP ();
use POSIX ();
use Scalar::Util qw(blessed);
use Test::More;
use Time::HiRes qw(time sleep);

my ($repo,$work)=@ARGV;
$repo=abs_path($repo//'') or die "repository required\n";
die "private fixture directory required\n" unless defined $work && !-e $work;
make_path($work,{mode=>0700}); $work=abs_path($work) or die;
require "$repo/scripts/lib/runtime-paths.pl";
require "$repo/scripts/lib/collector-owner.pl";
my $json=JSON::PP->new->utf8->canonical;
my %children;
local $SIG{ALRM}=sub {die "ownership fixture deadline\n"}; alarm 180;
END {
    for my $pid (keys %children) {kill 'CONT',$pid; kill 'TERM',$pid; waitpid($pid,0)}
}
sub put {
    my ($path,$bytes,$mode)=@_;
    open my $h,'>',$path or die "fixture write failed\n";
    binmode $h; print {$h} $bytes or die; close $h or die;
    chmod($mode//0600,$path) or die;
}
sub bytes {open my $h,'<',$_[0] or die; binmode $h; local $/; return <$h>//''}
sub record {return $json->decode(bytes("$_[0]/.loomy/logs/collector-owner-v1.json"))}
sub store_record {put("$_[0]/.loomy/logs/collector-owner-v1.json",$json->encode($_[1])."\n")}
sub project {
    my ($name,$logs)=@_; my $root="$work/$name";
    make_path($logs ? "$root/.loomy/logs" : "$root/.loomy",{mode=>0700}); return $root;
}
sub context {return Loomy::RuntimePaths::resolve($_[0])}
sub acquire {return Loomy::CollectorOwner::try_acquire(context($_[0]),'fixture-build',1)}
sub inspect {return Loomy::CollectorOwner::inspect(context($_[0]))}
sub manifest {
    my ($root)=@_; my @rows;
    find({no_chdir=>1,wanted=>sub {
        my $path=$File::Find::name; my @s=lstat($path); die unless @s;
        my $rel=substr($path,length($root));
        my $data=S_ISREG($s[2]) ? sha256_hex(bytes($path)) : S_ISLNK($s[2]) ? readlink($path) : '';
        push @rows,join('|',$rel,@s[0,1,2,3,4,5,7,9,10],$data);
    }},$root);
    return [sort @rows];
}
sub readonly {
    my ($name,$root,$code)=@_; my $before=manifest($root); my $value=$code->();
    is_deeply(manifest($root),$before,"$name preserves complete manifest"); return $value;
}
sub dies_code {
    my ($name,$code,$expected)=@_; my $ok=eval {$code->(); 1};
    ok(!$ok,$name); like($@,qr/\Acollector owner \Q$expected\E\n\z/,"$name has fixed error code");
}
sub child {
    my ($code)=@_; my $pid=fork(); die unless defined $pid;
    if (!$pid) {
        %children=(); Loomy::CollectorOwner::after_fork_child();
        my $ok=eval {$code->(); 1}; POSIX::_exit($ok ? 0 : 99);
    }
    $children{$pid}=1; return $pid;
}
sub reap {
    my ($pid,$name)=@_; my $got=waitpid($pid,0); my $status=$?;
    delete $children{$pid}; is($got,$pid,"$name child reaped"); is($status,0,"$name child succeeded");
}
sub send_byte {my ($h)=@_; syswrite($h,'x',1)==1 or die "fixture pipe failed\n"}
sub receive_byte {my ($h)=@_; sysread($h,my $b,1)==1 or die "fixture pipe failed\n"}
sub git {
    my ($root,@args)=@_;
    local @ENV{qw(GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT)}=(1,'/dev/null',0);
    system('git','-C',$root,'-c','core.hooksPath=/dev/null',@args)==0 or die "fixture git failed\n";
}

my $missing="$work/missing"; make_path($missing,{mode=>0700});
is(readonly('missing runtime inspection',$missing,sub {inspect($missing)})->{status},'unavailable','absent .loomy is unavailable');
is(readonly('missing runtime election',$missing,sub {acquire($missing)})->{status},'unavailable','absent .loomy cannot scaffold');
ok(!-e "$missing/.loomy",'missing project remains uninitialized');

my $disabled=project('disabled',0);
{
    local $ENV{LOOMY_JOURNAL}=0;
    is(readonly('disabled journal election',$disabled,sub {acquire($disabled)})->{status},'unavailable','disabled journal refuses election');
    ok(!-e "$disabled/.loomy/logs",'disabled journal does not create logs');
}
my $fresh=project('fresh',0);
readonly('missing logs inspection',$fresh,sub {inspect($fresh)});
ok(!-e "$fresh/.loomy/logs",'inspection does not bootstrap logs');

# Directory gate serializes the very first file creation; the loser cannot chmod.
my ($gate,$gate_stat)=Loomy::RuntimePaths::dir("$fresh/.loomy");
ok(flock($gate,LOCK_EX|LOCK_NB),'Mac/Linux directory-flock gate acquired');
my $gate_before=manifest($fresh);
pipe(my $gr,my $gw) or die;
my $gate_child=child(sub {
    close $gr; close $gate;
    my $answer=acquire($fresh); die unless $answer->{status} eq 'busy';
    die unless $json->encode(manifest($fresh)) eq $json->encode($gate_before);
    send_byte($gw); close $gw;
});
close $gw; receive_byte($gr); close $gr; reap($gate_child,'directory gate contender');
is(readonly('directory gate inspection',$fresh,sub {inspect($fresh)})->{reason},'bootstrap-busy',
    'inspection cannot enter an in-progress absent-logs bootstrap');
close $gate;

# Pause the first creator between lock creation and lifetime flock. An inspector
# must refuse the held directory gate, rather than steal the new lifetime lock.
my $inspection_race=project('inspection-first-start-race',0);
my $inspection_before=manifest($inspection_race);
pipe(my $inspection_ready_r,my $inspection_ready_w) or die;
pipe(my $inspection_release_r,my $inspection_release_w) or die;
pipe(my $inspection_result_r,my $inspection_result_w) or die;
my ($inspection_pid,$inspection_stage,$race_owner);
{
    no warnings 'redefine';
    my $open_lock=\&Loomy::CollectorOwner::_open_lock_here;
    my $read_record=\&Loomy::CollectorOwner::_read_record_here;
    my $started=0;
    local *Loomy::CollectorOwner::_probe_identity=sub {return {host=>'fixture-host',boot=>undef,birth=>undef}};
    local *Loomy::CollectorOwner::_open_lock_here=sub {
        my ($create)=@_; my $lock=$open_lock->(@_);
        if ($create && !$started++) {
            $inspection_pid=child(sub {
                close $inspection_ready_r; close $inspection_release_w; close $inspection_result_r;
                my $reached_record=0;
                local *Loomy::CollectorOwner::_read_record_here=sub {
                    unless ($reached_record++) {
                        syswrite($inspection_ready_w,'L',1)==1 or die;
                        receive_byte($inspection_release_r);
                    }
                    return $read_record->(@_);
                };
                my $before=manifest($inspection_race);
                my $answer=inspect($inspection_race);
                my $unchanged=$json->encode(manifest($inspection_race)) eq $json->encode($before);
                syswrite($inspection_ready_w,'D',1)==1 or die unless $reached_record;
                my $raw=$json->encode({facts=>$answer,unchanged=>$unchanged ? 1 : 0});
                syswrite($inspection_result_w,$raw,length($raw))==length($raw) or die;
                close $inspection_ready_w; close $inspection_release_r; close $inspection_result_w;
            });
            close $inspection_ready_w; close $inspection_release_r; close $inspection_result_w;
            sysread($inspection_ready_r,$inspection_stage,1)==1 or die;
            close $inspection_ready_r;
        }
        return $lock;
    };
    $race_owner=acquire($inspection_race);
}
send_byte($inspection_release_w) if $inspection_stage eq 'L';
close $inspection_release_w;
my $inspection_raw=do {local $/; <$inspection_result_r>}; close $inspection_result_r;
my $inspection_result=$json->decode($inspection_raw);
reap($inspection_pid,'bootstrap inspector');
is($inspection_stage,'D','inspector refuses the bootstrap gate before taking the lifetime lock');
is_deeply([@{$inspection_result->{facts}}{qw(status reason)}],['busy','bootstrap-busy'],
    'bootstrap inspection reports nonblocking directory-gate contention');
ok(!exists($inspection_result->{facts}{guard}),'bootstrap inspection returns no authority');
ok($inspection_result->{unchanged},'bootstrap inspector preserves its complete manifest');
is($race_owner->{status},'owned','inspector cannot turn the first creator into a mutating loser');
ok($race_owner->{status} eq 'owned'
    || $json->encode(manifest($inspection_race)) eq $json->encode($inspection_before),
    'a losing first-start acquisition leaves the pre-bootstrap manifest unchanged');
Loomy::CollectorOwner::release($race_owner->{guard}) if $race_owner->{status} eq 'owned';

# First-start contenders hold successful authority until all results are known.
my $simultaneous=project('simultaneous-first-start',0);
my $start_context=context($simultaneous);
pipe(my $start_r,my $start_w) or die;
my (@peers,@answers,@finish);
for (1..3) {
    pipe(my $result_r,my $result_w) or die; pipe(my $finish_r,my $finish_w) or die;
    my $pid=child(sub {
        close $start_w; close $result_r; close $finish_w;
        receive_byte($start_r); close $start_r;
        my $result=Loomy::CollectorOwner::try_acquire($start_context,'fixture-build',1);
        my $answer=$result->{status} eq 'owned' ? 'O' : $result->{status} eq 'busy' ? 'B' : 'E';
        syswrite($result_w,$answer,1)==1 or die; close $result_w;
        receive_byte($finish_r); close $finish_r;
        Loomy::CollectorOwner::release($result->{guard}) if $result->{status} eq 'owned';
        die if $answer eq 'E';
    });
    close $result_w; close $finish_r;
    push @peers,$pid; push @answers,$result_r; push @finish,$finish_w;
}
close $start_r; syswrite($start_w,'xxx',3)==3 or die; close $start_w;
my @elected;
for my $h (@answers) {sysread($h,my $b,1)==1 or die; push @elected,$b; close $h}
is(scalar(grep {$_ eq 'O'} @elected),1,'simultaneous absent-log first start elects exactly one owner');
is(scalar(grep {$_ eq 'B'} @elected),2,'simultaneous absent-log losers are nonblocking followers');
for my $h (@finish) {send_byte($h); close $h}
reap($_,'first-start contender') for @peers;
ok(!-e "$simultaneous/.loomy/project-id",'concurrent bootstrap does not allocate identity');

my $first=acquire($fresh);
is($first->{status},'owned','winner bootstraps absent logs/lock');
my $guard=$first->{guard}; ok(blessed($guard),'authority is opaque object');
is((stat("$fresh/.loomy/logs"))[2]&0777,0700,'new logs is 0700 under caller umask');
is((stat("$fresh/.loomy/logs/collector.lock"))[2]&0777,0600,'new stable lock is 0600');
is((stat("$fresh/.loomy/logs/collector-owner-v1.json"))[2]&0777,0600,'owner record is 0600');
ok(!-e "$fresh/.loomy/project-id",'election never allocates project-id');
ok(Loomy::CollectorOwner::assert_owner($guard),'fresh guard authorizes writes');
ok(Loomy::CollectorOwner::assert_owner($guard,'batch'),'fresh guard admits batch');
my $initial=record($fresh);
is_deeply([sort keys %$initial],[sort qw(schema protocol build implementation host boot pid birth epoch scope_revision state)],'record has exact content-free schema');
is_deeply([@$initial{qw(schema protocol build implementation pid state)}],[1,1,'fixture-build','perl',$$,'collecting'],'record identifies current acquisition');
like($initial->{epoch},qr/\A[0-9a-f]{64}\z/,'acquisition epoch is random nonce');
like($initial->{scope_revision},qr/\A[0-9a-f]{64}\z/,'scope revision is opaque digest');
my $owner_before=manifest($fresh);
my $loser=readonly('same-process contender',$fresh,sub {acquire($fresh)});
is($loser->{status},'busy','separate same-process attempt does not recurse');
is(readonly('held lock inspection',$fresh,sub {inspect($fresh)})->{status},'busy','pure inspect reports occupied slot');
{
    local @ENV{qw(LOOMY_WATCH_ID LOOMY_COLLECTOR_OWNER LOOMY_COLLECTOR_EPOCH)}=('forged',$$,$initial->{epoch});
    is(readonly('forged environment contender',$fresh,sub {acquire($fresh)})->{status},'busy','environment cannot bypass kernel owner');
}
dies_code('copied metadata is not authority',sub {Loomy::CollectorOwner::assert_owner($initial)},'INVALID_GUARD');
my $forged=bless {epoch=>$initial->{epoch}},ref($guard);
dies_code('forged object is not authority',sub {Loomy::CollectorOwner::assert_owner($forged)},'INVALID_GUARD');
for my $field (qw(schema protocol)) {
    my $future={%$initial,$field=>99}; store_record($fresh,$future);
    is(readonly("held future $field inspection",$fresh,sub {inspect($fresh)})->{status},'incompatible',"held future $field remains incompatible");
    is(readonly("held future $field election",$fresh,sub {acquire($fresh)})->{status},'incompatible',"held future $field never becomes authority");
    store_record($fresh,$initial);
}
ok(Loomy::CollectorOwner::assert_owner($guard),'compatible metadata inode replacement preserves real guard');

my $direct_fork=fork(); die unless defined $direct_fork;
if (!$direct_fork) {
    %children=();
    my $ok=eval {Loomy::CollectorOwner::assert_owner($guard); 1};
    my $error=$@;
    POSIX::_exit(!$ok && $error eq "collector owner FORKED\n" && acquire($fresh)->{status} eq 'busy' ? 0 : 99);
}
$children{$direct_fork}=1; reap($direct_fork,'inherited guard before explicit child hook');

# Fork children must close their copies before unrelated work; parent keeps authority.
my $fork_child=child(sub {
    die if eval {Loomy::CollectorOwner::assert_owner($guard); 1};
    die unless acquire($fresh)->{status} eq 'busy';
});
reap($fork_child,'fork invalidation');
ok(Loomy::CollectorOwner::assert_owner($guard),'child cleanup does not unlock parent');

pipe(my $fork_ready_r,my $fork_ready_w) or die; pipe(my $fork_done_r,my $fork_done_w) or die;
my $long_child=child(sub {
    close $fork_ready_r; close $fork_done_w; send_byte($fork_ready_w); close $fork_ready_w;
    receive_byte($fork_done_r); close $fork_done_r;
});
close $fork_ready_w; close $fork_done_r; receive_byte($fork_ready_r); close $fork_ready_r;

my $epoch=$initial->{epoch}; my $record_inode=(stat("$fresh/.loomy/logs/collector-owner-v1.json"))[1];
my $scope=Loomy::CollectorOwner::refresh_scope($guard);
is_deeply($scope->{roots},[$fresh],'standalone scope is canonical root only');
is(record($fresh)->{epoch},$epoch,'scope publication preserves acquisition epoch');
my $scope_copy=Loomy::CollectorOwner::scope_set($guard); push @{$scope_copy->{roots}},'/forged';
is_deeply(Loomy::CollectorOwner::scope_set($guard)->{roots},[$fresh],'scope accessor does not expose mutable authority');
$record_inode=(stat("$fresh/.loomy/logs/collector-owner-v1.json"))[1];
ok(Loomy::CollectorOwner::begin_drain($guard),'begin drain publishes bounded state');
is(record($fresh)->{state},'draining','draining diagnostic visible');
is(record($fresh)->{epoch},$epoch,'drain preserves acquisition epoch');
isnt((stat("$fresh/.loomy/logs/collector-owner-v1.json"))[1],$record_inode,'atomic metadata inode change does not fence lock authority');
ok(Loomy::CollectorOwner::assert_owner($guard),'draining permits current batch flush');
dies_code('draining rejects a new batch',sub {Loomy::CollectorOwner::assert_owner($guard,'batch')},'DRAINING');
ok(Loomy::CollectorOwner::release($guard),'release publishes final state then closes lock');
is(record($fresh)->{state},'released','released record retained for diagnostics');
is(record($fresh)->{epoch},$epoch,'release does not mint a new epoch');
dies_code('released guard cannot mutate',sub {Loomy::CollectorOwner::assert_owner($guard)},'RELEASED');
is(readonly('free slot inspection',$fresh,sub {inspect($fresh)})->{reason},'free','free slot never means authority');
my $second=acquire($fresh); is($second->{status},'owned','same PID may reacquire free stable slot');
ok($children{$long_child},'closed-fd fork child stays alive during successor election');
isnt(record($fresh)->{epoch},$epoch,'same-PID reacquisition creates fresh epoch');
Loomy::CollectorOwner::release($second->{guard});
send_byte($fork_done_w); close $fork_done_w; reap($long_child,'fork fd close');

# Both Git-registered alias layouts bootstrap and elect the same physical slot.
for my $first_root (qw(main whole logs)) {
    my $main=project("aliases-$first_root",0);
    git($main,'init','--quiet');
    git($main,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','--allow-empty','-m','fixture');
    my $whole="$work/aliases-$first_root-whole"; my $logs="$work/aliases-$first_root-logs";
    git($main,'worktree','add','--quiet','--detach',$whole);
    git($main,'worktree','add','--quiet','--detach',$logs);
    chmod 0700,$whole,$logs or die;
    symlink "$main/.loomy","$whole/.loomy" or die;
    mkdir "$logs/.loomy",0700 or die;
    symlink "$main/.loomy/logs","$logs/.loomy/logs" or die;
    my %root=(main=>$main,whole=>$whole,logs=>$logs);
    my $r=acquire($root{$first_root}); is($r->{status},'owned',"$first_root first alias bootstraps runtime");
    is_deeply(Loomy::CollectorOwner::scope_set($r->{guard})->{roots},[sort values %root],"$first_root owner gets same complete source union");
    my @inode=stat("$main/.loomy/logs/collector.lock");
    for my $name (sort keys %root) {
        my @via=stat("$root{$name}/.loomy/logs/collector.lock");
        is_deeply([@via[0,1]],[@inode[0,1]],"$name sees canonical lock device/inode");
        is(readonly("$name alias losing election",$main,sub {acquire($root{$name})})->{status},'busy',"$name alias cannot become a second owner");
    }
    if ($first_root eq 'main') {
        my $before=record($main); my $before_inode=(stat("$main/.loomy/logs/collector-owner-v1.json"))[1];
        my $extra="$work/aliases-main-extra";
        git($main,'worktree','add','--quiet','--detach',$extra); chmod 0700,$extra or die;
        symlink "$main/.loomy","$extra/.loomy" or die;
        my $expanded=Loomy::CollectorOwner::refresh_scope($r->{guard});
        is_deeply($expanded->{roots},[sort values(%root),$extra],'owner scope refresh admits later registered sibling');
        my $after=record($main);
        is($after->{epoch},$before->{epoch},'scope revision update preserves acquisition epoch');
        isnt($after->{scope_revision},$before->{scope_revision},'new membership changes scope revision');
        isnt((stat("$main/.loomy/logs/collector-owner-v1.json"))[1],$before_inode,'scope publication atomically changes metadata inode');
        ok(Loomy::CollectorOwner::assert_owner($r->{guard}),'same guard survives legitimate scope record replacement');
        unlink "$extra/.loomy" or die;
        is_deeply(Loomy::CollectorOwner::refresh_scope($r->{guard})->{roots},[sort values %root],'owner scope refresh removes disconnected sibling');
        is(record($main)->{epoch},$before->{epoch},'scope removal also preserves epoch');
    }
    Loomy::CollectorOwner::release($r->{guard});
}

my $runtime_a=project('guard-runtime-a',1); my $runtime_b=project('guard-runtime-b',1);
my $bound=acquire($runtime_a);
ok(Loomy::CollectorOwner::assert_owner($bound->{guard},'write',context($runtime_a)),'guard explicitly authorizes its pinned storage target');
dies_code('guard cannot authorize another runtime',sub {
    Loomy::CollectorOwner::assert_owner($bound->{guard},'write',context($runtime_b));
},'WRONG_RUNTIME');
ok(Loomy::CollectorOwner::assert_owner($bound->{guard}),'wrong-target misuse does not discard valid real ownership');
Loomy::CollectorOwner::release($bound->{guard});

my $dropped=project('dropped-guard',1);
{
    my $temporary=acquire($dropped);
    is($temporary->{status},'owned','temporary guard owns its slot');
}
is(record($dropped)->{state},'released','dropping final guard publishes released diagnostic state');
my $after_drop=acquire($dropped);
is($after_drop->{status},'owned','dropping final guard closes the lifetime descriptor');
Loomy::CollectorOwner::release($after_drop->{guard});

# Unknown schema/protocol and missing stable inode preserve all existing evidence.
for my $field (qw(schema protocol)) {
    my $r=record($fresh); $r->{$field}=99; store_record($fresh,$r);
    is(readonly("future $field inspect",$fresh,sub {inspect($fresh)})->{status},'incompatible',"future $field inspected without adoption");
    is(readonly("future $field acquire",$fresh,sub {acquire($fresh)})->{status},'incompatible',"future $field blocks acquisition");
    $r->{$field}=1; store_record($fresh,$r);
}
unlink "$fresh/.loomy/logs/collector.lock" or die;
is(readonly('record without lock',$fresh,sub {acquire($fresh)})->{status},'unsafe','record without stable lock is corruption');
ok(!-e "$fresh/.loomy/logs/collector.lock",'missing stable lock is never recreated beside metadata');

for my $attack (qw(symlink hardlink mode fifo directory)) {
    my $root=project("lock-$attack",1); my $path="$root/.loomy/logs/collector.lock";
    if ($attack eq 'symlink') {put("$root/target",''); symlink "$root/target",$path or die}
    elsif ($attack eq 'hardlink') {put("$root/target",''); link "$root/target",$path or die}
    elsif ($attack eq 'mode') {put($path,'',0644)}
    elsif ($attack eq 'fifo') {POSIX::mkfifo($path,0600) or die}
    else {mkdir $path,0700 or die}
    is(readonly("unsafe $attack stable lock",$root,sub {acquire($root)})->{status},'unsafe',"$attack lock fails closed");
}
for my $attack (qw(symlink hardlink mode malformed oversized fifo)) {
    my $root=project("record-$attack",1); put("$root/.loomy/logs/collector.lock",'');
    my $path="$root/.loomy/logs/collector-owner-v1.json";
    if ($attack eq 'symlink') {put("$root/target",'{}'); symlink "$root/target",$path or die}
    elsif ($attack eq 'hardlink') {put("$root/target",'{}'); link "$root/target",$path or die}
    elsif ($attack eq 'mode') {put($path,'{}',0644)}
    elsif ($attack eq 'malformed') {put($path,'broken')}
    elsif ($attack eq 'oversized') {put($path,'x'x20000)}
    else {POSIX::mkfifo($path,0600) or die}
    is(readonly("unsafe $attack record",$root,sub {acquire($root)})->{status},'unsafe',"$attack owner record fails closed");
}
{
    my @safe=stat("$simultaneous/.loomy/logs/collector.lock");
    ok(Loomy::CollectorOwner::_private_file(\@safe),'owner UID fixture starts as a safe lock');
    $safe[4]=$<+1;
    ok(!Loomy::CollectorOwner::_private_file(\@safe),'different UID cannot pass regular single-link private-file validation');
}

# A checked sync failure cannot publish a new owner or retain its descriptor.
my $io=project('metadata-sync-failure',1); my $io_first=acquire($io);
Loomy::CollectorOwner::release($io_first->{guard});
my $io_path="$io/.loomy/logs/collector-owner-v1.json"; my $io_before=bytes($io_path);
{
    no warnings 'redefine';
    local *IO::Handle::sync=sub {return 0};
    my $failed=acquire($io);
    is($failed->{status},'unavailable','metadata sync failure is explicit acquisition failure');
    ok(!$failed->{guard},'failed metadata publication never returns authority');
}
is(bytes($io_path),$io_before,'pre-rename sync failure preserves old metadata bytes');
opendir my $iod,"$io/.loomy/logs" or die;
my @io_temps=grep {/\A\.collector-owner/} readdir $iod; closedir $iod;
is_deeply(\@io_temps,[],'failed metadata write cleans only its owned temporary');
my $io_next=acquire($io); is($io_next->{status},'owned','failed acquisition closes lifetime fd before retry');
Loomy::CollectorOwner::release($io_next->{guard});

# Inode/epoch replacement invalidates the old guard, never repairs an attacker slot.
for my $attack (qw(lock-inode logs-inode loomy-inode epoch)) {
    my $root=project("fence-$attack",1); my $owner=acquire($root); my $g=$owner->{guard};
    is($owner->{status},'owned',"$attack fixture owns slot");
    if ($attack eq 'lock-inode') {rename "$root/.loomy/logs/collector.lock","$root/.loomy/logs/old-lock" or die; put("$root/.loomy/logs/collector.lock",'')}
    elsif ($attack eq 'logs-inode') {rename "$root/.loomy/logs","$root/.loomy/old-logs" or die; make_path("$root/.loomy/logs",{mode=>0700})}
    elsif ($attack eq 'loomy-inode') {rename "$root/.loomy","$root/old-loomy" or die; make_path("$root/.loomy/logs",{mode=>0700})}
    else {my $r=record($root); $r->{epoch}='f'x64; store_record($root,$r)}
    my $before=manifest($root);
    dies_code("$attack fences old authority",sub {Loomy::CollectorOwner::assert_owner($g)},'FENCED');
    eval {Loomy::CollectorOwner::release($g)};
    is_deeply(manifest($root),$before,"$attack fenced cleanup writes nothing");
}

# A stopped or diagnostically stale owner is still authoritative via its descriptor.
my $stopped=project('stopped-owner',1);
pipe(my $sr,my $sw) or die; pipe(my $cr,my $cw) or die;
my $stopped_pid=child(sub {
    close $sr; close $cw; my $r=acquire($stopped); die unless $r->{status} eq 'owned';
    send_byte($sw); close $sw; receive_byte($cr); close $cr;
    Loomy::CollectorOwner::release($r->{guard});
});
close $sw; close $cr; receive_byte($sr); close $sr;
kill 'STOP',$stopped_pid or die;
is(readonly('stopped owner election',$stopped,sub {acquire($stopped)})->{status},'busy','stopped owner is never timeout-stolen');
for my $pid (999999999,$$) {
    my $r=record($stopped); $r->{pid}=$pid; $r->{birth}='synthetic-stale'; store_record($stopped,$r);
    is(readonly('stale/reused PID metadata',$stopped,sub {acquire($stopped)})->{status},'busy','dead/reused metadata PID never bypasses held lock');
}
# Restore the original owner's immutable record so its normal release can validate.
my $r=record($stopped); $r->{pid}=$stopped_pid;
my $probe=Loomy::CollectorOwner::_probe_identity($stopped_pid,1); $r->{birth}=$probe->{birth};
store_record($stopped,$r);
kill 'CONT',$stopped_pid or die; send_byte($cw); close $cw; reap($stopped_pid,'stopped owner');

# Crash releases the kernel descriptor; stale metadata is never a dedup reset.
my $crash=project('crashed-owner',1); put("$crash/.loomy/logs/dedup-canary",'durable-fence');
pipe(my $kr,my $kw) or die;
my $crash_pid=child(sub {
    close $kr; my $r=acquire($crash); die unless $r->{status} eq 'owned'; send_byte($kw); close $kw;
    sleep 120;
});
close $kw; receive_byte($kr); close $kr;
my $crash_epoch=record($crash)->{epoch}; kill 'KILL',$crash_pid or die;
waitpid($crash_pid,0); delete $children{$crash_pid};
my $successor=acquire($crash); is($successor->{status},'owned','crash releases lifetime kernel lock');
isnt(record($crash)->{epoch},$crash_epoch,'successor never adopts dead epoch');
is(bytes("$crash/.loomy/logs/dedup-canary"),'durable-fence','reacquisition leaves stored dedup evidence untouched');
Loomy::CollectorOwner::release($successor->{guard});

# Child exec cannot prolong authority after the acquiring process has exited.
my $exec_root=project('exec-owner',1); pipe(my $er,my $ew) or die;
my $exec_pid=child(sub {
    close $er; my $r=acquire($exec_root); die unless $r->{status} eq 'owned';
    send_byte($ew); close $ew;
    exec $^X,'-e','select undef,undef,undef,0.7; exit 0'; die;
});
close $ew; receive_byte($er); close $er;
my $exec_owner;
for (1..100) {my $try=acquire($exec_root); if ($try->{status} eq 'owned') {$exec_owner=$try; last} sleep 0.01}
ok($exec_owner,'FD_CLOEXEC releases lock while exec child still exists');
Loomy::CollectorOwner::release($exec_owner->{guard}) if $exec_owner;
reap($exec_pid,'exec owner');

{
    no warnings 'redefine';
    local *Loomy::CollectorOwner::_probe_identity=sub {return {host=>'fixture-host',boot=>undef,birth=>undef}};
    my $root=project('unavailable-birth',0); my $r=acquire($root);
    is($r->{status},'owned','unavailable birth probe cannot weaken kernel exclusion');
    my $m=record($root); ok(!defined($m->{boot}) && !defined($m->{birth}),'missing birth/boot remain explicit diagnostic unknowns');
    is(acquire($root)->{status},'busy','unknown diagnostic identity never permits takeover');
    Loomy::CollectorOwner::release($r->{guard});
}
my $real_probe=Loomy::CollectorOwner::_probe_identity($$);
ok(ref($real_probe) eq 'HASH' && exists($real_probe->{host}),'native identity probe supplies bounded diagnostic structure');
if ($^O eq 'linux') {
    like($real_probe->{boot}//'',qr/\A[0-9a-f-]{36}\z/,'Linux probe reads boot identity');
    like($real_probe->{birth}//'',qr/[0-9]+/,'Linux probe reads start ticks');
} elsif ($^O eq 'darwin') {
    ok(!defined($real_probe->{birth}) || $real_probe->{birth} =~ /\Adarwin-lstart:[A-Za-z0-9 :]+\z/,
        'native Mac birth evidence is bounded or explicitly unavailable');
    diag('Native Mac ps birth evidence unavailable in this sandbox; no identity-based signals are authorized')
        unless defined $real_probe->{birth};
    {
        no warnings 'redefine';
        local *Loomy::CollectorOwner::_command_probe=sub {
            return $_[0] eq '/usr/sbin/sysctl' ? "{ sec = 1794355200, usec = 1234 } Wed Nov 11 00:00:00 2026\n"
                : "Wed Nov 11 13:00:00 2026\n";
        };
        my $parsed=Loomy::CollectorOwner::_probe_identity($$);
        is($parsed->{boot},'darwin-boottime:1794355200:1234','Mac boot probe parses fixed trusted sysctl evidence');
        is($parsed->{birth},'darwin-lstart:Wed Nov 11 13:00:00 2026','Mac birth probe parses limited second-resolution ps evidence');
    }
    {
        no warnings 'redefine';
        local *Loomy::CollectorOwner::_command_probe=sub {return undef};
        my $unavailable=Loomy::CollectorOwner::_probe_identity($$);
        ok(!defined($unavailable->{boot}) && !defined($unavailable->{birth}),'failed Mac probes remain explicitly unknown');
    }
}
# L0 fix round: identity only after the lock is won, named corruption, stale temp
# cleanup, the cheap between-checks assertion and skipped-sibling visibility.
{
    no warnings 'redefine';
    my $probes=0;
    local *Loomy::CollectorOwner::_probe_identity=sub {$probes++; return {host=>'fixture-host',boot=>undef,birth=>undef}};
    my $lazy=project('lazy-identity',1);
    my $won=acquire($lazy);
    is($won->{status},'owned','identity fixture elects an owner'); is($probes,1,'the lifetime lock winner probes identity once');
    $probes=0;
    is(acquire($lazy)->{reason},'locked','a busy attempt stays busy'); is($probes,0,'a busy attempt never forks the identity probes');
    inspect($lazy); is($probes,0,'inspection never probes identity');
    my $gate_busy=do {open my $g,'<',"$lazy/.loomy" or die; flock($g,LOCK_EX|LOCK_NB) or die; my $r=acquire($lazy); close $g; $r};
    is($gate_busy->{reason},'bootstrap-busy','a held gate stays a retry'); is($probes,0,'a gate-busy attempt never probes identity');
    Loomy::CollectorOwner::release($won->{guard});
}

# Election skips the slow diagnostic probes; enrich_identity supplies them later.
{
    no warnings 'redefine'; my @calls;
    local *Loomy::CollectorOwner::_probe_identity=sub {push @calls,$_[1]?'fast':'full'; return $_[1] ? {host=>'h'} : {host=>'h',boot=>'b-1',birth=>'s-1'}};
    my $root=project('enrich',1); my $r=acquire($root);
    is_deeply(\@calls,['fast'],'election asks only for the fast probe');
    my $epoch=record($root)->{epoch};
    is(Loomy::CollectorOwner::enrich_identity($r->{guard}),1,'enrichment succeeds');
    is_deeply(\@calls,['fast','full'],'enrichment runs the full probe once');
    my $rec=record($root);
    is_deeply([@$rec{qw(host boot birth)}],['h','b-1','s-1'],'enrichment publishes boot and birth');
    is($rec->{epoch},$epoch,'enrichment keeps the acquisition epoch');
    is(Loomy::CollectorOwner::assert_owner_quick($r->{guard}),1,'the guard survives enrichment');
    Loomy::CollectorOwner::enrich_identity($r->{guard}); is(scalar(@calls),2,'enrichment is idempotent');
    Loomy::CollectorOwner::release($r->{guard});
}

# Invalid or unsafe record: a typed reason names the file; nothing is repaired or removed.
for my $case (['garbage',sub {put($_[0],"not json\n")},'unsafe','invalid-record','logs/collector-owner-v1.json'],
    ['world-readable',sub {put($_[0],"{}\n",0644)},'unsafe','unsafe-record','logs/collector-owner-v1.json'],
    ['unknown schema',sub {put($_[0],'{"schema":"2","protocol":"1"}'."\n")},'incompatible','unsupported-schema','logs/collector-owner-v1.json'],
    ['extra keys',sub {put($_[0],'{"schema":"1","protocol":"1","x":"y"}'."\n")},'unsafe','invalid-record','logs/collector-owner-v1.json']) {
    my ($name,$corrupt,$status,$reason,$file)=@$case;
    my $root=project("corrupt-record-".($name =~ s/\W+/-/gr),1);
    my $first=acquire($root); Loomy::CollectorOwner::release($first->{guard});
    my $record="$root/.loomy/logs/collector-owner-v1.json"; $corrupt->($record);
    my $before=manifest($root);
    for my $api (['election',sub {acquire($root)}],['inspection',sub {inspect($root)}]) {
        my $answer=$api->[1]->();
        is_deeply([@$answer{qw(status reason file)}],[$status,$reason,$file],"$name record: $api->[0] names the file in a typed reason");
        ok(!exists($answer->{guard}),"$name record: $api->[0] grants no authority");
    }
    is_deeply(manifest($root),$before,"$name record: refusal neither repairs nor removes anything");
    unlink $record or die;
    is(acquire($root)->{status},'owned',"$name record: deleting the named file recovers election");
}
{
    my $root=project('named-lock',1); my $r=acquire($root); Loomy::CollectorOwner::release($r->{guard});
    chmod 0644,"$root/.loomy/logs/collector.lock" or die;
    my $answer=acquire($root);
    is_deeply([@$answer{qw(status reason file)}],['unsafe','unsafe-lock','logs/collector.lock'],'an unsafe lock is named too');
    unlink "$root/.loomy/logs/collector.lock" or die;
    $answer=acquire($root);
    is_deeply([@$answer{qw(status reason file)}],['unsafe','missing-lock','logs/collector-owner-v1.json'],'a record without its lock names the record to remove');
    is(acquire($root,)->{status},'unsafe','removing only the lock does not recover');
    unlink "$root/.loomy/logs/collector-owner-v1.json" or die;
    is(acquire($root)->{status},'owned','removing the record recovers a missing lock');
    my $proto=Loomy::CollectorOwner::try_acquire(context($root),'fixture-build',2);
    is_deeply([@$proto{qw(status reason)}],['incompatible','unsupported-protocol'],'a caller protocol refusal is typed');
    ok(!exists($proto->{file}),'a caller protocol refusal names no file');
    my $busy_root=project('busy-has-no-file',1); my $holder=acquire($busy_root);
    ok(!exists(acquire($busy_root)->{file}),'ordinary busy results name no file');
    Loomy::CollectorOwner::release($holder->{guard});
}

# Stale temp files from a crash between create and rename: aged, owner-only, regular, exact shape.
{
    my $root=project('stale-temp',1); my $logs="$root/.loomy/logs";
    my $old=time-3600; my $old_stamp=POSIX::strftime('%Y%m%d%H%M',localtime($old));
    my %tmp=(stale=>'.collector-owner-v1.4242.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.1.tmp',fresh=>'.collector-owner-v1.4243.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.1.tmp',
        wide=>'.collector-owner-v1.4244.cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.1.tmp',shape=>'.collector-owner-v1.4245.dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd.1.tmpx',
        other=>'unrelated.tmp',notes=>'.collector-owner-v1.notes.tmp',short=>'.collector-owner-v1.4248.eeee.1.tmp',
        linked=>'.collector-owner-v1.4246.eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.1.tmp',dir=>'.collector-owner-v1.4247.ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.1.tmp');
    put("$logs/$tmp{$_}",'x') for qw(stale fresh wide shape other notes short);
    chmod 0644,"$logs/$tmp{wide}" or die;
    utime $old,$old,"$logs/$tmp{$_}" for qw(stale wide shape other notes short);
    put("$work/stale-temp-target",'keep'); symlink "$work/stale-temp-target","$logs/$tmp{linked}" or die;
    system('touch','-h','-t',$old_stamp,"$logs/$tmp{linked}")==0 or die;
    mkdir "$logs/$tmp{dir}",0700 or die; utime $old,$old,"$logs/$tmp{dir}";
    readonly('inspection with stale temp files',$root,sub {inspect($root)});
    ok(-e "$logs/$tmp{stale}",'inspection never cleans stale temp files');
    my $r=acquire($root); is($r->{status},'owned','election succeeds beside stale temp files');
    ok(!-e "$logs/$tmp{stale}",'an aged owner-only regular temp file is removed under the gate');
    ok(-e "$logs/$tmp{$_}","$_ temp entry is kept") for qw(fresh wide shape other notes short dir);
    ok(-l "$logs/$tmp{linked}" && -e "$work/stale-temp-target",'a symlink temp entry is never followed or removed');
    Loomy::CollectorOwner::release($r->{guard});
}

# Cheap revalidation between full checks.
{
    my $root=project('quick-assert',1); my $r=acquire($root); my $g=$r->{guard};
    is(Loomy::CollectorOwner::assert_owner_quick($g),1,'the cheap assertion accepts the owner');
    is(Loomy::CollectorOwner::assert_owner_quick($g,'batch'),1,'the cheap batch phase accepts a collecting owner');
    dies_code('the cheap assertion validates its phase',sub {Loomy::CollectorOwner::assert_owner_quick($g,'bogus')},'INVALID_PHASE');
    dies_code('a copied guard is invalid for the cheap assertion',sub {Loomy::CollectorOwner::assert_owner_quick(bless({},'Loomy::CollectorOwner::Guard'))},'INVALID_GUARD');
    Loomy::CollectorOwner::refresh_scope($g);
    is(Loomy::CollectorOwner::assert_owner_quick($g),1,'a legitimate scope publication keeps the cheap assertion valid');
    Loomy::CollectorOwner::begin_drain($g);
    is(Loomy::CollectorOwner::assert_owner_quick($g),1,'the cheap write phase survives draining');
    dies_code('the cheap batch phase refuses new work while draining',sub {Loomy::CollectorOwner::assert_owner_quick($g,'batch')},'DRAINING');
    Loomy::CollectorOwner::release($g);
    dies_code('a released guard fails the cheap assertion',sub {Loomy::CollectorOwner::assert_owner_quick($g)},'RELEASED');

    for my $kind (qw(record lock)) {
        my $victim=project("quick-fence-$kind",1); my $e=acquire($victim); my $guard=$e->{guard};
        my $path="$victim/.loomy/logs/".($kind eq 'record' ? 'collector-owner-v1.json' : 'collector.lock');
        put("$path.new",bytes($path)); rename "$path.new",$path or die;
        dies_code("a replaced $kind fences the cheap assertion",sub {Loomy::CollectorOwner::assert_owner_quick($guard)},'FENCED');
        dies_code("the fence from the cheap assertion is final for $kind",sub {Loomy::CollectorOwner::assert_owner($guard)},'FENCED');
    }
    {
        my $touch=project('quick-metadata',1); my $te=acquire($touch); my $tg=$te->{guard};
        my $rec="$touch/.loomy/logs/collector-owner-v1.json";
        chmod 0600,$rec or die;
        is(Loomy::CollectorOwner::assert_owner_quick($tg),1,'a no-op chmod (ctime only) does not fence the cheap assertion');
        my $xattr=($^O eq 'darwin') ? ['xattr','-w','com.example.l0','1',$rec] : ['setfattr','-n','user.l0','-v','1',$rec];
        if (system(@$xattr) == 0) {
            is(Loomy::CollectorOwner::assert_owner_quick($tg),1,'an extended attribute (ctime only) does not fence the cheap assertion');
        } else { pass('extended attributes unavailable here; the no-op chmod covers the ctime-only case') }
        is(Loomy::CollectorOwner::assert_owner($tg),1,'the full assertion agrees');
        my $moved="$work/quick-metadata-renamed"; rename $touch,$moved or die;
        dies_code('renaming the project directory fences the cheap assertion',sub {Loomy::CollectorOwner::assert_owner_quick($tg)},'FENCED');
    }
    my $forked=project('quick-fork',1); my $fe=acquire($forked);
    my $kid=child(sub {my $ok=eval {Loomy::CollectorOwner::assert_owner_quick($fe->{guard}); 1}; die unless !$ok && $@ eq "collector owner FORKED\n"});
    reap($kid,'cheap assertion fork'); Loomy::CollectorOwner::release($fe->{guard});
    my $perf=project('quick-perf',1); my $pe=acquire($perf);
    my ($t1,$full,$quick); $t1=time; Loomy::CollectorOwner::assert_owner($pe->{guard}) for 1..300; $full=time-$t1;
    $t1=time; Loomy::CollectorOwner::assert_owner_quick($pe->{guard}) for 1..300; $quick=time-$t1;
    ok($quick<$full,'the cheap assertion costs less than the full assertion');
    Loomy::CollectorOwner::release($pe->{guard});
}

# Skipped registrations stay visible in the owner's scope.
{
    my $main=project('skipped-visible',1); git($main,'init','--quiet');
    git($main,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','--allow-empty','-m','fixture');
    my $wt="$work/skipped-visible-wt"; git($main,'worktree','add','--quiet','--detach',$wt); chmod 0700,$wt or die;
    symlink "$main/.loomy","$wt/.loomy" or die;
    my $real_git=''; for my $dir (split /:/,$ENV{PATH}) {if (-x "$dir/git") {$real_git="$dir/git"; last}}
    my $shim="$work/skipped-shim"; mkdir $shim,0700 or die;
    put("$shim/git",<<'SHIM',0700);
#!/bin/bash
list=0; z=0
for a in "$@"; do [[ $a == worktree ]] && list=1; [[ $a == -z ]] && z=1; done
if (( list )); then
  (( z )) && { echo "error: unknown switch 'z'" >&2; exit 129; }
  "$SHIM_REAL_GIT" "$@" || exit $?
  printf '\nworktree %s/odd\tpath\nHEAD 0000\n' "$SHIM_WORK"
  exit 0
fi
exec "$SHIM_REAL_GIT" "$@"
SHIM
    local $ENV{PATH}="$shim:$ENV{PATH}"; local $ENV{SHIM_REAL_GIT}=$real_git; local $ENV{SHIM_WORK}=$work;
    my $r=acquire($main);
    is($r->{status},'owned','election survives an odd unrelated registration under a Git without -z');
    is_deeply($r->{scope_set}{roots},[sort($main,$wt)],'the admitted union is unaffected by the odd sibling');
    is($r->{scope_set}{skipped},1,'the skipped sibling is counted in the election result');
    is(Loomy::CollectorOwner::scope_set($r->{guard})->{skipped},1,'the owner scope accessor keeps the count');
    is(Loomy::CollectorOwner::refresh_scope($r->{guard})->{skipped},1,'a scope refresh keeps the count');
    Loomy::CollectorOwner::release($r->{guard});
}

alarm 0;
done_testing();

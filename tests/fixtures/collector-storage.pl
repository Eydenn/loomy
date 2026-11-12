# LOCK L1 storage boundary and pure checkpoint evidence. Synthetic roots only: no process
# census, provider, daemon or external service. Guards come from the L0 elector.
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :mode);
use File::Find qw(find);
use File::Path qw(make_path);
use IO::Handle;
use JSON::PP ();
use POSIX ();
use Test::More;
use Time::HiRes ();
use Time::Local ();

my ($repo,$work)=@ARGV;
$repo=abs_path($repo//'') or die "repository required\n";
die "private fixture directory required\n" unless defined $work && !-e $work;
make_path($work,{mode=>0700}); $work=abs_path($work) or die;
require "$repo/scripts/lib/runtime-paths.pl";
require "$repo/scripts/lib/collector-owner.pl";
require "$repo/scripts/lib/live-state.pl";
my $json=JSON::PP->new->utf8->canonical;
local $SIG{ALRM}=sub {die "storage fixture deadline\n"}; alarm 240;
my $T=1_800_000_000; $ENV{LOOMY_NATIVE_NOW}=$T;
my $seq=0;

sub put {
    my ($path,$bytes,$mode)=@_;
    open my $h,'>',$path or die "fixture write failed: $path\n";
    binmode $h; print {$h} $bytes or die; close $h or die;
    chmod($mode//0600,$path) or die;
}
sub bytes {open my $h,'<',$_[0] or die; binmode $h; local $/; return <$h>//''}
sub project {
    my ($name)=@_; my $root="$work/$name";
    make_path("$root/.loomy/logs",{mode=>0700}); chmod 0700,"$root/.loomy","$root/.loomy/logs"; return $root;
}
sub context {return Loomy::RuntimePaths::resolve($_[0])}
sub elect {
    my ($root)=@_; my $r=Loomy::CollectorOwner::try_acquire(context($root),'fixture-build',1);
    die "fixture election failed: $r->{status}/$r->{reason}\n" unless $r->{status} eq 'owned';
    return $r->{guard};
}
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
sub refuses {
    my ($name,$root,$code,$expected)=@_; my $before=manifest($root);
    my $ok=eval {$code->(); 1}; my $err=$@;
    ok(!$ok,"$name refused"); like($err,qr/\Q$expected\E/,"$name names its refusal");
    is_deeply(manifest($root),$before,"$name leaves the whole manifest unchanged");
}
sub logs {"$_[0]/.loomy/logs"}
sub opts {my ($guard,$root)=@_; return {owner=>$guard,context=>context($root),flush=>[]}}
sub cp {
    my ($files)=@_;
    my %f; $f{"/nonexistent/$_"}={meta=>{id=>"id$_"},offset=>$_} for 1..($files//3);
    return {version=>2,files=>\%f,seen=>{a=>1},sent=>{k=>'v'},journal=>{offset=>5}};
}
sub put_cp {put($_[0],$json->encode($_[1])."\n")}
sub quarantine_file {my ($idx)=@_; put("$idx.invalid-1-2","damaged\n")}

# Guard convention and refusal table for collector-origin checkpoint mutators.
Loomy::LiveState::require_owner(1);
my $a=project('a'); my $b=project('b');
my $ga=elect($a); my $gb=elect($b);
my $idx=logs($a)."/codex-native.idx";
put_cp($idx,cp(3));

for my $call (
    ['load',sub {Loomy::LiveState::checkpoint_load($idx)}],
    ['save',sub {Loomy::LiveState::checkpoint_save($idx,cp(2))}],
    ['prune',sub {Loomy::LiveState::checkpoint_prune_invalid($idx)}],
    ['migrate',sub {Loomy::LiveState::migrate_checkpoints($a)}],
) {
    refuses("$call->[0] without options",$a,$call->[1],'collector owner INVALID_GUARD');
}
refuses('load with undefined guard (lost election)',$a,sub {Loomy::LiveState::checkpoint_load($idx,{owner=>undef,context=>context($a)})},'INVALID_GUARD');
refuses('load with forged guard object',$a,sub {Loomy::LiveState::checkpoint_load($idx,{owner=>bless({},'Loomy::CollectorOwner::Guard'),context=>context($a)})},'INVALID_GUARD');
refuses('load with non-guard value',$a,sub {Loomy::LiveState::checkpoint_load($idx,{owner=>{epoch=>'x'},context=>context($a)})},'INVALID_GUARD');
refuses('load with guard of another project',$a,sub {Loomy::LiveState::checkpoint_load($idx,{owner=>$gb,context=>context($b)})},'WRONG_RUNTIME');
refuses('load with guard A and context B',$a,sub {Loomy::LiveState::checkpoint_load($idx,{owner=>$ga,context=>context($b)})},'WRONG_RUNTIME');
refuses('load without a target context',$a,sub {Loomy::LiveState::checkpoint_load($idx,{owner=>$ga})},'WRONG_RUNTIME');
{
    local $ENV{LOOMY_WATCH_ID}='forged'; local $ENV{LOOMY_COLLECTOR_EPOCH}='f' x 64;
    refuses('environment cannot stand in for a guard',$a,sub {Loomy::LiveState::checkpoint_load($idx,{})},'INVALID_GUARD');
}
my $loaded=Loomy::LiveState::checkpoint_load($idx,opts($ga,$a));
is($loaded->{version},2,'owned load returns the supported checkpoint');
is($loaded->{journal}{offset},5,'owned load keeps tolerated fields');

# load can never serve as peek: the owned path demands a guard before reading anything.
Loomy::LiveState::require_owner(0);
ok(eval {Loomy::LiveState::checkpoint_load($idx); 1},'transitional legacy call without options still works until L3 enforces');
Loomy::LiveState::require_owner(1);

# Pure peek.
my $peek=readonly('peek valid',$a,sub {Loomy::LiveState::checkpoint_peek($idx)});
is($peek->{status},'valid','valid primary'); is($peek->{reason},'primary','primary reason');
is($peek->{checkpoint}{sent}{k},'v','peek returns content');
my $none=logs($a)."/claude-native.idx";
$peek=readonly('peek missing',$a,sub {Loomy::LiveState::checkpoint_peek($none)});
is($peek->{status},'unavailable','missing is unavailable'); is($peek->{reason},'missing','missing reason');
{
    my $r=project("peek-absent"); rmdir logs($r) or die;
    $peek=readonly('peek absent logs',$r,sub {Loomy::LiveState::checkpoint_peek(logs($r).'/codex-native.idx')});
    is($peek->{reason},'missing','absent logs is missing'); ok(!-e logs($r),'peek never creates logs');
}

# Supported corruption: peek reports it without repair, owned load quarantines it.
my $c=project('corrupt'); my $cidx=logs($c)."/codex-native.idx"; my $gc=elect($c);
put_cp("$cidx.bak",cp(4)); put($cidx,"{broken");
$peek=readonly('peek invalid primary with valid backup',$c,sub {Loomy::LiveState::checkpoint_peek($cidx)});
is($peek->{status},'stale','invalid primary falls to stale backup'); is($peek->{reason},'backup','backup reason');
my $last=cp(1);
put("$cidx.bak","{also broken");
$peek=readonly('peek both invalid',$c,sub {Loomy::LiveState::checkpoint_peek($cidx)});
is($peek->{status},'unavailable','both invalid is unavailable'); is($peek->{reason},'invalid','invalid reason');
$peek=readonly('peek keeps last valid',$c,sub {Loomy::LiveState::checkpoint_peek($cidx,$last)});
is($peek->{status},'stale','last valid retained across an invalid replacement'); is($peek->{reason},'last-valid','last-valid reason');
is($peek->{checkpoint},$last,'last valid snapshot returned');
put_cp("$cidx.bak",cp(4));
{
    my @w; local $SIG{__WARN__}=sub {push @w,@_};
    my $got=Loomy::LiveState::checkpoint_load($cidx,opts($gc,$c));
    is(scalar(keys %{$got->{files}}),4,'supported corruption recovers from backup'); like("@w",qr/recovered from backup/,'recovery announced');
}
put($cidx,"{broken"); put("$cidx.bak","{broken too");
{
    my @w; local $SIG{__WARN__}=sub {push @w,@_};
    my $got=Loomy::LiveState::checkpoint_load($cidx,opts($gc,$c));
    ok($got->{reconstructing},'supported corruption of every candidate reconstructs');
}
is(scalar(() = glob("$cidx*.invalid-*")),2,'both damaged candidates preserved as quarantine');
ok(!-e $cidx && !-e "$cidx.bak",'damaged candidates moved aside, not rewritten');

# Unsupported formats are refused unchanged: not corruption, not quarantined, not pruned.
for my $case (['future version',sub {+{version=>3,files=>{},extra=>'x'}},'unsupported-version'],
              ['non-numeric version',sub {+{version=>'beta'}},'unsupported-version'],
              ['future shard kind',sub {+{version=>2,source_shards=>['ranges-'.('a' x 64)]}},'unsupported-extension']) {
    my ($label,$make,$reason)=@$case; (my $slug=$label)=~s/\W+/-/g;
    my $r=project("unsupported-$slug"); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r);
    put_cp($ridx,$make->()); put_cp("$ridx.bak",cp(2));
    my $shard_name='files-'.('b' x 64); put("$ridx.$shard_name","{}");
    put("$ridx.invalid-1-1","old\n"); put("$ridx.invalid-1-2","old\n"); put("$ridx.invalid-1-3","old\n"); put("$ridx.bak.invalid-1-4","old\n");
    put(logs($r).'/events.jsonl','');
    $peek=readonly("peek $label with valid v2 backup",$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{status},'unsupported',"$label is unsupported");
    is($peek->{reason},$reason,"$label reason");
    is(ref($peek->{checkpoint}) eq 'HASH' ? scalar(keys %{$peek->{checkpoint}{files}}) : -1,2,"$label offers the backup only as stale display");
    refuses("owned load of $label",$r,sub {Loomy::LiveState::checkpoint_load($ridx,opts($gr,$r))},"unsupported checkpoint format: $reason");
    refuses("owned save over $label",$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(5),opts($gr,$r))},"unsupported checkpoint format: $reason");
    is(readonly("migration over $label",$r,sub {Loomy::LiveState::migrate_checkpoints($r,opts($gr,$r))}),'refused',"migration over $label is refused, not deferred or done");
    ok(!-e logs($r).'/checkpoint-v2','no migration marker written for an unsupported format');
    $peek=readonly("peek $label primary with last valid",$r,sub {Loomy::LiveState::checkpoint_peek($ridx,cp(1))});
    is($peek->{status},'unsupported',"$label precedes last-valid evidence");
}
{
    # Unsupported backup beside a missing or damaged primary is equally untouchable.
    my $r=project('unsupported-backup'); my $ridx=logs($r)."/claude-native.idx"; my $gr=elect($r);
    put($ridx,'{broken'); put_cp("$ridx.bak",{version=>9});
    $peek=readonly('peek damaged primary and future backup',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{reason},'unsupported-version','future backup is unsupported evidence');
    refuses('owned load keeps damaged primary beside a future backup',$r,sub {Loomy::LiveState::checkpoint_load($ridx,opts($gr,$r))},'unsupported checkpoint format: unsupported-version');
}

# Review round L1b: future-format backup, whole-set migration, shard-name precedence,
# FIFO swap, alias layouts, changed-read injection, stale display and owned rotation entries.
{
    my $r=project('future-bak'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    put_cp($ridx,cp(2)); put("$ridx.bak",$json->encode({version=>3,future=>'evidence'})."\n");
    $peek=readonly('peek valid primary beside future backup',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{status},'valid','primary stays the authority'); is($peek->{backup_kind},'unsupported-version','backup kind exposed');
    refuses('load beside a future backup',$r,sub {Loomy::LiveState::checkpoint_load($ridx,$o)},'unsupported checkpoint format: unsupported-version');
    refuses('save beside a future backup',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(9),$o)},'unsupported checkpoint format: unsupported-version');
    is(readonly('migrate beside a future backup',$r,sub {Loomy::LiveState::migrate_checkpoints($r,$o)}),'refused','migrate refuses');
    like(bytes("$ridx.bak"),qr/evidence/,'future backup bytes survive');
    # Backup alone (primary missing) is equally protected, for the whole tool set.
    unlink $ridx; $peek=Loomy::LiveState::checkpoint_peek($ridx); is($peek->{status},'unsupported','missing primary beside future backup is unsupported');
    is(readonly('migrate with only a future backup',$r,sub {Loomy::LiveState::migrate_checkpoints($r,$o)}),'refused','refused'); ok(!-e logs($r).'/checkpoint-v2','no marker');
}
{
    my $r=project('mixed-tools'); my $gr=elect($r); my $o=opts($gr,$r);
    put_cp(logs($r).'/codex-native.idx',{version=>1,files=>{}}); put_cp(logs($r).'/claude-native.idx',{version=>5});
    is(readonly('migrate codex v1 with claude future',$r,sub {Loomy::LiveState::migrate_checkpoints($r,$o)}),'refused','whole set refused before any rewrite');
    ok(!-e logs($r).'/codex-native.idx.bak' && !-e logs($r).'/codex-native.idx.lock' && !-e logs($r).'/checkpoint-v2','codex untouched, no lock, no marker');
}
{
    my $r=project('deferred'); my $gr=elect($r); my $o=opts($gr,$r); my $idxp=logs($r).'/codex-native.idx';
    put_cp($idxp,{version=>1,files=>{}});
    sysopen my $held,"$idxp.lock",O_RDWR|O_CREAT,0600 or die; flock($held,Fcntl::LOCK_EX|Fcntl::LOCK_NB) or die;
    close $held; # a child holds the index lock; one process cannot conflict with itself
    pipe(my $rd,my $wr) or die; pipe(my $rd2,my $wr2) or die;
    my $holder=fork(); die unless defined $holder;
    if (!$holder) {
        Loomy::CollectorOwner::after_fork_child(); close $rd; close $wr2;
        sysopen my $h,"$idxp.lock",O_RDWR,0600 or exit 9; flock($h,Fcntl::LOCK_EX|Fcntl::LOCK_NB) or exit 9;
        syswrite($wr,'x',1); sysread($rd2,my $b,1); exit 0;
    }
    close $wr; close $rd2; sysread($rd,my $b,1);
    is(Loomy::LiveState::migrate_checkpoints($r,$o),'deferred','lost index lock is deferred');
    close $wr2; waitpid($holder,0);
    is(Loomy::LiveState::migrate_checkpoints($r,$o),'done','migration completes once the lock is free');
    is(Loomy::LiveState::migrate_checkpoints($r,$o),'done','already migrated is done');
    is($json->decode(bytes($idxp))->{version},2,'migrated checkpoint is v2');
}
{
    my $sh='ranges-'.('a' x 64);
    for my $names ([qw(junk),$sh],[$sh,'junk'],['junk','files-'.('c' x 64)]) {
        my $k=Loomy::LiveState::_checkpoint_kind({version=>2,source_shards=>$names});
        is($k,($names->[0] eq 'junk' && !grep {$_ eq $sh} @$names) ? 'invalid' : 'unsupported-extension',"shard names @{[join ',', map {substr($_,0,6)} @$names]} classified");
    }
}
{
    # A FIFO swapped in between lstat and open must neither block nor be read.
    my $r=project('fifo'); my $ridx=logs($r)."/codex-native.idx"; put_cp($ridx,cp(1));
    {
        my $fifo=logs($r).'/swap'; POSIX::mkfifo($fifo,0600) or die;
        rename $ridx,"$ridx.keep" or die; rename $fifo,$ridx or die;
        my $t=Time::HiRes::time(); $peek=Loomy::LiveState::checkpoint_peek($ridx);
        ok(Time::HiRes::time()-$t<2,'FIFO primary does not block a follower');
        is($peek->{reason},'unsafe','FIFO primary is unsafe');
    }
}
{
    # Alias layouts: the follower reads the owner's physical store; the sibling spelling is refused.
    my $own=project('alias-owner'); put_cp(logs($own).'/codex-native.idx',cp(2));
    my $s1="$work/alias-dotloomy"; make_path($s1,{mode=>0700}); symlink("$own/.loomy","$s1/.loomy") or die;
    my $s2="$work/alias-logs"; make_path("$s2/.loomy",{mode=>0700}); symlink(logs($own),"$s2/.loomy/logs") or die;
    my $st=Loomy::LiveState->new;
    my $pp=readonly('follower on owner root',$own,sub {Loomy::LiveState::follower_read($st,$own,{})}); is($pp->{codex}{status},'valid','canonical owner root works');
    $pp=Loomy::LiveState::follower_read(Loomy::LiveState->new,logs($own),{}); is($pp->{codex}{status},'valid','logs directory argument works');
    for my $sib ($s1,$s2) {
        $pp=Loomy::LiveState::follower_read(Loomy::LiveState->new,$sib,{});
        is($pp->{codex}{reason},'unsafe',"sibling spelling $sib is not followed");
    }
    is(Loomy::LiveState::checkpoint_peek(logs($own).'/codex-native.idx')->{status},'valid','physical store valid for both layouts');
}
{
    # peek 'changed' via injection: the file changes while it is being read, on both attempts.
    my $r=project('changed'); my $ridx=logs($r)."/codex-native.idx"; put_cp($ridx,cp(2));
    {
        no warnings 'redefine'; my $real=\&Loomy::LiveState::_read_chunk; my $n=0;
        local *Loomy::LiveState::_read_chunk=sub {my @v=$real->(@_); utime(1_700_000_000+(++$n),1_700_000_000+$n,$ridx); return @v};
        $peek=Loomy::LiveState::checkpoint_peek($ridx);
    }
    is($peek->{status},'unavailable','unstable file is unavailable'); is($peek->{reason},'changed','changed reason');
    $peek=Loomy::LiveState::checkpoint_peek($ridx,cp(1)); is($peek->{reason},'primary','stable again after the injection ends');
    my $g=elect($r);
    {
        no warnings 'redefine'; my $real=\&Loomy::LiveState::_read_chunk; my $n=0;
        local *Loomy::LiveState::_read_chunk=sub {my @v=$real->(@_); utime(1_700_000_100+(++$n),1_700_000_100+$n,$ridx); return @v};
        my $before=bytes($ridx); my $ok=eval {Loomy::LiveState::checkpoint_load($ridx,opts($g,$r)); 1};
        ok(!$ok && $@ =~ /checkpoint changed during read/,'owned load on an unstable file refuses'); is(bytes($ridx),$before,'unstable file content untouched');
        ok(!glob("$ridx*invalid*"),'unstable file is never quarantined');
    }
}
{
    # Stale display beside an unsupported primary keeps silent agents alive.
    my $r=project('stale-follower'); my $dir=logs($r); my $hold=elect($r);
    my $src="$work/stale-rollout.jsonl"; put($src,"{}\n"); utime($T-10,$T-10,$src) or die;
    put("$dir/events.jsonl",$json->encode({ts=>'2027-01-15T07:43:20Z',type=>'session_observed',tool=>'codex',session=>'abc',session_key=>'codex:abc',schema=>2,source_active=>1,state=>'running',surface=>'cli'})."\n");
    put_cp("$dir/codex-native.idx",{version=>9}); put_cp("$dir/codex-native.idx.bak",{version=>2,files=>{$src=>{meta=>{id=>'abc'},source_mtime=>$T-1000}}});
    my $st=Loomy::LiveState->new;
    my $pp=readonly('follower beside future primary',$r,sub {Loomy::LiveState::follower_read($st,$r,{})});
    is($pp->{codex}{status},'unsupported','unsupported reported'); ok($pp->{codex}{stale},'stale marker set');
    like(join("\n",$st->projections($T)),qr/^N\|G\|codex:abc\|codex\|cli\|[^|]*\|live\|/m,'stale backup evidence keeps the lease');
}
{
    my $r=project('rotate-owned'); my $go=elect($r);
    refuses('journal_rotate_owned without options',$r,sub {Loomy::LiveState::journal_rotate_owned(logs($r).'/events.jsonl',undef,undef)},'INVALID_GUARD');
    refuses('recover_rotation_owned without options',$r,sub {Loomy::LiveState::recover_rotation_owned(logs($r).'/events.jsonl',logs($r),undef)},'INVALID_GUARD');
    ok(eval {Loomy::LiveState::journal_rotate_owned(logs($r).'/events.jsonl',undef,opts($go,$r)); 1},'owned rotation entry accepts a guard');
}

# Compatible v2 behavior: no version, version 1 and tolerated fields all load and save as v2.
{
    my $r=project('compat'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r);
    put_cp($ridx,{files=>{},future_tolerated=>{x=>1},seen=>{}});
    my $got=Loomy::LiveState::checkpoint_load($ridx,opts($gr,$r));
    is($got->{future_tolerated}{x},1,'unknown tolerated field survives load');
    Loomy::LiveState::checkpoint_save($ridx,$got,opts($gr,$r));
    my $disk=$json->decode(bytes($ridx));
    is($disk->{version},2,'save keeps checkpoint version 2'); is($disk->{future_tolerated}{x},1,'save keeps tolerated field');
    put_cp($ridx,{version=>1,sent=>{}}); is(Loomy::LiveState::checkpoint_load($ridx,opts($gr,$r))->{version},1,'version 1 loads');
    unlink "$ridx.bak";     put_cp($ridx,{version=>2,files=>[]});
    {local $SIG{__WARN__}=sub {}; my $g=eval {Loomy::LiveState::checkpoint_load($ridx,opts($gr,$r))}; diag($@) if $@; ok($g->{reconstructing},'wrong container type is corruption in a supported format')}
}

# Sharded checkpoints round trip through peek and save; the journal handle is flushed first.
{
    my $r=project('shards'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r);
    my %files; $files{"/nonexistent/$_"}={meta=>{id=>"id$_"},pad=>'x' x 1800} for 1..1400;
    my $big={version=>2,files=>\%files,seen=>{}};
    Loomy::LiveState::checkpoint_save($ridx,$big,opts($gr,$r));
    my $disk=$json->decode(bytes($ridx)); ok($disk->{source_shards} && !exists $disk->{files},'large inventory is sharded');
    $peek=readonly('peek sharded',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{status},'valid','sharded primary valid'); is(scalar(keys %{$peek->{checkpoint}{files}}),1400,'shards reassembled by peek');
    my ($shard)=glob("$ridx.files-*"); put($shard,'{"tampered":1}');
    $peek=readonly('peek tampered shard',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{status},'unavailable','tampered shard is corruption'); is($peek->{reason},'invalid','shard checksum failure is invalid, not unsupported');
}

# Unsafe and oversized candidates.
{
    my $r=project('unsafe'); my $ridx=logs($r)."/codex-native.idx"; put(logs($r).'/real',"{}");
    symlink('real',$ridx) or die;
    $peek=readonly('peek symlink',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{reason},'unsafe','symlinked primary is unsafe'); unlink $ridx;
    sysopen my $h,$ridx,O_WRONLY|O_CREAT,0600 or die; truncate($h,33554433) or die; close $h;
    $peek=readonly('peek oversized',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{reason},'invalid','container over 32 MiB is refused');
    unlink $ridx; mkdir $ridx or die;
    $peek=readonly('peek directory',$r,sub {Loomy::LiveState::checkpoint_peek($ridx)});
    is($peek->{reason},'unsafe','non-regular primary is unsafe');
}

# Fencing, draining and ordering at storage boundaries.
{
    my $r=project('fence'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    Loomy::LiveState::checkpoint_save($ridx,cp(2),$o);
    ok(Loomy::CollectorOwner::begin_drain($gr),'drain begins');
    refuses('batch after drain',$r,sub {Loomy::LiveState::owner_check($o,'batch')},'DRAINING');
    ok(eval {Loomy::LiveState::owner_check($o,'event')},'quick event check still allowed while draining the current batch');
    my $jpath=logs($r).'/events.jsonl'; put($jpath,"{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"x\"}\n");
    open my $jh,'>>',$jpath or die; print {$jh} "tail\n";
    my $before=bytes($ridx);
    ok(eval {Loomy::LiveState::checkpoint_save($ridx,cp(3),{%$o,flush=>[$jh]}); 1},'draining save flushes the journal handle then publishes the watermark');
    close $jh;
    is($json->decode(bytes($ridx))->{files}{'/nonexistent/3'}{offset},3,'drain save durable');
    open my $dead,'>',"$work/dead" or die; close $dead;
    my $kept=manifest($r);
    refuses('guarded save without a flush list',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(8),{owner=>$gr,context=>context($r)})},'INVALID_GUARD');
    refuses('flush failure blocks the watermark',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(7),{%$o,flush=>[$dead]})},'journal flush failed');
    Loomy::CollectorOwner::release($gr);
    refuses('released guard cannot save',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(9),$o)},'RELEASED');
    refuses('released guard cannot load',$r,sub {Loomy::LiveState::checkpoint_load($ridx,$o)},'RELEASED');
}
{
    # A replaced lock inode fences further writes; no replacement lock is created.
    my $r=project('lockswap'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    Loomy::LiveState::checkpoint_save($ridx,cp(1),$o);
    rename logs($r).'/collector.lock',logs($r).'/collector.lock.moved' or die;
    put(logs($r).'/collector.lock','',0600);
    refuses('replaced lock fences save',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(2),$o)},'FENCED');
    refuses('fenced guard stays fenced',$r,sub {Loomy::LiveState::checkpoint_load($ridx,$o)},'FENCED');
}

# Batch cadence (L1c): load runs the one full fence, a save in the same batch only the quick check.
{
    my $r=project('cadence'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    put_cp($ridx,cp(2));
    my ($full,$quick)=(0,0);
    {
        no warnings 'redefine';
        my $fa=\&Loomy::CollectorOwner::assert_owner; my $qa=\&Loomy::CollectorOwner::assert_owner_quick;
        local *Loomy::CollectorOwner::assert_owner=sub {$full++; $fa->(@_)};
        local *Loomy::CollectorOwner::assert_owner_quick=sub {$quick++; $qa->(@_)};
        my $s=Loomy::LiveState::checkpoint_load($ridx,$o); Loomy::LiveState::checkpoint_save($ridx,$s,$o);
        is("$full/$quick",'1/1','load takes one full fence, the same-batch save one quick check');
        ($full,$quick)=(0,0);
        Loomy::LiveState::checkpoint_save($ridx,$s,$o);
        is("$full/$quick",'1/0','a save without a batch-start full check runs the full fence');
        ($full,$quick)=(0,0);
        Loomy::LiveState::checkpoint_load($ridx,$o); Loomy::LiveState::checkpoint_save($ridx,$s,{%$o,context=>context($r)});
        is("$full/$quick",'2/0','a different context object forces the full fence');
        ($full,$quick)=(0,0);
        Loomy::LiveState::checkpoint_load($ridx,{%$o,full=>1}); Loomy::LiveState::checkpoint_save($ridx,$s,{%$o,full=>1});
        is("$full/$quick",'2/0','explicit full option keeps both fences');
    }
    # A fence lost between load and save is still caught.
    my $s=Loomy::LiveState::checkpoint_load($ridx,$o);
    rename logs($r).'/collector.lock',logs($r).'/collector.lock.moved' or die;
    put(logs($r).'/collector.lock','',0600);
    my $before=manifest($r);
    refuses('lock replaced between load and save',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(9),$o)},'FENCED');
}
{
    my $r=project('cadence-record'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r); put_cp($ridx,cp(2));
    Loomy::LiveState::checkpoint_load($ridx,$o);
    my $rec=logs($r).'/collector-owner-v1.json'; my $raw=bytes($rec); put($rec,$raw." \n");
    refuses('record replaced between load and save',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(9),$o)},'FENCED');
}
{
    my $r=project('cadence-released'); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r); put_cp($ridx,cp(2));
    Loomy::LiveState::checkpoint_load($ridx,$o); Loomy::CollectorOwner::release($gr);
    refuses('release between load and save',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(9),$o)},'RELEASED');
}

# Interruption at every step of save: old or new generation survives, v2 schema preserved.
for my $sharded (0,1) {
    my $r=project("interrupt$sharded"); my $ridx=logs($r)."/codex-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    my $make=sub {my $n=shift; my %f; $f{"/nonexistent/$_"}={meta=>{id=>"id$_"},pad=>($sharded ? 'x' x 1800 : '')} for 1..($sharded ? 1400 : 3); return {version=>2,files=>\%f,seen=>{gen=>$n}}};
    Loomy::LiveState::checkpoint_save($ridx,$make->(1),$o); Loomy::LiveState::checkpoint_save($ridx,$make->(2),$o);
    for my $step (1..($sharded ? 8 : 3)) {
        my $n=0; my $failed=0;
        {
            no warnings 'redefine'; my $real=\&Loomy::LiveState::atomic_file;
            local *Loomy::LiveState::atomic_file=sub {die "fixture interruption\n" if ++$n==$step; $real->(@_)};
            $failed=!eval {Loomy::LiveState::checkpoint_save($ridx,$make->(3+$step),$o); 1};
        }
        my $got=Loomy::LiveState::checkpoint_peek($ridx);
        ok($got->{checkpoint} && $got->{checkpoint}{version}==2,"interrupted save step $step (sharded=$sharded) leaves a readable v2 generation");
        my $loaded=Loomy::LiveState::checkpoint_load($ridx,$o);
        ok($loaded->{seen}{gen}>=2 && $loaded->{version}==2,"owned load after step $step recovers without quarantine");
        is(scalar(() = glob("$ridx.invalid-*")),0,"no quarantine after interruption $step");
        Loomy::LiveState::checkpoint_save($ridx,$make->(20+$step),$o);
    }
}

# Rotation is dual-origin: hooks need no lifetime lock; a collector passes its guard.
{
    my $r=project('rotate'); my $jpath=logs($r).'/events.jsonl'; my $go=elect($r); my $o=opts($go,$r);
    my $event=sub {$json->encode({ts=>'2020-01-05T00:00:00Z',type=>'session',tool=>'codex',event=>'start',session=>'s1'})."\n"};
    # Hook-origin append runs while another process holds the collector lifetime lock, without it.
    ok(Loomy::LiveState::journal_append($jpath,{type=>'session',tool=>'codex',event=>'start',session=>'hook'},'2026-01-01T00:00:00Z'),'hook-origin append without a guard');
    put($jpath,$event->()x3); put(logs($r).'/month',"2020-01\n");
    refuses('collector rotation with a forged guard',$r,sub {Loomy::LiveState::journal_rotate($jpath,undef,{owner=>{},context=>context($r)})},'INVALID_GUARD');
    refuses('collector rotation without a guard in options',$r,sub {Loomy::LiveState::journal_rotate($jpath,undef,{context=>context($r)})},'INVALID_GUARD');
    ok(!-d logs($r).'/archive','refused rotation created nothing');
    Loomy::LiveState::journal_rotate($jpath,undef,$o);
    my @archived=glob(logs($r).'/archive/events-2020-01-*.jsonl'); is(scalar(@archived),1,'guarded rotation archives');
    ok(-e logs($r).'/month','guarded rotation completes');
    put($jpath,$event->()x3); put(logs($r).'/month',"2020-01\n"); unlink grep {/events-2020/} @archived; unlink glob(logs($r).'/archive/next-*');
    my $before=manifest($r);
    ok(eval {Loomy::LiveState::journal_rotate($jpath); 1},'hook-origin rotation without options still works');
    isnt(manifest($r),$before,'hook-origin rotation proceeded');
}

# Followers: pure, project-id never allocated, live lease clarity from checkpoint plus stat.
{
    my $r=project('follower'); my $dir=logs($r); my $holder=elect($r);
    ok(!-e "$r/.loomy/project-id",'fixture has no project identity');
    my $src="$work/follower-rollout.jsonl"; put($src,"{}\n"); utime($T-10,$T-10,$src) or die;
    my $ev=$json->encode({ts=>'2027-01-15T07:58:40Z',type=>'session_observed',tool=>'codex',session=>'abc',session_key=>'codex:abc',schema=>2,source_active=>1,state=>'running',surface=>'cli'});
    # 1800000000 is 2027-01-15T08:00:00Z; the journal event is 1000 s old.
    $ev=$json->encode({ts=>'2027-01-15T07:43:20Z',type=>'session_observed',tool=>'codex',session=>'abc',session_key=>'codex:abc',schema=>2,source_active=>1,state=>'running',surface=>'cli'});
    put("$dir/events.jsonl","$ev\n");
    put_cp("$dir/codex-native.idx",{version=>2,files=>{$src=>{meta=>{id=>'abc'},source_mtime=>$T-1000}}});
    my $state=Loomy::LiveState->new; my $last={};
    my $peeks=readonly('follower read',$r,sub {Loomy::LiveState::follower_read($state,$r,$last)});
    is($peeks->{codex}{status},'valid','follower sees the checkpoint'); is($peeks->{claude}{reason},'missing','absent claude checkpoint is missing');
    my @rows=$state->projections($T);
    like(join("\n",@rows),qr/^N\|G\|codex:abc\|codex\|cli\|[^|]*\|live\|/m,'silent active agent keeps its lease from stat evidence');
    ok(!-e "$r/.loomy/project-id",'follower never allocates identity');
    # Same journal, but the source is gone: no stat evidence, so the lease honestly lapses.
    unlink $src; my $s2=Loomy::LiveState->new;
    readonly('follower without source',$r,sub {Loomy::LiveState::follower_read($s2,$r,{})});
    like(join("\n",$s2->projections($T)),qr/^N\|G\|codex:abc\|codex\|cli\|[^|]*\|stale\|/m,'no source evidence means stale, never repaired');
    # Atomic replacement by an invalid checkpoint keeps the last valid snapshot and repairs nothing.
    put("$dir/codex-native.idx","{broken");
    my $p=readonly('follower on replaced checkpoint',$r,sub {Loomy::LiveState::follower_read(Loomy::LiveState->new,$r,$last)});
    is($p->{codex}{status},'stale','last valid snapshot retained'); is($p->{codex}{reason},'last-valid','stale reason');
    # A symlinked source outside the owner is never trusted.
    put($src,"{}\n"); my $link="$work/follower-link.jsonl"; symlink($src,$link) or die;
    my $cpl={files=>{$link=>{meta=>{id=>'abc'},source_mtime=>1}}};
    is(Loomy::LiveState::stat_evidence('codex',$cpl),1,'bounded stat pass examined the entry'); is($cpl->{files}{$link}{source_mtime},1,'symlinked source ignored');
    my %many; $many{"/nonexistent/$_"}={meta=>{id=>$_},source_mtime=>$_} for 1..600;
    is(Loomy::LiveState::stat_evidence('codex',{files=>\%many}),256,'stat evidence bounded at 256 entries');
    # Claude call evidence.
    my $csrc="$work/claude-agent.jsonl"; put($csrc,"{}\n"); utime($T-5,$T-5,$csrc) or die;
    my $ccp={sessions=>{lead=>{id=>'lead',calls=>{'agent:a1'=>{call=>'agent:a1',source_mtime=>1}}}},files=>{$csrc=>{meta=>{id=>'lead',agent=>'a1'}}}};
    Loomy::LiveState::stat_evidence('claude',$ccp);
    is($ccp->{sessions}{lead}{calls}{'agent:a1'}{source_mtime},$T-5,'claude agent call lease evidence from stat');
}

# The exact-shape scanner behind journal, transcript and checkpoint decoding must return what
# JSON::PP returns (same structure, same string/number flags, same failures) for every text.
{
    my $pp=JSON::PP->new->utf8->canonical->allow_nonref; my $diverged=0; my $texts=0;
    my $flags=sub {require B; my $f=B::svref_2object(\$_[0])->FLAGS; return $f & (B::SVf_IOK()|B::SVf_NOK()|B::SVf_POK()|B::SVp_IOK()|B::SVp_NOK()|B::SVp_POK()|B::SVf_UTF8())};
    my $same; $same=sub {
        my ($x,$y)=@_; return 0 if ref($x) ne ref($y);
        if (ref($x) eq 'HASH') {return 0 unless join("\0",sort keys %$x) eq join("\0",sort keys %$y); $same->($x->{$_},$y->{$_}) or return 0 for keys %$x; return 1}
        if (ref($x) eq 'ARRAY') {return 0 unless @$x==@$y; $same->($x->[$_],$y->[$_]) or return 0 for 0..$#$x; return 1}
        return $x==$y if ref($x);
        return defined($x)==defined($y) && (!defined($x) || ($x eq $y && $flags->($x)==$flags->($y)));
    };
    my @texts=('{}','[]',' [1, 2 ,3] ','{"a":{"b":[1,{"c":null}],"d":true,"e":false}}','{"a":"x\\ny\\"z\\\\w\\/q\\t"}',
        '{"a":"\\u00e9"}','{"a":1.5}','{"a":-0}','{"a":01}','{"a":1e3}','{"a":123456789012345678}',"{\"a\":\"\xc3\xa9\"}",'{"a":-5}',
        '{"a":tru}','{"a":trueX}','{"a":1}x','{"a":1,}','[1,]','{"":1}','{"a":"\\q"}',"{\"a\":\"\x01\"}","{\"a\":\"\x7f\"}",'{"a":"b"',
        "\t{\"a\": 1 }\n",'{"a":1,"a":2}','"str"','12','null',('[' x 70).(']' x 70),('[' x 40).(']' x 40),
        '{"ts":"2026-10-13T02:05:04.750Z","type":"x","n":7,"z":null,"s":"a b:c.d-e_f"}',
        $pp->encode({sent=>{'start:cl:a:b'=>'1','ctx'=>$pp->encode({model=>'m',n=>3})},files=>{'/p/q.jsonl'=>{at_eof=>0,meta=>{agent=>'',id=>'lead'},offset=>12}}}));
    my @mutated; srand(5);
    for my $t (@texts) {for (1..160) {my $m=$t; next unless length $m; my $i=int rand length $m; my $op=int rand 3;
        if ($op==0) {substr($m,$i,1)=''} elsif ($op==1) {substr($m,$i,0)=substr('{}[]",:0-9nulte\\ .',int rand 19,1)} else {substr($m,$i,1)=substr('{}[]",:0-9nulte\\ .',int rand 19,1)}
        push @mutated,$m}}
    for my $t (@texts,@mutated) {
        $texts++; my $a=eval {Loomy::LiveState::decode_fast($t)}; my $ea=$@ ? 1 : 0; my $b=eval {$pp->decode($t)}; my $eb=$@ ? 1 : 0;
        $diverged++ if $ea!=$eb || (!$ea && (!$same->($a,$b) || $pp->encode($a) ne $pp->encode($b)));
    }
    is($diverged,0,"fast scanner matches JSON::PP on $texts texts"); cmp_ok($texts,">=",4800,"scanner differential covers about 5000 texts");
}
# A byte-identical supported backup is classified once; changed bytes are always classified again.
{
    my $r=project('kind-memo'); my $ridx=logs($r)."/claude-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    put($ridx,$json->encode({version=>2,files=>{},sent=>{a=>'1'}})."\n"); put("$ridx.bak",$json->encode({version=>2,sent=>{}})."\n");
    Loomy::LiveState::checkpoint_load($ridx,$o);
    put("$ridx.bak",$json->encode({version=>3,sent=>{}})."\n");
    refuses('a backup that turns unsupported after a supported load is refused on save',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(5),$o)},'unsupported checkpoint format: unsupported-version');
    put("$ridx.bak",$json->encode({version=>2,sent=>{}})."\n");
    ok(eval {Loomy::LiveState::checkpoint_save($ridx,cp(6),$o); 1},'a supported backup saves again');
    put($ridx,$json->encode({version=>3,files=>{}})."\n");
    refuses('a primary that turns unsupported after a supported save is refused',$r,sub {Loomy::LiveState::checkpoint_save($ridx,cp(7),$o)},'unsupported checkpoint format: unsupported-version');
}

# journal_line: identifier-like fields are quoted directly; everything else must match the JSON::PP bytes.
{
    my $pp=JSON::PP->new->utf8->canonical; my $bad=0; my $n=0;
    my $old=sub {my $e=shift; my %b=%$e; my ($ts,$type)=delete @b{qw(ts type)}; my $q=sub {substr($pp->encode([$_[0]]),1,-1)};
        my $p='{"ts":'.$q->($ts).',"type":'.$q->($type); $p.=',"id":'.$q->(delete $b{id}) if exists $b{id};
        return $p.(keys(%b) ? ','.substr($pp->encode(\%b),1) : '}')."\n"};
    my @ts=('2026-10-13T02:05:04.750Z','2026-10-13T02:05:04Z',"\x{662}\x{660}\x{662}\x{666}-\x{660}\x{661}-\x{660}\x{661}T\x{660}\x{660}:\x{660}\x{660}:\x{660}\x{660}Z",'2026-10-13T02:05:04.7500000000Z',"2026-10-13T02:05:04Z\n",'x"y',"a\\b","t\x01",'\x{e9}',5,1.5,'inf');
    my @ty=('session_observed','delegation_start','x y','Inf','nan','Infinity','9','a/b',"q\"r",'a_b-c.d:e',"\x{e9}t\x{e9}");
    my @id=(undef,'cl:lead:call','lead','7',7,'inf','NaN','a b',"a\n","\x{661}",'x"y','z\\z');
    for my $ts (@ts) {for my $ty (@ty) {for my $id (@id) {
        my %e=(ts=>$ts,type=>$ty,state=>'idle',n=>3); $e{id}=$id if defined $id; $n++;
        my ($a,$b)=(eval {Loomy::LiveState::journal_line(\%e)},eval {$old->(\%e)});
        $bad++ unless (defined($a)==defined($b)) && (!defined($a) || ($a eq $b && !utf8::is_utf8($a)==!utf8::is_utf8($b)));
    }}}
    is($bad,0,"journal_line matches the JSON::PP encoding on $n ts/type/id combinations");
}
# Structural value checks: each kind accepts and rejects the same values as the table-free original.
{
    my $pp=JSON::PP->new->canonical->allow_nonref;
    my %gold=(
        requested=>'c2ff1ff9a647d613e5f279a59e67a9878b8610a5cd41eecaadb917da45e4928e',
        source_active=>'833c841f34cd6ffa59ef41a5dc7115cbd4062b5a8672af48c1f5ef73efa7f2c4',
        task_ref=>'691ae8621035cadb27d09e194b5834989d507991b82a10e5d4f38aa5aab9fcfb',
        label_refs=>'a803e4ce19f67746671aefd96cf73db617f7b328c5d3e4be560b3e62885b4305',
        analysis_codes=>'5c3fb24e2494ff9b08e489e68487ab407720043ab81169d5733adae7c567496d',
        role=>'69a9b5af41965d3a43cf5972c28e216a0b63df49dccdf42bc0ace040f6cdf02d',
        agent_type=>'62c099b773dd1f6a09e7dbd0459a9d17efbcda4f04c2d67b385fd3f23b31cf83',
        agent=>'76220a4b5e38e7c31a97e6c829ade407be8871b034ed26927b22c0173fdd4edd',
        tool=>'f707ced3d8d1789d1d0650bcb7b8f2c6bf382fa9dbcccf3642e254b4961ed817',
        bridge=>'f282c57aa8e566f05f49070b5bdc30cd1fe4ec08779deac7392c2212fbd5ead7',
        effort=>'bc4f967e419c2721863cdc2e92ec9a32a773762b047cab74f2fdaaf30be43bed',
        status=>'6b46f308073bf2294156d406bcf4dbc47ccefa1325c920baa9c54919fc506e38',
        outcome=>'747c9f006a812dcdb4c2056ce7933b181a139e89c8ac93b788899b33d1f3564a',
        state=>'5a3f2e3c3990b741d094bad4023308e1485714cfd35789314510641fd77be072',
        surface=>'63bdab5a95d56878c3d17991590d7d9b4fe974b0437189db8fcd38ff83c6f7eb',
        source=>'68e1a257caaaf7c1a6ed40c4d032a177c19e48c80c12165fb373b1005a021d8e',
        evidence=>'73a81c3cf5865812024d909b72509aad84a6d5f768c33c3a9459fdb06e1cd78d',
        event=>'63186bf9ecdbbd1ded76c86dc5976d140d462a347c46267b3a80513b3ccbdebf',
        reason_code=>'a92293782c3f9d3fd31a8df51193bdf770f34e39daa7419e073e4bdf68290f48',
        multi_agent_version=>'c3a1f8a38f00cd9387a91b3dbfd8d3da13585208e0edcc8311ecda73371ebb14',
        acting=>'748bf19ef1e9c585d16bf9619dff1c0e63fb4f287efa705b996dcfbc18bfb87b',
        master=>'d2674261dcaed06388c44f454bd1d092531372ef00d9b1bbb495a9dd5332c409',
        failover_from=>'d65d2362f7bd95b5820ca8722dae3e36181dedfea1fed1278c3d050f6840e413',
        off_routing=>'edd90a9981620e83113ebc214fd0d92df72871c2cef888eb206f2aef39d5e5cf',
        ts=>'1bfc4a18c273bc188a4590e877fcf9d0cb35c3f6029fdecf6a5c7669e0b52a20',
        source_ts=>'f46b206414e35ea395936640c064a0cc959f43d7065fc1a973f8fe00054b4c43',
        resume_at=>'1f5978d10aee8f0f0faab5967c5fd1b46743c19ec61f7fab0a537c01a4466ba4',
        observed_at=>'db20fa0a54e9e27714daf087bacebf7794876ad853b803e620584f15251c5f94',
        tokens_in=>'fe12c5d11e2c69ccaeba7208caaa7370f3e7e209571594b948bfb855e1dc48f5',
        cost_usd=>'377f3806fcb1adf50cf1b09826d06c71ba1129a881a7180ad7c24cf00483a6a4',
        used_percent=>'a7ad7e96a123181e63785606c57859acf26ba42f0fac4d6dd9a9a865c50268a7',
        signal=>'cdc748a7b90cf9e3d5f14b6b293664122cbac867740a7ba32ce2952c0e476a9c',
        pid=>'b13b231d853dbcd2a24fb521f1955a291acba6e3b7c113116ae4a08bebc7ba68',
        schema=>'be7be72aa7181869098ad29b70d0afac1b2c9c62ef983a80c160c0dbd8679ac8',
        source_inode=>'2610c5862ff5637b0a6c3d4c529456086f2db1c43be3cb7ddc41d10ef94f0d7c',
        model=>'64e399b949360b78b152ebf8ec2218756f2bf4d44c840aebb17f943b58902552',
        requested_model=>'e59bcef6843cabeb6c34c63f1892756a64b6ba75d719ae276da2871a0d7ef417',
        name=>'03c92d3b727a5d5a70636bd832a60d68cf8a1db03953e79700d69f0b734f06d3',
        native_key=>'6474c52497df98d5fdc8806575c22a4c864fdf8d84c027720784105311a0bbcb',
        checkpoint_key=>'3a6a7c1ab7253b6129dc059e241f4dd256de772722103b9ba132caef94f75b16',
        id=>'38862c09c4c3b938ca36b23303a14514ee881c7fb9d811c36e6f3ae0f091a038',
        agent_id=>'d5494814f8ebd724bad2994d691d10ae25e0489ada575fbd838111270d7cb617',
        session=>'dd16d8c3b3fed4a3d72331ef8016f1d9a50048ae86d8ccaef74849ca5e062f94',
        session_key=>'f076a7e31d6ca78ec6d3ac3d605549f6b0067fbec3aea272b9ae22e525dbd84a',
        alias_from=>'01c351bcbf19ae4a134c23ac79400655e6d49d55879533ad5d2cc2cfa66be724',
        parent_session=>'6b265eb3b9a37c4fb31e21490d50345ad349695e0907f7a1a6d050ece3c5133d',
        turn_id=>'c9d98fce7729c42a2007a8b14a4bab1d84ed48b990abd4e71c3d3e7160a4ea7f',
        bogus=>'088009e3a8e2f8ecb9ee73f408c88f9e990f88cd97065e64ca6d45372930256b',
    );
    my @vals=(undef,'','unknown','claude','codex','running','done','sha256:'.('a' x 64),'worker','Explore','my agent','0','1','2','7','-1','1.5','100','101',
        '2026-10-13T02:05:04.750Z','2026-13-45T00:00:00Z','2026-10-13T02:05:04','a:b','cl:lead:call','claude:lead','pending:x','lead:call','a/b','gpt-6/x:y','x' x 130,
        'model,effort','v2','5:6',JSON::PP::true,{a=>1},[1],{});
    my $bad=0;
    for my $k (sort keys %gold) {
        my @rows; for my $v (@vals) {my $r=eval {Loomy::ContentPolicy::_value($k,$v,'proj')}; my $e=$@; $e =~ s/\n//; push @rows,[$k,$v,$e ? "DIE:$e" : $r]}
        $bad++ unless sha256_hex(join("\n",map {$pp->encode($_)} @rows)) eq $gold{$k};
    }
    is($bad,0,'structural value table matches the golden accept/reject results for '.scalar(keys %gold).' keys');
}
# Memos stay correct across their bounds (4096 stamps, 64 checkpoint paths) and wrap-around.
{
    my $bad=0;
    for my $i (0..9000) {
        my $ts=sprintf('2026-%02d-%02dT%02d:%02d:%02dZ',1+$i%12,1+$i%28,$i%24,$i%60,($i*7)%60);
        my $want=Time::Local::timegm(($i*7)%60,$i%60,$i%24,1+$i%28,$i%12,2026);
        $bad++ unless Loomy::LiveState::epoch($ts)==$want && Loomy::CodexNative::epoch($ts)==$want && Loomy::ContentPolicy::_timestamp($ts);
    }
    $bad++ if Loomy::LiveState::epoch('2026-13-45T00:00:00Z')!=0 || Loomy::ContentPolicy::_timestamp('2026-13-45T00:00:00Z');
    is($bad,0,'epoch and timestamp memos stay exact across wrap-around');
    my $r=project('memo-bound'); my $o=opts(elect($r),$r); my $bad2=0;
    for my $i (1..90) {
        my $p=logs($r)."/m$i.idx"; put($p,$json->encode({version=>$i%2 ? 2 : 3,files=>{}})."\n");
        my ($k)=Loomy::LiveState::_checkpoint_read($p); $bad2++ unless $k eq ($i%2 ? 'valid' : 'unsupported-version');
        put("$p.bak",$json->encode({version=>$i%2 ? 3 : 2})."\n");
        my $ref=Loomy::LiveState::_backup_refusal($p); $bad2++ unless defined($ref)==($i%2 ? 1 : 0);
        $bad2++ unless defined(Loomy::LiveState::_backup_refusal($p))==($i%2 ? 1 : 0);
    }
    is($bad2,0,'kind memo answers stay exact past its 64-entry cap');
}
# A backup naming its shards through an escaped key still keeps them on save.
{
    my $r=project('escaped-shard'); my $ridx=logs($r)."/claude-native.idx"; my $gr=elect($r); my $o=opts($gr,$r);
    my $shard='files-'.sha256_hex('{}');
    my $state=cp(2); Loomy::LiveState::checkpoint_save($ridx,$state,$o); put("$ridx.$shard",'{}');
    put("$ridx.bak",'{"\u0073ource_shards":["'.$shard.'"],"version":2}'."\n");
    Loomy::LiveState::checkpoint_save($ridx,$state,$o); # unchanged primary: the backup is left as written
    ok(-e "$ridx.$shard",'a shard named only by an escaped key in the backup is kept');
}
# Disabled project: peek and follower never scaffold anything.
{
    my $r="$work/none"; make_path($r,{mode=>0700});
    readonly('peek without runtime',$r,sub {Loomy::LiveState::checkpoint_peek("$r/.loomy/logs/codex-native.idx")});
    ok(!-e "$r/.loomy",'peek does not scaffold .loomy');
}

done_testing;

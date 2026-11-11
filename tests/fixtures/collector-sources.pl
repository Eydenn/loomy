# LOCK L2 adapter cases (L01-L04, L07, L10-L13): synthetic sources and roots only.
# The collector guard comes from the L0 primitive; adapters never elect when given one.
use strict;
use warnings;
no warnings 'once';
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :mode);
use File::Find qw(find);
use File::Path qw(make_path);
use JSON::PP ();
use POSIX qw(strftime);
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
require "$repo/scripts/lib/live-state.pl";
my $json=JSON::PP->new->utf8->canonical;
local $SIG{ALRM}=sub {die "sources fixture deadline\n"}; alarm 240;
my $NOW=$ENV{LOOMY_NATIVE_NOW};
my ($sessions,$projects)=("$work/codex-sessions","$work/claude-projects");
make_path($sessions,$projects);

sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($NOW+$_[0])).'.250Z'}
sub put {my ($p,$b)=@_; make_path(($p =~ m{^(.*)/[^/]+$})[0]); open my $h,'>',$p or die "write $p"; binmode $h; print {$h} $b; close $h or die}
sub rows {my $p=shift; make_path(($p =~ m{^(.*)/[^/]+$})[0]); open my $h,'>>',$p or die; print {$h} $json->encode($_),"\n" for @_; close $h or die}
sub bytes {open my $h,'<',$_[0] or return ''; binmode $h; local $/; return <$h>//''}
sub git {
    my ($root,@a)=@_; local @ENV{qw(GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT)}=(1,'/dev/null',0);
    system('git','-C',$root,'-c','core.hooksPath=/dev/null',@a)==0 or die "git failed\n";
}
sub manifest {
    my ($root)=@_; my @rows;
    find({no_chdir=>1,wanted=>sub {
        my $path=$File::Find::name; my @s=lstat($path); die unless @s;
        push @rows,join('|',substr($path,length($root)),@s[0,1,2,3,4,5,7,9,10],S_ISREG($s[2]) ? sha256_hex(bytes($path)) : '');
    }},$root);
    return [sort @rows];
}
sub unchanged {
    my ($name,$root,$code)=@_; my $before=manifest($root); my @value=$code->();
    is_deeply(manifest($root),$before,"$name leaves the complete manifest unchanged"); return wantarray ? @value : $value[0];
}
sub dies_code {
    my ($name,$code,$expected)=@_; my $ok=eval {$code->(); 1};
    ok(!$ok,"$name refused"); like($@,qr/\Acollector owner \Q$expected\E\n\z/,"$name reports $expected");
}
sub project {
    my ($name,$git)=@_; my $root="$work/$name"; make_path("$root/.loomy/logs",{mode=>0700}); chmod 0700,"$root/.loomy","$root/.loomy/logs";
    # Explicit compatibility policy: structural journals omit cwd_relative.
    {my $p={%{Loomy::ContentPolicy::defaults()},journal_content=>'legacy-excerpts'}; put("$root/.loomy/logs/content-policy.conf",join('',map {"$_=$p->{$_}\n"} sort keys %$p)); chmod 0600,"$root/.loomy/logs/content-policy.conf"}
    if ($git) {
        git($root,'init','--quiet'); git($root,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','--allow-empty','-m','fixture');
    }
    return $root;
}
# main + a whole-.loomy alias worktree + a logs-only alias worktree.
sub family {
    my ($name)=@_; my $main=project($name,1); my %r=(main=>$main);
    for my $kind (qw(whole logs)) {
        my $wt="$work/$name-$kind"; git($main,'worktree','add','--quiet','--detach',$wt); $r{$kind}=$wt;
        if ($kind eq 'whole') {symlink "$main/.loomy",$wt.'/.loomy' or die}
        else {mkdir "$wt/.loomy",0700 or die; symlink "$main/.loomy/logs","$wt/.loomy/logs" or die}
    }
    return \%r;
}
sub add_sibling {
    my ($main,$name)=@_; my $wt="$work/$name"; git($main,'worktree','add','--quiet','--detach',$wt); symlink "$main/.loomy",$wt.'/.loomy' or die; return $wt;
}
sub slug {my $p=$_[0]; $p =~ s/[^A-Za-z0-9]/-/g; return $p}
my $seq=0;
sub codex_source {
    my ($cwd,$label,$extra)=@_; my $id=sprintf('00000000-0000-4000-8000-%012d',++$seq);
    my $day=strftime('%Y/%m/%d',gmtime($NOW)); my $path="$sessions/$day/rollout-fixture-$id.jsonl";
    rows($path,{timestamp=>ts(-59),type=>'session_meta',payload=>{id=>$id,cwd=>$cwd,timestamp=>ts(-59),source=>'cli'}},
        {timestamp=>ts(-30),type=>'turn_context',payload=>{turn_id=>"t$seq",model=>'gpt-6-luna',effort=>'max'}},
        {timestamp=>ts(-30),type=>'event_msg',payload=>{type=>'task_started',turn_id=>"t$seq"}},
        {timestamp=>ts(-29),type=>'response_item',payload=>{type=>'message',role=>'user',content=>'PRIVATE_PROMPT_CANARY'}});
    return {id=>$id,path=>$path,label=>$label};
}
sub claude_source {
    my ($cwd,$sid,$agent)=@_; my $path="$projects/".slug($cwd)."/$sid.jsonl";
    rows($path,{type=>'user',sessionId=>$sid,cwd=>$cwd,timestamp=>ts(-20),entrypoint=>'cli',uuid=>"u$sid",message=>{role=>'user',content=>'PRIVATE_PROMPT_CANARY'}},
        {type=>'assistant',sessionId=>$sid,cwd=>$cwd,timestamp=>ts(-19),uuid=>"a$sid",message=>{role=>'assistant',model=>'claude-sonnet-5-5',stop_reason=>undef,
            content=>[($agent ? {type=>'tool_use',id=>"call-$sid",name=>'Agent',input=>{subagent_type=>'developer',run_in_background=>JSON::PP::true}} : ())]}});
    return {id=>$sid,path=>$path};
}
sub elect {
    my ($root)=@_; my $ctx=Loomy::RuntimePaths::resolve($root);
    my $r=Loomy::CollectorOwner::try_acquire($ctx,'fixture-build',1); die "election failed: $r->{status} $r->{reason}\n" unless $r->{status} eq 'owned';
    return ($r->{guard},$ctx);
}
sub both {
    my ($root,$guard,$ctx)=@_; my $o={owner=>$guard,context=>$ctx};
    my $c=Loomy::CodexNative::poll($root,$sessions,$o); my $l=Loomy::ClaudeNative::poll($root,$projects,$o); return ($c,$l);
}
sub journal {
    my ($main)=@_; open my $h,'<',"$main/.loomy/logs/events.jsonl" or return (); my @e=map {my $d=eval {$json->decode($_)}; $d ? $d : ()} <$h>; return @e;
}
sub seen {my ($main)=@_; return {map {($_->{session}//'')=>$_} grep {($_->{type}//'') eq 'session_observed' && ($_->{session}//'') ne ''} journal($main)}}
sub count_sessions {my ($main,$id)=@_; return scalar grep {($_->{type}//'') eq 'session_observed' && ($_->{session}//'') eq $id} journal($main)}

# ---------------------------------------------------------------- L01/L03: one guarded poll sees the union from any first sibling
for my $first (qw(main whole logs)) {
    my $f=family("union-$first"); my $main=$f->{main}; my %src;
    for my $k (qw(main whole logs)) {
        $src{"codex-$k"}=codex_source($f->{$k}); $src{"claude-$k"}=claude_source($f->{$k},"claude-$first-$k");
    }
    make_path("$f->{main}/sub/dir"); $src{'codex-sub'}=codex_source("$f->{main}/sub/dir");
    # Excluded: a string-prefix sibling path, an unrelated clone with its own store.
    make_path("$f->{main}-other"); $src{foreign}=codex_source("$f->{main}-other"); $src{foreignc}=claude_source("$f->{main}-other","claude-$first-foreign");
    my $clone=project("union-$first-clone",1); $src{clone}=codex_source($clone); claude_source($clone,"claude-$first-clone");
    my ($guard,$ctx)=elect($f->{$first});
    both($f->{$first},$guard,$ctx) for 1..3;
    my $seen=seen($main);
    for my $k (qw(main whole logs sub)) {ok($seen->{$src{"codex-$k"}{id}},"$first-first watch collects the $k Codex source")}
    for my $k (qw(main whole logs)) {ok($seen->{"claude-$first-$k"},"$first-first watch collects the $k Claude source")}
    ok(!$seen->{$src{foreign}{id}} && !$seen->{"claude-$first-foreign"},"$first-first: a same-prefix non-member path stays excluded");
    ok(!$seen->{$src{clone}{id}} && !$seen->{"claude-$first-clone"},"$first-first: an unrelated clone stays excluded");
    is($seen->{$src{'codex-sub'}{id}}{cwd_relative},'sub/dir',"$first-first: project-relative path of a nested cwd");
    is($seen->{$src{"codex-$_"}{id}}{cwd_relative},'.',"$first-first: $_ cwd is its own root") for qw(whole logs);
    ok(-s "$main/.loomy/logs/claude-native.idx" && -s "$main/.loomy/logs/codex-native.idx",'storage is the canonical owner store');
    ok(!-e "$f->{whole}/.loomy/logs/claude-native.idx.alias-copy",'no stray copy beside the alias');
    is(count_sessions($main,$_),1,"$_ is journaled exactly once (no duplicate collection across repeated polls)") for ("claude-$first-main",$src{'codex-main'}{id});
    if ($first eq 'main') {
        # L02: a bare (legacy) call keeps single-root behavior and never reads another member.
        my $bare=family('union-bare'); my $sib=codex_source($bare->{whole}); my $own=codex_source($bare->{main});
        Loomy::CodexNative::poll($bare->{main},$sessions); my $s=seen($bare->{main});
        ok($s->{$own->{id}},'bare call collects its own root'); ok(!$s->{$sib->{id}},'bare call: nothing outside its root');
        # Later sibling admission and removal (L03).
        my $before=count_sessions($main,'x'); my $extra=add_sibling($main,'union-main-extra');
        my $late=codex_source($extra); my $lateclaude=claude_source($extra,'claude-late');
        both($main,$guard,$ctx) for 1..2;
        ok(!seen($main)->{$late->{id}},'a sibling registered after the revision is not read before the owner refreshes the scope');
        my $set=Loomy::CollectorOwner::refresh_scope($guard); ok(scalar(grep {$_ eq $extra} @{$set->{roots}}),'owner scope refresh admits the new sibling');
        both($main,$guard,$ctx) for 1..3;
        ok(seen($main)->{$late->{id}} && seen($main)->{'claude-late'},'later sibling admission: both adapters collect it without restarting');
        is(count_sessions($main,$late->{id}),1,'admitted sibling is journaled once');
        my $held=scalar(grep {($_->{session}//'') eq $late->{id}} journal($main)); my $held_claude=scalar(grep {($_->{session}//'') eq 'claude-late'} journal($main));
        unlink "$extra/.loomy" or die; Loomy::CollectorOwner::refresh_scope($guard);
        rows($late->{path},{timestamp=>ts(5),type=>'event_msg',payload=>{type=>'task_complete',turn_id=>"t$seq"}});
        rows($lateclaude->{path},{type=>'user',sessionId=>'claude-late',cwd=>$extra,timestamp=>ts(6),uuid=>'late2',message=>{role=>'user',content=>'x'}});
        my $fresh=codex_source($main);
        my $jb=-s "$main/.loomy/logs/events.jsonl"; both($main,$guard,$ctx) for 1..3;
        is(scalar(grep {($_->{session}//'') eq $late->{id}} journal($main)),$held,'removed sibling: no new Codex events, history retained');
        is(scalar(grep {($_->{session}//'') eq 'claude-late'} journal($main)),$held_claude,'removed sibling: no new Claude reads');
        ok(seen($main)->{$fresh->{id}},'removal of one member leaves the others collected');
        ok(Loomy::CollectorOwner::assert_owner($guard),'scope removal keeps the guard valid');
        # Idle ticks of a held guard: no election, no source read, no JSON encode (L12).
        {no warnings 'redefine'; local *Loomy::CodexNative::open_read=sub {die "idle read\n"};
         ok(eval {both($main,$guard,$ctx); both($main,$guard,$ctx); 1},'idle polls under a held guard re-read nothing') or diag $@}
        # L04: no global safe-path relaxation: a symlinked rollout directory stays rejected.
        my $real="$work/real-sessions"; make_path("$real/2026/10/13"); symlink $real,"$work/link-sessions" or die;
        ok(!defined(Loomy::CodexNative::poll($main,"$work/link-sessions",{owner=>$guard,context=>$ctx})),'a symlinked sessions directory is still refused for a guarded poll');
        ok(!Loomy::CodexNative::safe_path("$f->{whole}/.loomy/logs"),'safe_path itself is unchanged (alias spelling is not relaxed)');
        Loomy::CollectorOwner::release($guard);
        # Bare-election switch: a non-owner mutates nothing; a free slot is taken for one call and freed.
        my ($g2,$c2)=elect($main); local $Loomy::CodexNative::bare_election=1;
        unchanged('a bare call that loses the election',"$main/.loomy/logs",sub {Loomy::CodexNative::poll($main,$sessions)});
        Loomy::CollectorOwner::release($g2);
        codex_source($main); my $r=Loomy::CodexNative::poll($main,$sessions);
        ok(defined $r,'a bare call with the election switch on owns the free slot'); is(Loomy::CollectorOwner::inspect(Loomy::RuntimePaths::resolve($main))->{reason},'free','and frees it afterwards');
        next;
    }
    Loomy::CollectorOwner::release($guard);
}

# ---------------------------------------------------------------- L01/L02: guard validation before any storage is touched
{
    my $a=project('guard-a',0); my $b=project('guard-b',0); codex_source($a); claude_source($a,'claude-guard-a');
    my ($ga,$ca)=elect($a); my ($gb,$cb)=elect($b);
    for my $adapter (['Codex',sub {Loomy::CodexNative::poll($a,$sessions,$_[0])}],['Claude',sub {Loomy::ClaudeNative::poll($a,$projects,$_[0])}]) {
        my ($n,$call)=@$adapter;
        unchanged("$n: options without an owner",$a,sub {dies_code("$n: options without an owner",sub {$call->({context=>$ca})},'INVALID_GUARD')});
        unchanged("$n: a forged guard",$a,sub {my $x=1; dies_code("$n: a forged guard",sub {$call->({owner=>bless(\$x,'Loomy::CollectorOwner::Guard'),context=>$ca})},'INVALID_GUARD')});
        unchanged("$n: a copied guard value",$a,sub {my $copy=$$ga; dies_code("$n: a copied guard value",sub {$call->({owner=>\$copy,context=>$ca})},'INVALID_GUARD')});
        unchanged("$n: project B's guard for project A",$a,sub {dies_code("$n: a guard for another runtime",sub {$call->({owner=>$gb,context=>$ca})},'WRONG_RUNTIME')});
        unchanged("$n: a missing target context",$a,sub {dies_code("$n: a missing target context",sub {$call->({owner=>$ga})},'WRONG_RUNTIME')});
    }
    ok(Loomy::CollectorOwner::assert_owner($ga,'batch',$ca),'a wrong target does not discard valid ownership');
    both($a,$ga,$ca); ok(seen($a)->{'claude-guard-a'},'the valid guard still collects after the refusals');
    Loomy::CollectorOwner::release($gb);
    # Draining admits no new batch; the poll returns without writing.
    codex_source($a); Loomy::CollectorOwner::begin_drain($ga);
    my $drained=unchanged('a poll while draining',"$a/.loomy/logs",sub {Loomy::CodexNative::poll($a,$sessions,{owner=>$ga,context=>$ca})});
    ok(!defined $drained,'draining: no new collection batch is admitted');
    Loomy::CollectorOwner::release($ga);
    dies_code('a released guard',sub {Loomy::ClaudeNative::poll($a,$projects,{owner=>$ga,context=>$ca})},'RELEASED');
}

# ---------------------------------------------------------------- L04: lock replacement fences the poll, also between events
{
    my $r=project('fence-lock',0); my @c=map {codex_source($r)} 1..4; my ($g,$c)=elect($r);
    rename "$r/.loomy/logs/collector.lock","$r/.loomy/logs/collector.lock.old" or die; put("$r/.loomy/logs/collector.lock",''); chmod 0600,"$r/.loomy/logs/collector.lock";
    my $before=-s "$r/.loomy/logs/events.jsonl";
    dies_code('a replaced lock inode (batch start)',sub {Loomy::CodexNative::poll($r,$sessions,{owner=>$g,context=>$c})},'FENCED');
    is(-s "$r/.loomy/logs/events.jsonl",$before,'fenced poll appended nothing');
    ok(!-e "$r/.loomy/logs/codex-native.idx",'fenced poll saved nothing');
    my $mid=project('fence-mid',0); codex_source($mid) for 1..4; my ($g2,$c2)=elect($mid); my $n=0;
    {
        no warnings 'redefine'; my $orig=\&Loomy::LiveState::journal_event_line;
        local *Loomy::LiveState::journal_event_line=sub {
            if (++$n==2) {rename "$mid/.loomy/logs/collector.lock","$mid/.loomy/logs/collector.lock.old" or die; put("$mid/.loomy/logs/collector.lock",''); chmod 0600,"$mid/.loomy/logs/collector.lock"}
            return $orig->(@_);
        };
        dies_code('a lock replaced between events',sub {Loomy::CodexNative::poll($mid,$sessions,{owner=>$g2,context=>$c2})},'FENCED');
    }
    is(scalar(grep {($_->{bridge}//'') eq 'codex-native'} journal($mid)),1,'only the event before the fence was appended');
    my $mc=project('fence-mid-claude',0); claude_source($mc,"claude-mid-$_") for 1..3; my ($g3,$c3)=elect($mc); $n=0;
    {
        no warnings 'redefine'; my $orig=\&Loomy::LiveState::journal_event_line;
        local *Loomy::LiveState::journal_event_line=sub {
            if (++$n==2) {rename "$mc/.loomy/logs/collector.lock","$mc/.loomy/logs/collector.lock.old" or die; put("$mc/.loomy/logs/collector.lock",''); chmod 0600,"$mc/.loomy/logs/collector.lock"}
            return $orig->(@_);
        };
        dies_code('Claude: a lock replaced between events',sub {Loomy::ClaudeNative::poll($mc,$projects,{owner=>$g3,context=>$c3})},'FENCED');
    }
    is(scalar(grep {($_->{bridge}//'') eq 'claude-native'} journal($mc)),1,'Claude: only the event before the fence was appended');
}

# ---------------------------------------------------------------- L07/L10/L13: crash replay, handover, accounting, argument shape
{
    my $r=project('crash',0); my $c1=codex_source($r); claude_source($r,'claude-crash',1); my ($g,$c)=elect($r);
    my %shape;
    {
        no warnings 'redefine'; no strict 'refs';
        for my $name (qw(checkpoint_load checkpoint_save)) {
            my $orig=\&{"Loomy::LiveState::$name"};
            *{"Loomy::LiveState::$name"}=sub {my @a=@_; push @{$shape{$name}},$a[-1]; return $orig->(@_)};
        }
        both($r,$g,$c);
    }
    for my $name (qw(checkpoint_load checkpoint_save)) {
        ok($shape{$name} && !grep({ref($_) ne 'HASH' || !defined $_->{owner} || $_->{owner} != $g || $_->{context} != $c} @{$shape{$name}}),"$name receives the trailing {owner,context} pair");
    }
    # Interruption after append, before the checkpoint: replay must not duplicate any native key.
    my $k=project('crash-replay',0); codex_source($k) for 1..2; claude_source($k,'claude-replay',1); my ($gk,$ck)=elect($k);
    {
        no warnings 'redefine'; local *Loomy::LiveState::checkpoint_save=sub {die "injected interruption\n"};
        ok(!eval {Loomy::CodexNative::poll($k,$sessions,{owner=>$gk,context=>$ck}); 1} && $@ eq "injected interruption\n",'Codex interrupted after append and before the checkpoint');
        ok(!eval {Loomy::ClaudeNative::poll($k,$projects,{owner=>$gk,context=>$ck}); 1} && $@ eq "injected interruption\n",'Claude interrupted after append and before the checkpoint');
    }
    my $after_crash=scalar(grep {($_->{bridge}//'') =~ /-native$/} journal($k));
    both($k,$gk,$ck) for 1..3;
    my %keys; $keys{($_->{native_key}//$_->{checkpoint_key}//'')}++ for grep {($_->{bridge}//'') =~ /-native$/} journal($k);
    is(scalar(grep {$_ ne '' && $keys{$_}>1} keys %keys),0,'replay after the interruption appends no duplicate native key');
    ok(scalar(grep {($_->{bridge}//'') =~ /-native$/} journal($k))>=$after_crash,'old evidence is kept and the replay completes the rest');
    # Handover: a second owner (new epoch) continues without duplicates or extra usage rows.
    Loomy::LiveState::journal_append("$k/.loomy/logs/events.jsonl",{type=>'usage',tool=>'claude',family=>'claude',scope=>'subagent',model=>'claude-sonnet-5-5',cost_usd=>0.25,session=>'claude-replay'},ts(3));
    my $rows=sub {scalar grep {($_->{type}//'') eq $_[0]} journal($k)}; my $native=sub {scalar grep {($_->{bridge}//'') =~ /-native$/} journal($k)};
    my ($u,$n)=($rows->('usage'),$native->()); Loomy::CollectorOwner::release($gk);
    my ($g2,$c2)=elect($k); both($k,$g2,$c2) for 1..3;
    is($rows->('usage'),$u,'handover creates no extra usage row'); is($native->(),$n,'handover replays no native event');
    my %starts; $starts{$_->{id}//''}++ for grep {($_->{type}//'') eq 'delegation_start'} journal($k);
    is(scalar(grep {$_ ne '' && $starts{$_}>1} keys %starts),0,'each delegation starts once across the handover');
    ok(scalar(grep {($_->{agent_type}//'') eq 'developer'} journal($k)),'agent_type is preserved');
    # L11: canaries never reach ownership state or the journal.
    my $record=bytes("$k/.loomy/logs/collector-owner-v1.json"); my $journal=bytes("$k/.loomy/logs/events.jsonl");
    unlike($record,qr/PRIVATE|claude-replay|rollout|\Q$sessions\E|\Q$projects\E/,'ownership record carries no label, source path or prompt');
    unlike($journal,qr/PRIVATE_PROMPT_CANARY/,'journal carries no prompt content');
    Loomy::CollectorOwner::release($g2);
}

# ---------------------------------------------------------------- L12: bounded cost
{
    my @cpu;
    for my $i (1..20) {
        my $r=project("cold-$i",0); codex_source($r); claude_source($r,"claude-cold-$i",1); my ($g,$c)=elect($r);
        Loomy::CodexNative::reset_caches();
        my $t0=(times)[0]+(times)[1]; both($r,$g,$c); push @cpu,((times)[0]+(times)[1]-$t0)*1000;
        Loomy::CollectorOwner::release($g);
    }
    my @sorted=sort {$a<=>$b} @cpu; my $p95=$sorted[int(0.95*$#sorted+0.5)];
    printf "# paired cold poll (codex+claude, guarded, election excluded): p50 %.1f ms p95 %.1f ms max %.1f ms\n",$sorted[$#sorted/2],$p95,$sorted[-1];
    cmp_ok($p95,'<=',80,'paired cold poll p95 stays within 80 ms');
    # Discovery keeps its 32-file / 2 MiB-per-tick bound for the union.
    my $r=project('bounded',0); my $other=project('bounded-other',0); codex_source($other) for 1..50; my ($g,$c)=elect($r);
    my $reads=0; {no warnings 'redefine'; my $o=\&Loomy::CodexNative::metadata; local *Loomy::CodexNative::metadata=sub {++$reads; $o->(@_)};
        Loomy::CodexNative::poll($r,$sessions,{owner=>$g,context=>$c})}
    cmp_ok($reads,'<=',32,'discovery reads at most 32 rollout heads per tick'); Loomy::CollectorOwner::release($g);
}
# ---------------------------------------------------------------- L07 (L1 API): unsupported checkpoint = read-only refusal, nothing rewritten
SKIP: {
    skip 'storage without the L1 fence API',6 unless Loomy::LiveState->can('owner_check');
    my $r=project('unsupported',0); codex_source($r); claude_source($r,'claude-unsupported'); my ($g,$c)=elect($r);
    for my $t (['codex-native.idx',sub {Loomy::CodexNative::poll($r,$sessions,{owner=>$g,context=>$c})}],['claude-native.idx',sub {Loomy::ClaudeNative::poll($r,$projects,{owner=>$g,context=>$c})}]) {
        put("$r/.loomy/logs/$t->[0]",'{"version":3,"future":true}'); my $before=bytes("$r/.loomy/logs/$t->[0]");
        my $j=-s "$r/.loomy/logs/events.jsonl"//0; my $got=eval {$t->[1]->()};
        ok(!defined $got && !$@,"$t->[0]: an unsupported primary yields a refusal, not a die");
        like($Loomy::CodexNative::refusal,qr/\Aunsupported-(?:format|version)\z/,"$t->[0]: the read-only reason is surfaced");
        is(bytes("$r/.loomy/logs/$t->[0]"),$before,"$t->[0]: the unsupported primary is never rewritten");
    }
    Loomy::CollectorOwner::release($g);
}
# ---------------------------------------------------------------- L2d: refusal memo, nothing created, label guard, signature, guard identity
SKIP: {
    skip 'storage without the L1 fence API',16 unless Loomy::LiveState->can('owner_check');
    for my $tool (qw(codex claude)) {
        my $r=project("memo-$tool",0); codex_source($r); claude_source($r,"claude-memo-$tool"); my ($g,$c)=elect($r);
        my $idx="$r/.loomy/logs/$tool-native.idx"; put($idx,'{"version":3}');
        my $poll=$tool eq 'codex' ? sub {Loomy::CodexNative::poll($r,$sessions,{owner=>$g,context=>$c})} : sub {Loomy::ClaudeNative::poll($r,$projects,{owner=>$g,context=>$c})};
        my $watch=$tool eq 'codex' ? sub {Loomy::CodexNative::watch_changed($r,$sessions,$NOW,{owner=>$g,context=>$c})} : sub {Loomy::ClaudeNative::watch_changed($r,$projects,{owner=>$g,context=>$c})};
        ok(!-e "$idx.lock",'$tool: the refused manifest has no lock yet');
        my $reads=0; no warnings 'redefine';
        my ($lo,$po)=(\&Loomy::LiveState::checkpoint_load,\&Loomy::LiveState::checkpoint_peek);
        local *Loomy::LiveState::checkpoint_load=sub {++$reads; $lo->(@_)}; local *Loomy::LiveState::checkpoint_peek=sub {++$reads; $po->(@_)};
        ok(!defined $poll->(),"$tool: first poll is refused"); ok(!-e "$idx.lock","$tool: a refused poll creates no idx.lock");
        my $first=$reads; cmp_ok($first,'>=',1,"$tool: the refusal read the manifest once");
        ok(!defined $poll->() && !defined $poll->(),"$tool: repeated polls stay refused"); is($reads,$first,"$tool: repeated polls read nothing");
        ok(!$watch->(),"$tool: watch_changed is false while the manifest is unchanged");
        like($Loomy::CodexNative::refusal,qr/\Aunsupported-/,"$tool: the same reason is returned");
        unlink $idx; ok(defined $poll->(),"$tool: a changed manifest is read again and collected");
        Loomy::CollectorOwner::release($g);
    }
    # Label writes are owner-checked like appends.
    my $r=project('labels',0); my $f="$projects/".slug($r)."/lead.jsonl";
    rows($f,{type=>'user',sessionId=>'lead',cwd=>$r,timestamp=>ts(-20),entrypoint=>'cli',message=>{role=>'user',content=>'x'}},
        {type=>'assistant',sessionId=>'lead',cwd=>$r,timestamp=>ts(-19),message=>{role=>'assistant',model=>'claude-sonnet-5-5',stop_reason=>undef,
            content=>[map {{type=>'tool_use',id=>"call$_",name=>'Agent',input=>{subagent_type=>'developer',description=>"d$_"}}} 1..3]}});
    my ($g,$c)=elect($r); my $n=0;
    {
        no warnings 'redefine'; my $orig=\&Loomy::LiveState::content_label;
        local *Loomy::LiveState::content_label=sub {
            if (++$n==1) {rename "$r/.loomy/logs/collector.lock","$r/.loomy/logs/collector.lock.old" or die; put("$r/.loomy/logs/collector.lock",''); chmod 0600,"$r/.loomy/logs/collector.lock"}
            return $orig->(@_);
        };
        dies_code('a lock replaced during label writes',sub {Loomy::ClaudeNative::poll($r,$projects,{owner=>$g,context=>$c})},'FENCED');
    }
    is($n,1,'no label write after the fence');
    # A removed member's growth does not make the input signature change.
    my $fam=family('sigfam'); my $own=codex_source($fam->{main}); my $gone=codex_source($fam->{whole});
    my ($g2,$c2)=elect($fam->{main}); my $o={owner=>$g2,context=>$c2};
    Loomy::CodexNative::poll($fam->{main},$sessions,$o) for 1..3;
    unlink "$fam->{whole}/.loomy" or die; Loomy::CollectorOwner::refresh_scope($g2);
    Loomy::CodexNative::poll($fam->{main},$sessions,$o) for 1..10;
    Loomy::CodexNative::watch_changed($fam->{main},$sessions,$NOW,$o);
    rows($gone->{path},{timestamp=>ts(9),type=>'event_msg',payload=>{type=>'task_complete',turn_id=>'tz'}});
    ok(!Loomy::CodexNative::watch_changed($fam->{main},$sessions,$NOW,$o),'growth of a removed member does not trigger a poll');
    # Guard identity: a new acquisition is a change, the same guard is not, even after the old one is freed.
    my $r3=project('identity',0); my ($ga,$ca)=elect($r3);
    ok(!Loomy::CodexNative::guard_changed('k',$ga),'first guard is not a change'); ok(!Loomy::CodexNative::guard_changed('k',$ga),'the same guard is not a change');
    Loomy::CollectorOwner::release($ga); undef $ga; my ($gb)=elect($r3);
    ok(Loomy::CodexNative::guard_changed('k',$gb),'a reacquired guard is a change');
    Loomy::CollectorOwner::release($gb); Loomy::CollectorOwner::release($g2);
}
done_testing;

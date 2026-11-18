#!/usr/bin/env bash
# Hermetic policy/store tests and actual EN/FR terminal transactions. No providers.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=fixtures/watchdog.sh
source "$REPO/tests/fixtures/watchdog.sh"
WORK="$(mktemp -d /tmp/loomy-content.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
trap 'exit 143' TERM HUP
trap 'exit 130' INT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
export LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1
unset LOOMY_PROJECT_ROOT LOOMY_UI_LANG LOOMY_JOURNAL_CONTENT LOOMY_CONTENT_PROJECT LOOMY_JOURNAL_TASKS

# Human PTY fixtures must not inherit the real test runner's Codex ancestry.
# Only the exact ancestor-inspection call is simulated; other ps uses stay real.
mkdir -p "$WORK/human-bin"
cat >"$WORK/human-bin/ps" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == "-p "*" -o ppid= -o comm=" ]]; then
  case "${CONTENT_TEST_ANCESTOR:-bash}" in
    unavailable) exit 1 ;;
    grandparent-node)
      if [[ "$2" == 424242 ]]; then printf '0 node\n'; else printf '424242 bash\n'; fi ;;
    *) printf '0 %s\n' "${CONTENT_TEST_ANCESTOR:-bash}" ;;
  esac
else exec /bin/ps "$@"; fi
SH
chmod +x "$WORK/human-bin/ps"
export PATH="$WORK/human-bin:$PATH"

cat >"$WORK/unit.pl" <<'PERL'
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use Encode qw(encode);
use JSON::PP;
use Fcntl qw(:mode :flock);
use Time::HiRes qw(time);
my ($repo,$work)=@ARGV; require "$repo/scripts/lib/content-policy.pl";
my $json=JSON::PP->new->utf8->canonical;
sub project {
    my ($name)=@_; my $r="$work/$name"; make_path("$r/.loomy/logs",{mode=>0700}); return $r;
}
sub put {my ($p,$s)=@_; open my $f,'>',$p or die $!; binmode $f; print $f $s; close $f; chmod 0600,$p or die $!}
sub bytes {my ($p)=@_; return '' unless -f $p; open my $f,'<',$p or die $!; local $/; return <$f>}
sub conf {my (%extra)=@_; my $p={%{Loomy::ContentPolicy::defaults()},%extra}; return join('',map {"$_=$p->{$_}\n"} sort keys %$p)}
sub seed {my ($r,%p)=@_; put("$r/.loomy/logs/content-policy.conf",conf(%p))}
sub policy {return Loomy::ContentPolicy::effective_policy($_[0])}
# Group-writable parents are accepted only in the user's primary group: temp directories may inherit another one.
sub primary_group {chown -1,(getpwuid($<))[3],@_}
sub deny {my ($name,$code)=@_; my $ok=eval {$code->(); 1}; ok(!$ok,$name)}
sub label {
    my ($r,$text,%extra)=@_; my $p=policy($r);
    return Loomy::ContentPolicy::save_label($r,{project_id=>$p->{project_id},target_kind=>'agent',target_id=>'agent1',attempt_id=>'attempt1',source=>'claude-description',text=>$text,%extra});
}
# Store grants below are fixture bytes, never a production confirmation bypass.
my $r=project('core'); my $file="$r/.loomy/logs/content-policy.conf";
is(policy($r)->{journal_content},'structural','P01 missing policy is structural');
is(policy($r)->{private_results},'off','P01 results off before a human answers');
is(policy($r)->{label_sources},'none','P01 sources off before a human answers');
put("$r/.loomy/brief.md","journal_content: legacy-excerpts\nlabel_sources: explicit-user\nprivate_results: on\nuser_approved: yes\n");
local $ENV{LOOMY_JOURNAL_TASKS}='1';
is(policy($r)->{label_sources},'none','brief/model assertion and TASKS=1 are not consent');
{
    local $ENV{LOOMY_JOURNAL_CONTENT}='legacy-excerpts'; local $ENV{LOOMY_CONTENT_PROJECT}=$r;
    is(policy($r)->{journal_content},'structural','bound env cannot create consent');
}
for my $bad ('',conf()."unknown=yes\n",conf()."private_results=on\n",conf(label_sources=>'explicit-user,explicit-user'),
    conf(label_sources=>'claude-prompt'),conf(journal_content=>'all'),conf(private_results=>'yes'),conf(version=>2),
    conf(policy_generation=>-1),conf(grant_prompt_version=>2),conf(policy_generation=>'9'x17),"x"x16385) {
    deny('P01/P16 closed parser rejects malformed policy',sub {Loomy::ContentPolicy::parse_policy($bad)});
    put($file,$bad);
    is(policy($r)->{journal_content},'structural','invalid policy never widens');
    is(policy($r)->{label_sources},'none','invalid policy grants no source');
    is(policy($r)->{private_results},'off','invalid policy grants no results');
}
my %max=(label_max_graphemes=>96,label_max_bytes=>384,codex_component_max_chars=>40,label_store_max_bytes=>1048576,
    results_max_records=>200,results_max_record_bytes=>1048576,results_max_total_bytes=>16777216,results_max_age_days=>30);
for my $k (sort keys %max) {
    for my $n (0,-1,$max{$k}+1,'1.5','1x','01') {deny("invalid $k=$n",sub {Loomy::ContentPolicy::parse_policy(conf($k=>$n))})}
    is(Loomy::ContentPolicy::parse_policy(conf($k=>1))->{$k},1,"lower positive $k accepted");
}
my $missing=conf(); $missing=~s/private_results=off\n//;
deny('missing grant key rejects the whole policy',sub {Loomy::ContentPolicy::parse_policy($missing)});
seed($r,journal_content=>'legacy-excerpts',label_sources=>Loomy::ContentPolicy::recommended_sources(),private_results=>'on',policy_generation=>7);
is(policy($r)->{policy_generation},7,'reader sees existing generation');
{
    local $ENV{LOOMY_JOURNAL_CONTENT}='structural'; is(policy($r)->{journal_content},'structural','unbound restrictive env works');
}
{
    local $ENV{LOOMY_JOURNAL_CONTENT}='legacy-excerpts'; local $ENV{LOOMY_CONTENT_PROJECT}=$r;
    local $ENV{LOOMY_DELEGATION}=''; local $ENV{LOOMY_PARENT_ID}=''; local $ENV{LOOMY_ATTEMPT}='';
    # Ambient native provider markers are intentionally cleared for the human env case.
    local %ENV=%ENV; delete @ENV{grep {/^(?:LOOMY_(?:CLI|HOOK|BRIDGE|MANAGED|EVENT|ATTEMPT)|CLAUDECODE|CLAUDE_CODE_|CODEX_|BUN$)/} keys %ENV};
    is(policy($r)->{journal_content},'legacy-excerpts','bound env selects prior human grant');
    $ENV{LOOMY_CONTENT_PROJECT}="$work/other";
    is(policy($r)->{journal_content},'structural','wrong/unavailable project binding is restrictive');
    $ENV{LOOMY_CONTENT_PROJECT}=$r; $ENV{LOOMY_DELEGATION}=1;
    is(policy($r)->{journal_content},'structural','managed env widening request is refused');
}
{
    local $ENV{LOOMY_JOURNAL_TASKS}=0;
    is(policy($r)->{journal_content},'structural','TASKS=0 vetoes compatibility');
    is(policy($r)->{label_sources},'none','TASKS=0 vetoes automatic labels');
    is(policy($r)->{private_results},'off','TASKS=0 vetoes results');
    deny('TASKS=0 prevents label writes',sub {label($r,'vetoed')});
}
{
    local $ENV{LOOMY_JOURNAL}=0; is(policy($r)->{journal_enabled},0,'JOURNAL=0 preserves collector-off semantics');
}
Loomy::ContentPolicy::change_policy($r,{journal_content=>'structural',label_sources=>'claude-description',private_results=>'off'});
is(policy($r)->{policy_generation},8,'P03 a live reader notices restrictions without cache invalidation');
Loomy::ContentPolicy::change_policy($r,{private_results=>'off'});
is(policy($r)->{policy_generation},8,'no-op does not manufacture a generation');
is(policy($r)->{grant_prompt_version},0,'noninteractive restriction keeps first use pending');
for my $change ({private_results=>'on'},{journal_content=>'legacy-excerpts'},{label_sources=>'explicit-lead'},
    {label_sources=>'claude-description,explicit-user'}) {
    my $before=bytes($file); deny('P20 non-TTY widening refused',sub {Loomy::ContentPolicy::change_policy($r,$change)});
    is(bytes($file),$before,'failed widening leaves exact policy bytes');
}
seed($r,label_max_graphemes=>24,policy_generation=>9);
deny('increasing even a lower approved limit requires human consent',sub {Loomy::ContentPolicy::change_policy($r,{label_max_graphemes=>25})});
Loomy::ContentPolicy::change_policy($r,{label_max_graphemes=>23});
is(policy($r)->{policy_generation},10,'lower positive limits are restrictive');
my $lock="$r/.loomy/logs/content-policy.lock";
is((stat($file))[2]&0777,0600,'new policy is private');
is((stat($lock))[2]&0777,0600,'new lock is private');
{
    my ($reader,$writer,$ready,$go); pipe $reader,$ready or die $!; pipe $go,$writer or die $!;
    my $pid=fork(); die $! unless defined $pid;
    if (!$pid) {
        close $reader; close $writer; my $gen=policy($r)->{policy_generation}; syswrite $ready,"$gen\n";
        scalar <$go>; my $new=policy($r)->{policy_generation}; syswrite $ready,"$new\n"; POSIX::_exit(0);
    }
    close $ready; close $go; chomp(my $old=<$reader>);
    Loomy::ContentPolicy::change_policy($r,{results_max_records=>199}); syswrite $writer,"go\n";
    chomp(my $new=<$reader>); waitpid($pid,0);
    is($new,$old+1,'P03 already-running reader sees the committed generation');
}
{
    my $a=project('atomic-preflight'); seed($a,policy_generation=>20);
    my $read_stat=\&Loomy::ContentPolicy::_private_stat; my $swapped=0;
    no warnings 'redefine';
    local *Loomy::ContentPolicy::_private_stat=sub {
        my $s=$read_stat->(@_);
        if ($_[0] eq 'content-policy.conf' && !$swapped++) {
            put("$a/.loomy/logs/replacement",conf(policy_generation=>21,results_max_records=>199));
            rename "$a/.loomy/logs/replacement","$a/.loomy/logs/content-policy.conf" or die $!;
        }
        return $s;
    };
    is(policy($a)->{policy_generation},21,'reader retries an actual atomic inode replacement during preflight');
}
{
    my $a=project('policy-concurrency'); seed($a); my @children; my @keys=sort keys %max;
    for my $k (@keys) {my $pid=fork(); die $! unless defined $pid;
        if (!$pid) {eval {Loomy::ContentPolicy::change_policy($a,{$k=>1})}; my $err=$@; warn $err if $err; POSIX::_exit($err?1:0)} push @children,$pid}
    my $status=0; for (@children) {waitpid($_,0); $status|=$?}
    is($status,0,'concurrent restrictive transactions finish');
    is(policy($a)->{policy_generation},scalar(@keys),'concurrent generations are monotonic without lost updates');
    is_deeply([map {0+policy($a)->{$_}} @keys],[(1)x@keys],'all eight independent restrictions survive');
}

# P16 filesystem objects, including the policy file, its lock and runtime dirs.
deny('P16 device cannot be a content file',sub {Loomy::ContentPolicy::_private_stat('/dev/null')});
for my $object (qw(symlink hardlink fifo directory public-mode)) {
    my $a=project("unsafe-$object"); my $path="$a/.loomy/logs/content-policy.conf"; my $outside="$work/outside-$object";
    put($outside,conf(journal_content=>'legacy-excerpts',policy_generation=>20)); my $before=bytes($outside);
    if ($object eq 'symlink') {symlink $outside,$path or die $!}
    elsif ($object eq 'hardlink') {link $outside,$path or die $!}
    elsif ($object eq 'fifo') {require POSIX; POSIX::mkfifo($path,0600) or die $!}
    elsif ($object eq 'directory') {mkdir $path or die $!}
    else {put($path,conf(journal_content=>'legacy-excerpts')); chmod 0644,$path}
    is(policy($a)->{journal_content},'structural',"P16 $object cannot authorize content");
    deny("P16 $object cannot be replaced by a policy save",sub {Loomy::ContentPolicy::change_policy($a,{private_results=>'off'})});
    is(bytes($outside),$before,"P16 $object leaves outside bytes intact");
}
for my $part (qw(logs lock)) {
    my $a=project("unsafe-$part"); my $outside=project("outside-$part");
    if ($part eq 'logs') {rmdir "$a/.loomy/logs"; symlink "$outside/.loomy/logs","$a/.loomy/logs" or die $!}
    else {put("$outside/lock",''); symlink "$outside/lock","$a/.loomy/logs/content-policy.lock" or die $!}
    deny("P16 rejects symlinked $part",sub {Loomy::ContentPolicy::change_policy($a,{results_max_records=>199})});
    ok(!-e "$outside/.loomy/logs/content-policy.conf","no write through $part link");
}
for my $part ('.loomy','.loomy/logs') {
    my @modes=$part eq '.loomy' ? (0777) : (0775,0777);
    for my $mode (@modes) {
        my $a=project("unsafe-dir-$mode-".($part eq '.loomy' ? 'loomy' : 'logs'));
        chmod $mode,"$a/$part" or die $!;
        is(policy($a)->{source},'invalid',"P16 $part mode $mode is refused");
        my $saved=eval {Loomy::ContentPolicy::change_policy($a,{private_results=>'off'}); 1};
        ok(!$saved,'unsafe directory cannot create policy');
        is($@,"unsafe directory: $a/$part (group/world writable)\n",'unsafe mode names its directory, not the policy file');
        ok(!-e "$a/.loomy/logs/content-policy.lock",'unsafe directory receives no lock');
        chmod 0700,"$a/$part" or die $!;
    }
}
{
    my $a="$work/umask-002"; make_path($a);
    system('git','-C',$a,'init','-q','-b','main')==0 or die 'umask fixture git init';
    my $mask=umask 0002; mkdir "$a/.loomy" or die $!; umask $mask; primary_group("$a/.loomy");
    is((stat("$a/.loomy"))[2]&0777,0775,'mkdir .loomy under umask 002 produces expected 0775 mode');
    # Group write is accepted only for the user's private group (Linux user-private groups). Simulate that
    # group on any host, then check the real one: a shared group such as macOS staff is refused by name.
    my $user=(getpwuid($<))[0];
    {
        no warnings 'redefine';
        local *Loomy::ContentPolicy::_group_info=sub {($user,'')};
        is(policy($a)->{valid},1,'P16 user-owned group-writable .loomy with a private group has a valid policy');
        my $ctx=Loomy::ContentPolicy::_context($a,1);
        is((stat("$a/.loomy/logs"))[2]&0777,0700,'logs stay private under umask 002');
        seed($a,label_sources=>'claude-description');
        my $ref=label($a,'umask label');
        is(Loomy::ContentPolicy::resolve_label($a,$ref)->{text},'umask label','label storage works with a private-group group-writable .loomy');
        local *Loomy::ContentPolicy::_group_info=sub {('staff','')};
        ok(!eval {Loomy::ContentPolicy::_assert_context($ctx); 1} && $@ =~ /\Aunsafe directory: .*\.loomy \(group\/world writable\)\n\z/,
            'a shared group makes the same directory unsafe');
        ok(!eval {Loomy::ContentPolicy::_context($a,0); 1} && $@ =~ /\Aunsafe directory: /,'shared group: the context is refused with the named directory');
    }
    my $real_private=Loomy::ContentPolicy::_private_group((stat("$a/.loomy"))[5]);
    is(eval {Loomy::ContentPolicy::_context($a,0); 1} ? 1 : 0,$real_private ? 1 : 0,'real group: accepted only when it is the private group');
}
{
    my $a="$work/default-noop"; make_path("$a/.loomy",{mode=>0700});
    Loomy::ContentPolicy::change_policy($a,{label_sources=>'none'});
    ok(!-e "$a/.loomy/logs",'labels off with defaults creates no directory, lock or policy');
}
for my $id ('.','..','_name','-name',':name') {
    ok(!Loomy::ContentPolicy::_id($id),'ID must begin with an alphanumeric character');
}
{
    my $a=project('swapped'); seed($a,label_sources=>'claude-description');
    my $c=Loomy::ContentPolicy::_context($a,0);
    rename "$a/.loomy/logs","$a/.loomy/old" or die $!; make_path("$a/.loomy/logs",{mode=>0700});
    deny('P16 pinned descriptor refuses ancestor replacement',sub {
        Loomy::ContentPolicy::_in_context($c,sub {Loomy::ContentPolicy::_atomic($c,'new','safe',[])})
    });
    ok(!-e "$a/.loomy/logs/new" && !-e "$a/.loomy/old/new",'race-swapped ancestor receives no bytes');
}
{
    my $a=project('swapped-target'); seed($a,label_sources=>'claude-description');
    my $c=Loomy::ContentPolicy::_context($a,0); my $outside="$work/swap-outside"; put($outside,'untouched');
    Loomy::ContentPolicy::_in_context($c,sub {
        my (undef,$before)=Loomy::ContentPolicy::_read('content-policy.conf',16384);
        unlink 'content-policy.conf'; symlink $outside,'content-policy.conf' or die $!;
        deny('P16 replaced destination is not followed or clobbered',sub {Loomy::ContentPolicy::_atomic($c,'content-policy.conf','no',$before)});
    }); is(bytes($outside),'untouched','destination swap preserves outside bytes');
}

# P23 longest whole-grapheme prefix; byte and grapheme units differ deliberately.
{
    my $owner=project('registered-owner');
    system('git','-C',$owner,'init','-q','-b','main')==0 or die 'fixture init';
    system('git','-C',$owner,'-c','user.name=test','-c','user.email=test@example.com','commit','-q','--allow-empty','-m','fixture')==0 or die 'fixture commit';
    my $wt="$work/registered-worktree";
    system('git','-C',$owner,'worktree','add','-q','-b','shared',$wt)==0 or die 'fixture worktree';
    symlink "$owner/.loomy","$wt/.loomy" or die $!;
    seed($owner,label_sources=>'claude-description',policy_generation=>12);
    is(policy($wt)->{project_id},policy($owner)->{project_id},'registered worktrees share exact project identity');
    is(policy($wt)->{policy_generation},12,'registered worktree reads shared policy generation');
    Loomy::ContentPolicy::change_policy($wt,{label_sources=>'none'});
    is(policy($owner)->{policy_generation},13,'shared restriction is visible at the registered root');
    unlink "$wt/.loomy" or die $!; mkdir "$wt/.loomy",0700 or die $!;
    symlink "$owner/.loomy/logs","$wt/.loomy/logs" or die $!;
    is(policy($wt)->{project_id},policy($owner)->{project_id},'tracked .loomy layout shares identity through logs link');
    is(policy($wt)->{policy_generation},13,'logs link reads owner generation');
    chmod 0775,"$wt/.loomy" or die $!; primary_group("$wt/.loomy");
    {
        no warnings 'redefine'; my $user=(getpwuid($<))[0];
        local *Loomy::ContentPolicy::_group_info=sub {($user,'')};
        is(policy($wt)->{source},'project','logs link accepts a group-writable worktree .loomy parent of the private group');
    }
    chmod 0700,"$wt/.loomy" or die $!;
    Loomy::ContentPolicy::change_policy($wt,{results_max_records=>199});
    is(policy($owner)->{policy_generation},14,'logs link commits restrictions in owner policy');
    my $unregistered="$work/unregistered-link"; mkdir $unregistered or die $!;
    symlink "$owner/.loomy","$unregistered/.loomy" or die $!;
    local $ENV{GIT_DIR}="$owner/.git"; local $ENV{GIT_COMMON_DIR}="$owner/.git";
    is(policy($unregistered)->{source},'invalid','forged Git environment cannot register a foreign policy link');
}
for my $length (95,96,97,199,200,201) {
    is(Loomy::ContentPolicy::sanitize_label('a'x$length,96,384),'a'x($length<96?$length:96),"description length $length truncates");
}
my $comb="e\x{301}";
is(Loomy::ContentPolicy::sanitize_label($comb x 97,96,384),$comb x 96,'combining sequences count as one grapheme');
my $emoji="\x{1f469}\x{1f3fd}";
is(Loomy::ContentPolicy::sanitize_label($emoji x 60,96,384),$emoji x 48,'emoji modifier cluster excluded whole at byte cap');
is(Loomy::ContentPolicy::sanitize_label("A\x{ad}\x{200b}\x{200c}\x{200d}\x{2060}\x{2064}\x{feff}\x{e0001}\x{e007f}B",96,384),'AB','all format controls and tag characters stripped');
for my $bytes (383,384,385) {
    my $text="\x{1f600}"x96;
    is(length(encode('UTF-8',Loomy::ContentPolicy::sanitize_label($text,96,$bytes))),4*int($bytes/4),"$bytes-byte cap is grapheme-safe");
}
is(Loomy::ContentPolicy::sanitize_label("\e[31mA\e[0m\e]0;SECRET\aB\x{202e}\nC\tD\0",96,384),'AB C D','ANSI/OSC, controls and bidi removed; one line');
deny('empty after controls is unavailable',sub {Loomy::ContentPolicy::sanitize_label("\e[0m\x{202e}\0",96,384)});
deny('malformed UTF-8 is unavailable',sub {Loomy::ContentPolicy::sanitize_label("\xff",96,384)});
is(Loomy::ContentPolicy::sanitize_label("A\ePPRIVATE\e\\B\e]8;;PRIVATE\e\\C\e]8;;\e\\",96,384),'ABC','complete DCS and OSC hyperlink payloads removed');
for my $tail ("é",$comb,"\x{1f600}") {
    my $prefix="\x{1f600}"x94 . "a\x{301}\x{302}";
    my $input=$prefix.$tail; my $size=length(encode('UTF-8',$input));
    is(Loomy::ContentPolicy::sanitize_label($input,96,384),$size<=384 ? $input : $prefix,"$size-byte input at the actual 384-byte cap");
}
my $s=project('store'); seed($s,label_sources=>Loomy::ContentPolicy::recommended_sources());
for my $case (['a'x95 . ' ' . 'b'x50,'a'x95], [$emoji x47 . ' 'x8 . 'x',$emoji x47]) {
    my ($text,$expected)=@$case;
    my $ref=label($s,$text);
    is(Loomy::ContentPolicy::resolve_label($s,$ref)->{text},$expected,'truncation at 96 graphemes/384 bytes trims trailing spaces and resolves');
    my $next=label($s,'still writable');
    is(Loomy::ContentPolicy::resolve_label($s,$next)->{text},'still writable','space truncation never bricks later writes');
}
my $ref=label($s,$comb x 97);
is(Loomy::ContentPolicy::resolve_label($s,$ref)->{text},$comb x 96,'stored multibyte label resolves after fresh read');
is((stat("$s/.loomy/logs/display-context-v1.jsonl"))[2]&0777,0600,'label store 0600 from creation');
is(label($s,'second')->{attempt_id},'attempt1','scoped reference records attempt');
is(Loomy::ContentPolicy::resolve_label($s,$ref)->{text},$comb x 96,'old reference remains durable after relabel');
ok(!Loomy::ContentPolicy::resolve_label($s,{%$ref,attempt_id=>'wrong'}),'wrong attempt never resolves');
ok(!Loomy::ContentPolicy::resolve_label($s,{%$ref,target_id=>'wrong'}),'wrong target never resolves');
ok(!Loomy::ContentPolicy::resolve_label($r,$ref),'wrong project never resolves');
deny('wrong project capture refused',sub {label($s,'bad',project_id=>policy($r)->{project_id})});
for my $source (qw(codex-path-slug codex-nickname codex-role)) {
    my $good=label($s,'A'x40,source=>$source);
    is(Loomy::ContentPolicy::resolve_label($s,$good)->{text},'A'x40,"$source accepts 40 ASCII chars");
    for my $bad ('A'x41,"bad\nvalue",'é','raw/prompt',"\e[31mred",' nick','nick ',' nick ') {
        deny("$source rejects invalid component",sub {label($s,$bad,source=>$source)});
    }
}
my $sf="$s/.loomy/logs/display-context-v1.jsonl"; my $before=bytes($sf);
{
    my $a=project('invalid-rows'); seed($a,label_sources=>'claude-description');
    my $old=label($a,'valid before'); my $store="$a/.loomy/logs/display-context-v1.jsonl";
    my $row=$json->decode(bytes($store)); $row->{text}='trailing '; $row->{label_id}='invalid1';
    put($store,bytes($store).$json->encode($row)."\nnot json\n[]\n".('x'x4097)."\n{partial");
    is(Loomy::ContentPolicy::resolve_label($a,$old)->{text},'valid before','invalid/schema/oversized/partial rows skip without hiding a valid label');
    my $new=label($a,'valid after');
    is(Loomy::ContentPolicy::resolve_label($a,$new)->{text},'valid after','append after invalid partial row remains resolvable');
    is(Loomy::ContentPolicy::resolve_label($a,$old)->{text},'valid before','append preserves earlier valid reference');
}
{
    my $a=project('bounded-lock'); seed($a,label_sources=>'claude-description');
    my ($read,$write); pipe $read,$write or die $!; my ($release,$go); pipe $release,$go or die $!;
    my $pid=fork(); die $! unless defined $pid;
    if (!$pid) {
        close $read; close $go;
        Loomy::ContentPolicy::with_policy($a,sub {syswrite $write,"ready\n"; scalar <$release>});
        POSIX::_exit(0);
    }
    close $write; close $release; scalar <$read>;
    my $start=time; deny('automatic label writer refuses a busy lock',sub {label($a,'blocked')});
    cmp_ok(time-$start,'<',2.5,'automatic lock retry is bounded');
    my $called=0; $start=time;
    deny('T2 with_policy helper refuses a busy lock',sub {Loomy::ContentPolicy::with_policy($a,sub {$called++})});
    cmp_ok(time-$start,'<',2.5,'T2 helper lock retry is bounded'); is($called,0,'busy helper never calls writer');
    syswrite $go,"done\n"; waitpid($pid,0);
    my $ref=label($a,'recovered'); ok(Loomy::ContentPolicy::resolve_label($a,$ref),'writer recovers after lock release');
}
deny('ungranted source name never attests consent',sub {label($r,'denied',source=>'codex-path-slug')});
deny('managed explicit-user capture refused despite existing source grant',sub {label($s,'denied',source=>'explicit-user')});
is(bytes($sf),$before,'failed captures preserve store bytes');
my $last=label($s,'known label'); my $size=-s $sf;
seed($s,label_sources=>'claude-description',label_store_max_bytes=>$size);
deny('failed relabel returns a visible full failure',sub {label($s,'replacement')});
is(Loomy::ContentPolicy::label_health($s),'full','full fact persists independently of the caller');
is(Loomy::ContentPolicy::resolve_label($s,$last)->{text},'known label','failed relabel preserves prior label');
is(-s $sf,$size,'overflow does not append a partial record');
# Record byte size is deterministic (ID and timestamp have fixed widths).
for my $delta (-1,0,1) {
    my $a=project("cliff$delta"); seed($a,label_sources=>'claude-description');
    label($a,'界'); my $one=-s "$a/.loomy/logs/display-context-v1.jsonl";
    unlink "$a/.loomy/logs/display-context-v1.jsonl";
    seed($a,label_sources=>'claude-description',label_store_max_bytes=>$one+$delta);
    my $ok=eval {label($a,'界'); 1}; is($ok?1:0,$delta>=0?1:0,"P10 cap $delta bytes around a multibyte record");
    ok((-s "$a/.loomy/logs/display-context-v1.jsonl"//0)<=$one+$delta,'cap never crossed');
}
# Exercise the real 1 MiB cliff with valid records and exact on-disk lengths.
my $hard=project('hard-cap'); seed($hard,label_sources=>'claude-description');
label($hard,'界'); my $line=bytes("$hard/.loomy/logs/display-context-v1.jsonl");
my $row=$json->decode($line); my $base=$json->encode({%$row,text=>'a'})."\n";
my $final=$json->encode({%$row,supersedes=>$row->{label_id}})."\n";
my $n=int((1048576-length($final))/length($base));
my $padding=1048576-length($final)-$n*length($base);
# Split the padding across valid texts rather than inserting whitespace/invalid rows.
my $raw=''; for (1..$n) {my $add=$padding>95?95:$padding; $padding-=$add;
    $raw.=$json->encode({%$row,label_id=>'l'.sprintf('%032x',$_),text=>'a'x(1+$add)})."\n"}
is($padding,0,'hard-cap padding fits the bounded record schema');
put("$hard/.loomy/logs/display-context-v1.jsonl",$raw);
label($hard,'界'); is(-s "$hard/.loomy/logs/display-context-v1.jsonl",1048576,'1 MiB exactly is accepted');
deny('1 MiB + next record rejected before append',sub {label($hard,'界')});
is(-s "$hard/.loomy/logs/display-context-v1.jsonl",1048576,'hard cap preserved after restart/rejection');
my $con=project('concurrent'); seed($con,label_sources=>'claude-description'); my @pids;
for my $i (1..8) {my $pid=fork(); die $! unless defined $pid;
    if (!$pid) {eval {label($con,"label$i",target_id=>"agent$i")}; POSIX::_exit($@ ? 1 : 0)} push @pids,$pid}
my $status=0; for (@pids) {waitpid($_,0); $status|=$?} is($status,0,'eight concurrent appends finish');
my @rows=split /\n/,bytes("$con/.loomy/logs/display-context-v1.jsonl"); is(scalar @rows,8,'concurrent appends lose no complete record');
my %ids=map {$json->decode($_)->{target_id}=>1} @rows; is(scalar keys %ids,8,'concurrent scoped identities survive');

# Stable namespace migration: both normal moves and pre-upgrade moved labels.
for my $pre_move (0,1) {
    my $a=project("stable-$pre_move"); seed($a,label_sources=>'claude-description');
    my $ref=label($a,'Durable label'); my $id=policy($a)->{project_id};
    unlink "$a/.loomy/project-id" if $pre_move; # simulate old path-hash deployment
    my $moved="$a-renamed"; rename $a,$moved or die;
    is(policy($moved)->{project_id},$id,'project identity survives rename including existing legacy refs');
    ok(!-e "$moved/.loomy/project-id",'a reader never stores the identity') if $pre_move;
    is(Loomy::ContentPolicy::resolve_label($moved,$ref)->{text},'Durable label','legacy label reference resolves after moving');
    my $again=label($moved,'New title');
    is($again->{project_id},$id,'new writes use the migrated namespace');
    is((stat("$moved/.loomy/project-id"))[2]&0777,0600,'persistent project identity is private');
}
# Writer branch of the identity pin: only where Git cannot show project-id as an untracked file.
{
    sub pinned_in {
        my ($name,$ignore,%o)=@_; my $r="$work/pin-$name"; make_path($r);
        my $top=$o{parent} ? $r : $r; my $proj=$o{sub} ? "$r/sub" : $r;
        system('git','-C',$r,'init','-q','-b','main')==0 or die 'pin git init' unless $o{nogit};
        make_path("$proj/.loomy/logs",{mode=>0700}); chmod 0755,"$proj/.loomy";
        if (defined $ignore) {open my $f,'>',"$proj/.gitignore" or die; print $f $ignore; close $f}
        if (defined $o{parent_ignore}) {open my $f,'>',"$r/.gitignore" or die; print $f $o{parent_ignore}; close $f}
        if (defined $o{exclude}) {open my $f,'>>',"$r/.git/info/exclude" or die; print $f $o{exclude}; close $f}
        if ($o{loomy_gitignore}) {open my $f,'>',"$proj/.loomy/.gitignore" or die; print $f "!project-id\n"; close $f}
        Loomy::ContentPolicy::_context($proj,1);
        return -e "$proj/.loomy/project-id" ? 1 : 0;
    }
    is(pinned_in('outside',undef,nogit=>1),1,'identity pinned outside any Git work tree');
    is(pinned_in('ignored',"/.loomy/\n"),1,'identity pinned when .gitignore ignores .loomy');
    is(pinned_in('ignored-file',".loomy/project-id\n"),1,'identity pinned when .gitignore ignores project-id');
    is(pinned_in('not-ignored',"node_modules/\n"),0,'identity not pinned when Git does not ignore it');
    is(pinned_in('no-gitignore',undef),0,'identity not pinned in Git without any .gitignore');
    is(pinned_in('empty-gitignore',''),0,'identity not pinned with a 0-byte .gitignore');
    is(pinned_in('trailing-space',".loomy  \n"),1,'trailing spaces are ignored by Git, so the identity is pinned');
    is(pinned_in('trailing-tab',".loomy\t\n"),0,'a trailing tab is part of the pattern: not pinned');
    is(pinned_in('negated',".loomy\n!.loomy/project-id\n"),0,'a later negation naming project-id prevents pinning');
    is(pinned_in('negated-dir',".loomy/\n!.loomy\n"),0,'a negation naming .loomy prevents pinning');
    is(pinned_in('loomy-gitignore',".loomy/\n",loomy_gitignore=>1),0,'a .loomy/.gitignore prevents pinning');
    is(pinned_in('exclude',undef,exclude=>"/.loomy/\n"),1,'identity pinned when info/exclude ignores .loomy');
    is(pinned_in('sub-not-ignored',undef,sub=>1),0,'subdirectory project in a parent repository without an ignore rule: not pinned');
    is(pinned_in('sub-own',"/.loomy/\n",sub=>1),1,'subdirectory project with its own .gitignore rule: pinned');
    is(pinned_in('sub-parent-anchored',undef,sub=>1,parent_ignore=>"/.loomy/\n"),0,'parent anchored rule does not cover a subdirectory project');
    is(pinned_in('sub-parent',undef,sub=>1,parent_ignore=>".loomy/\n"),1,'parent unanchored rule covers a subdirectory project');
    is(pinned_in('sub-parent-path',undef,sub=>1,parent_ignore=>"/sub/.loomy/\n"),1,'parent rule naming the subdirectory covers it');
    is(pinned_in('sub-exclude',undef,sub=>1,exclude=>".loomy\n"),1,'parent info/exclude covers a subdirectory project');
}
# Pin decisions must never claim more than `git check-ignore`: pinned implies Git ignores the identity file.
{
    sub git_ignores {my ($dir)=@_; return system('git','-C',$dir,'check-ignore','-q','--','.loomy/project-id')==0 ? 1 : 0}
    sub put_file {my ($p,$c)=@_; my ($d)=$p =~ m{\A(.*)/}; make_path($d); open my $f,'>',$p or die "$p: $!"; print $f $c; close $f}
    sub pin_case {
        my ($name,$expect,%o)=@_; my $r="$work/pin2-$name"; make_path($r);
        my $proj=$r.(length($o{sub}//'') ? "/$o{sub}" : '');
        system('git','-C',$r,'init','-q','-b','main')==0 or die 'pin2 git init';
        make_path("$proj/.loomy/logs",{mode=>0700}); chmod 0755,"$proj/.loomy";
        put_file("$r/$_",$o{files}{$_}) for keys %{$o{files}//{}};
        put_file("$r/.git/info/exclude",$o{exclude}) if defined $o{exclude};
        Loomy::ContentPolicy::_context($proj,1);
        my $pinned=-e "$proj/.loomy/project-id" ? 1 : 0;
        is($pinned,$expect,"pin2 $name: pinned=$expect");
        ok(!$pinned || git_ignores($proj),"pin2 $name: pinned only when git check-ignore agrees");
        return $pinned;
    }
    pin_case('plain',1,files=>{'.gitignore'=>".loomy\n"});
    pin_case('glob-neg-star',0,files=>{'.gitignore'=>".loomy\n!*\n"});
    pin_case('glob-neg-dot',0,files=>{'.gitignore'=>".loomy\n!.l*\n"});
    pin_case('glob-neg-slash',0,files=>{'.gitignore'=>".loomy\n!/.*\n"});
    pin_case('neg-in-exclude',0,files=>{'.gitignore'=>".loomy\n"},exclude=>"!x\n");
    pin_case('intermediate',0,sub=>'a/b',files=>{'.gitignore'=>".loomy\n",'a/.gitignore'=>"!.loomy\n"});
    pin_case('intermediate-harmless',0,sub=>'a/b',files=>{'.gitignore'=>".loomy\n",'a/.gitignore'=>"*.o\n"});
    pin_case('project-gitignore-ok',1,sub=>'a/b',files=>{'a/b/.gitignore'=>"/.loomy/\n"});
    pin_case('class-dir',0,sub=>'my[1]',files=>{'.gitignore'=>"my[1]/.loomy\n"});
    pin_case('hash-dir',0,sub=>'#c',files=>{'.gitignore'=>"#c/.loomy\n"});
    pin_case('plain-subdir-parent',1,sub=>'sub',files=>{'.gitignore'=>"/sub/.loomy/\n"});
    pin_case('class-dir-own',1,sub=>'my[1]',files=>{'my[1]/.gitignore'=>"/.loomy/\n"});
    # Registered worktree: ".git" is a file (gitdir + commondir); only the common info/exclude counts.
    {
        for my $case (['common',1],['private',0]) {
            my ($kind,$expect)=@$case; my $wt="$work/pin2-wt-$kind";
            my $main="$work/pin2-wt-main-$kind"; make_path($main);
            my @g=('git','-C',$main,'-c','user.name=t','-c','user.email=t@example.com');
            system(@g,'init','-q','-b','main')==0 or die; put_file("$main/f","x\n");
            system(@g,'add','f')==0 && system(@g,'commit','-q','-m','i')==0 or die;
            system(@g,'worktree','add','-q','-b',"wt-$kind",$wt)==0 or die;
            my $gitdir=(`git -C "$wt" rev-parse --git-dir`)[0]; chomp $gitdir;
            my $ex=$kind eq 'common' ? "$main/.git/info/exclude" : "$gitdir/info/exclude"; make_path($ex =~ m{\A(.*)/} ? $1 : '.');
            open my $f,'>>',$ex or die; print $f "/.loomy/\n"; close $f;
            make_path("$wt/.loomy/logs",{mode=>0700}); chmod 0755,"$wt/.loomy";
            Loomy::ContentPolicy::_context($wt,1); my $pinned=-e "$wt/.loomy/project-id" ? 1 : 0;
            is($pinned,git_ignores($wt),"pin2 worktree $kind exclude: decision agrees with git check-ignore");
            ok(!$pinned || git_ignores($wt),"pin2 worktree $kind: never pinned when git does not ignore it");
            is($pinned,$expect,"pin2 worktree $kind exclude: pinned=$expect");
        }
    }
    # Submodule: ".git" file without commondir (gitdir: ../.git/modules/x).
    {
        my $sup="$work/pin2-sub-super"; my $inner="$work/pin2-sub-inner"; make_path($sup,$inner);
        for my $r ($sup,$inner) {
            my @g=('git','-C',$r,'-c','user.name=t','-c','user.email=t@example.com');
            system(@g,'init','-q','-b','main')==0 or die; put_file("$r/f","x\n");
            system(@g,'add','f')==0 && system(@g,'commit','-q','-m','i')==0 or die;
        }
        if (system('git','-C',$sup,'-c','protocol.file.allow=always','-c','user.name=t','-c','user.email=t@example.com','submodule','add','-q',$inner,'x')==0) {
            my $sm="$sup/x"; my ($gd)=`git -C "$sm" rev-parse --git-dir`; chomp $gd;
            make_path("$gd/info"); open my $f,'>>',"$gd/info/exclude" or die; print $f "/.loomy/\n"; close $f;
            make_path("$sm/.loomy/logs",{mode=>0700}); chmod 0755,"$sm/.loomy";
            Loomy::ContentPolicy::_context($sm,1); my $pinned=-e "$sm/.loomy/project-id" ? 1 : 0;
            is($pinned,git_ignores($sm),'pin2 submodule: decision agrees with git check-ignore');
            is($pinned,1,'pin2 submodule: its own info/exclude is read');
        } else {ok(1,'pin2 submodule: skipped (git cannot add a local submodule here)'); ok(1,'pin2 submodule: skipped')}
    }
}
# _private_group also needs the user's primary gid: gr_mem omits accounts that only have it as primary group.
{
    no warnings 'redefine';
    my @pw=getpwuid($<);
    local *Loomy::ContentPolicy::_group_info=sub {($pw[0],'')};
    is(Loomy::ContentPolicy::_private_group($pw[3]),1,'private group: name and primary gid match');
    is(Loomy::ContentPolicy::_private_group($pw[3]+4242),0,'a group of the right name whose gid is not the primary gid is refused');
}
for my $kind (qw(symlink hardlink mode)) {
    my $a=project("identity-$kind"); my $target="$work/identity-target-$kind";
    put($target,'p'.('a'x64)."\n");
    if ($kind eq 'symlink') {symlink $target,"$a/.loomy/project-id" or die}
    elsif ($kind eq 'hardlink') {link $target,"$a/.loomy/project-id" or die}
    else {put("$a/.loomy/project-id",bytes($target)); chmod 0644,"$a/.loomy/project-id" or die}
    ok(!policy($a)->{valid},"unsafe $kind project identity fails closed");
    is(bytes($target),'p'.('a'x64)."\n",'foreign identity bytes untouched');
    is((stat($target))[2]&0777,0600,'foreign identity permissions untouched');
}
for my $type (qw(delegation_start delegation agent_link)) {
    my $p=policy($s);
    for my $value ('Explore','Plan','general-purpose','loomy-developer','a'x40) {
        is(Loomy::ContentPolicy::project_with_policy($p,{type=>$type,agent_type=>$value})->{agent_type},$value,'Claude configuration token retained');
    }
    for my $bad ('a'x41,'private role prose','../agent',"Explore\n",'日本語') {
        is(Loomy::ContentPolicy::project_with_policy($p,{type=>$type,agent_type=>$bad})->{agent_type},'unknown','invalid Claude configuration token neutralized');
    }
}

# P19 public manifest and four mutations go through precisely the runtime loader.
my $manifest="$repo/scripts/lib/content-allowlist.tsv";
my $allow=Loomy::ContentPolicy::check_allowlist($manifest);
is(scalar(grep {!m{/}} keys %$allow),23,'23 producer event types');
for my $k (qw(multi_agent_version cost_in cost_usd)) {ok((grep {($allow->{$_}{$k}//'') eq 'keep'} keys %$allow),"retains $k")}
my $original=bytes($manifest);
my @mutations=($original."usage\tunknown_key\tkeep\n",$original,$original,$original."novel_type\tid\tkeep\n");
$mutations[1]=~s/usage\tcost_usd\tkeep\n//; $mutations[2]=~s/request\texcerpt\tomit/request\texcerpt\tkeep/;
for my $i (0..3) {my $path="$work/mutation$i.tsv"; put($path,$mutations[$i]);
    deny("allowlist mutation $i fails the real drift comparison",sub {Loomy::ContentPolicy::check_allowlist($path)})}
my $p=policy($r); my $event={type=>'delegation',ts=>'2026-10-26T12:00:00Z',id=>'d179297280012345',role=>'developer',model=>'gpt-6.2-sol',
    status=>'paused',outcome=>'partial',multi_agent_version=>'v2',cost_in=>'usage',cost_usd=>0,tokens_in=>12,duration_s=>undef,
    task=>'TASK_CANARY',why=>'WHY_CANARY',changed_files=>['PATH_CANARY'],unknown=>{task=>'NESTED_CANARY'},summary=>'RESULT_CANARY'};
my $out=Loomy::ContentPolicy::project_with_policy($p,$event);
ok($json->encode($out)!~/CANARY/,'projector omits unknown/content objects recursively');
is($out->{cost_in},'usage','accounting attribution retained'); is($out->{cost_usd},0,'known zero cost retained');
ok(exists($out->{duration_s}) && !defined($out->{duration_s}),'null stays unknown');
is($out->{multi_agent_version},'v2','v2 protocol retained'); is($out->{status},'paused','paused retained');
is($out->{policy_generation},$p->{policy_generation},'projector supplies actual policy generation');
is($out->{content_policy},'structural-v1','default structural envelope');
is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation',status=>'handed_over'})->{status},'handed_over','handed_over retained');
# Producer domains: local-writer.sh's model token grammar, usage.sh's pause,
# models.sh's result/role contract, native metadata/lifecycle, and skills.sh.
for my $model ('user/local-model','user/model','provider/nested/model:tag','m'x128) {
    for my $field (qw(model requested_model)) {
        is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',$field=>$model})->{$field},$model,"bounded $field with provider/local prefix retained");
    }
}
for my $bad ('m'x129,'provider/model with prose',"provider/model\n",'provider/model;echo','/absolute/path',"provider/\x{e9}") {
    ok(!defined(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',model=>$bad})->{model}),'invalid model becomes null');
}
for my $case (
    ['delegation','cost_source','reported'], # claude bridge: reported vs estimate
    ['delegation','outcome','waiting_for_reset'], # usage.sh pause
    ['delegation','outcome','unformatted'], # models.sh ai_result_json
    ['session_observed','state','failed'], # native task_failed
    ['session_observed','surface','exec'], # codex-native metadata
    ['delegation_activity','activity','waiting'], # native wait/wait_agent
    ['delegation_start','evidence','rollout'], # Codex native emit default
    (map {['skill','event',$_]} qw(added restored removed)),
    (map {['skill','source',$_]} qw(anthropic openai)),
    (map {['audit_phase','phase',$_]} qw(scope analyze validate fix)),
    ['delegation_start','role','debugger']
) {
    my ($type,$key,$value)=@$case;
    is(Loomy::ContentPolicy::project_with_policy($p,{type=>$type,$key=>$value})->{$key},$value,"producer domain $key=$value retained");
    is(Loomy::ContentPolicy::project_with_policy($p,{type=>$type,$key=>'PRIVATE prose'})->{$key},'unknown',"$key remains a closed enum");
}
# Providers/efforts need no widening; cover the domains already used by launch,
# routing overrides and native turn_context alongside the repaired domains.
for my $provider (qw(claude codex local)) {
    is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',family=>$provider})->{family},$provider,'supported provider retained');
}
for my $effort (qw(none minimal low medium high xhigh max)) {
    is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',effort=>$effort})->{effort},$effort,'supported effort retained');
}
my $part='a'x100;
for my $case (['id',"cl:$part:$part"],['id',"cn:$part:$part"],['agent_id',"$part:$part"],
    ['alias_from',"$part:$part"],['alias_id',"cl:$part:$part"],['session_key',"claude:$part"],
    ['session_key',"codex:pending:$part"],['parent_agent_id',"codex:$part"],['session',"pending:$part"]) {
    my ($key,$value)=@$case;
    is(Loomy::ContentPolicy::project_with_policy($p,{type=>'agent_alias',$key=>$value})->{$key},$value,'composite of bounded native IDs retained');
}
for my $bad ('a'x101,'cl:'.('a'x101).':'.('b'x100),'cl:private prose:id','cl:../path:id') {
    ok(!defined(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',id=>$bad})->{id}),'invalid composite identity becomes null');
}
for my $type (grep {!m{/}} keys %$allow) {
    is(Loomy::ContentPolicy::project_with_policy($p,{type=>$type,task=>'CANARY',extension=>{raw=>'CANARY'}})->{type},$type,"per-type $type projection");
}
for my $bad ({type=>'surprise'},{type=>'delegation',id=>'../../secret'}, {type=>'delegation',cost_usd=>-1},
    {type=>'delegation',tokens_in=>'NaN'},{type=>'delegation',duration_s=>'Infinity'},
    {type=>'delegation',model=>'model with prompt'},{type=>'delegation_start',requested=>'true'},
    {type=>'session',snapshot=>1},{type=>'delegation',model=>{prompt=>'CANARY'}},{type=>'delegation',multi_agent_version=>'v3'},
    {type=>'delegation',ts=>'2026-02-31T99:00:00Z'}, {type=>'delegation',off_routing=>'private prose'}) {
    if ($bad->{type} eq 'surprise') {deny('unknown structural type fails closed',sub {Loomy::ContentPolicy::project_with_policy($p,$bad)})}
    else {my ($key)=grep {$_ ne 'type'} keys %$bad; my $out=Loomy::ContentPolicy::project_with_policy($p,$bad); ok(exists($out->{$key}) && !defined($out->{$key}),'invalid structural value becomes null without killing the event')}

}
is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation',role=>'custom private remit'})->{role},'unknown','custom roles never persist prose');
{
    # bridge values reproduced by content-census.py shell/hooks/native fixtures.
    for my $bridge (qw(claude codex claude-native codex-native subagent)) {
        is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',bridge=>$bridge})->{bridge},$bridge,"census bridge $bridge survives");
    }
    my $usage={type=>'usage',ts=>'2026-10-26T12:00:00Z',scope=>'subagent',agent=>'Explore',model=>'claude-sonnet-5-5',cost_usd=>0.25};
    my $u=Loomy::ContentPolicy::project_with_policy($p,$usage);
    is($u->{agent},'Explore','native agent_type is a bounded identity, not a role enum');
    is(Loomy::ContentPolicy::project_with_policy($p,{%$usage,agent=>'reviewer'})->{agent},'reviewer','known Loomy role identity unchanged');
    my $digest='sha256:'.('a'x64);
    is(Loomy::ContentPolicy::project_with_policy($p,{%$usage,agent=>$digest})->{agent},$digest,'opaque agent identity survives projection');
    my $custom=Loomy::ContentPolicy::project_with_policy($p,{%$usage,agent=>'custom private type'});
    like($custom->{agent},qr/^sha256:[a-f0-9]{64}$/,'invalid agent token becomes an opaque identity');
    is(Loomy::ContentPolicy::project_with_policy($p,$custom)->{agent},$custom->{agent},'agent identity projection is idempotent');
    isnt(Loomy::ContentPolicy::project_with_policy({%$p,project_id=>'p'.('f'x64)},{%$usage,agent=>'custom private type'})->{agent},$custom->{agent},'opaque custom identity is project scoped');
    require "$repo/scripts/lib/claude-native.pl";
    my $start={type=>'delegation_start',ts=>'2026-10-26T12:00:00Z',session=>'fixture-session',id=>'fixture-call',bridge=>'subagent',role=>'developer'};
    my ($old,$new)=({sessions=>{}},{sessions=>{}});
    Loomy::ClaudeNative::hook($old,$start);
    Loomy::ClaudeNative::hook($new,Loomy::ContentPolicy::project_with_policy($p,$start));
    ok(exists($old->{sessions}{'fixture-session'}{calls}{'fixture-call'}),'original census hook reaches native consumer');
    ok(exists($new->{sessions}{'fixture-session'}{calls}{'fixture-call'}),'projected hook reaches same native consumer');
    is($u->{cost_usd},0.25,'native identity repair preserves cost');
}
is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation',status=>'SECRET'})->{status},'unknown','unknown enum becomes unknown');
is(Loomy::ContentPolicy::project_with_policy($p,{type=>'delegation_start',requested=>JSON::PP::true})->{requested},JSON::PP::true,'real boolean retained');
my $sig1=Loomy::ContentPolicy::project_with_policy($p,{type=>'session_observed',checkpoint_value=>$json->encode({session=>'session1',cwd_relative=>'CANARY',content=>'CANARY'})});
my $sig2=Loomy::ContentPolicy::project_with_policy($p,{type=>'session_observed',checkpoint_value=>$json->encode({session=>'session1',cwd_relative=>'OTHER'})});
like($sig1->{checkpoint_value},qr/^sha256:[a-f0-9]{64}$/,'serialized checkpoint body becomes typed signature');
is($sig1->{checkpoint_value},$sig2->{checkpoint_value},'content cannot influence a structural signature');
my $legacy={%$p,journal_content=>'legacy-excerpts'};
my $ex=Loomy::ContentPolicy::project_with_policy($legacy,{type=>'delegation',task=>'t'x201,why=>'w'x201,changed_files=>['NEVER'],result=>'NEVER'});
is(length($ex->{task}),200,'legacy task cap'); is(length($ex->{why}),200,'legacy why cap');
ok(!exists($ex->{changed_files}) && !exists($ex->{result}),'legacy is only the five declared bounded fields');
my $path=Loomy::ContentPolicy::project_with_policy($legacy,{type=>'session_observed',cwd_relative=>'../private'});
ok(!exists($path->{cwd_relative}),'legacy path cannot escape project');
{
    local $ENV{LOOMY_JOURNAL_TASKS}=0;
    ok(!exists(Loomy::ContentPolicy::project_with_policy($legacy,{type=>'delegation',task=>'NO'})->{task}),'TASKS=0 also vetoes a stale legacy projection');
}
done_testing();
PERL
perl "$WORK/unit.pl" "$REPO" "$WORK"

# Use an empty inherited environment for simulated human terminals. Every provider
# and managed-origin marker is injected explicitly in the negative tests below.
cat >"$WORK/entry.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo="$1"; root="$2"; cmd="$3"; shift 3
# shellcheck disable=SC1091
source "$repo/scripts/lib/content-policy.sh"
case "$cmd" in
  first-use) loomy_content_first_use "$root" ;;
  first-use-ahead) printf 'READY_BEFORE_SCREEN\n'; /bin/sleep 0.2; loomy_content_first_use "$root" ;;
  acknowledged-fast) loomy_content_human_tty() { exit 91; }; loomy_content_command() { exit 92; }; loomy_content_first_use "$root" ;;
  hint) loomy_content_status_hint "$root" ;;
  privacy) bash "$repo/scripts/loomy-privacy.sh" --root "$root" "$@" ;;
  init) cd "$root"; bash "$repo/bin/loomy" init "$root" --update ;;
  watch) bash "$repo/scripts/loomy-status.sh" --root "$root" --watch "$@" ;;
  watch-pane) LOOMY_JOURNAL=0 bash "$repo/scripts/loomy-status.sh" --root "$root" --watch --pane "$@" ;;
  restrict) perl -e 'require $ARGV[0]; Loomy::ContentPolicy::change_policy($ARGV[1],{results_max_records=>199})' "$repo/scripts/lib/content-policy.pl" "$root" ;;
  *) exit 2 ;;
esac
SH
for content_lang in en fr; do
  env -i HOME="$HOME" PATH="$PATH" LOOMY_LANG="$content_lang" bash -c '
    source "$1/scripts/lib/content-policy.sh"
    _loomy_content_ui
    printf "%s\n%s\n%s\n" "$LOOMY_CONTENT_UI_KEEP_LABELS" "$LOOMY_CONTENT_UI_KEEP_RESULTS" "$LOOMY_CONTENT_UI_CONFIRM"
  ' _ "$REPO" >"$WORK/expected-$content_lang.txt"
done
for group_root_name in umask-002-first-use umask-002-privacy; do
  group_root="$WORK/$group_root_name"
  mkdir -p "$group_root"
  git -C "$group_root" init -q -b main
  (umask 002; mkdir "$group_root/.loomy")
  # A shared group (macOS staff) refuses group write: the fixture then is the safe 0755 form.
  [[ "$(id -gn)" == "$(id -un)" ]] || chmod 0755 "$group_root/.loomy"
done
if [[ "$(id -gn)" == "$(id -un)" ]]; then export LOOMY_TEST_LOOMY_MODE=509; else export LOOMY_TEST_LOOMY_MODE=493; fi
cat >"$WORK/prompt.exp" <<'TCL'
source [file join [lindex $argv 0] tests fixtures watchdog.exp]
log_user 0
set timeout 12
set repo [lindex $argv 0]; set work [lindex $argv 1]
set prompt_prefixes {}
foreach lang {en fr} {
    set f [open [file join $work expected-$lang.txt]]; fconfigure $f -encoding utf-8
    foreach field {labels results confirm} {
        gets $f prompts($lang,$field)
        lappend prompt_prefixes [lindex [regexp -inline {^[A-Za-z ]+} $prompts($lang,$field)] 0]
    }
    close $f
}
proc check {ok name} {if {![uplevel 1 [list expr $ok]]} {error $name}; puts "ok $name"}
proc root {name} {
    global work
    set r [file join $work $name]; file mkdir [file join $r .loomy]
    file attributes [file join $r .loomy] -permissions 0755   ;# whatever the umask of the run
    return $r
}
proc root_group_writable {name} {
    global work
    return [file join $work $name]
}
proc start {r lang cmd args} {
    global repo work spawn_id
    set env [list env -i HOME=$work/home XDG_CONFIG_HOME=$work/config XDG_STATE_HOME=$work/state TMPDIR=$work/tmp TMUX_TMPDIR=$work/tmux CODEX_HOME=$work/codex CLAUDE_CONFIG_DIR=$work/claude PATH=$work/human-bin:$repo/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin NO_COLOR=1 LOOMY_LANG=$lang LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_START_WATCH=0 LOOMY_HOME=$repo LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS=$repo/tests/stubs LOOMY_TEST_GUARD_LOG=$work/guard-violations.log]
    spawn {*}$env bash $work/entry.sh $repo $r $cmd {*}$args
    return $spawn_id
}
proc see {text} {
    global spawn_id
    expect -i $spawn_id -exact $text {} eof {error "missing expected prompt: $text"} timeout {error "content prompt timed out: $text"}
}
proc finish {id} {global spawn_id; set spawn_id $id; expect -i $id eof {} timeout {error "content command did not finish"}; set w [wait -i $id]; return [lindex $w 3]}
proc no_prompt {id} {
    global spawn_id prompt_prefixes; set spawn_id $id
    expect -i $id -re [join $prompt_prefixes |] {error "unexpected grant prompt"} eof {} timeout {error "content command did not finish"}
    set w [wait -i $id]; return [lindex $w 3]
}
proc policy {r} {set f [open [file join $r .loomy logs content-policy.conf]]; set data [read $f]; close $f; return $data}
proc question {lang field} {
    global spawn_id prompts
    if {$lang eq "en"} {
        see $prompts($lang,$field)
    } else {
        # macOS system Expect can SIGBUS on long accented -exact patterns. Match
        # the ASCII sentence prefix and the localized default-answer suffix.
        see [lindex [regexp -inline {^[A-Za-z ]+} $prompts($lang,$field)] 0]
        see [lindex [regexp -inline {\[[A-Za-z]/[A-Za-z]\]} $prompts($lang,$field)] 0]
    }
}
foreach lang {en fr} {
    set r [root default-$lang]; set id [start $r $lang first-use]
    question $lang labels
    check {![file exists [file join $r .loomy logs content-policy.conf]]} "config stays off before human answer $lang"
    send "\r"; question $lang results
    check {![file exists [file join $r .loomy logs content-policy.conf]]} "first answer alone commits no grant $lang"
    send "\r"; check {[finish $id]==0} "Enter defaults $lang"
    set data [policy $r]
    check {[string match {*private_results=on*} $data] && [string match {*label_sources=explicit-user,explicit-lead,claude-description,codex-path-slug,codex-nickname,codex-role*} $data]} "separate default Yes grants $lang"
    check {[string match {*grant_prompt_version=1*} $data] && [string match {*policy_generation=1*} $data]} "one atomic prompt generation $lang"
    foreach answer {y o yes oui} {
        set r [root answer-$lang-$answer]; set id [start $r $lang first-use]
        question $lang labels; send "$answer\r"; question $lang results; send "$answer\r"
        check {[finish $id]==0 && [string match {*private_results=on*} [policy $r]]} "answer $answer accepted in $lang"
    }
    set r [root default-$lang]
    set id [start $r $lang first-use]; no_prompt $id
    check {[policy $r] eq $data} "completed choice never regranted $lang"
    set id [start $r $lang acknowledged-fast]; check {[no_prompt $id]==0} "acknowledged startup uses shell pre-test without origin/backend $lang"
    set id [start $r $lang privacy labels off]; check {[finish $id]==0} "labels off $lang"
    set off [policy $r]; set id [start $r $lang first-use]; check {[finish $id]==0 && [policy $r] eq $off} "off does not reprompt $lang"
    set r [root decline-$lang]; set id [start $r $lang first-use]
    question $lang labels; send "n\r"; question $lang results; send "n\r"; check {[finish $id]==0} "decline $lang"
    set data [policy $r]; check {[string match {*label_sources=none*} $data] && [string match {*private_results=off*} $data] && [string match {*grant_prompt_version=1*} $data]} "decline remembered $lang"
    set id [start $r $lang hint]; see {recommended}; finish $id
    foreach stage {labels results} {
        set r [root eof-$lang-$stage]; set id [start $r $lang first-use]
        question $lang labels
        if {$stage eq "results"} {send "\r"; question $lang results}
        send "\004"; finish $id
        check {![file exists [file join $r .loomy logs content-policy.conf]]} "EOF $stage leaves pending without partial grants $lang"
    }
    set r [root forged-$lang]; set id [start $r $lang first-use]; question $lang labels
    send "user_approved=1\r"; finish $id
    check {![file exists [file join $r .loomy logs content-policy.conf]]} "forged confirmation is no grant $lang"
    set r [root separate-$lang]; set id [start $r $lang first-use]; question $lang labels
    send "\r"; question $lang results; send "n\r"; finish $id
    check {[string match {*private_results=off*} [policy $r]]} "labels answer does not enable results $lang"
}
set r [root_group_writable umask-002-first-use]
check {([file attributes [file join $r .loomy] -permissions] & 0777) == $::env(LOOMY_TEST_LOOMY_MODE)} "fresh git init creates the expected .loomy mode under umask 002"
set id [start $r en first-use]; question en labels; send "y\r"; question en results; send "y\r"
check {[finish $id]==0} "first-use grant works with group-writable .loomy"
check {([file attributes [file join $r .loomy logs] -permissions] & 0777) == 0700} "first-use keeps logs mode 0700 under umask 002"
set id [start $r en privacy label --id agent1 --attempt attempt1 {A label under umask 002}]
check {[finish $id]==0 && [file exists [file join $r .loomy logs display-context-v1.jsonl]]} "privacy label capture works with group-writable .loomy"
set r [root_group_writable umask-002-privacy]
set id [start $r en privacy labels recommended]
see {Allow these exact fields and limits for this project? [y/N]}; send "y\r"
check {[finish $id]==0 && [string match {*grant_prompt_version=1*} [policy $r]]} "privacy labels grant works with group-writable .loomy"
# A distinct screen lock suppresses competing screens without blocking writers.
set r [root concurrent-prompts]; set first [start $r en first-use]; question en labels
set second [start $r en first-use]
set spawn_id $first; send "\r"; question en results; send "\r"; finish $first
no_prompt $second
check {[string match {*policy_generation=1*} [policy $r]]} "concurrent opens produce one completed screen"

foreach lang {en fr} {
    set r [root first-typed-ahead-$lang]; set id [start $r $lang first-use-ahead]
    see READY_BEFORE_SCREEN; send "yes\ryes\r"
    question $lang labels; after 300
    check {![file exists [file join $r .loomy logs content-policy.conf]]} "typed-ahead input flushed before first question $lang"
    send "n\r"; question $lang results; send "n\r"
    check {[finish $id]==0 && [string match {*label_sources=none*} [policy $r]]} "fresh first answer required $lang"
    set r [root typed-ahead-$lang]; set id [start $r $lang first-use]; question $lang labels
    send "n\ryes\r\r"; question $lang results
    after 300
    check {![file exists [file join $r .loomy logs content-policy.conf]]} "typed-ahead answers flushed before second question $lang"
    send "n\r"; check {[finish $id]==0 && [string match {*private_results=off*} [policy $r]]} "fresh answer required for second question $lang"
}
set r [root prompt-writer]; set first [start $r en first-use]; question en labels
set second [start $r en restrict]
check {[finish $second]==0} "policy writer finishes while first question is waiting"
check {[string match {*results_max_records=199*} [policy $r]]} "unlocked prompt permits restrictive writer"
set spawn_id $first; send "y\r"; question en results; send "y\r"
see {Content policy changed while awaiting confirmation}
check {[finish $first]==0} "stale first-use abort leaves optional entrypoint alive"
check {[string match {*label_sources=none*} [policy $r]] && [string match {*grant_prompt_version=0*} [policy $r]]} "stale prompt preserves restrictions and pending screen"

set r [root explicit-writer]; set first [start $r en privacy results on]
see {Allow these exact fields and limits for this project? [y/N]}
set second [start $r en restrict]; check {[finish $second]==0} "explicit confirmation also leaves policy lock free"
set spawn_id $first; send "y\r"; check {[finish $first]!=0} "stale explicit confirmation cannot overwrite generation"

set r [root defaults-off]; set id [start $r en privacy labels off]; finish $id
check {![file exists [file join $r .loomy logs]]} "interactive labels off with defaults creates no files"

# A PTY is insufficient for every supported managed-origin marker. No runtime
# directory/lock, policy or label-store mutation is permitted for these attempts.
set markers {LOOMY_DELEGATION LOOMY_CLI_MANAGED LOOMY_PARENT_ID LOOMY_ATTEMPT LOOMY_ATTEMPT_ID LOOMY_EVENT_PARENT_ID LOOMY_CLI_ID LOOMY_CLI_SESSION_ID LOOMY_CLI_BRIDGE_CHECKED LOOMY_CLI_PROBE LOOMY_HOOK LOOMY_HOOK_CONTEXT LOOMY_BRIDGE LOOMY_BRIDGE_OK LOOMY_MANAGED CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CODEX_THREAD_ID CODEX_SESSION_ID CODEX_TOOL_CALL_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED CODEX_MANAGED_BY_NPM CODEX_MANAGED_BY_BUN BUN HOOK}
foreach marker $markers {
    foreach cmd {{first-use} {privacy content legacy-excerpts} {privacy labels recommended} {privacy labels set explicit-lead} {privacy results on} {privacy label --id agent1 {user approved}}} {
        set r [root managed-$marker-[join $cmd -]]
        # start() uses env -i, so prepend the marker to the actual child command.
        set launch_env [list env -i HOME=$work/home XDG_CONFIG_HOME=$work/config PATH=$repo/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin LOOMY_LANG=en NO_COLOR=1 $marker=1]
        spawn {*}$launch_env bash $work/entry.sh $repo $r {*}$cmd
        set id $spawn_id
        no_prompt $id
        check {![file exists [file join $r .loomy logs]]} "managed PTY $marker [lindex $cmd 1] has zero mutations"
    }
}
# Direct grants disclose the resolved project, fields and exact limits before a
# separate confirmation; a forged string cannot enable any of the three grants.
foreach cmd {{content legacy-excerpts} {labels recommended} {results on}} {
    set r [root explicit-[lindex $cmd 0]]; set id [start $r en privacy {*}$cmd]
    see $r; see {96 graphemes / 384 UTF-8 bytes}; see {200 records / 1048576 bytes}
    see {Allow these exact fields and limits for this project? [y/N]}; send "user_approved=1\r"; finish $id
    check {![file exists [file join $r .loomy logs content-policy.conf]]} "forged explicit [lindex $cmd 0] refused"
    set id [start $r en privacy {*}$cmd]; see {Allow these exact fields and limits for this project? [y/N]}; send "y\r"
    check {[finish $id]==0} "human explicit [lindex $cmd 0] accepted"
}
set r [root explicit-label]; set id [start $r en privacy label --id agent1 --attempt attempt1 "A deliberate label"]
see {Allow these exact fields and limits for this project? [y/N]}; send "y\r"; check {[finish $id]==0} "human explicit-user label"
check {[file exists [file join $r .loomy logs display-context-v1.jsonl]]} "explicit-user store exists only after guarded grant"
check {[string match {*grant_prompt_version=0*} [policy $r]]} "singular label never acknowledges first-use screen"
set id [start $r en first-use]; question en labels; send "n\r"; question en results; send "n\r"; finish $id

set r [root label-veto]; set id [start $r en first-use]
question en labels; send "y\r"; question en results; send "n\r"; finish $id
set before [policy $r]
spawn env -i HOME=$work/home XDG_CONFIG_HOME=$work/config PATH=$work/human-bin:$repo/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin LOOMY_LANG=en LOOMY_JOURNAL_TASKS=0 bash $work/entry.sh $repo $r privacy label --id agent1 blocked
set id $spawn_id; check {[no_prompt $id]!=0} "TASKS=0 singular label refuses without question"
check {[policy $r] eq $before && ![file exists [file join $r .loomy logs display-context-v1.jsonl]]} "TASKS=0 preserves every stored grant"

foreach ancestor {codex claude node /opt/runtime/node /opt/runtime/codex-aarch64 grandparent-node unavailable} {
    foreach cmd {{first-use} {privacy labels recommended} {privacy label --id agent1 text}} {
        set r [root ancestor-[string map {/ _} $ancestor]-[lindex $cmd 0]-[lindex $cmd 1]]
        spawn env -i HOME=$work/home PATH=$work/human-bin:$repo/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin LOOMY_LANG=en CONTENT_TEST_ANCESTOR=$ancestor bash $work/entry.sh $repo $r {*}$cmd
        no_prompt $spawn_id
        check {![file exists [file join $r .loomy logs]]} "managed ancestor $ancestor refuses [lindex $cmd 0] without env markers"
    }
}
foreach lang {en fr} {
    foreach ancestor {codex claude node} {
        set r [root ancestor-message-$lang-$ancestor]
        spawn env -i HOME=$work/home PATH=$work/human-bin:$repo/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin LOOMY_LANG=$lang CONTENT_TEST_ANCESTOR=$ancestor bash $work/entry.sh $repo $r privacy labels recommended
        set id $spawn_id
        if {$lang eq "en"} {
            see "Agent ancestor detected: $ancestor. Run this command from a plain terminal."
        } else {
            see "Agent détecté dans les processus parents : $ancestor. Lancez cette commande depuis un terminal ordinaire."
        }
        check {[finish $id]!=0 && ![file exists [file join $r .loomy logs]]} "named $ancestor ancestor refusal is localized in $lang"
    }
}

set r [root "bidi-\u202e-project-\u0085-\u200b"]
set id [start $r en first-use]; see {bidi-\u{202E}-project-\u{0085}-\u{200B}}
question en labels; send "n\r"; question en results; send "n\r"; finish $id

set r [root pane-pending]; set id [start $r en watch-pane]
see {Task labels off}; see {[q]}
file mkdir [file join $r .loomy logs]
file attributes [file join $r .loomy logs] -permissions 0700
set f [open [file join $r .loomy logs display-context-full] w]; puts $f {display context full; label not saved}; close $f
file attributes [file join $r .loomy logs display-context-full] -permissions 0600
see {display context full; label not saved}
send "q"; check {[finish $id]==0} "watch pane shows live mtime hints and exits without prompt"
check {![file exists [file join $r .loomy logs content-policy.conf]]} "pane never grants or acknowledges"
set r [root explicit-labels-decline]; set id [start $r en privacy labels recommended]
see {Allow these exact fields and limits for this project? [y/N]}; send "n\r"; finish $id
check {[string match {*grant_prompt_version=1*} [policy $r]] && [string match {*label_sources=none*} [policy $r]]} "explicit human labels decline acknowledges without a grant"
set id [start $r en first-use]; no_prompt $id
puts "ok EN/FR PTY grant matrix"
foreach lang {en fr} {
    foreach entry {init watch} {
        set r [root entry-$entry-$lang]
        if {$entry eq "init"} {
            file copy [file join $repo VERSION] [file join $r .loomy VERSION]
            set f [open [file join $r .loomy brief.md] w]
            puts $f "---\nname: fixture\nai_mode: SOLO\nai_lead: codex\nprofile: equilibre\n---"; close $f
        }
        set id [start $r $lang $entry]; question $lang labels; send "n\r"; question $lang results; send "n\r"
        if {$entry eq "watch"} {see {[q]}; send "q"}
        check {[finish $id]==0} "actual $entry entrypoint $lang"
        check {[string match {*grant_prompt_version=1*} [policy $r]] && [string match {*private_results=off*} [policy $r]]} "actual $entry commits the separate human answers $lang"
    }
}
TCL
expect "$WORK/prompt.exp" "$REPO" "$WORK"

# Unsafe directory diagnostics remain distinct at the real CLI boundary.
for unsafe_part in .loomy logs; do
  unsafe_root="$WORK/unsafe-message-$unsafe_part"
  mkdir -p "$unsafe_root"
  git -C "$unsafe_root" init -q -b main
  (umask 002; mkdir "$unsafe_root/.loomy")
  if [[ "$unsafe_part" == .loomy ]]; then
    chmod 0777 "$unsafe_root/.loomy"
    unsafe_path="$unsafe_root/.loomy"
  else
    chmod 0755 "$unsafe_root/.loomy"
    mkdir -m 0700 "$unsafe_root/.loomy/logs"
    chmod 0775 "$unsafe_root/.loomy/logs"
    unsafe_path="$unsafe_root/.loomy/logs"
  fi
  if bash "$WORK/entry.sh" "$REPO" "$unsafe_root" privacy labels recommended >"$WORK/unsafe-$unsafe_part.out" 2>&1; then
    printf 'unsafe directory unexpectedly accepted: %s\n' "$unsafe_path" >&2; exit 1
  fi
  grep -Fq "unsafe directory: $unsafe_path (group/world writable)" "$WORK/unsafe-$unsafe_part.out"
  if grep -Fq 'Invalid content policy:' "$WORK/unsafe-$unsafe_part.out"; then exit 1; fi
done
printf 'ok directory safety errors name the unsafe directory\n'

# Piped answers (including a model-style assertion) never create a policy or store.
for args in 'content legacy-excerpts' 'labels recommended' 'results on' 'label --id agent1 forged'; do
  root="$WORK/piped-${args%% *}"; mkdir -p "$root/.loomy"
  # Deliberate word splitting: these are fixed technical CLI tokens, no user data.
  # shellcheck disable=SC2086
  if printf 'yes\nuser_approved=1\n' | bash "$WORK/entry.sh" "$REPO" "$root" privacy $args; then
    printf 'piped widening unexpectedly succeeded: %s\n' "$args" >&2; exit 1
  fi
  [[ ! -e "$root/.loomy/logs" ]]
done
mkdir -p "$WORK/noninteractive/.loomy"
bash "$WORK/entry.sh" "$REPO" "$WORK/noninteractive" first-use </dev/null >"$WORK/noninteractive.out"
[[ ! -s "$WORK/noninteractive.out" && ! -e "$WORK/noninteractive/.loomy/logs" ]]
bash "$WORK/entry.sh" "$REPO" "$WORK/store" hint >"$WORK/full-hint.out"
grep -q '^display context full; label not saved$' "$WORK/full-hint.out"

# Machine-readable show and the consent title use the same display-safe path.
for root in "$WORK"/bidi-*; do
  bash -c 'source "$1/scripts/lib/content-policy.sh"; loomy_content_policy "$2"' _ "$REPO" "$root" >"$WORK/show-safe.json"
  perl -MJSON::PP -0777 -e 'my $p=decode_json(<>)->{project}; die "unsafe project display" if $p =~ /[\p{Cc}\p{Cf}]/;
    die "missing escaped bidi path" unless $p =~ /\\u\{202E\}/' "$WORK/show-safe.json"
done
LOOMY_LANG=fr LOOMY_UI_LANG=fr bash "$WORK/entry.sh" "$REPO" "$WORK/default-fr" privacy labels >"$WORK/privacy-fr.out"
grep -q 'Sources de libellés sélectionnées' "$WORK/privacy-fr.out"
grep -q 'portée : projet · génération' "$WORK/privacy-fr.out"
if grep -qE '^(journal_content|label_sources|private_results|source|scope|policy_generation|grant_prompt_version)=' "$WORK/privacy-fr.out"; then exit 1; fi
mkdir -p "$WORK/invalid-policy/.loomy/logs"; chmod 0755 "$WORK/invalid-policy/.loomy"; chmod 0700 "$WORK/invalid-policy/.loomy/logs"
printf 'not a valid policy\n' >"$WORK/invalid-policy/.loomy/logs/content-policy.conf"
chmod 600 "$WORK/invalid-policy/.loomy/logs/content-policy.conf"
if bash "$WORK/entry.sh" "$REPO" "$WORK/invalid-policy" privacy labels off >"$WORK/invalid-policy.out" 2>&1; then exit 1; fi
grep -Fq "$WORK/invalid-policy/.loomy/logs/content-policy.conf" "$WORK/invalid-policy.out"
if bash "$WORK/entry.sh" "$REPO" "$WORK/default-en" privacy results invalid >"$WORK/invalid-argument.out" 2>&1; then exit 1; fi
if grep -Fq 'Fix or remove this file' "$WORK/invalid-argument.out"; then exit 1; fi
printf 'ok safe project display, readable FR privacy, named invalid policy\n'

# Every idle check is builtins only; translations/backend run only on a change.
cat >"$WORK/hints.sh" <<'SH'
set -euo pipefail
repo="$1"; work="$2"; root="$work/hint-root"
source "$repo/scripts/lib/content-policy.sh"
mkdir -p "$root/.loomy/logs"; chmod 0755 "$root/.loomy"; chmod 0700 "$root/.loomy/logs"
_loomy_content_ui() { echo 'hint loaded the complete screen dictionary' >&2; return 99; }
perl() { printf 'perl\n' >>"$work/hint-calls"; command perl "$@"; }
touch() { printf 'touch\n' >>"$work/hint-calls"; command touch "$@"; }
rm() { printf 'rm\n' >>"$work/hint-calls"; command rm "$@"; }
tv() { printf 'translate\n' >>"$work/hint-calls"; printf -v "$1" '%s' "$2"; }
content_sig() {
  command perl -MTime::HiRes=stat -e 'print join("|",map {(stat("$ARGV[0]/.loomy/logs/$_"))[9] // "-"} qw(content-policy.conf display-context-full))' "$root"
}
: >"$work/hint-calls"
_loomy_content_hint_load "$root"
[[ "$LOOMY_CONTENT_HINT" == 'Task labels off · run loomy privacy labels recommended' ]]
! grep -q '^perl$' "$work/hint-calls"
cp "$work/hint-calls" "$work/hint-calls-before"
for ((i=0; i<200; i++)); do loomy_content_hint_refresh "$root" "$LOOMY_CONTENT_HINT_SIGNATURE"; done
cmp "$work/hint-calls-before" "$work/hint-calls"
cp "$work/answer-en-y/.loomy/logs/content-policy.conf" "$root/.loomy/logs/content-policy.conf"
# In this shell (not a command substitution) so the direct call also clears the cached hint.
loomy_content_status_hint "$root" >"$work/direct-hint"
[[ ! -s "$work/direct-hint" && -z "$LOOMY_CONTENT_HINT" ]]
policy_sig="$(content_sig)"
loomy_content_hint_refresh "$root" "$policy_sig"
[[ -z "$LOOMY_CONTENT_HINT" ]]
[[ "$LOOMY_CONTENT_HINT_SIGNATURE" == "$policy_sig" ]]
[[ "$(grep -c '^perl$' "$work/hint-calls" || true)" == 0 ]]
# Completed first use must return before its origin check or full dictionary.
loomy_content_human_tty() { echo 'completed first use checked origin' >&2; return 99; }
loomy_content_first_use "$root"
cp "$work/hint-calls" "$work/hint-calls-before"
: >"$root/.loomy/logs/events.jsonl"
for ((i=0; i<200; i++)); do loomy_content_hint_refresh "$root" "$LOOMY_CONTENT_HINT_SIGNATURE"; done
cmp "$work/hint-calls-before" "$work/hint-calls"
command perl -MTime::HiRes=stat,utime -e 'my $f=$ARGV[0]; my $s=int((stat($f))[9]); utime($s+0.1,$s+0.1,$f)' "$root/.loomy/logs/content-policy.conf"
loomy_content_hint_refresh "$root" "$(content_sig)"
[[ "$(grep -c '^perl$' "$work/hint-calls" || true)" == 0 ]]
command perl -MTime::HiRes=stat,utime -e 'my $f=$ARGV[0]; my $s=int((stat($f))[9]); utime($s+0.2,$s+0.2,$f)' "$root/.loomy/logs/content-policy.conf"
loomy_content_hint_refresh "$root" "$(content_sig)"
[[ "$(grep -c '^perl$' "$work/hint-calls" || true)" == 0 ]]
printf 'display context full; label not saved\n' >"$root/.loomy/logs/display-context-full"
chmod 600 "$root/.loomy/logs/display-context-full"
loomy_content_hint_refresh "$root" "$(content_sig)"
[[ "$LOOMY_CONTENT_HINT" == 'display context full; label not saved' ]]
[[ "$(grep -c '^perl$' "$work/hint-calls")" == 1 ]]
command rm "$root/.loomy/logs/display-context-full"
loomy_content_hint_refresh "$root" "$(content_sig)"
[[ -z "$LOOMY_CONTENT_HINT" ]]
[[ "$(grep -c '^perl$' "$work/hint-calls")" == 1 ]]
command rm "$root/.loomy/logs/content-policy.conf"
loomy_content_hint_refresh "$root" "$(content_sig)"
[[ "$LOOMY_CONTENT_HINT" == 'Task labels off · run loomy privacy labels recommended' ]]
printf 'ok hint mtime invalidation, lazy translations, zero idle helper/interpreter launches\n'
SH
bash "$WORK/hints.sh" "$REPO" "$WORK"

# Reproduce Homebrew removing the old policy library during the upgrade. This
# is an isolated install fixture; the real repository and package manager stay idle.
old_install="$WORK/Cellar/loomy/0.0.0"
mkdir -p "$old_install/bin" "$old_install/scripts" "$WORK/update-bin"
cp "$REPO/bin/loomy" "$old_install/bin/loomy"
cp "$REPO/VERSION" "$old_install/VERSION"
cp -R "$REPO/scripts/lib" "$old_install/scripts/lib"
cp -R "$REPO/catalog" "$old_install/catalog"
cat >"$WORK/update-bin/brew" <<'SH'
#!/usr/bin/env bash
case "$1" in
  update) exit 0 ;;
  upgrade) rm -f "$CONTENT_TEST_OLD_HOME/scripts/lib/content-policy.sh" ;;
  *) exit 99 ;;
esac
SH
chmod +x "$WORK/update-bin/brew"
env PATH="$WORK/update-bin:$PATH" CONTENT_TEST_OLD_HOME="$old_install" bash "$old_install/bin/loomy" update >"$WORK/update.out" 2>&1
grep -q 'Loomy up to date' "$WORK/update.out"
[[ ! -e "$old_install/scripts/lib/content-policy.sh" ]]
printf 'ok update survives a removed old-install content-policy source\n'
test_guard_gate

# Hermetic R2-T0 contracts. Synthetic sources only; no provider or quota calls.
use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Fcntl qw(:mode);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP ();
use POSIX qw(strftime mkfifo);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes ();

my ($repo,$requested)=@ARGV; $repo=abs_path($repo//'') or die "repository required\n";
my $work=$requested // tempdir('loomy-r2-policy-XXXXXX',TMPDIR=>1,CLEANUP=>1);
die "fixture directory already populated\n" if -e $work && do {opendir my $d,$work or die; scalar grep {!/^\.{1,2}$/} readdir $d};
umask 0077;
make_path($work,{mode=>0700}); $work=abs_path($work) or die;
for my $pair ([HOME=>'home'],[XDG_CONFIG_HOME=>'config'],[XDG_STATE_HOME=>'state'],[XDG_CACHE_HOME=>'cache'],
    [XDG_RUNTIME_DIR=>'runtime'],[TMPDIR=>'tmp'],[CODEX_HOME=>'codex'],[CLAUDE_CONFIG_DIR=>'claude']) {
    $ENV{$pair->[0]}="$work/$pair->[1]"; make_path($ENV{$pair->[0]},{mode=>0700});
}
delete @ENV{qw(BASH_ENV ENV LOOMY_JOURNAL_CONTENT LOOMY_CONTENT_PROJECT LOOMY_PROJECT_ROOT LOOMY_HOOK_CONTEXT)};
$ENV{LOOMY_JOURNAL}=1; $ENV{LOOMY_JOURNAL_TASKS}=1; $ENV{LOOMY_CLI_MANAGED}=1;
$ENV{LOOMY_LANG}='en'; $ENV{LOOMY_UI_LANG}='en'; $ENV{LOOMY_HOME}=$repo;
$ENV{LOOMY_NO_AUTOUPDATE}=1; $ENV{LOOMY_CATALOG_CHECK}=0;
my $json=JSON::PP->new->utf8->canonical;
require "$repo/scripts/lib/content-policy.pl";
my $project_id='p'.('a'x64);
my $stamp='2026-10-27T12:00:00Z';
sub cp {Loomy::ContentPolicy::project_checkpoint(@_)}
sub valid {Loomy::ContentPolicy::validate_checkpoint(@_)}
sub clone {$json->decode($json->encode($_[0]))}
sub put {
    my ($p,$bytes,$mode)=@_; open my $f,'>',$p or die "fixture write failed\n";
    binmode $f; print {$f} $bytes or die; close $f or die; chmod($mode//0600,$p) or die;
}
sub bytes {open my $f,'<',$_[0] or die; binmode $f; local $/; return <$f>}
sub project {
    my ($name,$identity,$grants)=@_; my $root="$work/$name";
    make_path("$root/.loomy/logs",{mode=>0700});
    put("$root/.loomy/project-id","$project_id\n") if $identity;
    conf($root,%$grants) if $grants; return $root;
}
sub conf {
    my ($root,%changes)=@_; my $p={%{Loomy::ContentPolicy::defaults()},%changes};
    put("$root/.loomy/logs/content-policy.conf",join('',map {"$_=$p->{$_}\n"} sort keys %$p)); Loomy::PolicyRecord::record_file($root);   # ADR-0012
}
sub manifest {
    my ($root)=@_; my %result;
    find({no_chdir=>1,wanted=>sub {
        my $path=$File::Find::name; my @s=Time::HiRes::lstat($path); die unless @s;
        my $payload=S_ISREG($s[2]) ? sha256_hex(bytes($path)) : S_ISLNK($s[2]) ? readlink($path) : '';
        $result{substr($path,length($root))}=[@s[0,1,2,3,4,5,7,9,10],$payload];
    }},$root);
    return \%result;
}
sub readonly {
    my ($name,$root,$code)=@_; my $before=manifest($root); my $value=$code->();
    is_deeply(manifest($root),$before,"$name changes no bytes, names, modes, ownership or mtimes"); return $value;
}
sub denied {
    my ($name,$code)=@_; my $ok=eval {$code->(); 1};
    ok(!$ok,$name); is($@,"invalid structural checkpoint\n","$name has a fixed content-free error") unless $ok;
}
sub bash_snapshot {
    my ($api,$root,@mode)=@_; my $error=gensym();
    my $pid=open3(undef,my $out,$error,'/bin/bash','-c',
        'source "$1"; _loomy_content_ui() { exit 98; }; shift; "$@"','r2-snapshot',
        "$repo/scripts/lib/content-policy.sh",$api,$root,@mode);
    my $raw=do {local $/; <$out>}//''; my $errors=do {local $/; <$error>}//'';
    waitpid($pid,0)==$pid or die "snapshot wrapper wait failed\n";
    return ($?,$raw,$errors);
}

# No external provider/process census is permitted, even if an accidental code
# path is introduced later. These executables are test-owned, never real CLIs.
make_path("$work/bin",{mode=>0700});
for my $name (qw(codex claude pgrep tmux ps)) {put("$work/bin/$name","#!/bin/sh\nexit 97\n",0700)}
$ENV{PATH}="$work/bin:/usr/bin:/bin:/usr/sbin:/sbin";

my $granted=project('granted',1,{journal_content=>'legacy-excerpts',label_sources=>Loomy::ContentPolicy::recommended_sources(),
    private_results=>'on',grant_prompt_version=>1,policy_generation=>7});
put("$granted/.loomy/logs/old.idx",'{"task":"HISTORICAL_CANARY"}',0644);
put("$granted/.loomy/logs/old.idx.bak",'broken historical backup',0600);
my $snapshot=readonly('initialized grant snapshot',$granted,sub {Loomy::ContentPolicy::policy_snapshot($granted)});
is($snapshot->{identity_state},'present','initialized identity is explicit');
is($snapshot->{policy_state},'project','existing policy origin retained');
is($snapshot->{project_id},$project_id,'existing identity retained exactly');
is($snapshot->{policy_generation},7,'read-only snapshot retains grant generation');
is($snapshot->{private_results},'on','same-project grant is readable');
is($snapshot->{journal_content},'legacy-excerpts','journal compatibility remains separately visible');

# Git registration and the link are fixture setup, outside the read-only probe.
{
    my $owner=project('snapshot-owner',1,{journal_content=>'legacy-excerpts',private_results=>'on',
        label_sources=>'explicit-lead',grant_prompt_version=>1,policy_generation=>12});
    system('git','-C',$owner,'init','-q','-b','main')==0 or die "fixture init failed\n";
    system('git','-C',$owner,'-c','user.name=test','-c','user.email=test@example.invalid',
        '-c','commit.gpgsign=false','commit','-q','--allow-empty','-m','fixture')==0 or die "fixture commit failed\n";
    my $wt="$work/snapshot-worktree";
    system('git','-C',$owner,'worktree','add','-q','-b','shared',$wt)==0 or die "fixture worktree failed\n";
    symlink "$owner/.loomy","$wt/.loomy" or die;
    my $p=readonly('registered shared worktree snapshot',$work,sub {
        my $shared=Loomy::ContentPolicy::policy_snapshot($wt);
        is_deeply($shared,Loomy::ContentPolicy::policy_snapshot($owner),'registered worktree reads the exact owner snapshot');
        return $shared;
    });
    is($p->{identity_state},'present','registered shared worktree attests existing identity');
    is($p->{project_id},$project_id,'registered shared worktree retains exact owner identity');
    is($p->{policy_generation},12,'registered shared worktree retains owner policy generation');
    is($p->{private_results},'on','registered shared worktree reads the existing grant');
}

for my $case ('no-loomy','no-logs','no-identity','no-policy') {
    my $root="$work/$case";
    if ($case eq 'no-loomy') {make_path($root,{mode=>0700})}
    elsif ($case eq 'no-logs') {make_path("$root/.loomy",{mode=>0700})}
    else {$root=project($case,$case eq 'no-policy',$case eq 'no-identity' ? {journal_content=>'legacy-excerpts',private_results=>'on',label_sources=>'explicit-lead'} : undef)}
    put("$root/.loomy/logs/display-context-v1.jsonl",$json->encode({project_id=>$project_id,text=>'NO_MIGRATION_CANARY'})."\n") if $case eq 'no-identity';
    my $p=readonly("$case snapshot",$root,sub {Loomy::ContentPolicy::policy_snapshot($root)});
    is($p->{identity_state},$case eq 'no-policy' ? 'present' : 'missing',"$case identity state");
    ok(!exists($p->{project_id}),"$case never invents a project ID") unless $case eq 'no-policy';
    is($p->{journal_content},'structural',"$case structural default");
    is($p->{label_sources},'none',"$case grants no labels"); is($p->{private_results},'off',"$case grants no results");
    is($p->{journal_enabled},0,"$case unavailable identity closes collection") unless $case eq 'no-policy';
}

for my $field ('identity','policy') {
    for my $attack (qw(malformed oversized symlink hardlink fifo directory mode)) {
        my $root=project("$field-$attack",1,{journal_content=>'legacy-excerpts',private_results=>'on',label_sources=>'explicit-lead'});
        my $path=$field eq 'identity' ? "$root/.loomy/project-id" : "$root/.loomy/logs/content-policy.conf";
        my $target="$root/foreign-target"; put($target,bytes($path)); unlink $path or die;
        if ($attack eq 'malformed') {put($path,'INVALID_PRIVATE_CANARY'); Loomy::PolicyRecord::record_file($root) if $field eq 'policy'}   # a file Loomy wrote that went invalid (an unrecorded one is ignored, ADR-0012)
        elsif ($attack eq 'oversized') {put($path,'x'x($field eq 'identity' ? 129 : 16385))}
        elsif ($attack eq 'symlink') {symlink $target,$path or die}
        elsif ($attack eq 'hardlink') {link $target,$path or die}
        elsif ($attack eq 'fifo') {mkfifo($path,0600) or die}
        elsif ($attack eq 'directory') {mkdir $path,0700 or die}
        else {put($path,bytes($target),0644)}
        my $p=readonly("$field $attack snapshot",$root,sub {Loomy::ContentPolicy::policy_snapshot($root)});
        ok(!$p->{valid},"$field $attack fails closed");
        is($p->{journal_enabled},0,"$field $attack cannot collect");
        is($p->{label_sources},'none',"$field $attack cannot authorize labels");
        is($p->{private_results},'off',"$field $attack cannot authorize results");
        is($p->{journal_content},'structural',"$field $attack cannot authorize excerpts");
    }
}
for my $attack (qw(loomy-mode logs-mode logs-symlink loomy-symlink)) {
    my $root=project("directory-$attack",1,{private_results=>'on'});
    if ($attack eq 'loomy-mode' || $attack eq 'logs-mode') {chmod 0777,$attack eq 'loomy-mode' ? "$root/.loomy" : "$root/.loomy/logs" or die}
    elsif ($attack eq 'logs-symlink') {rename "$root/.loomy/logs","$root/foreign-logs" or die; symlink "$root/foreign-logs","$root/.loomy/logs" or die}
    else {rename "$root/.loomy","$root/foreign-loomy" or die; symlink "$root/foreign-loomy","$root/.loomy" or die}
    my $p=readonly("$attack snapshot",$root,sub {Loomy::ContentPolicy::policy_snapshot($root)});
    ok(!$p->{valid} && !$p->{journal_enabled} && $p->{private_results} eq 'off',"$attack is refused without repair");
}

# Replace after the pinned policy read, before the final snapshot assertion.
# Only the fixture mutates here: capture its expected manifest in the injection
# and prove that the accessor adds no lock, repair, migration or other effect.
my $real_stored=Loomy::ContentPolicy->can('_stored');
for my $replacement (qw(identity logs-directory)) {
    my $root=project("race-$replacement",1,{journal_content=>'legacy-excerpts',private_results=>'on',label_sources=>'explicit-lead',policy_generation=>7});
    my ($expected,$injected)=(undef,0); my $p;
    {
        no warnings 'redefine';
        local *Loomy::ContentPolicy::_stored=sub {
            my $stored=$real_stored->(@_);
            if ($_[0]{root} eq $root && !$injected++) {
                if ($replacement eq 'identity') {
                    put("$root/.loomy/replacement-project-id","$project_id\n");
                    rename "$root/.loomy/project-id","$root/.loomy/preserved-project-id" or die;
                    rename "$root/.loomy/replacement-project-id","$root/.loomy/project-id" or die;
                } else {
                    rename "$root/.loomy/logs","$root/.loomy/preserved-logs" or die;
                    mkdir "$root/.loomy/logs",0700 or die;
                }
                $expected=manifest($root);
            }
            return $stored;
        };
        $p=Loomy::ContentPolicy::policy_snapshot($root);
    }
    is($injected,1,"$replacement race injection follows exactly one policy read");
    ok(!$p->{valid},"$replacement replacement invalidates the snapshot");
    is($p->{identity_state},'invalid',"$replacement replacement cannot attest stable identity");
    ok(!exists($p->{project_id}),"$replacement replacement supplies no usable project identity");
    is_deeply([@$p{qw(journal_content label_sources private_results)}],['structural','none','off'],"$replacement replacement closes every content grant");
    is($p->{journal_enabled},0,"$replacement replacement closes collection");
    is_deeply(manifest($root),$expected,"$replacement replacement adds no mutations beyond the recorded fixture injection");
}

my $export=readonly('structural export selection',$granted,sub {Loomy::ContentPolicy::export_policy_snapshot($granted)});
is($export->{journal_content},'structural','export defaults to explicit structural mode despite project compatibility');
is($export->{identity_state},'present','successful structural export requires the existing identity');
is($export->{project_id},$project_id,'successful structural export retains the exact project salt');
my $event={type=>'delegation',id=>'d1',role=>'developer',cost_in=>'usage',cost_usd=>0,task=>'EXPORT_CANARY',why=>'EXPORT_CANARY'};
my $public=Loomy::ContentPolicy::project_with_policy($export,$event);
ok(!exists($public->{task}) && !exists($public->{why}),'export goes through project_with_policy with structural snapshot');
is($public->{cost_usd},0,'export projection preserves known zero cost');
my $compat=readonly('explicit compatibility selection',$granted,sub {Loomy::ContentPolicy::export_policy_snapshot($granted,'legacy-excerpts')});
is(Loomy::ContentPolicy::project_with_policy($compat,$event)->{task},'EXPORT_CANARY','existing compatibility grant can be consumed explicitly');
my $ungranted=project('ungranted',1,undef);
readonly('identified structural export without a content grant',$ungranted,sub {
    is(Loomy::ContentPolicy::export_policy_snapshot($ungranted,'structural')->{project_id},$project_id,
        'existing valid identity permits explicit structural export without a content grant');
});
readonly('ungranted compatibility refusal',$ungranted,sub {
    ok(!eval {Loomy::ContentPolicy::export_policy_snapshot($ungranted,'legacy-excerpts'); 1},'output flag never creates a compatibility grant');
});
{
    local $ENV{LOOMY_JOURNAL_TASKS}=0;
    my $p=readonly('TASKS veto snapshot',$granted,sub {Loomy::ContentPolicy::policy_snapshot($granted)});
    is_deeply([@$p{qw(journal_content label_sources private_results policy_generation)}],['structural','none','off',7],'TASKS=0 restricts process without rewriting grants');
    is(Loomy::ContentPolicy::export_policy_snapshot($granted,'legacy-excerpts')->{journal_content},'structural','TASKS veto wins over explicit output mode');
}
{
    local $ENV{LOOMY_JOURNAL_CONTENT}='legacy-excerpts'; local $ENV{LOOMY_CONTENT_PROJECT}=$ungranted;
    readonly('bound environment cannot grant',$ungranted,sub {
        is(Loomy::ContentPolicy::policy_snapshot($ungranted)->{journal_content},'structural','same-project environment is not consent');
    });
}
{
    local $ENV{LOOMY_JOURNAL_CONTENT}='structural';
    readonly('environment restriction',$granted,sub {
        is(Loomy::ContentPolicy::policy_snapshot($granted)->{journal_content},'structural','structural environment restriction remains effective');
        ok(!eval {Loomy::ContentPolicy::export_policy_snapshot($granted,'legacy-excerpts'); 1},'explicit output does not override environment restriction');
    });
}
readonly('Bash snapshot API',$granted,sub {
    my ($status,$raw,$errors)=bash_snapshot('loomy_content_policy_snapshot',$granted);
    is($status,0,'Bash read-only accessor succeeds without interactive UI');
    is($errors,'','Bash read-only accessor emits no diagnostics');
    is_deeply($json->decode($raw),Loomy::ContentPolicy::policy_snapshot($granted),'Bash accessor uses the same canonical snapshot');
});
for my $selection ([default=>undef],[structural=>'structural'],['legacy-excerpts'=>'legacy-excerpts']) {
    my @mode=defined($selection->[1]) ? ($selection->[1]) : ();
    readonly("Bash $selection->[0] export API",$granted,sub {
        my ($status,$raw,$errors)=bash_snapshot('loomy_content_export_policy_snapshot',$granted,@mode);
        is($status,0,"Bash $selection->[0] export succeeds without interactive UI");
        is($errors,'',"Bash $selection->[0] export emits no diagnostics");
        is_deeply($json->decode($raw),Loomy::ContentPolicy::export_policy_snapshot($granted,@mode),
            "Bash $selection->[0] export forwards the selected mode to the canonical snapshot");
    });
}

# No identity means no export snapshot, including structural output and vetoed
# compatibility output. Unsafe fixture objects must remain untouched on error.
for my $identity_case (qw(no-loomy no-logs no-identity identity-malformed identity-oversized
        identity-symlink identity-hardlink identity-fifo identity-directory identity-mode
        directory-loomy-mode directory-logs-mode directory-logs-symlink directory-loomy-symlink)) {
    my $root="$work/$identity_case";
    isnt(Loomy::ContentPolicy::policy_snapshot($root)->{identity_state},'present',"$identity_case cannot attest identity");
    for my $tasks (1,0) {
        local $ENV{LOOMY_JOURNAL_TASKS}=$tasks;
        for my $selection ([default=>undef],[structural=>'structural'],['legacy-excerpts'=>'legacy-excerpts']) {
            my @mode=defined($selection->[1]) ? ($selection->[1]) : ();
            my $name="$identity_case $selection->[0] export TASKS=$tasks";
            readonly($name,$root,sub {
                my ($value,$error); my $warnings='';
                my $ok=eval {local $SIG{__WARN__}=sub {$warnings.=join('',@_)};
                    $value=Loomy::ContentPolicy::export_policy_snapshot($root,@mode); 1};
                $error=$@;
                ok(!$ok && !defined($value),"$name refuses before returning a snapshot");
                is($error,"content export grant unavailable\n","$name has the fixed content-free diagnostic");
                is($warnings,'',"$name leaks no warnings or supplied content");
            });
        }
    }
}
for my $tasks (1,0) {
    local $ENV{LOOMY_JOURNAL_TASKS}=$tasks;
    for my $selection ([default=>undef],[structural=>'structural'],['legacy-excerpts'=>'legacy-excerpts']) {
        my @mode=defined($selection->[1]) ? ($selection->[1]) : ();
        my $name="Bash missing-identity $selection->[0] export TASKS=$tasks";
        readonly($name,"$work/no-identity",sub {
            my ($status,$raw,$errors)=bash_snapshot('loomy_content_export_policy_snapshot',"$work/no-identity",@mode);
            isnt($status,0,"$name propagates refusal");
            is($raw,'',"$name emits no snapshot bytes");
            is($errors,"content export grant unavailable\n","$name emits only the fixed content-free diagnostic");
        });
    }
}

my $context={project_id=>$project_id,source_roots=>['/synthetic-provider/sessions'],workspace_roots=>['/synthetic-workspace'],policy_generation=>7};
my $source='/synthetic-provider/sessions/missing.jsonl';
my $ref={version=>1,project_id=>$project_id,target_kind=>'agent',target_id=>'agent1',attempt_id=>'attempt1',label_id=>'label1'};
for my $identity_case ('no-identity','identity-malformed') {
    my $closed_snapshot=Loomy::ContentPolicy::policy_snapshot("$work/$identity_case");
    my $warnings=''; local $SIG{__WARN__}=sub {$warnings.=join('',@_)};
    for my $field (qw(label_ref task_ref label_refs)) {
        my $forged={%$ref,project_id=>''}; delete $forged->{label_id} if $field eq 'task_ref';
        $forged={slug=>$forged} if $field eq 'label_refs';
        my $out=Loomy::ContentPolicy::project_with_policy($closed_snapshot,{type=>'delegation',$field=>$forged});
        ok(!defined($out->{$field}),"$identity_case snapshot cannot authorize forged $field scope");
    }
    is($warnings,'',"$identity_case forged scopes leak no warnings or content");
}
my $terminal={ts=>$stamp,status=>'ok',outcome=>'done'};
my $legacy={version=>1,files=>{$source=>{
    meta=>{id=>'agent1',parent=>'parent1',agent=>'',role=>'explorer',surface=>'cli',ts=>$stamp,v2=>1,metadata_protocol=>2,
        workspace_id=>'workspace1',cwd=>'/synthetic-workspace',workspace_roots=>['/synthetic-workspace/src'],task=>'PRIVATE_META',nickname=>'PRIVATE_META'},
    key=>'1:2',offset=>0,skipping=>0,read_sig=>'1:2:120:1793102400.125',at_eof=>1,replay_fence=>1793102400,source_mtime=>1793102400.125,
    last_observed_ts=>$stamp,last_evidence_ts=>$stamp,last_model=>'gpt-6.2-sol',last_effort=>'max',id=>'cn:agent1:turn1',turn=>'turn1',started=>$stamp,finished=>0,
    model=>'gpt-6.2-sol',effort=>'max',activity=>'waiting',activity_ts=>$stamp,activity_position=>120,event_position=>120,
    lead_state=>'waiting',lead_turn=>'turn1',lead_position=>120,lead_waits=>{wait1=>1},wait_calls=>{wait1=>1},close_calls=>{close1=>'agent2'},closed_agents=>{agent2=>$stamp},
    context=>{turn=>'turn1',ts=>$stamp,position=>0,model=>'',effort=>''},context_invalidated=>0,context_revision=>4,
    emitted_activity=>'cn:agent1:turn1:gpt-6.2-sol:max:waiting:a2',projected_lead=>'pending:parent1',projected_metadata=>2,journal_generation=>1,
    complete_sig=>'1:2:120:1793102400.125',tail_sig=>'1:2:120:1793102400.125',tail_start=>0,tail_end=>120,tail_at=>1793102400,back_chunk=>262144,
    gap_start=>0,gap_end=>120,v2_position=>120,v2_tail_sig=>'1:2:120:1793102400.125',v2_window=>0,model_probe=>'cn:agent1:turn1',
    probe_sig=>'1:2:120:1793102400.125',starts=>[1793102400,1793102400.125],oversized=>0,oversized_at=>120,buffer=>'PRIVATE_BUFFER',read_bytes=>128,read_start=>0}},
    source_shards=>['files-'.('a'x64)],journal=>{key=>'1:3',offset=>40,read_sig=>'1:3:40:1793102400.25',skipping=>0,at_eof=>1,generation=>2,active=>{'cn:agent1:turn1'=>1},read_bytes=>30,read_start=>0},
    seen=>{('b'x64)=>1793102400},sent=>{'start:cl:session1:call1'=>'1','end:cl:session1:call1'=>"$stamp:ok",
        'context:cl:session1:call1'=>$json->encode({id=>'cl:session1:call1',session=>'session1',session_key=>'claude:session1',turn_id=>'call1',role=>'Explore',model=>'',effort=>'',state=>'running',cost_in=>'usage',cost_usd=>0,task=>'PRIVATE_SENT'})},
    sessions=>{session1=>{id=>'session1',surface=>'app',state=>'waiting',state_ts=>$stamp,seen=>$stamp,model=>'',effort=>'',
        calls=>{call1=>{call=>'call1',agent=>'child1',alias_from=>'agent:child1',role=>'Explore',agent_type=>'Explore',model=>'',effort=>'',state=>'running',status=>'ok',outcome=>'unknown',
            started=>$stamp,ended=>undef,seen=>$stamp,background=>1,returned=>0,reopened=>0,terminal_evidence=>0,source_mtime=>1793102400,task=>'PRIVATE_CALL'}},
        aliases=>{child1=>'call1'},stops=>{child1=>clone($terminal)},waits=>{call1=>1},pending_notify=>{call1=>clone($terminal)},cwd_relative=>'PRIVATE_CWD'}},
    owners=>{"42:$stamp"=>{pid=>42,session=>'session1',ts=>$stamp,lead=>'agent1',ended=>undef,dead_at=>undef,unbound=>0}},
    owner_leads=>{"42:$stamp"=>{lead=>'agent1',session=>'session1'}},root_revisions=>{agent1=>4},
    root_snapshots=>{agent1=>{known=>1,ts=>$stamp,owner_pid=>42,context_freshness=>'current',context_revision=>4}},fences=>{session1=>1793102400},
    rotation=>0,read_rotation=>0,reconstructing=>1,discovering=>0,recovery_sources=>{agent1=>{
        type=>'delegation',ts=>$stamp,tool=>'codex',bridge=>'codex-native',id=>'cn:agent1:turn1',agent_id=>'agent1',turn_id=>'turn1',role=>'explorer',model=>'gpt-6.2-sol',effort=>'max',
        cost_in=>'usage',cost_usd=>0,duration_s=>undef,label_ref=>clone($ref),label_refs=>{map {$_=>clone($ref)} qw(slug nickname role)},
        source_inode=>'1:2',source_offset=>120,task=>'PRIVATE_RECOVERY',checkpoint_value=>'sha256:'.('c'x64)}},
    repair=>{'cn:agent1:turn1'=>{agent=>'agent1',turn=>'turn1',model=>'',effort=>'',ts=>$stamp}},unknown_repair_v1=>1};
my $before=$json->encode($legacy);
my $projected=cp($legacy,$context);
is($json->encode($legacy),$before,'pure projection leaves caller state untouched');
ok(valid($projected,$context),'projected logical checkpoint validates strictly');
ok($json->encode($projected)!~/PRIVATE_/,'known legacy text and transient raw buffers are omitted at every declared depth');
is_deeply(cp($projected,$context),$projected,'projection is idempotent');
is_deeply(cp({},$context),{version=>2,content_policy=>'structural-v1',policy_generation=>7},'empty adoption fixes only structural container envelope');
is($projected->{files}{$source}{offset},0,'known zero cursor is preserved');
ok(!defined($projected->{sessions}{session1}{calls}{call1}{ended}),'null remains unknown');
is($projected->{sessions}{session1}{calls}{call1}{role},'Explore','legacy Claude role retains approved configuration identifier');
is_deeply($projected->{owner_leads}{"42:$stamp"},{lead=>'agent1',session=>'session1'},'owner_leads retains actual record constructor');
is_deeply($projected->{recovery_sources}{agent1}{label_refs},{map {$_=>clone($ref)} qw(slug nickname role)},'all three scoped references survive recursive projection');
is($projected->{recovery_sources}{agent1}{cost_usd},0,'recovery accounting keeps actual zero cost');
ok(!defined($projected->{recovery_sources}{agent1}{duration_s}),'recovery duration stays unknown');
for my $field (qw(task_ref label_ref label_refs)) {
    my $state=clone($projected); $state->{recovery_sources}{agent1}{$field}=undef;
    ok(valid($state,$context),"R1 null $field stays unknown without reference authority");
    ok(!defined(cp($state,$context)->{recovery_sources}{agent1}{$field}),"null $field never becomes an invented scoped reference");
}
my $null_component=clone($projected); $null_component->{recovery_sources}{agent1}{label_refs}{slug}=undef;
ok(valid($null_component,$context),'null component reference preserves R1 unknown/no-authority semantics');
ok(!defined(cp($null_component,$context)->{recovery_sources}{agent1}{label_refs}{slug}),'null component never becomes a fabricated label');
my $schema=Loomy::ContentPolicy::checkpoint_schema();
is_deeply([sort keys %{$projected->{files}{$source}}],[sort keys %{$schema->{objects}{source_state}{fields}}],'fixture covers every permitted source-state constructor key');
is_deeply([sort keys %$projected],[sort keys %{$schema->{objects}{checkpoint}{fields}}],'fixture covers every top-level checkpoint key');
$schema->{objects}{source_state}{fields}{prompt}='native_id'; $schema->{domains}{role}[0]='MUTATED';
ok(!exists(Loomy::ContentPolicy::checkpoint_schema()->{objects}{source_state}{fields}{prompt}),'public schema is detached from caller mutation');

for my $case (
    ['unknown top-level',sub {$_[0]{extension}={prompt=>'PRIVATE_NESTED'}}],
    ['unknown source object',sub {$_[0]{files}{$source}{extension}={prompt=>'PRIVATE_NESTED'}}],
    ['unknown metadata',sub {$_[0]{files}{$source}{meta}{summary}='PRIVATE_NESTED'}],
    ['unknown context',sub {$_[0]{files}{$source}{context}{raw}='PRIVATE_NESTED'}],
    ['unknown journal cursor',sub {$_[0]{journal}{extension}='PRIVATE_NESTED'}],
    ['unknown session',sub {$_[0]{sessions}{session1}{extension}='PRIVATE_NESTED'}],
    ['unknown call',sub {$_[0]{sessions}{session1}{calls}{call1}{extension}='PRIVATE_NESTED'}],
    ['unknown terminal',sub {$_[0]{sessions}{session1}{stops}{child1}{raw}='PRIVATE_NESTED'}],
    ['unknown owner',sub {$_[0]{owners}{"42:$stamp"}{raw}='PRIVATE_NESTED'}],
    ['unknown owner-lead member',sub {$_[0]{owner_leads}{"42:$stamp"}{raw}='PRIVATE_NESTED'}],
    ['unknown root snapshot',sub {$_[0]{root_snapshots}{agent1}{raw}='PRIVATE_NESTED'}],
    ['unknown repair',sub {$_[0]{repair}{'cn:agent1:turn1'}{raw}='PRIVATE_NESTED'}],
    ['unknown recovery event',sub {$_[0]{recovery_sources}{agent1}{raw}={prompt=>'PRIVATE_NESTED'}}],
    ['wrong scoped project',sub {$_[0]{recovery_sources}{agent1}{label_ref}{project_id}='p'.('f'x64)}],
    ['unknown label component',sub {$_[0]{recovery_sources}{agent1}{label_refs}{summary}=clone($ref)}],
    ['unknown scoped field',sub {$_[0]{recovery_sources}{agent1}{label_refs}{slug}{text}='PRIVATE_NESTED'}],
    ['missing scoped attempt',sub {delete $_[0]{recovery_sources}{agent1}{label_ref}{attempt_id}}],
    ['untyped owner lead',sub {$_[0]{owner_leads}{"42:$stamp"}='agent1'}],
    ['metadata protocol object',sub {$_[0]{files}{$source}{projected_metadata}={raw=>'PRIVATE_NESTED'}}],
    ['invalid role object',sub {$_[0]{files}{$source}{meta}{role}={raw=>'PRIVATE_NESTED'}}],
    ['invalid stat tuple',sub {$_[0]{files}{$source}{probe_sig}='1:2:120:PRIVATE_NESTED'}],
    ['negative source offset',sub {$_[0]{files}{$source}{offset}=-1}],
    ['unsafe integer cursor',sub {$_[0]{files}{$source}{v2_window}='9007199254740992'}],
    ['probe encoded JSON',sub {$_[0]{files}{$source}{model_probe}='{"prompt":"PRIVATE_NESTED"}'}],
    ['activity text',sub {$_[0]{files}{$source}{emitted_activity}='cn:agent1:turn1:private model:max:waiting:a2'}],
    ['activity unknown suffix',sub {$_[0]{files}{$source}{emitted_activity}='cn:agent1:turn1:gpt-6:max:waiting:a3'}],
    ['oversize starts',sub {$_[0]{files}{$source}{starts}=[(1)x4097]}],
    ['unknown starts object',sub {$_[0]{files}{$source}{starts}=[{prompt=>'PRIVATE_NESTED'}]}],
    ['unknown starts null',sub {$_[0]{files}{$source}{starts}=[undef]}],
    ['negative epoch',sub {$_[0]{files}{$source}{tail_at}=-1}],
    ['encoded window',sub {$_[0]{files}{$source}{v2_window}='["PRIVATE_NESTED"]'}],
    ['untyped seen key',sub {$_[0]{seen}{'PRIVATE KEY'}=1}],
    ['untyped sent key',sub {$_[0]{sent}{'{"prompt":"PRIVATE_NESTED"}'}='1'}],
    ['untyped owner key',sub {$_[0]{owners}{'42:PRIVATE_NESTED'}={pid=>42}}],
    ['unknown shard',sub {$_[0]{source_shards}=['files-PRIVATE_NESTED']}],
    ['duplicate shard',sub {$_[0]{source_shards}=[('files-'.('a'x64))x2]}],
    ['unknown container',sub {$_[0]{version}=3}],
) {
    my ($name,$mutate)=@$case; my $bad=clone($projected); $mutate->($bad);
    denied("$name fails projection",sub {cp($bad,$context)});
    denied("$name fails strict validation",sub {valid($bad,$context)});
}
for my $locator ('/synthetic-provider/sessions-other/leak.jsonl','/synthetic-provider/sessions/../private.jsonl',
    '/synthetic-provider/sessions/./source.jsonl','/synthetic-provider/sessions//source.jsonl',"/synthetic-provider/sessions/source\n.jsonl",'/synthetic-provider/sessions/') {
    my $bad=clone($projected); $bad->{files}{$locator}=delete $bad->{files}{$source};
    denied('unapproved/traversal/control source locator is rejected',sub {cp($bad,$context)});
}
my $missing=cp({files=>{$source=>{meta=>{id=>'missing'}}}},$context);
is($missing->{files}{$source}{meta}{id},'missing','missing source locator remains representable without filesystem discovery');
for my $bytes_form (0,1) {
    my $root='/synthetic-provider/日本語'; my $path="$root/源.jsonl";
    my $unicode_context={%$context,source_roots=>[$bytes_form ? encode('UTF-8',$root) : $root]};
    my $state=cp({files=>{($bytes_form ? encode('UTF-8',$path) : $path)=>{meta=>{id=>'unicode'}}}},$unicode_context);
    ok(exists($state->{files}{$path}),$bytes_form ? 'filesystem UTF8 bytes normalize to canonical Unicode locator' : 'Unicode source locator is preserved');
}
my $long=clone($projected); my $long_id='cn:'.('a'x100).':'.('b'x100);
$long->{files}{$source}{id}=$long_id;
$long->{files}{$source}{model}='openai/model:variant';
$long->{files}{$source}{emitted_activity}="$long_id:openai/model:variant:max:waiting:a2";
ok(valid(cp($long,$context),$context),'maximum native ID components plus namespaced model preserve exact activity tuple');
for my $agent_type ('Explore','Plan','general-purpose','custom-agent','a'x40) {
    my $state=clone($projected); @{$state->{sessions}{session1}{calls}{call1}}{qw(role agent_type)}=($agent_type,$agent_type);
    is(cp($state,$context)->{sessions}{session1}{calls}{call1}{role},$agent_type,'approved bounded Claude agent type survives');
}
for my $agent_type ('a'x41,'private role prose','../agent','日本語',"Explore\n") {
    my $state=clone($projected); @{$state->{sessions}{session1}{calls}{call1}}{qw(role agent_type)}=($agent_type,$agent_type);
    denied('unapproved Claude agent type fails closed',sub {cp($state,$context)});
}
my $custom=clone($projected); $custom->{files}{$source}{meta}{role}='linguistique';
is(cp($custom,$context)->{files}{$source}{meta}{role},'unknown','legacy custom Codex role adopts existing generic enum fallback');
denied('strict generations reject raw custom Codex role',sub {valid($custom,$context)});
for my $name ('unknown_key','nested_object','wrong_scope') {
    my $body={session=>'session1',role=>'Explore',model=>'',effort=>'',task=>'PRIVATE_SIGNATURE'};
    $body->{extension}={prompt=>'PRIVATE_SIGNATURE'} if $name eq 'unknown_key';
    $body->{model}={prompt=>'PRIVATE_SIGNATURE'} if $name eq 'nested_object';
    $body->{label_ref}={%$ref,project_id=>'p'.('f'x64)} if $name eq 'wrong_scope';
    denied('unknown nested serialized signature cannot be hashed as permission',sub {Loomy::ContentPolicy::checkpoint_signature('context:cl:session1:call1',$json->encode($body),$context)});
}
my $signature_a=Loomy::ContentPolicy::checkpoint_signature('context:cl:session1:call1',{session=>'session1',model=>'',effort=>'',role=>'Explore',task=>'PRIVATE_A'},$context);
my $signature_b=Loomy::ContentPolicy::checkpoint_signature('context:cl:session1:call1',{session=>'session1',model=>'',effort=>'',role=>'Explore',task=>'PRIVATE_B'},$context);
is($signature_a,$signature_b,'discarded task text never influences structural signature digest');
denied('strict generation rejects serialized old body',sub {my $bad=clone($projected); $bad->{sent}{'context:cl:session1:call1'}='{"session":"session1"}'; valid($bad,$context)});

# Constructor-backed evidence: run the real collectors over small synthetic v2
# and Claude sources. Their existing legacy writes stay inside this fixture.
require "$repo/scripts/lib/codex-native.pl";
require "$repo/scripts/lib/claude-native.pl";
my $now=1793102400; local $ENV{LOOMY_NATIVE_NOW}=$now;
sub ts {strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now+($_[0]//0)))}
sub rows {my $path=shift; $path =~ m{\A(.+)/[^/]+\z} or die; make_path($1,{mode=>0700}); put($path,join('',map {$json->encode($_)."\n"} @_))}
my $native=project('native-codex',1,{label_sources=>Loomy::ContentPolicy::recommended_sources()});
my $sessions="$work/native-sessions"; make_path("$native/src",$sessions,{mode=>0700});
Loomy::LiveState::journal_append("$native/.loomy/logs/events.jsonl",{type=>'session',event=>'start',tool=>'codex',pid=>0+$$,ts=>ts(-100)},ts(-100));
my $native_dir="$sessions/2026/10/27";
for my $n (1,2) {
    my $id="node$n";
    rows("$native_dir/rollout-$id.jsonl",
        {type=>'session_meta',timestamp=>ts(-600),payload=>{id=>$id,cwd=>$native,timestamp=>ts(-600),source=>$n==1 ? 'cli' : {subagent=>{thread_spawn=>{parent_thread_id=>'node1'}}},
            history_mode=>'paginated',multi_agent_version=>'v2',($n==2 ? (parent_thread_id=>'node1') : ()),agent_role=>$n==1 ? '' : 'linguistique',agent_nickname=>'Lyra',agent_path=>'/root/inventory',runtime_workspace_roots=>["$native/src"]}},
        {type=>'event_msg',timestamp=>ts(-50),payload=>{type=>'task_started',turn_id=>"turn$n"}},
        {type=>'turn_context',timestamp=>ts(-49),payload=>{turn_id=>"turn$n",model=>'gpt-6.2-sol',effort=>'max'}},
        {type=>'response_item',timestamp=>ts(-48),payload=>{type=>'function_call',name=>'wait_agent',call_id=>"wait$n",arguments=>'PRIVATE_NATIVE_ARGUMENT'}},
        {type=>'world_state',timestamp=>ts(-47),payload=>{padding=>'x'x300000}},
        {type=>'token_usage_record',timestamp=>ts(-1),payload=>{turn_id=>"turn$n",thread_id=>$id}});
}
my $native_state;
$native_state=Loomy::CodexNative::poll($native,$sessions) for 1..4;
ok(ref($native_state) eq 'HASH' && keys(%{$native_state->{files}//{}})==2,'real Codex collector produced synthetic v2 state');
my $native_context={project_id=>$project_id,source_roots=>[$sessions],workspace_roots=>[$native],policy_generation=>0};
my $native_projected=cp($native_state,$native_context);
ok(valid($native_projected,$native_context),'real v2 constructor state projects and validates recursively');
is_deeply({map {$_=>$native_projected->{files}{$_}{offset}} keys %{$native_projected->{files}}},
    {map {$_=>$native_state->{files}{$_}{offset}} keys %{$native_state->{files}}},'all actual Codex consumption offsets survive projection');
ok(grep({exists($_->{probe_sig}) && ref($_->{starts}) eq 'ARRAY'} values %{$native_state->{files}}),'actual owner-binding probe_sig/starts branch exercised');
ok(grep({exists($_->{v2_window})} values %{$native_state->{files}}),'actual paginated v2_window constructor exercised');
ok(grep({$_->{meta}{role} eq 'unknown'} values %{$native_projected->{files}}),'actual custom/empty Codex metadata roles become existing structural unknown fallback');
open my $native_journal,'<',"$native/.loomy/logs/events.jsonl" or die;
my @native_events=map {$json->decode($_)} <$native_journal>; close $native_journal;
my ($native_refs)=grep {exists $_->{label_refs}} @native_events;
ok($native_refs && keys(%{$native_refs->{label_refs}})==3,'actual native events reference all three granted label components');
if ($native_refs) {
    my $recover=cp({recovery_sources=>{node2=>$native_refs}},$native_context);
    is_deeply($recover->{recovery_sources}{node2}{label_refs},$native_refs->{label_refs},'actual native scoped refs survive recovery-event projection');
}

my $claude=project('native-claude',1,{label_sources=>'claude-description'});
my $projects="$work/native-projects"; my $slug=$claude; $slug =~ s/[^A-Za-z0-9]/-/g;
my $claude_path="$projects/$slug/claude-session.jsonl";
rows($claude_path,
    {type=>'user',timestamp=>ts(-10),sessionId=>'claude-session',cwd=>$claude,entrypoint=>'cli',message=>{content=>'PRIVATE_CLAUDE_PROMPT'}},
    {type=>'assistant',timestamp=>ts(-9),sessionId=>'claude-session',cwd=>$claude,entrypoint=>'cli',effort=>'high',message=>{model=>'claude-sonnet-5-5',content=>[
        {type=>'tool_use',name=>'Agent',id=>'call1',input=>{subagent_type=>'Explore',description=>'Synthetic title',prompt=>'PRIVATE_CLAUDE_TASK',run_in_background=>JSON::PP::true}}]}},
    {type=>'user',timestamp=>ts(-8),sessionId=>'claude-session',cwd=>$claude,toolUseResult=>{agentId=>'child1',status=>'async_launched'},message=>{content=>[{type=>'tool_result',tool_use_id=>'call1',content=>'PRIVATE_CLAUDE_RESULT'}]}});
my $claude_state=Loomy::ClaudeNative::poll($claude,$projects);
ok(ref($claude_state) eq 'HASH' && exists $claude_state->{sessions}{'claude-session'}{calls}{call1},'real Claude collector produced call/session state');
my $claude_context={project_id=>$project_id,source_roots=>[$projects],workspace_roots=>[$claude],policy_generation=>0};
my $claude_projected=cp($claude_state,$claude_context);
ok(valid($claude_projected,$claude_context),'real Claude constructor state projects and validates recursively');
is($claude_projected->{sessions}{'claude-session'}{calls}{call1}{role},'Explore','actual Claude built-in agent type is preserved');
for my $key (sort keys %{$claude_state->{sent}}) {
    my $type=$key =~ /^start:/ ? 'delegation_start' : $key =~ /^end:/ ? 'delegation' : $key =~ /^alias:/ ? 'agent_alias'
        : $key =~ /^context:cl:/ ? 'delegation_activity' : $key =~ /^context:/ ? 'session_context' : 'session_observed';
    my $r1=Loomy::LiveState::content_signature({policy=>{project_id=>$project_id}},$type,$claude_state->{sent}{$key});
    is($claude_projected->{sent}{$key},$r1,'actual Claude sent signature matches existing R1 replay/emit canonicalization');
}
is(Loomy::ContentPolicy::checkpoint_signature('context:cl:session1:call1',{session=>'session1',model=>'',effort=>'',role=>'Explore',task=>'PRIVATE_A'},$context),
    Loomy::LiveState::content_signature({policy=>{project_id=>$project_id}},'delegation_activity',{session=>'session1',model=>'',effort=>'',role=>'Explore',task=>'PRIVATE_A'}),
    'empty models and Claude role aliases match R1 structural signature semantics');

# The existing public allowlist drift gate stays the gate. No checkpoint key is
# an excuse to add an event permission; mutations hit the real loader/digest.
my $allow_path="$repo/scripts/lib/content-allowlist.tsv"; my $allow_raw=bytes($allow_path);
my $allow=Loomy::ContentPolicy::check_allowlist($allow_path);
is(scalar(grep {!m{/}} keys %$allow),23,'existing 23 journal producer types remain the public permission set');
ok($allow->{delegation_start}{label_refs} eq 'keep' && $allow->{delegation_start}{agent_type} eq 'keep','reviewed R1 scoped-component/type rows already exist');
my @mutations=($allow_raw."usage\tunknown_key\tkeep\n",$allow_raw,$allow_raw,$allow_raw."novel_type\tid\tkeep\n");
$mutations[1]=~s/usage\tcost_usd\tkeep\n//; $mutations[2]=~s/request\texcerpt\tomit/request\texcerpt\tkeep/;
for my $i (0..$#mutations) {my $path="$work/allowlist-$i.tsv"; put($path,$mutations[$i]);
    ok(!eval {Loomy::ContentPolicy::check_allowlist($path); 1},'public allowlist drift mutation fails the runtime loader');
    is($@,"content allowlist drift\n",'allowlist mutation diagnostic contains no supplied content');
}
my $admission=Loomy::ContentPolicy::collector_admission_contract();
is($admission->{callable},'Loomy::CollectorContent::admit(request, lock_attestation)','future collector callable/signature is frozen');
is_deeply($admission->{result}{fields}{decision},[qw(admitted refused hold)],'collector outcomes form a closed protocol');
is_deeply($admission->{request}{required},[qw(protocol_version project_id requester_pid requester_birth policy_generation journal_enabled tasks_restricted)],'collector request freezes project/process/restriction identity');
like($admission->{rules}{default},qr/hold; no effects/,'no attestation defaults to hold before effects');
ok(!defined(&Loomy::CollectorContent::admit),'contract does not claim to implement LOCK or collector admission');
$admission->{result}{fields}{decision}[0]='MUTATED';
is(Loomy::ContentPolicy::collector_admission_contract()->{result}{fields}{decision}[0],'admitted','collector descriptor is detached');

done_testing();

# Hermetic LOCK-L0 path and public-reader contracts. Synthetic sources only.
use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:mode F_GETFD FD_CLOEXEC);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);
use Test::More;
use Time::HiRes ();

my ($repo,$requested)=@ARGV;
$repo=abs_path($repo//'') or die "repository required\n";
my $work=$requested // tempdir('loomy-runtime-readers-XXXXXX',TMPDIR=>1,CLEANUP=>1);
die "fixture directory already populated\n" if -e $work && do {
    opendir my $d,$work or die; scalar grep {!/^\.{1,2}$/} readdir $d
};
umask 0077;
make_path($work,{mode=>0700}); $work=abs_path($work) or die;
for my $pair ([HOME=>'home'],[XDG_CONFIG_HOME=>'config'],[XDG_STATE_HOME=>'state'],
    [XDG_CACHE_HOME=>'cache'],[XDG_RUNTIME_DIR=>'runtime'],[TMPDIR=>'tmp'],
    [CODEX_HOME=>'codex'],[CLAUDE_CONFIG_DIR=>'claude']) {
    $ENV{$pair->[0]}="$work/$pair->[1]";
    make_path($ENV{$pair->[0]},{mode=>0700});
}
delete @ENV{grep {/\AGIT_/} keys %ENV};
delete @ENV{qw(BASH_ENV ENV LOOMY_JOURNAL_CONTENT LOOMY_CONTENT_PROJECT LOOMY_PROJECT_ROOT LOOMY_HOOK_CONTEXT)};
$ENV{LOOMY_JOURNAL}=1; $ENV{LOOMY_JOURNAL_TASKS}=1; $ENV{LOOMY_CLI_MANAGED}=1;
$ENV{LOOMY_LANG}='en'; $ENV{LOOMY_UI_LANG}='en'; $ENV{LOOMY_HOME}=$repo;
$ENV{LOOMY_NO_AUTOUPDATE}=1; $ENV{LOOMY_CATALOG_CHECK}=0;
$ENV{GIT_CONFIG_NOSYSTEM}=1; $ENV{GIT_TERMINAL_PROMPT}=0;
$ENV{PATH}='/usr/bin:/bin:/usr/sbin:/sbin';
my $json=JSON::PP->new->utf8->canonical;
require "$repo/scripts/lib/runtime-paths.pl";
require "$repo/scripts/lib/content-policy.pl";

my $project_id='p'.('a'x64);
my $other_id='p'.('b'x64);
my $stamp='2026-11-11T12:00:00Z';
my $label={version=>1,project_id=>$project_id,target_kind=>'agent',target_id=>'reader-agent',
    attempt_id=>'reader-attempt',label_id=>'reader-label',text=>'Existing scoped label',
    source=>'explicit-lead',created_at=>$stamp,supersedes=>''};
my $ref={map {$_=>$label->{$_}} qw(version project_id target_kind target_id attempt_id label_id)};

sub put {
    my ($path,$raw,$mode)=@_; open my $h,'>',$path or die "fixture write failed\n";
    binmode $h; print {$h} $raw or die; close $h or die;
    chmod($mode//0600,$path) or die;
}
sub bytes {open my $h,'<',$_[0] or die; binmode $h; local $/; return <$h>}
sub project {
    my ($name,$identity,$grant)=@_; my $root="$work/$name";
    make_path("$root/.loomy/logs",{mode=>0700});
    put("$root/.loomy/project-id","$project_id\n") if $identity;
    conf($root) if $grant;
    return $root;
}
sub conf {
    my ($root,%extra)=@_;
    put("$root/.loomy/logs/content-policy.conf",policy_bytes(%extra));
}
sub policy_bytes {
    my (%extra)=@_;
    my $p={%{Loomy::ContentPolicy::defaults()},journal_content=>'legacy-excerpts',
        label_sources=>'explicit-lead',private_results=>'on',grant_prompt_version=>1,
        policy_generation=>12,%extra};
    return join('',map {"$_=$p->{$_}\n"} sort keys %$p);
}
sub labels {put("$_[0]/.loomy/logs/display-context-v1.jsonl",$json->encode($label)."\n")}
sub full {put("$_[0]/.loomy/logs/display-context-full","display context full; label not saved\n")}
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
    my ($name,$root,$code)=@_; my $before=manifest($root); my ($value,$error);
    my $ok=eval {$value=$code->(); 1}; $error=$@;
    is_deeply(manifest($root),$before,"$name preserves names, inodes, modes, ownership, timestamps and hashes");
    die $error unless $ok;
    return $value;
}
sub denied {
    my ($name,$code)=@_; my $ok=eval {$code->(); 1};
    ok(!$ok,$name);
}
sub closed {
    my ($p,$name)=@_;
    is_deeply([@$p{qw(journal_content label_sources private_results)}],
        ['structural','none','off'],"$name closes every content grant");
    ok(!defined($p->{project_id}),"$name supplies no invented project identity");
    is($p->{valid},0,"$name reports the unavailable grant as invalid");
    is($p->{journal_enabled},0,"$name cannot authorize collection");
}
sub compatible {
    my ($p,$id,$name,$grant)=@_;
    is($p->{project_id},$id,"$name uses the expected transient or stored namespace");
    is($p->{valid},1,"$name retains valid R1 policy semantics");
    is($p->{journal_enabled},1,"$name preserves enabled journal collection");
    is_deeply([@$p{qw(journal_content label_sources private_results policy_generation)}],
        $grant ? ['legacy-excerpts','explicit-lead','on',12] : ['structural','none','off',0],
        "$name retains the existing grants and generation");
}
sub no_exports {
    my ($root,$name)=@_;
    readonly("$name strict export refusal",$work,sub {
        for my $mode (qw(structural legacy-excerpts)) {
            my $ok=eval {Loomy::ContentPolicy::export_policy_snapshot($root,$mode); 1};
            my $error=$@;
            ok(!$ok,"$name cannot export $mode without an attested identity");
            is($error,"content export grant unavailable\n","$name $mode export uses the fixed grant refusal");
        }
    });
}
sub stored_grant {
    my ($loaded,$name)=@_;
    is_deeply([sort keys %$loaded],[qw(policy source stat valid)],"$name retains the stored-policy result shape");
    is($loaded->{valid},1,"$name reports valid stored syntax without attesting identity");
    is($loaded->{source},'project',"$name retains the stored project origin");
    is_deeply([@{$loaded->{policy}}{qw(journal_content label_sources private_results policy_generation)}],
        ['legacy-excerpts','explicit-lead','on',12],"$name retains stored grant diagnostics");
    ok(!exists($loaded->{project_id}) && !exists($loaded->{policy}{project_id}),"$name never derives a project identity");
}
sub command {
    my (@args)=@_; my $error=gensym();
    my $pid=open3(undef,my $out,$error,@args);
    my $raw=do {local $/; <$out>}//'';
    my $errors=do {local $/; <$error>}//'';
    waitpid($pid,0)==$pid or die "fixture child wait failed\n";
    return ($?,$raw,$errors);
}
sub hint {
    my ($root)=@_; local $ENV{LOOMY_CONTENT_UI_HINT}='labels need consent';
    local $ENV{LOOMY_CONTENT_UI_LABEL_FULL}='label store full';
    return command($^X,"$repo/scripts/lib/content-policy.pl",'hint',$root);
}
sub shell_hint {
    my ($root)=@_;
    return command('/bin/bash','-c',
        't() { :; }; tv() { printf -v "$1" "%s" "$2"; }; source "$1"; '
        .'_loomy_content_ui() { exit 98; }; _loomy_content_hint_load "$2"; '
        .'loomy_content_hint_refresh "$2" "$LOOMY_CONTENT_HINT_SIGNATURE"; '
        .'printf "C|%s\n%s\n" "$LOOMY_CONTENT_HINT_SIGNATURE" "$LOOMY_CONTENT_HINT"',
        'runtime-hint',"$repo/scripts/lib/content-policy.sh",$root);
}
sub reader_probe {
    my ($root,$name)=@_; my %value;
    for my $api (qw(policy_snapshot load_policy effective_policy label_health)) {
        no strict 'refs';
        $value{$api}=readonly("$name $api",$work,sub {&{"Loomy::ContentPolicy::$api"}($root)});
    }
    readonly("$name explicit snapshot modes",$work,sub {
        is_deeply(Loomy::ContentPolicy::policy_snapshot($root,'strict'),$value{policy_snapshot},
            "$name default snapshot mode is strict");
        is_deeply(Loomy::ContentPolicy::policy_snapshot($root,'effective'),$value{effective_policy},
            "$name explicit effective snapshot matches the R1 reader");
    });
    $value{label}=readonly("$name resolve_label",$work,sub {Loomy::ContentPolicy::resolve_label($root,$ref)});
    readonly("$name actual hint command",$work,sub {
        my ($status,$raw,$errors)=hint($root);
        is($status,0,"$name actual hint succeeds without prompting");
        is($errors,'',"$name actual hint has no diagnostics");
        $value{hint}=$raw;
    });
    return \%value;
}
sub git {
    my ($root,@args)=@_;
    system('git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false',
        '-c','user.name=test','-c','user.email=test@example.invalid','-C',$root,@args)==0
        or die "fixture Git setup failed\n";
}
sub repository {
    my ($root)=@_; make_path($root,{mode=>0700});
    git($root,'init','-q','-b','main');
    git($root,'commit','-q','--allow-empty','-m','fixture');
}
sub worktree {
    my ($owner,$name)=@_; my $root="$work/$name";
    git($owner,'worktree','add','-q','-b',$name,$root); return $root;
}
sub context {
    my ($root,$owner,$name,$private_group)=@_;
    my $c=readonly("$name resolve",$work,sub {Loomy::RuntimePaths::resolve($root,$private_group)});
    is($c->{root},$owner,"$name canonical owner root");
    is($c->{requested_root},$root,"$name requested root retained");
    ok(!exists($c->{project_id}),"$name path resolution does not allocate content identity");
    readonly("$name pinned assertion",$work,sub {is(Loomy::RuntimePaths::assert_current($c),1,"$name context remains current")});
    return $c;
}
sub scopes {
    my ($c,$roots,$name)=@_;
    my $scope=readonly("$name scope set",$work,sub {Loomy::RuntimePaths::scope_set($c)});
    is_deeply($scope->{roots},[sort @$roots],"$name contains exactly the sorted validated sources");
    like($scope->{revision},qr/\A[0-9a-f]{64}\z/,"$name has a SHA-256 revision");
    return $scope;
}

# Missing runtime state is a legitimate reader result, never a bootstrap request.
my $bare="$work/no-loomy"; make_path($bare,{mode=>0700});
my $bare_ctx=context($bare,$bare,'absent .loomy');
ok(!$bare_ctx->{loomy} && !$bare_ctx->{logs} && !$bare_ctx->{ls} && !$bare_ctx->{ds},
    'absent .loomy has no directory handles or invented stat identity');
my $bare_read=reader_probe($bare,'absent .loomy');
is($bare_read->{policy_snapshot}{identity_state},'missing','absent .loomy snapshot identity is missing');
closed($bare_read->{policy_snapshot},'absent .loomy snapshot');
closed($bare_read->{effective_policy},'absent .loomy effective policy');
no_exports($bare,'absent .loomy');
ok(!-e "$bare/.loomy",'all public readers leave absent .loomy absent');

my $no_logs="$work/no-logs"; make_path("$no_logs/.loomy",{mode=>0700});
my $no_logs_ctx=context($no_logs,$no_logs,'absent logs');
ok($no_logs_ctx->{loomy} && $no_logs_ctx->{ls} && !$no_logs_ctx->{logs} && !$no_logs_ctx->{ds},
    'absent logs retains only the pinned existing .loomy');
my $no_logs_read=reader_probe($no_logs,'absent logs');
is($no_logs_read->{policy_snapshot}{identity_state},'missing','absent logs snapshot identity is missing');
closed($no_logs_read->{policy_snapshot},'absent logs strict snapshot');
compatible($no_logs_read->{effective_policy},'p'.sha256_hex($no_logs),'absent logs effective policy',0);
is($no_logs_read->{effective_policy}{identity_state},'missing','a computed namespace does not attest an absent identity file');
no_exports($no_logs,'absent logs');
is_deeply($no_logs_read->{load_policy},{policy=>Loomy::ContentPolicy::defaults(),source=>'default',valid=>1,stat=>[]},
    'absent logs retains the baseline stored-policy preflight without an identity');
ok(!-e "$no_logs/.loomy/logs" && !-e "$no_logs/.loomy/project-id",'readers create neither logs nor project-id');

my $no_id=project('no-identity',0,1); full($no_id);
my $no_id_ctx=context($no_id,$no_id,'logs without project-id');
ok($no_id_ctx->{logs} && $no_id_ctx->{ds},'existing logs is pinned without an identity');
my $no_id_read=reader_probe($no_id,'logs without project-id');
is($no_id_read->{policy_snapshot}{identity_state},'missing','project-id absence remains explicit');
closed($no_id_read->{policy_snapshot},'absent identity snapshot');
compatible($no_id_read->{effective_policy},'p'.sha256_hex($no_id),'absent identity effective policy',1);
is($no_id_read->{effective_policy}{identity_state},'missing','R1 fallback preserves missing-identity evidence');
stored_grant($no_id_read->{load_policy},'absent identity policy load');
no_exports($no_id,'absent identity');
ok(!defined($no_id_read->{label}),'no label is invented without evidence');
is($no_id_read->{label_health},'full','existing full-store hint survives absent identity');
like($no_id_read->{hint},qr/^label store full\n/m,'actual hint retains full-store notice without identity');
unlike($no_id_read->{hint},qr/^labels need consent\n/m,'actual hint preserves the existing acknowledged grant');
readonly('Bash C| hint without identity',$work,sub {
    my ($status,$raw,$errors)=shell_hint($no_id);
    is($status,0,'Bash hint API succeeds without loading the full UI');
    is($errors,'','Bash hint API emits no diagnostics');
    like($raw,qr/\AC\|[0-9.]+\|[0-9.]+\n/,'Bash hint retains its actual C| mtime signature');
    like($raw,qr/display context full; label not saved/,'Bash hint retains existing health text');
    unlike($raw,qr/Task labels off/,'Bash hint does not discard the existing label grant');
});
ok(!-e "$no_id/.loomy/project-id",'actual Perl and Bash hint APIs never pin the missing identity');

my $identified=project('identified',1,1); labels($identified); full($identified);
my $identified_read=reader_probe($identified,'existing identity');
is($identified_read->{policy_snapshot}{identity_state},'present','existing identity is explicit');
is($identified_read->{effective_policy}{project_id},$project_id,'effective policy retains the existing identity exactly');
compatible($identified_read->{effective_policy},$project_id,'existing identity effective policy',1);
is($identified_read->{load_policy}{policy}{policy_generation},12,'policy load retains existing generation');
is($identified_read->{label}{text},$label->{text},'valid existing label retains its scoped display text');
is($identified_read->{label_health},'full','existing label health is readable');
readonly('attested identity export',$work,sub {
    my $p=Loomy::ContentPolicy::export_policy_snapshot($identified,'legacy-excerpts');
    is($p->{identity_state},'present','strict export accepts the existing attested identity');
    is($p->{project_id},$project_id,'strict export retains the exact stored namespace');
    is($p->{policy_generation},12,'strict export retains the stored generation');
});

# R1 consumes validated legacy recovery evidence transiently; strict export
# snapshots still require an actual project-id file.
my $legacy=project('legacy-label-no-identity',0,1); labels($legacy); full($legacy);
my $legacy_read=reader_probe($legacy,'legacy label without identity');
is($legacy_read->{policy_snapshot}{identity_state},'missing','legacy evidence cannot make the snapshot identity present');
closed($legacy_read->{policy_snapshot},'legacy evidence snapshot');
compatible($legacy_read->{effective_policy},$project_id,'legacy evidence effective policy',1);
is($legacy_read->{effective_policy}{identity_state},'missing','legacy recovery does not attest a stored identity');
stored_grant($legacy_read->{load_policy},'legacy evidence policy load');
no_exports($legacy,'legacy evidence');
is_deeply($legacy_read->{label},$label,'validated legacy label resolves with transient recovery identity');
is($legacy_read->{label_health},'full','legacy label health survives identity absence');
readonly('legacy scope rejection',$work,sub {
    my %wrong=(%$ref,project_id=>$other_id);
    ok(!Loomy::ContentPolicy::resolve_label($legacy,\%wrong),'legacy recovery does not broaden the exact project scope');
});
ok(!-e "$legacy/.loomy/project-id",'legacy compatibility reads do not persist recovered identity');

my $invalid_legacy=project('invalid-legacy-label',0,1);
put("$invalid_legacy/.loomy/logs/display-context-v1.jsonl",$json->encode({%$label,unexpected=>'untrusted'})."\n");
readonly('invalid legacy recovery evidence',$work,sub {
    ok(!Loomy::ContentPolicy::resolve_label($invalid_legacy,$ref),'schema-invalid legacy evidence cannot recover an identity');
    is(Loomy::ContentPolicy::policy_snapshot($invalid_legacy)->{identity_state},'missing','invalid legacy evidence leaves identity missing');
    compatible(Loomy::ContentPolicy::effective_policy($invalid_legacy),'p'.sha256_hex($invalid_legacy),
        'invalid legacy evidence path fallback',1);
});

# A malformed or unsafe existing identity must never fall back to valid label
# evidence or a path hash. Every reader leaves the foreign evidence untouched.
for my $kind (qw(empty malformed symlink hardlink mode)) {
    my $invalid=project("invalid-identity-$kind",0,1); labels($invalid);
    my $identity="$invalid/.loomy/project-id";
    my $target="$work/identity-target-$kind";
    if ($kind eq 'symlink' || $kind eq 'hardlink') {
        put($target,"$project_id\n");
        if ($kind eq 'symlink') {symlink $target,$identity or die}
        else {link $target,$identity or die}
    } else {put($identity,$kind eq 'empty' ? '' : $kind eq 'malformed' ? "invalid\n" : "$project_id\n",$kind eq 'mode' ? 0644 : 0600)}
    my $r=reader_probe($invalid,"invalid $kind identity");
    is($r->{policy_snapshot}{identity_state},'invalid',"$kind identity is explicitly invalid");
    closed($r->{policy_snapshot},"$kind identity strict snapshot");
    closed($r->{effective_policy},"$kind identity effective policy");
    ok(!$r->{effective_policy}{valid},"$kind identity cannot preserve an effective content grant");
    is($r->{load_policy}{valid},0,"$kind identity makes the R1 stored-policy reader unavailable");
    is($r->{load_policy}{source},'invalid',"$kind identity does not expose valid stored grant diagnostics");
    ok(!defined($r->{label}),"$kind identity cannot recover a label through a substitute namespace");
    is($r->{label_health},'unavailable',"$kind identity makes the R1 health reader unavailable");
    no_exports($invalid,"$kind identity");
}

# An identity writer may be between O_EXCL and its first durable write. R1's
# effective reader retries that empty file, while strict snapshots never wait
# for identity initialization or derive a fallback from an empty present file.
my $initializing=project('initializing-effective-identity',0,1);
my $initializing_path="$initializing/.loomy/project-id"; put($initializing_path,'');
my $initializing_inode=(stat($initializing_path))[1];
my ($identity_reads,$initialized_manifest)=(0,undef);
my $initializing_policy;
{
    no warnings 'redefine';
    my $read=\&Loomy::ContentPolicy::_read;
    local *Loomy::ContentPolicy::_read=sub {
        my @result=$read->(@_);
        if ($_[0] eq 'project-id' && ++$identity_reads==1) {
            put($initializing_path,"$project_id\n");
            $initialized_manifest=manifest($work);
        }
        return @result;
    };
    $initializing_policy=Loomy::ContentPolicy::effective_policy($initializing);
}
is((stat($initializing_path))[1],$initializing_inode,'concurrent identity initialization fills the same real inode');
cmp_ok($identity_reads,'>=',3,'effective reader retries the initial empty identity before pinning it');
compatible($initializing_policy,$project_id,'concurrently initialized effective identity',1);
is($initializing_policy->{identity_state},'present','completed concurrent initialization supplies present identity evidence');
is_deeply(manifest($work),$initialized_manifest,'effective retry makes no filesystem changes beyond the injected identity writer');

my $strict_initializing=project('initializing-strict-identity',0,1);
put("$strict_initializing/.loomy/project-id",'');
readonly('strict empty identity initialization',$work,sub {
    no warnings 'redefine';
    my $read=\&Loomy::ContentPolicy::_read; my $reads=0;
    local *Loomy::ContentPolicy::_read=sub { $reads++ if $_[0] eq 'project-id'; return $read->(@_) };
    my $p=Loomy::ContentPolicy::policy_snapshot($strict_initializing);
    is($reads,1,'strict snapshot reads an empty existing identity once without initialization retry');
    is($p->{identity_state},'invalid','strict snapshot treats the initial empty identity as invalid');
    closed($p,'strict empty initializing identity');
});

# A successful helper read is not authority if the identity disappears or
# changes before the shared snapshot pins the independently read file.
for my $change (qw(disappeared changed)) {
    my $root=project("identity-between-reads-$change",1,1); labels($root);
    my $path="$root/.loomy/project-id";
    my ($reads,$injected_manifest)=(0,undef); my $p;
    {
        no warnings 'redefine';
        my $read=\&Loomy::ContentPolicy::_read;
        local *Loomy::ContentPolicy::_read=sub {
            my @result=$read->(@_);
            if ($_[0] eq 'project-id' && ++$reads==1) {
                if ($change eq 'disappeared') {unlink $path or die}
                else {put($path,"$other_id\n")}
                $injected_manifest=manifest($work);
            }
            return @result;
        };
        $p=Loomy::ContentPolicy::effective_policy($root);
    }
    cmp_ok($reads,'>=',2,"$change identity is independently re-read after the R1 helper");
    is($p->{identity_state},'invalid',"$change identity invalidates the shared snapshot");
    closed($p,"$change identity between helper and pin");
    is_deeply(manifest($work),$injected_manifest,"$change identity read preserves the injected filesystem evidence");
}
# A concurrent first writer may pin an absent identity while an effective reader
# runs (umask 002 label-store race): accept only the namespace the reader derived.
for my $pin (qw(empty-during-read after-read other-namespace)) {
    my $root=project("concurrent-pin-$pin",0,1); my $path="$root/.loomy/project-id";
    my $derived='p'.sha256_hex($root); my $calls=0; my $p;
    {
        no warnings 'redefine';
        my $read=\&Loomy::ContentPolicy::_read; my $stored=\&Loomy::ContentPolicy::_stored;
        local *Loomy::ContentPolicy::_read=sub {
            if ($_[0] eq 'project-id' && $pin ne 'after-read') {
                $calls++;
                put($path,$pin eq 'other-namespace' ? "$other_id\n" : '') if $calls==1;
                put($path,"$derived\n") if $calls==2 && $pin eq 'empty-during-read';
            }
            return $read->(@_);
        };
        local *Loomy::ContentPolicy::_stored=sub {
            put($path,"$derived\n") if $pin eq 'after-read' && !$calls++;
            return $stored->(@_);
        };
        $p=Loomy::ContentPolicy::effective_policy($root);
    }
    if ($pin eq 'other-namespace') {closed($p,'a concurrent pin of another namespace')}
    else {compatible($p,$derived,"identity pinned concurrently ($pin)",1)}
}
readonly('unsupported identity mode',$work,sub {
    my $ok=eval {Loomy::ContentPolicy::policy_snapshot($identified,'invented'); 1};
    my $error=$@;
    ok(!$ok,'the public snapshot refuses an unsupported identity mode');
    is($error,"invalid content identity mode\n",'unsupported identity mode has a fixed error');
});

# Invalid policy bytes close the grants without changing R1's existing identity
# and journal diagnostics. Strict snapshot/export keeps its narrower boundary.
for my $identity (0,1) {
    my $invalid=project("invalid-policy-$identity",$identity,0); full($invalid);
    put("$invalid/.loomy/logs/content-policy.conf","version=unknown\n");
    readonly("identity=$identity malformed policy inspection",$work,sub {
        my $p=Loomy::ContentPolicy::effective_policy($invalid);
        is($p->{valid},0,"identity=$identity malformed policy remains invalid");
        is($p->{source},'invalid',"identity=$identity malformed policy retains its source diagnostic");
        is($p->{project_id},$identity ? $project_id : 'p'.sha256_hex($invalid),
            "identity=$identity malformed policy retains the existing R1 namespace");
        is($p->{journal_enabled},1,"identity=$identity malformed policy retains the journal diagnostic");
        is_deeply([@$p{qw(journal_content label_sources private_results policy_generation)}],
            ['structural','none','off',0],"identity=$identity malformed policy grants only structural defaults");
        my $strict=Loomy::ContentPolicy::policy_snapshot($invalid);
        is($strict->{journal_enabled},0,"identity=$identity strict malformed-policy snapshot disables collection");
        is($strict->{identity_state},$identity ? 'present' : 'missing',
            "identity=$identity strict malformed-policy snapshot preserves identity evidence");
        is(Loomy::ContentPolicy::label_health($invalid),'full',
            "identity=$identity malformed policy does not hide existing R1 label health");
    });
}

# Retain R1's unlocked-preflight retry. The seam replaces a real inode after
# lstat and before open; no synthetic error substitutes for that filesystem race.
for my $identity (0,1) {
    my $atomic=project("atomic-policy-preflight-$identity",$identity,1);
    conf($atomic,policy_generation=>20);
    my $path="$atomic/.loomy/logs/content-policy.conf";
    my $before=(stat($path))[1];
    my $read_stat=\&Loomy::ContentPolicy::_private_stat;
    my ($swapped,$reads)=(0,0);
    my $p;
    {
        no warnings 'redefine';
        local *Loomy::ContentPolicy::_private_stat=sub {
            my $s=$read_stat->(@_);
            if ($_[0] eq 'content-policy.conf') {
                $reads++;
                unless ($swapped) {
                    put("$atomic/.loomy/logs/replacement",policy_bytes(policy_generation=>21,results_max_records=>199));
                    rename "$atomic/.loomy/logs/replacement",$path or die;
                    $swapped=1;
                }
            }
            return $s;
        };
        $p=Loomy::ContentPolicy::effective_policy($atomic);
    }
    isnt((stat($path))[1],$before,"identity=$identity preflight replaces the actual policy inode");
    cmp_ok($reads,'>=',2,"identity=$identity preflight rereads after the atomic replacement");
    is($p->{policy_generation},21,"identity=$identity reader retries actual inode replacement and sees committed generation");
    is($p->{results_max_records},199,"identity=$identity retried policy includes the committed restriction");
    is($p->{project_id},$identity ? $project_id : 'p'.sha256_hex($atomic),"identity=$identity retry retains the correct R1 namespace");
    is(-e "$atomic/.loomy/project-id" ? 1 : 0,$identity,"identity=$identity preflight does not allocate identity");
}

# A bound human environment may select only an existing grant. Stub ancestry
# evidence locally so this fixture neither depends on its launcher nor probes ps.
{
    no warnings 'redefine';
    local *Loomy::ContentPolicy::_agent_ancestor=sub {0};
    local %ENV=%ENV;
    delete @ENV{grep {/\A(?:LOOMY_(?:DELEGATION|PARENT_ID|CLI|HOOK|BRIDGE|MANAGED|EVENT|ATTEMPT)|CLAUDECODE|CLAUDE_CODE_|CODEX_|BUN\z)/} keys %ENV};
    $ENV{LOOMY_JOURNAL_CONTENT}='legacy-excerpts';
    $ENV{LOOMY_CONTENT_PROJECT}=$no_id;
    readonly('bound environment consumes an existing human grant',$work,sub {
        my $p=Loomy::ContentPolicy::effective_policy($no_id);
        is($p->{journal_content},'legacy-excerpts','bound human environment retains the prior excerpt grant without project-id');
        is($p->{source},'environment','bound human environment retains its R1 policy source');
        is($p->{policy_generation},12,'bound human environment retains the stored generation');
        is($p->{project_id},'p'.sha256_hex($no_id),'bound human grant uses only the transient path namespace');
        closed(Loomy::ContentPolicy::policy_snapshot($no_id),'bound environment strict snapshot');
        $ENV{LOOMY_CONTENT_PROJECT}=$no_logs;
        is(Loomy::ContentPolicy::effective_policy($no_logs)->{journal_content},'structural','a bound environment cannot create consent');
        $ENV{LOOMY_CONTENT_PROJECT}=$no_id;
        $ENV{LOOMY_DELEGATION}=1;
        is(Loomy::ContentPolicy::effective_policy($no_id)->{journal_content},'structural','managed origin still refuses an excerpt environment request');
    });
}

# First-use is an authorized writer. Its stored-policy preflight must remain
# usable when a fresh project has no identity yet; only these local test seams
# supply human answers, and production origin checks are otherwise unchanged.
my $first_use="$work/first-use-writer"; make_path("$first_use/.loomy",{mode=>0700});
readonly('fresh writer stored-policy preflight',$work,sub {
    is_deeply(Loomy::ContentPolicy::load_policy($first_use),
        {policy=>Loomy::ContentPolicy::defaults(),source=>'default',valid=>1,stat=>[]},
        'first-use can inspect valid default policy before identity creation');
});
my (@questions,$used,$use_error);
{
    no warnings qw(redefine once);
    local *Loomy::ContentPolicy::human_tty=sub {1};
    local *Loomy::ContentPolicy::_say=sub {};
    local *Loomy::ContentPolicy::_answer=sub {push @questions,$_[1]; return 1};
    $used=eval {Loomy::ContentPolicy::first_use($first_use)}; $use_error=$@;
}
is($use_error,'','authorized first-use completes with local human test answers');
is($used,1,'fresh first-use performs the writer transaction');
is_deeply(\@questions,[qw(KEEP_LABELS KEEP_RESULTS)],'fresh first-use asks the existing bounded consent sequence');
ok(-f "$first_use/.loomy/project-id",'authorized first-use stores the identity outside Git');
is((stat("$first_use/.loomy/project-id"))[2]&0777,0600,'first-use identity stays private');
is((stat("$first_use/.loomy/logs"))[2]&0777,0700,'first-use runtime directory stays private');
readonly('first-use result inspection',$work,sub {
    my $p=Loomy::ContentPolicy::policy_snapshot($first_use);
    is($p->{identity_state},'present','first-use writer identity is visible to pure readers');
    is($p->{label_sources},Loomy::ContentPolicy::recommended_sources(),'first-use stores the confirmed label grant');
    is($p->{private_results},'on','first-use stores the confirmed private-results grant');
    is($p->{grant_prompt_version},1,'first-use acknowledges the existing grant prompt version');
});

# R1 deliberately keeps an unpinned namespace where Git does not ignore
# project-id. A writer can consume its existing grant and validated legacy ID
# without storing a new identity or making the public snapshot authoritative.
my $legacy_writer=project('legacy-writer-unignored',0,1); labels($legacy_writer); repository($legacy_writer);
ok(!Loomy::ContentPolicy::_identity_ignorable($legacy_writer),'writer fixture cannot persist project-id in its unignored Git root');
my $policy_before=bytes("$legacy_writer/.loomy/logs/content-policy.conf");
my $saved=eval {Loomy::ContentPolicy::save_label($legacy_writer,{project_id=>$project_id,
    target_kind=>'agent',target_id=>'writer-agent',attempt_id=>'writer-attempt',
    source=>'explicit-lead',text=>'Authorized unpinned label'})};
is($@,'','existing explicit-lead grant remains consumable by the writer');
is(ref($saved),'HASH','unpinned label writer returns a scoped reference');
is(ref($saved) eq 'HASH' ? $saved->{project_id} : undef,$project_id,'unpinned label writer retains the recovered legacy namespace');
ok(!-e "$legacy_writer/.loomy/project-id",'unpinned Git writer never persists a project identity');
is(bytes("$legacy_writer/.loomy/logs/content-policy.conf"),$policy_before,'label capture never changes the existing stored grant');
readonly('unpinned writer result inspection',$work,sub {
    my $resolved=Loomy::ContentPolicy::resolve_label($legacy_writer,$saved);
    is(ref($resolved) eq 'HASH' ? $resolved->{text} : undef,'Authorized unpinned label',
        'pure legacy reader resolves the authorized writer result');
    my $p=Loomy::ContentPolicy::policy_snapshot($legacy_writer);
    is($p->{identity_state},'missing','authorized unpinned capture leaves snapshot identity missing');
    closed($p,'unpinned writer snapshot');
});

# The same writer contract works before any legacy label supplies a namespace.
# An unignored Git root must keep the deterministic path identity in memory.
my $computed_writer=project('computed-writer-unignored',0,1); repository($computed_writer);
my $computed_id='p'.sha256_hex($computed_writer);
my $computed_policy_before=bytes("$computed_writer/.loomy/logs/content-policy.conf");
my $computed_saved=eval {Loomy::ContentPolicy::save_label($computed_writer,{project_id=>$computed_id,
    target_kind=>'agent',target_id=>'computed-agent',attempt_id=>'computed-attempt',
    source=>'explicit-lead',text=>'Authorized computed namespace'})};
is($@,'','existing grant permits a writer using a deterministic path namespace');
is(ref($computed_saved),'HASH','computed-namespace writer returns a scoped reference');
is(ref($computed_saved) eq 'HASH' ? $computed_saved->{project_id} : undef,$computed_id,
    'computed-namespace writer uses the exact deterministic project ID');
ok(!-e "$computed_writer/.loomy/project-id",'computed-namespace Git writer never persists an unignored identity');
is(bytes("$computed_writer/.loomy/logs/content-policy.conf"),$computed_policy_before,
    'computed-namespace writer preserves the existing stored policy bytes');
readonly('computed-namespace writer result inspection',$work,sub {
    my $resolved=Loomy::ContentPolicy::resolve_label($computed_writer,$computed_saved);
    is(ref($resolved) eq 'HASH' ? $resolved->{text} : undef,'Authorized computed namespace',
        'pure R1 reader resolves the computed-namespace writer result');
    compatible(Loomy::ContentPolicy::effective_policy($computed_writer),$computed_id,
        'computed-namespace writer effective policy',1);
    closed(Loomy::ContentPolicy::policy_snapshot($computed_writer),'computed-namespace writer strict snapshot');
});
no_exports($computed_writer,'computed-namespace writer');

# Doctor's existing read-only seam carries only root and directory stat pins.
# Preserve that caller shape while still rejecting a replacement directory.
my $doctor=project('legacy-doctor-context',1,1);
my ($doctor_loomy,$doctor_ls)=Loomy::ContentPolicy::_dir("$doctor/.loomy");
my ($doctor_logs,$doctor_ds)=Loomy::ContentPolicy::_dir("$doctor/.loomy/logs");
my $doctor_context={root=>$doctor,ls=>$doctor_ls,ds=>$doctor_ds};
readonly('legacy stat-only doctor assertion',$work,sub {
    ok(eval {Loomy::ContentPolicy::_assert_context($doctor_context); 1},'legacy root/ls/ds assertion remains accepted');
});
rename "$doctor/.loomy/logs","$doctor/.loomy/preserved-logs" or die;
mkdir "$doctor/.loomy/logs",0700 or die;
readonly('legacy stat-only stale pin',$work,sub {
    denied('legacy root/ls/ds assertion rejects a replaced logs inode',
        sub {Loomy::ContentPolicy::_assert_context($doctor_context)});
});

{
    local $ENV{LOOMY_JOURNAL}=0;
    readonly('disabled journal readers',$work,sub {
        is(Loomy::ContentPolicy::effective_policy($bare)->{journal_enabled},0,'disabled journal stays disabled without a runtime');
        is(Loomy::ContentPolicy::effective_policy($no_id)->{journal_enabled},0,'disabled journal also vetoes R1 collection with a transient namespace');
        is(Loomy::ContentPolicy::policy_snapshot($identified)->{journal_enabled},0,'disabled journal preserves the existing snapshot without collection');
        Loomy::RuntimePaths::resolve($bare);
    });
}
{
    local $ENV{LOOMY_JOURNAL_TASKS}=0;
    readonly('task veto with missing identity',$work,sub {
        my $p=Loomy::ContentPolicy::effective_policy($no_id);
        is_deeply([@$p{qw(journal_content label_sources private_results source policy_generation)}],
            ['structural','none','off','tasks-veto',12],'TASKS=0 closes existing R1 grants while retaining the stored generation');
        is($p->{project_id},'p'.sha256_hex($no_id),'TASKS=0 retains the transient R1 namespace without attesting it');
        denied('TASKS=0 refuses an otherwise granted label writer without project-id',sub {
            Loomy::ContentPolicy::save_label($no_id,{project_id=>$p->{project_id},target_kind=>'agent',
                target_id=>'vetoed-agent',attempt_id=>'vetoed-attempt',source=>'explicit-lead',text=>'Must not be saved'});
        });
    });
}

# The setup uses real local Git registrations; every subsequent probe is pure.
my $owner=project('registered-main',1,1); labels($owner); full($owner); repository($owner);
my $whole=worktree($owner,'registered-whole');
my $logs=worktree($owner,'registered-logs');
symlink "$owner/.loomy","$whole/.loomy" or die;
mkdir "$logs/.loomy",0700 or die;
symlink "$owner/.loomy/logs","$logs/.loomy/logs" or die;
my $owner_ctx=context($owner,$owner,'main');
my $whole_ctx=context($whole,$owner,'whole .loomy alias');
my $logs_ctx=context($logs,$owner,'logs-only alias');
for my $pair ([$whole_ctx,'whole .loomy alias'],[$logs_ctx,'logs-only alias']) {
    is_deeply([@{$pair->[0]{ls}}[0,1]],[@{$owner_ctx->{ls}}[0,1]],"$pair->[1] shares the exact .loomy device/inode");
    is_deeply([@{$pair->[0]{ds}}[0,1]],[@{$owner_ctx->{ds}}[0,1]],"$pair->[1] shares the exact logs device/inode");
}
for my $h ($owner_ctx->{loomy},$owner_ctx->{logs},$whole_ctx->{loomy},$logs_ctx->{logs}) {
    ok(fcntl($h,F_GETFD,0)&FD_CLOEXEC,'runtime directory descriptor is close-on-exec');
}
readonly('shared public directory validation',$work,sub {
    my ($h,$stat)=Loomy::RuntimePaths::dir("$owner/.loomy/logs",'fixture logs');
    is_deeply([@$stat[0,1]],[@{$owner_ctx->{ds}}[0,1]],'dir returns the pinned canonical directory stat');
    is_deeply([(stat($h))[0,1]],[@$stat[0,1]],'dir handle and returned stat identify the same directory');
    denied('dir itself never follows an otherwise registered alias',sub {Loomy::RuntimePaths::dir("$whole/.loomy",'fixture alias')});
});
my @shared=($owner,$whole,$logs);
my $initial_scope=scopes($owner_ctx,\@shared,'main union');
for my $pair ([$whole_ctx,'whole alias union'],[$logs_ctx,'logs alias union']) {
    my $scope=scopes($pair->[0],\@shared,$pair->[1]);
    is($scope->{revision},$initial_scope->{revision},"$pair->[1] agrees independently of the first caller");
}
for my $pair ([$whole,'whole alias'],[$logs,'logs alias']) {
    my $r=reader_probe($pair->[0],$pair->[1]);
    is_deeply($r->{policy_snapshot},Loomy::ContentPolicy::policy_snapshot($owner),"$pair->[1] reads the exact owner snapshot");
    is_deeply($r->{label},$label,"$pair->[1] resolves the owner's scoped label");
    is($r->{label_health},'full',"$pair->[1] reads the owner's health without a local identity");
}

my $added=worktree($owner,'registered-added');
my $unshared=scopes($owner_ctx,\@shared,'registered but unshared sibling');
is($unshared->{revision},$initial_scope->{revision},'Git registration alone does not change source eligibility');
symlink "$owner/.loomy","$added/.loomy" or die;
my $admitted=scopes($owner_ctx,[@shared,$added],'later shared sibling');
isnt($admitted->{revision},$initial_scope->{revision},'admitting a shared sibling invalidates the source revision');
my $added_ctx=context($added,$owner,'later sibling');
is(scopes($added_ctx,[@shared,$added],'later sibling union')->{revision},$admitted->{revision},'new caller observes the same expanded union');
unlink "$added/.loomy" or die;
my $removed=scopes($owner_ctx,\@shared,'removed shared source');
isnt($removed->{revision},$admitted->{revision},'removing a shared source invalidates the source revision');
is($removed->{revision},$initial_scope->{revision},'the same validated membership has a deterministic revision');

my $foreign="$work/foreign-alias"; mkdir $foreign,0700 or die;
symlink "$owner/.loomy","$foreign/.loomy" or die;
my $foreign_logs="$work/foreign-logs-alias"; make_path("$foreign_logs/.loomy",{mode=>0700});
symlink "$owner/.loomy/logs","$foreign_logs/.loomy/logs" or die;
make_path("$work/unrelated",{mode=>0700}); my $clone="$work/unrelated/registered-main";
git($work,'clone','-q','--no-hardlinks',$owner,$clone);
symlink "$owner/.loomy","$clone/.loomy" or die;
for my $pair ([$foreign,'arbitrary whole alias'],[$foreign_logs,'arbitrary logs alias'],[$clone,'unrelated same-slug clone']) {
    readonly($pair->[1],$work,sub {
        denied("$pair->[1] cannot claim the physical runtime",sub {Loomy::RuntimePaths::resolve($pair->[0])});
        ok(!Loomy::ContentPolicy::policy_snapshot($pair->[0])->{valid},"$pair->[1] cannot read a usable content grant");
    });
}
is(scopes($owner_ctx,\@shared,'foreign paths excluded')->{revision},$initial_scope->{revision},'unrelated and same-slug paths cannot alter the source revision');

{
    local %ENV=%ENV;
    $ENV{GIT_DIR}="$clone/.git"; $ENV{GIT_COMMON_DIR}="$clone/.git";
    $ENV{GIT_WORK_TREE}=$clone; $ENV{GIT_INDEX_FILE}="$work/forged-index";
    my $safe=context($whole,$owner,'registered alias under inherited GIT_*');
    is(scopes($safe,\@shared,'inherited GIT_* scope')->{revision},$initial_scope->{revision},'scope verification clears inherited Git routing');
    $ENV{GIT_DIR}="$owner/.git"; $ENV{GIT_COMMON_DIR}="$owner/.git"; $ENV{GIT_WORK_TREE}=$owner;
    readonly('forged registration environment',$work,sub {
        denied('inherited Git routing cannot register an arbitrary alias',sub {Loomy::RuntimePaths::resolve($foreign)});
        denied('inherited Git routing cannot register an unrelated clone',sub {Loomy::RuntimePaths::resolve($clone)});
    });
}

my $source_link="$work/source-root-link"; symlink $whole,$source_link or die;
readonly('symlinked source root',$work,sub {
    for my $suffix ('','/','/.','/./') {
        denied("a symlinked source root with suffix '$suffix' cannot masquerade as a registered workspace",
            sub {Loomy::RuntimePaths::resolve("$source_link$suffix")});
    }
});

# Matching project-relative paths are required inside a registered worktree.
my $nested_top="$work/nested-main"; repository($nested_top);
my $nested_owner=project('nested-main/apps/client',1,1); labels($nested_owner);
my $nested_wt=worktree($nested_top,'nested-sibling');
make_path("$nested_wt/apps/client","$nested_wt/apps/other",{mode=>0700});
symlink "$nested_owner/.loomy","$nested_wt/apps/client/.loomy" or die;
symlink "$nested_owner/.loomy","$nested_wt/apps/other/.loomy" or die;
my $nested_ctx=context("$nested_wt/apps/client",$nested_owner,'nested project alias');
scopes($nested_ctx,[$nested_owner,"$nested_wt/apps/client"],'nested project union');
readonly('mismatched project-relative alias',$work,sub {
    denied('a registered worktree cannot alias a different project-relative path',sub {Loomy::RuntimePaths::resolve("$nested_wt/apps/other")});
});
my $nested_link_wt=worktree($nested_top,'nested-source-symlink');
symlink "$nested_wt/apps","$nested_link_wt/apps" or die;
my $nested_top_link="$work/nested-git-top-link"; symlink $nested_wt,$nested_top_link or die;
readonly('symlinked project-relative source or Git top',$work,sub {
    denied('a source root through a symlinked project-relative component is rejected',
        sub {Loomy::RuntimePaths::resolve("$nested_link_wt/apps/client")});
    denied('a nested source root through a symlinked Git top is rejected',
        sub {Loomy::RuntimePaths::resolve("$nested_top_link/apps/client")});
});
scopes($nested_ctx,[$nested_owner,"$nested_wt/apps/client"],'symlinked source excluded from union');

# Preserve the established private-group exception, without repairing modes.
my $private="$work/private-group-umask-002";
my $mask=umask 0002; mkdir $private or die; mkdir "$private/.loomy" or die; umask $mask;
repository($private);
chown -1,(getpwuid($<))[3],$private,"$private/.loomy" or die;
is((stat($private))[2]&0777,0775,'ordinary Git root starts at the real umask-002 mode');
is((stat("$private/.loomy"))[2]&0777,0775,'fixture .loomy starts at the real umask-002 mode');
my $user=(getpwuid($<))[0];
{
    no warnings 'redefine';
    local *Loomy::ContentPolicy::_group_info=sub {($user,'')};
    readonly('private-group reader compatibility',$work,sub {
        my $p=Loomy::ContentPolicy::policy_snapshot($private);
        is($p->{identity_state},'missing','private-group .loomy is readable without allocating identity');
        isnt($p->{policy_state},'invalid','private-group exception remains accepted');
        compatible(Loomy::ContentPolicy::effective_policy($private),'p'.sha256_hex($private),
            'private-group ordinary Git root effective policy',0);
        is(Loomy::ContentPolicy::label_health($private),'ok','private-group health read succeeds without logs');
    });
    local *Loomy::ContentPolicy::_group_info=sub {('staff','')};
    readonly('nonprivate group refusal',$work,sub {
        is(Loomy::ContentPolicy::policy_snapshot($private)->{policy_state},'invalid','shared staff group is refused without mode repair');
        ok(!Loomy::ContentPolicy::effective_policy($private)->{valid},'shared-group effective policy fails closed');
    });
}
is((stat("$private/.loomy"))[2]&0777,0775,'group validation never relaxes or repairs the existing .loomy mode');
ok(!-e "$private/.loomy/logs" && !-e "$private/.loomy/project-id",'group compatibility checks never scaffold runtime or identity');
mkdir "$private/.loomy/logs",0700 or die;
{
    no warnings 'redefine';
    local *Loomy::ContentPolicy::_group_info=sub {($user,'')};
    my $c=readonly('private-group pinned writer context',$work,sub {Loomy::ContentPolicy::_context($private,0)});
    readonly('private-group pinned context validation',$work,sub {
        ok(eval {Loomy::ContentPolicy::_assert_context($c); 1},'private-group context remains valid before its trust changes');
    });
    local *Loomy::ContentPolicy::_group_info=sub {('staff','')};
    readonly('private-to-shared group context refusal',$work,sub {
        denied('an already-pinned CONTENT context rejects a newly shared group',sub {Loomy::ContentPolicy::_assert_context($c)});
    });
}

# R1 validates the physical runtime directories independently of source-root
# modes. Registered source roots may be group/world writable while the shared
# .loomy/logs remain private; preserve this in both existing alias layouts.
my $source_owner=project('source-modes-main',1,1); labels($source_owner); repository($source_owner);
my $source_whole=worktree($source_owner,'source-modes-whole');
my $source_logs=worktree($source_owner,'source-modes-logs');
symlink "$source_owner/.loomy","$source_whole/.loomy" or die;
mkdir "$source_logs/.loomy",0700 or die;
symlink "$source_owner/.loomy/logs","$source_logs/.loomy/logs" or die;
my @source_roots=($source_owner,$source_whole,$source_logs);
chown -1,(getpwuid($<))[3],@source_roots or die;
my $source_revision;
for my $case ([0775,'private'],[0775,'shared'],[0777,'shared']) {
    my ($mode,$group)=@$case;
    chmod $mode,@source_roots or die;
    no warnings 'redefine';
    local *Loomy::ContentPolicy::_group_info=sub {$group eq 'private' ? ($user,'') : ('staff','')};
    for my $pair ([$source_owner,'canonical'],[$source_whole,'whole alias'],[$source_logs,'logs alias']) {
        my ($root,$layout)=@$pair;
        my $name=sprintf('R1 source %04o %s group %s',$mode,$group,$layout);
        my $c=context($root,$source_owner,$name,\&Loomy::ContentPolicy::_private_group);
        my $scope=scopes($c,\@source_roots,$name);
        $source_revision//=$scope->{revision};
        is($scope->{revision},$source_revision,"$name retains the exact shared source revision");
        readonly("$name CONTENT reads",$work,sub {
            compatible(Loomy::ContentPolicy::effective_policy($root),$project_id,$name,1);
            is_deeply(Loomy::ContentPolicy::resolve_label($root,$ref),$label,"$name retains its exact scoped label");
        });
    }
}
is((stat("$source_owner/.loomy"))[2]&0777,0700,'source compatibility retains the private canonical .loomy mode');
is((stat("$source_owner/.loomy/logs"))[2]&0777,0700,'source compatibility retains the private logs mode');
is((stat("$source_logs/.loomy"))[2]&0777,0700,'source compatibility retains the private logs-alias parent mode');
for my $part ('.loomy','.loomy/logs') {
    my $unsafe=project('unsafe-'.($part eq '.loomy' ? 'loomy' : 'logs'),1,1);
    chmod($part eq '.loomy' ? 0777 : 0775,"$unsafe/$part") or die;
    readonly("unsafe $part mode",$work,sub {
        denied("unsafe $part is rejected by the pure resolver",sub {Loomy::RuntimePaths::resolve($unsafe)});
        ok(!Loomy::ContentPolicy::policy_snapshot($unsafe)->{valid},"unsafe $part cannot supply a content grant");
    });
}

# Pin the caller's alias as well as the canonical target. A new valid target
# must not make an older context current again.
my $other=project('registered-other-store',1,1);
git($owner,'worktree','add','-q','-b','other-store',"$work/other-store-worktree");
my $other_wt="$work/other-store-worktree";
rename "$other/.loomy","$other_wt/.loomy" or die;
for my $pair ([$whole,'.loomy',$whole_ctx],[$logs,'.loomy/logs',$logs_ctx]) {
    my ($alias,$suffix,$old_ctx)=@$pair;
    unlink "$alias/$suffix" or die;
    symlink "$other_wt/$suffix","$alias/$suffix" or die;
    readonly("retargeted $suffix alias",$work,sub {
        denied("retargeted $suffix invalidates the pinned context",sub {Loomy::RuntimePaths::assert_current($old_ctx)});
        is(Loomy::RuntimePaths::resolve($alias)->{root},$other_wt,"retargeted $suffix resolves only through a fresh context");
    });
}
scopes($owner_ctx,[$owner],'retargeted aliases leave original source scope');

# L0 fix round: symlinked roots, reader git cost, old Git, odd siblings, identity race.
# 1. A symlinked project root or Git top is exactly as valid as at the R1 base for
#    ordinary readers; only registered-alias layouts check the caller's spelling.
{
    my $real=project('symlink-plain',1,1); labels($real);
    my $link="$work/symlink-plain-link"; symlink $real,$link or die;
    my $top="$work/symlink-top"; repository($top); my $sub=project('symlink-top/sub',1,1);
    my $top_link="$work/symlink-top-link"; symlink $top,$top_link or die;
    my $git_real=project('symlink-git-plain',1,1); repository($git_real);
    my $git_link="$work/symlink-git-plain-link"; symlink $git_real,$git_link or die;
    readonly('symlinked ordinary roots',$work,sub {
        for my $pair ([$link,$real,'a symlinked project root'],["$link/",$real,'a symlinked root with a trailing slash'],
            ["$link/.",$real,'a symlinked root with a trailing dot'],["$top_link/sub",$sub,'a project below a symlinked Git top'],
            [$git_link,$git_real,'a symlinked Git project root']) {
            my ($path,$canonical,$name)=@$pair;
            my $e=Loomy::ContentPolicy::effective_policy($path);
            is($e->{valid},1,"$name is a valid effective policy root");
            is($e->{journal_enabled},1,"$name keeps journal collection enabled");
            is(Loomy::ContentPolicy::load_policy($path)->{valid},1,"$name keeps stored-policy inspection valid");
            is(Loomy::ContentPolicy::label_health($path),'ok',"$name keeps label health");
            is(Loomy::ContentPolicy::policy_snapshot($path)->{identity_state},'present',"$name keeps a present strict identity");
            is_deeply(Loomy::ContentPolicy::effective_policy($canonical),$e,"$name equals its canonical root");
            is(Loomy::RuntimePaths::resolve($path)->{root},$canonical,"$name resolves to the canonical root");
        }
    });
}

# 8. A nonexistent root keeps the R2-T0 strict values.
{
    my $gone="$work/does-not-exist-l0e";
    my $p=Loomy::ContentPolicy::policy_snapshot($gone);
    is($p->{identity_state},'missing','a strict snapshot of a nonexistent root has identity missing');
    is($p->{policy_state},'default','a strict snapshot of a nonexistent root has policy default');
    is($p->{valid},0,'a nonexistent root grants nothing');
    ok(!-e $gone,'the nonexistent root is not created');
}

# 2-4. Git shim: count processes, refuse -z like Git < 2.36, forge odd and excess entries.
my $real_git=''; for my $dir (split /:/,$ENV{PATH}) {if (-x "$dir/git") {$real_git="$dir/git"; last}}
die "git not found\n" unless length $real_git;
my $shim_dir="$work.shim"; make_path($shim_dir,{mode=>0700});
put("$shim_dir/git",<<'SHIM',0700);
#!/bin/bash
printf '%s\n' "$*" >> "$SHIM_LOG"
list=0; z=0
for a in "$@"; do [[ $a == worktree ]] && list=1; [[ $a == -z ]] && z=1; done
mode="${SHIM_MODE:-}"
if (( list )) && [[ $mode == noz || $mode == odd ]] && (( z )); then
  echo "error: unknown switch 'z'" >&2; exit 129
fi
if (( list )) && [[ $mode == odd ]]; then
  "$SHIM_REAL_GIT" "$@" || exit $?
  printf '\nworktree %s/odd\tpath\nHEAD 0000\n' "$SHIM_WORK"
  printf '\nworktree %s/dup\nHEAD 0000\nHEAD 1111\n' "$SHIM_WORK"
  printf '\ngarbage line\nworktree %s/garbage\n' "$SHIM_WORK"
  for i in $(seq 1 300); do printf '\nworktree /nonexistent/l0d-%s\nHEAD 0000\n' "$i"; done
  exit 0
fi
exec "$SHIM_REAL_GIT" "$@"
SHIM
sub shim_log {open my $h,'<',"$shim_dir/shim.log" or return (); my @l=<$h>; chomp @l; return @l}
sub shim_reset {unlink "$shim_dir/shim.log"; open my $h,'>',"$shim_dir/shim.log" or die; close $h}
my $gmain=project('l0d-main',1,1); repository($gmain); labels($gmain);
my @gtops;
for my $n (1..4) {
    my $wt=worktree($gmain,"l0d-wt$n"); push @gtops,$wt;
    if ($n%2) {symlink "$gmain/.loomy","$wt/.loomy" or die}
    else {mkdir "$wt/.loomy",0700 or die; symlink "$gmain/.loomy/logs","$wt/.loomy/logs" or die}
}
my @gall=sort($gmain,@gtops);
{
    local $ENV{PATH}="$shim_dir:$ENV{PATH}"; local $ENV{SHIM_LOG}="$shim_dir/shim.log";
    local $ENV{SHIM_REAL_GIT}=$real_git; local $ENV{SHIM_WORK}=$work;
    my $alias=$gtops[0];
    shim_reset();
    my $reads=readonly('alias-layout readers under the Git shim',$work,sub {
        return [Loomy::ContentPolicy::effective_policy($alias),Loomy::ContentPolicy::load_policy($alias),
            Loomy::ContentPolicy::label_health($alias),Loomy::ContentPolicy::resolve_label($alias,$ref),
            Loomy::ContentPolicy::policy_snapshot($alias),Loomy::ContentPolicy::policy_snapshot($alias,'effective')];
    });
    my @log=shim_log();
    ok(@log>0,'the Git shim observes the alias-layout reader processes');
    is(scalar(grep {/\bworktree\b/} @log),0,'R1 readers never spawn git worktree list');
    is(scalar(grep {/ rev-parse /} @log),12,'each alias reader costs the base two relation probes');
    is($reads->[0]{valid},1,'alias-layout readers remain valid without registration probing');

    my $c=Loomy::RuntimePaths::resolve($alias); shim_reset();
    my $scope=readonly('scope under the Git shim',$work,sub {Loomy::RuntimePaths::scope_set($c)});
    @log=shim_log();
    is_deeply($scope->{roots},\@gall,'shimmed scope contains every registered alias exactly once');
    is($scope->{skipped},0,'a clean registration reports no skipped sibling');
    is(scalar(grep {/\bworktree list\b/} @log),1,'scope_set takes one worktree listing');
    ok(scalar(grep {/rev-parse/} @log)<=2,'scope_set spawns no Git process per sibling');
    is(scalar(grep {my $l=$_; grep {index($l,"-C $_ ")>=0} @gtops[1..3]} @log),0,'siblings are compared from their files, not by Git');

    # Git older than 2.36 has no -z: parse the plain porcelain, never die.
    {
        local $ENV{SHIM_MODE}='noz'; shim_reset();
        my $old=readonly('scope under a Git without -z',$work,sub {Loomy::RuntimePaths::scope_set($c)});
        is_deeply($old->{roots},\@gall,'a Git that refuses -z yields the same registered union');
        is($old->{revision},$scope->{revision},'the plain porcelain parse gives the same revision');
        is($old->{skipped},0,'plain porcelain with ordinary entries skips nothing');
        @log=shim_log();
        ok(scalar(grep {/worktree list --porcelain -z/} @log)<=1 && scalar(grep {/worktree list --porcelain\z/} @log)>=1,
            'the listing falls back from -z to plain porcelain');
        my $r=Loomy::ContentPolicy::effective_policy($alias);
        is($r->{valid},1,'readers are unaffected by a Git without -z');
    }
    # Odd entries and entries beyond the cap are skipped and counted, never fatal.
    {
        local $ENV{SHIM_MODE}='odd'; shim_reset();
        my $odd=readonly('scope with odd and excess registrations',$work,sub {Loomy::RuntimePaths::scope_set($c)});
        is_deeply($odd->{roots},\@gall,'odd and excess siblings leave the admitted union unchanged');
        is($odd->{revision},$scope->{revision},'odd siblings do not change the revision');
        # 3 malformed records, plus 5 real and 300 forged entries against a cap of 256.
        is($odd->{skipped},3+(5+300-256),'odd records and the excess beyond 256 are counted visibly');
        my $own=Loomy::RuntimePaths::scope_set(Loomy::RuntimePaths::resolve($gmain));
        is_deeply($own->{roots},\@gall,'the owner keeps itself when excess siblings are skipped');
    }
}

# 9. An identity absent at the start is accepted only when equal to the derived id.
{
    my $race=project('l0d-identity-race',0,1);
    my $derived=Loomy::ContentPolicy::effective_policy($race)->{project_id};
    like($derived,qr/\Ap[0-9a-f]{64}\z/,'race fixture derives an unstored namespace');
    my $orig=\&Loomy::ContentPolicy::_project_id; my $other='p'.('c'x64);
    for my $case ([$other,0,'a foreign identity appearing during derivation'],
        [$derived,1,'the derived identity appearing during derivation']) {
        my ($bytes,$accepted,$name)=@$case; my $calls=0;
        no warnings 'redefine';
        local *Loomy::ContentPolicy::_project_id=sub {
            put("$race/.loomy/project-id","$bytes\n") unless $calls++;
            return $orig->(@_);
        };
        my $p=Loomy::ContentPolicy::effective_policy($race);
        is($p->{valid},$accepted,"$name is ".($accepted ? 'accepted through the concurrent pin' : 'refused'));
        is($p->{project_id},$derived,"$name never selects another namespace") if $accepted;
        ok(!defined($p->{project_id}),"$name supplies no adopted identity") unless $accepted;
        unlink "$race/.loomy/project-id";
    }
}

done_testing();

#!/usr/bin/env bash
# Visibility of the project's AI files (AGENTS.md, CLAUDE.md, .claude/, .loomy/, START.md). Bash 3.2 compatible.
#   loomy privacy                          status: mode, files still tracked, private repository
#   loomy privacy versioned                versioned with the project
#   loomy privacy local                    excluded from Git on this machine (invisible in the repository)
#   loomy privacy private [--name NAME | --remote URL]   excluded from the project, backed up in a separate private repository
#   loomy privacy sync                     backs up the AI files to the private repository
#   loomy privacy adopt                    verifies an existing .loomy/ai.git (created by an older Loomy or copied) and trusts it
#   loomy privacy restore <URL|account/repo>   gets the AI files back on another machine
#   loomy privacy content [structural|legacy-excerpts]
#   loomy privacy labels [recommended|set SOURCE[,SOURCE...]|off]
#   loomy privacy results [on|off]
#   loomy privacy label --id ID [--attempt ID] [--kind agent|task|session|delegation] TEXT
#   loomy privacy inventory [--root DIR] [--json] [--paths] [--git-history] [--host]
# shellcheck disable=SC2034  # UI_* variables are consumed by the sourced UI library.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"

ROOT=""; CMD="show"; REMOTE=""; ARG=""; QUIET=0; AI_REPO_OPT=""; CONTENT_ARGS=()
INVENTORY_JSON=0; INVENTORY_PATHS=0; INVENTORY_GIT=0; INVENTORY_HOST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ -n "${2:-}" ]] || { t "--root requires a directory" >&2; echo >&2; exit 2; }
      ROOT="$2"; shift ;;
    --remote) REMOTE="${2:-}"; shift ;;
    --name) AI_REPO_OPT="${2:-}"; shift ;;
    --quiet) QUIET=1 ;;
    versioned|local|private|sync|apply|show|adopt) CMD="$1" ;;
    inventory) CMD=inventory ;;
    --json) INVENTORY_JSON=1 ;;
    --paths) INVENTORY_PATHS=1 ;;
    --git-history) INVENTORY_GIT=1 ;;
    --host) INVENTORY_HOST=1 ;;
    restore) CMD="restore"; ARG="${2:-}"; [[ $# -gt 1 ]] && shift ;;
    content|labels|results|label) CMD="$1"; shift; CONTENT_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy privacy --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
# Inventory exits before root canonicalisation, brief/policy reads, project
# setup or companion configuration. In particular a missing/denied/link root
# is a metadata result, never a reason to repair or initialise a project.
if [[ "$CMD" == inventory ]]; then
  tv LM_INV_TITLE "Activity storage — metadata only"
  tv LM_INV_ROW "%s: %s file(s), %s bytes, %s symlink(s), %s unreadable — %s"
  tv LM_INV_PARTIAL "Partial coverage: skipped, changed or unavailable metadata."
  tv LM_INV_COMPLETE "Known locations scanned; other copies remain unknown."
  tv LM_INV_NOTE "Content not inspected; no files copied, changed, sent or removed."
  tv LM_INV_UNKNOWN "unknown"
  tv LM_INV_LEGACY "legacy content possible"
  tv LM_INV_CURRENT "current private format"
  tv LM_INV_GIT "%s: %s runtime index path(s), %s local history commit(s)"
  tv LM_INV_GIT_UNKNOWN "%s: runtime index paths and local history unknown"
  tv LM_INV_NONE "%s: none found"
  tv LM_INV_HOST "Host candidates are not proof of abandoned files or safe deletion."
  tv LM_INV_EXTERNAL "Provider stores, arbitrary exports, remote clones and OS backups: unknown; not scanned."
  tv LM_INV_JOURNAL "Journal"
  tv LM_INV_ARCHIVES "Journal archives"
  tv LM_INV_SCRATCH "Checkpoints and scratch files"
  tv LM_INV_LABELS "Task labels and policy"
  tv LM_INV_DELEGATIONS "Legacy delegation results"
  tv LM_INV_RESULTS "Private results"
  tv LM_INV_RECEIPTS "Receipts"
  tv LM_INV_WORK "Tasks, audits and reviews"
  tv LM_INV_AUTHORED "Authored continuity and configuration"
  tv LM_INV_STATE "Work state and prompts"
  tv LM_INV_REPORTS "Reports"
  tv LM_INV_BACKUPS "Restore backups"
  tv LM_INV_HOST_FILES "Host repair, reports and cache"
  tv LM_INV_HOST_TMP "Host temporary candidates"
  tv LM_INV_PROJECT_GIT "Project Git metadata"
  tv LM_INV_COMPANION_GIT "Companion Git metadata"
  export LM_INV_GIT_UNKNOWN LM_INV_NONE
  export LM_INV_TITLE LM_INV_ROW LM_INV_PARTIAL LM_INV_COMPLETE LM_INV_NOTE LM_INV_UNKNOWN LM_INV_LEGACY LM_INV_CURRENT LM_INV_GIT LM_INV_HOST
  export LM_INV_EXTERNAL
  export LM_INV_JOURNAL LM_INV_ARCHIVES LM_INV_SCRATCH LM_INV_LABELS LM_INV_DELEGATIONS LM_INV_RESULTS LM_INV_RECEIPTS LM_INV_WORK
  export LM_INV_AUTHORED LM_INV_STATE LM_INV_REPORTS LM_INV_BACKUPS LM_INV_HOST_FILES LM_INV_HOST_TMP LM_INV_PROJECT_GIT LM_INV_COMPANION_GIT
  # A root that does not exist is one clear line, not a table of unknown rows. A symlinked ancestor is fine: the
  # user-supplied root itself is resolved physically in the scanner, only the tree below it is never followed.
  # (--json keeps the structured partial report, which is the machine-readable form of the same fact.)
  if (( ! INVENTORY_JSON )) && [[ -n "$ROOT" && ! -e "$ROOT" ]]; then t "Directory not found: %s" "$ROOT" >&2; echo >&2; exit 1; fi
  INVENTORY_SPECS=()
  if (( INVENTORY_GIT )); then
    loomy_history_specs_load || { t "Can't build the runtime exclusion list" >&2; echo >&2; exit 1; }
    INVENTORY_SPECS=("${LOOMY_HISTORY_SPECS[@]}")
  fi
  # Authored continuity documents are deliberately backed up, not runtime.
  INVENTORY_SPECS+=(':(exclude,literal).loomy/memory/STATE.md' ':(exclude,literal).loomy/memory/DEAD-ENDS.md' ':(exclude,literal).loomy/docs/HANDOFF.md')
  perl - "${ROOT:-$(ai_project_root)}" "$INVENTORY_JSON" "$INVENTORY_PATHS" "$INVENTORY_GIT" "$INVENTORY_HOST" "${INVENTORY_SPECS[@]}" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use JSON::PP;
use Encode qw(decode FB_DEFAULT);
use POSIX qw(strftime);
use Cwd ();
use Time::HiRes qw(time stat lstat);
use Errno qw(ENOENT ELOOP ENOTDIR EINVAL EAGAIN);
my ($root,$as_json,$paths,$with_git,$host,@history_specs)=@ARGV;
my $json=JSON::PP->new->utf8->canonical;
my $deadline=time+5; my $budget=20000; my $path_bytes=0; my @rows; my @observed; my @git_checks;
my $dir_flags=O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_DIRECTORY;
sub text { decode('UTF-8',$_[0]//' ',FB_DEFAULT) }
sub same { join(':',@{$_[0]}[0,1,2,3,4,7,9,10]) eq join(':',@{$_[1]}[0,1,2,3,4,7,9,10]) }
sub limited { --$budget>=0 && time<$deadline }
sub row {
    my ($name,$scope,$exposure,$retention)=@_;
    my $r={category=>$name,scope=>$scope,file_count=>0,bytes=>0,symlink_count=>0,
      unreadable_count=>0,exposure=>$exposure,retention=>$retention,
      content_status=>'legacy-possible',scan_complete=>JSON::PP::true};
    $r->{paths}=[] if $paths; push @rows,$r; return $r;
}
sub partial { $_[0]{scan_complete}=JSON::PP::false; $_[0]{content_status}='unknown'; $_[0]{unreadable_count}++ if $_[1] }
# Open each component relative to a pinned directory descriptor. No stat/open
# operation traverses an unchecked intermediate symlink, including in --root.
sub directory {
    my ($base,$parts)=@_; my $h;
    chdir($base) or return;
    sysopen($h,'.',$dir_flags) or return;
    for my $part (@$parts) {
        if ($part eq '..' || $part eq '') {$!=EINVAL; return}
        chdir($h) or return;
        my @before=lstat($part); return unless @before;
        if (!S_ISDIR($before[2])) {$!=S_ISLNK($before[2])?ELOOP:ENOTDIR; return}
        my $next; sysopen($next,$part,$dir_flags) or return;
        my @after=stat($next); unless (@after && same(\@before,\@after)) {$!=EAGAIN; return}
        $h=$next;
    }
    return $h;
}
# A user-supplied base (--root, TMPDIR, XDG_CONFIG_HOME, HOME) is resolved physically first, like cd -P: /tmp and
# /var are links on macOS. Only that base is resolved; everything below it is still opened without following links.
sub absolute_directory {
    my ($path)=@_; my $base;
    my $physical=Cwd::abs_path($path); return unless defined $physical;
    $path=$physical;
    sysopen($base,$path=~m{^/}?'/':'.',$dir_flags) or return;
    my @parts=grep {length && $_ ne '.'} split m{/+},$path;
    return directory($base,\@parts);
}
sub describe {
    my ($r,$relative,$s)=@_;
    return unless $paths && $r->{scope} ne 'git';
    if (($path_bytes+=length($relative)+192)>1048576) {partial($r,0); return}
    my $type=S_ISLNK($s->[2])?'symlink':S_ISDIR($s->[2])?'directory':S_ISREG($s->[2])?'regular':
      S_ISFIFO($s->[2])?'fifo':S_ISCHR($s->[2])?'character-device':S_ISBLK($s->[2])?'block-device':S_ISSOCK($s->[2])?'socket':'other';
    push @{$r->{paths}},{path=>text($relative),type=>$type,mode=>sprintf('%04o',$s->[2]&07777),
      owner=>0+$s->[4],link_count=>0+$s->[3],size=>0+$s->[7],mtime=>0+$s->[9]};
}
sub walk {
    my ($r,$parent,$name,$relative,$depth,$anchor,$actual)=@_;
    unless (limited() && $depth<=32) {partial($r,0); return}
    unless (chdir($parent)) {partial($r,1); return}
    my @s=lstat($name);
    unless (@s) {
        if ($! == ENOENT) {push @observed,[$r,$anchor,$actual,undef]}
        else {partial($r,1)}
        return;
    }
    push @observed,[$r,$anchor,$actual,\@s];
    describe($r,$relative,\@s);
    if ($r->{scope} eq 'git' && $name=~/\.promisor\z/) {partial($r,0); return}
    if (S_ISLNK($s[2])) {$r->{symlink_count}++; partial($r,0); return}
    if ($s[4]!=$< || (!S_ISDIR($s[2]) && !S_ISREG($s[2]))) {partial($r,1); return}
    if (S_ISREG($s[2])) {
        $r->{file_count}++; $r->{bytes}+=$s[7];
        partial($r,1) if $s[3]!=1 || !($s[2]&0400);
        return;
    }
    unless (($s[2]&0500)==0500) {partial($r,1); return}
    my $d; unless (sysopen($d,$name,$dir_flags)) {partial($r,1); return}
    my @opened=stat($d); unless (@opened && same(\@s,\@opened) && chdir($d)) {partial($r,1); return}
    my $entries; unless (opendir($entries,'.')) {partial($r,1); return}
    while (defined(my $child=readdir($entries))) {
        next if $child eq '.' || $child eq '..';
        unless (limited()) {partial($r,0); last}
        walk($r,$d,$child,"$relative/$child",$depth+1,$anchor,"$actual/$child");
    }
    closedir($entries);
    my @after=stat($d); partial($r,0) unless @after && same(\@s,\@after);
}
my $root_handle=absolute_directory($root);
my $root_ok=0;
if ($root_handle) {my @s=stat($root_handle); $root_ok=@s && $s[4]==$< && ($s[2]&0500)==0500}
my $root_parent=do {my $p=Cwd::abs_path($root)//'/'; $p=~s{/[^/]*\z}{}; length($p)?$p:'/'};
my @specs=(
 ['journal-active','local-runtime','unbounded',['.loomy/logs/events.jsonl']],
 ['journal-archives','local-runtime','unbounded',['.loomy/logs/archive']],
 ['checkpoints-and-scratch','local-runtime','unbounded',[]],
 ['labels-and-policy','local-private','preserved',['.loomy/logs/display-context-v1.jsonl','.loomy/logs/display-context-full','.loomy/logs/content-policy.conf','.loomy/project-id']],
 ['delegation-results','local-private','legacy-unbounded',['.loomy/memory/delegations']],
 ['private-results','local-private','configured-unverified',['.loomy/memory/private-results-v1']],
 ['receipts','local-runtime','preserved',['.loomy/memory/receipts-v1']],
 ['task-audit-review-work','local-runtime','unbounded',['.loomy/tasks','.loomy/TASKS.md','.loomy/task.state','.loomy/audit.state','.loomy/audits','.loomy/reviews','.loomy/audit.md','.loomy/assessment.md']],
 ['authored-continuity','authored-documents','preserved',['.loomy/memory/STATE.md','.loomy/memory/DEAD-ENDS.md','.loomy/docs/HANDOFF.md','.loomy/brief.md','.loomy/brief.previous.md','.loomy/skills.lock']],
 ['work-state-and-prompts','local-runtime','unbounded',['.loomy/state','.loomy/failover','.loomy/failover.lock','.loomy/relay.notice']],
 ['reports','authored-exports','unbounded',['docs/reports']],
 ['restore-backups','local-private','unbounded',[]]);
my %by_name;
for my $spec (@specs) { $by_name{$spec->[0]}=row($spec->[0],'project',$spec->[1],$spec->[2]) }
sub inspect_relative {
    my ($r,$rel)=@_; my @parts=split m{/},$rel; my $name=pop @parts;
    # Missing known ancestors are an empty location, not an access error.
    my $p=$root_handle; my @prefix;
    my @root_stat=stat($root_handle); push @observed,[$r,$root_handle,'.',\@root_stat];
    for my $part (@parts) {
        unless (chdir($p)) {partial($r,1); return}
        my @s=lstat($part);
        push @prefix,$part;
        unless (@s) {
            if ($! == ENOENT) {push @observed,[$r,$root_handle,join('/',@prefix),undef]}
            else {partial($r,1)}
            return;
        }
        push @observed,[$r,$root_handle,join('/',@prefix),\@s];
        if (S_ISLNK($s[2])) {$r->{symlink_count}++; partial($r,0); describe($r,join('/',@prefix),\@s); return}
        unless (S_ISDIR($s[2]) && $s[4]==$< && ($s[2]&0500)==0500) {partial($r,1); return}
        $p=directory($p,[$part]); unless ($p) {partial($r,1); return}
    }
    walk($r,$p,$name,$rel,0,$root_handle,$rel);
}
if (!$root_ok) {partial($_,1) for @rows}
else {
    for my $spec (@specs) {inspect_relative($by_name{$spec->[0]},$_) for @{$spec->[3]}}
    # Enumerate only the known .loomy/logs and .loomy basenames, without
    # recursively searching the project or opening any file body.
    for my $entry (['.loomy/logs','checkpoints-and-scratch'],['.loomy','restore-backups'],['.loomy','work-state-and-prompts']) {
        my ($rel,$category)=@$entry; my @parts=split m{/},$rel;
        my $d=directory($root_handle,\@parts);
        unless ($d) {next if $! == ENOENT; partial($by_name{$category},1); next}
        chdir($d) or next; my @before=stat($d);
        my $h; unless (opendir($h,'.')) {partial($by_name{$category},1); next}
        while (defined(my $name=readdir($h))) {
            unless (limited()) {partial($by_name{$category},0); last}
            next if $name eq '.' || $name eq '..';
            my $match=$category eq 'restore-backups' ? $name=~/\Arestore-backup-/ :
              $category eq 'work-state-and-prompts' ? $name=~/(?:-prompt\.txt\z|\.tmp(?:\.|\z)|\A(?:tmp|temp|prompts|inventory[^\/]*|task\.state|audit\.state)\z)/ :
              $name!~/\A(?:events\.jsonl|archive|display-context-v1\.jsonl|display-context-full|content-policy\.conf)\z/;
            walk($by_name{$category},$d,$name,"$rel/$name",0,$root_handle,"$rel/$name") if $match;
        }
        closedir($h); my @after=stat($d); partial($by_name{$category},0) unless same(\@before,\@after);
    }
}
# Git reads local index/ref/tree metadata only. No hooks, fsmonitor, pager,
# optional index refresh, lazy fetching, shell interpolation or inherited Git
# repository overrides. A byte/time bound also applies to large histories.
sub git_metadata {
    my ($base,$argv)=@_; return unless $root_ok && time<$deadline && chdir($root_handle);
    pipe(my $rd,my $wr) or return;
    my $pid=fork(); return unless defined $pid;
    if (!$pid) {
        close $rd; open STDOUT,'>&',$wr or POSIX::_exit(1); close $wr;
        open STDERR,'>','/dev/null' or POSIX::_exit(1); open STDIN,'<','/dev/null' or POSIX::_exit(1);
        delete @ENV{grep {/\AGIT_/} keys %ENV};
        # No repository discovery: the explicit git directory is the only candidate, and no parent is ever searched.
        $ENV{GIT_CEILING_DIRECTORIES}=$root_parent;
        @ENV{qw(GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_CONFIG_COUNT GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS GIT_NO_LAZY_FETCH GIT_NO_REPLACE_OBJECTS GIT_ALLOW_PROTOCOL GIT_PROTOCOL_FROM_USER)}=(1,'/dev/null',0,0,0,1,1,'',0);
        exec('git','--no-pager','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-c','log.showSignature=false',@$base,@$argv) or POSIX::_exit(1);
    }
    close $wr; my $out=''; my $ok=eval {
        local $SIG{ALRM}=sub {die "metadata unavailable\n"}; alarm 2;
        while (1) {my $n=sysread($rd,my $buf,8192); die unless defined $n; last unless $n; $out.=$buf; die if length($out)>1048576 || time>$deadline}
        close $rd; waitpid($pid,0); my $status=$?; alarm 0; die if $status; 1;
    };
    unless ($ok) {alarm 0; close $rd; kill 'TERM',$pid; kill 'KILL',$pid; waitpid($pid,0); return}
    return $out;
}
my @git;
if ($with_git) {
    for my $repo ('project','companion') {
        my $g={repository=>$repo,index=>{file_count=>undef,scan_complete=>JSON::PP::false},history=>{commit_count=>undef,scan_complete=>JSON::PP::false}};
        my $safe=$root_ok;
        if ($safe) {
            my @parts=$repo eq 'project'?('.git'):('.loomy','ai.git');
            my $name=pop @parts; my $parent=directory($root_handle,\@parts);
            my $d=$parent?directory($parent,[$name]):undef;
            $safe=!!$d;
            if ($safe) {
                # Gitfiles/commondir/alternates and any linked/unsafe metadata
                # have unknown coverage. Do not let Git follow them for us.
                my $probe={scope=>'git',file_count=>0,bytes=>0,symlink_count=>0,unreadable_count=>0,
                  content_status=>'unknown',scan_complete=>JSON::PP::true,paths=>[]};
                my $relative=$repo eq 'project'?'.git':'.loomy/ai.git';
                walk($probe,$parent,$name,$relative,0,$root_handle,$relative); $safe=!!$probe->{scan_complete};
                push @git_checks,[$g,$probe];
                chdir($d); $safe=0 if lstat('commondir');
                my $info=directory($d,['objects','info']);
                if ($info && chdir($info)) {$safe=0 if lstat('alternates') || lstat('http-alternates')}
            }
        }
        if ($safe) {
            # Inspect only local metadata key names with includes disabled.
            # Do this before normal repository setup can read external includes,
            # worktree config or partial-clone/promisor metadata.
            my $config=$repo eq 'project'?'.git/config':'.loomy/ai.git/config';
            my $keys=git_metadata([],['config','--no-includes','--file',$config,'--name-only','--list','-z']);
            $safe=defined($keys) && !grep { /\A(?:include(?:\.|if\.)|extensions\.(?:worktreeconfig|partialclone)\z|remote\..*\.promisor\z)/i } split /\0/,$keys//'';
        }
        if ($safe) {
            my @base=$repo eq 'project'?('--git-dir=.git','--work-tree=.') : ('--git-dir=.loomy/ai.git','--work-tree=.');
            my $index=git_metadata(\@base,['ls-files','-z','--',@history_specs]);
            if (defined $index) {$g->{index}={file_count=>scalar(grep {length} split /\0/,$index),scan_complete=>JSON::PP::true}}
            my $history=git_metadata(\@base,['log','--no-show-signature','--all','--format=%H','--',@history_specs]);
            if (defined $history) {my %ids=map {$_=>1} grep {/\A[0-9a-f]{40,64}\z/} split /\n/,$history; $g->{history}={commit_count=>scalar(keys %ids),scan_complete=>JSON::PP::true}}
        }
        push @git,$g;
    }
}
if ($host) {
    my $r=row('host-repair-reports-cache','host','host-local-unverified','unknown');
    my $config=$ENV{XDG_CONFIG_HOME}//(($ENV{HOME}//'').'/.config');
    for my $suffix ('loomy/logs','loomy/reports','loomy/cache','loomy/claude-limits','loomy/codex-limits','loomy/projects') {
        my $d=absolute_directory($config); unless ($d) {partial($r,1); next}
        my @base=stat($d); unless ($base[4]==$< && ($base[2]&0500)==0500) {partial($r,1); next}
        push @observed,[$r,$d,'.',\@base];
        my @parts=split m{/},$suffix; my $name=pop @parts; my $parent=directory($d,\@parts);
        if ($parent) {
            my @s=stat($parent); unless ($s[4]==$< && ($s[2]&0500)==0500) {partial($r,1); next}
            push @observed,[$r,$d,join('/',@parts),\@s];
            walk($r,$parent,$name,"config/$suffix",0,$d,$suffix);
        }
        elsif ($! != ENOENT) {partial($r,1)}
        else {push @observed,[$r,$d,join('/',@parts),undef]}
    }
    my $tmp=row('host-temporary-candidates','host','candidate-only','unknown');
    my $d=absolute_directory($ENV{TMPDIR}//'/tmp');
    if (!$d || !chdir($d)) {partial($tmp,1)}
    else {
        my @before=stat($d); push @observed,[$tmp,$d,'.',\@before]; my $h;
        if (!opendir($h,'.')) {partial($tmp,1)}
        else {
            while (defined(my $name=readdir($h))) {
                unless (limited()) {partial($tmp,0); last}
                next unless $name=~/\A(?:delegate-|loomy-(?:local|plan|triage|page|vue|sl|watch))/;
                walk($tmp,$d,$name,"temporary/$name",0,$d,$name);
            }
            closedir($h); my @after=stat($d); partial($tmp,0) unless same(\@before,\@after);
        }
    }
}
# Recheck files, directories and initially absent locations after all requested
# scopes. Anchors pin the original directories; link/race failures stay partial.
for my $item (@observed) {
    my ($r,$anchor,$rel,$before)=@$item;
    unless (limited()) {partial($r,0); next}
    my @parts=split m{/},$rel; my $name=pop @parts;
    my $d=directory($anchor,\@parts);
    unless ($d && chdir($d)) {partial($r,1); next}
    my @after=lstat($name);
    if ($before) {partial($r,0) unless @after && same($before,\@after)}
    else {partial($r,0) if @after || $! != ENOENT}
}
for my $check (@git_checks) {
    next if $check->[1]{scan_complete};
    $check->[0]{index}={file_count=>undef,scan_complete=>JSON::PP::false};
    $check->[0]{history}={commit_count=>undef,scan_complete=>JSON::PP::false};
}
my $complete=!(grep {!$_->{scan_complete}} @rows) && !(grep {!$_->{index}{scan_complete} || !$_->{history}{scan_complete}} @git);
my $report={inventory_version=>1,project_id=>undef,scanned_at=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime),
    scope=>$host?'known-project-and-host-locations':'known-project-locations',categories=>\@rows,scan_complete=>$complete?JSON::PP::true:JSON::PP::false};
$report->{git}=\@git if $with_git;
if ($as_json) {print $json->encode($report),"\n"}
else {
    my %labels=('journal-active'=>$ENV{LM_INV_JOURNAL},'journal-archives'=>$ENV{LM_INV_ARCHIVES},
      'checkpoints-and-scratch'=>$ENV{LM_INV_SCRATCH},'labels-and-policy'=>$ENV{LM_INV_LABELS},
      'delegation-results'=>$ENV{LM_INV_DELEGATIONS},'private-results'=>$ENV{LM_INV_RESULTS},'receipts'=>$ENV{LM_INV_RECEIPTS},
      'task-audit-review-work'=>$ENV{LM_INV_WORK},'authored-continuity'=>$ENV{LM_INV_AUTHORED},
      'work-state-and-prompts'=>$ENV{LM_INV_STATE},'reports'=>$ENV{LM_INV_REPORTS},'restore-backups'=>$ENV{LM_INV_BACKUPS},
      'host-repair-reports-cache'=>$ENV{LM_INV_HOST_FILES},'host-temporary-candidates'=>$ENV{LM_INV_HOST_TMP});
    print "$ENV{LM_INV_TITLE}\n";
    for my $r (@rows) {
        if (!$r->{bytes} && !$r->{symlink_count} && !$r->{unreadable_count} && $r->{scan_complete}) {
            printf "$ENV{LM_INV_NONE}\n",$labels{$r->{category}};
        } else {
            # Label and policy stores only exist in the private, current format: no legacy text to mention.
            printf "$ENV{LM_INV_ROW}\n",$labels{$r->{category}},$r->{file_count},$r->{bytes},$r->{symlink_count},$r->{unreadable_count},
              $r->{content_status} eq 'legacy-possible'?($r->{category} eq 'labels-and-policy'?$ENV{LM_INV_CURRENT}:$ENV{LM_INV_LEGACY}):$ENV{LM_INV_UNKNOWN};
        }
        if ($paths) {print '  ',$json->encode($_),"\n" for @{$r->{paths}}}
    }
    for my $g (@git) {
        my $name=$g->{repository} eq 'project'?$ENV{LM_INV_PROJECT_GIT}:$ENV{LM_INV_COMPANION_GIT};
        if (defined $g->{index}{file_count} && defined $g->{history}{commit_count}) {printf "$ENV{LM_INV_GIT}\n",$name,$g->{index}{file_count},$g->{history}{commit_count}}
        else {printf "$ENV{LM_INV_GIT_UNKNOWN}\n",$name}
    }
    print $complete?"$ENV{LM_INV_COMPLETE}\n":"$ENV{LM_INV_PARTIAL}\n";
    print "$ENV{LM_INV_HOST}\n" if $host;
    print "$ENV{LM_INV_EXTERNAL}\n";
    print "$ENV{LM_INV_NOTE}\n";
}
# Partial coverage is a successful, explicitly partial inventory, not an error
# that triggers a caller's repair fallback.
PERL
  exit $?
fi
if (( INVENTORY_JSON || INVENTORY_PATHS || INVENTORY_GIT || INVENTORY_HOST )); then
  t "Inventory options require: loomy privacy inventory" >&2; echo >&2; exit 2
fi
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
# On a new machine, .loomy doesn't exist yet (outside the repository): only restore can do without it.
# shellcheck disable=SC2174 # -m on the final directory only is intended
if [[ "$CMD" == "restore" ]]; then mkdir -p -m 0755 "$ROOT/.loomy"
elif [[ ! -d "$ROOT/.loomy" ]]; then t "No Loomy project in %s: loomy init first (or loomy privacy restore <account/repo> to recover its AI files)." "${ROOT/#$HOME/~}" >&2; echo >&2; exit 1; fi
case "$CMD" in
  content|labels|results|label)
    # This path never repairs, inventories, syncs or scans older content stores.
    # shellcheck source=lib/content-policy.sh
    source "$SCRIPT_DIR/lib/content-policy.sh"
    loomy_content_command "$CMD" "$ROOT" ${CONTENT_ARGS[@]+"${CONTENT_ARGS[@]}"}
    exit $? ;;
esac
GIT_ROOT="$(privacy_git_root "$ROOT")"
MODE="$(privacy_mode "$ROOT")"
# Private repository name: the project's (brief slug), so that everything has the same name.
NAME="$(loomy_slug "$(_ai_brief_get "$ROOT/.loomy/brief.md" slug)")"; [[ "$NAME" == "my-project" ]] && NAME=""
if [[ -z "$NAME" ]]; then
  NAME="$(_ai_brief_get "$ROOT/.loomy/brief.md" name)"
  NAME="$(loomy_slug "${NAME:-$(basename "$ROOT")}")"
fi
# Private repository name: --name, otherwise the brief's (validated in the questionnaire), otherwise <project>-ai.
AI_REPO="${AI_REPO_OPT:-$(_ai_brief_get "$ROOT/.loomy/brief.md" ai_repo_name)}"
AI_REPO="${AI_REPO:-$NAME-ai}"
# Whatever the brief says, the repository name is a plain technical name (it ends up in gh and git commands).
AI_REPO="$(loomy_slug "$AI_REPO")"

# ---------------------------------------------------------------- separate private repository
create_companion() {
  local url="$REMOTE" owner
  if privacy_companion_ready "$ROOT"; then return 0; fi
  if privacy_companion_present "$ROOT"; then
    ui_err "$(t "Private history not verified · run loomy privacy adopt")" "$(t "a .loomy/ai.git is here but Loomy did not create it")"
    return 1
  fi
  if [[ -z "$url" ]]; then
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
      ui_err "$(t "Can't create the private repository %s" "$AI_REPO")" "$(t "gh missing or not logged in: gh auth login, or give an existing repository with --remote URL")"
      return 1
    fi
    owner="$(gh api user --jq .login 2>/dev/null || true)"
    [[ -n "$owner" ]] || { ui_err "$(t "GitHub account not found")" "$(t "gh auth login")"; return 1; }
    # Name offered for approval, editable (unless it already comes from --name or the questionnaire).
    if [[ -z "$AI_REPO_OPT" && "$CMD" != "apply" ]] && ui_is_interactive; then
      UI_LABEL="$(t "Private repository")"
      UI_HINT="$(t "Private GitHub repository that will only hold the AI files.")"
      ui_input "$(t "Private repository name (%s/…)" "$owner")" "$AI_REPO"
      AI_REPO="$(loomy_slug "$UI_VALUE")"
    fi
    if gh repo view "$owner/$AI_REPO" >/dev/null 2>&1; then
      ui_info "$(t "repository %s already exists: used as is" "$owner/$AI_REPO")"
    else
      gh repo create "$owner/$AI_REPO" --private --description "AI files of the $NAME project (Loomy)" >/dev/null || { ui_err "$(t "Private repository creation failed")" "$owner/$AI_REPO"; return 1; }
      ui_ok "$(t "Private repository created")" "$owner/$AI_REPO"
    fi
    url="https://github.com/$owner/$AI_REPO.git"
  fi
  loomy_git_user init --bare -q -b main "$(privacy_ai_git_dir "$ROOT")"
  privacy_companion_record "$ROOT" || { ui_err "$(t "Can't record the private repository")" "${XDG_CONFIG_HOME:-~/.config}/loomy"; return 1; }
  privacy_set_key "$ROOT" ai_repo_name "$(basename "$url" .git)"
  ai_git "$ROOT" remote add origin "$url"
  privacy_companion_config "$ROOT"
  return 0
}

do_sync() {
  local p paths=() msg
  if ! privacy_companion_ready "$ROOT"; then
    if privacy_companion_present "$ROOT"; then ui_err "$(t "Private history not verified · run loomy privacy adopt")" "$(t "nothing was committed or pushed")"
    else ui_err "$(t "No private repository for this project")" "$(t "loomy privacy private")"; fi
    return 1
  fi
  # A path that disappeared (START.md archived at the end of the setup) is staged too when the companion
  # repository tracks it, so its deletion is committed; a missing, untracked path would make `git add` fail.
  for p in $LOOMY_AI_PATHS; do
    if [[ -e "$ROOT/$p" ]] || [[ -n "$(ai_git "$ROOT" ls-files -- "$p" 2>/dev/null)" ]]; then paths+=("$p"); fi
  done
  (( ${#paths[@]} )) || { ui_info "$(t "no AI file to back up")"; return 0; }
  # The companion repository reads the project's .gitignore, which now excludes the history and work files:
  # it keeps nothing of them but the continuity notes STATE.md, DEAD-ENDS.md and HANDOFF.md (force-added); what it tracked before is
  # dropped from its index.
  privacy_companion_config "$ROOT"
  # Fail closed: an incomplete spec list would leave runtime paths tracked and pushed.
  loomy_history_specs_load || { ui_err "$(t "Can't build the runtime exclusion list")" "$(t "Sync stopped before staging.")"; return 1; }
  for p in "${LOOMY_HISTORY_SPECS[@]}"; do
    ai_git "$ROOT" rm -r --cached --quiet --ignore-unmatch -- "$p" >/dev/null 2>&1 || true
  done
  ai_git "$ROOT" add -A -- "${paths[@]}"
  for p in .loomy/memory/STATE.md .loomy/memory/DEAD-ENDS.md .loomy/docs/HANDOFF.md; do [[ -f "$ROOT/$p" ]] && ai_git "$ROOT" add -f -- "$p"; done
  if ! ai_git "$ROOT" diff --cached --quiet 2>/dev/null; then
    msg="loomy: AI files $(date '+%Y-%m-%d %H:%M')"
    ai_git "$ROOT" commit -q -m "$msg"
  fi
  # Another machine may have backed up in the meantime: we replay our changes on top of theirs.
  if ai_git "$ROOT" ls-remote --exit-code origin main >/dev/null 2>&1; then
    ai_git "$ROOT" fetch -q origin
    # Nothing to replay when the remote is already contained in our history (a rebase would only fail on a dirty tree).
    if ! ai_git "$ROOT" merge-base --is-ancestor origin/main HEAD >/dev/null 2>&1; then
      if ! privacy_companion_ref_safe "$ROOT" origin/main; then
        ui_err "$(t "The remote private repository cannot be rebased safely")" "$(t "Runtime files or an unreadable tree were found. Sync stopped before checkout; inspect the remote repository manually.")"
        return 1
      fi
      if ! ai_git "$ROOT" rebase -q origin/main >/dev/null 2>&1; then
        ai_git "$ROOT" rebase --abort >/dev/null 2>&1 || true
        if ! ai_git "$ROOT" diff --quiet >/dev/null 2>&1; then
          ui_err "$(t "The private repository has uncommitted changes, the rebase cannot run")" "$(t "see them with: git --git-dir=.loomy/ai.git --work-tree=. status")"
        else
          ui_err "$(t "The AI files changed on both sides")" "$(t "resolve by hand: git --git-dir=.loomy/ai.git --work-tree=. pull --rebase origin main")"
        fi
        return 1
      fi
    fi
  fi
  if ai_git "$ROOT" rev-parse -q --verify HEAD >/dev/null; then
    ai_git "$ROOT" push -q -u origin main || { ui_err "$(t "Push to the private repository failed")" "$(ai_git "$ROOT" remote get-url origin)"; return 1; }
  fi
  (( QUIET )) || ui_ok "$(t "AI files backed up")" "$(ai_git "$ROOT" remote get-url origin | sed 's|https://github.com/||; s|\.git$||')"
  return 0
}

# ---------------------------------------------------------------- application d'un mode
warn_tracked() {
  local t
  t="$(privacy_tracked "$ROOT" | tr '\n' ' ')"
  [[ -n "$t" ]] || return 0
  ui_warn "$(t "Still tracked by the project repository")" "$t"
  ui_rail "    ${C_DIM}$(t "to stop tracking them (they stay on your disk):")${C_RESET} git rm -r --cached -- $t"
  ui_rail "    ${C_DIM}$(t "what was already pushed stays in the repository history")${C_RESET}"
}

apply_mode() {
  local m="$1"
  case "$m" in
    versioned)
      privacy_remove_exclude "$ROOT" || true
      if privacy_companion_ready "$ROOT"; then ui_info "$(t "the private repository (.loomy/ai.git) stays in place; it's no longer updated")"; fi ;;
    local|private)
      if [[ -n "$GIT_ROOT" ]]; then privacy_add_exclude "$ROOT"; else ui_info "$(t "no Git repository yet: loomy privacy %s will set the exclusion once the repository exists" "$m")"; fi
      if [[ "$m" == "private" ]]; then create_companion && do_sync || return 1; fi ;;
  esac
  privacy_set_mode "$ROOT" "$m"
  MODE="$m"
  return 0
}

show_state() {
  ui_section "$(t "AI FILES")" "$(echo "$LOOMY_AI_PATHS" | sed 's/ / · /g')"
  ui_kv "$(t "Mode")" "${C_BOLD}$(privacy_label "$MODE")${C_RESET}"
  if [[ -z "$GIT_ROOT" ]]; then ui_kv "$(t "Git repository")" "${C_DIM}$(t "none")${C_RESET}"
  elif [[ "$MODE" != "versioned" ]]; then
    if privacy_excluded "$ROOT"; then ui_kv "$(t "Exclusion")" "${C_GREEN}$(t "active")${C_RESET} ${C_DIM}($(t ".git/info/exclude, specific to this machine"))${C_RESET}"
    else ui_kv "$(t "Exclusion")" "${C_YELLOW}$(t "not set on this machine")${C_RESET} ${C_DIM}→ loomy privacy $MODE${C_RESET}"; fi
  fi
  if [[ "$MODE" == "private" ]]; then
    if privacy_companion_ready "$ROOT"; then
      ui_kv "$(t "Private repository")" "$(ai_git "$ROOT" remote get-url origin 2>/dev/null | sed 's|https://github.com/||; s|\.git$||')"
      pending="$(privacy_pending "$ROOT")"
      if [[ "$pending" == "0" ]]; then ui_kv "$(t "Backup")" "${C_GREEN}$(t "up to date")${C_RESET}"
      else ui_kv "$(t "Backup")" "${C_YELLOW}$(t "%s change(s) to back up" "$pending")${C_RESET} ${C_DIM}→ loomy privacy sync${C_RESET}"; fi
    elif privacy_companion_present "$ROOT"; then
      ui_kv "$(t "Private repository")" "${C_YELLOW}$(t "not verified")${C_RESET} ${C_DIM}→ loomy privacy adopt${C_RESET}"
    else
      ui_kv "$(t "Private repository")" "${C_YELLOW}$(t "missing on this machine")${C_RESET} ${C_DIM}→ $(t "loomy privacy restore <account/repo>, or loomy privacy private to create it")${C_RESET}"
    fi
  fi
  if [[ "$MODE" != "versioned" ]]; then warn_tracked; fi
}

case "$CMD" in
  show)
    ui_banner "$(t "AI files visibility")" "${ROOT/#$HOME/~}"
    show_state
    ui_section "$(t "CHANGE")"
    ui_rail "${C_BOLD}loomy privacy versioned${C_RESET}  ${C_DIM}$(t "versioned with the project (private repository: recommended)")${C_RESET}"
    ui_rail "${C_BOLD}loomy privacy local${C_RESET}      ${C_DIM}$(t "never pushed to GitHub, specific to this machine")${C_RESET}"
    ui_rail "${C_BOLD}loomy privacy private${C_RESET}    ${C_DIM}$(t "outside the project repository, backed up in a private repository (public repository: recommended)")${C_RESET}"
    ui_end "$(t "GitHub doesn't handle visibility file by file: a repository is entirely public or private")"
    ;;
  versioned|local|private)
    ui_banner "$(t "AI files visibility")" "${ROOT/#$HOME/~}"
    ui_section "$(t "MODE")" "$(privacy_label "$CMD")"
    apply_mode "$CMD" || { ui_end "$(t "mode unchanged: %s" "$(privacy_label "$(privacy_mode "$ROOT")")")"; exit 1; }
    ui_ok "$(t "Mode saved")" "$(privacy_label "$CMD") · $(t "in .loomy/brief.md")"
    [[ "$CMD" != "versioned" ]] && warn_tracked
    ui_end "$(t "status: loomy privacy")$( [[ "$CMD" == private ]] && echo " · $(t "backup: loomy privacy sync")")"
    ;;
  apply)
    # Used by the questionnaire: applies the brief's mode, without header.
    apply_mode "$MODE" || exit 1
    ;;
  sync)
    if [[ "$MODE" != "private" ]]; then t "This project doesn't use a separate private repository (mode: %s)." "$(privacy_label "$MODE")" >&2; echo >&2; exit 1; fi
    do_sync || exit 1
    ;;
  adopt)
    # Explicit, user-run: validates a .loomy/ai.git Loomy did not create (older Loomy, a copied folder) and records it.
    if privacy_companion_ready "$ROOT"; then t "The private repository is already verified (.loomy/ai.git)." ; echo; exit 0; fi
    if problems="$(privacy_companion_adopt "$ROOT")"; then
      ui_ok "$(t "Private repository verified")" ".loomy/ai.git"
    else
      ui_err "$(t "Private repository refused")" ".loomy/ai.git"
      while IFS= read -r line; do [[ -z "$line" ]] || ui_rail "    ${C_DIM}$line${C_RESET}"; done <<<"$problems"
      ui_end "$(t "nothing was run or recorded; remove or fix what is listed, then loomy privacy adopt again")"
      exit 1
    fi
    ;;
  restore)
    [[ -n "$ARG" ]] || { t "Usage: loomy privacy restore <URL | account/repo>" >&2; echo >&2; exit 2; }
    if privacy_companion_ready "$ROOT"; then t "The private repository is already here (.loomy/ai.git): loomy privacy sync" >&2; echo >&2; exit 1; fi
    if privacy_companion_present "$ROOT"; then t "Private history not verified · run loomy privacy adopt" >&2; echo >&2; exit 1; fi
    url="$ARG"
    if [[ "$ARG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ! -e "$ARG" ]]; then url="https://github.com/$ARG.git"; fi
    ROOT="$(privacy_companion_worktree "$ROOT")" || { t "Can't restore: %s" "$url" >&2; echo >&2; exit 1; }
    loomy_git_user clone --bare -q "$url" "$(privacy_ai_git_dir "$ROOT")" || { t "Can't clone: %s" "$url" >&2; echo >&2; exit 1; }
    # The user cloned it themselves: record it, then drop anything a repository could carry beyond its objects.
    rm -rf "$(privacy_ai_git_dir "$ROOT")/hooks" "$(privacy_ai_git_dir "$ROOT")/info/attributes"
    privacy_companion_record "$ROOT" || { t "Can't clone: %s" "$url" >&2; echo >&2; rm -rf "$(privacy_ai_git_dir "$ROOT")"; exit 1; }
    privacy_companion_config "$ROOT"
    # Filter historical runtime paths before either backing up local files or materializing the old commit.
    if ! privacy_companion_restore_index "$ROOT"; then
      t "Can't restore: %s" "$url" >&2; echo >&2
      rm -rf "$(privacy_ai_git_dir "$ROOT")"; exit 1
    fi
    # Files already present: identical ones are kept; different ones are set aside before restoring.
    # Nothing is moved or written through a symlinked or foreign-owned directory: every parent component of every
    # restored path is checked first, and the whole restore is refused (before any move) if one is in the way.
    backup="$ROOT/.loomy/restore-backup-$(date +%Y%m%d-%H%M%S)"; moved=0
    blocked=""
    while IFS= read -r -d '' f; do
      d="$ROOT"; rest="$(dirname "$f")"
      if [[ "$rest" != . ]]; then
        old_ifs="$IFS"; IFS=/; set -f; for comp in $rest; do
          d="$d/$comp"
          if [[ -L "$d" || ( -e "$d" && ( ! -d "$d" || ! -O "$d" ) ) ]]; then blocked="${d#"$ROOT"/}"; break; fi
          [[ -e "$d" ]] || break
        done; set +f; IFS="$old_ifs"
      fi
      [[ -z "$blocked" ]] || break
    done < <(ai_git "$ROOT" ls-files -z 2>/dev/null)
    if [[ -n "$blocked" ]]; then
      t "Can't restore: %s" "$url" >&2; echo >&2
      t "A symlinked or foreign directory is in the way: %s. Nothing was moved or written." "$blocked" >&2; echo >&2
      rm -rf "$(privacy_ai_git_dir "$ROOT")"; exit 1
    fi
    while IFS= read -r -d '' f; do
      [[ -e "$ROOT/$f" || -L "$ROOT/$f" ]] || continue
      if [[ ! -L "$ROOT/$f" ]] && ai_git "$ROOT" show "HEAD:$f" 2>/dev/null | cmp -s - "$ROOT/$f"; then continue; fi
      mkdir -p "$backup/$(dirname "$f")" && mv "$ROOT/$f" "$backup/$f" && moved=$(( moved + 1 ))
    done < <(ai_git "$ROOT" ls-files -z 2>/dev/null)
    if ! ai_git "$ROOT" checkout-index --all --force 2>/dev/null; then
      t "Can't restore: %s" "$url" >&2; echo >&2
      if (( moved > 0 )); then t "%s different local file(s) set aside" "$moved" >&2; echo " (${backup#"$ROOT"/})" >&2; fi
      rm -rf "$(privacy_ai_git_dir "$ROOT")"; exit 1
    fi
    if (( moved > 0 )); then ui_warn "$(t "%s different local file(s) set aside" "$moved")" "${backup#"$ROOT"/}"; fi
    [[ -n "$GIT_ROOT" ]] && privacy_add_exclude "$ROOT"
    privacy_set_mode "$ROOT" private
    ui_ok "$(t "AI files recovered")" "$url"
    ;;
esac

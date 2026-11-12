# Read-only doctor checks; paths and bounded metadata only, never transcript/error content.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW);
use Cwd qw(abs_path);
my ($root,$codex,$claude)=@ARGV;
$root=abs_path($root)//exit;
for my $path ($codex,"$claude/projects") {
    print "symlink\t$path\t0\n" if -l $path;
}
my $dir="$root/.loomy/logs";
sub safe {
    my $path=shift;
    while ($path ne '') {return 0 if -l $path; $path =~ s{/[^/]*$}{} } return 1;
}
# LOCK L3 owner facts: pure inspection (no election, no creation). Fixed machine codes and bounded,
# charset-limited fields only, never labels, prompts or paths from the record.
{
    my $clean=sub { my $v=defined($_[0]) && !ref($_[0]) ? "$_[0]" : ""; $v =~ s/[^A-Za-z0-9_.:\/-]/_/g; return length($v) ? substr($v,0,64) : "-" };
    my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+$}{};
    # These checks run before the plain-path gate below: inspect resolves both registered alias layouts.
    my $ctx=eval { require "$lib/runtime-paths.pl"; require "$lib/collector-owner.pl"; Loomy::RuntimePaths::resolve($root) };
    my $r=eval { Loomy::CollectorOwner::inspect($ctx) };
    my $phys=ref($ctx) eq "HASH" && defined $ctx->{root} ? "$ctx->{root}/.loomy/logs" : $dir;
    $r={status=>"unsafe",reason=>"invalid-context"} unless ref($r) eq "HASH";
    my $rec=ref($r->{record}) eq "HASH" ? $r->{record} : {};
    print join("\t","owner",map {$clean->($_)} @$r{qw(status reason file)},@$rec{qw(state build pid boot birth epoch scope_revision)}),"\n"
        unless ($r->{reason}//"") =~ /\A(?:disabled|missing-runtime)\z/;
    # An unsupported (future) checkpoint format is preserved, never repaired: say so, once for both tools.
    eval {
        require "$lib/live-state.pl";
        for my $tool (qw(codex claude)) {
            my $p=Loomy::LiveState::checkpoint_peek("$phys/$tool-native.idx");
            if (($p->{status}//"") eq "unsupported") { print "checkpoint\t".$clean->($p->{reason})."\n"; last }
        }
    };
    # A clone can ship runtime files: any tracked content under .loomy/logs is named.
    my @names;
    local %ENV=%ENV; delete @ENV{grep {/\AGIT_/} keys %ENV};
    if (open my $git,"-|","sh","-c",'exec git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$1" ls-files -z -- .loomy/logs 2>/dev/null',"sh",$root) {
        local $/="\0"; my $n=0;
        while (defined(my $name=<$git>)) { chomp $name; last if ++$n>1000; push @names,$name if @names<64 }
        close $git; print "committed\t$n\t".join(", ",grep {/\A[A-Za-z0-9._\/-]{1,120}\z/} @names[0..($#names>2 ? 2 : $#names)])."\n" if $n;
    }
    # Tracked runtime state (checkpoints, shards, markers, owner record, lock, or a tracked gitlink/symlink for .loomy)
    # is refused by the election too: named here with its `git rm --cached` remedy. Targeted, case-insensitive, bounded.
    my ($tp,$tw)=eval { Loomy::RuntimePaths::tracked_runtime($phys =~ s{/\.loomy/logs\z}{}r) };
    print "shipped\t$tp\n" if ($tw//"") eq "tracked" && $tp =~ m{\A[A-Za-z0-9._/-]{1,160}\z};
}
exit unless safe($dir) && -d $dir;
for my $entry (['events.jsonl',8388608],['codex-native.idx',2097152],['claude-native.idx',2097152]) {
    my ($name,$bound)=@$entry; my $path="$dir/$name";
    print "bounds\t$path\t".(-s $path)."\n" if safe($path) && -f $path && -s $path>$bound;
}
for my $tool (qw(codex claude)) {
    opendir my $d,$dir or next; my $total=0; my ($invalid,$invalid_bytes)=(0,0);
    for my $name (readdir $d) {
        if ($name =~ /^\Q$tool\E-native\.idx(?:\.bak)?\.invalid-\d+-\d+$/) {
            my $path="$dir/$name";
            if (safe($path) && -f $path) {++$invalid; $invalid_bytes+=-s $path}
        }
        next unless $name =~ /^\Q$tool\E-native\.idx\.files-[0-9a-f]{64}$/;
        my $path="$dir/$name"; next unless safe($path) && -f $path;
        my $bytes=-s $path; $total+=$bytes;
        print "bounds\t$path\t$bytes\n" if $bytes>262144;
    }
    print "bounds\t$dir/$tool-native.idx.files-*\t$total\n" if $total>16777216;
    print "quarantine\t$dir/$tool-native.idx\t$invalid / $invalid_bytes\n" if $invalid;
}
my $errors="$dir/watch-errors.log";
if (safe($errors) && sysopen(my $f,$errors,O_RDONLY|O_NOFOLLOW)) {
    my @st=stat($f); seek $f,($st[7]>4096 ? $st[7]-4096 : 0),0;
    sysread($f,my $tail,4096);
    my @rows=grep {/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ watch [a-z-]{1,40} [a-z-]{1,40}\z/} split /\n/,$tail;
    splice @rows,0,@rows-3 if @rows>3;
    print "error\t$errors\t$_\n" for @rows;
}

# Read-only doctor checks; paths and bounded metadata only, never transcript/error content.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW);
my ($root,$codex,$claude)=@ARGV;
for my $path ($codex,"$claude/projects") {
    print "symlink\t$path\t0\n" if -l $path;
}
my $dir="$root/.loomy/logs";
sub safe {
    my $path=shift;
    while ($path ne '') {return 0 if -l $path; $path =~ s{/[^/]*$}{} } return 1;
}
exit unless safe($dir) && -d $dir;
for my $entry (['events.jsonl',8388608],['codex-native.idx',2097152],['claude-native.idx',2097152]) {
    my ($name,$bound)=@$entry; my $path="$dir/$name";
    print "bounds\t$path\t".(-s $path)."\n" if safe($path) && -f $path && -s $path>$bound;
}
for my $tool (qw(codex claude)) {
    opendir my $d,$dir or next; my $total=0;
    for my $name (readdir $d) {
        next unless $name =~ /^\Q$tool\E-native\.idx\.files-[0-9a-f]{64}$/;
        my $path="$dir/$name"; next unless safe($path) && -f $path;
        my $bytes=-s $path; $total+=$bytes;
        print "bounds\t$path\t$bytes\n" if $bytes>262144;
    }
    print "bounds\t$dir/$tool-native.idx.files-*\t$total\n" if $total>16777216;
}
my $errors="$dir/watch-errors.log";
if (safe($errors) && sysopen(my $f,$errors,O_RDONLY|O_NOFOLLOW)) {
    my @st=stat($f); seek $f,($st[7]>4096 ? $st[7]-4096 : 0),0;
    sysread($f,my $tail,4096);
    my @rows=grep {/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ watch [a-z-]{1,40} [a-z-]{1,40}\z/} split /\n/,$tail;
    splice @rows,0,@rows-3 if @rows>3;
    print "error\t$errors\t$_\n" for @rows;
}

# Cache quota source discovery independently of payload changes; no credentials/network.
use strict;
use warnings;
use File::Find qw(find);
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
my ($dir,$cache,$now,$readonly)=@ARGV;
sub safe {
    my $p=shift; return 0 unless defined($p) && $p =~ m{^/};
    while ($p ne '') {return 0 if -l $p; $p =~ s{/[^/]*$}{} } return 1;
}
exit unless safe($dir) && -d $dir;
my $saved;
if (safe($cache) && sysopen(my $f,$cache,O_RDONLY|O_NOFOLLOW)) {
    sysread($f,my $raw,16384); $saved=eval {decode_json($raw)};
}
my ($path,$fresh)=('',0);
if (ref($saved) eq 'HASH' && ($saved->{dir}//'') eq $dir && $now-($saved->{checked}//0)<15
    && $now>=($saved->{checked}//0)) {
    $path=$saved->{path}//''; $fresh=1;
    $fresh=0 if $path ne '' && (!safe($path) || !-f $path);
}
unless ($fresh) {
    my $mtime=-1;
    find({no_chdir=>1,wanted=>sub {
        return unless /\.jsonl\z/ && !-l $_ && -f $_;
        my @st=stat($_); return unless @st && $st[9]>=$now-1209600;
        if ($st[9]>$mtime || ($st[9]==$mtime && $_ gt $path)) { $mtime=$st[9]; $path=$_ }
    }},$dir);
    if (!$readonly && safe($cache)) {
        my $tmp="$cache.$$";
        if (sysopen(my $f,$tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600)) {
            print $f encode_json({dir=>$dir,checked=>0+$now,path=>$path});
            close $f; rename $tmp,$cache or unlink $tmp;
        }
    }
}
if ($path ne '' && safe($path)) {
    my @st=stat($path); print "$st[9] $st[7]\t$path\n" if @st;
}

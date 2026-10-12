use strict;
use warnings;
use utf8;
my ($file,$count)=@ARGV;
open my $f,'<:encoding(UTF-8)',$file or die $!;
my $found=0;
if ($count eq 'neutral') {
    while (<$f>) {
        my $raw=$_; my ($text,@colors); $text=''; my $color=0;
        while (length $raw) {
            if ($raw=~s/^\e\[([0-9;]*)m//) { for(split /;/,$1){$color=0 if $_ eq '0' || $_ eq '39'; $color=$_ if /^(?:3[0-7]|9[0-7])$/}; next }
            $text.=substr($raw,0,1,''); push @colors,$color;
        }
        while ($text=~/(response received|end unconfirmed|réponse reçue|fin non confirmée)/g) {
            for my $i ($-[0]..$+[0]-1) { die 'unassessed/unconfirmed response styled as green success' if $colors[$i]==32 || $colors[$i]==92 }
            ++$found;
        }
    }
    die 'missing neutral terminal labels' unless $found>=2;
    exit 0;
}
while (<$f>) {
    my $raw=$_; my $plain=$raw; $plain=~s/\e\[[0-9;]*[A-Za-z]//g;
    next unless $plain=~/(?:waiting for|attend|attente de) \Q$count\E /;
    my $bold=0; my ($text,$marked)=('','');
    while (length $raw) {
        if ($raw=~s/^\e\[([0-9;]*)m//) { for(split /;/,$1){$bold=0 if $_ eq '0' || $_ eq '22'; $bold=1 if $_ eq '1'}; next }
        my $c=substr($raw,0,1,''); $text.=$c; $marked.=$c if $bold;
    }
    die "return box bold leaked outside count: $marked" unless $marked eq "$count";
    die 'missing return-box border or padding' unless $text=~/│  +[^│]+  +│/;
    ++$found;
}
die 'missing waiting return box' unless $found==1;

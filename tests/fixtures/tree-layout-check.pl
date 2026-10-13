use strict;
use warnings;
use utf8;
my ($file,$width,$advisor)=@ARGV;
open my $f,'<:encoding(UTF-8)',$file or die $!;
my @rows;
while (<$f>) { s/\e\[[0-9;]*[A-Za-z]//g; chomp; push @rows,substr($_,3) if /^│  / }
die 'missing diagram' unless @rows>=57;
for (@rows) { die "canvas overflows $width columns" if length($_)>$width-7 }
my @boxes;
while ($rows[27]=~/┌─+┐/g) { push @boxes,[$-[0],$+[0]-$-[0]] }
die 'missing child boxes' unless @boxes>=2;
my $expected=int(($width-7-($advisor ? 32 : 0)-2)/28); $expected=4 if $expected>4;
die "lost visible child cards: expected $expected, got ".scalar(@boxes) unless @boxes==$expected;
for my $box (@boxes) {
    my ($x,$w)=@$box; die 'child too narrow' if $w<26;
    for my $y (28..34) {
        die "broken child border row $y" unless substr($rows[$y],$x,1) eq '│' && substr($rows[$y],$x+$w-1,1) eq '│';
        die "missing child padding row $y" unless substr($rows[$y],$x+1,2) eq '  ' && substr($rows[$y],$x+$w-3,2) eq '  ';
    }
    die 'broken child bottom' unless substr($rows[35],$x,$w)=~/^└[─┴┬]+┘$/;
}
my @labels=('vocab_enrichissement_reprise','vocab_integration_finale');
for my $n (0..1) {
    my ($x,$w)=@{$boxes[$n]}; my $title='';
    for my $y (29,30) { my $s=substr($rows[$y],$x+3,$w-6); $s=~s/^\s+|\s+$//g; $title.=$s }
    die "lost or overlapped title $labels[$n]" unless $title eq $labels[$n];
}
my ($lead_x,$lead_w);
while ($rows[6]=~/┌─+┐/g) { ($lead_x,$lead_w)=($-[0],$+[0]-$-[0]) if $+[0]-$-[0]>=54 }
die 'missing wide lead' unless defined $lead_x;
for my $y (7..10) {
    die 'broken lead border' unless substr($rows[$y],$lead_x,1) eq '│' && substr($rows[$y],$lead_x+$lead_w-1,1) eq '│';
    die 'missing lead padding' unless substr($rows[$y],$lead_x+1,2) eq '  ' && substr($rows[$y],$lead_x+$lead_w-3,2) eq '  ';
}
if ($advisor) {
    for my $y (7..43) { die "broken advisor border row $y" unless substr($rows[$y],0,1) eq '│' && substr($rows[$y],25,1) eq '│' }
    die 'advisor overlaps roles' if $boxes[0][0]<32;
}
# Persistent idle agents have a checkmark; an open lead cannot claim completion.
for (@rows) { die 'invented DONE state' if /✓/ && !/idle|au repos/ }

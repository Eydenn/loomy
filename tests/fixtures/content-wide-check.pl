# Wide-label display checks: terminal cells (East Asian wide = 2, combining/zero-width = 0), never bytes or codepoints.
#   content-wide-check.pl width <file> <columns>            every line fits, valid UTF-8, no canvas filler leaks
#   content-wide-check.pl cap   <file> <cells> <label> <n> [regex]  at least n matching lines carry the label; from its first character
#                                                           to the end the text fits <cells> and is a whole-grapheme prefix
use strict; use warnings; use utf8;
use Encode qw(decode);
binmode STDERR, ':utf8';
my ($mode,$file,$limit,$label,$min,$filter)=@ARGV; $filter=decode('UTF-8',$filter//'.');
open my $h,'<:raw',$file or die "$file: $!\n";
my $raw=do { local $/; <$h> }; $raw =~ s/\e\[[0-9;?]*[A-Za-z]//g;
my $s=eval { decode('UTF-8',$raw,Encode::FB_CROAK) } // die "invalid UTF-8 in $file\n";
die "canvas filler or private-use leak in $file\n" if $s =~ /[\x{01}\x{e000}-\x{f8ff}]/;
sub cells {
  my $g=shift; my $w=0;
  for my $c (split //,$g) { next if $c =~ /[\p{M}\p{Cf}\p{Emoji_Modifier}]/; $w+=$c =~ /[\p{East_Asian_Width=Wide}\p{East_Asian_Width=Fullwidth}]/ ? 2 : 1 }
  $w=2 if $w && $g =~ /[\p{Emoji_Presentation}\p{Regional_Indicator}\x{fe0f}\x{20e3}]/;
  return $w;
}
sub total { my $t=0; $t+=cells($_) for $_[0] =~ /\X/g; return $t }
if ($mode eq 'width') {
  for my $line (split /\n/,$s) { my $w=total($line); die "$w cells > $limit in $file: $line\n" if $w>$limit }
} elsif ($mode eq 'cap') {
  $label=decode('UTF-8',$label); my ($first)=$label =~ /\A(\X)/; my @full=$label =~ /\X/g; my $n=0;
  for my $line (split /\n/,$s) {
    next unless $line =~ /$filter/; my $at=index($line,$first); next if $at<0; my $part=substr($line,$at); $part =~ s/\s+\z//; ++$n;
    die sprintf("%d cells > %d in %s: %s\n",total($part),$limit,$file,$line) if total($part)>$limit;
    (my $body=$part) =~ s/…\z//; $body =~ s/[ ]+\z//; my @g=$body =~ /\X/g;
    die "not a whole-grapheme prefix in $file: $line\n" if join('',@g) ne join('',@full[0..$#g]);
  }
  die "label not found often enough ($n < $min) in $file\n" if $n<$min;
} else { die "mode\n" }

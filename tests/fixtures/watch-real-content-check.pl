use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK);
my ($file,$mode,$lang,$width)=@ARGV;
open my $f,'<:raw',$file or die $!; local $/; my $s=decode('UTF-8',<$f>,FB_CROAK);
$s =~ s/\e\[[0-9;]*[A-Za-z]//g;
# Independent terminal-cell sum for these fixtures, including paired flags and
# zero-width marks/modifiers; length() alone misses CJK overflow.
sub display_cells {
    my $n=0;
    for my $c (split //,$_[0]) {
        next if $c =~ /[\p{M}\p{Cf}]/ || ord($c)>=0x1f3fb && ord($c)<=0x1f3ff;
        $n+=($c =~ /[\p{East_Asian_Width=Wide}\p{East_Asian_Width=Fullwidth}]/
            || $c =~ /\p{Emoji_Presentation}/ && $c !~ /\p{Regional_Indicator}/) ? 2 : 1;
    }
    return $n;
}
die "ungranted task leaked\n$s" if $s =~ /UNGRANTED_TASK_CANARY/;
die "render diagnostics\n$s" if $s =~ /Wide character|Undefined|unbound variable|syntax error|Can't locate/;
if ($mode ne 'bridge' && $mode ne 'hook') {
    for (split /\n/,$s) {die "native line exceeds $width terminal cells: $_\n" if display_cells($_)>$width}
    die "native state/model/effort lost\n$s" unless $s =~ /(?:6-luna|sonnet-5-5) max/ && $s =~ /running|en cours/;
    die "turn identity lost\n$s" unless $s =~ /turn [123]00087654321/;
}
if ($width>=170) {
    if ($mode eq 'codex-v1') {die "v1 work lost\n$s" unless $s =~ /consolidation/ && $s =~ /enrichment/ && $s =~ /vocabulary/}
    elsif ($mode eq 'codex-v2') {die "v2 identity/work lost\n$s" unless $s =~ /Lyra explorer inventory/ && $s =~ /Lyra explorer verification/ && $s =~ /Nova qa vocabulary/}
    elsif ($mode eq 'claude') {die "Claude descriptions lost\n$s" unless $s =~ /Claude description 1/ && $s =~ /Claude description 2/}
    elsif ($mode eq 'bridge') {die "bridge label/role lost\n$s" unless $s =~ /Bridge review/ && $s =~ /Reviewer|Relecteur/ && $s =~ /max/}
    elsif ($mode eq 'hook') {die "Claude types/descriptions lost\n$s" unless $s =~ /Explore/ && $s =~ /Plan/ && $s =~ /custom\.agent/ && $s =~ /Claude description/}
    elsif ($mode eq 'off') {
        my $unavailable=$lang eq 'fr' ? 'contexte indisponible' : 'context unavailable';
        my $mission=$lang eq 'fr' ? 'Rôle : lit le code' : 'Role: reads the code';
        die "fallback distinction lost\n$s" unless index($s,$mission)>=0 && index($s,$unavailable)>=0
            && $s =~ /explorer 100012345678/ && $s =~ /explorer 200012345678/ && $s =~ /agent 300012345678/;
    }
    elsif ($mode eq 'unicode') {die "Unicode title lost\n$s" unless $s =~ /かな語彙 e\x{301} 👩🏽/}
    elsif ($mode eq 'wide') {die "Japanese title lost\n$s" unless $s =~ /語彙 語彙 語彙/}
    elsif ($mode eq 'flags') {die "flag identity lost\n$s" unless $s =~ /🇯🇵 🇯🇵/}
    elsif ($mode eq 'halfwidth') {die "halfwidth kana lost\n$s" unless $s =~ /ｶﾞ ｶﾞ/}
}
die "split emoji cluster\n$s" if $s =~ /👩(?!🏽)/;
die "split flag cluster\n$s" if $s =~ /🇯(?!🇵)/ || $s =~ /(?<!🇯)🇵/;
1;

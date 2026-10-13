#!/usr/bin/env perl
# Read-only desktop resume discovery; no transcripts or prompts are copied.
use strict;
use warnings;
use Cwd qw(abs_path);
use JSON::PP qw(decode_json);
my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+$}{};
require "$lib/codex-native.pl";
require "$lib/claude-native.pl";
my ($tool,$root,$home)=@ARGV;
$root=abs_path($root)//exit 1;
sub uuid { defined $_[0] && $_[0] =~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i }
sub names {
    my ($dir,$pattern)=@_;
    return () unless Loomy::CodexNative::safe_path($dir);
    opendir my $dh,$dir or return ();
    return sort { $b cmp $a } grep { /$pattern/ } readdir $dh;
}
sub codex {
    my ($dir,$depth)=@_;
    for my $name (names($dir,$depth==3 ? qr/^rollout-.*\.jsonl$/ : qr/^\d{2,4}$/)) {
        my $path="$dir/$name";
        if ($depth<3) { my $id=codex($path,$depth+1); return $id if $id; next }
        # Metadata only, at most 256 KiB per candidate; newest dates first, first match wins.
        my $m=Loomy::CodexNative::metadata($path) or next;
        next unless uuid($m->{id}) && !$m->{parent};
        next unless $m->{cwd};
        my $cwd=abs_path($m->{cwd})//'';
        next unless $cwd eq $root || index($cwd,"$root/")==0;
        return $m->{id};
    }
    return '';
}
sub journal {
    my $f=Loomy::CodexNative::open_read("$root/.loomy/logs/events.jsonl") or return ();
    my $size=-s $f; my $offset=$size>262144 ? $size-262144 : 0;
    seek $f,$offset,0; sysread $f,my $buf,262144;
    $buf =~ s/^[^\n]*\n// if $offset;
    return map { my $d=eval { decode_json($_) }; ref($d) eq 'HASH' ? $d : () } split /\n/,$buf;
}
sub busy {
    my ($id,$path)=@_;
    my %print_owners;
    # A real terminal process owns the folder even before its first transcript write.
    if (open my $ps,'-|','ps','-axo','pid=,comm=,args=') {
        while (<$ps>) {
            next unless /^\s*(\d+)\s+(\S+)\s+(.+)$/;
            my ($pid,$comm,$args)=($1,$2,$3); my $cwd='';
            next unless $comm =~ m{(?:^|/)claude$} ||
                ($comm =~ m{(?:^|/)node$} && $args =~ m{(?:^|\s)\S*(?:/claude(?:\.js)?|/claude-code/\S+)(?:\s|$)});
            if ($args =~ /(?:^|\s)(?:-p|--print)(?:\s|=|$)/) {$print_owners{$pid}=1; next}
            if (-d "/proc/$pid") { $cwd=readlink("/proc/$pid/cwd")//'' }
            elsif (open my $ls,'-|','lsof','-a','-p',$pid,'-d','cwd','-Fn') {
                while (<$ls>) { $cwd=$1 if /^n(.*)\n$/ } close $ls;
            }
            return 1 if $cwd ne '' && (abs_path($cwd)//'') eq $root;
        }
        close $ps;
    }
    return 0 unless $path && time-(stat($path))[9]<10;
    my %owners;
    for my $d (journal()) {
        next unless ($d->{tool}//'') eq 'claude';
        my $sid=$d->{session}//$d->{session_id}//'';
        next if $sid && $sid ne $id;
        my $pid=$d->{owner_pid}//$d->{pid}//0;
        next unless $pid =~ /^\d+$/ && $pid>1;
        if (($d->{type}//'') eq 'session' && ($d->{event}//'') eq 'end') { delete $owners{$pid}; next }
        $owners{$pid}=1 if ($d->{pid_role}//'') eq 'owner' || (($d->{type}//'') eq 'session' && ($d->{event}//'') eq 'start');
    }
    return scalar grep { !$print_owners{$_} && Loomy::CodexNative::alive($_) } keys %owners;
}
if ($tool eq 'codex') { print codex("$home/.codex/sessions",0); exit 0 }
my $dir="$home/.claude/projects/".Loomy::ClaudeNative::slug($root);
my @files=grep { uuid(s/\.jsonl$//r) && -f "$dir/$_" } names($dir,qr/\.jsonl$/);
@files=sort { (stat("$dir/$b"))[9] <=> (stat("$dir/$a"))[9] || $b cmp $a } @files;
my $file=$files[0]//''; my $id=$file; $id =~ s/\.jsonl$//;
exit 3 if busy($id,$file ? "$dir/$file" : '');
print $id;

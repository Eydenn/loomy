#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
my ($root,$home)=@ARGV;
make_path("$root/sub", "$root-other", "$root/.loomy/logs");
sub rollout {
    my ($date,$clock,$id,$cwd,$source)=@_;
    my $dir="$home/.codex/sessions/$date"; make_path($dir);
    open my $f,'>',"$dir/rollout-2026-01-02T$clock-$id.jsonl" or die $!;
    print $f encode_json({type=>'session_meta',payload=>{id=>$id,cwd=>$cwd,source=>$source,developer_instructions=>'x'x70000}}),"\n";
    # Discovery must not read body records (including their unrelated cwd).
    print $f encode_json({type=>'event_msg',payload=>{cwd=>$root}}),"\n";
}
rollout('2025/12/31','08-00-00','11111111-1111-1111-1111-111111111111',$root,'cli');
rollout('2026/01/02','08-00-00','22222222-2222-2222-2222-222222222222',$root,'cli');
rollout('2026/01/02','09-00-00','33333333-3333-3333-3333-333333333333',"$root/sub",'vscode');
rollout('2026/01/02','10-00-00','44444444-4444-4444-4444-444444444444',$root,{subagent=>{thread_spawn=>{parent_thread_id=>'55555555-5555-5555-5555-555555555555'}}});
rollout('2026/01/03','11-00-00','66666666-6666-6666-6666-666666666666',"$root-other",'app');
my $slug=$root; $slug =~ s/[^A-Za-z0-9]/-/g;
my $dir="$home/.claude/projects/$slug"; make_path($dir);
for my $i (7,8) {
    my $id="$i"x8 . '-' . "$i"x4 . '-' . "$i"x4 . '-' . "$i"x4 . '-' . "$i"x12;
    open my $f,'>',"$dir/$id.jsonl" or die $!; print $f "{}\n"; close $f;
    utime time-100+$i,time-100+$i,"$dir/$id.jsonl";
}

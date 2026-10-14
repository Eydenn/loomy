#!/usr/bin/env bash
# S4 checkpoint/recovery, bounded journal and Round 4 Claude regressions.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-live-growth.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_NATIVE_NOW=1791853207 LOOMY_FIXTURE_NOW=1791853200
export LOOMY_JOURNAL=1 LOOMY_JOURNAL_TASKS=1
mkdir -p "$HOME"
PASS=0
# Exercise both the optional native codec and the mandatory pure-Perl fallback.
for codec in native pp; do
  LOOMY_TEST_CHECKPOINT_CODEC="$codec" perl - "$REPO" "$WORK/checkpoint-$codec" <<'PERL'
use strict;
use warnings;
use utf8;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
BEGIN {
    unshift @INC,sub {die 'fixture disables optional JSON::XS' if $_[1] eq 'JSON/XS.pm'}
        if ($ENV{LOOMY_TEST_CHECKPOINT_CODEC}//'') eq 'pp';
}
my ($repo,$dir)=@ARGV; make_path($dir); require "$repo/scripts/lib/live-state.pl";
my $idx="$dir/native.idx";
my $s={version=>1,files=>{'/source/fixture'=>{offset=>17,meta=>{id=>'fixture',cwd=>'/fixture/日本語'}}},
    seen=>{retained=>JSON::PP::true,disabled=>JSON::PP::false},sent=>{key=>"quote\" slash\\ newline\n"}};
Loomy::LiveState::checkpoint_save($idx,$s);
my $loaded=Loomy::LiveState::checkpoint_load($idx);
my $json=JSON::PP->new->canonical;
die 'checkpoint codec changed structure' unless $json->encode($loaded) eq $json->encode($s) && $loaded->{version}==2;
die 'checkpoint boolean incompatible with PP' unless ref($loaded->{seen}{retained}) eq 'JSON::PP::Boolean';
my $signature=Loomy::LiveState::file_signature($idx);
Loomy::LiveState::checkpoint_save($idx,$loaded);
die 'unchanged checkpoint rewritten' unless Loomy::LiveState::file_signature($idx) eq $signature && !-e "$idx.bak";
$loaded->{seen}{next}=1; Loomy::LiveState::checkpoint_save($idx,$loaded);
my $backup=Loomy::LiveState::checkpoint_load("$idx.bak");
die 'previous generation not preserved' unless $backup->{seen}{retained} && !$backup->{seen}{next};
my $backup_signature=Loomy::LiveState::file_signature("$idx.bak");
$signature=Loomy::LiveState::file_signature($idx);
Loomy::LiveState::checkpoint_save($idx,$loaded);
die 'unchanged backup rewritten' unless Loomy::LiveState::file_signature("$idx.bak") eq $backup_signature;
die 'unchanged primary rewritten' unless Loomy::LiveState::file_signature($idx) eq $signature;
chmod 0644,$idx or die; Loomy::LiveState::checkpoint_save($idx,$loaded);
for ($idx,"$idx.bak") {die 'checkpoint mode not private' unless ((stat($_))[2]&0777)==0600}
# A failed bound check must leave both durable generations untouched.
$loaded->{sent}{overflow}='x'x2097152;
die 'oversized checkpoint accepted' if eval {Loomy::LiveState::checkpoint_save($idx,$loaded); 1};
die 'overflow replaced primary' unless Loomy::LiveState::file_signature($idx) eq $signature;
die 'overflow replaced backup' unless Loomy::LiveState::file_signature("$idx.bak") eq $backup_signature;
die 'atomic temporary left behind' if glob "$idx.tmp.*";
print "PASS checkpoint $ENV{LOOMY_TEST_CHECKPOINT_CODEC}: JSON compatibility, unchanged writes, backup, modes and bounds\n";
my $sharded="$dir/sharded.idx";
my $large={files=>{map {("/source/$_",{offset=>$_,padding=>'x'x4096})} 1..520}};
Loomy::LiveState::checkpoint_save($sharded,$large);
open my $f,'<',$sharded or die; my $snapshot=JSON::PP::decode_json(do {local $/; <$f>}); close $f;
my %shards=map {($_=>Loomy::LiveState::file_signature("$sharded.$_"))} @{$snapshot->{source_shards}//[]};
die 'large checkpoint not sharded' unless keys %shards;
$large=Loomy::LiveState::checkpoint_load($sharded);
Loomy::LiveState::checkpoint_save($sharded,$large);
die 'unchanged shards rewritten' if grep {Loomy::LiveState::file_signature("$sharded.$_") ne $shards{$_}} keys %shards;
die 'unchanged sharded snapshot rewritten' if -e "$sharded.bak";
$large->{files}{'/source/1'}{offset}=2; Loomy::LiveState::checkpoint_save($sharded,$large);
die 'backup shards rewritten or pruned' if grep {Loomy::LiveState::file_signature("$sharded.$_") ne $shards{$_}} keys %shards;
open $f,'>',$sharded or die; print $f '{'; close $f;
die 'sharded backup lost' unless Loomy::LiveState::checkpoint_load($sharded)->{files}{'/source/1'}{offset}==1;
print "PASS checkpoint $ENV{LOOMY_TEST_CHECKPOINT_CODEC}: unchanged shards and backup recovery\n";
PERL
  PASS=$((PASS+1))
done
cmp "$WORK/checkpoint-native/native.idx" "$WORK/checkpoint-pp/native.idx"
PASS=$((PASS+1)); printf 'PASS checkpoint native/PP byte compatibility\n'
for finding in G2 G3 G4 G6 arrival-race growth prune migration crash-codex crash-claude reconstruct-codex reconstruct-claude crash-batch reconstruct-batch rotation corruption backup quarantine shards repair privacy; do
  perl "$REPO/tests/fixtures/growth-live.pl" "$REPO" "$WORK" "$finding"
  PASS=$((PASS+1)); printf 'PASS S4 %s\n' "$finding"
done
printf '%s S4 growth checks passed\n' "$PASS"

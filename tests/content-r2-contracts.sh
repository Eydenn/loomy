#!/usr/bin/env bash
# T0 contract probes only. No provider, network, user config or process census.
# Production bridge scratch, parser and cleanup integration belong to R2 T2.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---all}"
case "$MODE" in --all|--framing-only) ;; *) echo "usage: $0 [--all|--framing-only]" >&2; exit 2 ;; esac
if [[ "${2:-}" != --isolated ]]; then
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash "$REPO/tests/content-r2-contracts.sh" "$MODE" --isolated
fi

# guard.sh performs a process census on teardown; this API-only suite instead
# owns one private root and waits for its known synthetic child directly.
umask 077
WORK="$(mktemp -d /tmp/loomy-content-r2.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/runtime" TMPDIR="$WORK/tmp"
export CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude" LOOMY_SOCKET_DIR="$WORK/sockets"
export LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS="$REPO/tests/stubs"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
  "$XDG_RUNTIME_DIR" "$TMPDIR" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$LOOMY_SOCKET_DIR"

if [[ "$MODE" == --all ]]; then
  printf '# Read-only policy and recursive checkpoint contracts\n'
  perl "$REPO/tests/fixtures/content-r2-contracts.pl" "$REPO" "$WORK/policy"
fi

printf '# Synthetic output contract; not production bridge/provider evidence\n'
perl - "$WORK" <<'PERL'
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Fcntl qw(:DEFAULT);
use File::Path qw(remove_tree);
use File::Temp qw(tempdir);
use JSON::PP;
use POSIX ();

my ($work)=@ARGV;
my $CHUNK=65536;
my $ERROR_WINDOW=65536;
my $CAPTURE=1048576;
my $SENTINEL=$CAPTURE+1;
my $META_FIXTURE=4096; # Small metadata-fixture bound, not a provider parser limit.
my $block=pack('C*',0..255)x256;
my %expected=(
  0=>'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  1048576=>'fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83',
  1114112=>'92cfd5431e59266ba0671d2fb3a943039445e4a3a8002632118dfb3c78fe1b1f',
  67108864=>'281e519df3077b557c6b03f5da83c4e8d397219259615dd7c3308f89cae8f2a6',
);
my $known_child;
END { if (defined $known_child) {kill 'TERM',$known_child; waitpid($known_child,0)} }

sub observe {
  my ($s,$bytes)=@_;
  my $n=length($bytes);
  $s->{read_bytes}+=$n;
  $s->{max_read}=$n if $n>$s->{max_read};
  $s->{input_sha}->add($bytes);
  $s->{error_tail}.=$bytes;
  substr($s->{error_tail},0,length($s->{error_tail})-$ERROR_WINDOW,'')
    if length($s->{error_tail})>$ERROR_WINDOW;
  my $need=$SENTINEL-length($s->{capture});
  $s->{capture}.=substr($bytes,0,$need) if $need>0;
  my $held=length($bytes)+length($s->{error_tail})+length($s->{capture});
  $s->{peak_tracked_bytes}=$held if $held>$s->{peak_tracked_bytes};
}
sub state {
  return {read_bytes=>0,max_read=>0,error_tail=>'',capture=>'',peak_tracked_bytes=>0,
    input_sha=>Digest::SHA->new(256)};
}
sub write_all {
  my ($fh,$bytes)=@_;
  my $at=0;
  while ($at<length($bytes)) {
    my $n=syswrite($fh,$bytes,length($bytes)-$at,$at);
    die "synthetic write failed: $!" unless defined($n) && $n>0;
    $at+=$n;
  }
}

# A local feasibility oracle, deliberately not a reusable bridge scratch API.
# It retains opaque output until a known child exits, then hashes/discards the
# caller stream. The only raw file is the private synthetic execution spool.
sub deferred {
  my ($size,$child_status,%options)=@_;
  my $dir=tempdir('r2-synthetic-XXXXXX',DIR=>$ENV{XDG_RUNTIME_DIR},CLEANUP=>0);
  chmod 0700,$dir or die $!;
  my $path="$dir/output";
  sysopen(my $spool,$path,O_RDWR|O_CREAT|O_EXCL,0600) or die $!;
  binmode $spool;
  my $mode=(stat($spool))[2]&0777;
  pipe(my $reader,my $writer) or die $!;
  my $pid=fork(); die $! unless defined $pid;
  if (!$pid) {
    close $reader; close $spool;
    my $ok=eval {
      for (my $left=$size;$left>0;) {
        my $n=$left>$CHUNK ? $CHUNK : $left;
        write_all($writer,substr($block,0,$n)); $left-=$n;
      }
      close $writer or die $!;
      1;
    };
    if ($ok && $options{signal}) {
      $SIG{$options{signal}}='DEFAULT';
      kill $options{signal},$$;
      POSIX::_exit(99); # A synthetic signal that failed to terminate is an error.
    }
    POSIX::_exit($ok ? $child_status : 99);
  }
  $known_child=$pid;
  close $writer;
  my $s=state();
  my ($stored,$storage_failed,$caller_bytes,$max_replay)=(0,0,0,0);
  my $caller_sha=Digest::SHA->new(256);
  while (1) {
    my $n=sysread($reader,my $bytes,$CHUNK);
    die $! unless defined $n;
    last unless $n;
    observe($s,$bytes);
    # An injected write failure tests the no-successful-truncation rule. This
    # is not a claim that a real filesystem ENOSPC was induced.
    if (exists($options{fail_after}) && $stored+$n>$options{fail_after}) {
      my $keep=$options{fail_after}-$stored;
      write_all($spool,substr($bytes,0,$keep)) if $keep>0;
      $stored+=$keep if $keep>0;
      $storage_failed=1;
    } elsif (!$storage_failed) {
      write_all($spool,$bytes); $stored+=$n;
    }
  }
  close $reader;
  my $before_final_status=$caller_bytes;
  waitpid($pid,0)==$pid or die $!;
  my $wait_status=$?;
  my $provider_status=($wait_status&127) ? 128+($wait_status&127) : $wait_status>>8;
  my $status=$provider_status;
  undef $known_child;
  $status=1 if $storage_failed && !$status;
  if (!$status) {
    seek($spool,0,0) or die $!;
    while (1) {
      my $n=sysread($spool,my $bytes,$CHUNK);
      die $! unless defined $n;
      last unless $n;
      $caller_bytes+=$n; $caller_sha->add($bytes);
      $max_replay=$n if $n>$max_replay;
    }
  }
  my $result={
    %$s,status=>$status,provider_status=>$provider_status,stored_bytes=>$stored,
    caller_bytes=>$caller_bytes,before_final_status=>$before_final_status,
    input_digest=>$s->{input_sha}->hexdigest,caller_digest=>$caller_sha->hexdigest,
    capture_bytes=>length($s->{capture}),capture_eligible=>length($s->{capture})<=$CAPTURE ? 1 : 0,
    error_bytes=>length($s->{error_tail}),max_replay=>$max_replay,mode=>$mode,
    storage_failed=>$storage_failed,
  };
  delete @$result{qw(input_sha capture error_tail)};
  close $spool or die $!;
  unlink($path) or die $!; rmdir($dir) or die $!;
  $result->{scratch_removed}=!-e $dir ? 1 : 0;
  return $result;
}

for my $size (0,1048576,67108864) {
  my $s=deferred($size,0);
  is($s->{status},0,"success $size: terminal success");
  is($s->{before_final_status},0,"success $size: no premature caller bytes");
  is($s->{read_bytes},$size,"success $size: all provider bytes consumed");
  is($s->{stored_bytes},$size,"success $size: no scratch size cap");
  is($s->{caller_bytes},$size,"success $size: complete caller bytes");
  is($s->{input_digest},$expected{$size},"success $size: independent input digest");
  is($s->{caller_digest},$expected{$size},"success $size: identical caller digest");
  cmp_ok($s->{max_read},'<=',$CHUNK,"success $size: reads <= 64 KiB");
  cmp_ok($s->{max_replay},'<=',$CHUNK,"success $size: replay <= 64 KiB");
  cmp_ok($s->{error_bytes},'<=',$ERROR_WINDOW,"success $size: error window <= 64 KiB");
  cmp_ok($s->{capture_bytes},'<=',$SENTINEL,"success $size: optional capture <= 1 MiB + 1");
  cmp_ok($s->{peak_tracked_bytes},'<=',2*$CHUNK+$SENTINEL,"success $size: bounded tracked raw buffers");
  is($s->{capture_eligible},$size<=$CAPTURE ? 1 : 0,"success $size: oversize optional capture refused");
  is($s->{mode},0600,"success $size: synthetic spool private");
  ok($s->{scratch_removed},"success $size: synthetic spool removed");
  diag(JSON::PP->new->canonical->encode({probe=>'synthetic-deferred',%$s}));
}

my @late;
for my $status (0,1,75) {
  my $s=deferred(1114112,$status);
  is($s->{provider_status},$status,"late status $status: child exit retained");
  is($s->{status},$status,"late status $status: caller exit unchanged");
  is($s->{input_digest},$expected{1114112},"late status $status: identical arbitrary prefix");
  is($s->{before_final_status},0,"late status $status: prefix withheld until status");
  is($s->{caller_bytes},$status ? 0 : 1114112,"late status $status: success-only caller delivery");
  push @late,$s->{input_digest};
}
is_deeply(\@late,[($expected{1114112})x3],'late failure/75 cannot be distinguished by the preceding output');
for my $signal ([HUP=>129],[INT=>130],[TERM=>143]) {
  my $s=deferred(1048576,0,signal=>$signal->[0]);
  is($s->{status},$signal->[1],"synthetic child $signal->[0]: conventional signal exit retained");
  is($s->{caller_bytes},0,"synthetic child $signal->[0]: late output remains withheld");
  is($s->{read_bytes},1048576,"synthetic child $signal->[0]: complete prefix is consumed before signal");
  ok($s->{scratch_removed},"synthetic child $signal->[0]: local probe removes its owned spool");
}
my $full=deferred(1048576,0,fail_after=>65536);
ok($full->{storage_failed},'injected scratch write failure is observed');
is($full->{status},1,'scratch write failure cannot return success');
is($full->{caller_bytes},0,'scratch write failure cannot deliver a successful truncated prefix');
is($full->{read_bytes},1048576,'failure path drains and waits for the known local child');

for my $size ($CAPTURE-1,$CAPTURE,$CAPTURE+1,$CAPTURE+$CHUNK) {
  my $s=state();
  for (my $left=$size;$left>0;) {
    my $n=$left>$CHUNK ? $CHUNK : $left; observe($s,'x'x$n); $left-=$n;
  }
  is(length($s->{capture}),$size>$SENTINEL ? $SENTINEL : $size,"optional $size: one-byte sentinel bound");
  is(length($s->{capture})<=$CAPTURE ? 1 : 0,$size<=$CAPTURE ? 1 : 0,"optional $size: never accept a partial oversized result");
}
my $window=state();
observe($window,'a'x$CHUNK); observe($window,'b'x$CHUNK); observe($window,'tail');
is($window->{error_tail},('b'x($ERROR_WINDOW-4)).'tail','classification window retains exactly the bounded suffix');

# Small synthetic protocol frames freeze escaping, record boundaries and late
# metadata, independently of the unbounded opaque-byte delivery probe above.
# JSON::PP is used only on these <= 4 KiB fixtures. It is not an arbitrary-size
# streaming parser and does not establish real provider framing/CLI support.
my $json=JSON::PP->new->utf8->canonical;
my $answer="no trailing newline: quote=\" slash=\\ tab=\t nul=\0 wave=\x{1f30a}";
my $codex=$json->encode({type=>'item.completed',item=>{type=>'agent_message',text=>$answer}})."\n".
  $json->encode({type=>'turn.completed',usage=>{input_tokens=>12,cached_input_tokens=>4,output_tokens=>9}})."\n";
for my $piece (1,7,$CHUNK) {
  my ($pending,@events)=('');
  for (my $at=0;$at<length($codex);$at+=$piece) {
    $pending.=substr($codex,$at,$piece);
    while ($pending=~s/\A([^\n]*)\n//) {push @events,$json->decode($1)}
    die 'metadata fixture exceeded its separate bound' if length($pending)>$META_FIXTURE;
  }
  is($pending,'',"Codex fixture $piece-byte fragments: complete NDJSON boundary");
  is($events[0]{item}{text},$answer,"Codex fixture $piece-byte fragments: exact escapes/Unicode/NUL/no LF");
  is_deeply($events[1]{usage},{input_tokens=>12,cached_input_tokens=>4,output_tokens=>9},"Codex fixture $piece-byte fragments: terminal usage after answer");
}
for my $is_error (JSON::PP::false,JSON::PP::true) {
  # The result precedes is_error/usage in this wire fixture intentionally.
  my $wire='{"result":'.$json->encode($answer).',"is_error":'.($is_error?'true':'false').
    ',"usage":{"input_tokens":12,"output_tokens":9},"type":"result"}';
  cmp_ok(length($wire),'<=',$META_FIXTURE,'Claude metadata fixture has a separate finite bound');
  my $value=$json->decode($wire);
  is(sha256_hex(encode('UTF-8',$value->{result})),sha256_hex(encode('UTF-8',$answer)),'Claude fixture: escaped result bytes unchanged');
  is($value->{is_error}?1:0,$is_error?1:0,'Claude fixture: terminal logical failure may follow the answer');
  is($value->{usage}{output_tokens},9,'Claude fixture: accounting survives late logical failure');
}
for my $bad ('{"result":"unterminated','{"type":"result"} trailing') {
  ok(!eval {$json->decode($bad); 1},'malformed/trailing framing cannot become a successful synthetic frame');
}
diag('Real-provider framing and provider-created-file feasibility: NOT RUN / NOT VERIFIED; no provider flags tested');
done_testing();
PERL

printf '# Bash descriptor probe: %s\n' "$BASH_VERSION"
cat >"$WORK/fstat.pl" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:mode);
use Digest::SHA;
use JSON::PP;
my @s=stat(STDIN); die $! unless @s;
my ($n,$max)=(0,0); my $sha=Digest::SHA->new(256);
while (1) {my $r=sysread(STDIN,my $b,65536); die $! unless defined $r; last unless $r; $n+=$r; $max=$r if $r>$max; $sha->add($b)}
print JSON::PP->new->canonical->encode({kind=>S_ISREG($s[2])?'REG':S_ISFIFO($s[2])?'FIFO':'OTHER',
  nlink=>$s[3],mode=>$s[2]&0777,bytes=>$n,max_read=>$max,sha256=>$sha->hexdigest}),"\n";
PERL
PAYLOAD="$(perl -e 'print "H" x 110592')"
perl "$WORK/fstat.pl" <<<"$PAYLOAD" >"$WORK/here.json"
printf '%s\n' "$PAYLOAD" | perl "$WORK/fstat.pl" >"$WORK/pipe.json"
unset PAYLOAD
perl - "$WORK/here.json" "$WORK/pipe.json" "$BASH_VERSION" <<'PERL'
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use JSON::PP;
my @r;
for my $path (@ARGV[0,1]) {open my $h,'<',$path or die $!; local $/; push @r,decode_json(<$h>)}
is($r[0]{kind},'REG','110592-byte Bash here-string uses a regular file');
is($r[1]{kind},'FIFO','same builtin printf stream uses a pipe');
for my $i (0,1) {
  is($r[$i]{nlink},0,"descriptor $i: zero links alone does not prove disk-free");
  is($r[$i]{bytes},110593,"descriptor $i: payload plus exactly one LF");
  is($r[$i]{sha256},sha256_hex(('H'x110592)."\n"),"descriptor $i: exact payload digest");
  cmp_ok($r[$i]{max_read},'<=',65536,"descriptor $i: bounded reads");
  diag(JSON::PP->new->canonical->encode({probe=>$i?'pipe':'here-string',bash=>$ARGV[2],%{$r[$i]}}));
}
is($r[0]{mode},0600,'unlinked here-string regular file is private but remains raw scratch');
diag('Bash 3.2 acceptance is VERIFIED only when the reported native version is 3.2; other versions do not establish that platform gate');
done_testing();
PERL

# SKILLS_CONTRACTS_BEGIN: adopted from the skills lane, no evidence-file dependency.
if [[ "$MODE" == --all ]]; then
  printf '# Typed skills matcher and pipe transport contracts\n'
  (
SK_CONTRACT_REPO="$REPO"
SK_CONTRACT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/loomy-r2-skills.XXXXXX")"
trap 'rm -rf "$SK_CONTRACT_WORK"' EXIT
mkdir -p "$SK_CONTRACT_WORK/project/.loomy" "$SK_CONTRACT_WORK/scratch"
SK_CONTRACT_CATALOG="$SK_CONTRACT_REPO/catalog/skills.conf"
SK_CONTRACT_COUNT=0
SK_CONTRACT_FAILURES=0
ai_journal_write() { :; }
# shellcheck source=../../scripts/lib/skills.sh
source "$SK_CONTRACT_REPO/scripts/lib/skills.sh"
skills_catalog() { builtin printf '%s\n' "$SK_CONTRACT_CATALOG"; }
sk_contract_expect() {
  local label="$1" expected="$2" actual="$3"
  SK_CONTRACT_COUNT=$((SK_CONTRACT_COUNT + 1))
  if [[ "$actual" == "$expected" ]]; then
    builtin printf 'ok %s - skills: %s\n' "$SK_CONTRACT_COUNT" "$label"
  else
    builtin printf 'not ok %s - skills: %s\n' "$SK_CONTRACT_COUNT" "$label"
    SK_CONTRACT_FAILURES=$((SK_CONTRACT_FAILURES + 1))
  fi
}
SK_CONTRACT_WEB=$'webapp-testing\nfrontend-design'
SK_CONTRACT_SECURITY=$'security-best-practices\nsecurity-threat-model'
sk_contract_expect 'existing web fixture and catalog order' "$SK_CONTRACT_WEB"$'\n'"$SK_CONTRACT_SECURITY"$'\nvercel-deploy' "$(skills_auto_for_values web auth,payments vercel)"
sk_contract_expect 'site cloudflare matrix' "$SK_CONTRACT_WEB"$'\n'"$SK_CONTRACT_SECURITY"$'\ncloudflare-deploy' "$(skills_auto_for_values site personal cloudflare)"
sk_contract_expect 'API clauses combine with AND' $'security-best-practices\ncloudflare-deploy' "$(skills_auto_for_values api publicapi cloudflare)"
sk_contract_expect 'data type' jupyter-notebook "$(skills_auto_for_values data '' '')"
sk_contract_expect 'AI OpenAI selection' openai-docs "$(skills_auto_for_values ai '' openai)"
sk_contract_expect 'AI Anthropic and traits' $'claude-api\nsecurity-best-practices\nsecurity-threat-model' "$(skills_auto_for_values ai infra anthropic)"
sk_contract_expect 'AI multi selection retains catalog order' $'claude-api\nsecurity-best-practices\nsecurity-threat-model\nopenai-docs' "$(skills_auto_for_values ai personal multi)"
sk_contract_expect 'CSV alternatives use OR' $'claude-api\nopenai-docs' "$(skills_auto_for_values ai '' anthropic,openai)"
sk_contract_expect 'CSV detail alternatives' "$SK_CONTRACT_WEB"$'\nvercel-deploy\ncloudflare-deploy' "$(skills_auto_for_values web '' vercel,cloudflare)"
sk_contract_expect 'traits match independently from type' security-best-practices "$(skills_auto_for_values '' auth vercel)"
sk_contract_expect 'unknown inputs have no recommendation' '' "$(skills_auto_for_values unknown unknown unknown)"
sk_contract_expect 'CSV boundaries are exact' '' "$(skills_auto_for_values unknown authenticator,payment,personalized,publicapis,infrared,multitenants unknown)"
sk_contract_expect 'unknown CSV members do not hide known values' $'security-best-practices\ncloudflare-deploy' "$(skills_auto_for_values api unknown,auth unknown,cloudflare)"
sk_contract_expect 'empty values' '' "$(skills_auto_for_values '' '' '')"
sk_contract_expect 'missing optional values under nounset' '' "$(skills_auto_for_values)"

# These are pre-existing brief fixtures containing typed selections, not free-text matcher scratch.
builtin printf 'type: web\ntraits: "auth,payments"\ndetail1: vercel\n' >"$SK_CONTRACT_WORK/project/.loomy/brief.md"
sk_contract_expect 'root wrapper retains existing brief behavior' "$SK_CONTRACT_WEB"$'\n'"$SK_CONTRACT_SECURITY"$'\nvercel-deploy' "$(skills_auto_for "$SK_CONTRACT_WORK/project")"
builtin printf 'type: api\ntraits: ""\nsensitive: personal\ndetail1: cloudflare\n' >"$SK_CONTRACT_WORK/project/.loomy/brief.md"
sk_contract_expect 'empty traits falls back to sensitive' "$SK_CONTRACT_SECURITY"$'\ncloudflare-deploy' "$(skills_auto_for "$SK_CONTRACT_WORK/project")"
builtin printf 'type: api\ntraits: auth\nsensitive: payments\ndetail1: cloudflare\n' >"$SK_CONTRACT_WORK/project/.loomy/brief.md"
sk_contract_expect 'nonempty traits wins over sensitive' $'security-best-practices\ncloudflare-deploy' "$(skills_auto_for "$SK_CONTRACT_WORK/project")"
sk_contract_expect 'missing brief does not create a project' '' "$(skills_auto_for "$SK_CONTRACT_WORK/missing")"
sk_contract_expect 'missing project remains absent' false "$(if [[ -e "$SK_CONTRACT_WORK/missing" ]]; then builtin printf true; else builtin printf false; fi)"

sk_contract_expect 'task fixture CI suggestion' gh-fix-ci "$(skills_suggest "$SK_CONTRACT_WORK/project" 'fix the failing GitHub Actions checks')"
sk_contract_expect 'task multiword scoring' $'playwright\nwebapp-testing' "$(skills_suggest "$SK_CONTRACT_WORK/project" 'playwright browser automation')"
sk_contract_expect 'task whole-word negative fixture' '' "$(skills_suggest "$SK_CONTRACT_WORK/project" 'Fix the build and improve precision of the crossword solver' 3)"
sk_contract_expect 'task normalization and Unicode catalog keywords' $'pptx\nxlsx' "$(skills_suggest "$SK_CONTRACT_WORK/project" 'Créer une présentation PowerPoint et un tableau Excel')"
sk_contract_expect 'task scores and catalog tie sorting' $'cloudflare-deploy\nvercel-deploy' "$(skills_suggest "$SK_CONTRACT_WORK/project" 'deploy cloudflare')"
sk_contract_expect 'task explicit limit' playwright "$(skills_suggest "$SK_CONTRACT_WORK/project" 'playwright browser automation' 1)"
builtin printf 'playwright|openai|skills/playwright|abcdef0|Apache-2.0|2026-10-27|old prose|old analysis\n' >"$SK_CONTRACT_WORK/project/.loomy/skills.lock"
sk_contract_expect 'task installed filter' webapp-testing "$(skills_suggest "$SK_CONTRACT_WORK/project" 'playwright browser automation')"
rm "$SK_CONTRACT_WORK/project/.loomy/skills.lock"

# Closed auto conditions: AND/OR, order, proprietary/no/empty, unknown key, and empty trailing clause.
cat >"$SK_CONTRACT_WORK/catalog.conf" <<'CATALOG'
# Synthetic catalog; no free-text input is written here.
date=2099-01-01
first|openai|p|abcdef0|MIT|type=web,site;trait=auth,payments;detail1=vercel,cloudflare|alpha|first
second|openai|p|abcdef0|MIT|type=web|beta|second
proprietary|anthropic|p|abcdef0|proprietary|type=web|gamma|excluded
manual|openai|p|abcdef0|MIT|no|delta|excluded
empty|openai|p|abcdef0|MIT||epsilon|excluded
unknown|openai|p|abcdef0|MIT|unknown=web|zeta|excluded
trailing|openai|p|abcdef0|MIT|type=web;|eta|excluded
CATALOG
SK_CONTRACT_CATALOG="$SK_CONTRACT_WORK/catalog.conf"
sk_contract_expect 'condition domains and exclusions' $'first\nsecond' "$(skills_auto_for_values web auth vercel)"
sk_contract_expect 'all clauses must match' second "$(skills_auto_for_values web '' vercel)"
sk_contract_expect 'values within clauses use OR' first "$(skills_auto_for_values site payments cloudflare)"
SK_CONTRACT_CATALOG="$SK_CONTRACT_REPO/catalog/skills.conf"

# Raw canaries are created only in shell memory. External wrappers see argv before exec and fail closed.
# Marker-only receipts survive command-substitution subshells; failure output never repeats raw values.
SK_CONTRACT_CANARY=r2skillsrawcanary
sk_contract_guard() {
  local tool="$1" arg inherited
  shift
  for arg in "$@"; do
    if [[ "$arg" == *"$SK_CONTRACT_CANARY"* ]]; then
      builtin printf '%s argv\n' "$tool" >>"$SK_CONTRACT_WORK/violations"
      return 97
    fi
  done
  inherited="$(export -p)"
  if [[ "$inherited" == *"$SK_CONTRACT_CANARY"* ]]; then
    builtin printf '%s environment\n' "$tool" >>"$SK_CONTRACT_WORK/violations"
    return 97
  fi
  case "$tool" in
    perl|tr)
      if [[ ! -p /dev/fd/0 ]]; then
        builtin printf '%s non-pipe-stdin\n' "$tool" >>"$SK_CONTRACT_WORK/violations"
        return 97
      fi ;;
    mktemp|tee)
      builtin printf '%s scratch-attempt\n' "$tool" >>"$SK_CONTRACT_WORK/violations"
      return 97 ;;
  esac
  return 0
}
for SK_CONTRACT_TOOL in perl awk tr sed grep sort cut head cat tee mktemp env printf; do
  eval "$SK_CONTRACT_TOOL() { sk_contract_guard $SK_CONTRACT_TOOL \"\$@\" || return; command $SK_CONTRACT_TOOL \"\$@\"; }"
done
export TMPDIR="$SK_CONTRACT_WORK/scratch"
sk_contract_expect 'raw type never reaches external argv or environment' '' "$(skills_auto_for_values "$SK_CONTRACT_CANARY" '' '')"
sk_contract_expect 'raw traits never reach external argv or environment' "$SK_CONTRACT_SECURITY" "$(skills_auto_for_values unknown "personal,$SK_CONTRACT_CANARY" '')"
sk_contract_expect 'raw detail never reaches external argv or environment' "$SK_CONTRACT_WEB"$'\nvercel-deploy' "$(skills_auto_for_values web '' "vercel,$SK_CONTRACT_CANARY")"
sk_contract_expect 'embedded newlines stay literal in each value' '' "$(skills_auto_for_values "$SK_CONTRACT_CANARY"$'\nweb' "$SK_CONTRACT_CANARY"$'\nauth' "$SK_CONTRACT_CANARY"$'\nvercel')"
sk_contract_expect 'literal backslash escapes cannot become typed selections' '' "$(skills_auto_for_values 'w\x65b' '\x61uth' '\x76ercel')"
sk_contract_expect 'Unicode and quotes stay literal in typed inputs' '' "$(skills_auto_for_values "日本語 $SK_CONTRACT_CANARY" '"auth"' '"vercel"')"
sk_contract_expect 'task canary uses pipes without changing recommendations' $'playwright\nwebapp-testing' "$(skills_suggest "$SK_CONTRACT_WORK/project" "playwright browser automation $SK_CONTRACT_CANARY")"
sk_contract_expect 'task multiline boundaries remain literal' '' "$(skills_suggest "$SK_CONTRACT_WORK/project" "$SK_CONTRACT_CANARY"$'\nci\nplaywright')"
sk_contract_expect 'task literal backslash is normalized without interpretation' '' "$(skills_suggest "$SK_CONTRACT_WORK/project" "$SK_CONTRACT_CANARY"' \x63i')"
builtin printf -v SK_CONTRACT_PADDING '%110592s' ''
sk_contract_expect 'oversized values keep matching known CSV selections' "$SK_CONTRACT_WEB"$'\n'"$SK_CONTRACT_SECURITY"$'\nvercel-deploy' "$(skills_auto_for_values web "personal,$SK_CONTRACT_CANARY$SK_CONTRACT_PADDING" "vercel,$SK_CONTRACT_CANARY$SK_CONTRACT_PADDING")"
sk_contract_expect 'oversized task still has complete keyword input' $'playwright\nwebapp-testing' "$(skills_suggest "$SK_CONTRACT_WORK/project" "$SK_CONTRACT_CANARY$SK_CONTRACT_PADDING playwright browser automation")"
sk_contract_expect 'no guarded argv, environment, descriptor or scratch violations' false "$(if [[ -e "$SK_CONTRACT_WORK/violations" ]]; then builtin printf true; else builtin printf false; fi)"
sk_contract_expect 'scratch directory remains empty' '' "$(find "$SK_CONTRACT_WORK/scratch" -mindepth 1 -print)"
builtin printf '1..%s\n' "$SK_CONTRACT_COUNT"
[[ "$SK_CONTRACT_FAILURES" == 0 ]]
  )
fi
# SKILLS_CONTRACTS_END

printf '# Real-provider feasibility: NOT RUN / NOT VERIFIED (no provider calls or new flags)\n'

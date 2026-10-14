#!/usr/bin/env bash
# A real watch controller with pipe input proves reducer exceptions do not end its lifetime.
set -euo pipefail
REPO="$1"; WORK="$2"; runtime="$WORK/error-runtime"; root="$WORK/error-project"
poll_limit="$(command perl -MPOSIX=ceil -e 'require $ARGV[0]; print ceil(Loomy::TestTiming::budget(100))' "$REPO/tests/fixtures/time-scale.pl")"
opt_out_wait="$(command perl "$REPO/tests/fixtures/time-scale.pl" 2)"
mkdir -p "$runtime" "$root/.loomy"
cp -R "$REPO/scripts" "$runtime/"
cat >>"$runtime/scripts/lib/live-state.pl" <<'PERL'
package Loomy::LiveState;
my $original=\&read_journal;
my $injected=0;
no warnings 'redefine';
*read_journal=sub {die "INJECTED_PRIVATE_REDUCER_ERROR" unless $injected++; goto &$original};
PERL
{
  # Wait for the injected reducer observation, rather than racing a cold sampler's first frame.
  for (( i=0; i<poll_limit; i++ )); do [[ ! -s "$root/.loomy/logs/watch-errors.log" ]] || break; sleep 0.1; done
  if [[ ! -s "$root/.loomy/logs/watch-errors.log" ]]; then
    printf 'FAIL reducer diagnostic missing after %s polls of 100 ms (budget <%s polls)\n' "$i" "$poll_limit" >&2
    printf 'q\n'; exit 1
  fi
  printf 'q\n'
} | bash "$runtime/scripts/loomy-status.sh" --root "$root" --watch >"$WORK/error-frame" 2>"$WORK/error-stderr"
grep -q 'watch reducer exception' "$root/.loomy/logs/watch-errors.log"
if grep -q 'INJECTED_PRIVATE' "$root/.loomy/logs/watch-errors.log" "$WORK/error-stderr"; then
  printf 'FAIL reducer diagnostic content leaked\n' >&2; exit 1
fi
readonly_root="$WORK/error-opt-out"; mkdir -p "$readonly_root/.loomy"
{ sleep "$opt_out_wait"; printf 'q\n'; } | LOOMY_JOURNAL=0 bash "$runtime/scripts/loomy-status.sh" --root "$readonly_root" --watch >"$WORK/opt-out-frame" 2>"$WORK/opt-out-stderr"
[[ ! -e "$readonly_root/.loomy/logs/watch-errors.log" ]]
printf 'PASS injected reducer pipe controller: continued watch, q, content-free diagnostics and opt-out\n'

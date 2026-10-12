#!/usr/bin/env bash
# Record only this test's sampler; all Perl behavior remains real.
if [[ "${1:-}" == -MIO::Select && "${2:-}" == -MTime::HiRes=time,stat ]]; then
  printf '%s\n' "$$" >"$WATCH_BACKPRESSURE_SAMPLER"
fi
exec /usr/bin/perl "$@"

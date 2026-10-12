#!/usr/bin/env bash
# Keep the real reducer, replacing only expensive diagram rendering in an isolated checkout.
if [[ "${1:-}" == --library ]]; then
  source "${BASH_SOURCE[0]%/*}/loomy-tree-real.sh" --library
  return 0
fi
perl -MTime::HiRes=time,sleep -e '
  my ($tick,$trace,$delay)=@ARGV; my $start=time;
  open my $f,">>",$trace or die $!;
  print $f join("|",$start,$tick,$$),"\n"; close $f;
  sleep($delay);
  printf "BACKPRESSURE_FRAME tick=%s start=%.3f\n",$tick,$start;
' "$LOOMY_TICK" "$WATCH_BACKPRESSURE_TRACE" "${WATCH_BACKPRESSURE_DELAY:-1.4}"

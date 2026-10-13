#!/usr/bin/env bash
# Keep the real reducer, replacing only expensive diagram rendering in an isolated checkout.
if [[ "${1:-}" == --library ]]; then
  source "${BASH_SOURCE[0]%/*}/loomy-tree-real.sh" --library
  eval "$(declare -f loomy_native_render | sed '1s/loomy_native_render/_loomy_native_render_real/')"
  eval "$(declare -f loomy_live_render | sed '1s/loomy_live_render/_loomy_live_render_real/')"
  loomy_live_render() {
    if (( NS_ENABLED )); then _loomy_native_render_real; else _loomy_live_render_real; fi
  }
  loomy_native_render() {
    if [[ "${WATCH:-0}" != 1 || "${view:-}" != tree ]]; then _loomy_native_render_real; return 0; fi
    perl -MTime::HiRes=time,sleep -e '
      my ($tick,$trace,$delay)=@ARGV; my $start=time;
      open my $f,">>",$trace or die $!; print $f join("|",$start,$tick,$$),"\n"; close $f;
      sleep($delay); printf "BACKPRESSURE_FRAME tick=%s start=%.3f\n",$tick,$start;
    ' "$LOOMY_TICK" "$WATCH_BACKPRESSURE_TRACE" "${WATCH_BACKPRESSURE_DELAY:-1.4}"
  }
  return 0
fi
perl -MTime::HiRes=time,sleep -e '
  my ($tick,$trace,$delay)=@ARGV; my $start=time;
  open my $f,">>",$trace or die $!;
  print $f join("|",$start,$tick,$$),"\n"; close $f;
  sleep($delay);
  printf "BACKPRESSURE_FRAME tick=%s start=%.3f\n",$tick,$start;
' "$LOOMY_TICK" "$WATCH_BACKPRESSURE_TRACE" "${WATCH_BACKPRESSURE_DELAY:-1.4}"

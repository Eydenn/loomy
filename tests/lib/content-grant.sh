#!/usr/bin/env bash
# Test-only human input doubles. Exercise the real first-use transaction, lock,
# recommended source selection and policy writer; production guards stay intact.
test_content_grant() (
  local repo="$1" root="$2"; shift 2
  [[ "${LOOMY_TEST_GUARD:-}" == 1 && -n "${WORK:-}" && "$root" == "$WORK/"* && ! -L "$root/.loomy" ]] || {
    printf 'test grant requires a guarded isolated project\n' >&2; return 2
  }
  # shellcheck source=../../scripts/lib/content-policy.sh
  source "$repo/scripts/lib/content-policy.sh"
  _loomy_content_ui
  perl -e '
    require shift; my $root=shift;
    no warnings "redefine";
    local *Loomy::ContentPolicy::human_tty=sub {1};
    local *Loomy::ContentPolicy::_answer=sub {
      die "unexpected human question" unless $_[0]==1 && $_[1]=~/\AKEEP_(?:LABELS|RESULTS)\z/;
      return 1;
    };
    Loomy::ContentPolicy::first_use($root);
    my $p=Loomy::ContentPolicy::effective_policy($root);
    die "first-use grant missing" unless $p->{private_results} eq "on"
      && $p->{label_sources} eq Loomy::ContentPolicy::recommended_sources() && $p->{grant_prompt_version};
    my %limits=map {split /=/,$_,2} @ARGV;
    Loomy::ContentPolicy::change_policy($root,\%limits) if %limits;
  ' "$repo/scripts/lib/content-policy.pl" "$root" "$@" >/dev/null
)
# test_content_decline <repo> <root>: the same real first-use transaction answered No twice. The project
# keeps today's defaults (no labels, no private results, hint shown) and its screen is complete, so a PTY
# watch in a plain terminal (CI, no agent ancestor) starts on its frame instead of the first-use questions.
test_content_decline() (
  local repo="$1" root="$2"
  [[ "${LOOMY_TEST_GUARD:-}" == 1 && -n "${WORK:-}" && "$root" == "$WORK/"* && ! -L "$root/.loomy" ]] || {
    printf 'test decline requires a guarded isolated project\n' >&2; return 2
  }
  # shellcheck source=../../scripts/lib/content-policy.sh
  source "$repo/scripts/lib/content-policy.sh"
  _loomy_content_ui
  perl -e '
    require shift; my $root=shift;
    no warnings "redefine";
    local *Loomy::ContentPolicy::human_tty=sub {1};
    local *Loomy::ContentPolicy::_answer=sub {
      die "unexpected human question" unless $_[0]==1 && $_[1]=~/\AKEEP_(?:LABELS|RESULTS)\z/;
      return 0;
    };
    Loomy::ContentPolicy::first_use($root) or die "first-use screen not completed";
    my $p=Loomy::ContentPolicy::effective_policy($root);
    die "first-use decline missing" unless $p->{private_results} eq "off"
      && $p->{label_sources} eq "none" && $p->{grant_prompt_version};
  ' "$repo/scripts/lib/content-policy.pl" "$root" >/dev/null
)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == --decline ]]; then shift; test_content_decline "$@"; else test_content_grant "$@"; fi
fi

# Explicit bridge ownership, including late links and concurrent same-role attempts.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
my ($repo,$root)=@ARGV;
require "$repo/scripts/lib/live-state.pl";
my $v=Loomy::LiveState->new;
my $now=time; my $ts=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
sub event {$v->consume({ts=>$ts,@_})}
event(type=>'session',tool=>'claude',event=>'start',session=>'lead',pid=>$$);
for my $n (1,2) {
    event(type=>'delegation_start',id=>"bridge$n",family=>'codex',bridge=>'codex',session=>'lead',role=>'developer',attempt_id=>"attempt$n");
    event(type=>'session_observed',schema=>2,tool=>'codex',session_key=>"codex:exec$n",session=>"exec$n",state=>'running',source_active=>1);
    event(type=>'delegation_start',schema=>2,tool=>'codex',bridge=>'codex-native',session_key=>"codex:exec$n",agent_id=>"child$n",parent_agent_id=>"codex:exec$n",id=>"turn$n",role=>"child$n");
}
$v->projections($now);
for my $n (1,2) {
    event(type=>'bridge_link',schema=>2,tool=>'codex',session=>"exec$n",session_key=>"codex:exec$n",parent_delegation=>"bridge$n",attempt_id=>"attempt$n");
    event(type=>'bridge_link',schema=>2,tool=>'codex',session=>"child$n",session_key=>"codex:child$n",parent_session=>"exec$n",parent_delegation=>"bridge$n",attempt_id=>"attempt$n");
}
event(type=>'delegation_start',schema=>2,tool=>'codex',bridge=>'codex-native',session_key=>'codex:exec1',agent_id=>'grandchild',parent_agent_id=>'codex:child1',id=>'grandturn',role=>'grandchild');
event(type=>'bridge_link',schema=>2,tool=>'codex',session=>'grandchild',session_key=>'codex:grandchild',parent_session=>'child1',parent_delegation=>'bridge1',attempt_id=>'attempt1');
my @rows=$v->projections($now);
for my $n (1,2) {
    die 'child grouped under wrong bridge' unless grep {/^N\|A\|codex:child$n\|claude:lead\|codex:bridge$n\|running\|/} @rows;
    die 'bridge session still projected as lead' if grep {/^N\|G\|codex:exec$n\|/} @rows;
    die 'late link did not remove previous lead group' unless grep {/^N\|D\|codex:exec$n$/} @rows;
}
die 'grandchild parent lost' unless grep {/^N\|A\|codex:grandchild\|claude:lead\|codex:child1\|running\|/} @rows;
# Claude bridge transcripts use the same explicit session ownership.
event(type=>'delegation_start',id=>'cbridge',family=>'claude',session=>'lead',role=>'reviewer',attempt_id=>'ca');
event(type=>'bridge_link',schema=>2,tool=>'claude',session=>'c-exec',session_key=>'claude:c-exec',parent_delegation=>'cbridge',attempt_id=>'ca');
event(type=>'delegation_start',schema=>2,tool=>'claude',session_key=>'claude:c-exec',agent_id=>'c-child',parent_agent_id=>'claude:c-exec',id=>'c-turn');
@rows=$v->projections($now);
die 'Claude bridge child not owned' unless grep {/^N\|A\|claude:c-child\|claude:lead\|claude:cbridge\|/} @rows;
event(type=>'bridge_link',tool=>'codex',session=>'exec1',session_key=>'codex:exec1',parent_delegation=>'bridge2',attempt_id=>'wrong');
@rows=$v->projections($now);
@rows=grep {/^(?:N\|A\||N\|G\|)/} values %{$v->{sent}};
die 'mismatched attempt attached to bridge' unless grep {/^N\|A\|codex:child1\|claude:lead\|codex:bridge1\|/} @rows;
my $wire="$root/bridge-wire"; open my $f,'>',$wire or die $!;
print $f "$_\n" for (@rows,$v->projections($now+1)); close $f;
# Both rendering surfaces consume the exact same ownership projection.
my $script=q{source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/phases.sh"; source "$1/scripts/loomy-tree.sh" --library;
ROOT="$2"; loomy_live_init; NS_ENABLED=1; while IFS= read -r row; do loomy_native_accept "$row"; done <"$2/bridge-wire";
LV_NOW="$3"; LOOMY_WATCH_VIEW="$4"; loomy_live_states; loomy_live_metadata; loomy_live_render >"$2/bridge-$4";
grep -q 'child1.*running' "$2/bridge-$4" && grep -q 'grandchild.*running' "$2/bridge-$4";};
for my $view (qw(tree list)) {if (system('bash','-c',$script,'_',$repo,$root,$now,$view)) {open my $h,'<',"$root/bridge-$view" or die; print STDERR <$h>; die "bridge $view render failed"}}
print "PASS explicit nested bridge ownership and tree/list rendering\n";

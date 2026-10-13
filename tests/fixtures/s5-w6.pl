use strict;
use warnings;
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use Time::HiRes qw(time);
my ($repo,$work)=@ARGV;
require "$repo/scripts/lib/codex-native.pl";
require "$repo/scripts/lib/watch-errors.pl";
my $root="$work/project"; my $logs="$root/.loomy/logs"; my $sources="$work/old/sessions";
my $now=time; $ENV{LOOMY_NATIVE_NOW}=int $now;
sub ts {strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($_[0]))}
sub rows {
    my ($path,@rows)=@_; (my $dir=$path)=~s{/[^/]*$}{}; make_path($dir);
    open my $f,'>>',$path or die $!; print $f encode_json($_),"\n" for @rows; close $f or die $!;
}
my $old="$sources/2020/01/01/rollout-old.jsonl";
rows($old,{type=>'session_meta',timestamp=>ts($now-1000000),payload=>{id=>'old',cwd=>$root,source=>'cli',timestamp=>ts($now-1000000)}});
Loomy::CodexNative::poll($root,$sources);
rows($old,{type=>'event_msg',timestamp=>ts($now),payload=>{type=>'task_started',turn_id=>'resumed'}});
my $start=time; die 'old-date append missed' unless Loomy::CodexNative::watch_changed($root,$sources,$now);
my $state=Loomy::CodexNative::poll($root,$sources);
my $view=Loomy::LiveState->new; $view->read_journal("$logs/events.jsonl"); $view->source_evidence($state);
die 'resumed old-date session absent' unless grep {/N\|G\|codex:old\|.*\|running\|/} $view->projections($now);
die 'old-date resume >=1s' if time-$start>=1;
my $new="$sources/2020/01/02/rollout-new.jsonl";
rows($new,{type=>'session_meta',timestamp=>ts($now),payload=>{id=>'new',cwd=>$root,source=>'exec',timestamp=>ts($now)}},
    {type=>'event_msg',timestamp=>ts($now),payload=>{type=>'task_started',turn_id=>'created'}});
die 'old-date creation missed' unless Loomy::CodexNative::watch_changed($root,$sources,$now);
Loomy::CodexNative::poll($root,$sources);
my $log="$logs/watch-errors.log";
for (1..2200) {Loomy::WatchErrors::record($log,'reducer','exception')}
die 'error log exceeds bound' if -s $log>65536;
die 'error log permissions' unless ((stat $log)[2]&0777)==0600;
my $before=-s $log; $ENV{LOOMY_JOURNAL}=0; Loomy::WatchErrors::record($log,'controller','error');
die 'opt-out writes diagnostics' if -s $log!=$before;
$ENV{LOOMY_JOURNAL}=1;
symlink "$work/old","$work/codex-link" or die $!;
make_path("$work/claude-link-home"); symlink "$work/old","$work/claude-link-home/projects" or die $!;
open my $f,'>',"$logs/claude-native.idx" or die; truncate $f,2097153 or die; close $f;
my $out=`perl "$repo/scripts/lib/watch-health.pl" "$root" "$work/codex-link" "$work/claude-link-home"`;
my @warnings=$out =~ /symlink/g; die 'doctor source warnings absent' unless @warnings==2;
die 'doctor bounds warning absent' unless $out =~ /bounds\t.*claude-native.idx\t2097153/;
die 'doctor recent errors absent' unless $out =~ /error\t.*watch-errors.log\t.*watch reducer exception/;
unlink "$logs/claude-native.idx";
print "old-date append/creation, diagnostic bounds/mode/opt-out, doctor symlinks/bounds/errors passed\n";

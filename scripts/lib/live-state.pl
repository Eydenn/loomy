# Shared, content-free live projection. The sampler owns this reducer; one-shot views use it once.
package Loomy::LiveState;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Time::Local qw(timegm);
use Fcntl qw(O_RDONLY O_NOFOLLOW);
use Errno qw(EPERM);
use Cwd qw(abs_path);
use Time::HiRes ();

sub text { defined $_[0] && !ref($_[0]) ? "$_[0]" : '' }
sub epoch {
    my @t=text($_[0]) =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$/;
    return @t ? (eval { timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0]) } // 0)+($t[6]//0) : 0;
}
sub safe_path {
    my $p=$_[0]; return 0 unless defined $p && $p =~ m{^/};
    while ($p ne '') { return 0 if -l $p; $p =~ s{/[^/]*$}{} } return 1;
}
sub new { bless {sessions=>{},agents=>{},turns=>{},cursor=>{},sent=>{},native=>0},shift }
sub session {
    my ($self,$key)=@_;
    return $self->{sessions}{$key}//={key=>$key,tool=>($key =~ /^(codex|claude):/ ? $1 : 'unknown'),state=>'unknown',surface=>'unknown',seen=>0,pid=>0};
}
sub consume {
    my ($self,$d)=@_; my $type=text($d->{type}); my $ts=epoch($d->{source_ts}//$d->{ts});
    my $tool=text($d->{tool}//$d->{family});
    my $key=text($d->{session_key});
    $self->{native}=1 if text($d->{schema}) eq '2' && $tool eq 'codex';
    if ($type eq 'session') {
        return unless $tool =~ /^(codex|claude)$/;
        $key="$tool:".(text($d->{session}) || 'pid'.text($d->{pid}));
        my $s=$self->session($key);
        $s->{pid}=text($d->{pid}); $s->{created}//=$ts;
        if (text($d->{event}) eq 'start') { $s->{closed}=0; $s->{state}='idle' }
        elsif (text($d->{event}) eq 'end') {
            $s->{closed_at}=$ts; $s->{closed}=($s->{seen}<=$ts ? 1 : 0);
            $s->{pid}=0;
            if (!text($d->{session})) {
                for my $bound (grep { $_->{tool} eq $tool && text($_->{pid}) eq text($d->{pid}) } values %{$self->{sessions}}) {
                    $bound->{closed_at}=$ts; $bound->{closed}=($bound->{seen}<=$ts ? 1 : 0); $bound->{pid}=0;
                }
            }
        }
        $s->{seen}=$ts if $ts>$s->{seen}; return;
    }
    if ($key eq '' && $type =~ /^(delegation_start|delegation_activity|delegation)$/ && text($d->{session}) ne '') {
        my $sid=text($d->{session});
        my @parents=grep { /:\Q$sid\E$/ } keys %{$self->{sessions}};
        if (@parents==1) {
            $key=$parents[0]; $d->{parent_agent_id}//=$key;
            $d->{agent_id}//=text($d->{id});
        }
    }
    if ($key eq '' && $type =~ /^(delegation_start|delegation_activity|delegation)$/ && text($d->{id}) ne '') {
        $tool='unknown' unless $tool =~ /^(codex|claude)$/;
        $key="unassigned:$tool"; $d->{parent_agent_id}=$key; $d->{agent_id}//=text($d->{id});
        my $bucket=$self->session($key); $bucket->{unassigned}=1; $bucket->{tool}=$tool;
    }
    return unless $key ne '';
    my $s=$self->session($key);
    if ($ts>($s->{closed_at}//0) && $s->{closed} && text($d->{schema}) eq '2'
        && ($type ne 'session_observed' || ($d->{source_active}//0))) {
        $s->{closed}=0; $s->{pid}=0;
    }
    # Merge only a launcher explicitly paired by the adapter, never a nearest-start guess.
    my $pid=text($d->{owner_pid});
    if ($pid =~ /^\d+$/ && $pid>1 && $ts>($s->{closed_at}//0)) {
        $s->{pid}=$pid;
        delete $self->{sessions}{"$tool:pid$pid"};
    }
    $s->{seen}=$ts if $ts>$s->{seen} && !($type eq 'session_observed' && !($d->{source_active}//0));
    if ($type eq 'session_observed') {
        $s->{pid}=0 if text($d->{schema}) eq '2' && $pid eq '' && $ts>($s->{closed_at}//0);
        $s->{$_}=text($d->{$_}) for qw(surface state cwd_relative evidence);
        $s->{created}//=$ts; $s->{agent_id}=text($d->{agent_id}); return;
    }
    if ($type eq 'session_context') {
        $s->{$_}=text($d->{$_}) for qw(model effort context_freshness); return;
    }
    my $aid=text($d->{agent_id}); my $id=text($d->{id});
    return unless $aid ne '' && $id ne '';
    my $ak="$tool:$aid";
    my $a=$self->{agents}{$ak}//={key=>$ak,session=>$key,parent=>text($d->{parent_agent_id}),state=>'unknown',latest=>'',seen=>0};
    my $prior_session=$a->{session};
    $a->{session}=$key;
    if ($prior_session ne $key) {
        $_->{session}=$key for grep { $_->{agent} eq $ak } values %{$self->{turns}};
        delete $self->{sessions}{$prior_session} if $prior_session =~ /^codex:pending:/ && !grep { $_->{session} eq $prior_session } values %{$self->{agents}};
    }
    $a->{parent}=text($d->{parent_agent_id}) if text($d->{parent_agent_id}) ne '';
    if ($type eq 'agent_link' || $type eq 'agent_closed') {
        $a->{$_}=text($d->{$_}) for grep { defined $d->{$_} && !ref($d->{$_}) } qw(role task nickname model effort);
        if ($type eq 'agent_closed' && $ts>=$a->{seen}) { $a->{closed}=1; $a->{closed_at}=$ts; $a->{state}='done' }
        return;
    }
    my $fresh=!exists $self->{turns}{$id};
    my $turn=$self->{turns}{$id}//={key=>$id,agent=>$ak,session=>$key,state=>'unknown',outcome=>'unknown',started=>0,seen=>0};
    if ($type eq 'delegation_start') {
        $turn->{started}=$ts;
        delete @$turn{qw(ended duration status)} if $turn->{ended} && $turn->{ended}<$ts;
        $turn->{state}='running' unless $turn->{ended};
        $a->{closed}=0 if $fresh && text($d->{bridge}) eq 'codex-native' && $ts>($a->{closed_at}//0);
    }
    elsif ($type eq 'delegation_activity') {
        $turn->{state}=text($d->{state}//$d->{activity}) || 'unknown' unless $turn->{ended};
    } elsif ($type eq 'delegation') {
        return if $turn->{started} && $ts<$turn->{started};
        $turn->{ended}=$ts; $turn->{state}=text($d->{status}) eq 'ok' ? 'done' : text($d->{status}) eq 'error' ? 'failed' : text($d->{status}) || 'unknown';
        $turn->{outcome}=text($d->{outcome}) || 'unknown';
        $turn->{status}=text($d->{status}); $turn->{duration}=defined $d->{duration_s} && !ref($d->{duration_s}) ? text($d->{duration_s}) : '—';
    }
    $turn->{$_}=text($d->{$_}) for grep { defined $d->{$_} && !ref($d->{$_}) } qw(model effort task role);
    $turn->{seen}=$ts if $ts>$turn->{seen};
    $a->{latest}=$id if $a->{latest} eq '' || ($fresh && $type eq 'delegation_start');
    if ($a->{latest} eq $id) {
        $a->{$_}=$turn->{$_} for qw(model effort task role);
        $a->{state}=$a->{closed} ? 'done' : $turn->{ended} ? (text($d->{bridge}) eq 'codex-native' ? 'idle' : $turn->{state}) : $turn->{state};
    }
    $a->{seen}=$ts if $ts>$a->{seen};
}

# Seek before decoding; malformed complete lines advance, partial appends retry, oversized lines skip.
sub read_journal {
    my ($self,$path)=@_; $self->{read_bytes}=0;
    my @probe=Time::HiRes::stat($path);
    my $sig=@probe ? join(':',$path,@probe[0,1,7,9]) : '';
    return if $sig ne '' && ($self->{read_sig}//'') eq $sig;
    return unless safe_path($path) && -f $path;
    sysopen my $f,$path,O_RDONLY|O_NOFOLLOW or return;
    my @st=stat($f); my $key="$st[0]:$st[1]"; my $c=$self->{cursor};
    if (($c->{key}//'') ne $key || ($c->{offset}//0)>$st[7]) {
        $c->{offset}=0; delete $c->{skipping};
        # Retain identities through rotation; snapshots are not new work.
    }
    $c->{key}=$key; my $off=$c->{offset}//0; seek $f,$off,0 or return;
    my $n=sysread($f,my $buf,2097152); $self->{read_bytes}=$n//0;
    $self->{read_sig}=$sig if defined $n && $off+$n >= $st[7];
    return unless $n;
    my $skip=0;
    if ($c->{skipping}) { my $i=index($buf,"\n"); if ($i<0) { $c->{offset}=$off+$n; return } $skip=$i+1; delete $c->{skipping} }
    my $end=rindex($buf,"\n");
    if ($end<0) { if ($n==2097152) { $c->{offset}=$off+$n; $c->{skipping}=1 } return }
    $c->{offset}=$off+$end+1;
    for my $line (split /\n/,substr($buf,$skip,$end-$skip+1)) {
        my $d=eval { decode_json($line) }; $self->consume($d) if ref($d) eq 'HASH';
    }
}

# Ordinary source activity renews the lease in memory without journal heartbeats.
sub source_evidence {
    my ($self,$native)=@_; return unless ref($native) eq 'HASH';
    my %files=map { $_->{meta}{id}=>$_ } values %{$native->{files}//{}};
    for my $f (values %files) {
        my $m=$f->{meta}; my %seen;
        while ($m->{parent}) { last if $seen{$m->{id}}++; my $parent=$files{$m->{parent}} or last; $m=$parent->{meta} }
        my $key=$m->{parent} ? "codex:pending:$m->{parent}" : "codex:$m->{id}";
        my $s=$self->{sessions}{$key} or next;
        my $ts=epoch($f->{last_evidence_ts}//$f->{last_observed_ts});
        if ($s->{closed} && $ts>($s->{closed_at}//0)) { $s->{closed}=0; $s->{pid}=0 }
        $s->{seen}=$ts if $ts>$s->{seen};
    }
}
sub wire {
    my @row=@_; for (@row) { $_=text($_); s/[\x00-\x1f\x7f|]/ /g } return join('|',@row);
}
sub projections {
    my ($self,$now)=@_; my @out;
    if ($self->{native} && !$self->{sent}{native}) { push @out,'N|native|1'; $self->{sent}{native}=1 }
    for my $key (keys %{$self->{sent}}) {
        next unless $key =~ /^G:(.*)$/; my $sid=$1;
        unless ($self->{sessions}{$sid}) { push @out,wire('N','D',$sid); delete $self->{sent}{$key} }
    }
    for my $key (sort keys %{$self->{sessions}}) {
        my $s=$self->{sessions}{$key}; my $pid=$s->{pid}//0;
        my $alive=$pid =~ /^\d+$/ && $pid>1 && (kill(0,$pid) || $! == EPERM);
        my $live=!$s->{unassigned} && !$s->{closed} && ($alive || ($s->{seen}>0 && $now-$s->{seen}<=120));
        my $row=wire('N','G',$key,$s->{tool},$s->{surface},$s->{cwd_relative},$live ? 'live' : 'stale',
            $s->{state},$s->{model},$s->{effort},int($s->{seen}),$alive ? 'launcher' : 'source lease',$s->{context_freshness});
        push @out,$row if ($self->{sent}{"G:$key"}//'') ne $row; $self->{sent}{"G:$key"}=$row;
    }
    for my $key (sort keys %{$self->{agents}}) {
        my $a=$self->{agents}{$key}; my $t=$self->{turns}{$a->{latest}}//{};
        my $agent_state=$a->{state};
        my $session=$self->{sessions}{$a->{session}}//{};
        my $pid=$session->{pid}//0;
        my $dead=$pid =~ /^\d+$/ && $pid>1 && !(kill(0,$pid) || $! == EPERM);
        # Completed agents close with an observed owner; absent PIDs remain source-owned.
        $agent_state='done' if $t->{ended} && (($session->{closed}//0) || $dead);
        my $turns=grep { $_->{agent} eq $key } values %{$self->{turns}};
        my $row=wire('N','A',$key,$a->{session},$a->{parent},$agent_state,$a->{role},$a->{task},$a->{model},$a->{effort},
            int($t->{started}//0),($t->{ended} ? int($t->{ended}) : ''),$t->{duration},$t->{outcome},$a->{latest},int($a->{seen}),$t->{state},$turns);
        push @out,$row if ($self->{sent}{"A:$key"}//'') ne $row; $self->{sent}{"A:$key"}=$row;
    }
    for my $key (sort keys %{$self->{turns}}) {
        my $t=$self->{turns}{$key}; next unless $t->{ended};
        my $row=wire('N','T',$key,$t->{session},$t->{agent},$t->{state},$t->{outcome},int($t->{started}//0),int($t->{ended}),$t->{duration},$t->{model},$t->{role});
        push @out,$row if ($self->{sent}{"T:$key"}//'') ne $row; $self->{sent}{"T:$key"}=$row;
    }
    return @out;
}
unless (caller) {
    my ($root,$sessions)=@ARGV; $root=abs_path($root)//exit 1;
    my $dir=__FILE__; $dir =~ s{/[^/]+$}{};
    require "$dir/codex-native.pl";
    my $native=Loomy::CodexNative::poll($root,$sessions);
    my $state=__PACKAGE__->new; $state->read_journal("$root/.loomy/logs/events.jsonl"); $state->source_evidence($native);
    print "$_\n" for $state->projections($ENV{LOOMY_NATIVE_NOW}//time);
}
1;

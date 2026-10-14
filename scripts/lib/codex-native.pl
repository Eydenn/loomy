# Local Codex rollout ingestion. Loaded by the watch sampler or invoked with perl.
package Loomy::CodexNative;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Fcntl qw(O_RDONLY O_RDWR O_WRONLY O_CREAT O_APPEND O_NOFOLLOW LOCK_EX LOCK_NB);
use Cwd qw(abs_path);
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Time::HiRes ();
my (%inventory,%cached,%diagnosed,%watch);
my $live_lib=abs_path(__FILE__); $live_lib =~ s{/[^/]+$}{};
require "$live_lib/live-state.pl";
my $canonical=JSON::PP->new->canonical;
my $metadata_bytes=0;
use Errno qw(EPERM);
use IO::Handle;
use Digest::SHA qw(sha256_hex);

sub scalar_text { defined $_[0] && !ref($_[0]) ? "$_[0]" : '' }
sub identity { scalar_text($_[0]) =~ /\A[A-Za-z0-9_.:-]{1,100}\z/ ? scalar_text($_[0]) : '' }
sub label { my $s=scalar_text($_[0]); $s =~ s/[^A-Za-z0-9 _.-]/ /g; return substr($s,0,40) }
sub stamp { scalar_text($_[0]) }
sub epoch {
    my @t=stamp($_[0]) =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$/;
    return @t ? (eval { timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0]) } // 0)+($t[6]//0) : 0;
}
sub alive { my $p=scalar_text($_[0]); return $p =~ /^\d+$/ && $p>1 && (kill(0,$p) || $! == EPERM) }
sub safe_path {
    my $p=$_[0]; return 0 unless defined $p && $p =~ m{^/};
    while ($p ne '') { return 0 if -l $p; $p =~ s{/[^/]*$}{} }
    return 1;
}
sub open_read {
    my $p=$_[0]; return unless safe_path($p) && -f $p;
    sysopen my $f,$p,O_RDONLY|O_NOFOLLOW or return;
    return $f;
}

# Stat-only watch probe: retained dates cover old resumes; today's ancestors cover midnight.
sub input_signature {
    my ($root,$sessions,$now)=@_;
    my $idx="$root/.loomy/logs/codex-native.idx";
    my $s=$cached{$idx} ? $cached{$idx}{state} : {};
    my %paths=map { $_=>1 } ($idx,"$root/.loomy/logs/events.jsonl",keys %{$s->{files}//{}},
        keys %{$inventory{$sessions}{dirs}//{}},keys %{$inventory{$sessions}{invalid}//{}});
    my $day=strftime('%Y/%m/%d',gmtime($now));
    $paths{$sessions}=1;
    my $path=$sessions; for my $part (split '/', $day) { $path.="/$part"; $paths{$path}=1 }
    my $sig=join(';',map { my @st=Time::HiRes::stat($_); join(':',$_,@st ? @st[0,1,7,9] : '-') } sort keys %paths);
    return $sig;
}
sub pending_input {
    my ($root,$sessions,$s)=@_;
    return 1 if ($s->{journal}{read_sig}//'') ne Loomy::LiveState::file_signature("$root/.loomy/logs/events.jsonl");
    for my $path (keys %{$s->{files}//{}}) {
        return 1 if ($s->{files}{$path}{read_sig}//'') ne Loomy::LiveState::file_signature($path);
    }
    for my $dir (keys %{$inventory{$sessions}{dirs}//{}}) {
        my @st=Time::HiRes::stat($dir);
        return 1 if ($inventory{$sessions}{dirs}{$dir}{sig}//'') ne (@st ? join(':',@st[0,1,9]) : '-');
    }
    return 0;
}
sub watch_changed {
    my ($root,$sessions,$now)=@_; my $idx="$root/.loomy/logs/codex-native.idx";
    my $s=$cached{$idx} ? $cached{$idx}{state} : {};
    my $sig=input_signature($root,$sessions,$now);
    my $changed=!defined($watch{$idx}) || $watch{$idx} ne $sig;
    $watch{$idx}=$sig;
    # Continue bounded catch-up even if the producer stops appending.
    return $changed || @{$inventory{$sessions}{queue}//[]} || pending_input($root,$sessions,$s) || grep { !($_->{at_eof}//0) } values %{$s->{files}//{}};
}

# sysread has a fixed budget; offsets stop at complete lines, including malformed ones.
sub lines {
    my ($path,$cursor,$budget)=@_; $cursor->{read_bytes}=0;
    my @probe=Time::HiRes::stat($path);
    my $sig=@probe ? join(':',@probe[0,1,7,9]) : '';
    if ($sig ne '' && ($cursor->{read_sig}//'') eq $sig) { $cursor->{at_eof}=1; return () }
    $cursor->{at_eof}=0;
    my $f=open_read($path) or return ();
    my @s=stat($f); my $key="$s[0]:$s[1]";
    if (($cursor->{key}//'') ne $key || ($cursor->{offset}//0)>$s[7]) {
        my $fence=epoch($cursor->{last_observed_ts}//$cursor->{last_evidence_ts});
        $cursor->{replay_fence}=$fence if $fence>($cursor->{replay_fence}//0);
        $cursor->{offset}=0; delete $cursor->{skipping}; delete $cursor->{read_sig};
    }
    $cursor->{key}=$key; my $off=$cursor->{offset}//0;
    $cursor->{read_start}=$off;
    seek $f,$off,0 or return ();
    my $n=sysread($f,my $buf,$budget); $cursor->{read_bytes}=$n//0;
    my @after=stat($f);
    $cursor->{at_eof}=1 if defined $n && $off+$n >= $s[7] && $after[7]==$s[7] && $after[9]==$s[9];
    $cursor->{read_sig}=$sig if defined $n && $cursor->{at_eof};
    return () unless $n;
    my $skip=0;
    if ($cursor->{skipping}) {
        my $first=index($buf,"\n");
        if ($first<0) { $cursor->{offset}=$off+$n; return () }
        $skip=$first+1; delete $cursor->{skipping};
    }
    my $end=rindex($buf,"\n");
    if ($end<0) {
        # Oversized records (usually prompts/tool output) must not pin the reader forever.
        if ($n==$budget) { $cursor->{offset}=$off+$n; $cursor->{skipping}=1; $cursor->{oversized}=1; $cursor->{oversized_at}=$off+$n }
        return ();
    }
    $cursor->{offset}=$off+$end+1;
    my @records; my $pos=$off+$skip;
    for my $line (split /\n/,substr($buf,$skip,$end-$skip+1)) { $pos+=length($line)+1; push @records,[$line,$pos] }
    return @records;
}

sub metadata {
    $metadata_bytes=0;
    my $f=open_read($_[0]) or return;
    my $buf='';
    while (length($buf)<262144 && index($buf,"\n")<0) {
        my $n=sysread($f,my $chunk,4096); last unless $n;
        $buf.=$chunk; $metadata_bytes+=$n;
    }
    my ($line)=$buf =~ /\A([^\n]*)\n/;
    unless (defined $line) {
        warn "Codex rollout metadata exceeds 256 KiB; tracking unknown\n" if length($buf)==262144 && !$diagnosed{$_[0]}++;
        return;
    }
    my $d=eval { decode_json($line) }; return unless ref($d) eq 'HASH' && ($d->{type}//'') eq 'session_meta';
    my $p=$d->{payload}; return unless ref($p) eq 'HASH' && identity($p->{id});
    my $spawn=ref($p->{source}) eq 'HASH' && ref($p->{source}{subagent}) eq 'HASH' ? $p->{source}{subagent}{thread_spawn} : undef;
    my $v2=scalar_text($p->{multi_agent_version}) eq 'v2' || scalar_text($p->{history_mode}) eq 'paginated';
    my $parent=identity($p->{parent_thread_id}) || (ref($spawn) eq 'HASH' ? identity($spawn->{parent_thread_id}) : '');
    $parent=identity($p->{session_id}) if !$parent && $v2 && scalar_text($p->{thread_source}) eq 'subagent';
    $parent='' if $parent eq identity($p->{id});
    my $source=scalar_text($p->{source});
    my $origin=scalar_text($p->{originator});
    my $surface=$source eq 'exec' ? 'exec' : $source eq 'cli' ? 'cli'
        : ($source eq 'app' || ($source eq 'vscode' && $origin =~ /desktop/i)) ? 'app' : 'unknown';
    my $task=scalar_text($p->{agent_path}) || (ref($spawn) eq 'HASH' ? scalar_text($spawn->{agent_path}) : '');
    $task =~ s{.*/}{};
    my $names=($ENV{LOOMY_JOURNAL_TASKS}//'1') ne '0';
    return {id=>identity($p->{id}),parent=>$parent,surface=>$surface,cwd=>scalar_text($p->{cwd}),task=>($names ? label($task) : ''),
        metadata_protocol=>2,v2=>($v2 ? 1 : 0),workspace_roots=>(ref($p->{runtime_workspace_roots}) eq 'ARRAY' ? $p->{runtime_workspace_roots} : []),
        ts=>stamp($p->{timestamp}//$d->{timestamp}),role=>label($p->{agent_role}//(ref($spawn) eq 'HASH' ? $spawn->{agent_role} : '')),
        nickname=>($names ? label($p->{agent_nickname}//(ref($spawn) eq 'HASH' ? $spawn->{agent_nickname} : '')) : '')};
}

# Directory signatures detect new names; known files are retained for old-date resumes.
sub discover {
    my ($s,$sessions,$root,$now)=@_;
    my $inv=$inventory{$sessions}//={dirs=>{},paths=>{},checked=>{},invalid=>{}};
    my @queue=([$sessions,0]);
    while (my $entry=shift @queue) {
        my ($dir,$depth)=@$entry; next unless safe_path($dir) && -d $dir;
        my @st=Time::HiRes::stat($dir); my $sig=join(':',@st[0,1,9]);
        my $d=$inv->{dirs}{$dir};
        if (!$d || $d->{sig} ne $sig) {
            opendir my $dh,$dir or next;
            my @names=sort grep { $depth==3 ? /^rollout-.*\.jsonl$/ : /^\d{2,4}$/ } readdir $dh;
            if ($depth==3) {
                my @new;
                for my $name (@names) {
                    my $path="$dir/$name"; my @file=stat($path);
                    next unless @file;
                    my $key="$file[0]:$file[1]";
                    next if ($inv->{checked}{$path}//'') eq $key || $inv->{queued}{$path};
                    push @new,$path; $inv->{queued}{$path}=1;
                }
                # A newly changed directory precedes the older bootstrap backlog.
                unshift @{$inv->{queue}},@new;
            }
            $d=$inv->{dirs}{$dir}={sig=>$sig,names=>\@names};
        }
        if ($depth<3) { push @queue,map { ["$dir/$_",$depth+1] } @{$d->{names}} }
        else { $inv->{paths}{"$dir/$_"}=1 for @{$d->{names}} }
    }
    for my $path (keys %{$inv->{invalid}}) {
        my @st=stat($path); next unless @st && join(':',@st[0,1,7,9]) ne $inv->{invalid}{$path};
        next if $inv->{queued}{$path}; unshift @{$inv->{queue}},$path; $inv->{queued}{$path}=1;
    }
    my ($read,$bytes)=(0,0);
    while (@{$inv->{queue}//[]}) {
        my $path=shift @{$inv->{queue}}; delete $inv->{queued}{$path};
        next unless safe_path($path) && -f $path;
        my @st=stat($path); my $sig="$st[0]:$st[1]";
        next if ($inv->{checked}{$path}//'') eq $sig;
        # Checkpointed eligible metadata is reusable across one-shot calls and sampler restarts.
        if ($s->{files}{$path} && ($s->{files}{$path}{key}//'') eq $sig && $s->{files}{$path}{meta}{metadata_protocol}) {
            $inv->{checked}{$path}=$sig; next;
        }
        my $version=join(':',@st[0,1,7,9]);
        next if ($inv->{invalid}{$path}//'') eq $version;
        if (++$read>32 || $bytes+262144>2097152) {
            unshift @{$inv->{queue}},$path; $inv->{queued}{$path}=1; last;
        }
        my $m=metadata($path); $bytes+=$metadata_bytes;
        if (!$m) { $inv->{invalid}{$path}=$version; next }
        delete $inv->{invalid}{$path}; $inv->{checked}{$path}=$sig;
        my $cwd='';
        for my $candidate ($m->{cwd},@{delete $m->{workspace_roots}}) {
            next unless scalar_text($candidate) =~ m{^/};
            my $resolved=abs_path($candidate)//'';
            if ($resolved eq $root || index($resolved,"$root/")==0) { $cwd=$resolved; last }
        }
        next unless $cwd;
        $m->{cwd}=$cwd;
        my $old=$s->{files}{$path};
        $s->{files}{$path}={meta=>$m,offset=>0} unless $old && ($old->{key}//'') eq $sig;
        $s->{files}{$path}{meta}=$m;
        # A live child's explicit parent should precede the historical inventory backlog.
        if ($m->{v2} && $m->{parent} && !grep { $_->{meta}{id} eq $m->{parent} } values %{$s->{files}}) {
            my ($parent)=grep { /\Q$m->{parent}\E\.jsonl$/ } keys %{$inv->{paths}};
            unshift @{$inv->{queue}},$parent if $parent && ($inv->{checked}{$parent}//'') eq '';
        }
    }
    $s->{discovering}=scalar @{$inv->{queue}//[]};
    return $bytes;
}

# Parent identity, never role or arrival order, determines the lead group.
sub lead_id {
    my ($m,$by_id)=@_; my %seen;
    while ($m->{parent}) {
        return '' if $seen{$m->{id}}++;
        my $parent=$by_id->{$m->{parent}}; return "pending:$m->{parent}" unless $parent;
        $m=$parent;
    }
    return $m->{id};
}

# An ended launcher owns historical turns only; later source work has its own activation.
sub owner_at {
    my ($owners,$lead,$ts,$created)=@_;
    for my $o (@$owners) {
        next if $o->{unbound} || ($o->{lead}//'') ne $lead;
        next if epoch($ts)<epoch($o->{ts})-10;
        my $end=$o->{ended}//$o->{dead_at};
        next if $end && epoch($ts)>epoch($end);
        return $o;
    }
    return {lead=>$lead,session=>$lead,ts=>$created,unbound=>1,pid=>0};
}

sub save { Loomy::LiveState::checkpoint_save(@_) }
# Cursors replace lifetime event hashes. Retain current identities and a bounded recent replay window.
sub prune_checkpoint {
    my ($s,$now)=@_; my $changed=($s->{version}//0)!=2; $s->{version}=2;
    my %keep;
    my @finished=sort {epoch($b->{last_observed_ts})<=>epoch($a->{last_observed_ts})}
        grep {$_->{finished} && $_->{id}} values %{$s->{files}//{}};
    for my $i (0..$#finished) {
        my $f=$finished[$i]; next if $i<1000 && $now-epoch($f->{last_observed_ts})<=604800;
        $f->{replay_fence}=epoch($f->{last_observed_ts});
        delete @$f{qw(id turn started model effort wait_calls starts closed_agents context emitted_activity projected_lead event_position)};
        delete @{$f->{meta}}{qw(task nickname)}; $changed=1;
    }
    for my $f (values %{$s->{files}//{}}) {
        if ($f->{id}) {$keep{sha256_hex("$f->{id}:$_")}=1 for qw(start end)}
    }
    my @keys=sort {($s->{seen}{$b}//0)<=>($s->{seen}{$a}//0) || $a cmp $b} keys %{$s->{seen}//{}};
    for my $i (0..$#keys) {
        my $key=$keys[$i]; next if $keep{$key};
        next if $i<8000 && ($s->{seen}{$key}//0)>1 && $now-$s->{seen}{$key}<=604800;
        delete $s->{seen}{$key}; $changed=1;
    }
    for my $key (keys %{$s->{owners}//{}}) {
        my $o=$s->{owners}{$key}; my $end=epoch($o->{ended}//$o->{dead_at});
        if ($end && $now-$end>604800) {delete $s->{owners}{$key}; delete $s->{owner_leads}{$key}; $changed=1}
    }
    return $changed;
}

# Older checkpoints lack an activity timestamp; inspect only their already-consumed source tail.
sub observed_time {
    my ($path,$cursor)=@_; my $f=open_read($path) or return $cursor->{started};
    my $end=$cursor->{activity_position}//$cursor->{offset}//0;
    my $size=-s $f; return $cursor->{started} if !$end || $end>$size;
    my $length=$end<65536 ? $end : 65536;
    seek $f,$end-$length,0 or return $cursor->{started};
    sysread($f,my $buf,$length);
    for my $line (reverse split /\n/,$buf) {
        my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH' && scalar_text($d->{type}) =~ /^(event_msg|turn_context|response_item)$/;
        my $ts=stamp($d->{timestamp}); return $ts if epoch($ts)>=epoch($cursor->{started});
    }
    return $cursor->{started};
}

# A confirmed close ends a persistent child, including grandchildren of a native parent.
sub close_record {
    my ($f,$p,$ts)=@_;
    if (($p->{type}//'') eq 'function_call' && scalar_text($p->{name}) =~ /^(?:.*[._])?close_agent$/) {
        my $args=eval { decode_json(scalar_text($p->{arguments})) };
        my $id=ref($args) eq 'HASH' ? identity($args->{agent_id}//$args->{id}) : '';
        $f->{close_calls}{identity($p->{call_id})}=$id if $id && identity($p->{call_id});
    } elsif (($p->{type}//'') eq 'function_call_output') {
        my $id=delete $f->{close_calls}{identity($p->{call_id})};
        my $result=eval { decode_json(scalar_text($p->{output})) };
        if ($id && epoch($ts) && ref($result) eq 'HASH' && !$result->{error} && exists $result->{status}) {
            $f->{closed_agents}{$id}=$ts if epoch($ts)>epoch($f->{closed_agents}{$id});
        }
    }
}

# A turn first seen mid-flight (tail window) lacks its start, model and the end of the turn it replaced.
# Scan backwards from the window start, down to the head already consumed, for those turn-level facts only.
sub v2_backfill {
    my ($path,$turn,$before,$floor,$limit)=@_; my %r=(ends=>{}); my $used=0; my $to=$before; my $size=4096;
    my $h=open_read($path) or return (\%r,0);
    $floor=0 if $floor<0;
    while ($to>$floor && $used<$limit) {
        $size=$to-$floor if $to-$floor<$size; $size=$limit-$used if $limit-$used<$size;
        last if $size<=0;
        my $from=$to-$size; $from=0 if $from<0;
        seek $h,$from,0 or last;
        my $n=sysread($h,my $buf,$to-$from); $used+=$n//0;
        last unless $n && $n==$to-$from;
        my $skip=0;
        if ($from>0) {
            $skip=index($buf,"\n")+1;
            if ($skip==0 || $skip>=length($buf)) { $size*=2; $size=8388608 if $size>8388608; next }
        }
        for my $line (reverse split /\n/,substr($buf,$skip)) {
            next unless index($line,'"task_started"')>=0 || index($line,'"turn_context"')>=0 || $line =~ /"(?:task_complete|turn_complete|task_failed|turn_aborted|task_aborted)"/;
            my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH' && ref($d->{payload}) eq 'HASH';
            my $p=$d->{payload}; my $type=scalar_text($d->{type}); my $event=scalar_text($p->{type}); my $id=identity($p->{turn_id}); my $ts=stamp($d->{timestamp});
            next unless $id && epoch($ts);
            if ($type eq 'turn_context' && $id eq $turn && !defined $r{model}) { @r{qw(model effort)}=(identity($p->{model}),identity($p->{effort})) }
            elsif ($type eq 'event_msg' && $event eq 'task_started' && $id eq $turn) { $r{started}=$ts }
            elsif ($type eq 'event_msg' && $event =~ /^(?:task_complete|turn_complete|task_failed|turn_aborted|task_aborted)$/ && !$r{ends}{$id}) {
                $r{ends}{$id}={ts=>$ts,event=>$event,started_at=>$p->{started_at},text=>scalar_text($p->{last_agent_message})};
            }
        }
        last if $from<=$floor || (defined $r{started} && keys %{$r{ends}});
        $size*=2 if $size<262144;
        $to=$from+$skip;
    }
    return (\%r,$used);
}

# Paginated children need current evidence before bounded historical catch-up finishes.
# The head retains launch/context facts; positions fence older replay behind the tail.
sub v2_records {
    my ($path,$f,$budget)=@_;
    my $key=$f->{key}//''; my $old_offset=$f->{offset}//0;
    my $head=$budget<131072 ? $budget : 131072;
    my @records=lines($path,$f,$head); my $used=$f->{read_bytes}//0;
    if ($key ne ($f->{key}//'') || ($f->{offset}//0)<$old_offset) {
        delete @$f{qw(v2_position v2_tail_sig)};
    }
    my @st=stat($path); return @records unless @st;
    my $sig=join(':',@st[0,1,7,9]);
    my $room=$budget-$used; $room=131072 if $room>131072;
    if (!$f->{at_eof} && $room>0 && ($f->{v2_tail_sig}//'') ne $sig) {
        my $h=open_read($path);
        if ($h) {
            my $start=$st[7]>$room ? $st[7]-$room : 0;
            if (seek $h,$start,0) {
                my $n=sysread($h,my $buf,$room); $used+=$n//0;
                if ($n) {
                    my $end=rindex($buf,"\n"); my $first=index($buf,"\n");
                    my $skip=$start ? ($first<0 ? length($buf) : $first+1) : 0;
                    my $position=$start+$skip;
                    $f->{v2_window}=$position;
                    if ($end>=$skip) {
                        for my $line (split /\n/,substr($buf,$skip,$end-$skip+1)) {
                            $position+=length($line)+1; push @records,[$line,$position];
                        }
                    }
                    $f->{v2_tail_sig}=$sig;
                }
            }
        }
    }
    $f->{read_bytes}=$used;
    return @records;
}

# Root contexts share the child read budget: incremental head plus a cached recent tail.
# Position ordering prevents old catch-up records from replacing a newer tail observation.
sub root_context {
    my ($path,$f,$budget)=@_; my $used=0; my $reset=0;
    my @before=stat($path);
    if (@before && (($f->{offset}//0)>$before[7] || ($f->{context} && ($f->{context}{position}//0)>$before[7]))) {
        ++$f->{context_revision};
        $reset=1;
        $f->{context_invalidated}=1 if $f->{context};
        delete $f->{context}; delete $f->{tail_sig}; delete $f->{tail_start}; delete @$f{qw(tail_end tail_at back_chunk gap_start gap_end)}; delete $f->{complete_sig};
        delete $f->{lead_position}; $f->{lead_waits}={}; $f->{lead_state}='unknown';
    }
    my $accept=sub {
        my ($line,$position)=@_;
        my $d=eval { decode_json($line) };
        return unless ref($d) eq 'HASH';
        my $p=$d->{payload};
        return unless ref($p) eq 'HASH';
        my $ts=stamp($d->{timestamp});
        if (epoch($ts) && scalar_text($d->{type}) =~ /^(event_msg|response_item|turn_context|token_usage_record|inter_agent_communication_metadata)$/) {
            $f->{last_evidence_ts}=$ts if epoch($ts)>epoch($f->{last_evidence_ts});
        }
        if ($f->{meta}{v2} && $position>($f->{lead_position}//0)
            && (scalar_text($d->{type}) eq 'token_usage_record' || (scalar_text($d->{type}) eq 'event_msg' && scalar_text($p->{type}) eq 'item_completed'))) {
            my $turn=identity($p->{turn_id});
            if ($turn && ($turn ne ($f->{lead_turn}//'') || ($f->{lead_state}//'unknown') eq 'unknown')) {
                $f->{lead_turn}=$turn; $f->{lead_state}='running'; $f->{lead_waits}={};
            }
            $f->{lead_position}=$position;
        }
        if (scalar_text($d->{type}) eq 'event_msg' && $position>($f->{lead_position}//0)) {
            my $event=scalar_text($p->{type});
            if ($event eq 'task_started') { $f->{lead_state}='running'; $f->{lead_turn}=identity($p->{turn_id}); $f->{lead_waits}={} }
            elsif ($event =~ /^(task_complete|turn_complete|task_failed|turn_aborted|task_aborted)$/) {
                $f->{lead_state}=$event =~ /complete$/ ? 'idle' : $event eq 'task_failed' ? 'failed' : 'interrupted';
            }
            $f->{lead_position}=$position if $event =~ /^(task_started|task_complete|turn_complete|task_failed|turn_aborted|task_aborted)$/;
        }
        if (scalar_text($d->{type}) eq 'response_item') {
            close_record($f,$p,$ts);
            if ($position>($f->{lead_position}//0) && ($p->{type}//'') eq 'function_call' && scalar_text($p->{name}) =~ /(?:^|[._])(?:wait|wait_agent)$/) {
                $f->{lead_position}=$position; $f->{lead_waits}{identity($p->{call_id}) || 'legacy'}=1; $f->{lead_state}='waiting';
            } elsif ($position>($f->{lead_position}//0) && ($p->{type}//'') eq 'function_call_output' && delete $f->{lead_waits}{identity($p->{call_id})}) {
                $f->{lead_position}=$position; $f->{lead_state}=keys %{$f->{lead_waits}//{}} ? 'waiting' : 'running';
            }
            return;
        }
        return unless scalar_text($d->{type}) eq 'turn_context';
        return unless identity($p->{turn_id}) && epoch($d->{timestamp});
        return if $f->{context} && $position<=$f->{context}{position};
        if ($position>($f->{lead_position}//0)) {
            $f->{lead_position}=$position; $f->{lead_state}=keys %{$f->{lead_waits}//{}} ? 'waiting' : 'running';
            $f->{lead_turn}=identity($p->{turn_id});
        }
        $f->{context}={position=>$position,ts=>stamp($d->{timestamp}),turn=>identity($p->{turn_id}),
            model=>identity($p->{model}),effort=>identity($p->{effort})};
    };
    my $key=$f->{key}//'';
    my $limit=$budget<131072 ? $budget : 131072;
    my @records=lines($path,$f,$limit); $used+=$f->{read_bytes}//0;
    if ($key ne ($f->{key}//'')) {
        ++$f->{context_revision} if $key ne '' && !$reset;
        $f->{context_invalidated}=1 if $f->{context};
        delete $f->{context}; delete $f->{tail_sig}; delete $f->{tail_start}; delete @$f{qw(tail_end tail_at back_chunk gap_start gap_end)}; delete $f->{complete_sig};
        delete $f->{lead_position}; $f->{lead_waits}={}; $f->{lead_state}='unknown';
    }
    $accept->(@$_) for @records;
    my @st=stat($path); return $used unless @st;
    my $sig=join(':',@st[0,1,7,9]);
    if ($f->{at_eof}) { $f->{tail_sig}=$sig; $f->{complete_sig}=$sig; return $used }
    my $room=$budget-$used; $room=131072 if $room>131072;
    my $now_t=$ENV{LOOMY_NATIVE_NOW}//time;
    if ($room>0 && ($f->{tail_sig}//'') ne $sig) {
        my $h=open_read($path) or return $used;
        # Growth since the last covered end is read incrementally; anything else restarts the window.
        my $incremental=defined $f->{tail_end} && defined $f->{tail_start} && $f->{tail_end}<=$st[7] && $st[7]-$f->{tail_end}<=$room;
        # A restarted window keeps the previous coverage so only the gap between the two has to be scanned.
        if (!$incremental && defined $f->{tail_end} && defined $f->{tail_start} && $f->{context} && $f->{context}{position}>$f->{tail_start}
            && $f->{tail_end}<=$st[7]) { @$f{qw(gap_start gap_end)}=($f->{tail_start},$f->{tail_end}) unless defined $f->{gap_end} }
        my $start=$incremental ? $f->{tail_end} : $st[7]>$room ? $st[7]-$room : 0;
        seek $h,$start,0 or return $used;
        my $want=$st[7]-$start; $want=$room if $want>$room;
        my $n=sysread($h,my $buf,$want); $used+=$n//0;
        return $used unless $n;
        my $end=rindex($buf,"\n"); my $skip=($start && !$incremental) ? index($buf,"\n")+1 : 0;
        my $position=$start+$skip;
        if ($end>=$skip) {
            for my $line (split /\n/,substr($buf,$skip,$end-$skip+1)) {
                $position+=length($line)+1; $accept->($line,$position);
            }
            $f->{tail_end}=$start+$end+1;
        } elsif (!$incremental) { delete $f->{tail_end} }
        $f->{tail_sig}=$sig; $f->{tail_at}=$now_t;
        $f->{tail_start}=$start+$skip unless $incremental;
    }
    if (defined $f->{gap_end} && defined $f->{tail_start}) {
        if ($f->{context} && $f->{context}{position}>$f->{tail_start}) { delete @$f{qw(gap_start gap_end)} }
        elsif ($f->{tail_start}<=$f->{gap_end}) { $f->{tail_start}=$f->{gap_start}; delete @$f{qw(gap_start gap_end)} }
    }
    # The newest turn_context may lie far behind a busy tail: extend the covered window backwards, a quarter MiB per tick.
    if (defined $f->{tail_start} && defined $f->{tail_end} && $f->{tail_start}>0
        && (!$f->{context} || $f->{context}{position}<=$f->{tail_start}) && $st[7]-$f->{tail_start}<16777216) {
        my $span=$f->{back_chunk}||262144; my $limit=$budget-$used; $span=$limit if $limit<$span;
        my $h=$span>=65536 ? open_read($path) : undef;
        if ($h) {
            my $to=$f->{tail_start}; my $from=$to>$span ? $to-$span : 0;
            if (seek $h,$from,0) {
                my $n=sysread($h,my $buf,$to-$from); $used+=$n//0;
                if ($n && $n==$to-$from) {
                    my $skip=$from ? index($buf,"\n")+1 : 0;
                    if ($from && ($skip==0 || $skip>=length($buf))) { $f->{back_chunk}=$span*2 if $span<8388608 }
                    else {
                        my $position=$from+$skip;
                        for my $line (split /\n/,substr($buf,$skip)) { $position+=length($line)+1; $accept->($line,$position) }
                        $f->{tail_start}=$from+$skip;
                    }
                }
            }
        }
    }
    return $used;
}

sub poll {
    my ($root,$sessions)=@_;
    return if ($ENV{LOOMY_JOURNAL}//'1') eq '0';
    $root=abs_path($root)//return;
    my $dir="$root/.loomy/logs";
    return unless safe_path($dir) && -d $dir;
    unless (safe_path($sessions)) {
        warn "Codex session path contains a symlink; tracking unavailable\n" unless $diagnosed{$sessions}++;
        return;
    }
    return unless -d $sessions;
    my $idx="$dir/codex-native.idx"; my $journal="$dir/events.jsonl";
    return unless safe_path($idx) && safe_path($journal);
    umask 0077;
    sysopen my $directory,$dir,O_RDONLY|O_NOFOLLOW or return; chmod 0700,$directory or return;
    return unless safe_path("$idx.lock");
    sysopen my $lock,"$idx.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return;
    flock($lock,LOCK_EX|LOCK_NB) or return;
    chmod 0600,$lock or return;
    my $isig=Loomy::LiveState::file_signature($idx);
    my $s=$cached{$idx} && $cached{$idx}{sig} eq $isig ? $cached{$idx}{state} : undef;
    my $now=$ENV{LOOMY_NATIVE_NOW}//time; my $day=int($now/86400);
    if ($s && ($cached{$idx}{pruned_day}//-1)==$day && ($cached{$idx}{poll_sig}//'') eq input_signature($root,$sessions,$now)
        && !(grep {!($_->{at_eof}//0)} values %{$s->{files}//{}})
        && !@{$inventory{$sessions}{queue}//[]} && ($s->{journal}{at_eof}//0) && !pending_input($root,$sessions,$s)) {return $s}
    $s=Loomy::LiveState::checkpoint_load($idx) unless $s;
    my $dirty=prune_checkpoint($s,$now);
    my $journal_lock=Loomy::LiveState::journal_lock($dir) or return;
    Loomy::LiveState::recover_rotation($journal,$dir);
    sysopen my $out,$journal,O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or return;
    chmod 0600,$out or return;
    my $jc=$s->{journal}//={};
    # Upgrade old checkpoints through the same bounded replay, without clearing deduplication or usage events.
    if (grep { !exists $_->{context_freshness} } values %{$s->{root_snapshots}//{}}) {
        $jc->{offset}=0;
        $_->{context_freshness}//='' for values %{$s->{root_snapshots}//{}};
    }
    # A replaced journal needs fresh owner evidence, but stable native keys remain deduplicated.
    my @js=stat($out); my $jk="$js[0]:$js[1]";
    my $generation=$jc->{generation}//1;
    for my $f (values %{$s->{files}//{}}) { $f->{journal_generation}//=$generation }
    if (($jc->{key}//'') ne $jk || ($jc->{offset}//0)>$js[7]) {
        ++$generation if $jc->{key};
        for my $key (keys %{$s->{owners}//{}}) {
            my $o=$s->{owners}{$key};
            $s->{owner_leads}{$key}={lead=>$o->{lead},session=>$o->{session}} if $o->{lead};
        }
        $s->{owners}={}; $jc->{active}={};
    }
    $jc->{generation}=$generation;
    my $input=Loomy::LiveState::recovery_path($journal,$jc);
    my %replay_files=map {$s->{files}{$_}{meta}{id}=>[$_,$s->{files}{$_}]} keys %{$s->{files}//{}};
    for my $record (lines($input,$jc,2097152)) {
        my $line=$record->[0];
        my $d=eval { decode_json($line) }; next unless Loomy::LiveState::valid_event($d);
        $s->{seen}{identity($d->{native_key})}=epoch($d->{ts}) || $now if identity($d->{native_key});
        if ($s->{reconstructing} && ($d->{bridge}//'') eq 'codex-native' && identity($d->{agent_id})
            && scalar_text($d->{source_offset}) =~ /^\d+$/) {
            my $aid=identity($d->{agent_id}); my $prior=$s->{recovery_sources}{$aid};
            $s->{recovery_sources}{$aid}=$d if !$prior || epoch($d->{ts})>=epoch($prior->{ts});
        }
        # Recover consumed source positions before bounded event keys age out.
        my $recovered=$replay_files{identity($d->{agent_id})}; my $f=$recovered ? $recovered->[1] : undef;
        if ($f && $f->{meta}{parent} && identity($d->{id}) && scalar_text($d->{source_offset}) =~ /^\d+$/
            && scalar_text($d->{source_inode}) eq ($f->{key}//'') && $d->{source_offset}>($f->{offset}//0)
            && safe_path($recovered->[0]) && $d->{source_offset}<=(-s $recovered->[0]//0)) {
            $f->{offset}=0+$d->{source_offset}; delete $f->{read_sig}; $f->{at_eof}=0;
            $f->{id}=identity($d->{id}); $f->{turn}=identity($d->{turn_id});
            $f->{started}=stamp($d->{ts}) if ($d->{type}//'') eq 'delegation_start';
            $f->{finished}=($d->{type}//'') eq 'delegation' ? 1 : 0;
            $f->{activity}=scalar_text($d->{activity}//$d->{state}) || 'unknown';
            $f->{model}=identity($d->{model}); $f->{effort}=identity($d->{effort});
            $f->{last_observed_ts}=stamp($d->{ts});
        }
        if (($d->{type}//'') eq 'session_context' && ($d->{tool}//'') eq 'codex' && ($d->{bridge}//'') eq 'codex-native' && ($d->{scope}//'') eq 'lead') {
            my $root_id=identity($d->{parent_session}) || identity($d->{session});
            if ($root_id) {
                my $revision=scalar_text($d->{context_revision});
                # Legacy records cannot reveal their hashed revision: one bounded recovery snapshot is safer than reuse.
                $revision=($s->{root_revisions}{$root_id}//0)+1 unless $revision =~ /\A[0-9]{1,12}\z/;
                if ($revision>=($s->{root_revisions}{$root_id}//0)) {
                    $s->{root_revisions}{$root_id}=0+$revision;
                    my $freshness=scalar_text($d->{context_freshness});
                    $freshness='' unless $freshness eq 'current' || $freshness eq 'catching_up';
                    $s->{root_snapshots}{$root_id}={known=>(identity($d->{model}) ne '' || identity($d->{effort}) ne '' ? 1 : 0),
                        ts=>stamp($d->{ts}),owner_pid=>scalar_text($d->{owner_pid}),context_freshness=>$freshness,context_revision=>0+$revision};
                }
            }
        }
        if (($d->{bridge}//'') eq 'codex-native' && identity($d->{id})) {
            $jc->{active}{$d->{id}}=1 if ($d->{type}//'') eq 'delegation_start';
            delete $jc->{active}{$d->{id}} if ($d->{type}//'') eq 'delegation';
        }
        next unless ($d->{type}//'') eq 'session' && ($d->{tool}//'') eq 'codex';
        my $pid=scalar_text($d->{pid}); next unless $pid =~ /^\d+$/ && $pid>1;
        if (($d->{event}//'') eq 'start') {
            my $key="$pid:".stamp($d->{ts});
            if (identity($d->{session})) {
                for my $candidate (sort { $s->{owners}{$a}{ts} cmp $s->{owners}{$b}{ts} } keys %{$s->{owners}//{}}) {
                    my $o=$s->{owners}{$candidate};
                    if (!$o->{ended} && !$o->{dead_at} && $o->{pid}==$pid && $o->{session} eq identity($d->{session})) { $key=$candidate; last }
                }
            }
            $s->{owners}{$key}//={pid=>0+$pid,ts=>stamp($d->{ts}),session=>identity($d->{session})};
            my $prior=$s->{owner_leads}{$key};
            $s->{owners}{$key}{lead}=$prior->{lead} if $prior && $prior->{session} eq identity($d->{session});
        } elsif (($d->{event}//'') eq 'end') {
            for my $o (values %{$s->{owners}//{}}) {
                $o->{ended}=stamp($d->{ts}) if !$o->{ended} && epoch($d->{ts})>=epoch($o->{ts})
                    && $o->{pid}==$pid && (!identity($d->{session}) || $o->{session} eq identity($d->{session}));
            }
        }
    }
    my %live_owner;
    for my $key (sort { $s->{owners}{$a}{ts} cmp $s->{owners}{$b}{ts} } keys %{$s->{owners}//{}}) {
        my $o=$s->{owners}{$key}; next if $o->{ended} || $o->{dead_at} || !$o->{session};
        my $group="$o->{pid}:$o->{session}";
        if (my $first=$live_owner{$group}) {
            $s->{owners}{$first}{lead}||=$o->{lead};
            delete $s->{owners}{$key};
        } else { $live_owner{$group}=$key }
    }
    if ($input ne $journal || !$jc->{at_eof}) { prune_checkpoint($s,$now); save($idx,$s); return $s }
    $dirty=1 if ($jc->{read_bytes}//0);
    my $discovery_bytes=discover($s,$sessions,$root,$now)//0; $dirty=1 if $discovery_bytes;
    # Replay fences survive event-key pruning; only matching source inodes are seekable.
    for my $path (keys %{$s->{files}//{}}) {
        my $f=$s->{files}{$path}; my $d=$s->{recovery_sources}{$f->{meta}{id}} or next;
        next unless $f->{meta}{parent}; my @st=stat($path);
        if (@st && "$st[0]:$st[1]" eq scalar_text($d->{source_inode}) && $d->{source_offset}<=$st[7]) {
            $f->{key}=scalar_text($d->{source_inode}); $f->{offset}=0+$d->{source_offset};
            $f->{id}=identity($d->{id}); $f->{turn}=identity($d->{turn_id});
            my $ts=epoch($d->{ts}); my $duration=scalar_text($d->{duration_s});
            $f->{started}=($d->{type}//'') eq 'delegation_start' ? stamp($d->{ts})
                : strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($ts-($duration =~ /^\d+(?:\.\d+)?$/ ? $duration : 0)));
            $f->{last_observed_ts}=stamp($d->{ts}); $f->{finished}=($d->{type}//'') eq 'delegation' ? 1 : 0;
            $f->{activity}=scalar_text($d->{activity}//$d->{state})||'unknown';
            $f->{model}=identity($d->{model}); $f->{effort}=identity($d->{effort});
            $f->{journal_generation}=$generation; delete $f->{read_sig};
        } else {$f->{replay_fence}=epoch($d->{ts})}
        delete $s->{recovery_sources}{$f->{meta}{id}}; $dirty=1;
    }
    if ($s->{reconstructing} && $jc->{at_eof} && $input eq $journal) {delete $s->{reconstructing}; $dirty=1}
    if (($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0') {
        for my $f (values %{$s->{files}//{}}) { $f->{meta}{task}=''; $f->{meta}{nickname}='' }
    }
    my $emitting_file;
    my $emit=sub {
        my ($key,$type,$ts,$body)=@_; $key=sha256_hex($key); return if $s->{seen}{$key};
        if (($body->{schema}//0)==2) {
            if ($emitting_file && $emitting_file->{meta}{parent}) {
                $body->{source_offset}=$emitting_file->{event_position}//$emitting_file->{offset}//0;
                $body->{source_inode}=$emitting_file->{key}//'';
                $body->{turn_id}//=$emitting_file->{turn} if $emitting_file->{meta}{v2};
            }
            delete @$body{qw(owner_pid pid_role)} if exists($body->{owner_pid}) && scalar_text($body->{owner_pid}) eq '0';
            $body->{source_ts}=stamp($ts); $body->{observed_at}=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
            $body->{evidence}//='rollout'; $body->{event_key}=$key; $body->{source_revision}//=$generation;
            $body->{state}//=$type eq 'delegation_start' ? 'running' : $type eq 'delegation_activity' ? ($body->{activity}//'unknown')
                : $type eq 'delegation' ? ($body->{status} eq 'ok' ? 'done' : $body->{status} eq 'error' ? 'failed' : $body->{status}) : 'unknown';
        }
        my $json=encode_json($body); $json =~ s/^\{//; $json =~ s/\}$//;
        print $out '{"ts":'.encode_json(stamp($ts)).',"type":'.encode_json($type).',"native_key":'.encode_json($key).($json ne '' ? ",$json" : '')."}\n" or die 'native journal write failed';
        $out->flush or die 'native journal flush failed';
        $s->{seen}{$key}=$now; $dirty=1;
        $jc->{active}{$body->{id}}=1 if $type eq 'delegation_start';
        delete $jc->{active}{$body->{id}} if $type eq 'delegation';
    };
    my @owners=sort { $b->{ts} cmp $a->{ts} } values %{$s->{owners}//{}};
    for my $o (@owners) {
        if (!$o->{dead_at} && !$o->{ended} && !alive($o->{pid})) {$o->{dead_at}=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now)); $dirty=1}
    }
    my $probe_budget=2097152-$discovery_bytes; my $probe_used=0;
    for my $o (@owners) {
        next if $o->{lead} || $o->{ended} || $o->{dead_at} || !alive($o->{pid});
        my @candidates;
        for my $path (sort keys %{$s->{files}//{}}) {
            my $m=$s->{files}{$path}{meta}; next if $m->{parent};
            if ($o->{session}) { push @candidates,$m->{id} if $m->{id} eq $o->{session}; next }
            next unless $m->{surface} eq 'cli';
            my $start=epoch($o->{ts}); my $created=epoch($m->{ts});
            if ($created && $created >= $start-10) { push @candidates,$m->{id}; next }
            # Resume keeps the original metadata timestamp: inspect only its bounded tail.
            my $record=$s->{files}{$path}; my @st=stat($path); my $sig=join(':',@st[0,1,7,9]);
            if (($record->{probe_sig}//'') ne $sig && $probe_budget>=65536) {
                my $f=open_read($path) or next; seek $f,($st[7]>65536 ? $st[7]-65536 : 0),0;
                my $n=sysread($f,my $tail,65536); $probe_budget-=$n//0; $probe_used+=$n//0;
                $record->{starts}=[]; $record->{probe_sig}=$sig;
                for my $line (split /\n/,$tail) {
                    my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH' && ($d->{type}//'') eq 'event_msg' && ref($d->{payload}) eq 'HASH' && ($d->{payload}{type}//'') eq 'task_started';
                    push @{$record->{starts}},epoch($d->{timestamp});
                }
            }
            push @candidates,$m->{id} if grep { $_ >= $start-10 } @{$record->{starts}//[]};
        }
        $o->{lead}=$candidates[0] if @candidates==1;
    }
    my %by_id=map { $_->{meta}{id}=>$_->{meta} } values %{$s->{files}//{}};
    # Launcher evidence enriches a group, but never decides whether it is collected.
    for my $m (values %by_id) {
        next if $m->{parent};
        next if grep { ($_->{lead}//'') eq $m->{id} } @owners;
        push @owners,{lead=>$m->{id},session=>$m->{id},ts=>$m->{ts},unbound=>1,pid=>0};
    }
    my $budget=2097152-$discovery_bytes-$probe_used;
    my @paths=sort keys %{$s->{files}//{}};
    my %path_slot; @path_slot{@paths}=(0..$#paths);
    my $rotation=@paths ? ($s->{read_rotation}//0)%@paths : 0;
    @paths=(@paths[$rotation..$#paths],@paths[0..$rotation-1]) if $rotation;
    my %recent;
    for my $path (@paths) {
        my @st=stat($path);
        $recent{$path}=1 if @st && $st[9]>=$now-120 && $st[9]<=$now+1;
    }
    # Current sources get this frame's evidence first; the remaining backlog still rotates.
    @paths=((grep {$recent{$_}} @paths),(grep {!$recent{$_}} @paths));
    for my $path (@paths) {
        my $f=$s->{files}{$path}; my $m=$f->{meta}; $emitting_file=$f;
        # Legacy activity snapshots omitted turn_id; its scoped native id retains it.
        if ($m->{v2} && !$f->{turn} && ($f->{id}//'') =~ /^cn:\Q$m->{id}\E:([A-Za-z0-9_.-]+)$/) { $f->{turn}=identity($1) }
        my @source_stat=stat($path);
        if (@source_stat && ($f->{source_mtime}//0)!=$source_stat[9]) { $f->{source_mtime}=$source_stat[9]; $dirty=1 }
        if (!$m->{parent}) {
            my ($owner)=grep { ($_->{lead}//'') eq $m->{id} } @owners;
            next unless $owner;
            my $recovered=$s->{root_revisions}{$m->{id}}//0;
            $f->{context_revision}=$recovered if $recovered>($f->{context_revision}//0);
            $f->{at_eof}=0 if $budget<=0;
            if ($budget>0) {
                $s->{read_rotation}=($path_slot{$path}+1)%@paths;
                my $used=root_context($path,$f,$budget); $budget-=$used; $dirty=1 if $used;
            }
            $owner=owner_at(\@owners,$m->{id},$f->{last_evidence_ts}//$m->{ts},$m->{ts});
            my $snapshot=$s->{root_snapshots}{$m->{id}};
            if (!$f->{context} && !$f->{context_invalidated} && $f->{at_eof} && $snapshot && $snapshot->{known}
                && $snapshot->{owner_pid} eq "$owner->{pid}" && epoch($snapshot->{ts})>=epoch($owner->{ts})-10) {
                ++$f->{context_revision}; $f->{context_invalidated}=1;
            }
            if (my $c=$f->{context}) {
                next if !$owner->{unbound} && epoch($c->{ts})<epoch($owner->{ts})-10;
                my @st=stat($path); my $sig=@st && safe_path($path) && -f $path ? join(':',@st[0,1,7,9]) : '';
                my $fresh=$sig ne '' && (($f->{complete_sig}//'') eq $sig || (($f->{tail_sig}//'') eq $sig || $now-($f->{tail_at}//0)<=5) && defined $f->{tail_start} && $c->{position}>$f->{tail_start});
                my $freshness=$fresh ? 'current' : 'catching_up';
                # Re-entering a prior freshness state is a new observation, not a duplicate of an old cycle.
                ++$f->{context_revision} if $snapshot && ($snapshot->{context_freshness}//'') ne '' && $snapshot->{context_freshness} ne $freshness;
                my $revision=$f->{context_revision}//0;
                $emit->("lead:$m->{id}:$owner->{pid}:$owner->{ts}:$revision:$c->{turn}:$c->{ts}:$c->{position}:$c->{model}:$c->{effort}:$freshness:$generation",'session_context',$c->{ts},
                    {schema=>2,session_key=>"codex:$m->{id}",surface=>$m->{surface},bridge=>'codex-native',tool=>'codex',scope=>'lead',session=>$owner->{session},parent_session=>$m->{id},
                        owner_pid=>$owner->{pid},pid_role=>'owner',model=>$c->{model},effort=>$c->{effort},turn_id=>$c->{turn},context_freshness=>$freshness,context_revision=>$revision});
                $s->{root_revisions}{$m->{id}}=$revision;
                $s->{root_snapshots}{$m->{id}}={known=>($c->{model} ne '' || $c->{effort} ne '' ? 1 : 0),ts=>$c->{ts},owner_pid=>"$owner->{pid}",context_freshness=>$freshness,context_revision=>$revision};
                delete $f->{context_invalidated};
            } elsif (delete $f->{context_invalidated}) {
                my $revision=$f->{context_revision}//0;
                $emit->("lead:$m->{id}:$owner->{pid}:$owner->{ts}:invalidated:$revision:$f->{key}:$f->{offset}:$generation",'session_context',strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now)),
                    {schema=>2,session_key=>"codex:$m->{id}",surface=>$m->{surface},bridge=>'codex-native',tool=>'codex',scope=>'lead',session=>$owner->{session},parent_session=>$m->{id},owner_pid=>$owner->{pid},pid_role=>'owner',model=>'',effort=>'',context_freshness=>'catching_up',context_revision=>$revision});
                $s->{root_revisions}{$m->{id}}=$revision;
                $s->{root_snapshots}{$m->{id}}={known=>0,ts=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now)),owner_pid=>"$owner->{pid}",context_freshness=>'catching_up',context_revision=>$revision};
            }
            my $state=$f->{lead_state}//'unknown';
            my $ts=$f->{last_evidence_ts}//$m->{ts};
            my $relative=($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0' ? '' : ($m->{cwd} eq $root ? '.' : substr($m->{cwd},length($root)+1));
            $emit->("session:$m->{id}:$state:".($f->{lead_turn}//'').":".($owner->{unbound} ? 'unbound' : "$owner->{pid}"),'session_observed',$ts,
                {schema=>2,session_key=>"codex:$m->{id}",session=>$m->{id},agent_id=>$m->{id},tool=>'codex',surface=>$m->{surface},
                    state=>$state,source_active=>($f->{last_evidence_ts} ? 1 : 0),cwd_relative=>$relative,owner_pid=>$owner->{pid},evidence=>($owner->{unbound} ? 'source lease' : 'launcher')});
            next;
        }
        # A child skipped by this tick's shared budget has no fresh EOF evidence.
        $f->{at_eof}=0 if $budget<=0;
        my $lead=lead_id($m,\%by_id); next unless $lead;
        my ($owner)=grep { ($_->{lead}//'') eq $lead } @owners;
        $owner//={lead=>$lead,session=>$lead,ts=>$m->{ts},unbound=>1,pid=>0} if $lead =~ /^pending:/;
        next unless $owner;
        my $base;
        my $bind=sub {
            $owner=owner_at(\@owners,$lead,$_[0],$m->{ts});
            $base={bridge=>'codex-native',family=>'codex',tool=>'codex',owner_pid=>$owner->{pid},pid_role=>'owner',
                schema=>2,session_key=>"codex:$lead",surface=>($by_id{$lead} ? $by_id{$lead}{surface} : 'unknown'),parent_agent_id=>"codex:$m->{parent}",
                parent_session=>$m->{parent},session=>$owner->{session},agent_id=>$m->{id},role=>($m->{role}||'agent'),
                task=>(($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0' ? '' : ($m->{task}||'Codex agent '.($m->{nickname}||$m->{id}))),nickname=>$m->{nickname},cost_in=>'unknown'};
            if ($m->{v2}) {
                $base->{multi_agent_version}='v2';
                $base->{task}=join(' ',grep {$_ ne ''} ($m->{nickname},$m->{role},$m->{task})) if ($ENV{LOOMY_JOURNAL_TASKS}//'1') ne '0';
            }
            delete @$base{qw(owner_pid pid_role)} if $owner->{unbound};
        };
        $bind->($f->{started}//$m->{ts});
        if ($lead =~ /^pending:/) {
            $emit->("pending:$lead",'session_observed',$m->{ts},
                {schema=>2,session_key=>"codex:$lead",session=>$lead,tool=>'codex',surface=>'unknown',state=>'unknown',source_active=>0,evidence=>'parent pending'});
        }
        if ($f->{id} && (($f->{projected_lead}//'') ne $lead || ($m->{v2} && ($f->{projected_metadata}//0)!=2))) {
            $emit->("agent:$m->{id}:link:$lead".($m->{v2} ? ':metadata2' : ''),'agent_link',$f->{last_observed_ts}//$f->{started},
                {%$base,id=>$f->{id},turn_id=>$f->{turn},model=>$f->{model},effort=>$f->{effort}});
        }
        $f->{projected_lead}=$lead;
        $f->{projected_metadata}=2;
        if ($budget>0) {
            $f->{last_observed_ts}//=observed_time($path,$f) if $f->{id} && !$f->{finished};
            $s->{read_rotation}=($path_slot{$path}+1)%@paths;
            my $limit=$budget<262144 ? $budget : 262144;
            my @records=$m->{v2} ? v2_records($path,$f,$limit) : lines($path,$f,$limit);
            for my $record (@records) {
                my ($line,$position)=@$record;
                my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH';
                my $p=$d->{payload}; next unless ref($p) eq 'HASH';
                my $type=scalar_text($d->{type}); my $event=scalar_text($p->{type}); my $ts=stamp($d->{timestamp}); next unless epoch($ts);
                next if $f->{replay_fence} && epoch($ts)<=$f->{replay_fence};
                if ($m->{v2}) {
                    next if identity($p->{thread_id}) && identity($p->{thread_id}) ne $m->{id};
                    next unless $type =~ /^(event_msg|turn_context|response_item|token_usage_record|inter_agent_communication_metadata)$/;
                    next if $position<=($f->{v2_position}//0);
                    $f->{v2_position}=$position;
                }
                $f->{event_position}=$position;
                close_record($f,$p,$ts) if $type eq 'response_item';
                my $turn=identity($p->{turn_id});
                my $inferred=$m->{v2} && $turn && ($type eq 'turn_context' || $type eq 'token_usage_record' || ($type eq 'event_msg' && $event eq 'item_completed'))
                    && (!$f->{id} || $turn ne ($f->{turn}//''));
                my $terminal=$m->{v2} && $turn && $type eq 'event_msg' && $event =~ /^(task_complete|turn_complete|task_failed|turn_aborted|task_aborted)$/
                    && (!$f->{id} || $turn ne ($f->{turn}//''));
                # Terminal evidence of a turn: its exact end when observed, never a guess.
                my $end_turn=sub {
                    my ($ev,$at,$text)=@_;
                    my $outcome='unknown';
                    $outcome='done' if $m->{v2} && $ev =~ /complete$/;
                    $outcome=lc($1) if $text =~ /^\s*STATUS\s*:\s*(done|partial|blocked)\b/im;
                    $outcome='interrupted' if $ev =~ /aborted$/;
                    $outcome='failed' if $ev eq 'task_failed';
                    my $duration=epoch($at)-epoch($f->{started}); $duration=0 if $duration<0;
                    $emit->("$f->{id}:end",'delegation',$at,{%$base,id=>$f->{id},turn_id=>$f->{turn},model=>$f->{model},effort=>$f->{effort},
                        status=>($ev =~ /complete$/ ? 'ok' : $ev eq 'task_failed' ? 'error' : 'interrupted'),outcome=>$outcome,duration_s=>$duration});
                    $f->{finished}=1; $f->{last_observed_ts}=$at; delete $f->{activity_ts};
                };
                if (($type eq 'event_msg' && $event eq 'task_started' && $turn) || $inferred || $terminal) {
                    # First sight of a turn in the tail window: recover its start, model and the previous turn's end.
                    my $facts={ends=>{}};
                    if ($m->{v2} && ($inferred || $terminal) && $position>($f->{v2_window}//9e15) && $budget>65536) {
                        my ($found,$extra)=v2_backfill($path,$turn,$f->{v2_window},$f->{offset}//0,$budget<4194304 ? $budget : 4194304);
                        $facts=$found; $budget-=$extra; $dirty=1;
                    }
                    if ($f->{id} && !$f->{finished} && ($f->{turn}//'') ne $turn) {
                        my $seen=$facts->{ends}{$f->{turn}//''};
                        if ($seen && epoch($seen->{ts})>=epoch($f->{started})) { $end_turn->($seen->{event},$seen->{ts},$seen->{text}) }
                        else {
                            my $end=$f->{last_observed_ts}//observed_time($path,$f)//$f->{started};
                            $end=$f->{started} if epoch($end)<epoch($f->{started});
                            my $duration=epoch($end)-epoch($f->{started}); $duration=0 if $duration<0;
                            $emit->("$f->{id}:end",'delegation',$end,{%$base,id=>$f->{id},turn_id=>$f->{turn},model=>$f->{model},effort=>$f->{effort},status=>'unknown',outcome=>'unknown',duration_s=>$duration});
                        }
                    }
                    my $begin=$ts;
                    if ($terminal && scalar_text($p->{started_at}) =~ /^\d{13}$/ && $p->{started_at}/1000<=epoch($ts)) {
                        $begin=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($p->{started_at}/1000));
                    } elsif ($facts->{started} && epoch($facts->{started})<=epoch($ts)) { $begin=$facts->{started} }
                    $bind->($begin);
                    $f->{turn}=$turn; $f->{started}=$begin; $f->{finished}=0;
                    $f->{id}="cn:$m->{id}:$turn"; $f->{model}=''; $f->{effort}='';
                    if ($inferred && $type eq 'turn_context') { $f->{model}=identity($p->{model}); $f->{effort}=identity($p->{effort}) }
                    elsif ($facts->{model}) { $f->{model}=$facts->{model}; $f->{effort}=$facts->{effort}//'' }
                    elsif ($m->{v2} && $f->{last_model}) { $f->{model}=$f->{last_model}; $f->{effort}=$f->{last_effort}//'' }
                    @$f{qw(last_model last_effort)}=($f->{model},$f->{effort}) if $f->{model} ne '';
                    $f->{activity}='running'; $f->{wait_calls}={}; $f->{last_observed_ts}=$ts; delete $f->{activity_ts}; delete $f->{activity_position};
                    $emit->("$f->{id}:start",'delegation_start',$begin,{%$base,id=>$f->{id},turn_id=>$turn,model=>$f->{model},effort=>$f->{effort}});
                    $f->{journal_generation}=$generation if $jc->{active}{$f->{id}};
                    next unless $terminal;
                }
                if ($type eq 'turn_context' && $turn && $turn eq ($f->{turn}//'')) {
                    $f->{model}=identity($p->{model}); $f->{effort}=identity($p->{effort});
                    @$f{qw(last_model last_effort)}=($f->{model},$f->{effort}) if $f->{model} ne '';
                    $f->{activity}=keys %{$f->{wait_calls}//{}} ? 'waiting' : 'running'; $f->{last_observed_ts}=$ts;
                    $emit->("$f->{id}:context:$position",'delegation_activity',$ts,{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},activity=>$f->{activity}});
                } elsif ($type eq 'event_msg' && $event =~ /^(task_complete|turn_complete|task_failed|turn_aborted|task_aborted)$/ && $f->{id} && (!$turn || $turn eq ($f->{turn}//'')) && !$f->{finished}) {
                    next if epoch($ts)<epoch($f->{started});
                    $end_turn->($event,$ts,scalar_text($p->{last_agent_message}));
                } elsif ($f->{id} && !$f->{finished} && ($type eq 'event_msg' || $type eq 'response_item'
                    || ($m->{v2} && ($type eq 'token_usage_record' || $type eq 'inter_agent_communication_metadata')))) {
                    $f->{activity_ts}=$ts;
                    $f->{last_observed_ts}=$ts;
                    $f->{activity_position}=$position;
                    if ($type eq 'response_item' && ($p->{type}//'') eq 'function_call' && scalar_text($p->{name}) =~ /(?:^|[._])(?:wait|wait_agent)$/) {
                        $f->{wait_calls}{identity($p->{call_id}) || 'legacy'}=1;
                    } elsif ($type eq 'response_item' && ($p->{type}//'') eq 'function_call_output') {
                        delete $f->{wait_calls}{identity($p->{call_id})};
                    }
                    $f->{activity}=keys %{$f->{wait_calls}//{}} ? 'waiting' : 'running';
                }
            }
            $budget-=$f->{read_bytes}//0; $dirty=1 if $f->{read_bytes};
            if ($f->{id} && !$f->{finished} && (($f->{oversized} && (!$m->{v2} || ($f->{v2_position}//0)<=($f->{oversized_at}//$f->{offset}//0))) || !safe_path($path) || !-f $path)) {
                $f->{activity}='unknown';
                $emit->("$f->{id}:unavailable:$f->{offset}",'delegation_activity',strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now)),{%$base,id=>$f->{id},activity=>'unknown'});
                delete $f->{oversized}; delete $f->{emitted_activity};
            }
            # A turn adopted without its turn_context learns model and effort once, from before the tail window.
            if ($m->{v2} && $f->{id} && !$f->{finished} && ($f->{model}//'') eq '' && ($f->{model_probe}//'') ne $f->{id}
                && ($f->{v2_window}//0)>0 && $budget>65536) {
                $f->{model_probe}=$f->{id};
                my ($found,$extra)=v2_backfill($path,$f->{turn},$f->{v2_window},0,$budget<1048576 ? $budget : 1048576);
                $budget-=$extra; $dirty=1;
                if ($found->{model}) {
                    @$f{qw(model effort last_model last_effort)}=($found->{model},$found->{effort}//'',$found->{model},$found->{effort}//'');
                    $f->{activity_ts}//=$f->{last_observed_ts}; $f->{activity_position}//=$f->{event_position}//$f->{offset};
                }
            }
            if ($f->{id} && !$f->{finished} && $f->{activity_ts}) {
                my $signature=join(':',$f->{id},$f->{model}//'',$f->{effort}//'',$f->{activity}//'unknown','a2');
                if (($f->{emitted_activity}//'') ne $signature) {
                    $emit->("$f->{id}:activity:$f->{activity_position}",'delegation_activity',$f->{activity_ts},{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},activity=>$f->{activity}});
                    $f->{emitted_activity}=$signature;
                }
                delete $f->{activity_ts};
            }
        }
        my ($parent)=grep { $_->{meta}{id} eq $m->{parent} } values %{$s->{files}};
        my $closed=$parent ? $parent->{closed_agents}{$m->{id}} : undef;
        $closed=undef if $closed && ((!$owner->{unbound} && epoch($closed)<epoch($owner->{ts})) || epoch($closed)<epoch($f->{started}));
        my $dead=$closed || (!$owner->{unbound} && ($owner->{ended} || $owner->{dead_at} || !alive($owner->{pid})));
        # A turn still open when its owner died is interrupted everywhere (turn end, agent close, projected state);
        # the 900 s quiet rule below only lets an idle agent close as done.
        my $open_turn=$dead && $f->{at_eof} && $f->{id} && !$f->{finished};
        if ($open_turn) {
            my $ts=$closed||$owner->{ended}||strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
            $ts=$f->{started} if epoch($ts)<epoch($f->{started});
            $emit->("$f->{id}:end",'delegation',$ts,{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},status=>'interrupted',outcome=>'interrupted',duration_s=>undef});
            $f->{finished}=1;
        }
        if ($dead && $f->{at_eof} && $f->{id}) {
            my $ts=$closed||$owner->{ended}||strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
            $ts=$f->{started} if epoch($ts)<epoch($f->{started});
            $emit->("agent:$m->{id}:$owner->{pid}:$owner->{ts}:close",'agent_closed',$ts,{%$base,id=>$f->{id},turn_id=>$f->{turn},status=>($closed || $open_turn || epoch($f->{last_observed_ts})>=$now-900 ? 'interrupted' : 'done')});
        }
        # Restore only an observed active turn; rotation is not new work or a new delegation.
        if (!$dead && $f->{id} && !$f->{finished} && !$s->{seen}{sha256_hex("$f->{id}:end")} && ($f->{journal_generation}//0)!=$generation && epoch($f->{started})>=epoch($owner->{ts})-10) {
            $f->{last_observed_ts}//=observed_time($path,$f);
            $emit->("$f->{id}:restore:$generation:start",'delegation_start',$f->{started},
                {%$base,id=>$f->{id},turn_id=>$f->{turn},model=>$f->{model},effort=>$f->{effort}});
            $emit->("$f->{id}:restore:$generation:activity",'delegation_activity',$f->{last_observed_ts}//$f->{started},
                {%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},activity=>$f->{activity}//'unknown'});
            $f->{journal_generation}=$generation;
        }
    }
    # The append and checkpoint share one lock; crash recovery replays only unseen native keys.
    $out->flush or die 'native journal flush failed'; $out->sync or die 'native journal sync failed';
    # Do not skip external owner/hooks appended between the read and our writes.
    my @end=stat($out);
    if ($end[7]>=8388608) {close $out; Loomy::LiveState::journal_rotate($journal)}
    prune_checkpoint($s,$now) if $dirty;
    save($idx,$s) if $dirty;
    $cached{$idx}={sig=>Loomy::LiveState::file_signature($idx),state=>$s,pruned_day=>$day};
    $cached{$idx}{poll_sig}=input_signature($root,$sessions,$now);
    return $s;
}

unless (caller) { eval { poll(@ARGV) }; exit($@ ? 1 : 0) }
1;

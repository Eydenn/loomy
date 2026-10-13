# Local Claude hooks/transcripts adapter; content-free output shared by watch and one-shot views.
package Loomy::ClaudeNative;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Fcntl qw(O_RDONLY O_RDWR O_APPEND O_CREAT O_NOFOLLOW LOCK_EX LOCK_NB);
use Cwd qw(abs_path);
use Time::HiRes ();
use IO::Handle;
my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+$}{};
require "$lib/codex-native.pl";
my (%cache,%inventory,%watch,%diagnosed,%retry);
use POSIX qw(strftime);
my $json=JSON::PP->new->canonical;
sub text { Loomy::CodexNative::scalar_text($_[0]) }
sub id { my $value=$_[0]; Loomy::CodexNative::identity($value) }
sub epoch { Loomy::CodexNative::epoch($_[0]) }
sub safe { Loomy::CodexNative::safe_path($_[0]) }
sub lines { Loomy::CodexNative::lines(@_) }
sub label { Loomy::CodexNative::label($_[0]) }
sub signature { my @s=Time::HiRes::stat($_[0]); return @s ? join(':',@s[0,1,7,9]) : '-' }
sub slug { my $p=$_[0]; $p =~ s/[^A-Za-z0-9]/-/g; return $p }
sub input_signature {
    my ($root,$projects)=@_; my $idx="$root/.loomy/logs/claude-native.idx";
    my $s=$cache{$idx}{state}//{}; my $inv=$inventory{$projects}//{};
    my %p=map {$_=>1} ($projects,$idx,"$root/.loomy/logs/events.jsonl",keys %{$s->{files}//{}},keys %{$inv->{dirs}//{}},keys %{$inv->{invalid}//{}});
    return join(';',map {$_ . ':' . signature($_)} sort keys %p);
}
# Signatures are committed only for bytes/inventory actually inspected during the poll.
sub pending_input {
    my ($root,$projects,$s)=@_;
    return 1 if ($s->{journal}{read_sig}//'') ne signature("$root/.loomy/logs/events.jsonl");
    for my $path (keys %{$s->{files}//{}}) {
        return 1 if ($s->{files}{$path}{read_sig}//'') ne signature($path);
    }
    for my $dir (keys %{$inventory{$projects}{dirs}//{}}) {
        return 1 if ($inventory{$projects}{dirs}{$dir}{sig}//'') ne signature($dir);
    }
    return 0;
}
sub watch_changed {
    my ($root,$projects)=@_; my $idx="$root/.loomy/logs/claude-native.idx";
    my $s=$cache{$idx}{state}//{}; my $sig=input_signature($root,$projects);
    my $committed=$cache{$idx}{poll_sig};
    my $changed=!defined($committed) || $committed ne $sig; $watch{$idx}=$sig;
    return $changed || pending_input($root,$projects,$s) || due($s) || ($s->{journal} && !($s->{journal}{at_eof}//0))
        || grep {!($_->{at_eof}//0)} values %{$s->{files}//{}};
}
# Only an explicit terminal envelope ends a Claude call; the reducer owns its 15-minute lease.
sub due { return 0 }
sub stale_calls { return 0 }
sub can_interrupt { return 0 }
sub session {
    my ($s,$sid)=@_; return $s->{sessions}{$sid}//={id=>$sid,surface=>'unknown',state=>'unknown',seen=>'',calls=>{},aliases=>{},stops=>{}};
}
sub call {
    my ($lead,$cid)=@_; return $lead->{calls}{$cid}//={call=>$cid,role=>'agent',model=>'',effort=>'',state=>'unknown',task=>''};
}
sub touch {
    my ($lead,$ts)=@_; $lead->{seen}=$ts if epoch($ts)>epoch($lead->{seen});
}
sub lead_state {
    my ($lead,$ts,$state)=@_; return if epoch($ts)+($ts =~ /\.\d+Z$/ ? 0 : 0.999)<epoch($lead->{state_ts});
    $lead->{state}=$state; $lead->{state_ts}=$ts;
}
sub start {
    my ($lead,$cid,$ts,$fields)=@_; return unless $cid && epoch($ts);
    my $c=call($lead,$cid);
    $c->{started}=$ts if !$c->{started} || epoch($ts)<epoch($c->{started});
    $c->{state}='running' unless $c->{ended};
    $c->{$_}=$fields->{$_} for grep {defined $fields->{$_} && !ref($fields->{$_}) && text($fields->{$_}) ne ''} qw(role model effort task);
    $c->{seen}=$ts if epoch($ts)>epoch($c->{seen});
    $c->{background}=1 if $fields->{background}; touch($lead,$ts); return $c;
}
sub child_activity {
    my ($c,$ts)=@_;
    # Legacy inferred interruptions are provisional; explicit stops remain terminal.
    if (($c->{status}//'') eq 'interrupted' && !$c->{terminal_evidence} && epoch($ts)>epoch($c->{ended})) {
        delete @$c{qw(ended status outcome)};
        $c->{reopened}=1; # A correction must publish once even if the state signature was running before.
    }
    $c->{seen}=$ts if epoch($ts)>epoch($c->{seen});
    $c->{state}='running' unless $c->{ended};
}
sub finish {
    my ($lead,$cid,$ts,$status,$outcome)=@_; return unless $cid && epoch($ts);
    my $c=$lead->{calls}{$cid} or return;
    return if ($c->{ended} && ($c->{status}//'') ne 'interrupted') || ($c->{started} && epoch($ts)<epoch($c->{started}));
    $c->{ended}=$ts; $c->{status}=$status; $c->{outcome}=$outcome||'unknown';
    $c->{state}=$status eq 'ok' ? 'done' : $status eq 'error' ? 'failed' : $status; touch($lead,$ts);
}
sub alias_link {
    my ($lead,$cid,$aid,$ts)=@_; return unless $cid && $aid;
    my $old=$lead->{aliases}{$aid}; return if $old && $old ne $cid && $old ne "agent:$aid";
    $lead->{aliases}{$aid}=$cid; my $c=call($lead,$cid); $c->{agent}=$aid;
    # Child evidence may precede the tool result. Merge only this exact identity pair.
    if ($cid ne "agent:$aid" && (my $orphan=delete $lead->{calls}{"agent:$aid"})) {
        $c->{$_}=$orphan->{$_} for grep {!defined $c->{$_} || text($c->{$_}) eq ''} qw(model effort);
        $c->{started}=$orphan->{started} if $orphan->{started} && (!$c->{started} || epoch($orphan->{started})<epoch($c->{started}));
        child_activity($c,$orphan->{seen}) if epoch($orphan->{seen});
        $c->{source_mtime}=$orphan->{source_mtime} if ($orphan->{source_mtime}//0)>($c->{source_mtime}//0);
        finish($lead,$cid,$orphan->{ended},$orphan->{status},$orphan->{outcome}) if $orphan->{ended};
        $c->{alias_from}="agent:$aid";
    }
    my $stop=$lead->{stops}{$aid}; finish($lead,$cid,$stop->{ts},$stop->{status},$stop->{outcome}) if $stop;
    touch($lead,$ts);
}
sub stop {
    my ($lead,$aid,$ts,$status,$outcome)=@_; return unless $aid && epoch($ts);
    $lead->{stops}{$aid}//={ts=>$ts,status=>$status,outcome=>$outcome||'unknown'};
    my $cid=$lead->{aliases}{$aid}; finish($lead,$cid,$ts,$status,$outcome) if $cid; touch($lead,$ts);
}
sub hook {
    my ($s,$e)=@_; return if ($e->{bridge}//'') eq 'claude-native';
    my $type=text($e->{type}); my $sid=id($e->{session}); return unless $sid;
    return unless ($type eq 'session' && text($e->{tool}) eq 'claude') || ($type eq 'session_activity' && text($e->{tool}) eq 'claude')
        || $type eq 'request' || $type =~ /^subagent_(?:link|stop)$/ || text($e->{bridge}) eq 'subagent';
    my $ts=text($e->{source_ts}//$e->{ts}); return unless epoch($ts);
    return if epoch($ts)<=($s->{fences}{$sid}//0);
    my $lead=session($s,$sid); touch($lead,$ts);
    if ($type eq 'session') { lead_state($lead,$ts,text($e->{event}) eq 'end' ? 'unknown' : 'idle'); return }
    if ($type eq 'request' || $type eq 'session_activity') { lead_state($lead,$ts,$type eq 'request' ? 'running' : text($e->{state})); return }
    my $cid=id($e->{id}); my $aid=id($e->{agent_id});
    if ($type eq 'delegation_start') {
        my $c=start($lead,$cid,$ts,{role=>label($e->{role}),model=>id($e->{model}),effort=>id($e->{effort}),background=>$e->{background},
            task=>(($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0' ? '' : label($e->{task}))});
        $lead->{waits}{$cid}=1 if $c && !$c->{background} && !$c->{ended};
        lead_state($lead,$ts,keys %{$lead->{waits}//{}} ? 'waiting' : 'running');
    } elsif ($type eq 'subagent_link') {
        alias_link($lead,$cid,$aid,$ts); call($lead,$cid)->{returned}=1 if $cid; delete $lead->{waits}{$cid};
        lead_state($lead,$ts,keys %{$lead->{waits}//{}} ? 'waiting' : 'running');
    }
    elsif ($type eq 'subagent_stop') { stop($lead,$aid,$ts,'ok',text($e->{outcome})) }
    elsif ($type eq 'delegation') {
        alias_link($lead,$cid,$aid,$ts) if $aid;
        # The source stop, rather than a delayed hook return, supplies the terminal time.
        my $st=$lead->{stops}{$aid};
        finish($lead,$cid,$st ? $st->{ts} : $ts,text($e->{status})||'unknown',text($e->{outcome}));
        delete $lead->{waits}{$cid};
        lead_state($lead,$ts,keys %{$lead->{waits}//{}} ? 'waiting' : 'running');
    }
}
# The filename owns identity; resumed heads belong to a previous session/project.
sub metadata {
    my ($path,$root,$parent,$bytes)=@_; my $f=Loomy::CodexNative::open_read($path) or return;
    my $sid=$parent || ($path =~ m{/([^/]+)\.jsonl$} ? id($1) : ''); return unless $sid;
    my $size=-s $f; my $start=$size>262144 ? $size-262144 : 0;
    seek $f,$start,0 or return; my $n=sysread($f,my $buf,262144)//0;
    $$bytes+=$n if $bytes;
    $buf =~ s/^[^\n]*\n// if $start;
    for my $line (reverse split /\n/,$buf) {
        my $e=eval {decode_json($line)}; next unless ref($e) eq 'HASH' && id($e->{sessionId}) eq $sid;
        next unless text($e->{cwd}) ne '';
        my $cwd=abs_path(text($e->{cwd}))//'';
        return {invalid=>1} unless $cwd && ($cwd eq $root || index($cwd,"$root/")==0);
        my $aid=$parent && $path =~ m{/agent-([^/]+)\.jsonl$} ? id($1) : '';
        my $entry=text($e->{entrypoint});
        return {id=>$sid,agent=>$aid,cwd=>$cwd,surface=>$entry eq 'claude-desktop' ? 'app' : $entry =~ /^(cli|claude-cli)$/ ? 'cli' : 'unknown'};
    }
    warn "Claude transcript metadata unavailable within 256 KiB; tracking unknown\n" if $n==262144 && !$diagnosed{$path}++;
    return;
}
sub discover {
    my ($s,$projects,$root)=@_; return 0 unless safe($projects) && -d $projects;
    my $inv=$inventory{$projects}//={dirs=>{},paths=>{},checked=>{},invalid=>{}}; my $prefix=slug($root);
    my @q=([$projects,0,'']);
    while (my $item=shift @q) {
        my ($dir,$depth,$parent)=@$item; next unless safe($dir) && -d $dir;
        my $sig=signature($dir); my $d=$inv->{dirs}{$dir};
        if (!$d || $d->{sig} ne $sig) {
            opendir my $h,$dir or next;
            my @names=sort grep {$_ ne '.' && $_ ne '..'} readdir $h;
            $d=$inv->{dirs}{$dir}={sig=>$sig,names=>\@names};
        }
        for my $name (@{$d->{names}}) {
            my $path="$dir/$name";
            if ($depth==0) {push @q,[$path,1,''] if $name eq $prefix || index($name,"$prefix-")==0}
            elsif ($depth==1) {
                if ($name =~ /^([A-Za-z0-9_.:-]{1,100})\.jsonl$/) {$inv->{paths}{$path}=''}
                elsif (id($name) && -d $path) {push @q,[$path,2,$name]}
            } elsif ($depth==2 && $name eq 'subagents') {push @q,[$path,3,$parent]}
            elsif ($depth==3 && $name =~ /^agent-[A-Za-z0-9_.:-]+\.jsonl$/) {$inv->{paths}{$path}=$parent}
        }
    }
    my $bytes=0;
    for my $path (sort keys %{$inv->{paths}}) {
        next unless safe($path) && -f $path;
        my @st=stat($path); my $key=join(':',@st[0,1]);
        next if ($inv->{checked}{$path}//'') eq $key;
        if ($s->{files}{$path} && ($s->{files}{$path}{key}//'') eq $key) {$inv->{checked}{$path}=$key; next}
        my $sig=signature($path); my $bad=$inv->{invalid}{$path};
        next if $bad && ($bad->{permanent} ? $bad->{key} eq $key && $st[7]>=$bad->{size} : $bad->{sig} eq $sig);
        last if $bytes+($st[7]<262144 ? $st[7] : 262144)>2097152;
        my $m=metadata($path,$root,$inv->{paths}{$path},\$bytes);
        unless ($m && !$m->{invalid}) {$inv->{invalid}{$path}={sig=>$sig,key=>$key,size=>$st[7],permanent=>($m && $m->{invalid} ? 1 : 0)}; next}
        delete $inv->{invalid}{$path}; $inv->{checked}{$path}=$key;
        $s->{files}{$path}={meta=>$m,offset=>0,key=>$key};
        my $lead=session($s,$m->{id}); $lead->{cwd_relative}=$m->{cwd} eq $root ? '.' : substr($m->{cwd},length($root)+1);
        $lead->{surface}=$m->{surface} if $m->{surface} ne 'unknown';
    }
    return $bytes;
}
sub transcript_record {
    my ($s,$f,$e)=@_; return unless ref($e) eq 'HASH';
    my $m=$f->{meta}; my $sid=id($e->{sessionId}); return if $sid && $sid ne $m->{id};
    my $ts=text($e->{timestamp}); return unless epoch($ts);
    return if epoch($ts)<=($f->{replay_fence}//0);
    return if epoch($ts)<=($s->{fences}{$m->{id}}//0);
    my $type=text($e->{type}); return unless $type =~ /^(user|assistant|system|progress|queue-operation)$/;
    my $lead=session($s,$m->{id}); touch($lead,$ts); $f->{last_evidence_ts}=$ts;
    my $aid=$m->{agent}; my $cid=$aid ? ($lead->{aliases}{$aid}//"agent:$aid") : '';
    my $msg=ref($e->{message}) eq 'HASH' ? $e->{message} : {};
    my $content=ref($msg->{content}) eq 'ARRAY' ? $msg->{content} : [];
    if (!$aid && $type eq 'queue-operation' && text($e->{operation}) eq 'enqueue') {
        # Read only the notification envelope's identity/status, never its summary/result.
        my $notification=text($e->{content});
        if ($notification =~ /<task-notification>/ && $notification =~ /<tool-use-id>([A-Za-z0-9_.:-]{1,100})<\/tool-use-id>/) {
            my $call=$1;
            if ($notification =~ /<status>(completed|failed|killed)<\/status>/) {
                my $status=$1 eq 'completed' ? 'ok' : $1 eq 'failed' ? 'error' : 'interrupted';
                $lead->{pending_notify}{$call}={ts=>$ts,status=>$status,outcome=>$status eq 'error' ? 'failed' : 'unknown'};
                notify($lead,$call) if $lead->{calls}{$call};
            }
        }
        return;
    }
    if ($aid) {
        # A structural child user record establishes its start; assistant text never ends it.
        start($lead,$cid,$ts,{}) if $type eq 'user' && !call($lead,$cid)->{started};
        $lead->{aliases}{$aid}//=$cid;
        my $c=call($lead,$cid); child_activity($c,$ts); $c->{model}=id($msg->{model}) if id($msg->{model});
        if ($type eq 'assistant' && text($msg->{stop_reason}) eq 'end_turn') {
            stop($lead,$aid,$ts,'ok','unknown');
        } elsif ($e->{isApiErrorMessage} || ($type eq 'system' && text($e->{subtype}) eq 'error')) {
            stop($lead,$aid,$ts,'error','failed');
        }
        return;
    }
    $lead->{model}=id($msg->{model}) if id($msg->{model});
    $lead->{effort}=id($e->{effort}) if id($e->{effort});
    my $has_result=grep {ref($_) eq 'HASH' && text($_->{type}) eq 'tool_result'} @$content;
    $lead->{state}='running' if $type eq 'user' && !$has_result;
    for my $b (@$content) {
        next unless ref($b) eq 'HASH'; my $bt=text($b->{type});
        if ($bt eq 'tool_use' && text($b->{name}) =~ /^(Agent|Task)$/ && id($b->{id})) {
            my $in=ref($b->{input}) eq 'HASH' ? $b->{input} : {};
            my $c=start($lead,id($b->{id}),$ts,{role=>label($in->{subagent_type})||'agent',model=>id($in->{model}),background=>$in->{run_in_background}});
            notify($lead,id($b->{id}));
            $lead->{waits}{id($b->{id})}=1 unless $c->{background} || $c->{ended} || $c->{returned};
        } elsif ($bt eq 'tool_result' && id($b->{tool_use_id})) {
            my $call=id($b->{tool_use_id}); my $r=ref($e->{toolUseResult}) eq 'HASH' ? $e->{toolUseResult} : {};
            next unless $lead->{calls}{$call};
            my $agent=id($r->{agentId}//$r->{agent_id}); alias_link($lead,$call,$agent,$ts) if $agent;
            my $c=call($lead,$call); $c->{background}=1 if $r->{isAsync} || text($r->{status}) eq 'async_launched'; $c->{returned}=1;
            delete $lead->{waits}{$call};
            finish($lead,$call,$ts,'error','failed') if $b->{is_error};
            finish($lead,$call,$ts,'ok','unknown') unless $b->{is_error} || $c->{background};
        }
    }
    $lead->{state}='waiting' if keys %{$lead->{waits}//{}};
    $lead->{state}='running' if $has_result && !keys %{$lead->{waits}//{}};
    if (($type eq 'assistant' && text($msg->{stop_reason}) eq 'end_turn')
        || ($type eq 'system' && text($e->{subtype}) eq 'turn_duration')) { $lead->{state}='idle' }
}
# Older head catch-up enriches identities without rolling back newer lifecycle evidence.
sub transcript {
    my ($s,$f,$e)=@_; return unless ref($e) eq 'HASH';
    my $sid=id($e->{sessionId}); return if $sid && $sid ne $f->{meta}{id};
    my $ts=text($e->{timestamp});
    return if epoch($ts)<=($s->{fences}{$f->{meta}{id}}//0);
    my $lead=session($s,$f->{meta}{id});
    my %prior=map {$_=>$lead->{$_}} qw(state model effort);
    return if epoch($ts)<=($s->{fences}{$f->{meta}{id}}//0);
    my $old=epoch($ts)<epoch($lead->{state_ts});
    transcript_record($s,$f,$e);
    if ($old) {$lead->{$_}=$prior{$_} for keys %prior}
    elsif (epoch($ts)) {$lead->{state_ts}=$ts}
}
sub notify {
    my ($lead,$cid)=@_; my $n=delete $lead->{pending_notify}{$cid} or return;
    finish($lead,$cid,$n->{ts},$n->{status},$n->{outcome});
    call($lead,$cid)->{terminal_evidence}=1;
    delete $lead->{waits}{$cid};
    lead_state($lead,$n->{ts},'idle') unless keys %{$lead->{waits}//{}} || grep {!$_->{ended}} values %{$lead->{calls}};
}
# Historical lead content cannot affect identities; decode lifecycle candidates and the latest envelope.
sub relevant_result {
    my ($s,$f,$line)=@_;
    return 0 if index($line,'tool_result')<0;
    return 1 if index($line,'async_launched')>=0 || index($line,'agentId')>=0 || index($line,'agent_id')>=0;
    # Ordinary large Bash results do not carry Agent lifecycle evidence.
    my $calls=$s->{sessions}{$f->{meta}{id}}{calls}//{};
    return scalar(grep {index($line,$_)>=0} keys %$calls);
}
sub replay_records {
    my ($s,$f,$records,$filter)=@_;
    for my $i (0..$#$records) {
        my $line=$records->[$i][0];
        next if $filter && $i<$#$records && index($line,'queue-operation')<0 && !relevant_result($s,$f,$line)
            && index($line,'turn_duration')<0 && index($line,'"end_turn"')<0 && index($line,'isApiErrorMessage')<0
            && !(index($line,'tool_use')>=0 && (index($line,'"Agent"')>=0 || index($line,'"Task"')>=0));
        my $e=eval {decode_json($line)}; transcript($s,$f,$e);
    }
}
# New lifecycle tails share the fixed total budget, independently of the contiguous cursor.
sub read_transcript {
    my ($s,$path,$f,$budget)=@_;
    my $catchup=!$f->{meta}{agent} && (-s $path)-($f->{offset}//0)>131072;
    my $limit=$catchup ? $budget-($budget>131072 ? 131072 : 0) : ($budget>131072 ? 131072 : $budget);
    my @records=lines($path,$f,$limit); replay_records($s,$f,\@records,$catchup);
    my $used=$f->{read_bytes}//0; my $sig=signature($path);
    if ($f->{meta}{agent}) {
        my $lead=session($s,$f->{meta}{id}); my $aid=$f->{meta}{agent}; my $c=$lead->{calls}{$lead->{aliases}{$aid}//"agent:$aid"};
        my @st=stat($path); $c->{source_mtime}=$st[9] if $c && @st;
    }
    return $used if $f->{at_eof} || $budget-$used<=0 || ($f->{tail_sig}//'') eq $sig;
    my $h=Loomy::CodexNative::open_read($path) or return $used;
    my $room=$budget-$used; $room=131072 if $room>131072;
    my $size=-s $h; my $start=$size>$room ? $size-$room : 0;
    seek $h,$start,0 or return $used; my $n=sysread($h,my $buf,$room)//0; $used+=$n;
    my $skip=$start ? index($buf,"\n")+1 : 0; my $end=rindex($buf,"\n");
    if ($end>=$skip) {
        my @tail=map {[$_]} split /\n/,substr($buf,$skip,$end-$skip+1);
        replay_records($s,$f,\@tail,!$f->{meta}{agent});
    }
    $f->{tail_sig}=$sig; return $used;
}
# Keep source cursors and replay fences when terminal detail ages out.
sub prune {
    my ($s,$dirty)=@_; my $now=$ENV{LOOMY_NATIVE_NOW}//time;
    my @ended;
    for my $sid (keys %{$s->{sessions}//{}}) {
        my $lead=$s->{sessions}{$sid};
        for my $cid (keys %{$lead->{pending_notify}//{}}) {
            next if $now-epoch($lead->{pending_notify}{$cid}{ts})<=604800;
            delete $lead->{pending_notify}{$cid}; $$dirty=1;
        }
        push @ended,map {[$sid,$_,epoch($lead->{calls}{$_}{ended})]} grep {$lead->{calls}{$_}{ended}} keys %{$lead->{calls}};
    }
    @ended=sort {$b->[2]<=>$a->[2]} @ended;
    my %retired;
    for my $i (0..$#ended) {
        my ($sid,$cid,$end)=@{$ended[$i]}; next if $i<1000 && $now-$end<=604800;
        my $lead=$s->{sessions}{$sid};
        $s->{fences}{$sid}=$end if $end>($s->{fences}{$sid}//0);
        delete $lead->{calls}{$cid}; delete $lead->{waits}{$cid};
        $retired{"$sid:$cid"}=1;
        delete $s->{sent}{"$_:cl:$sid:$cid"} for qw(start end context alias);
        $$dirty=1;
    }
    for my $sid (keys %{$s->{sessions}//{}}) {
        my $lead=$s->{sessions}{$sid};
        for my $aid (keys %{$lead->{aliases}}) {
            if ($retired{"$sid:$lead->{aliases}{$aid}"}) {delete $lead->{aliases}{$aid}; delete $lead->{stops}{$aid}}
        }
        for my $aid (keys %{$lead->{stops}//{}}) {
            next if $lead->{aliases}{$aid} || $now-epoch($lead->{stops}{$aid}{ts})<=604800;
            delete $lead->{stops}{$aid}; $$dirty=1;
        }
        next if keys %{$lead->{calls}} || $now-epoch($lead->{seen})<=604800;
        $s->{fences}{$sid}=epoch($lead->{seen}) if epoch($lead->{seen})>($s->{fences}{$sid}//0);
        delete $s->{sessions}{$sid}; delete $s->{sent}{"session:$sid"}; delete $s->{sent}{"context:$sid"}; $$dirty=1;
    }
}
sub poll {
    my $root=abs_path($_[0])//$_[0]; my $idx="$root/.loomy/logs/claude-native.idx";
    return if ($retry{$idx}//0)>Time::HiRes::time();
    my $result=eval {poll_locked(@_)}; my $error=$@;
    if (!defined $result) {$retry{$idx}=Time::HiRes::time()+5}
    else {delete $retry{$idx}}
    if ($error) {delete $cache{$idx}; die $error}
    return $result;
}
sub poll_locked {
    my ($root,$projects)=@_; return if ($ENV{LOOMY_JOURNAL}//'1') eq '0';
    $root=abs_path($root)//return; my $dir="$root/.loomy/logs"; return unless safe($dir) && -d $dir;
    unless (safe($projects)) {warn "Claude project path contains a symlink; tracking unavailable\n" unless $diagnosed{$projects}++; return}
    my $idx="$dir/claude-native.idx"; my $journal="$dir/events.jsonl"; return unless safe($idx) && safe($journal);
    my $day=int(($ENV{LOOMY_NATIVE_NOW}//time)/86400);
    if ($cache{$idx} && ($cache{$idx}{pruned_day}//-1)==$day && ($cache{$idx}{poll_sig}//'') eq input_signature($root,$projects) && !due($cache{$idx}{state})
        && !pending_input($root,$projects,$cache{$idx}{state})
        && ($cache{$idx}{state}{journal}{at_eof}//0) && !grep {!($_->{at_eof}//0)} values %{$cache{$idx}{state}{files}//{}}) {return $cache{$idx}{state}}
    umask 0077;
    sysopen my $directory,$dir,O_RDONLY|O_NOFOLLOW or return; chmod 0700,$directory or return;
    return unless safe("$idx.lock");
    sysopen my $lock,"$idx.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return;
    flock($lock,LOCK_EX|LOCK_NB) or return; chmod 0600,$lock or return;
    my $sig=signature($idx); my $s=$cache{$idx} && defined $cache{$idx}{sig} && $cache{$idx}{sig} eq $sig ? $cache{$idx}{state} : undef;
    $s=Loomy::LiveState::checkpoint_load($idx) unless $s;
    my $dirty=($s->{version}//0)!=2; $s->{version}=2;
    if (($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0') {
        for my $saved (values %{$s->{sent}//{}}) {
            my $e=eval {decode_json($saved)}; next unless ref($e) eq 'HASH';
            $dirty=1 if ($e->{task}//'') ne ''; $e->{task}='' if exists $e->{task}; $saved=$json->encode($e);
        }
    }
    my $journal_lock=Loomy::LiveState::journal_lock($dir) or return;
    Loomy::LiveState::recover_rotation($journal,$dir);
    sysopen my $out,$journal,O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or return;
    flock($out,LOCK_EX|LOCK_NB) or return; chmod 0600,$out or return;
    my $jc=$s->{journal}//={};
    my $input=Loomy::LiveState::recovery_path($journal,$jc);
    for my $r (lines($input,$jc,2097152)) {
        my $e=eval {decode_json($r->[0])}; next unless Loomy::LiveState::valid_event($e);
        if (text($e->{bridge}) eq 'claude-native' && text($e->{checkpoint_key}) ne '') {
            $s->{sent}{text($e->{checkpoint_key})}=text($e->{checkpoint_value});
        }
        if ($s->{reconstructing} && text($e->{bridge}) eq 'claude-native') {
            my $sid=id($e->{session}); my $cid=id($e->{turn_id});
            if ($sid) {
                my $lead=session($s,$sid); touch($lead,text($e->{source_ts}//$e->{ts}));
                if ($cid) {
                    my $c=call($lead,$cid); my $type=text($e->{type});
                    $c->{$_}=text($e->{$_}) for grep {exists $e->{$_}} qw(role task model effort state outcome status);
                    $c->{started}=text($e->{source_ts}//$e->{ts}) if $type eq 'delegation_start';
                    if ($type eq 'delegation') {
                        $c->{ended}=text($e->{source_ts}//$e->{ts});
                        $c->{state}=text($e->{status}) eq 'ok' ? 'done' : text($e->{status}) eq 'error' ? 'failed' : text($e->{status});
                    }
                    $c->{seen}=text($e->{source_ts}//$e->{ts});
                }
            }
        }
        hook($s,$e);
    }
    if ($input ne $journal || !$jc->{at_eof}) {prune($s,\$dirty); Loomy::LiveState::checkpoint_save($idx,$s); return $s}

    if ($s->{reconstructing}) {delete $s->{reconstructing}; $dirty=1}
    my $discovered=discover($s,$projects,$root);
    $dirty=1 if $discovered || ($jc->{read_bytes}//0);
    my $budget=2097152-$discovered;
    my @paths=sort keys %{$s->{files}//{}}; my $rotation=$s->{rotation}//0;
    for my $slot (0..$#paths) {
        last if $budget<=0; my $path=$paths[($rotation+$slot)%@paths]; my $f=$s->{files}{$path};
        # Cold one-shot polls also pay module/projection costs: leave CPU headroom below 80 ms.
        my $cap=$f->{meta}{agent} ? 262144 : 1572864;
        my $limit=$budget<$cap ? $budget : $cap;
        my $used=read_transcript($s,$path,$f,$limit);
        $budget-=$used; $dirty=1 if $used;
        $s->{rotation}=($rotation+$slot+1)%@paths if ($f->{read_bytes}//0)>0;
    }
    prune($s,\$dirty);
    my $emit=sub {
        my ($key,$type,$ts,$body)=@_; return unless epoch($ts);
        my $encoded=$key =~ /^start:/ ? "1" : $key =~ /^end:/ ? "$ts:$body->{status}" : $json->encode({%$body}); return if ($s->{sent}{$key}//'') eq $encoded;
        $s->{sent}{$key}=$encoded; $dirty=1;
        print $out encode_json({%$body,checkpoint_key=>$key,checkpoint_value=>$encoded,type=>$type,ts=>$ts,source_ts=>$ts,schema=>2,tool=>'claude',family=>'claude',bridge=>'claude-native'}),"\n" or die 'Claude journal write failed';
    };
    for my $sid (sort keys %{$s->{sessions}//{}}) {
        my $lead=$s->{sessions}{$sid}; next unless epoch($lead->{seen});
        my $catchup=grep {$_->{meta}{id} eq $sid && !$_->{meta}{agent} && !$_->{at_eof}} values %{$s->{files}//{}};
        for my $cid (keys %{$lead->{calls}}) {
            my $c=$lead->{calls}{$cid};
            $c->{state}='unknown' if $catchup && !$c->{ended} && epoch($lead->{seen})-epoch($c->{seen}//$c->{started})>900;
        }
        if (($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0') {$_->{task}='' for values %{$lead->{calls}}}
        my $source=(grep {$_->{meta}{id} eq $sid} values %{$s->{files}//{}}) ? 'transcript' : 'hook';
        my $base={source=>$source,session_key=>"claude:$sid",session=>$sid,surface=>$lead->{surface},agent_id=>$sid};
        $emit->("session:$sid",'session_observed',$lead->{seen},{%$base,state=>$lead->{state},source_active=>1,cwd_relative=>$lead->{cwd_relative}//'.',evidence=>'source lease'});
        $emit->("context:$sid",'session_context',$lead->{seen},{%$base,model=>$lead->{model}//'',effort=>$lead->{effort}//''}) if $lead->{model};
        for my $cid (sort keys %{$lead->{calls}}) {
            my $c=$lead->{calls}{$cid}; my $turn="cl:$sid:$cid";
            # The Agent call already represents a launched child; wait for its exact return alias.
            next if $cid =~ /^agent:/ && grep {$_ !~ /^agent:/ && !$lead->{calls}{$_}{agent} && !$lead->{calls}{$_}{ended}} keys %{$lead->{calls}};
            my $b={%$base,id=>$turn,turn_id=>$cid,agent_id=>"$sid:$cid",parent_agent_id=>"claude:$sid",role=>$c->{role},task=>$c->{task},model=>$c->{model},effort=>$c->{effort},cost_in=>'usage',cost_usd=>0};
            if ($c->{alias_from}) {
                $emit->("alias:$turn",'agent_alias',$lead->{seen},{%$b,alias_from=>"$sid:$c->{alias_from}",alias_id=>"cl:$sid:$c->{alias_from}"});
            }
            # Start and terminal signatures have fixed semantic identities; late model changes use activity.
            unless ($s->{sent}{"start:$turn"}) {$emit->("start:$turn",'delegation_start',$c->{started},$b) if $c->{started}}
            delete $s->{sent}{"context:$turn"} if delete $c->{reopened};
            $emit->("context:$turn",'delegation_activity',$c->{seen}//$c->{started}//$lead->{seen},
                {%$b,state=>$c->{state}}) if $c->{started} && !$c->{ended};
            {
                my $duration=$c->{started} && ($c->{status}//'') ne 'interrupted' ? epoch($c->{ended})-epoch($c->{started}) : undef;
                $emit->("end:$turn",'delegation',$c->{ended},{%$b,status=>$c->{status},outcome=>$c->{outcome},(defined $duration ? (duration_s=>$duration) : ())}) if $c->{ended};
            }
        }
    }
    $out->flush or die 'Claude journal flush failed'; $out->sync or die 'Claude journal sync failed';
    # Keep the consumed offset: hooks appended during source collection must be replayed next poll.
    if (-s $journal>=8388608) {close $out; Loomy::LiveState::journal_rotate($journal)}
    prune($s,\$dirty);
    Loomy::LiveState::checkpoint_save($idx,$s) if $dirty;
    $cache{$idx}={sig=>signature($idx),state=>$s,pruned_day=>$day}; $cache{$idx}{poll_sig}=input_signature($root,$projects); $watch{$idx}=$cache{$idx}{poll_sig}; return $s;
}
unless (caller) {my ($root,$projects)=@ARGV; poll($root,$projects//"$ENV{HOME}/.claude/projects")}
1;

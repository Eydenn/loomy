# Local Codex rollout ingestion. Loaded by the watch sampler or invoked with perl.
package Loomy::CodexNative;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Fcntl qw(O_RDONLY O_RDWR O_WRONLY O_CREAT O_APPEND O_NOFOLLOW LOCK_EX LOCK_NB);
use Cwd qw(abs_path);
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Errno qw(EPERM);
use IO::Handle;
use Digest::SHA qw(sha256_hex);

sub scalar_text { defined $_[0] && !ref($_[0]) ? "$_[0]" : '' }
sub identity { scalar_text($_[0]) =~ /\A[A-Za-z0-9_.:-]{1,100}\z/ ? scalar_text($_[0]) : '' }
sub label { my $s=scalar_text($_[0]); $s =~ s/[^A-Za-z0-9 _.-]/ /g; return substr($s,0,40) }
sub stamp { my $s=scalar_text($_[0]); $s =~ s/\.\d+Z$/Z/; return $s }
sub epoch {
    my @t=stamp($_[0]) =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/;
    return @t ? (eval { timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0]) } // 0) : 0;
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

# sysread has a fixed budget; offsets stop at complete lines, including malformed ones.
sub lines {
    my ($path,$cursor,$budget)=@_; $cursor->{read_bytes}=0; $cursor->{at_eof}=0;
    my $f=open_read($path) or return ();
    my @s=stat($f); my $key="$s[0]:$s[1]";
    if (($cursor->{key}//'') ne $key || ($cursor->{offset}//0)>$s[7]) { $cursor->{offset}=0; delete $cursor->{skipping} }
    $cursor->{key}=$key; my $off=$cursor->{offset}//0;
    $cursor->{read_start}=$off;
    seek $f,$off,0 or return ();
    my $n=sysread($f,my $buf,$budget); $cursor->{read_bytes}=$n//0;
    my @after=stat($f);
    $cursor->{at_eof}=1 if defined $n && $off+$n >= $s[7] && $after[7]==$s[7] && $after[9]==$s[9];
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
        if ($n==$budget) { $cursor->{offset}=$off+$n; $cursor->{skipping}=1; $cursor->{oversized}=1 }
        return ();
    }
    $cursor->{offset}=$off+$end+1;
    my @records; my $pos=$off+$skip;
    for my $line (split /\n/,substr($buf,$skip,$end-$skip+1)) { $pos+=length($line)+1; push @records,[$line,$pos] }
    return @records;
}

sub metadata {
    my $f=open_read($_[0]) or return;
    sysread($f,my $buf,65536); my ($line)=$buf =~ /\A([^\n]*)\n/; return unless defined $line;
    my $d=eval { decode_json($line) }; return unless ref($d) eq 'HASH' && ($d->{type}//'') eq 'session_meta';
    my $p=$d->{payload}; return unless ref($p) eq 'HASH' && identity($p->{id});
    my $spawn=ref($p->{source}) eq 'HASH' && ref($p->{source}{subagent}) eq 'HASH' ? $p->{source}{subagent}{thread_spawn} : undef;
    my $parent=ref($spawn) eq 'HASH' ? identity($spawn->{parent_thread_id}) : '';
    my $source=scalar_text($p->{source});
    return unless $parent || $source eq 'cli' || $source eq 'vscode';
    my $task=ref($spawn) eq 'HASH' ? scalar_text($spawn->{agent_path}) : '';
    $task =~ s{.*/}{};
    my $names=($ENV{LOOMY_JOURNAL_TASKS}//'1') ne '0';
    return {id=>identity($p->{id}),parent=>$parent,cwd=>scalar_text($p->{cwd}),task=>($names ? label($task) : ''),
        ts=>stamp($p->{timestamp}//$d->{timestamp}),role=>label($p->{agent_role}//(ref($spawn) eq 'HASH' ? $spawn->{agent_role} : '')),
        nickname=>($names ? label($p->{agent_nickname}//(ref($spawn) eq 'HASH' ? $spawn->{agent_nickname} : '')) : '')};
}

# Only recent date directories, capped file count, cached metadata, no recursive history traversal.
sub discover {
    my ($s,$sessions,$root,$now)=@_;
    return if $now<($s->{discover_after}//0);
    $s->{discover_after}=$now+5;
    my @paths;
    for my $day (-1..6) {
        my $dir="$sessions/".strftime('%Y/%m/%d',gmtime($now-$day*86400));
        next unless safe_path($dir) && -d $dir;
        opendir my $dh,$dir or next;
        my @names; my $n=0;
        while (my $name=readdir $dh) { last if ++$n>4096; push @names,$name if $name =~ /^rollout-.*\.jsonl$/ }
        push @paths,map { "$dir/$_" } (reverse sort @names)[0..($#names<127 ? $#names : 127)] if @names;
    }
    my %present=map { $_=>1 } @paths;
    for my $p (keys %{$s->{checked}//{}}) { delete $s->{checked}{$p} unless $present{$p} || $s->{files}{$p} }
    for my $p (keys %{$s->{invalid}//{}}) { delete $s->{invalid}{$p} unless $present{$p} }
    my $read=0;
    for my $path (@paths) {
        next unless safe_path($path) && -f $path;
        my @st=stat($path); my $sig="$st[0]:$st[1]";
        next if ($s->{checked}{$path}//'') eq $sig;
        my $version=join(':',@st[0,1,7,9]);
        next if ($s->{invalid}{$path}//'') eq $version;
        last if ++$read>32;
        my $m=metadata($path);
        if (!$m) { $s->{invalid}{$path}=$version; next }
        delete $s->{invalid}{$path};
        $s->{checked}{$path}=$sig;
        next unless safe_path($m->{cwd}) && (abs_path($m->{cwd})//'') eq $root;
        $s->{files}{$path}={meta=>$m,offset=>0};
    }
}

sub save {
    my ($lock,$s)=@_;
    seek $lock,0,0; print $lock encode_json($s) or die 'native checkpoint write failed';
    $lock->flush or die 'native checkpoint flush failed';
    truncate $lock,tell($lock) or die 'native checkpoint truncate failed';
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

sub poll {
    my ($root,$sessions)=@_;
    return if ($ENV{LOOMY_JOURNAL}//'1') eq '0';
    $root=abs_path($root)//return;
    my $dir="$root/.loomy/logs";
    return unless safe_path($dir) && -d $dir && safe_path($sessions) && -d $sessions;
    my $idx="$dir/codex-native.idx"; my $journal="$dir/events.jsonl";
    return unless safe_path($idx) && safe_path($journal);
    umask 0077;
    sysopen my $lock,$idx,O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return;
    flock($lock,LOCK_EX|LOCK_NB) or return;
    chmod 0600,$lock or return;
    my $raw=''; sysread($lock,$raw,4194304);
    my $s=eval { decode_json($raw) }; $s={} unless ref($s) eq 'HASH' && ($s->{version}//0)==1;
    $s->{version}=1;
    sysopen my $out,$journal,O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or return;
    flock($out,LOCK_EX|LOCK_NB) or return;
    chmod 0600,$out or return;
    my $now=time;
    my $jc=$s->{journal}//={};
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
    for my $record (lines($journal,$jc,2097152)) {
        my $line=$record->[0];
        my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH';
        $s->{seen}{identity($d->{native_key})}=1 if identity($d->{native_key});
        if (($d->{bridge}//'') eq 'codex-native' && identity($d->{id})) {
            $jc->{active}{$d->{id}}=1 if ($d->{type}//'') eq 'delegation_start';
            delete $jc->{active}{$d->{id}} if ($d->{type}//'') eq 'delegation';
        }
        next unless ($d->{type}//'') eq 'session' && ($d->{tool}//'') eq 'codex';
        my $pid=scalar_text($d->{pid}); next unless $pid =~ /^\d+$/ && $pid>1;
        if (($d->{event}//'') eq 'start') {
            my $key="$pid:".stamp($d->{ts});
            $s->{owners}{$key}//={pid=>0+$pid,ts=>stamp($d->{ts}),session=>identity($d->{session})};
            my $prior=$s->{owner_leads}{$key};
            $s->{owners}{$key}{lead}=$prior->{lead} if $prior && $prior->{session} eq identity($d->{session});
        } elsif (($d->{event}//'') eq 'end') {
            for my $o (values %{$s->{owners}//{}}) { $o->{ended}=stamp($d->{ts}) if $o->{pid}==$pid && (!identity($d->{session}) || $o->{session} eq identity($d->{session})) }
        }
    }
    if (($jc->{offset}//0)<$js[7]) { save($lock,$s); return }
    discover($s,$sessions,$root,$now);
    if (($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0') {
        for my $f (values %{$s->{files}//{}}) { $f->{meta}{task}=''; $f->{meta}{nickname}='' }
    }
    my $emit=sub {
        my ($key,$type,$ts,$body)=@_; $key=sha256_hex($key); return if $s->{seen}{$key};
        my $json=encode_json($body); $json =~ s/^\{//; $json =~ s/\}$//;
        print $out '{"ts":'.encode_json(stamp($ts)).',"type":'.encode_json($type).',"native_key":'.encode_json($key).($json ne '' ? ",$json" : '')."}\n" or die 'native journal write failed';
        $out->flush or die 'native journal flush failed';
        $s->{seen}{$key}=1;
        $jc->{active}{$body->{id}}=1 if $type eq 'delegation_start';
        delete $jc->{active}{$body->{id}} if $type eq 'delegation';
    };
    my @owners=sort { $b->{ts} cmp $a->{ts} } values %{$s->{owners}//{}};
    my $probe_budget=2097152;
    for my $o (@owners) {
        next if $o->{lead} || $o->{ended} || !alive($o->{pid});
        my @candidates;
        for my $path (sort keys %{$s->{files}//{}}) {
            my $m=$s->{files}{$path}{meta}; next if $m->{parent};
            if ($o->{session}) { push @candidates,$m->{id} if $m->{id} eq $o->{session}; next }
            my $start=epoch($o->{ts}); my $created=epoch($m->{ts});
            if ($created && $created >= $start-10 && $created <= $start+120) { push @candidates,$m->{id}; next }
            # Resume keeps the original metadata timestamp: inspect only its bounded tail.
            my $record=$s->{files}{$path}; my @st=stat($path); my $sig=join(':',@st[0,1,7,9]);
            if (($record->{probe_sig}//'') ne $sig && $probe_budget>=65536) {
                my $f=open_read($path) or next; seek $f,($st[7]>65536 ? $st[7]-65536 : 0),0;
                my $n=sysread($f,my $tail,65536); $probe_budget-=$n//0;
                $record->{starts}=[]; $record->{probe_sig}=$sig;
                for my $line (split /\n/,$tail) {
                    my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH' && ($d->{type}//'') eq 'event_msg' && ref($d->{payload}) eq 'HASH' && ($d->{payload}{type}//'') eq 'task_started';
                    push @{$record->{starts}},epoch($d->{timestamp});
                }
            }
            push @candidates,$m->{id} if grep { $_ >= $start-10 && $_ <= $start+120 } @{$record->{starts}//[]};
        }
        $o->{lead}=$candidates[0] if @candidates==1;
    }
    my $budget=2097152;
    my @paths=sort keys %{$s->{files}//{}};
    my $rotation=@paths ? ($s->{read_rotation}//0)%@paths : 0;
    @paths=(@paths[$rotation..$#paths],@paths[0..$rotation-1]) if $rotation;
    my $position=0;
    for my $path (@paths) {
        my $slot=$position++;
        my $f=$s->{files}{$path}; my $m=$f->{meta}; next unless $m->{parent};
        # A child skipped by this tick's shared budget has no fresh EOF evidence.
        $f->{at_eof}=0;
        my ($owner)=grep { ($_->{lead}//'') eq $m->{parent} } @owners; next unless $owner;
        my $base={bridge=>'codex-native',family=>'codex',tool=>'codex',owner_pid=>$owner->{pid},pid_role=>'owner',
            parent_session=>$m->{parent},session=>$owner->{session},agent_id=>$m->{id},role=>($m->{role}||'agent'),
            task=>(($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0' ? '' : ($m->{task}||'Codex agent '.($m->{nickname}||$m->{id}))),nickname=>$m->{nickname},cost_in=>'unknown'};
        my $dead=$owner->{ended} || !alive($owner->{pid});
        if ($budget>0) {
            $s->{read_rotation}=($rotation+$slot+1)%@paths;
            my $limit=$budget<262144 ? $budget : 262144;
            for my $record (lines($path,$f,$limit)) {
                my ($line,$position)=@$record;
                my $d=eval { decode_json($line) }; next unless ref($d) eq 'HASH';
                my $p=$d->{payload}; next unless ref($p) eq 'HASH';
                my $type=scalar_text($d->{type}); my $event=scalar_text($p->{type}); my $ts=stamp($d->{timestamp}); next unless epoch($ts);
                my $turn=identity($p->{turn_id});
                if ($type eq 'event_msg' && $event eq 'task_started' && $turn) {
                    next if epoch($ts)<epoch($owner->{ts})-10;
                    if ($f->{id} && !$f->{finished} && ($f->{turn}//'') ne $turn) {
                        $emit->("$f->{id}:end",'delegation',$ts,{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},status=>'unknown',outcome=>'unknown',duration_s=>epoch($ts)-epoch($f->{started})});
                    }
                    $f->{turn}=$turn; $f->{started}=$ts; $f->{finished}=0;
                    $f->{id}="cn:$m->{id}:$turn"; $f->{model}=''; $f->{effort}='';
                    $f->{activity}='running'; $f->{last_observed_ts}=$ts;
                    $emit->("$f->{id}:start",'delegation_start',$ts,{%$base,id=>$f->{id},turn_id=>$turn,model=>'',effort=>''});
                    $f->{journal_generation}=$generation if $jc->{active}{$f->{id}};
                } elsif ($type eq 'turn_context' && $turn && $turn eq ($f->{turn}//'')) {
                    $f->{model}=identity($p->{model}); $f->{effort}=identity($p->{effort});
                    $f->{activity}='running'; $f->{last_observed_ts}=$ts;
                    $emit->("$f->{id}:context:$position",'delegation_activity',$ts,{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},activity=>'running'});
                } elsif ($type eq 'event_msg' && $event =~ /^(task_complete|turn_aborted|task_aborted)$/ && $f->{id} && (($turn && $turn eq ($f->{turn}//'')) || (!$turn && $event ne 'task_complete'))) {
                    my $outcome='unknown'; my $text=scalar_text($p->{last_agent_message});
                    $outcome=lc($1) if $text =~ /^\s*STATUS\s*:\s*(done|partial|blocked)\b/im;
                    $outcome='interrupted' if $event ne 'task_complete';
                    my $duration=epoch($ts)-epoch($f->{started}); $duration=0 if $duration<0;
                    $emit->("$f->{id}:end",'delegation',$ts,{%$base,id=>$f->{id},turn_id=>$turn,model=>$f->{model},effort=>$f->{effort},
                        status=>($event eq 'task_complete' ? 'ok' : 'interrupted'),outcome=>$outcome,duration_s=>$duration});
                    $f->{finished}=1;
                } elsif ($f->{id} && !$f->{finished} && ($type eq 'event_msg' || $type eq 'response_item')) {
                    $f->{activity_ts}=$ts;
                    $f->{last_observed_ts}=$ts;
                    $f->{activity_position}=$position;
                    $f->{activity}=($type eq 'response_item' && ($p->{type}//'') eq 'function_call' && ($p->{name}//'') =~ /^(wait|wait_agent)$/) ? 'waiting' : 'running';
                }
            }
            $budget-=$f->{read_bytes}//0;
            if ($f->{id} && !$f->{finished} && ($f->{oversized} || !safe_path($path) || !-f $path)) {
                $f->{activity}='unknown';
                $emit->("$f->{id}:unavailable:$f->{offset}",'delegation_activity',strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now)),{%$base,id=>$f->{id},activity=>'unknown'});
                delete $f->{oversized};
            }
            if ($f->{id} && !$f->{finished} && $f->{activity_ts}) {
                $emit->("$f->{id}:activity:$f->{activity_position}",'delegation_activity',$f->{activity_ts},{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},activity=>$f->{activity}});
                delete $f->{activity_ts};
            }
        }
        if ($dead && $f->{at_eof} && $f->{id} && !$f->{finished}) {
            my $ts=$owner->{ended}||strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
            $emit->("$f->{id}:end",'delegation',$ts,{%$base,id=>$f->{id},model=>$f->{model},effort=>$f->{effort},status=>'interrupted',outcome=>'interrupted',duration_s=>undef});
            $f->{finished}=1;
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
    my @end=stat($out); $jc->{offset}=$end[7]; $jc->{key}="$end[0]:$end[1]";
    save($lock,$s);
}

unless (caller) { eval { poll(@ARGV) }; exit($@ ? 1 : 0) }
1;

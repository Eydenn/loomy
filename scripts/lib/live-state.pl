# Shared, content-free live projection. The sampler owns this reducer; one-shot views use it once.
package Loomy::LiveState;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Time::Local qw(timegm);
use Fcntl qw(O_RDONLY O_RDWR O_WRONLY O_CREAT O_EXCL O_APPEND O_NOFOLLOW LOCK_EX LOCK_NB);
use Errno qw(EPERM);
use Cwd qw(abs_path);
use Time::HiRes ();
use IO::Handle;
use POSIX qw(strftime);
# Direct CLI migration can load an adapter which requires this same module.
$INC{abs_path(__FILE__)}=1;

sub text { defined $_[0] && !ref($_[0]) ? "$_[0]" : '' }
sub epoch {
    my @t=text($_[0]) =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$/;
    return @t ? (eval { timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0]) } // 0)+($t[6]//0) : 0;
}
sub safe_path {
    my $p=$_[0]; return 0 unless defined $p && $p =~ m{^/};
    while ($p ne '') { return 0 if -l $p; $p =~ s{/[^/]*$}{} } return 1;
}
# One stable lock protects rotation and every writer, including native collectors.
sub journal_lock {
    my ($dir,$blocking)=@_; return unless safe_path("$dir/events.lock");
    sysopen my $f,"$dir/events.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return;
    chmod 0600,$f or return; flock($f,LOCK_EX|($blocking ? 0 : LOCK_NB)) or return; return $f;
}
sub file_signature {
    my @s=Time::HiRes::stat($_[0]); return @s ? join(':',@s[0,1,7,9]) : '-';
}
sub checkpoint_load {
    my ($path)=@_; my $exists=0;
    for my $candidate ($path,"$path.bak") {
        next unless -e $candidate; $exists=1;
        next unless safe_path($candidate) && -f $candidate && -s $candidate<=33554432;
        sysopen my $f,$candidate,O_RDONLY|O_NOFOLLOW or next;
        my $raw=''; while (1) {my $n=sysread($f,my $b,262144); last unless $n; $raw.=$b; last if length($raw)>33554432}
        next if !length($raw) || length($raw)>33554432;
        my $s=eval {decode_json($raw)};
        next unless ref($s) eq 'HASH' && (!exists $s->{version} || text($s->{version}) =~ /^(1|2)$/);
        # Reject broken containers rather than silently discarding saved deduplication.
        next if grep {exists $s->{$_} && ref($s->{$_}) ne 'HASH'} qw(files seen sent journal sessions owners);
        if (exists $s->{source_shards}) {
            my $ok=eval {load_shards($path,$s); 1}; next unless $ok;
        }
        warn "Native checkpoint recovered from backup\n" if $candidate ne $path;
        return $s;
    }
    if ($exists) {
        # Keep damaged evidence untouched while bounded journal replay rebuilds a separate generation.
        for my $candidate ($path,"$path.bak") {
            next unless -e $candidate;
            die 'unsafe damaged checkpoint' unless safe_path($candidate) && -f $candidate;
            my @st=stat($candidate); my $saved="$candidate.invalid-$st[0]-$st[1]";
            die 'unsafe checkpoint quarantine' unless safe_path($saved) && !-e $saved;
            rename $candidate,$saved or die 'checkpoint preservation failed'; chmod 0600,$saved or die;
        }
        my $dir=$path; $dir =~ s{/[^/]+$}{};
        my @segments;
        if (safe_path("$dir/archive") && -d "$dir/archive") {
            opendir my $archive,"$dir/archive" or die 'archive reconstruction open failed';
            @segments=sort {(stat($a))[9]<=>(stat($b))[9] || $a cmp $b}
                grep {safe_path($_) && -f $_}
                map {"$dir/archive/$_"} grep {/^events-\d{4}-\d{2}-\d+-\d+\.jsonl$/} readdir $archive;
        }
        my $cursor={};
        if (@segments) {my @st=stat($segments[0]); $cursor={key=>"$st[0]:$st[1]",offset=>0}}
        warn "Native checkpoint invalid; reconstructing from journal in bounded polls\n";
        return {version=>2,reconstructing=>1,journal=>$cursor};
    }
    return {};
}
sub load_shards {
    my ($path,$s)=@_; my $refs=delete $s->{source_shards};
    die 'invalid source shards' unless ref($refs) eq 'ARRAY' && @$refs<=64;
    my %files; my $total=0;
    for my $name (@$refs) {
        die 'invalid shard identity' unless text($name) =~ /^files-[0-9a-f]{64}$/;
        my $p="$path.$name"; die 'unsafe source shard' unless safe_path($p) && -f $p && -s $p<=262144;
        sysopen my $f,$p,O_RDONLY|O_NOFOLLOW or die; local $/; my $raw=<$f>; $total+=length($raw);
        die 'source inventory exceeds 16 MiB' if $total>16777216;
        require Digest::SHA; die 'source shard checksum mismatch' unless $name eq 'files-'.Digest::SHA::sha256_hex($raw);
        my $part=decode_json($raw); die 'invalid source shard' unless ref($part) eq 'HASH';
        $files{$_}=$part->{$_} for keys %$part;
    }
    $s->{files}=\%files;
}
sub atomic_file {
    my ($path,$raw)=@_; die 'unsafe atomic destination' unless safe_path($path);
    my $tmp="$path.tmp.$$"; die 'unsafe atomic temporary' unless safe_path($tmp);
    sysopen my $f,$tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600 or die 'atomic temporary open failed';
    my $ok=eval {chmod 0600,$f or die; print $f $raw or die; $f->flush or die; $f->sync or die;
        close $f or die; rename $tmp,$path or die; 1};
    unless ($ok) {unlink $tmp; die 'atomic write failed'}
}
sub checkpoint_save {
    my ($path,$s)=@_; $s->{version}=2;
    my $json=JSON::PP->new->canonical; my %snapshot=%$s;
    my $raw=$json->encode(\%snapshot);
    if (length($raw)>2097152 && keys %{$s->{files}//{}}) {
        my (%part,@shards); my $size=2; my $total=0;
        my $write=sub {
            return unless keys %part; my $chunk=$json->encode(\%part); $total+=length($chunk);
            die 'source inventory exceeds 16 MiB' if $total>16777216 || @shards>=64;
            require Digest::SHA; my $name='files-'.Digest::SHA::sha256_hex($chunk);
            my $p="$path.$name"; atomic_file($p,$chunk) unless -f $p && safe_path($p);
            push @shards,$name; %part=(); $size=2;
        };
        for my $key (sort keys %{$s->{files}}) {
            my $bytes=length($json->encode({$key=>$s->{files}{$key}}));
            die 'active source exceeds 256 KiB; checkpoint paused' if $bytes>262144;
            $write->() if $size+$bytes>262144; $part{$key}=$s->{files}{$key}; $size+=$bytes;
        }
        $write->(); delete $snapshot{files}; $snapshot{source_shards}=\@shards; $raw=$json->encode(\%snapshot);
    }
    die "Native checkpoint exceeds 2 MiB; active state preserved in memory\n" if length($raw)>2097152;
    # Preserve the last valid generation; an invalid primary must not replace a usable backup.
    if (-s $path && -s $path<=33554432 && safe_path($path)) {
        sysopen my $old,$path,O_RDONLY|O_NOFOLLOW or die 'checkpoint backup open failed';
        local $/; my $prior=<$old>; my $valid=eval {decode_json($prior)};
        my $ok=ref($valid) eq 'HASH' && eval {load_shards($path,$valid) if exists $valid->{source_shards}; 1};
        atomic_file("$path.bak",$prior) if $ok;
    }
    atomic_file($path,$raw);
    # Keep only shards referenced by the primary or its backup, after both are durable.
    my %keep=map {text($_)=>1} @{$snapshot{source_shards}//[]};
    if (-f "$path.bak" && safe_path("$path.bak")) {
        sysopen my $b,"$path.bak",O_RDONLY|O_NOFOLLOW or die; local $/; my $old=eval {decode_json(<$b>)};
        $keep{text($_)}=1 for @{ref($old) eq 'HASH' ? ($old->{source_shards}//[]) : []};
    }
    my $dir=$path; $dir =~ s{/[^/]+$}{}; my $base=$path; $base =~ s{.*/}{};
    opendir my $h,$dir or return; my @names=readdir $h;
    return if grep {/^\Q$base\E\.invalid-/} @names; # Preserve damaged evidence and its shards.
    for my $name (@names) {
        next unless $name =~ /^\Q$base\E\.(files-[0-9a-f]{64})$/;
        unlink "$dir/$name" unless $keep{$1} || !safe_path("$dir/$name");
    }
}
# Rotation keeps structural snapshots, never usage; archives are immutable size-bounded segments.
sub recover_rotation {
    my ($path,$dir)=@_; return unless -e "$dir/rotation";
    die 'unsafe rotation marker' unless safe_path("$dir/rotation") && -s "$dir/rotation"<=4096;
    sysopen my $f,"$dir/rotation",O_RDONLY|O_NOFOLLOW or die; local $/;
    my $r=decode_json(<$f>);
    die 'invalid rotation marker' unless ref($r) eq 'HASH' && text($r->{archive}) =~ /^events-\d{4}-\d{2}-\d+-\d+\.jsonl$/
        && text($r->{month}) =~ /^\d{4}-\d{2}$/ && text($r->{key}) =~ /^\d+:\d+$/;
    my $dest="$dir/archive/$r->{archive}";
    die 'unsafe rotation recovery' unless safe_path($dest) && safe_path("$dir/events.next") && safe_path($path);
    if (-f $path) {
        my @st=stat($path);
        if ("$st[0]:$st[1]" eq $r->{key}) {rename $path,$dest or die 'rotation archive recovery failed'}
    }
    die 'rotation archive missing' unless -f $dest;
    if (-f "$dir/events.next") {rename "$dir/events.next",$path or die 'rotation snapshot recovery failed'}
    die 'rotation snapshot missing' unless -f $path;
    my @next=stat($path); my $old=$r->{key}; $old =~ s/:/-/;
    atomic_file("$dir/archive/next-$old","$next[0]:$next[1]\n");
    atomic_file("$dir/month","$r->{month}\n"); unlink "$dir/rotation" or die 'rotation marker removal failed';
}
sub journal_rotate {
    my ($path)=@_; return unless safe_path($path);
    my $dir=$path; $dir =~ s{/[^/]+$}{};
    recover_rotation($path,$dir); return unless -s $path;
    my $now=strftime('%Y-%m',gmtime($ENV{LOOMY_NATIVE_NOW}//time));
    my $month='';
    if (safe_path("$dir/month") && -f "$dir/month") {sysopen my $m,"$dir/month",O_RDONLY|O_NOFOLLOW or die; $month=text(<$m>); $month =~ s/\s+$//}
    if ($month !~ /^\d{4}-\d{2}$/) {
        sysopen my $h,$path,O_RDONLY|O_NOFOLLOW or return; sysread($h,my $head,65536);
        my ($line)=split /\n/,$head; my $e=eval {decode_json($line//"")};
        $month=ref($e) eq 'HASH' ? substr(text($e->{ts}),0,7) : $now;
        $month=$now unless $month =~ /^\d{4}-\d{2}$/;
    }
    if ($month eq $now && -s $path<8388608) {atomic_file("$dir/month","$now\n") unless -f "$dir/month"; return}
    my $archive="$dir/archive"; die 'unsafe archive' unless safe_path($archive);
    mkdir $archive,0700 unless -d $archive; chmod 0700,$archive or die;
    my (%last,%open,%activity,%closed); my $reader=__PACKAGE__->new;
    while (1) {
        my @records=$reader->journal_records($path);
        for my $e (@records) {
            next unless valid_event($e); my $type=text($e->{type});
            my $sid=text($e->{session_key}) || join(':',text($e->{tool}//$e->{family}),text($e->{session}));
            my $key="$sid|".text($e->{id}); my $ts=epoch($e->{source_ts}//$e->{ts});
            if ($type eq 'bridge_link' || $type =~ /^session(?:_observed|_context|_activity)?$/) {
                my $k="$sid|$type"; $last{$k}=$e if !$last{$k} || $ts>=epoch($last{$k}{source_ts}//$last{$k}{ts});
            } elsif ($type eq 'delegation_start') {$open{$key}=$e unless $closed{$key}}
            elsif ($type eq 'delegation_activity') {$activity{$key}=$e if !$activity{$key} || $ts>=epoch($activity{$key}{source_ts}//$activity{$key}{ts})}
            elsif ($type eq 'delegation') {next if $open{$key} && $ts<epoch($open{$key}{source_ts}//$open{$key}{ts}); $closed{$key}=1; delete $open{$key}; delete $activity{$key}}
        }
        last if $reader->{cursor}{at_eof};
        die 'journal rotation stalled on partial record' unless $reader->{read_bytes};
    }
    my @keep=(values %last,values %open,map {$activity{$_}} grep {exists $activity{$_}} keys %open);
    $_->{snapshot}=JSON::PP::true for @keep;
    my $canonical=JSON::PP->new->canonical;
    my $snapshot=join('',map {$canonical->encode($_)."\n"}
        sort {epoch($a->{ts})<=>epoch($b->{ts}) || text($a->{type}) cmp text($b->{type}) || $canonical->encode($a) cmp $canonical->encode($b)} @keep);
    die 'journal active snapshot exceeds 8 MiB; rotation paused' if length($snapshot)>=8388608;
    my @st=stat($path); my $dest="$archive/events-$month-$st[0]-$st[1].jsonl";
    die 'unsafe archive segment' unless safe_path($dest) && !-e $dest;
    chmod 0600,$path or die;
    atomic_file("$dir/events.next",$snapshot);
    my $name=$dest; $name =~ s{.*/}{};
    atomic_file("$dir/rotation",encode_json({archive=>$name,month=>$now,key=>"$st[0]:$st[1]"}));
    recover_rotation($path,$dir);
}
sub journal_append {
    my ($path,$body,$ts)=@_; die 'journal record exceeds 64 KiB' if length($body)>65000;
    my $dir=$path; $dir =~ s{/[^/]+$}{};
    my $lock=journal_lock($dir,1) or return; journal_rotate($path);
    return unless safe_path($path);
    sysopen my $f,$path,O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or return;
    chmod 0600,$f or return;
    $ts=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime) unless epoch($ts);
    print $f '{"ts":'.encode_json($ts).",$body}\n" or die 'journal append failed'; $f->flush or die; $f->sync or die;
    close $f; journal_rotate($path) if -s $path>=8388608;
}
# After rotation replay the old inode's uncheckpointed suffix before the new snapshots.
sub recovery_path {
    my ($path,$cursor)=@_; my @st=stat($path); my $key=@st ? "$st[0]:$st[1]" : '';
    return $path if !($cursor->{key}//'') || $cursor->{key} eq $key;
    my $dir=$path; $dir =~ s{/[^/]+$}{/archive}; return $path unless safe_path($dir) && -d $dir;
    opendir my $h,$dir or return $path;
    my %archives;
    for my $name (readdir $h) {
        next unless $name =~ /^events-.*\.jsonl$/; my $p="$dir/$name";
        next unless safe_path($p) && -f $p; my @s=stat($p); $archives{"$s[0]:$s[1]"}=[$p,$s[7]];
    }
    my $target=$cursor->{key}; my %visited;
    while ($target ne $key && !$visited{$target}++) {
        my $old=$archives{$target} or last;
        return $old->[0] if ($cursor->{offset}//0)<$old->[1];
        my $name=$target; $name =~ s/:/-/; my $next="$dir/next-$name";
        last unless safe_path($next) && -f $next && -s $next<=128;
        sysopen my $f,$next,O_RDONLY|O_NOFOLLOW or last; my $value=text(<$f>); $value =~ s/\s+$//;
        last unless $value =~ /^\d+:\d+$/;
        $target=$value; $cursor->{key}=$target; $cursor->{offset}=0; delete $cursor->{read_sig}; delete $cursor->{skipping};
    }
    return $path;
}
sub migrate_checkpoints {
    my ($root)=@_; return if ($ENV{LOOMY_JOURNAL}//'1') eq '0';
    my $dir="$root/.loomy/logs"; return unless safe_path($dir) && -d $dir;
    return if -f "$dir/checkpoint-v2";
    my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+$}{};
    require "$lib/codex-native.pl"; require "$lib/claude-native.pl";
    for my $tool (qw(codex claude)) {
        my $idx="$dir/$tool-native.idx"; next unless -e $idx;
        die 'unsafe migration lock' unless safe_path("$idx.lock");
        sysopen my $lock,"$idx.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or die;
        flock($lock,LOCK_EX|LOCK_NB) or return;
        my $s=checkpoint_load($idx); next if ($s->{version}//0)==2;
        my $dirty=1;
        if ($tool eq 'codex') {Loomy::CodexNative::prune_checkpoint($s,$ENV{LOOMY_NATIVE_NOW}//time)}
        else {Loomy::ClaudeNative::prune($s,\$dirty)}
        checkpoint_save($idx,$s);
    }
    atomic_file("$dir/checkpoint-v2","2\n");
}
sub valid_event {
    my ($d)=@_; return 0 unless ref($d) eq 'HASH';
    my $ts=epoch($d->{source_ts}//$d->{ts}); my $now=$ENV{LOOMY_NATIVE_NOW}//time;
    return 0 unless $ts && $ts<=$now+300 && text($d->{type}) ne '';
    return 0 if grep {exists $d->{$_} && ref($d->{$_})} qw(type tool family session session_key agent_id parent_agent_id parent_delegation attempt_id parent_session id schema state status pid owner_pid ts source_ts);
    return 0 if text($d->{type}) =~ /^delegation(?:_start|_activity)?$/ && text($d->{id}) eq '';
    return 0 if text($d->{schema}) eq '2' && text($d->{type}) =~ /^delegation(?:_start|_activity)?$/
        && (text($d->{agent_id}) eq '' || text($d->{session_key}) eq '' || text($d->{tool}//$d->{family}) !~ /^(codex|claude)$/);
    return 0 if text($d->{type}) eq 'session' && text($d->{event}) !~ /^(start|end)$/;
    return 0 if text($d->{type}) eq 'session' && text($d->{session}) eq '' && text($d->{pid}) !~ /^[1-9][0-9]*$/;
    return 0 if text($d->{type}) eq 'delegation' && text($d->{status}) !~ /^(ok|error|interrupted|unknown|paused|blocked|unavailable)$/;
    return 1;
}
sub new { bless {sessions=>{},agents=>{},turns=>{},cursor=>{},sent=>{},native=>0},shift }
sub session {
    my ($self,$key)=@_;
    return $self->{sessions}{$key}//={key=>$key,tool=>($key =~ /^(codex|claude):/ ? $1 : 'unknown'),state=>'unknown',surface=>'unknown',seen=>0,pid=>0};
}
sub consume {
    my ($self,$d)=@_; return unless valid_event($d); my $type=text($d->{type}); my $ts=epoch($d->{source_ts}//$d->{ts});
    my $tool=text($d->{tool}//$d->{family});
    my $key=text($d->{session_key});
    $self->{native}=1 if $type ne 'bridge_link' && text($d->{schema}) eq '2' && $tool =~ /^(codex|claude)$/ && text($d->{source}) ne 'hook';
    # Claude hooks are projected by the adapter using the same scoped keys as transcripts.
    return if text($d->{bridge}) eq 'subagent' && text($d->{schema}) ne '2';
    if ($type eq 'bridge_link') {
        return unless $tool =~ /^(codex|claude)$/ && $key eq "$tool:".text($d->{session})
            && text($d->{session}) =~ /^[A-Za-z0-9_.:-]{1,100}$/ && text($d->{parent_delegation}) ne '';
        my $prior=$self->{links}{$key};
        return if $prior && $ts<($prior->{seen}//0);
        $self->{links}{$key}={bridge=>text($d->{parent_delegation}),attempt=>text($d->{attempt_id}),
            parent=>text($d->{parent_session}),seen=>$ts};
        return;
    }
    if ($type eq 'session') {
        return unless $tool =~ /^(codex|claude)$/;
        $key="$tool:".(text($d->{session}) || 'pid'.text($d->{pid}));
        my $s=$self->session($key);
        return if $ts<($s->{hook_seen}//0) || (text($d->{event}) eq 'start' && $ts<=($s->{closed_at}//0));
        $s->{hook_seen}=$ts;
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
    return if $type eq 'delegation_activity' && !$self->{turns}{text($d->{id})};
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
        return if $ts<($s->{state_seen}//0); $s->{state_seen}=$ts;
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
    return if $type ne 'agent_alias' && $self->{turns}{$id} && $self->{turns}{$id}{agent} ne $ak;
    if ($type eq 'agent_alias') {
        my $old="$tool:".text($d->{alias_from}); my $old_id=text($d->{alias_id});
        my $a=delete $self->{agents}{$old}; my $t=delete $self->{turns}{$old_id};
        if ($a && !$self->{agents}{$ak}) { $a->{key}=$ak; $a->{latest}=$id; $self->{agents}{$ak}=$a }
        if ($t && !$self->{turns}{$id}) { $t->{key}=$id; $t->{agent}=$ak; $self->{turns}{$id}=$t }
        push @{$self->{deleted}},wire('N','X',$old),wire('N','Y',$old_id);
        delete $self->{sent}{"A:$old"}; delete $self->{sent}{"T:$old_id"}; return;
    }
    my $a=$self->{agents}{$ak}//={key=>$ak,session=>$key,parent=>text($d->{parent_agent_id}),state=>'unknown',latest=>'',seen=>0};
    my $prior_session=$a->{session};
    $a->{schema}=2 if text($d->{schema}) eq "2";
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
    my $turn=$self->{turns}{$id}//={key=>$id,agent=>$ak,session=>$key,state=>'unknown',outcome=>'unknown',started=>0,seen=>0,seq=>++$self->{seq}};
    if ($type eq 'delegation_start') {
        if ($turn->{ended}) {$turn->{started}=$ts if !$turn->{started} && $ts<=$turn->{ended}; return}
        $turn->{started}=$ts if !$turn->{started} || $ts<$turn->{started};
        delete @$turn{qw(ended duration status)} if $turn->{ended} && $turn->{ended}<$ts;
        $turn->{state}='running' unless $turn->{ended};
        $a->{closed}=0 if $fresh && text($d->{bridge}) eq 'codex-native' && $ts>($a->{closed_at}//0);
    }
    elsif ($type eq 'delegation_activity') {
        return if $ts<$turn->{seen};
        delete @$turn{qw(ended duration status)} if $tool eq 'claude' && ($turn->{status}//'') eq 'interrupted'
            && $ts>($turn->{ended}//0) && text($d->{state}) eq 'running';
        $turn->{state}=text($d->{state}//$d->{activity}) || 'unknown' unless $turn->{ended} || $ts<$turn->{seen};
        $a->{source_mtime}=text($d->{source_mtime}) if $tool eq 'claude' && text($d->{source_mtime}) =~ /^\d+(?:\.\d+)?$/;
    } elsif ($type eq 'delegation') {
        return if ($turn->{started} && $ts<$turn->{started}) || ($turn->{ended} && $ts<$turn->{ended});
        $turn->{ended}=$ts; $turn->{state}=text($d->{status}) eq 'ok' ? 'done' : text($d->{status}) eq 'error' ? 'failed' : text($d->{status}) || 'unknown';
        $turn->{outcome}=text($d->{outcome}) || 'unknown';
        $turn->{status}=text($d->{status}); $turn->{duration}=defined $d->{duration_s} && !ref($d->{duration_s}) ? text($d->{duration_s}) : '—';
    }
    $turn->{$_}=text($d->{$_}) for grep { defined $d->{$_} && !ref($d->{$_}) } qw(model effort task role);
    $turn->{attempt}=text($d->{attempt_id}) if text($d->{attempt_id}) ne '';
    $turn->{seen}=$ts if $ts>$turn->{seen};
    $a->{latest}=$id if $a->{latest} eq '' || ($fresh && $type eq 'delegation_start' && $ts>=(($self->{turns}{$a->{latest}}//{})->{started}//0));
    if ($a->{latest} eq $id) {
        $a->{$_}=$turn->{$_} for qw(model effort task role);
        $a->{state}=$a->{closed} ? 'done' : $turn->{ended} ? (text($d->{bridge}) eq 'codex-native' ? 'idle' : $turn->{state}) : $turn->{state};
    }
    $a->{seen}=$ts if $ts>$a->{seen};
}

# Seek before decoding; malformed complete lines advance, partial appends retry, oversized lines skip.
sub journal_records {
    my ($self,$path)=@_; $self->{read_bytes}=0;
    my @probe=Time::HiRes::stat($path);
    my $sig=@probe ? join(':',$path,@probe[0,1,7,9]) : '';
    return () if $sig ne '' && ($self->{read_sig}//'') eq $sig;
    return unless safe_path($path) && -f $path;
    sysopen my $f,$path,O_RDONLY|O_NOFOLLOW or return;
    my @st=stat($f); my $key="$st[0]:$st[1]"; my $c=$self->{cursor};
    if (($c->{key}//'') ne $key || ($c->{offset}//0)>$st[7]) {
        $c->{offset}=0; delete $c->{skipping};
        # Retain identities through rotation; snapshots are not new work.
    }
    $c->{key}=$key; $c->{at_eof}=0; my $off=$c->{offset}//0; seek $f,$off,0 or return;
    my $n=sysread($f,my $buf,2097152); $self->{read_bytes}=$n//0;
    $c->{at_eof}=1 if defined $n && $off+$n >= $st[7];
    $self->{read_sig}=$sig if $c->{at_eof};
    return unless $n;
    my $skip=0;
    if ($c->{skipping}) { my $i=index($buf,"\n"); if ($i<0) { $c->{offset}=$off+$n; return } $skip=$i+1; delete $c->{skipping} }
    my $end=rindex($buf,"\n");
    if ($end<0) { if ($n==2097152) { $c->{offset}=$off+$n; $c->{skipping}=1 } return }
    $c->{offset}=$off+$end+1;
    my @out;
    for my $line (split /\n/,substr($buf,$skip,$end-$skip+1)) {
        next if length($line)>65536;
        my $d=eval {decode_json($line)}; push @out,$d if ref($d) eq 'HASH';
    }
    return @out;
}

sub read_journal {
    my ($self,$path)=@_; $self->consume($_) for $self->journal_records($path);
    $self->prune_projection;
}
# Recap detail is bounded; retain every unfinished turn and its session.
sub prune_projection {
    my ($self)=@_; my $now=$ENV{LOOMY_NATIVE_NOW}//time;
    my @ended=sort {($self->{turns}{$b}{ended}//0)<=>($self->{turns}{$a}{ended}//0) || ($self->{turns}{$b}{seq}//0)<=>($self->{turns}{$a}{seq}//0)} grep {$self->{turns}{$_}{ended}} keys %{$self->{turns}};
    my %counts;
    for my $i (0..$#ended) {
        my $id=$ended[$i]; my $t=$self->{turns}{$id}; my $n=++$counts{$t->{agent}};
        next if $i<1000 && $n<=32 && $now-$t->{ended}<=604800;
        delete $self->{turns}{$id}; delete $self->{sent}{"T:$id"};
        push @{$self->{deleted}},wire('N','Y',$id) if $self->{sent}{native};
    }
    my %agents=map {$_->{agent}=>1} values %{$self->{turns}};
    for my $key (keys %{$self->{agents}}) {
        next if $agents{$key}; delete $self->{agents}{$key}; delete $self->{sent}{"A:$key"};
        push @{$self->{deleted}},wire('N','X',$key) if $self->{sent}{native};
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
sub claude_evidence {
    my ($self,$native)=@_; return unless ref($native) eq 'HASH';
    for my $lead (values %{$native->{sessions}//{}}) {
        my $s=$self->{sessions}{"claude:$lead->{id}"} or next;
        my $ts=epoch($lead->{seen});
        if ($s->{closed} && $ts>($s->{closed_at}//0)) { $s->{closed}=0; $s->{pid}=0 }
        $s->{seen}=$ts if $ts>$s->{seen};
        for my $c (values %{$lead->{calls}//{}}) {
            my $a=$self->{agents}{"claude:$lead->{id}:$c->{call}"} or next;
            my $own=epoch($c->{seen}//$c->{started});
            $a->{seen}=$own if $own>$a->{seen};
            $a->{source_mtime}=$c->{source_mtime}//0;
        }
    }
}
sub wire {
    my @row=@_; for (@row) { $_=text($_); s/[\x00-\x1f\x7f|]/ /g } return join('|',@row);
}
# Recompute explicit ownership at projection time: links can arrive after native starts.
sub bridge_owner {
    my ($self,$key,$visited)=@_; return unless !$visited->{$key}++;
    my $link=$self->{links}{$key} or return;
    my $t=$self->{turns}{$link->{bridge}} or return;
    return if $link->{attempt} ne '' && ($t->{attempt}//'') ne '' && $link->{attempt} ne $t->{attempt};
    my $a=$self->{agents}{$t->{agent}} or return;
    my $up=$self->bridge_owner($a->{session},$visited);
    return {group=>$up ? $up->{group} : $a->{session},bridge=>$a->{key},parent=>$link->{parent}};
}
sub projections {
    my ($self,$now)=@_; my @out=@{delete $self->{deleted}//[]};
    if ($self->{native} && !$self->{sent}{native}) { push @out,'N|native|1'; $self->{sent}{native}=1 }
    for my $key (keys %{$self->{sent}}) {
        next unless $key =~ /^G:(.*)$/; my $sid=$1;
        unless ($self->{sessions}{$sid}) { push @out,wire('N','D',$sid); delete $self->{sent}{$key} }
    }
    my %owned;
    for my $key (keys %{$self->{links}//{}}) {
        my $owner=$self->bridge_owner($key,{}) or next; $owned{$key}=$owner;
        if (delete $self->{sent}{"G:$key"}) {push @out,wire('N','D',$key)}
    }
    for my $key (sort keys %{$self->{sessions}}) {
        next if $owned{$key};
        my $s=$self->{sessions}{$key}; my $pid=$s->{pid}//0;
        my $alive=$pid =~ /^\d+$/ && $pid>1 && (kill(0,$pid) || $! == EPERM);
        my $live=!$s->{unassigned} && !$s->{closed} && ($alive || ($s->{seen}>0 && $now-$s->{seen}<=120));
        my $row=wire('N','G',$key,$s->{tool},$s->{surface},$s->{cwd_relative},$live ? 'live' : 'stale',
            $s->{state},$s->{model},$s->{effort},int($s->{seen}),$alive ? 'launcher' : 'source lease',$s->{context_freshness});
        push @out,$row if ($self->{sent}{"G:$key"}//'') ne $row; $self->{sent}{"G:$key"}=$row;
    }
    my %turn_counts; ++$turn_counts{$_->{agent}} for values %{$self->{turns}};
    for my $key (sort keys %{$self->{agents}}) {
        my $a=$self->{agents}{$key}; my $t=$self->{turns}{$a->{latest}}//{};
        my $agent_state=$a->{state};
        my $session=$self->{sessions}{$a->{session}}//{};
        my $pid=$session->{pid}//0;
        my $dead=$pid =~ /^\d+$/ && $pid>1 && !(kill(0,$pid) || $! == EPERM);
        my $live=!$session->{unassigned} && !$session->{closed} && (!$dead && $pid>1 || ($session->{seen} && $now-$session->{seen}<=120));
        my $interrupted=($a->{schema}//0)==2 && !$t->{ended} && (!$live || $dead);
        my $expired=0;
        if (($a->{schema}//0)==2 && $a->{session}=~/^claude:/ && !$t->{ended} && !$session->{closed} && !$dead) {
            my $own=$a->{seen}//0; $own=$a->{source_mtime} if ($a->{source_mtime}//0)>$own;
            $interrupted=0; $expired=!$own || $now-$own>900;
            $agent_state='unknown' if $expired;
        }
        $agent_state='interrupted' if $interrupted;
        # Completed agents close with an observed owner; absent PIDs remain source-owned.
        $agent_state='done' if $t->{ended} && (($session->{closed}//0) || $dead);
        my $turns=$turn_counts{$key}//0;
        my $owner=$owned{$key}//$owned{$a->{session}};
        my $group=$owner ? $owner->{group} : $a->{session};
        my $parent=$a->{parent};
        if ($owner) {
            my $explicit=$owner->{parent} ne '' ? ($key =~ /^(.*?):/ ? "$1:$owner->{parent}" : '') : '';
            $parent=$explicit ne '' && $self->{agents}{$explicit} ? $explicit
                : $self->{agents}{$parent} ? $parent : $owner->{bridge};
        }
        my $row=wire('N','A',$key,$group,$parent,$agent_state,$a->{role},$a->{task},$a->{model},$a->{effort},
            int($t->{started}//0),($t->{ended} ? int($t->{ended}) : ''),$t->{duration},$t->{outcome},$a->{latest},int($a->{seen}),$interrupted ? 'interrupted' : $expired ? 'unknown' : $t->{state},$turns);
        push @out,$row if ($self->{sent}{"A:$key"}//'') ne $row; $self->{sent}{"A:$key"}=$row;
    }
    for my $key (sort keys %{$self->{turns}}) {
        my $t=$self->{turns}{$key}; next unless $t->{ended};
        my $owner=$owned{$t->{agent}}//$owned{$t->{session}};
        my $row=wire('N','T',$key,$owner ? $owner->{group} : $t->{session},$t->{agent},$t->{state},$t->{outcome},int($t->{started}//0),int($t->{ended}),$t->{duration},$t->{model},$t->{role});
        push @out,$row if ($self->{sent}{"T:$key"}//'') ne $row; $self->{sent}{"T:$key"}=$row;
    }
    return @out;
}
unless (caller) {
    if (($ARGV[0]//'') eq '--migrate') {migrate_checkpoints($ARGV[1]); exit 0}
    my ($root,$sessions)=@ARGV; $root=abs_path($root)//exit 1;
    my $dir=abs_path(__FILE__); $dir =~ s{/[^/]+$}{};
    require "$dir/codex-native.pl";
    require "$dir/claude-native.pl";
    my $native=Loomy::CodexNative::poll($root,$sessions);
    my $claude=Loomy::ClaudeNative::poll($root,($ENV{CLAUDE_CONFIG_DIR}//"$ENV{HOME}/.claude").'/projects');
    my $state=__PACKAGE__->new; $state->read_journal("$root/.loomy/logs/events.jsonl"); $state->source_evidence($native);
    $state->claude_evidence($claude);
    print "$_\n" for $state->projections($ENV{LOOMY_NATIVE_NOW}//time);
}
1;

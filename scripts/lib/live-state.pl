# Shared, content-free live projection. The sampler owns this reducer; one-shot views use it once.
package Loomy::LiveState;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Time::Local qw(timegm);
use Fcntl qw(O_RDONLY O_RDWR O_WRONLY O_CREAT O_EXCL O_APPEND O_NOFOLLOW O_NONBLOCK LOCK_EX LOCK_NB);
use Errno qw(EPERM);
use Cwd qw(abs_path);
use Time::HiRes ();
use IO::Handle;
use POSIX qw(strftime);
use Scalar::Util qw(blessed refaddr weaken);
# Direct CLI migration can load an adapter which requires this same module.
$INC{abs_path(__FILE__)}=1;
my $content_lib=abs_path(__FILE__); $content_lib =~ s{/[^/]+$}{/content-policy.pl};
require $content_lib;
my $journal_json=JSON::PP->new->utf8->canonical;
my ($gate_lib,$gate_loaded)=(abs_path(__FILE__),0);

# Locks protect only a policy snapshot or a label append, never source polling
# or waiting for events.lock. A short retry absorbs normal concurrent hooks.
sub content_writer {
    my ($root)=@_;
    my $c=eval {Loomy::ContentPolicy::_context($root,1)}; return unless $c;
    return Loomy::ContentPolicy::_in_context($c,sub {
        my $lock=eval {Loomy::ContentPolicy::_lock($c,'content-policy.lock',10)};
        my $p=Loomy::ContentPolicy::_effective($c,Loomy::ContentPolicy::_stored($c));
        $p={%$p,journal_content=>'structural',label_sources=>'none',private_results=>'off'} unless $lock;
        content_lock_miss($c) unless $lock;
        return {policy=>$p,context=>$c};
    });
}
sub content_lock_miss {
    my ($c,$key)=@_; $key//='policy_lock_misses';
    eval {Loomy::ContentPolicy::_in_context($c,sub {
        my $lock=Loomy::ContentPolicy::_lock($c,'content-health.lock',10);
        my ($raw,$before)=Loomy::ContentPolicy::_read('content-health.json',1024);
        my $health=eval {decode_json($raw//'{}')}; $health={} unless ref($health) eq 'HASH';
        my %counts;
        for my $name (qw(policy_lock_misses label_lock_misses)) {
            my $n=$health->{$name}//0; $counts{$name}="$n" =~ /^\d{1,15}$/ ? 0+$n : 0;
        }
        ++$counts{$key};
        Loomy::ContentPolicy::_atomic($c,'content-health.json',encode_json(\%counts)."\n",$before);
    })};
    warn $key eq 'label_lock_misses' ? "display context lock busy; structural event retained\n"
        : "content policy lock busy; structural event retained\n";
}
sub content_root {
    my $path=$_[0]; $path =~ s{/\.loomy/logs/events\.jsonl$}{}; return $path;
}
sub content_label {
    my ($w,$kind,$target,$attempt,$source,$text)=@_; return unless $w;
    return unless grep {$_ eq $source} split /,/,$w->{policy}{label_sources};
    my $previous;
    my $ref=eval {Loomy::ContentPolicy::_in_context($w->{context},sub {
        my $labels=eval {Loomy::ContentPolicy::_lock($w->{context},'display-context.lock',10)};
        unless ($labels) {content_lock_miss($w->{context},'label_lock_misses'); return}
        my $lock=eval {Loomy::ContentPolicy::_lock($w->{context},'content-policy.lock',10)};
        unless ($lock) {content_lock_miss($w->{context}); return}
        my $p=Loomy::ContentPolicy::_effective($w->{context},Loomy::ContentPolicy::_stored($w->{context}));
        undef $lock; # Store I/O never holds up a policy snapshot in another hook.
        return unless grep {$_ eq $source} split /,/,$p->{label_sources};
        my $last=Loomy::ContentPolicy::latest_label($w->{context},$kind,$target,$attempt,$source);
        $previous=Loomy::ContentPolicy::label_ref($last) if $last;
        return Loomy::ContentPolicy::label_ref($last) if $last && !defined($text);
        return unless defined($text) && !ref($text) && length($text);
        my $clean=$source =~ /^codex-/ ? $text : Loomy::ContentPolicy::sanitize_label($text,
            $p->{label_max_graphemes},$p->{label_max_bytes});
        return Loomy::ContentPolicy::label_ref($last) if $last && $last->{text} eq $clean;
        my $input={project_id=>$w->{policy}{project_id},target_kind=>$kind,target_id=>$target,
            attempt_id=>$attempt,source=>$source,text=>$text};
        return Loomy::ContentPolicy::_save_label($w->{context},$p,$input,$last);
    })};
    warn "display context full; label not saved\n" if $@ eq "display context full; label not saved\n";
    return $ref//$previous;
}
sub content_input {
    my ($event)=@_; my %input=%$event;
    # Existing constructors use empty optional IDs/models/times for unknown.
    # Preserve that meaning as null, rather than inventing an identity or zero.
    for my $key (qw(id agent agent_id alias_from alias_id attempt_id session session_key turn_id parent_id
        parent_delegation parent_session parent_agent_id model requested_model resume_at)) {
        $input{$key}=undef if exists($input{$key}) && defined($input{$key}) && !ref($input{$key}) && $input{$key} eq '';
    }
    # Bridge traps emit INT/TERM/HUP and the non-signal EXIT sentinel. T1's
    # signal domain is numeric; retain the real signal number, null for EXIT.
    if (exists($input{signal}) && defined($input{signal}) && !ref($input{signal})) {
        my %signals=(INT=>POSIX::SIGINT(),TERM=>POSIX::SIGTERM(),HUP=>POSIX::SIGHUP(),EXIT=>undef);
        $input{signal}=$signals{$input{signal}} if exists $signals{$input{signal}};
    }
    return \%input;
}
sub content_signature {
    my ($w,$type,$value)=@_;
    my $body=ref($value) eq 'HASH' ? $value : eval {decode_fast($value)};
    $value=content_input($body) if ref($body) eq 'HASH';
    return Loomy::ContentPolicy::_signature($type,$value,$w->{policy}{project_id});
}
sub project_journal_event {
    my ($w,$event)=@_; my $input=content_input($event);
    $input->{checkpoint_value}=content_signature($w,$input->{type},$input->{checkpoint_value}) if exists $input->{checkpoint_value};
    return Loomy::ContentPolicy::project_with_policy($w->{policy},$input);
}
sub journal_line {
    my ($e)=@_; my %body=%$e; my ($ts,$type)=delete @body{qw(ts type)};
    # Some shell readers require these compact literal pairs; canonical JSON
    # also avoids accidental spaces, regardless of the available XS encoder.
    # Plain identifier-like text cannot be a number and needs no escaping: quote it directly.
    my $scalar=sub {
        my $v=$_[0];
        return qq("$v") if defined $v && !ref($v) && ($v =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?Z\z/
            || $v =~ /\A[A-Za-z][A-Za-z0-9_.:-]*\z/ && $v !~ /\A(?:inf(?:inity)?|nan)\z/i);
        return substr($journal_json->encode([$v]),1,-1);
    };
    my $prefix='{"ts":'.$scalar->($ts).',"type":'.$scalar->($type);
    $prefix.=',"id":'.$scalar->(delete $body{id}) if exists $body{id};
    return $prefix.(keys(%body) ? ','.substr($journal_json->encode(\%body),1) : '}')."\n";
}
# Contain each event at every append boundary; diagnostics never include content.
sub journal_event_line {
    my ($w,$e)=@_; my $line=eval {journal_line(project_journal_event($w,$e))};
    if (!defined($line) || length($line)>65536) {warn "journal event skipped; invalid record\n"; return}
    return $line;
}

sub text { defined $_[0] && !ref($_[0]) ? "$_[0]" : '' }
# Pure in the text; the same stamps recur on every journal line and projection.
my (%epoch_memo,$epoch_memo_size);
sub epoch {
    my $stamp=text($_[0]); my $hit=$epoch_memo{$stamp}; return $hit if defined $hit;
    my @t=$stamp =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$/;
    my $value=@t ? (eval { timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0]) } // 0)+($t[6]//0) : 0;
    if ($epoch_memo_size++>=4096) {%epoch_memo=(); $epoch_memo_size=1}
    return $epoch_memo{$stamp}=$value;
}
sub safe_path {
    my $p=$_[0]; return 0 unless defined $p && $p =~ m{^/};
    while ($p ne '') { return 0 if -l $p; $p =~ s{/[^/]*$}{} } return 1;
}

# LOCK L1 storage boundary. Collector-origin mutators take a trailing options hash
# {owner=>$guard, context=>$ctx} (guard from Loomy::CollectorOwner, elected by L3;
# this module never elects). Hook-origin appends and rotation pass no options and keep
# their independent events lock. require_owner(1) makes the checkpoint mutators refuse a
# call without options; L3 enables it once every collector call site passes a guard.
our $REQUIRE_OWNER=0;
sub require_owner { $REQUIRE_OWNER=$_[0] ? 1 : 0 }
sub _owner_lib {
    my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+$}{/collector-owner.pl};
    require $lib; return 1;
}
# Returns the validated guard, or undef for a legacy/hook-origin call without options.
sub _owner_of {
    my ($opts,$legacy_ok)=@_;
    unless (defined $opts) {die "collector owner INVALID_GUARD\n" if $REQUIRE_OWNER && !$legacy_ok; return}
    die "collector owner INVALID_GUARD\n" unless ref($opts) eq 'HASH' && blessed($opts->{owner});
    _owner_lib();
    die "collector owner INVALID_GUARD\n" unless $opts->{owner}->isa('Loomy::CollectorOwner::Guard');
    return $opts->{owner};
}
# Every file this module mutates lives in the logs directory the target context pins.
sub _in_context {
    my ($path,$ctx)=@_;
    return 0 unless ref($ctx) eq 'HASH' && ref($ctx->{ds}) eq 'ARRAY';
    my $dir=$path; $dir =~ s{/[^/]+$}{}; my @s=stat($dir);
    return @s && $s[0]==$ctx->{ds}[0] && $s[1]==$ctx->{ds}[1];
}
# kind: batch (before a batch; refused after begin_drain), write (storage boundary; allowed
# while draining), event (cheap per-event check between boundaries; no directory re-pin).
sub owner_check {
    my ($opts,$kind,$path)=@_; my $guard=_owner_of($opts,0);
    return Loomy::CollectorOwner::assert_owner_quick($guard,'write') if ($kind//'') eq 'event';
    die "collector owner INVALID_PHASE\n" unless ($kind//'') =~ /^(?:batch|write)$/;
    Loomy::CollectorOwner::assert_owner($guard,$kind,$opts->{context});
    die "collector owner WRONG_RUNTIME\n" if defined($path) && !_in_context($path,$opts->{context});
    return 1;
}
# Mutator gate: validates the guard before any storage is touched.
sub _fence {
    my ($opts,$path,$legacy_ok)=@_; my $guard=_owner_of($opts,$legacy_ok); return unless $guard;
    return owner_check($opts,'write',$path);
}
# Batch cadence: checkpoint_load runs the full fence and remembers it for that guard and
# context object; a checkpoint_save in the same poll (within 5 s) then needs only the quick
# check plus the same-objects test. Missing, stale or mismatched marker, or a failing quick
# check, falls back to the full fence. Destructive steps and migrate always run the full one.
my %batch;
sub _fence_load {
    my ($opts,$path)=@_; my $guard=_owner_of($opts,0); return unless $guard;
    delete $batch{refaddr($guard)};
    owner_check($opts,'write',$path);
    my $m=$batch{refaddr($guard)}={guard=>$guard,context=>$opts->{context},at=>Time::HiRes::time()};
    weaken($m->{guard}); weaken($m->{context});
    return 1;
}
sub _fence_save {
    my ($opts,$path)=@_; my $guard=_owner_of($opts,0); return unless $guard;
    my $m=delete $batch{refaddr($guard)};
    if (!$opts->{full} && $m && ref($m->{guard}) && $m->{guard}==$guard && ref($m->{context}) && ref($opts->{context})
        && $m->{context}==$opts->{context} && Time::HiRes::time()-$m->{at}<=5
        && _in_context($path,$opts->{context}) && eval {Loomy::CollectorOwner::assert_owner_quick($guard,'write'); 1}) {return 1}
    return owner_check($opts,'write',$path);
}
# Flush and sync appended journal bytes before the matching durable watermark is saved.
sub _flush_handles {
    my ($opts)=@_; return unless ref($opts) eq 'HASH';
    for my $h (@{ref($opts->{flush}) eq 'ARRAY' ? $opts->{flush} : []}) {
        die "journal flush failed\n" unless defined($h) && defined(fileno($h)) && $h->flush && $h->sync;
    }
}
# One stable lock protects rotation and every writer, including native collectors.
sub journal_gate {   # leak barrier (journal-gate.pl): may this logs directory be written? Cached verdict, fail closed.
    my $dir=shift; $gate_lib =~ s{/[^/]+$}{/journal-gate.pl} unless $gate_loaded++;
    require $gate_lib; return Loomy::JournalGate::check($dir);
}
# The blocking callers are the hook writers (journal_append, agent start/finish, rotation): they pass the barrier here,
# before events.lock exists. Non-blocking callers are the elected collectors, which passed it at election.
sub journal_lock {
    my ($dir,$blocking)=@_; return unless safe_path("$dir/events.lock");
    return if $blocking && !journal_gate($dir);
    sysopen my $f,"$dir/events.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return;
    chmod 0600,$f or return; flock($f,LOCK_EX|($blocking ? 0 : LOCK_NB)) or return; return $f;
}
sub file_signature {
    my @s=Time::HiRes::stat($_[0]); return @s ? join(':',@s[0,1,7,9]) : '-';
}
{
    my $json;
    sub checkpoint_json {
        # Use XS when available; PP remains the dependency-free fallback.
        $json//=eval {require JSON::XS; JSON::XS->new->utf8->canonical->boolean_values(JSON::PP::false,JSON::PP::true)}
            // JSON::PP->new->utf8->canonical;
        return $json;
    }
}
# Pure classification of one parsed container: undef when supported, else a peek reason.
# A future version or an unknown shard kind is an unsupported format, never corruption.
sub _checkpoint_kind {
    my ($s)=@_;
    return 'invalid' unless ref($s) eq 'HASH';
    return 'unsupported-version' if exists $s->{version} && text($s->{version}) !~ /^(1|2)$/;
    if (exists $s->{source_shards}) {
        return 'invalid' unless ref($s->{source_shards}) eq 'ARRAY' && @{$s->{source_shards}}<=64;
        my $bad=0;
        for my $name (@{$s->{source_shards}}) {
            my $n=text($name); next if $n =~ /^files-[0-9a-f]{64}$/;
            return 'unsupported-extension' if $n =~ /^[a-z][a-z0-9]*-[0-9a-f]{64}$/;
            $bad=1; # keep scanning: an unknown shard kind anywhere outranks malformed names
        }
        return 'invalid' if $bad;
    }
    return 'invalid' if grep {exists $s->{$_} && ref($s->{$_}) ne 'HASH'} qw(files seen sent journal sessions owners);
    return;
}
# Read-only: never chmod, rename, prune or create. Returns (kind,state) with kind one of
# valid missing invalid unsafe unsupported-version unsupported-extension changed io-error.
sub _read_chunk {my $n=sysread($_[0],my $b,262144); return ($n,$b)}
# Bytes whose decode already classified as supported (or unsupported) in this process: a
# later kind-only check or save of the identical bytes skips the decode. Sharded manifests
# are never memoised because their validity also depends on the shard files. An entry is
# the stat signature plus the SHA-256 of the bytes, never the bytes; at most 64 entries.
my %KIND_MEMO; my $KIND_MEMO_SIZE=0;
sub _memo_tag {require Digest::SHA; return "$_[0]|".Digest::SHA::sha256_hex($_[1])}
sub _memo_set {
    my ($path,$tag,$kind)=@_;
    if (!exists $KIND_MEMO{$path} && $KIND_MEMO_SIZE>=64) {%KIND_MEMO=(); $KIND_MEMO_SIZE=0}
    $KIND_MEMO_SIZE++ unless exists $KIND_MEMO{$path};
    $KIND_MEMO{$path}=[$tag,$kind];
}
# A v2 manifest is at most 2 MiB (the writer's cap); the bound here is that plus a small slack, so a
# crafted manifest costs a stat, not hundreds of MB per follower peek. Only a legacy v1 index being
# migrated may be larger (up to 32 MiB): its callers pass the legacy bound explicitly.
our $V2_READ_LIMIT=2097152+65536; our $LEGACY_READ_LIMIT=33554432;
# The legacy bound applies only while a store still holds (or is being migrated from) v1 indexes: an explicit migration
# call, or no checkpoint-v2 marker yet (the owner's in-poll upgrade). Followers and peeks never use it.
sub _read_limit {
    my ($opts,$path)=@_; return $LEGACY_READ_LIMIT if ref($opts) eq 'HASH' && $opts->{legacy};
    my $dir=$path; $dir =~ s{/[^/]+$}{}; return -e "$dir/checkpoint-v2" ? $V2_READ_LIMIT : $LEGACY_READ_LIMIT;
}
sub _checkpoint_read {
    my ($candidate,$kind_only,$limit)=@_; $limit//=$V2_READ_LIMIT;
    my @l=lstat($candidate); return ($!{ENOENT}||$!{ENOTDIR} ? 'missing' : 'io-error') unless @l;
    return 'unsafe' unless -f _ && safe_path($candidate);
    return 'invalid' if !$l[7] || $l[7]>$limit;
    sysopen my $f,$candidate,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or return 'io-error';
    my @a=stat($f); return 'io-error' unless @a;
    # The handle, not the earlier lstat, is authoritative: a swapped FIFO/other file is unsafe.
    return 'unsafe' unless -f $f && $a[4]==$< && $a[0]==$l[0] && $a[1]==$l[1];
    my $raw=''; while (1) {my ($n,$b)=_read_chunk($f); return 'io-error' unless defined $n; last unless $n; $raw.=$b; last if length($raw)>$limit}
    my @z=stat($f);
    return 'changed' unless @z && length($raw)==$a[7] && $a[7]==$z[7] && $a[9]==$z[9];
    my $tag=_memo_tag("$a[0]:$a[1]:$a[7]:$a[9]",$raw); my $memo=$KIND_MEMO{$candidate};
    return $memo->[1] if $kind_only && $memo && $memo->[0] eq $tag;
    my $s=eval {checkpoint_decode($raw)};
    return 'invalid' unless ref($s) eq 'HASH';
    my $kind=_checkpoint_kind($s);
    _memo_set($candidate,$tag,$kind//'valid') unless exists $s->{source_shards};
    return $kind if defined $kind;
    if (exists $s->{source_shards}) {
        my $path=$candidate; $path =~ s{\.bak$}{} if $candidate =~ /\.bak$/;
        # Shards are named from the primary path; the backup refers to the same shard family.
        my $ok=eval {load_shards($path,$s); 1}; return 'invalid' unless $ok;
    }
    return ('valid',$s);
}
# A future-format backup is never replaced or ignored by a mutator: bounded read, then refuse.
sub _backup_refusal {
    my ($path)=@_; my ($k)=_checkpoint_read("$path.bak",1);
    return $k =~ /^unsupported-/ ? $k : undef;
}
# Pure bounded reader for followers. Never acquires ownership, repairs, chmods, prunes,
# quarantines or creates. status: valid (supported primary), stale (supported backup or
# the caller's last valid snapshot), unsupported (unknown format somewhere: the whole
# manifest is untouched; a supported backup may still be shown as stale), unavailable.
sub checkpoint_peek {
    my ($path,$last)=@_;
    my $r=eval {_checkpoint_peek($path,$last)};
    return $r // {status=>'unavailable',checkpoint=>undef,reason=>'io-error'};
}
sub _checkpoint_peek {
    my ($path,$last)=@_;
    my ($pk,$p)=_checkpoint_read($path);
    ($pk,$p)=_checkpoint_read($path) if $pk eq 'changed';
    my ($bk,$b)=_checkpoint_read("$path.bak");
    ($bk,$b)=_checkpoint_read("$path.bak") if $bk eq 'changed';
    # The valid primary stays the authority; the backup's kind is exposed so L3 can explain a refusal.
    return {status=>'valid',checkpoint=>$p,reason=>'primary',backup_kind=>$bk} if $pk eq 'valid';
    $last=undef unless ref($last) eq 'HASH';
    my $stale=$bk eq 'valid' ? $b : undef;
    return {status=>'unsupported',checkpoint=>$stale//$last,reason=>$pk,backup_kind=>$bk} if $pk =~ /^unsupported-/;
    return {status=>'unsupported',checkpoint=>$last,reason=>$bk,backup_kind=>$bk} if $bk =~ /^unsupported-/;
    return {status=>'stale',checkpoint=>$b,reason=>'backup',backup_kind=>$bk} if $bk eq 'valid';
    return {status=>'stale',checkpoint=>$last,reason=>'last-valid',backup_kind=>$bk} if $last;
    my ($worst)=grep {$_ ne 'missing'} ($pk,$bk);
    return {status=>'unavailable',checkpoint=>undef,reason=>$worst//'missing',backup_kind=>$bk};
}
# Bounded current-source evidence for a followed checkpoint: refreshes in memory only the
# source mtime of up to $limit recently active sources, so silent agents keep their lease
# without journal heartbeats. Paths are validated as real absolute same-UID regular files.
sub stat_evidence {
    my ($tool,$cp,$limit)=@_; return 0 unless ref($cp) eq 'HASH' && ref($cp->{files}) eq 'HASH';
    $limit//=256; my $now=$ENV{LOOMY_NATIVE_NOW}//time; my $done=0;
    my @paths=sort {($cp->{files}{$b}{source_mtime}//0)<=>($cp->{files}{$a}{source_mtime}//0) || $a cmp $b}
        grep {ref($cp->{files}{$_}) eq 'HASH'} keys %{$cp->{files}};
    for my $path (@paths) {
        last if $done>=$limit; $done++;
        next unless $path =~ m{^/} && $path !~ /[\x00-\x1f\x7f]/ && safe_path($path);
        my @st=lstat($path); next unless @st && -f _ && $st[4]==$< && $st[9]<=$now+1;
        my $f=$cp->{files}{$path};
        $f->{source_mtime}=$st[9] if $tool eq 'codex' && $st[9]>($f->{source_mtime}//0);
        next unless $tool eq 'claude' && ref($f->{meta}) eq 'HASH' && defined($f->{meta}{agent}) && length($f->{meta}{agent});
        my $lead=ref($cp->{sessions}) eq 'HASH' ? $cp->{sessions}{text($f->{meta}{id})} : undef; next unless ref($lead) eq 'HASH';
        my $aid=text($f->{meta}{agent}); my $c=ref($lead->{calls}) eq 'HASH' ? $lead->{calls}{(ref($lead->{aliases}) eq 'HASH' ? $lead->{aliases}{$aid} : undef)//"agent:$aid"} : undef;
        $c->{source_mtime}=$st[9] if ref($c) eq 'HASH' && $st[9]>($c->{source_mtime}//0);
    }
    return $done;
}
# Explicit read-only reducer entry for followers: journal projection plus peeked checkpoint
# evidence. Takes no guard, loads nothing through a mutator and writes nothing. $last holds
# the caller's last valid snapshots ({codex=>..,claude=>..}) and is updated in memory only.
sub follower_read {
    my ($self,$where,$last)=@_; $last//={};
    # $where is a logs directory, or the owner's canonical root (L0 context root) so that both
    # registered-alias layouts read the physical store; a worktree root with a symlinked
    # .loomy or logs is refused by safe_path (unavailable/unsafe), never followed.
    (my $dir=$where) =~ s{/+$}{};
    $dir.="/.loomy/logs" unless $dir =~ m{/\.loomy/logs$};
    my %peek;
    for my $tool (qw(codex claude)) {
        my $p=checkpoint_peek("$dir/$tool-native.idx",$last->{$tool});
        $last->{$tool}=$p->{checkpoint} if $p->{status} eq 'valid';
        $p->{stale}=1 if $p->{status} =~ /^(?:stale|unsupported)$/ && $p->{checkpoint};
        stat_evidence($tool,$p->{checkpoint}) if $p->{checkpoint} && $p->{status} =~ /^(?:valid|stale|unsupported)$/;
        $peek{$tool}=$p;
    }
    $self->read_journal("$dir/events.jsonl");
    my $usable=sub {$_[0]{checkpoint} && $_[0]{status} =~ /^(?:valid|stale|unsupported)$/};
    $self->source_evidence($peek{codex}{checkpoint}) if $usable->($peek{codex});
    $self->claude_evidence($peek{claude}{checkpoint}) if $usable->($peek{claude});
    return \%peek;
}
# Collector-origin load: may quarantine damaged evidence and prune, so it needs the guard.
# A supported-format failure is corruption; an unknown or future format is refused unchanged.
sub checkpoint_load {
    my ($path,$opts)=@_; my $exists=0;
    ref($opts) eq q(HASH) && $opts->{full} ? _fence($opts,$path,0) : _fence_load($opts,$path);
    my $lim=_read_limit($opts,$path);
    my ($pk,$p)=_checkpoint_read($path,0,$lim); ($pk,$p)=_checkpoint_read($path,0,$lim) if $pk eq 'changed';
    die "unsupported checkpoint format: $pk\n" if $pk =~ /^unsupported-/;
    my ($bk,$b);
    if ($pk eq 'valid') {my $r=_backup_refusal($path); die "unsupported checkpoint format: $r\n" if $r}
    if ($pk ne 'valid') {
        ($bk,$b)=_checkpoint_read("$path.bak",0,$lim); ($bk,$b)=_checkpoint_read("$path.bak",0,$lim) if $bk eq 'changed';
        die "unsupported checkpoint format: $bk\n" if $bk =~ /^unsupported-/;
        die "checkpoint changed during read\n" if $pk eq 'changed' || $bk eq 'changed';
        die "checkpoint unavailable\n" if $pk eq 'io-error' || $bk eq 'io-error';
    }
    checkpoint_prune_invalid($path,$opts);
    return $p if $pk eq 'valid';
    return do {warn "Native checkpoint recovered from backup\n"; $b} if $bk eq 'valid';
    $exists=1 if -e $path || -e "$path.bak";
    if ($exists) {
        # Keep damaged evidence untouched while bounded journal replay rebuilds a separate generation.
        _fence($opts,$path,0);
        for my $candidate ($path,"$path.bak") {
            next unless -e $candidate;
            die 'unsafe damaged checkpoint' unless safe_path($candidate) && -f $candidate;
            my @st=stat($candidate); my $saved="$candidate.invalid-$st[0]-$st[1]";
            die 'unsafe checkpoint quarantine' unless safe_path($saved) && !-e $saved;
            rename $candidate,$saved or die 'checkpoint preservation failed'; chmod 0600,$saved or die;
        }
        checkpoint_prune_invalid($path,$opts);
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
sub checkpoint_prune_invalid {
    my ($path,$opts)=@_; _owner_of($opts,0);
    my $dir=$path; $dir =~ s{/[^/]+$}{};
    my $base=$path; $base =~ s{.*/}{};
    return unless safe_path($dir);
    opendir my $h,$dir or return;
    my @old=sort {(stat($b))[9]<=>(stat($a))[9] || $b cmp $a}
        grep {safe_path($_) && -f $_}
        map {"$dir/$_"} grep {/^\Q$base\E(?:\.bak)?\.invalid-\d+-\d+$/} readdir $h;
    return if @old<=2;
    splice @old,0,2;
    # Only obsolete quarantine evidence is removed; live checkpoints and symlinks are untouched.
    if (@old) {_fence($opts,$path,0); unlink $_ or die 'checkpoint quarantine pruning failed' for @old}
}
sub load_shards {
    my ($path,$s)=@_; my $refs=delete $s->{source_shards};
    die 'invalid source shards' unless ref($refs) eq 'ARRAY' && @$refs<=64;
    my %files; my $total=0;
    for my $name (@$refs) {
        die 'invalid shard identity' unless text($name) =~ /^files-[0-9a-f]{64}$/;
        my $p="$path.$name"; die 'unsafe source shard' unless safe_path($p) && -f $p && -s $p<=262144;
        sysopen my $f,$p,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die; die 'unsafe source shard' unless -f $f; local $/; my $raw=<$f>; $total+=length($raw);
        die 'source inventory exceeds 16 MiB' if $total>16777216;
        require Digest::SHA; die 'source shard checksum mismatch' unless $name eq 'files-'.Digest::SHA::sha256_hex($raw);
        my $part=checkpoint_decode($raw); die 'invalid source shard' unless ref($part) eq 'HASH';
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
    my ($path,$s,$opts)=@_;
    # Fence first: nothing is flushed, written, backed up or pruned without live ownership.
    _fence_save($opts,$path);
    die "collector owner INVALID_GUARD\n" if defined($opts) && ref($opts->{flush}) ne 'ARRAY';
    _flush_handles($opts);
    $s->{version}=2;
    my $json=checkpoint_json(); my %snapshot=%$s;
    # An unsupported on-disk primary is preserved; saving would replace it and its backup.
    my ($prior_raw,$prior_state,$prior_known_valid);
    if (-s $path && -s $path<=_read_limit($opts,$path) && safe_path($path)) {
        sysopen my $old,$path,O_RDONLY|O_NOFOLLOW or die 'checkpoint backup open failed';
        my @pst=stat($old);
        local $/; $prior_raw=<$old>;
        my $memo=$KIND_MEMO{$path};
        if ($memo && $memo->[1] eq 'valid' && @pst && $memo->[0] eq _memo_tag("$pst[0]:$pst[1]:$pst[7]:$pst[9]",$prior_raw)) {$prior_known_valid=1}
        else {
            $prior_state=eval {checkpoint_decode($prior_raw)};
            my $kind=ref($prior_state) eq 'HASH' ? _checkpoint_kind($prior_state) : undef;
            die "unsupported checkpoint format: $kind\n" if defined($kind) && $kind =~ /^unsupported-/;
        }
    }
    {my $r=_backup_refusal($path); die "unsupported checkpoint format: $r\n" if $r}
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
    my $unchanged=0;
    # Preserve the last valid generation; an invalid primary must not replace a usable backup.
    if (defined $prior_raw) {
        my $prior=$prior_raw; my $valid=$prior_state;
        my $ok=$prior_known_valid || (ref($valid) eq 'HASH' && eval {load_shards($path,$valid) if exists $valid->{source_shards}; 1});
        $unchanged=$ok && $prior eq $raw;
        if ($unchanged) {sysopen my $old,$path,O_RDONLY|O_NOFOLLOW or die 'checkpoint backup open failed'; chmod 0600,$old or die 'checkpoint permissions failed'}
        atomic_file("$path.bak",$prior) if $ok && !$unchanged;
    }
    atomic_file($path,$raw) unless $unchanged;
    # Keep only shards referenced by the primary or its backup, after both are durable.
    my %keep=map {text($_)=>1} @{$snapshot{source_shards}//[]};
    if (-f "$path.bak" && safe_path("$path.bak")) {
        sysopen my $b,"$path.bak",O_RDONLY|O_NOFOLLOW or die; local $/; my $braw=<$b>;
        # Without the key (and without any escape that could spell it) the backup names no shard.
        my $old=(index($braw,'source_shards')<0 && index($braw,'\\')<0) ? undef : eval {checkpoint_decode($braw)};
        $keep{text($_)}=1 for @{ref($old) eq 'HASH' && ref($old->{source_shards}) eq 'ARRAY' ? $old->{source_shards} : []};
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
# Dual origin: hooks pass no options (events lock only); a collector passes its guard.
sub recover_rotation {
    my ($path,$dir,$opts)=@_; return unless -e "$dir/rotation";
    die 'unsafe rotation marker' unless safe_path("$dir/rotation") && -s "$dir/rotation"<=4096;
    _fence($opts,$path,1) if defined $opts;
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
    my ($path,$writer,$opts)=@_; return unless safe_path($path);
    $writer//=content_writer(content_root($path)); return unless $writer;
    my $dir=$path; $dir =~ s{/[^/]+$}{};
    recover_rotation($path,$dir,$opts); return unless -s $path;
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
    _fence($opts,$path,1) if defined $opts;
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
    # Rotation is never a fresh authorization to copy an old excerpt. Preserve
    # references and facts even when the current append policy allows excerpts.
    my $structural={%$writer,policy=>{%{$writer->{policy}},journal_content=>'structural'}};
    @keep=map {
        my $event=eval {project_journal_event($structural,{%$_,snapshot=>JSON::PP::true})};
        warn "journal snapshot skipped; invalid record\n" unless $event;
        $event ? ($event) : ();
    } @keep;
    my $canonical=JSON::PP->new->canonical;
    my $snapshot=join('',map {journal_line($_)}
        sort {epoch($a->{ts})<=>epoch($b->{ts}) || text($a->{type}) cmp text($b->{type}) || $canonical->encode($a) cmp $canonical->encode($b)} @keep);
    die 'journal active snapshot exceeds 8 MiB; rotation paused' if length($snapshot)>=8388608;
    my @st=stat($path); my $dest="$archive/events-$month-$st[0]-$st[1].jsonl";
    die 'unsafe archive segment' unless safe_path($dest) && !-e $dest;
    chmod 0600,$path or die;
    atomic_file("$dir/events.next",$snapshot);
    my $name=$dest; $name =~ s{.*/}{};
    atomic_file("$dir/rotation",encode_json({archive=>$name,month=>$now,key=>"$st[0]:$st[1]"}));
    _fence($opts,$path,1) if defined $opts;
    recover_rotation($path,$dir,$opts);
}
# Named collector entries: an undefined $opts (lost election) dies instead of taking the hook path.
sub journal_rotate_owned {
    my ($path,$writer,$opts)=@_; die "collector owner INVALID_GUARD\n" unless ref($opts) eq 'HASH';
    return journal_rotate($path,$writer,$opts);
}
sub recover_rotation_owned {
    my ($path,$dir,$opts)=@_; die "collector owner INVALID_GUARD\n" unless ref($opts) eq 'HASH';
    return recover_rotation($path,$dir,$opts);
}
sub journal_append {
    my $ok=eval {_journal_append(@_)};
    warn "journal event skipped; append unavailable\n" if $@;
    return $ok;
}
sub _journal_append {
    my ($path,$body,$ts,$label)=@_;
    die 'journal record exceeds 64 KiB' if !ref($body) && length($body)>65000;
    my $dir=$path; $dir =~ s{/[^/]+$}{};
    # Leak barrier at the single append every journal writer passes through: a project that tracks runtime state in
    # its Git index is never written into (cached verdict, fail closed; see journal-gate.pl). Before any directory,
    # lock or policy file is created.
    return unless journal_gate($dir);
    # Bootstrap directories/identity without a policy lock. A first PreToolUse
    # hook can arrive before a prompt/session hook has prepared the journal.
    Loomy::ContentPolicy::_context(content_root($path),1) unless -d $dir;
    my $lock=journal_lock($dir,1) or return;
    my $writer=content_writer(content_root($path)); return unless $writer && $writer->{policy}{journal_enabled};
    # Prompt hooks can build an authorized excerpt from stdin in this process,
    # after the snapshot, without an extra policy interpreter or content argv.
    $body=$body->($writer->{policy}) if ref($body) eq 'CODE';
    journal_rotate($path,$writer);
    return unless safe_path($path);
    sysopen my $f,$path,O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or return;
    chmod 0600,$f or return;
    $ts=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime) unless epoch($ts);
    my $event;
    if (ref($body) eq 'HASH') {$event={%$body,ts=>$ts}}
    else {
        # Old byte-cut shell producers can end on half a UTF-8 character.
        my $raw='{"ts":'.substr($journal_json->encode([$ts]),1,-1).",$body}";
        $event=eval {decode_json($raw)};
        $event=JSON::PP->new->decode(Loomy::ContentPolicy::_decode_utf8($raw)) unless $event;
    }
    if ($label) {
        my $ref=content_label($writer,@$label);
        $event->{label_ref}=$ref if $ref;
        $event->{task}=$label->[4] if $writer->{policy}{journal_content} eq 'legacy-excerpts'
            && $label->[3] eq 'claude-description' && defined($label->[4]);
    }
    my $line=journal_event_line($writer,$event); return unless defined $line;
    print $f $line or die 'journal append failed'; $f->flush or die; $f->sync or die;
    close $f or die 'journal close failed';
    eval {journal_rotate($path,$writer)} if -s $path>=8388608;
    return 1;
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
# Returns 'done', 'deferred' (another process holds an index lock), 'refused' (an unsupported
# primary or backup exists; nothing was touched) or 'unavailable' (disabled journal / no logs).
sub migrate_checkpoints {
    my ($root,$opts)=@_; return 'unavailable' if ($ENV{LOOMY_JOURNAL}//'1') eq '0';
    my $dir="$root/.loomy/logs"; return 'unavailable' unless safe_path($dir) && -d $dir;
    return 'done' if -f "$dir/checkpoint-v2";
    _fence($opts,"$dir/checkpoint-v2",0);
    # Pure refusal pass over every tool, primary and backup, before any lock, load or save.
    for my $tool (qw(codex claude)) {
        my $idx="$dir/$tool-native.idx";
        for my $candidate ($idx,"$idx.bak") {
            my ($k)=_checkpoint_read($candidate,0,$LEGACY_READ_LIMIT); return 'refused' if $k =~ /^unsupported-/;
        }
    }
    my $full=defined $opts ? {%$opts,full=>1,legacy=>1,flush=>(ref($opts->{flush}) eq 'ARRAY' ? $opts->{flush} : [])} : undef; # migration keeps the full fence everywhere
    my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+$}{};
    require "$lib/codex-native.pl"; require "$lib/claude-native.pl";
    for my $tool (qw(codex claude)) {
        my $idx="$dir/$tool-native.idx"; next unless -e $idx;
        die 'unsafe migration lock' unless safe_path("$idx.lock");
        sysopen my $lock,"$idx.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or die;
        flock($lock,LOCK_EX|LOCK_NB) or return 'deferred';
        my $s=checkpoint_load($idx,$full); next if ($s->{version}//0)==2;
        my $dirty=1;
        if ($tool eq 'codex') {Loomy::CodexNative::prune_checkpoint($s,$ENV{LOOMY_NATIVE_NOW}//time)}
        else {Loomy::ClaudeNative::prune($s,\$dirty)}
        checkpoint_save($idx,$s,$full);
    }
    _fence($opts,"$dir/checkpoint-v2",0);
    atomic_file("$dir/checkpoint-v2","2\n");
    return 'done';
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
    if ($pid =~ /^\d+$/ && $pid>1 && $ts>($s->{closed_at}//0) && $ts>=($s->{pid_ts}//0)) {
        # Replayed older events must not move the session back to a launcher that has since ended.
        $s->{pid}=$pid; $s->{pid_ts}=$ts;
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
    $a->{codex_v2}=1 if $tool eq 'codex' && text($d->{multi_agent_version}) eq 'v2';
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
        my $latest=$self->{turns}{$a->{latest}}//{};
        $a->{state}=$latest->{state} if $a->{codex_v2} && $latest->{ended} && !$a->{closed};
        if ($type eq 'agent_closed' && $ts>=$a->{seen}) {
            $a->{closed}=1; $a->{closed_at}=$ts; $a->{state}=$a->{codex_v2} && $latest->{ended} && text($d->{status}) eq 'interrupted' ? $latest->{state} : 'done';
        }
        return;
    }
    my $fresh=!exists $self->{turns}{$id};
    my $turn=$self->{turns}{$id}//={key=>$id,agent=>$ak,session=>$key,state=>'unknown',outcome=>'unknown',started=>0,seen=>0,seq=>++$self->{seq}};
    if ($type eq 'delegation_start') {
        if ($turn->{ended}) {$turn->{started}=$ts if !$turn->{started} && $ts<=$turn->{ended}; return}
        $turn->{started}=$ts if !$turn->{started} || $ts<$turn->{started};
        delete @$turn{qw(ended duration status)} if $turn->{ended} && $turn->{ended}<$ts;
        $turn->{state}='running' unless $turn->{ended};
        $turn->{pid}=text($d->{pid}) if text($d->{pid}) =~ /^[1-9][0-9]*$/;
        $a->{closed}=0 if $fresh && text($d->{bridge}) eq 'codex-native' && $ts>($a->{closed_at}//0);
    }
    elsif ($type eq 'delegation_activity') {
        return if $ts<$turn->{seen};
        delete @$turn{qw(ended duration status)} if $tool eq 'claude' && ($turn->{status}//'') eq 'interrupted'
            && $ts>($turn->{ended}//0) && text($d->{state}) eq 'running';
        $turn->{state}=text($d->{state}//$d->{activity}) || 'unknown' unless $turn->{ended} || $ts<$turn->{seen};
        $a->{source_mtime}=text($d->{source_mtime}) if $tool eq 'claude' && text($d->{source_mtime}) =~ /^\d+(?:\.\d+)?$/;
    } elsif ($type eq 'delegation') {
        return if ($turn->{started} && $ts<$turn->{started}) || ($turn->{ended} && $ts<$turn->{ended} && ($turn->{state}//'') ne 'unknown');
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
        $a->{state}=$a->{closed} && !($a->{codex_v2} && $turn->{ended}) ? 'done' : $turn->{ended} ? (text($d->{bridge}) eq 'codex-native' && !$a->{codex_v2} ? 'idle' : $turn->{state}) : $turn->{state};
    }
    $a->{seen}=$ts if $ts>$a->{seen};
}

# Seek before decoding; malformed complete lines advance, partial appends retry, oversized lines skip.
# JSON::PP reads strings one character at a time, which dominates checkpoint, journal
# and transcript decoding. This scanner reads plain ASCII text made of objects, arrays,
# strings with simple escapes, small integers, booleans and null with anchored regexes
# and builds exactly what JSON::PP builds. Anything else (non-ASCII, \u escapes,
# fractions, exponents, big or negative-zero numbers, deep nesting, malformed text)
# is handed unchanged to JSON::PP, so results and failures stay identical.
my %FD_ESC=('"'=>'"','\\'=>'\\','/'=>'/',b=>"\b",f=>"\f",n=>"\n",r=>"\r",t=>"\t");
our ($FD,$FD_DEPTH);
sub _fd_string {
    # A run of more than ~65k escapes exceeds the regex engine's recursion limit: the match fails (the JSON::PP
    # fallback then decodes it) and Perl warns. The warning must not reach the sampler's failure flag.
    no warnings 'regexp';
    $FD =~ /\G"((?:[^"\\\x00-\x1f]++|\\["\\\/bfnrt])*+)"/gc or die \&_fd_string;
    my $v=$1; $v =~ s/\\(.)/$FD_ESC{$1}/g if index($v,'\\')>=0; return $v;
}
sub _fd_value {
    $FD =~ /\G[ \t\r\n]*/gc;
    if ($FD =~ /\G"/gc) {pos($FD)--; return _fd_string()}
    if ($FD =~ /\G(0|-?[1-9][0-9]{0,14})(?![0-9.eE])/gc) {return 0+$1}
    if ($FD =~ /\G\{/gc) {
        die \&_fd_value if ++$FD_DEPTH>64;
        my %h; $FD =~ /\G[ \t\r\n]*/gc;
        unless ($FD =~ /\G\}/gc) {
            while (1) {
                my $k;
                if ($FD =~ /\G"([^"\\\x00-\x1f]*+)":/gc) {$k=$1}
                else {$FD =~ /\G[ \t\r\n]*/gc; $k=_fd_string(); $FD =~ /\G[ \t\r\n]*:/gc or die \&_fd_value}
                # Plain strings and small integers need no recursion.
                if ($FD =~ /\G"([^"\\\x00-\x1f]*+)"/gc) {$h{$k}=$1}
                elsif ($FD =~ /\G(0|-?[1-9][0-9]{0,14})(?![0-9.eE])/gc) {$h{$k}=0+$1}
                else {$h{$k}=_fd_value()}
                next if $FD =~ /\G,/gc; last if $FD =~ /\G\}/gc;
                $FD =~ /\G[ \t\r\n]*/gc; next if $FD =~ /\G,/gc; last if $FD =~ /\G\}/gc; die \&_fd_value;
            }
        }
        --$FD_DEPTH; return \%h;
    }
    if ($FD =~ /\G\[/gc) {
        die \&_fd_value if ++$FD_DEPTH>64;
        my @a; $FD =~ /\G[ \t\r\n]*/gc;
        unless ($FD =~ /\G\]/gc) {
            while (1) {
                push @a,_fd_value(); $FD =~ /\G[ \t\r\n]*/gc;
                next if $FD =~ /\G,/gc; last if $FD =~ /\G\]/gc; die \&_fd_value;
            }
        }
        --$FD_DEPTH; return \@a;
    }
    return $JSON::PP::true if $FD =~ /\Gtrue(?![A-Za-z0-9_])/gc;
    return $JSON::PP::false if $FD =~ /\Gfalse(?![A-Za-z0-9_])/gc;
    return undef if $FD =~ /\Gnull(?![A-Za-z0-9_])/gc;
    die \&_fd_value;
}
sub _fast_parse {
    my ($text)=@_;
    return unless defined $text && !ref($text) && $text =~ /\A[ \t\r\n]*[\{\[]/ && $text !~ /[^\x00-\x7f]/;
    my $v; local ($FD,$FD_DEPTH)=($text,0); pos($FD)=0;
    return eval {$v=_fd_value(); $FD =~ /\G[ \t\r\n]*\z/gc or die \&_fd_value; 1} ? (1,$v) : ();
}
# Same contract as decode_json (UTF-8 bytes in, structure out, dies on bad input).
sub decode_fast {my ($ok,$v)=_fast_parse($_[0]); return $ok ? $v : decode_json($_[0])}
# Same, with the checkpoint codec (JSON::XS when installed) as the fallback.
sub checkpoint_decode {
    my $codec=checkpoint_json(); return $codec->decode($_[0]) if ref($codec) eq 'JSON::XS';
    my ($ok,$v)=_fast_parse($_[0]); return $ok ? $v : $codec->decode($_[0]);
}
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
        my $d=eval {decode_fast($line)}; push @out,$d if ref($d) eq 'HASH';
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
        my $evidence=epoch($f->{last_evidence_ts}//$f->{last_observed_ts}); my $ts=$evidence;
        $ts=$f->{source_mtime} if ($f->{source_mtime}//0)>$ts && $f->{source_mtime}<=($ENV{LOOMY_NATIVE_NOW}//time)+1;
        # Only new records reopen a closed session; a bare mtime (touch, rsync, backup) renews a lease, never reopens.
        if ($s->{closed} && $evidence>($s->{closed_at}//0)) { $s->{closed}=0; $s->{pid}=0 }
        $s->{seen}=$ts if $ts>$s->{seen};
        my $a=$self->{agents}{"codex:$f->{meta}{id}"};
        my $own=epoch($f->{last_observed_ts});
        $a->{seen}=$own if $a && $own>$a->{seen};
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
            $agent_state='lost' if $expired;
        }
        # Pre-schema bridge turns (and any turn of an unassigned bucket) have no lease of their own: they run
        # only while their launcher still lives and the owning session shows live evidence; never forever.
        if (($a->{schema}//0)!=2 && !$t->{ended} && !$a->{closed}) {
            my $tp=$t->{pid}//0; my $tp_alive=$tp =~ /^\d+$/ && $tp>1 && (kill(0,$tp) || $! == EPERM);
            my $age=$now-($t->{started}||$a->{seen}||0);
            $interrupted=1 if ($tp ? !$tp_alive : (!$live && $age>120)) || ($age>86400 && !$live);
        }
        $agent_state='interrupted' if $interrupted;
        # Completed agents close with an observed owner; absent PIDs remain source-owned.
        $agent_state=$a->{codex_v2} ? $t->{state} : 'done' if $t->{ended} && (($session->{closed}//0) || $dead);
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
            int($t->{started}//0),($t->{ended} ? int($t->{ended}) : ''),$t->{duration},$t->{outcome},$a->{latest},int($a->{seen}),$interrupted ? 'interrupted' : $expired ? 'lost' : $t->{state},$turns);
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
# Direct CLI entries elect like the adapters' own CLI blocks (bare_election): one transient
# election per call, and a non-owner mutates nothing. A held owner slot means "follow": the
# reducer reads the stored journal only, and --migrate leaves the upgrade to the owner's turn.
unless (caller) {
    no warnings 'once';
    my $dir=abs_path(__FILE__); $dir =~ s{/[^/]+$}{};
    if (($ARGV[0]//'') eq '--migrate') {
        my $abs=abs_path($ARGV[1]//'') // exit 0;
        require "$dir/codex-native.pl"; Loomy::CodexNative::load_owner();
        my $ctx=eval {Loomy::RuntimePaths::resolve($abs)}; exit 0 unless $ctx && $ctx->{loomy} && $ctx->{logs};
        { my (undef,$why)=Loomy::RuntimePaths::tracked_runtime($ctx->{root}); exit 0 if $why; }   # a tracked (clone-shipped) index is neither read nor migrated
        my $r=eval {Loomy::CollectorOwner::try_acquire($ctx,Loomy::CodexNative::build_id())};
        exit 0 unless ref($r) eq 'HASH' && ($r->{status}//'') eq 'owned';
        my $ok=eval {migrate_checkpoints($ctx->{root},{owner=>$r->{guard},context=>$ctx}); 1};
        eval {Loomy::CollectorOwner::release($r->{guard})};
        exit($ok ? 0 : 1);
    }
    my ($root,$sessions)=@ARGV; $root=abs_path($root)//exit 1;
    require "$dir/codex-native.pl";
    require "$dir/claude-native.pl";
    $Loomy::CodexNative::bare_election=1;
    my $native=$ENV{LOOMY_WATCH_ID} ? undef : Loomy::CodexNative::poll($root,$sessions);
    my $claude=$ENV{LOOMY_WATCH_ID} ? undef : Loomy::ClaudeNative::poll($root,($ENV{CLAUDE_CONFIG_DIR}//"$ENV{HOME}/.claude").'/projects');
    my $state=__PACKAGE__->new; $state->read_journal("$root/.loomy/logs/events.jsonl"); $state->source_evidence($native);
    $state->claude_evidence($claude);
    print "$_\n" for $state->projections($ENV{LOOMY_NATIVE_NOW}//time);
}
1;

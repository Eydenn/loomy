# Strict schema for journal events (events.jsonl and archives): the read side never trusts a clone-shipped file.
# Bash evaluates the text of a variable as arithmetic, and `read` on the default IFS shifts a value with spaces into
# the next column, so a model or a ts such as "x 1 a[$(cmd)]" must never reach a producer row as it is. Every
# reader of events passes the decoded event through clean_event, at the two entry points: ai_journal_canonical
# (shell pipelines) and Loomy::LiveState::journal_records (live reducers), plus the legacy tree reader.
#   identifiers  (model, role, bridge, family, status, phase, id, outcome, ...): letters, digits and . _ : / @ + -
#                (model also allows [ and ]), 63 characters at most (127 for session-like ids); otherwise "?"
#   timestamps   the ISO form Loomy writes, otherwise the key is dropped
#   numbers      digits, at most 12 (a decimal part, uncapped, for durations and costs); otherwise 0; "" stays empty
#   free text    (task, excerpt, why, labels...) is the only text with spaces; control characters, DEL and
#                UTF-8 C1 controls become spaces
package Loomy::EventSchema;
use strict;
use warnings;
use JSON::PP ();

my %IDENT=map {$_=>63} qw(type model role bridge family tool provider status phase outcome effort scope event state
  activity surface context_freshness agent_type failover_from cost_in cost_source sandbox profile master acting
  review format content_policy reason_code quota_window source delegation_kind);
my %ID=map {$_=>127} qw(id session agent_id turn_id parent_session alias_id attempt_id session_key parent_agent_id
  parent_delegation attempt);
my %TS=map {$_=>1} qw(ts source_ts since ended_at_ts);
my %NUM=map {$_=>1} qw(pid owner_pid duration_s cost_usd tokens_in tokens_out tokens_cached messages calls resume_at
  files_changed used_percent schema started_at ended_at);

# strip: C0, DEL and C1 (a character string, or UTF-8 bytes: C2 80..9F) become spaces.
sub strip {
  my $s=shift; return $s unless defined $s && !ref($s);
  $s =~ s/[\x00-\x1f\x7f]/ /g;
  if (utf8::is_utf8($s)) { $s =~ s/[\x{80}-\x{9f}]/ /g } else { $s =~ s/\xc2[\x80-\x9f]/ /g }
  return $s;
}

my $MAXDEPTH=4;
# A numeric scalar as the JSON decoder produced it (not a string): stringifying it would turn it into a string.
sub _is_num { require B; my $f=B::svref_2object(\$_[0])->FLAGS; return ($f & (B::SVp_IOK()|B::SVp_NOK())) && !($f & B::SVp_POK()) }

# _scalar($key,$value): the schema rule of a field (by name) applied to one scalar; returns the new value, or
# undef to drop the key. Unknown names are free text (control characters stripped).
sub _scalar {
  my ($k,$v)=@_;
  if ($IDENT{$k} || $ID{$k}) {
    my $max=$IDENT{$k} ? $IDENT{$k} : $ID{$k}; my $copy=$v; my $text="$copy";
    my $re=$k eq 'model' ? qr/\A(?:|[A-Za-z0-9][A-Za-z0-9._:\/@+\[\]-]{0,$max})\z/ : qr/\A(?:|[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,$max})\z/;
    return $text =~ $re ? $v : '?';
  }
  if ($TS{$k}) { my $copy=$v; my $text="$copy"; return $text =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z\z/ ? $v : undef }
  # A number stays a number for the reducers that re-encode it (a quoted count would no longer match their regexes).
  if ($NUM{$k}) { my $t=_number($k,$v); return $t eq '' ? '' : 0+$t }
  return $v if _is_num($v);
  my $copy=$v; my $text="$copy";
  return $text =~ /[^\x20-\x7e]/ ? strip($text) : $v;
}
# _number: digits only (at most 12; a decimal part for duration_s and cost_usd), else 0. Exponent forms (a very
# small cost such as 1e-05) are written out; negatives, NaN, Inf and text become 0. Returns the number's text.
sub _number {
  my ($k,$v)=@_; my $copy=$v; my $text="$copy";
  $text=sprintf('%.9f',$copy) =~ s/0+\z//r =~ s/\.\z//r if $text =~ /\A\d+(?:\.\d+)?[eE][+-]?\d+\z/ && $k =~ /\A(?:duration_s|cost_usd)\z/;
  # An empty string stays empty (readers test emptiness: resume_at "" is not epoch 0). The decimals of a duration or a
  # cost are not capped (Claude hooks write 10.1150000095367); the whole number is at most 12 + 1 + 20 characters.
  return $text if $text eq '';
  my $bad=$k eq 'resume_at' ? '' : 0;   # an invalid resume_at is "no time", never epoch 0 ("until 01:00")
  return $text =~ ($k =~ /\A(?:duration_s|cost_usd)\z/ ? qr/\A\d{1,12}(?:\.\d{1,20})?\z/ : qr/\A\d{1,12}\z/) ? $text : $bad;
}
sub _hash {
  my ($h,$depth)=@_;
  for my $k (keys %$h) {
    my $v=$h->{$k}; next unless defined $v;
    if (ref($v) eq 'HASH') { if ($depth>=$MAXDEPTH) { delete $h->{$k} } else { _hash($v,$depth+1) } next }
    if (ref($v) eq 'ARRAY') { if ($depth>=$MAXDEPTH) { delete $h->{$k} } else { _array($v,$k,$depth+1) } next }
    next if ref($v);   # JSON booleans
    my $n=_scalar($k,$v); if (defined $n) { $h->{$k}=$n } else { delete $h->{$k} }
  }
}
sub _array {
  my ($a,$k,$depth)=@_;
  for my $i (0..$#$a) {
    my $v=$a->[$i]; next unless defined $v;
    if (ref($v) eq 'HASH') { if ($depth>=$MAXDEPTH) { $a->[$i]=undef } else { _hash($v,$depth+1) } next }
    if (ref($v) eq 'ARRAY') { if ($depth>=$MAXDEPTH) { $a->[$i]=undef } else { _array($v,$k,$depth+1) } next }
    next if ref($v);
    my $n=_scalar("\0array",$v); $a->[$i]=defined $n ? $n : undef;
  }
}

# clean_event(\%event): in place, nested objects and arrays included (a key that names a schema field gets that
# field's rule wherever it sits; other scalars are free text). True for a hash.
sub clean_event {
  my $e=shift; return 0 unless ref($e) eq 'HASH';
  _hash($e,0); return 1;
}

# encode(\%event): always the line a reader sees (never the raw input: duplicate keys, nested text and escapes
# are gone). type first (readers match "type":"x", with a trailing comma), the rest sorted. Numeric schema fields
# are written as plain numbers, whatever type the input had.
sub encode {
  my $e=shift; my $json=JSON::PP->new->utf8->canonical->allow_nonref;
  my @keys=((exists $e->{type} ? 'type' : ()),sort grep {$_ ne 'type'} keys %$e);
  return '{'.join(',',map {
    my ($k,$v)=($_,$e->{$_});
    $json->encode("$k").':'.((!ref($v) && defined($v) && $NUM{$k} && "$v" ne '') ? _number($k,$v) : $json->encode($v))
  } @keys).'}';
}
1;

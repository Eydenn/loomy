# Strict schema for journal events (events.jsonl and archives): the read side never trusts a clone-shipped file.
# Bash evaluates the text of a variable as arithmetic, and `read` on the default IFS shifts a value with spaces into
# the next column, so a model or a ts such as "x 1 a[$(cmd)]" must never reach a producer row as it is. Every
# reader of events passes the decoded event through clean_event, at the two entry points: ai_journal_canonical
# (shell pipelines) and Loomy::LiveState::journal_records (live reducers), plus the legacy tree reader.
#   identifiers  (model, role, bridge, family, status, phase, id, outcome, ...): letters, digits and . _ : / @ + -
#                (model also allows [ and ]), 63 characters at most (127 for session-like ids); otherwise "?"
#   timestamps   the ISO form Loomy writes, otherwise the key is dropped
#   numbers      digits, at most 12 (a decimal part for durations and costs); otherwise 0
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

# clean_event(\%event): in place; true when something changed.
sub clean_event {
  my $e=shift; return 0 unless ref($e) eq 'HASH';
  my $changed=0;
  for my $k (keys %$e) {
    my $v=$e->{$k}; next if !defined($v) || ref($v);
    my $new=$v;
    if ($IDENT{$k} || $ID{$k}) {
      my $max=$IDENT{$k} ? $IDENT{$k} : $ID{$k};
      my $re=$k eq 'model' ? qr/\A(?:|[A-Za-z0-9][A-Za-z0-9._:\/@+\[\]-]{0,$max})\z/ : qr/\A(?:|[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,$max})\z/;
      $new='?' unless "$v" =~ $re;
    } elsif ($TS{$k}) {
      unless ("$v" =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z\z/) { delete $e->{$k}; $changed=1; next }
    } elsif ($NUM{$k}) {
      my $text="$v"; $new=0 unless $text =~ ($k =~ /\A(?:duration_s|cost_usd)\z/ ? qr/\A\d{1,12}(?:\.\d{1,9})?\z/ : qr/\A\d{1,12}\z/);
    } elsif (!JSON::PP::is_bool($v) && "$v" =~ /[^\x20-\x7e]/) {
      my $s=strip("$v"); $new=$s if $s ne "$v";
    }
    if (!defined($new) || "$new" ne "$v" || ($new eq '0' && "$v" ne '0')) { $e->{$k}=$new; $changed=1 }
  }
  return $changed;
}

# encode(\%event): one line, type first (readers match "type":"x", with a trailing comma), the rest sorted.
sub encode {
  my $e=shift; my $json=JSON::PP->new->utf8->canonical->allow_nonref;
  my @keys=((exists $e->{type} ? 'type' : ()),sort grep {$_ ne 'type'} keys %$e);
  return '{'.join(',',map {$json->encode("$_").':'.$json->encode($e->{$_})} @keys).'}';
}
1;

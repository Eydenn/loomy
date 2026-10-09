#!/usr/bin/env bash
# Claude settings repair, also called by the project installer. Bash 3.2; sourced only.
# Invalid JSON stays untouched. User hooks and statusLine stay intact.
loomy_claude_hooks_merge() {
  local root="$1" f="$1/.claude/settings.json"
  [[ ! -L "$root/.claude" && ! -L "$f" ]] || return 1
  mkdir -p "$root/.claude" || return 1
  perl -MJSON::PP -MFcntl=O_WRONLY,O_CREAT,O_EXCL -e '
    my ($path)=@ARGV; my $d={};
    if (-e $path) { open my $in,"<",$path or exit 1; local $/; $d=eval { decode_json(<$in>) }; exit 1 unless ref($d) eq "HASH" }
    my $before=JSON::PP->new->canonical->encode($d);
    my $hooks=$d->{hooks}//={}; exit 1 unless ref($hooks) eq "HASH";
    for my $spec (["SessionStart","start",20],["SessionEnd","end",3],["Stop","stop",10],["SubagentStop","subagent",10],["UserPromptSubmit","prompt",5],["PreToolUse","agent-start",5],["PostToolUse","agent-return",5],["PostToolUseFailure","agent-failure",5]) {
      my ($event,$mode,$timeout)=@$spec;
      my $cmd=q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/loomy-context.sh" --hook }.$mode;
      my $groups=$hooks->{$event}//=[]; exit 1 unless ref($groups) eq "ARRAY";
      next if grep { ($event !~ /^(?:PreToolUse|PostToolUse|PostToolUseFailure)$/ || ($_->{matcher}//"") eq "Agent|Task") && grep { ($_->{command}//"") eq $cmd } @{$_->{hooks}//[]} } @$groups;
      my $g={hooks=>[{type=>"command",command=>$cmd,timeout=>$timeout}]};
      $g->{matcher}="Agent|Task" if $event =~ /^(?:PreToolUse|PostToolUse|PostToolUseFailure)$/;
      push @$groups,$g;
    }
    $d->{statusLine}//={type=>"command",padding=>0,command=>q{sh -c '\''d=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-statusline.sh" ] && exec bash "$d/.loomy/scripts/loomy-statusline.sh"'\''}};
    exit 0 if $before eq JSON::PP->new->canonical->encode($d);
    my $tmp=$path.".loomy-".$$; my $mode=(-e $path) ? ((stat $path)[2] & 07777) : 0644;
    sysopen my $out,$tmp,O_WRONLY|O_CREAT|O_EXCL,0600 or exit 1;
    # The usual JSON style of Claude Code settings: 2-space indent, "key": value.
    print $out JSON::PP->new->utf8->canonical->indent->indent_length(2)->space_after->encode($d); close $out or exit 1;
    chmod $mode,$tmp; rename $tmp,$path or do { unlink $tmp; exit 1 };
  ' "$f" 2>/dev/null
}

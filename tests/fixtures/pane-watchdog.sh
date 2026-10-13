#!/usr/bin/env bash
# Bounded command for a tmux pane: watchdog.pl normally moves its child to a background process group, where
# stty/tcsetattr (used by loomy watch) stops the process. Job control makes the watchdog the pane's foreground
# group so that the command keeps the terminal, like a user typing it; the deadline still applies.
set -m
LOOMY_WATCHDOG_PTY=1 perl "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watchdog.pl" "$@"

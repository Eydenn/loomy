# ADR-0008 — Terminal-only routing ownership

Status: accepted (0.17 final review).

A project-global `--only` marker lets unrelated terminals override each other and can mistake a reused PID for its original owner. Store each session marker under `.loomy/session-only-<pid>-<birth-time>` and export its path to the lead. Readers validate the process birth identity and ancestry before adopting the override; ordinary terminal launches drop the inherited token. Cleanup removes only that owner's marker. Live legacy markers are ignored and preserved; dead legacy markers are cleaned on mutable project reads.

This keeps the brief unchanged and supports concurrent terminal sessions with disjoint routing. Process inspection must establish owner identity; when unavailable, an only-session cannot start safely. Desktop apps still cannot own this override because their process is shared across sessions.

#!/usr/bin/env python3
"""Focused read-side regressions; called with REPO WORK by content-display.sh."""
import copy
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time


RAW_GOLDEN = (
    '{"ts":"2026-01-02T10:00:00Z","type":"delegation","id":"golden-1","bridge":"codex","family":"codex","role":"reviewer","agent":"agent-1","model":"gpt-6-luna","status":"ok","outcome":"done","duration_s":12,"messages":0,"tokens_in":1200,"tokens_cached":200,"tokens_out":300,"cost_usd":0.125,"cost_source":"estimate","content_policy":"structural-v1","task":"RAW_ONLY_TASK"}\n'
    '{"ts":"2026-01-02T10:00:01Z","type":"usage","scope":"lead","family":"claude","model":"claude-sonnet-5-5","messages":2,"tokens_in":5000,"tokens_cached":1000,"tokens_out":500,"cost_usd":0.25,"cost_source":"estimate","content_policy":"structural-v1"}\n'
).encode("utf-8")
CSV_GOLDEN = (
    "date_utc,type,role,agent,family,model,status,duration_s,messages,tokens_in,tokens_cached,tokens_out,cost_usd,cost_source\n"
    "2026-01-02T10:00:00Z,delegation,reviewer,agent-1,codex,gpt-6-luna,ok,12,0,1200,200,300,0.125,estimate\n"
    "2026-01-02T10:00:01Z,usage,lead,,claude,claude-sonnet-5-5,ok,,2,5000,1000,500,0.25,estimate\n"
).encode("utf-8")
LEGACY_GOLDEN = (
    "2026-01-02T10:00:00Z|reviewer|start|gpt-6-luna · Inspect \\\n"
    "2026-01-02T10:00:01Z|reviewer|done|3 s · gpt-6-luna\n"
    "2026-01-02T10:00:02Z|advisor|consulted|1 × claude-opus-5-5 · 35k\n"
).encode("utf-8")
EMPTY_ACTOR_GOLDEN = (
    "2026-01-02T10:00:00Z||start|gpt-6-luna · legacy task\n"
    "2026-01-02T10:00:01Z||done|2 s · gpt-6-luna\n"
).encode("utf-8")


class DisplayChecks:
    def __init__(self, repo, work):
        self.repo = repo
        self.base = Path(tempfile.mkdtemp(prefix="readside-check.", dir=work))
        self.root = self.base / "project"
        self.logs = self.root / ".loomy/logs"
        self.logs.mkdir(parents=True, mode=0o700)
        (self.root / ".loomy").chmod(0o700)
        self.project = "p" + "a" * 64
        self.private_write(self.root / ".loomy/project-id", (self.project + "\n").encode())
        self.store = self.logs / "display-context-v1.jsonl"
        self.journal = self.logs / "events.jsonl"
        self.private_write(self.store, b"")
        self.private_write(self.journal, b"")
        self.private_write(self.root / ".loomy/brief.md", b"---\nname: Content display checks\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\n---\n")
        self.env = os.environ.copy()
        # Keep the parent's guard, BASH_ENV, stub PATH and core selection intact.
        # Only this fixture's accounts, display language and plans are isolated.
        self.env.update(HOME=str(self.base / "home"), XDG_CONFIG_HOME=str(self.base / "config"),
                        CODEX_HOME=str(self.base / "codex"), CLAUDE_CONFIG_DIR=str(self.base / "claude"),
                        LC_ALL="C", TZ="UTC", NO_COLOR="1", LOOMY_LANG="en", LOOMY_UI_LANG="en",
                        LOOMY_HOME=str(repo), LOOMY_NO_AUTOUPDATE="1", LOOMY_CATALOG_CHECK="0",
                        LOOMY_WATCH_ID="content-display-check")
        for key in ("LOOMY_JOURNAL_CONTENT", "LOOMY_CONTENT_PROJECT", "LOOMY_JOURNAL_TASKS"):
            self.env.pop(key, None)
        for key in ("HOME", "XDG_CONFIG_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR"):
            Path(self.env[key]).mkdir(mode=0o700)
        config = Path(self.env["XDG_CONFIG_HOME"]) / "loomy"
        config.mkdir(mode=0o700)
        self.private_write(config / "config", b"plan_claude=api\nplan_codex=api\n")
        # These are synthetic preexisting grants. No policy/grant writer is run.
        policy = self.run(["perl", "-e", 'require shift; my $p=Loomy::ContentPolicy::defaults(); $p->{label_sources}=Loomy::ContentPolicy::recommended_sources(); $p->{grant_prompt_version}=1; print "$_=$p->{$_}\\n" for sort keys %$p', str(repo / "scripts/lib/content-policy.pl")])
        self.private_write(self.logs / "content-policy.conf", policy)
        self.passed = 0
        self.failures = []

    @staticmethod
    def private_write(path, data):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        path.chmod(0o600)

    @staticmethod
    def encoded(rows):
        return b"".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n" for row in rows)

    def check(self, name, condition, detail=""):
        if condition:
            self.passed += 1
            print("ok content display: " + name, flush=True)
        else:
            self.failures.append(name)
            print("FAIL content display: " + name + (": " + detail if detail else ""), file=sys.stderr, flush=True)

    def run(self, argv, data=None, ui=False):
        result = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT if ui else subprocess.PIPE,
                                env=self.env, timeout=20, check=False)
        if result.returncode:
            diagnostic = result.stdout if ui else result.stderr
            raise AssertionError(f"command failed ({result.returncode}): {argv!r}\n{diagnostic.decode('utf-8', 'replace')}")
        return result.stdout

    def shell(self, code, *args, data=None):
        return self.run(["bash", "-c", code, "_", str(self.repo), *map(str, args)], data)

    def prepared(self, rows):
        output = self.shell('source "$1/scripts/lib/journal.sh"; ai_display_context_events "$2"',
                            self.root, data=self.encoded(rows))
        return [json.loads(line) for line in output.splitlines()]

    def session_rows(self):
        return self.shell('source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/sessionlog.sh"; _ai_session_events "$2"', self.journal)

    def enhanced_rows(self):
        return self.shell('source "$1/scripts/lib/journal.sh"; ai_journal_display_events "$2"', self.journal)

    def log(self, *args):
        return self.run(["bash", str(self.repo / "scripts/loomy-log.sh"), "--root", str(self.root), *args])

    def write_labels(self, rows):
        self.private_write(self.store, self.encoded(rows))

    def write_events(self, rows, partial=b""):
        self.private_write(self.journal, self.encoded(rows) + partial)

    def label(self, label_id, target, attempt, text, kind="delegation", source="explicit-lead"):
        return dict(version=1, project_id=self.project, target_kind=kind, target_id=target,
                    attempt_id=attempt, label_id=label_id, text=text, source=source,
                    created_at="2026-01-02T10:00:00Z", supersedes="")

    @staticmethod
    def ref(label):
        return {key: label[key] for key in ("version", "project_id", "target_kind", "target_id", "attempt_id", "label_id")}

    @staticmethod
    def event(**changes):
        event = dict(type="delegation", content_policy="structural-v1", id="d1", family="codex",
                     tool="codex", session="owner", attempt_id="new", role="reviewer", model="gpt-6-luna",
                     status="ok", duration_s=12, outcome="done", ts="2026-01-02T10:00:00Z")
        event.update(changes)
        return event

    def scope_and_text(self):
        old = self.label("label-old", "d1", "old", "OLD_ATTEMPT_TITLE")
        self.write_labels([old])
        event = self.event(label_ref=self.ref(old))
        self.check("wrong attempt rejects direct label", self.prepared([event])[-1]["task"] == "Role: reviews the diff")
        start = dict(event, type="delegation_start", attempt_id="old")
        terminal = {key: value for key, value in event.items() if key != "label_ref"}
        self.check("wrong attempt rejects cached start label", self.prepared([start, terminal])[-1]["task"] == "Role: reviews the diff")
        user = dict(old, source="explicit-user", label_id="user-old", text="OLD_USER_TITLE")
        self.write_labels([user])
        start["label_ref"] = self.ref(user)
        self.check("wrong attempt rejects cached user label", self.prepared([start, terminal])[-1]["task"] == "Role: reviews the diff")
        self.write_labels([old])
        self.check("matching scope resolves the saved label", self.prepared([dict(event, attempt_id="old")])[-1]["task"] == old["text"])
        self.check("wrong target rejects a valid label", self.prepared([dict(event, id="different", attempt_id="old")])[-1]["task"] == "Role: reviews the diff")
        wrong_project = copy.deepcopy(event)
        wrong_project["attempt_id"] = "old"
        wrong_project["label_ref"]["project_id"] = "p" + "b" * 64
        self.check("wrong project rejects a valid label", self.prepared([wrong_project])[-1]["task"] == "Role: reviews the diff")
        missing = copy.deepcopy(event)
        missing["attempt_id"] = "old"
        missing["label_ref"]["label_id"] = "missing-label"
        self.check("missing saved label falls back to the named mission", self.prepared([missing])[-1]["task"] == "Role: reviews the diff")
        self.store.chmod(0o644)
        try:
            task = self.prepared([dict(event, attempt_id="old")])[-1]["task"]
            self.check("unsafe label-store permissions fail closed", task == "Role: reviews the diff")
        finally:
            self.store.chmod(0o600)

        agent = "manual-native-agent"
        native = self.event(type="delegation_start", id="manual-native-turn", agent_id=agent,
                            bridge="codex-native", role="worker", agent_type="worker")
        native.pop("attempt_id")
        manual = self.label("manual-native-first", agent, agent, "Recover native work", kind="agent", source="explicit-user")
        self.write_labels([manual])
        recovered = self.prepared([native])[-1]
        self.check("explicit user label recovers native work without automatic refs",
                   recovered["task"] == manual["text"] and recovered["role"] == "worker")

        automatic = [self.label("auto-" + part, agent, agent, text, kind="agent", source=source)
                     for part, source, text in (("slug", "codex-path-slug", "automatic-slug"),
                                               ("nickname", "codex-nickname", "Atlas"),
                                               ("role", "codex-role", "worker"))]
        refs = {part: self.ref(label) for part, label in zip(("slug", "nickname", "role"), automatic)}
        with_refs = dict(native, label_ref=refs["slug"], label_refs=refs)
        self.write_labels(automatic)
        automatic_title = self.prepared([with_refs])[-1]["task"]
        latest = self.label("manual-native-latest", agent, agent, "Latest user title", kind="agent", source="explicit-user")
        latest["supersedes"] = manual["label_id"]
        self.write_labels([*automatic, manual, latest])
        self.check("latest explicit user label overrides a valid Codex three-ref title",
                   automatic_title == "Atlas worker automatic-slug" and self.prepared([with_refs])[-1]["task"] == latest["text"])

        unicode_label = self.label("label-unicode", "unicode", "unicode", "あ" * 80)
        self.write_labels([unicode_label])
        unicode_event = self.event(type="delegation_start", id="unicode", attempt_id="unicode", label_ref=self.ref(unicode_label))
        self.check("resolver preserves approved Unicode text", self.prepared([unicode_event])[-1]["task"] == unicode_label["text"])
        self.write_events([unicode_event])
        output = self.log("-n", "20")
        decoded = output.decode("utf-8", "strict")
        self.check("pretty shortening is valid UTF-8 in C locale", "あ" * 47 + "…" in decoded)
        punctuation = self.label("label-punctuation", "punctuation", "punctuation", 'Review "TLS" C:\\src\\file')
        self.write_labels([punctuation])
        self.write_events([self.event(type="delegation_start", id="punctuation", attempt_id="punctuation", label_ref=self.ref(punctuation))])
        output = self.log("-n", "20")
        self.check("pretty labels render literal quotes and backslashes", punctuation["text"].encode() in output, repr(output))

    def legacy_and_fallback(self):
        self.write_events([
            dict(type="delegation_start", id="legacy", ts="2026-01-02T10:00:00Z", role="reviewer", model="gpt-6-luna", task='Inspect "quoted" task \\ path | separator'),
            dict(type="delegation", id="legacy", ts="2026-01-02T10:00:01Z", role="reviewer", model="gpt-6-luna", task="old task", status="ok", outcome="done", duration_s=3),
            dict(type="advisor", ts="2026-01-02T10:00:02Z", model="claude-opus-5-5", calls=1, tokens_in=35648),
        ])
        actual = self.session_rows()
        self.check("legacy escaped-string rows retain exact bytes", actual == LEGACY_GOLDEN, repr(actual))
        self.write_events([
            dict(type="delegation_start", id="missing-role-start", ts="2026-01-02T10:00:00Z", model="gpt-6-luna", task="legacy task"),
            dict(type="delegation", id="empty-role-end", ts="2026-01-02T10:00:01Z", role="", model="gpt-6-luna", status="ok", duration_s=2),
        ])
        actual = self.session_rows()
        self.check("legacy empty and missing actors retain exact bytes", actual == EMPTY_ACTOR_GOLDEN, repr(actual))
        self.write_events([self.event(status="handed_over", outcome="unknown")])
        self.check("structural handover uses display wording", b"|handed over|" in self.session_rows())

        native = []
        for number, agent in enumerate(("agent-10000001", "agent-20000002"), 1):
            start = dict(type="delegation_start", id=f"native-{number}", agent_id=agent, bridge="codex-native",
                         content_policy="structural-v1", schema=2, owner_pid=os.getpid(), role="worker", tool="codex",
                         family="codex", session="native-owner", model="gpt-6-luna", ts="2026-01-02T10:00:00Z")
            native += [start, dict(start, type="delegation_activity", activity="running", ts="2026-01-02T10:00:01Z")]
        self.write_events(native)
        output = self.enhanced_rows()
        self.check("unavailable native context retains short identities", b"10000001" in output and b"20000002" in output and output.count(b"context unavailable") == 2)
        for row in native:
            row["agent_id"] = "agent-alpha-12345678" if row["id"] == "native-1" else "agent-beta-12345678"
        self.write_events(native)
        details = [line.split(b"|")[-1] for line in self.enhanced_rows().splitlines()]
        self.check("colliding native suffixes extend distinctly", len(details) == 2 and b"ha-12345678" in details[0] and b"ta-12345678" in details[1])

        self.write_events([self.event(task="PRIVATE_STRAY_TASK")], b'{"type":"delegation_start","task":"PRIVATE_PARTIAL')
        self.check("partial tail and stray structural prose stay private", b"PRIVATE_" not in self.session_rows())
        for role in ("worker", "unknown", "custom-role"):
            task = self.prepared([self.event(role=role, task="PRIVATE_STRAY_TASK")])[-1]["task"]
            self.check(role + " receives no invented mission", task == "context unavailable")

    @staticmethod
    def stop_group(process):
        # Only the new session owned by this probe is signalled. Always reap its
        # leader, including assertion/timeout paths; never inspect other groups.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            if sig == signal.SIGTERM:
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    continue
        process.wait(timeout=2)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream:
                stream.close()

    @staticmethod
    def receive_until(process, marker, timeout=3):
        data = b""
        deadline = time.monotonic() + timeout
        while marker not in data and time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            data += chunk
        return data

    def follow(self):
        command = ["bash", "-c", 'source "$1/scripts/lib/journal.sh"; ai_display_context_events "$2"', "_", str(self.repo), str(self.root)]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=self.env, start_new_session=True, bufsize=0)
        try:
            process.stdin.write(self.encoded([self.event()]))
            output = self.receive_until(process, b"\n")
            self.check("resolver emits a row while stdin remains open", b"Role: reviews the diff" in output and process.poll() is None)
        finally:
            self.stop_group(process)

        labels = [self.label("label-" + name, name, name, text) for name, text in
                  (("follow-ready", "Follow ready"), ("follow-live", "Follow live"), ("follow-after", "Follow after malformed"))]
        self.write_labels(labels)
        rows = [self.event(type="delegation_start", id=label["target_id"], attempt_id=label["attempt_id"], label_ref=self.ref(label)) for label in labels]
        self.write_events(rows[:1])
        with (self.base / "follow.stderr").open("wb") as errors:
            process = subprocess.Popen(["bash", str(self.repo / "scripts/loomy-log.sh"), "--root", str(self.root), "-n", "1", "--follow"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors,
                                       env=self.env, start_new_session=True, bufsize=0)
            try:
                ready = self.receive_until(process, b"Follow ready")
                if b"Follow ready" not in ready:
                    raise AssertionError("actual log follow did not become ready: " + repr(ready))
                with self.journal.open("ab") as journal:
                    journal.write(self.encoded(rows[1:2]))
                live = self.receive_until(process, b"Follow live")
                self.check("actual log follow emits appended input before shutdown", b"Follow live" in live and process.poll() is None, repr(live))
                with self.journal.open("ab") as journal:
                    journal.write(b'{"ts":"2026-01-02T10:00:00Z","type":"delegation_start","content_policy":"structural-v1","role":"reviewer","model":"gpt-6-luna","task":"PRIVATE_PARTIAL_TASK"\n')
                    journal.write(self.encoded(rows[2:]))
                after = self.receive_until(process, b"Follow after malformed")
                self.check("actual log follow drops malformed structural prose and recovers", b"Follow after malformed" in after and b"PRIVATE_PARTIAL_TASK" not in after, repr(after))
            finally:
                self.stop_group(process)

    def exports_and_stats(self):
        self.private_write(self.journal, RAW_GOLDEN)
        raw_before = self.log("--raw", "-n", "20")
        csv_before = self.log("--csv")
        self.check("P11 raw output matches exact golden bytes", raw_before == RAW_GOLDEN, repr(raw_before))
        self.check("P11 CSV output matches exact golden bytes", csv_before == CSV_GOLDEN, repr(csv_before))
        stats_command = ["bash", str(self.repo / "scripts/loomy-stats.sh"), "--root", str(self.root)]
        before = self.run(stats_command, ui=True)
        protected = (self.journal, self.store, self.logs / "content-policy.conf", self.root / ".loomy/project-id")
        snapshot = {path: (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns) for path in protected}
        self.prepared([json.loads(line) for line in RAW_GOLDEN.splitlines()])
        self.session_rows()
        self.enhanced_rows()
        self.log("-n", "20")
        self.check("P11 raw and CSV bytes survive display reads", self.log("--raw", "-n", "20") == RAW_GOLDEN and self.log("--csv") == CSV_GOLDEN)
        after = self.run(stats_command, ui=True)
        self.check("stats bytes and accounting stay unchanged after display reads", before == after and self.journal.read_bytes() == RAW_GOLDEN)
        self.check("display and stats preserve journal, labels, policy and identity", all(
            (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns) == snapshot[path] for path in protected))
        text = before.decode("utf-8")
        self.check("stats retain delegation, token and cost totals", bool(re.search(r"Delegations\s+1 · 100 % succeeded", text)) and
                   "6.2k in · 1.2k from cache · 800 out" in text and bool(re.search(r"API cost\s+\$0\.38", text)), text)

        # Status runs in the parent's read-only watch context, so it does not
        # poll native collectors. The executor role and switched mission share a row.
        self.write_events([self.event(id="switched", attempt_id="switched", role="executor", family="claude", tool="claude",
                                      bridge="claude", model="claude-haiku-5-5", failover_from="codex", tokens_in=0, tokens_out=0, cost_usd=0)])
        status = self.run(["bash", str(self.repo / "scripts/loomy-status.sh"), "--root", str(self.root)], ui=True).decode("utf-8")
        self.check("switched status retains executor and its named mission", bool(re.search(r"[Ee]xecutor[^\n]*⇄ Role: runs bounded tasks", status)), status)

    def finish(self):
        print(f"{self.passed} focused content display checks passed", flush=True)
        if self.failures:
            raise AssertionError(f"{len(self.failures)} focused display checks failed: " + ", ".join(self.failures))

    def request_heading(self):
        timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.write_events([
            dict(ts=timestamp, type="session", event="start", tool="claude", session="request-heading", pid=os.getpid()),
            dict(ts=timestamp, type="request", session="request-heading", id="r123-456",
                 content_policy="structural-v1", excerpt="PRIVATE_REQUEST_HEADING"),
            dict(ts=timestamp, type="delegation_start", session="request-heading", id="heading-worker", pid=os.getpid(),
                 bridge="subagent", tool="claude", family="claude", role="developer", model="claude-sonnet-5-5",
                 effort="high", content_policy="structural-v1"),
        ])
        output = self.run(["bash", str(self.repo / "scripts/loomy-tree.sh"), "--root", str(self.root), "--once"], ui=True).decode("utf-8")
        self.check("classic structural request heading retains id and named unavailability",
                   bool(re.search(r"^┌─ r123-456 · context unavailable", output, re.M)) and "PRIVATE_REQUEST_HEADING" not in output, output)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: content-display-check.py REPO WORK")
    repo = Path(sys.argv[1]).resolve(strict=True)
    work = Path(sys.argv[2]).resolve()
    if not repo.is_dir():
        raise SystemExit("REPO must be a directory")
    work.mkdir(mode=0o700, exist_ok=True)
    suite = DisplayChecks(repo, work)
    suite.scope_and_text()
    suite.legacy_and_fallback()
    suite.follow()
    suite.exports_and_stats()
    suite.request_heading()
    suite.finish()


if __name__ == "__main__":
    main()

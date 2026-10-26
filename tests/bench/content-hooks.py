#!/usr/bin/env python3
"""Paired main/current content-writer benchmark; no providers or /tmp artifacts."""
import argparse
import collections
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tarfile
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
SOURCES = "explicit-user,explicit-lead,claude-description,codex-path-slug,codex-nickname,codex-role"
HOOK = '''source "$BENCH_REPO/scripts/lib/journal.sh"
ai_detect_env() { AI_ENV=codex; AI_PROFILE=equilibre; }
ai_resolve() { R_MODEL=claude-sonnet-5-5; R_EFFORT=max; }
ai_role_writes() { return 1; }; ai_delegate_off_routing() { printf ''; }
AI_ROLES='reviewer developer'
ai_journal_agent_start "$BENCH_PROJECT" '{"session_id":"hook-session","tool_use_id":"call1","tool_input":{"subagent_type":"reviewer","description":"Display 0","prompt":"PRIVATE_PROMPT","run_in_background":true}}' 0
ai_journal_agent_stop "$BENCH_PROJECT" '{"session_id":"hook-session","agent_id":"agent1","agent_type":"reviewer"}' 0 'STATUS: partial'
ai_journal_agent_return "$BENCH_PROJECT" '{"session_id":"hook-session","tool_use_id":"call1","tool_response":{"agentId":"agent1"}}'
'''


def stats(values):
    return {"p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(sorted(values)[math.ceil(len(values) * .95) - 1], 3), "n": len(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="main")
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--labels", type=int, default=150)
    parser.add_argument("--output", type=Path, default=REPO / "tests/bench/content-hooks-results.json")
    args = parser.parse_args()
    if args.samples < 10 or args.labels < 1:
        parser.error("use >=10 samples and >=1 label")
    env = dict(os.environ, LOOMY_NATIVE_NOW="1791853207", LOOMY_FIXTURE_NOW="1791853200")
    for key in list(env):
        if key.startswith(("LOOMY_JOURNAL", "LOOMY_PARENT", "LOOMY_ATTEMPT", "LOOMY_CONTENT", "LOOMY_CLI")):
            env.pop(key)
    for key in ("LOOMY_DELEGATION", "LOOMY_FIXTURE_CONTENT", "PERL5OPT", "PERL5LIB", "BASH_ENV"):
        env.pop(key, None)
    revision = subprocess.check_output(["git", "rev-parse", args.baseline], cwd=REPO, text=True).strip()
    archive = subprocess.check_output(["git", "archive", revision, "scripts/lib", "scripts/loomy-context.sh", "tests/fixtures/claude-native.pl", "tests/fixtures/codex-native.pl"], cwd=REPO)
    defaults = subprocess.check_output(["perl", "-e", 'require $ARGV[0]; print JSON::PP::encode_json(Loomy::ContentPolicy::defaults())', str(REPO / "scripts/lib/content-policy.pl")], env=env, text=True)
    results, samples = {}, {}
    # All runtime inputs stay next to this script and are removed after the run.
    with tempfile.TemporaryDirectory(prefix=".content-bench-", dir=Path(__file__).parent) as temporary:
        work = Path(temporary)
        baseline = work / "baseline"
        baseline.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            source.extractall(baseline, filter="data")
        versions = {"main": baseline, "current": REPO}
        for grants in ("off", "recommended"):
            for case in ("claude", "codex", "hooks", "prompt"):
                root, sources = work / f"{case}-{grants}", work / f"{case}-{grants}-sources"
                logs = root / ".loomy/logs"
                logs.mkdir(parents=True, mode=0o700)
                if case in ("claude", "codex"):
                    fixture_args = ["app", "1"] if case == "claude" else [str(os.getpid())]
                    subprocess.run(["perl", str(baseline / f"tests/fixtures/{case}-native.pl"), "seed", str(root), str(sources), *fixture_args], env=env, check=True, stdout=subprocess.DEVNULL)
                if case == "prompt":
                    (root / ".loomy/brief.md").write_text("---\nai_mode: SOLO\nai_lead: codex\n---\n")
                os.chmod(logs, 0o700)
                policy = json.loads(defaults)
                policy.update(label_sources=SOURCES if grants == "recommended" else "none",
                              private_results="on" if grants == "recommended" else "off", grant_prompt_version=1)
                conf = logs / "content-policy.conf"
                conf.write_text("".join(f"{key}={policy[key]}\n" for key in sorted(policy)))
                conf.chmod(0o600)
                if grants == "recommended":
                    project_id = "p" + hashlib.sha256(os.fsencode(root)).hexdigest()
                    labels = []
                    for number in range(args.labels):
                        labels.append(dict(version=1, project_id=project_id, target_kind="delegation", target_id=f"old{number}", attempt_id="hook-session", label_id=f"l{number:032x}", text=f"Display {number}", source="claude-description", created_at="2026-10-13T01:00:00Z", supersedes=""))
                    store = logs / "display-context-v1.jsonl"
                    store.write_text("".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in labels))
                    store.chmod(0o600)
                saved = work / f"saved-{case}-{grants}"
                shutil.copytree(logs, saved)
                measured = {name: [] for name in versions}
                expected = None
                for trial in range(args.samples + 2):
                    order = list(versions)
                    if trial % 2:
                        order.reverse()
                    for name in order:
                        shutil.rmtree(logs)
                        shutil.copytree(saved, logs)
                        tested = versions[name]
                        command = ["/bin/bash", "-c", HOOK] if case == "hooks" else ["perl", str(tested / f"scripts/lib/{case}-native.pl"), str(root), str(sources)]
                        if case == "prompt":
                            command = ["/bin/bash", str(tested / "scripts/loomy-context.sh"), "--hook", "prompt", "--root", str(root)]
                        before = time.perf_counter()
                        subprocess.run(command, env=dict(env, BENCH_REPO=str(tested), BENCH_PROJECT=str(root)), check=True, stdout=subprocess.DEVNULL, input=b'{"session_id":"prompt-session","prompt":"PRIVATE_PROMPT"}' if case == "prompt" else None)
                        elapsed = (time.perf_counter() - before) * 1000
                        events = [json.loads(row) for row in (logs / "events.jsonl").read_text().splitlines()]
                        facts = (dict(collections.Counter(row["type"] for row in events)), sum(row.get("cost_usd", 0) or 0 for row in events))
                        if expected is None:
                            expected = facts
                        assert facts == expected, (case, grants, name, facts, expected)
                        assert facts[0].get("request" if case == "prompt" else "delegation_start", 0) > 0, "empty poll/hook"
                        if name == "current" and grants == "recommended" and case != "prompt":
                            assert any(row.get("label_ref") for row in events), "labels-on benchmark did not save/reference a label"
                            assert (logs / "display-context-v1.jsonl").stat().st_size > (saved / "display-context-v1.jsonl").stat().st_size, "label append was not measured"
                        if trial >= 2:
                            measured[name].append(elapsed)
                key = f"{case}/{grants}"
                results[key] = {name: stats(values) for name, values in measured.items()}
                results[key]["paired_delta_p95_ms"] = stats([a-b for a, b in zip(measured["current"], measured["main"])])["p95_ms"]
                samples[key] = measured
                print(json.dumps({key: results[key]}), flush=True)
    fingerprints = {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted((REPO / "scripts/lib").iterdir()) if p.name in {
                        "journal.sh", "live-state.pl", "content-policy.pl", "content-allowlist.tsv", "claude-native.pl", "codex-native.pl", "launch.sh", "failover.sh"}}
    fingerprints["scripts/loomy-context.sh"] = hashlib.sha256((REPO / "scripts/loomy-context.sh").read_bytes()).hexdigest()
    output = dict(current_sha256=fingerprints, baseline=revision, platform=platform.platform(), python=platform.python_version(), labels=args.labels, sources=SOURCES,
                  protocol="same source/log fixture; alternating main/current; 2 warmups then independent cold processes; all six grants on AND off; exact event counts/costs checked outside timing; no concurrent suites", results=results, samples_ms=samples)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    assert all(result["current"]["p95_ms"] <= 80 for key, result in results.items() if key.startswith(("claude/", "codex/"))), "cold poll exceeds 80 ms"


if __name__ == "__main__":
    main()

# Content writer latency

Run from the checkout, while no other test suite is running:

```sh
python3 tests/bench/content-hooks.py --samples 60 --labels 150 --output tests/bench/content-hooks-results.json
```

The script archives the local `main` revision using read-only Git operations.
Each main/current pair receives the same provider transcript, initial journal,
policy and label history. Processes are cold; filesystem caches are warm after
two excluded warmups. Pair order alternates. The three-hook case measures start,
stop and return together; the prompt case measures the real fast prompt hook separately. Native cases measure one complete poll.

Both policy configurations are measured: all six recommended label sources and
private results on, and both off. The enabled case asserts that actual events
carry label references and append a fresh label beyond the 150 historical records (except the prompt hook, which never captures a display label). Every sample also checks identical lifecycle counts and
cost totals against main, outside the timed interval. The baseline predates
content-policy support and therefore ignores its supplied grants/store.

All temporary fixtures are created under this directory and removed afterwards;
no `/tmp` snapshot or external provider is needed. The JSON report retains the
baseline commit, platform, configuration, every sample, p50 and p95. Cold polls
above 80 ms fail the command. Hook overhead is reported for review.

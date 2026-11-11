#!/usr/bin/env bash
# Private results/receipts: fixture grants only, isolated accounts, no real CLI.
# shellcheck disable=SC2016,SC1112  # child programs and literal French apostrophes
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-content-memory.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$HERE/lib/guard.sh"
# shellcheck source=lib/content-grant.sh
source "$HERE/lib/content-grant.sh"
for v in $(env | sed -nE 's/^((LOOMY|AI|DELEGATE|STUB)_[A-Z0-9_]*|CLAUDE_PROJECT_DIR|CODEX_HOME)=.*/\1/p'); do
  case "$v" in LOOMY_TEST_* ) continue ;; esac
  unset "$v"
done
mkdir -p "$WORK/home" "$WORK/config/loomy" "$WORK/codex/sessions"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export LOOMY_HOME="$REPO" LOOMY_CODEX_BIN="$HERE/stubs/codex" LOOMY_LANG=en LOOMY_UI_LANG=en
export NO_COLOR=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1 LOOMY_NO_REPAIR=1
# shellcheck source=../scripts/lib/models.sh
source "$REPO/scripts/lib/models.sh"
# shellcheck source=../scripts/lib/memory.sh
source "$REPO/scripts/lib/memory.sh"
PASS=0; FAIL=0; OUT="$WORK/out"
ok() { PASS=$((PASS+1)); printf 'ok %s\n' "$1"; }
check() { local title="$1"; shift; if "$@" >"$OUT" 2>&1; then ok "$title"; else FAIL=$((FAIL+1)); printf 'not ok %s\n' "$title"; cat "$OUT"; fi; }
project() {
  P="$WORK/$1"; mkdir -p "$P/.loomy/logs"; chmod 0755 "$P/.loomy"; chmod 0700 "$P/.loomy/logs"   # whatever the umask
  printf '%s\n' '---' 'ai_mode: SOLO' 'ai_lead: codex' 'budget: equilibre' 'delegation_format: structured' '---' >"$P/.loomy/brief.md"
}
policy() {
  # Reset only isolated test policy choices, then exercise real first-use Yes.
  rm -f "$P/.loomy/logs/content-policy.conf"
  test_content_grant "$REPO" "$P" "$@"
}
save() { _lm_save "$P" "$1" reviewer gpt-6-luna "${2:-ok}" "${3:-private task}" "${4:-SUMMARY: private summary
NEXT: private next}"; }
project off
save off >"$OUT" 2>&1
check 'off creates a receipt without text or private store' python3 - "$P" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy/memory'
r=json.loads((p/'receipts-v1/off.json').read_text())
allowed=set('version id attempt_id session_key role model effort sandbox status outcome started_at ended_at resume_at files_changed task_ref label_ref result_ref format review'.split())
assert set(r)<=allowed and r['session_key'] is None and not (p/'private-results-v1').exists()
assert 'private' not in json.dumps(r)
PY
check 'off digest states unavailable, without claiming a summary' bash -c 'source "$1/scripts/lib/memory.sh"; s=$(loomy_memory_digest "$2"); [[ "$s" == *"result not retained; consult authorized task artifact"* && "$s" != *"private summary"* ]]' _ "$REPO" "$P"
check 'off show presents receipt facts' bash -c 'source "$1/scripts/lib/memory.sh"; s=$(loomy_memory_show "$2" 1); [[ "$s" == *"result not retained; consult authorized task artifact"* && "$s" == *"off"* ]]' _ "$REPO" "$P"
save native-blocked ok task $'STATUS: blocked\nSUMMARY: do not accept\nFINDINGS:\n- none\nCHECKS:\n- none\nNEXT: ask for evidence'
check 'native review receipt preserves blocked/incomplete with capture off' python3 - "$P" <<'PYNATIVE'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy/memory'
r=json.loads((p/'receipts-v1/native-blocked.json').read_text())
assert (r['format'],r['outcome'],r['review'])==('structured','blocked','incomplete')
assert 'do not accept' not in json.dumps(r) and not (p/'private-results-v1').exists()
PYNATIVE
check 'off digest exposes native review verdict without retaining prose' bash -c 'source "$1/scripts/lib/memory.sh"; d=$(loomy_memory_digest "$2"); [[ "$d" == *"outcome=blocked"* && "$d" == *"review=incomplete"* && "$d" != *"do not accept"* ]]' _ "$REPO" "$P"
project on; policy
(umask 022; save first) >"$OUT" 2>&1
check '022 creates only 0700 directories and 0600 files' python3 - "$P" <<'PY'
from pathlib import Path
import stat, sys
p=Path(sys.argv[1])/'.loomy/memory'
for f in [p,*p.rglob('*')]: assert stat.S_IMODE(f.stat().st_mode)==(0o700 if f.is_dir() else 0o600), f
PY
check 'on digest and show resolve private body with stable ID and effort' bash -c 'source "$1/scripts/lib/memory.sh"; d=$(loomy_memory_digest "$2"); s=$(loomy_memory_show "$2"); [[ "$d" == *"first: private summary · next: private next"* && "$s" == *"private task"* && "$s" == *"private summary"* && "$s" == *"unknown"* ]]' _ "$REPO" "$P"
policy private_results=off
save declined
check 'turning off preserves prior authorized results and stops capture' python3 - "$P" <<'PY'
from pathlib import Path
import json, sys
p=Path(sys.argv[1])/'.loomy/memory'
assert (p/'private-results-v1/first.json').exists()
assert not (p/'private-results-v1/declined.json').exists()
assert 'result_ref' not in json.loads((p/'receipts-v1/declined.json').read_text())
PY
policy
LOOMY_JOURNAL_TASKS=0 save veto
check 'TASKS=0 vetoes capture despite grant' test ! -f "$P/.loomy/memory/private-results-v1/veto.json"
check 'STATE mtime dedupe and rank/show share newest-first order' bash -c 'source "$1/scripts/lib/memory.sh"; d="$2/.loomy/memory"; printf "# Work state\n" >"$d/STATE.md"; touch -t 209901010000 "$d/STATE.md"; [[ -z "$(loomy_memory_digest "$2" 10 new)" ]]; [[ "$(loomy_memory_show "$2" 1)" == *"veto"* ]]; [[ "$(loomy_memory_digest "$2" 1)" == *"veto"* ]]' _ "$REPO" "$P"
mkdir "$P/.loomy/memory/delegations"; chmod 0755 "$P/.loomy/memory/delegations"
printf '# legacy sensitive\nlegacy task\n' >"$P/.loomy/memory/delegations/old.md"
chmod 644 "$P/.loomy/memory/delegations/old.md"
cp -p "$P/.loomy/memory/delegations/old.md" "$WORK/legacy-before"
save after-legacy
check 'legacy is separate and remains byte/mode/mtime identical' python3 - "$P" "$WORK/legacy-before" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])/'.loomy/memory/delegations/old.md'; q=Path(sys.argv[2])
assert p.read_bytes()==q.read_bytes() and p.stat().st_mode==q.stat().st_mode and p.stat().st_mtime_ns==q.stat().st_mtime_ns
PY
check 'legacy full result remains explicitly readable' bash -c 'source "$1/scripts/lib/memory.sh"; [[ "$(loomy_memory_legacy "$2" 1)" == *"legacy task"* ]]; [[ "$(loomy_memory_digest "$2")" != *"legacy task"* ]]' _ "$REPO" "$P"
check 'memory UI separates older sensitive results' bash -c 's=$(bash "$1/scripts/loomy-memory.sh" --root "$2" 2>&1); [[ "$s" == *"older sensitive results"* && "$s" == *"Private results: enabled"* && "$s" == *"show legacy"* ]]' _ "$REPO" "$P"
project limits; policy results_max_records=2
save pinned paused; save terminal
save replacement >"$OUT" 2>&1
check 'count cap evicts only completed new records, never paused pins' bash -c 'd="$1/.loomy/memory/private-results-v1"; [[ -f "$d/pinned.json" && -f "$d/replacement.json" && ! -e "$d/terminal.json" ]]' _ "$P"
save active running
save refused >"$OUT" 2>&1
check 'all-pinned store refuses visibly without silent eviction' bash -c 'd="$1/.loomy/memory/private-results-v1"; [[ -f "$d/pinned.json" && -f "$d/active.json" && ! -f "$d/refused.json" ]]' _ "$P"
# Re-run to inspect refusal text without check() replacing the captured output.
refusal="$(save refused 2>&1)"
check 'full refusal exposes original-task requirement and actionable retry' bash -c '[[ "$1" == *"result not saved / original task required"* && "$1" == *"loomy memory show N"* && "$1" == *"then retry"* ]]' _ "$refusal"
project size; policy results_max_record_bytes=512
big="$(printf '%01000d' 0)"; refusal="$(save oversize ok task "$big" 2>&1)"
check 'oversize refuses whole result, never truncates' bash -c '[[ "$1" == *"result not saved / original task required"* && ! -e "$2/.loomy/memory/private-results-v1/oversize.json" && -f "$2/.loomy/memory/receipts-v1/oversize.json" ]]' _ "$refusal" "$P"
project bytes; policy results_max_total_bytes=750
save first paused; save second paused
refusal="$(save third 2>&1)"
check 'total byte cap protects pinned records' python3 - "$P" "$refusal" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])/'.loomy/memory/private-results-v1'
assert sum(f.stat().st_size for f in p.glob('[!.]*.json'))<=750
assert not (p/'third.json').exists() and 'result not saved' in sys.argv[2]
PY
project age; policy results_max_age_days=1
save old; save pin paused
python3 - "$P" <<'PY'
import json, pathlib, sys, time
p=pathlib.Path(sys.argv[1])/'.loomy/memory/private-results-v1'
for f in p.glob('[!.]*.json'):
 r=json.loads(f.read_text()); r['saved_at']=int(time.time())-2*86400; f.write_text(json.dumps(r))
 import os; os.utime(f,(r['saved_at'],r['saved_at']))
PY
save fresh
check 'age retention prunes only new unpinned records' bash -c 'd="$1/.loomy/memory/private-results-v1"; [[ ! -e "$d/old.json" && -f "$d/pin.json" && -f "$d/fresh.json" ]]' _ "$P"
project unsafe; policy
mkdir -p "$P/.loomy/memory" "$WORK/outside"; chmod 0755 "$P/.loomy/memory"
ln -s "$WORK/outside" "$P/.loomy/memory/private-results-v1"
refusal="$(save denied 2>&1)"
check 'symlink store is refused, target unchanged, receipt retained' bash -c '[[ -z "$(ls -A "$1")" && "$2" == *"result not saved"* && -f "$3/.loomy/memory/receipts-v1/denied.json" ]]' _ "$WORK/outside" "$refusal" "$P"
project hardlink; policy
save original
ln "$P/.loomy/memory/private-results-v1/original.json" "$WORK/hardlink"
refusal="$(save denied 2>&1)"
check 'hardlink store member is refused without changing historical target' bash -c '[[ "$1" == *"result not saved"* && ! -f "$2/.loomy/memory/private-results-v1/denied.json" ]]' _ "$refusal" "$P"
project readonly; policy
mkdir -p "$P/.loomy/memory/receipts-v1"; chmod 700 "$P/.loomy/memory/receipts-v1"
ln -s /dev/full "$P/.loomy/memory/receipts-v1/denied.json"
refusal="$(save denied 2>&1)"
check 'unsafe/disk-error receipt failure is visible, never propagated to caller' test "$refusal" != ''
project concurrency; policy results_max_records=2
for i in 1 2 3 4; do save "c$i" paused >"$WORK/c$i" 2>&1 & done
wait
check 'concurrent saves honor pin/count caps under shared policy lock' python3 - "$P" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy/memory'
assert len(list((p/'private-results-v1').glob('[!.]*.json')))==2
assert len(list((p/'receipts-v1').glob('[!.]*.json')))==4
PY
# Fill real hard ceilings without 200 provider/process calls.
for cap in count total; do
  project "hard-$cap"; policy
  python3 - "$P" "$cap" <<'PYHARD'
import hashlib, json, pathlib, sys, time
p=pathlib.Path(sys.argv[1]); cap=sys.argv[2]
d=p/'.loomy/memory/private-results-v1'; d.mkdir(parents=True, mode=0o700); d.parent.chmod(0o700)
project_id='p'+hashlib.sha256(str(p.resolve()).encode()).hexdigest()
for i in range(200 if cap=='count' else 16):
 r=dict(version=1, project_id=project_id, id=f'pin{i}', attempt_id=f'pin{i}', saved_at=int(time.time()), status='paused', task='task', result='', resume=None)
 raw=lambda: json.dumps(r, separators=(',', ':'), sort_keys=True).encode()+b'\n'
 if cap=='total': r['result']='x'*(1048576-len(raw()))
 f=d/f'pin{i}.json'; f.write_bytes(raw()); f.chmod(0o600)
PYHARD
  refusal="$(save refused 2>&1)"
  check "default $cap hard limit refuses without evicting pins" python3 - "$P" "$cap" "$refusal" <<'PYHARD'
import pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy/memory/private-results-v1'; cap=sys.argv[2]
fs=list(p.glob('[!.]*.json'))
assert len(fs)==(200 if cap=='count' else 16)
assert 'result not saved / original task required' in sys.argv[3]
assert all(f.stat().st_size<=1048576 for f in fs)
assert sum(f.stat().st_size for f in fs)<=16777216
if cap=='total': assert sum(f.stat().st_size for f in fs)==16777216
PYHARD
done
project hard-record; policy
big="$(python3 -c 'print("x"*1048577,end="")')"
refusal="$(save refused ok task "$big" 2>&1)"
check '1 MiB overflow drains input and retains final receipt, never a truncated body' bash -c '[[ "$1" == *"result not saved / original task required"* && -f "$2/.loomy/memory/receipts-v1/refused.json" && ! -e "$2/.loomy/memory/private-results-v1/refused.json" ]]' _ "$refusal" "$P"
project unicode; policy
save unicode ok 'Tâche 日本語' $'SUMMARY: Résultat 日本語 👩🏽‍💻\nNEXT: vérifier' >"$OUT" 2>&1
check 'private UTF-8 text survives display with Cf stripped' bash -c 'source "$1/scripts/lib/memory.sh"; [[ "$(loomy_memory_digest "$2")" == *"Résultat 日本語 👩🏽💻"* && "$(loomy_memory_show "$2")" == *"Tâche 日本語"* ]]' _ "$REPO" "$P"
project bridge; policy
export STUB_LOG="$WORK/calls"
(cd "$P" && bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer --task-label 'Review receipts' --model gpt-6.1-sol --effort high --read-only --why 'exact options' 'original live task') >"$OUT" 2>&1
check 'bridge label refs match receipts/events; descriptor keeps exact effective options' python3 - "$P" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy'
rs=[json.loads(f.read_text()) for f in (p/'memory/receipts-v1').glob('[!.]*.json')]; assert len(rs)==1
r=rs[0]; b=json.loads((p/f'memory/private-results-v1/{r["id"]}.json').read_text())
d=b['resume']; assert (d['role'],d['provider'],d['model'],d['effort'],d['sandbox'])==('reviewer','codex','gpt-6.1-sol','high','read-only')
assert d['options']['why']=='exact options' and d['options']['task_label']=='Review receipts'
label=json.loads((p/'logs/display-context-v1.jsonl').read_text())
assert label['source']=='explicit-lead' and label['text']=='Review receipts'
events=[json.loads(x) for x in (p/'logs/events.jsonl').read_text().splitlines()]
assert len([e for e in events if e['type']=='delegation'])==1
for e in events:
 if e['type'] in ('delegation','delegation_start'): assert e['label_ref']==r['label_ref']
assert r['outcome']=='partial' and r['format']=='structured'
assert 'Resume:' not in json.dumps(b)
PY
for family in codex claude; do
  project "error-$family"; policy
  if [[ "$family" == codex ]]; then
    (cd "$P" && STUB_FAIL=1 bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer 'same error task') >"$OUT" 2>&1
  else
    (cd "$P" && STUB_CLAUDE_RESULT_ERROR='fixture error' STUB_CLAUDE_ERROR_EXIT=7 bash "$REPO/scripts/loomy-delegate-claude.sh" reviewer 'same error task') >"$OUT" 2>&1
  fi
  code=$?; want=1; [[ "$family" != claude ]] || want=7
  check "$family failure preserves provider exit code" test "$code" -eq "$want"
  check "$family failure persists one terminal error receipt" python3 - "$P" <<'PYERROR'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy/memory/receipts-v1'
r=[json.loads(f.read_text()) for f in p.glob('[!.]*.json')]
assert len(r)==1 and r[0]['status']=='error'
PYERROR
done
project bridge-unicode; policy
(cd "$P" && bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer --task-label 'Révision 日本語' --why 'demandé 日本語' 'Tâche 日本語') >"$OUT" 2>&1
check 'bridge UTF-8 label/options survive the structured stdin handoff' python3 - "$P" <<'PYUNICODE'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy'
b=[json.loads(f.read_text()) for f in (p/'memory/private-results-v1').glob('[!.]*.json')]
assert len(b)==1 and b[0]['task']=='Tâche 日本語'
assert b[0]['resume']['options']['task_label']=='Révision 日本語'
assert b[0]['resume']['options']['why']=='demandé 日本語'
assert json.loads((p/'logs/display-context-v1.jsonl').read_text())['text']=='Révision 日本語'
PYUNICODE
cat >"$WORK/result.txt" <<'RESULT'
STATUS: done
SUMMARY: exact result canary
FINDINGS:
- none
TRIED:
- inspected the fixture
FILES:
- none
CHECKS:
- `true` — passed
RISKS:
- none
NEXT: integrate
RESULT
for family in codex claude; do
  project "success-$family"; policy
  : >"$STUB_LOG"
  (cd "$P" && STUB_RESULT_FILE="$WORK/result.txt" bash "$REPO/scripts/loomy-delegate-$family.sh" reviewer --task-label 'Explicit title' 'private task canary') >"$WORK/result-$family.out" 2>"$OUT"
  code=$?
  check "$family success preserves result bytes, usage and closed receipt metadata" python3 - "$P" "$family" "$WORK/result-$family.out" "$WORK/result.txt" "$code" "$STUB_LOG" <<'PYSUCCESS'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy'; family=sys.argv[2]
assert sys.argv[5]=='0'
returned=pathlib.Path(sys.argv[3]).read_text()
if family=='claude': returned=json.loads(returned)['result']
assert returned.rstrip()==pathlib.Path(sys.argv[4]).read_text().rstrip()
events=[json.loads(x) for x in (p/'logs/events.jsonl').read_text().splitlines()]
ends=[e for e in events if e['type']=='delegation']; assert len(ends)==1
r=[json.loads(f.read_text()) for f in (p/'memory/receipts-v1').glob('[!.]*.json')]; assert len(r)==1
assert (r[0]['format'],r[0]['outcome'],r[0]['review'])==(ends[0]['format'],ends[0]['outcome'],ends[0].get('review','unknown'))
assert 'private task canary' not in json.dumps(r) and 'exact result canary' not in json.dumps(r)
assert ends[0]['tokens_in']==(1000 if family=='codex' else 200)
assert ends[0]['tokens_cached']==(400 if family=='codex' else 80)
assert ends[0]['tokens_out']==(200 if family=='codex' else 40)
assert '--task-label' not in pathlib.Path(sys.argv[6]).read_text()
PYSUCCESS
done
project label-off; policy label_sources=none
(cd "$P" && bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer --task-label 'Not granted' 'never infer this task title') >"$OUT" 2>&1
check 'explicit title without its source grant is not saved or inferred' python3 - "$P" <<'PYOFF'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])/'.loomy'
assert not (p/'logs/display-context-v1.jsonl').exists()
for f in (p/'memory/receipts-v1').glob('[!.]*.json'): assert 'label_ref' not in json.loads(f.read_text())
for f in (p/'memory/private-results-v1').glob('[!.]*.json'): assert json.loads(f.read_text())['resume']['options']['task_label']==''
PYOFF
# The pause finalizer must resolve policy again, not use a start-time cached grant.
project revoked; policy
check 'pause after policy revocation saves no new task/result and reports unavailable' bash -c '
 source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/memory.sh"; source "$1/scripts/lib/usage.sh"
 ROOT="$2"; DELEG_ID=revoked; ROLE=reviewer; MODEL=gpt-6.1-sol; EFFORT=high; SANDBOX=read-only; STARTED=1
 TASK="new sensitive task"; RESUME_DESCRIPTOR=""; LABEL_JSON=""; FORMAT_JSON=""
 perl -pi -e "s/private_results=on/private_results=off/" "$ROOT/.loomy/logs/content-policy.conf"
 msg=$(ai_delegate_memory_record paused "new sensitive result" 123 2>&1)
 [[ "$msg" == *"original task required to resume"* && ! -e "$ROOT/.loomy/memory/private-results-v1" ]]
' _ "$REPO" "$P"
project retained-task; policy
check 'revoking capture preserves an earlier authorized task without claiming a new result' bash -c '
 source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/memory.sh"; source "$1/scripts/lib/usage.sh"
 ROOT="$2"; DELEG_ID=retained; ROLE=reviewer; MODEL=gpt-6.1-sol; EFFORT=high; SANDBOX=read-only; STARTED=1
 TASK="authorized original task"; LABEL_JSON=""; FORMAT_JSON=""
 RESUME_DESCRIPTOR=$(printf "%s\0" "$ROLE" codex "$MODEL" "$EFFORT" "$SANDBOX" equilibre why label "" "" | _lm_backend descriptor "$ROOT")
 ai_delegate_memory_record running
 cp -p "$ROOT/.loomy/memory/private-results-v1/retained.json" "$ROOT/body-before"
 perl -pi -e "s/private_results=on/private_results=off/" "$ROOT/.loomy/logs/content-policy.conf"
 ai_delegate_memory_record paused "new result must not be captured" 123
 cmp "$ROOT/body-before" "$ROOT/.loomy/memory/private-results-v1/retained.json" || exit 1
 text=$(loomy_memory_show "$ROOT")
 [[ "$text" == *"authorized original task"* && "$text" == *"Resume descriptor"* && "$text" != *"new result must not be captured"* && -n "$MEMORY_RESULT_REF" ]]
' _ "$REPO" "$P"
# Hidden files and interrupted atomic writers must not poison either store.
project hidden; policy
save seed
python3 - "$P" <<'PYHIDDEN'
from pathlib import Path
import os, sys, time
p=Path(sys.argv[1])/'.loomy/memory'
for store in ('receipts-v1','private-results-v1'):
 d=p/store
 for name in ('.DS_Store','.seed.json.999999-aa','.seed.json.999999-bb','.unrelated'):
  f=d/name; f.write_text('ignored'); f.chmod(0o600)
  if name.endswith('-aa') or name=='.unrelated': os.utime(f,(time.time()-601,)*2)
PYHIDDEN
check 'dotfiles and atomic scratch do not break count/digest/show' bash -c 'source "$1/scripts/lib/memory.sh"; [[ $(loomy_memory_count "$2") == 1 ]]; loomy_memory_digest "$2"; loomy_memory_show "$2"' _ "$REPO" "$P"
check 'unlocked readers leave stale scratch untouched' test -f "$P/.loomy/memory/receipts-v1/.seed.json.999999-aa"
save next
check 'locked writers reap only own private stale scratch in both stores' python3 - "$P" <<'PYHIDDEN'
from pathlib import Path
import sys
for store in ('receipts-v1','private-results-v1'):
 d=Path(sys.argv[1])/'.loomy/memory'/store
 assert not (d/'.seed.json.999999-aa').exists()
 assert (d/'.seed.json.999999-bb').exists() and (d/'.DS_Store').exists() and (d/'.unrelated').exists()
PYHIDDEN
# Valid references from another project are unavailable, never a fatal identity error.
project scope; policy
save scoped
python3 - "$P" <<'PYSCOPE'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])/'.loomy/memory'
f=p/'private-results-v1/scoped.json'; v=json.loads(f.read_text()); v['project_id']='p'+'f'*64; f.write_text(json.dumps(v))
PYSCOPE
check 'foreign body is shown as unavailable without aborting' bash -c 'source "$1/scripts/lib/memory.sh"; [[ $(loomy_memory_show "$2") == *"result not retained"* ]]; [[ $(loomy_memory_count "$2") == 1 ]]' _ "$REPO" "$P"
python3 - "$P" <<'PYSCOPE'
from pathlib import Path
import json,sys
f=Path(sys.argv[1])/'.loomy/memory/receipts-v1/scoped.json'; v=json.loads(f.read_text()); v['result_ref']['project_id']='p'+'f'*64; f.write_text(json.dumps(v))
PYSCOPE
check 'foreign receipt is skipped by count/digest' bash -c 'source "$1/scripts/lib/memory.sh"; [[ $(loomy_memory_count "$2") == 0 && -z $(loomy_memory_digest "$2") ]]' _ "$REPO" "$P"
check 'out-of-scope-only memory show reports unavailable, rather than no results' bash -c 's=$(LOOMY_LANG=en LOOMY_UI_LANG=en bash "$1/scripts/loomy-memory.sh" --root "$2" show); [[ "$s" == *"result not retained"* && "$s" != *"No delegation result yet"* ]]' _ "$REPO" "$P"
save local
check 'foreign row never prevents a new local save' test -f "$P/.loomy/memory/private-results-v1/local.json"
# SUMMARY/NEXT rendering strips terminal and Unicode controls; storage stays full.
project controls; policy
poison=$'SUMMARY: safe\r\033[31m red\033[0m\302\205\342\200\256\342\200\250 wrapped  text\nNEXT: next\033]0;spoof\007\t  action\nFILES:\n- untouched'
save controls ok task "$poison"
check 'digest and show sanitize SUMMARY/NEXT without changing the saved full result' bash -c 'source "$1/scripts/lib/memory.sh"; loomy_memory_digest "$2" >"$3"; loomy_memory_show "$2" >"$4"' _ "$REPO" "$P" "$WORK/digest-safe" "$WORK/show-safe"
check 'Cc/Cf/ANSI/bidi/separators cannot forge display lines' python3 - "$P" "$WORK/digest-safe" "$WORK/show-safe" <<'PYCONTROL'
from pathlib import Path
import json,sys,unicodedata
for f in sys.argv[2:]:
 s=Path(f).read_text()
 assert 'safe red wrapped text' in s and 'next action' in s and 'spoof' not in s
 assert not any(unicodedata.category(c) in ('Cc','Cf') for c in s if c!='\n')
 assert '\u2028' not in s and '\u2029' not in s
raw=json.loads((Path(sys.argv[1])/'.loomy/memory/private-results-v1/controls.json').read_text())['result']
assert '\x1b' in raw and '\u202e' in raw and 'FILES:\n- untouched' in raw
PYCONTROL
# Stateful receipts through the same API used by bridges, with a real descriptor.
state_save() {
  local id="$1" state="$2" pid="$3" start="$4" reset="$5" task_ref="${6:-}"
  local metadata descriptor
  descriptor="$(printf '%s\0' reviewer codex gpt-6.1-sol high read-only equilibre why label '' '' | _lm_backend descriptor "$P")"
  metadata="$(printf '%s\0' "$id" "$state" "$start" "$reset" "$task_ref" | perl -MJSON::PP -0777 -ne '
    my ($id,$status,$start,$reset,$ref)=split /\0/;
    my $r={version=>1,id=>$id,attempt_id=>$id,session_key=>undef,role=>"reviewer",model=>"gpt-6.1-sol",effort=>"high",sandbox=>"read-only",
      status=>$status,outcome=>($status eq "paused" ? "waiting_for_reset" : "unknown"),started_at=>0+$start,ended_at=>0,resume_at=>0+$reset,
      files_changed=>0,format=>"unknown",review=>"unknown"};
    $r->{task_ref}=decode_json($ref) if length($ref//""); print encode_json($r);')"
  printf '%s\0' "$metadata" 'original state task' '' "$descriptor" | _lm_backend save "$P" "$pid"
}
for expired in dead age paused; do
  project "pin-$expired"; policy results_max_records=1
  now="$(date +%s)"; started="$now"; resume="$now"; owner="$$"; state=running
  case "$expired" in
    dead) owner=99999999 ;;
    age) started=$((now-86401)) ;;
    paused) state=paused; resume=$((now-30*86400-1)) ;;
  esac
  state_save old "$state" "$owner" "$started" "$resume" >"$OUT" 2>&1
  save replacement
  check "$expired pin expires and frees a full store" bash -c 'd="$1/.loomy/memory/private-results-v1"; [[ -f "$d/replacement.json" && ! -e "$d/old.json" ]]' _ "$P"
done
project live-pin; policy results_max_records=1
state_save active running "$$" "$(date +%s)" 0 >"$OUT" 2>&1
refusal="$(save denied 2>&1)"
check 'living running owner stays pinned before 24 hours' bash -c 'd="$1/.loomy/memory/private-results-v1"; [[ -f "$d/active.json" && ! -e "$d/denied.json" && "$2" == *"store full"* ]]' _ "$P" "$refusal"
project superseded; policy results_max_records=1
now="$(date +%s)"
state_save paused paused "$$" "$now" "$((now+3600))" >"$OUT" 2>&1
old_ref="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["result_ref"]))' "$P/.loomy/memory/receipts-v1/paused.json")"
bad_ref="$(printf '%s' "$old_ref" | python3 -c 'import json,sys; r=json.load(sys.stdin); r["attempt_id"]="other-attempt"; print(json.dumps(r))')"
check 'task_ref cannot supersede a different attempt' bash -c 'source "$1/scripts/lib/memory.sh"; ! { printf "%s\0" "$3" | _lm_backend task-ref "$2"; }' _ "$REPO" "$P" "$bad_ref"
state_save relaunched running "$$" "$now" 0 "$old_ref" >"$OUT" 2>&1
check 'task_ref relaunch supersedes and unpins the previous paused record' python3 - "$P" <<'PYPIN'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])/'.loomy/memory'
assert not (p/'private-results-v1/paused.json').exists() and (p/'private-results-v1/relaunched.json').exists()
assert json.loads((p/'receipts-v1/relaunched.json').read_text())['task_ref']['target_id']=='paused'
PYPIN
# A real bridge can carry the old typed task reference into its new receipt.
project relaunch-bridge; policy results_max_records=2
now="$(date +%s)"
state_save paused paused "$$" "$now" "$((now+3600))" >"$OUT" 2>&1
old_ref="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["result_ref"]))' "$P/.loomy/memory/receipts-v1/paused.json")"
(cd "$P" && LOOMY_TASK_REF="$old_ref" bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer 'resumed original task') >"$OUT" 2>&1
check 'real bridge relaunch marks the old task superseded and links its new receipt' python3 - "$P" <<'PYRELAUNCH'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])/'.loomy'
m=json.loads((p/'memory/private-results-v1/.retention-v1.json').read_text())['records']
new=m['paused']['superseded_by']; assert new and new!='paused'
r=json.loads((p/f'memory/receipts-v1/{new}.json').read_text()); assert r['task_ref']['target_id']=='paused'
for e in map(json.loads,(p/'logs/events.jsonl').read_text().splitlines()):
 if e['type'] in ('delegation_start','delegation'): assert e['task_ref']==r['task_ref']
PYRELAUNCH
project repeated-pause; policy results_max_records=1
now="$(date +%s)"; previous_ref=''
for i in 1 2 3 4; do
  state_save "pause$i" paused "$$" "$now" "$((now+3600))" "$previous_ref" >"$OUT" 2>&1
  previous_ref="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["result_ref"]))' "$P/.loomy/memory/receipts-v1/pause$i.json")"
done
check 'repeated paused relaunches free superseded pins instead of filling the store' python3 - "$P" <<'PYREPEATED'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])/'.loomy/memory'
assert [f.name for f in (p/'private-results-v1').glob('[!.]*.json')]==['pause4.json']
assert len(list((p/'receipts-v1').glob('[!.]*.json')))==4
PYREPEATED
project statuses; policy
now="$(date +%s)"
state_save paused paused "$$" "$now" "$((now+3600))" >"$OUT" 2>&1
state_save active running "$$" "$now" 0 >"$OUT" 2>&1
check 'digest keeps meaningful running/paused summaries and absolute show rank' bash -c 'source "$1/scripts/lib/memory.sh"; d=$(loomy_memory_digest "$2"); [[ "$d" == *"active: running"* && "$d" == *"paused until"* && "$d" == *"resumable: loomy memory show 2"* ]]' _ "$REPO" "$P"
# A legacy-only upgrader gets an actionable read command.
project legacy-only
mkdir -p "$P/.loomy/memory/delegations"; chmod 0755 "$P/.loomy/memory" "$P/.loomy/memory/delegations"
printf 'old full result\n' >"$P/.loomy/memory/delegations/old.md"
check 'legacy-only show points to legacy command' bash -c 's=$(bash "$1/scripts/loomy-memory.sh" --root "$2" show); [[ "$s" == *"loomy memory show legacy"* && "$s" != *"No delegation result yet"* ]]' _ "$REPO" "$P"
# Invalid environment descriptors are rejected, rather than trusted as options.
project descriptors; policy
valid="$(printf '%s\0' reviewer codex gpt-6.1-sol high read-only equilibre why '' '' '' | _lm_backend descriptor "$P")"
check 'matching environment descriptor is accepted' bash -c 'source "$1/scripts/lib/memory.sh"; printf "%s\0" "$3" reviewer codex | _lm_backend descriptor-env "$2"' _ "$REPO" "$P" "$valid"
for invalid in role provider sandbox effort label; do
  bad="$(printf '%s' "$valid" | python3 -c 'import json,sys; d=json.load(sys.stdin); k=sys.argv[1]; value={"role":"developer","provider":"claude","sandbox":"danger-full-access","effort":"unknown"}; d["options"]["task_label"]="raw\x1b[31m" if k=="label" else d["options"]["task_label"]; d.update({k:value[k]} if k in value else {}); print(json.dumps(d))' "$invalid")"
  check "invalid $invalid descriptor is rejected" bash -c 'source "$1/scripts/lib/memory.sh"; ! { printf "%s\0" "$3" reviewer codex | _lm_backend descriptor-env "$2"; }' _ "$REPO" "$P" "$bad"
done
project domains; policy
_lm_save "$P" native-debugger debugger 'local/model:revision' error task result >"$OUT" 2>&1
check 'T2 domains preserve native debugger and prefixed local model' python3 - "$P" <<'PYDOMAIN'
from pathlib import Path
import json,sys
r=json.loads((Path(sys.argv[1])/'.loomy/memory/receipts-v1/native-debugger.json').read_text())
assert (r['role'],r['model'],r['status'])==('debugger','local/model:revision','error')
PYDOMAIN
check 'T2 role domain accepts the real debugger bridge descriptor' bash -c 'source "$1/scripts/lib/memory.sh"; printf "%s\0" debugger claude claude-opus-5-5 high read-only equilibre why "" 8 strict | _lm_backend descriptor "$2"' _ "$REPO" "$P"
# Non-ASCII --why is bounded by characters even with a byte-oriented locale.
project long-why; policy
why="$(python3 -c 'print("日本語"*100,end="")')"
(cd "$P" && LC_ALL=C bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer --why "$why" 'unicode reason') >"$OUT" 2>&1
check 'LC_ALL=C long reason retains 200 complete Unicode characters' python3 - "$P" <<'PYWHY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])/'.loomy/memory/private-results-v1'
b=[json.loads(f.read_text()) for f in p.glob('[!.]*.json')]; assert len(b)==1
assert b[0]['resume']['options']['why']==('日本語'*100)[:200]
PYWHY
# Check capture-off messages in both locales, alongside the immutable receipt.
for lang in en fr; do
  project "degraded-$lang"
  state_save unavailable paused "$$" "$(date +%s)" "$(( $(date +%s)+3600 ))" >"$OUT" 2>&1
  check "$lang capture off keeps receipts, original-task requirement and label hint" bash -c '
    s=$(LOOMY_LANG="$3" LOOMY_UI_LANG="$3" bash "$1/scripts/loomy-memory.sh" --root "$2" 2>&1);
    f=$(LOOMY_LANG="$3" LOOMY_UI_LANG="$3" bash "$1/scripts/loomy-memory.sh" --root "$2" show);
    [[ -f "$2/.loomy/memory/receipts-v1/unavailable.json" && ! -d "$2/.loomy/memory/private-results-v1" ]] || exit 1
    [[ "$s" == *"loomy privacy labels recommended"* && "$s" == *"loomy memory show"* ]] || exit 1
    if [[ "$3" == en ]]; then [[ "$s" == *"receipts available"* && "$f" == *"original task required to resume"* ]]
    else [[ "$s" == *"reçus disponibles"* && "$f" == *"tâche d’origine nécessaire"* ]]; fi
  ' _ "$REPO" "$P" "$lang"
done
project notice
(cd "$P" && bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer --task-label 'No permission' 'notice fixture') >"$WORK/notice-pipe" 2>&1
check 'ungranted label is quiet without a terminal' bash -c '! grep -qE "label not recorded|Content operation failed|privacy labels" "$1"' _ "$WORK/notice-pipe"
check 'ungranted label gets one calm terminal notice per bridge run' python3 - "$REPO" "$P" <<'PYNOTICE'
import os, pathlib, pty, subprocess, sys
master,slave=pty.openpty()
p=subprocess.Popen(['bash',sys.argv[1]+'/scripts/loomy-delegate-codex.sh','reviewer','--task-label','No permission','notice fixture'],cwd=sys.argv[2],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=slave)
os.close(slave); output=b''
while True:
 try: chunk=os.read(master,65536)
 except OSError: break
 if not chunk: break
 output+=chunk
os.close(master); assert p.wait()==0
s=output.decode(); assert s.count('label not recorded (explicit-lead not granted)')==1,s
assert 'Content operation failed' not in s and 'privacy labels' not in s
PYNOTICE
check 'French bridge help translates task-label line' bash -c 's=$(LOOMY_LANG=fr LOOMY_UI_LANG=fr bash "$1/scripts/loomy-delegate-codex.sh" --help 2>&1); [[ "$s" == *"--task-label"* && "$s" == *"source explicit-lead"* ]]' _ "$REPO"
project clean-label; policy
(cd "$P" && bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer --task-label $'Title\033[31m red\033[0m\342\200\256\n   line' 'label fixture') >"$OUT" 2>&1
check 'descriptor stores only the granted sanitized label' python3 - "$P" <<'PYLABEL'
from pathlib import Path
import json,sys
p=Path(sys.argv[1])/'.loomy'
label=json.loads((p/'logs/display-context-v1.jsonl').read_text())['text']
assert label=='Title red    line'
b=[json.loads(f.read_text()) for f in (p/'memory/private-results-v1').glob('[!.]*.json')]; assert len(b)==1
assert b[0]['resume']['options']['task_label']==label and '\x1b' not in b[0]['resume']['options']['task_label']
PYLABEL
# Observe actual provider shells through a test-only BASH_ENV hook.
sed '/^trap .*DEBUG/,$d' "$BASH_ENV" >"$WORK/provider-env.sh"
cat >>"$WORK/provider-env.sh" <<'ENVHOOK'
_t3_provider_env() {
_test_core_enter "$@"
case "$0" in
  */tests/stubs/codex) [[ "${1:-}" != exec ]] || printf '%s|%s\n' "${LOOMY_RESUME_DESCRIPTOR+set}" "${LOOMY_FAILOVER_FROM+set}" >>"$STUB_ENV_FILE" ;;
  */tests/stubs/claude) case " $* " in *' -p '*) printf '%s|%s\n' "${LOOMY_RESUME_DESCRIPTOR+set}" "${LOOMY_FAILOVER_FROM+set}" >>"$STUB_ENV_FILE" ;; esac ;;
esac
}
trap 'trap - DEBUG; _t3_provider_env "$@"; unset -f _t3_provider_env _test_core_enter' DEBUG
ENVHOOK
for family in codex claude; do
  project "environment-$family"; policy
  from=codex; [[ "$family" != codex ]] || from=claude
  (cd "$P" && BASH_ENV="$WORK/provider-env.sh" STUB_ENV_FILE="$WORK/env-$family" LOOMY_RESUME_DESCRIPTOR="$valid" LOOMY_FAILOVER_FROM="$from" bash "$REPO/scripts/loomy-delegate-$family.sh" reviewer 'environment fixture') >"$OUT" 2>&1
  check "$family provider exec does not inherit resume/failover environment" bash -c '[[ -s "$1" ]] && ! grep -q set "$1"' _ "$WORK/env-$family"
done
# The body accounting path must not decode unrelated full bodies.
project stat-only; policy results_max_records=1
save evictable
printf 'not a JSON body' >"$P/.loomy/memory/private-results-v1/evictable.json"
save replacement
check 'retention accounts from stat/manifest without decoding unrelated bodies' test -f "$P/.loomy/memory/private-results-v1/replacement.json"
# Contention beyond the old one-second bound still saves all receipts and bodies.
project lock-wait; policy
python3 - "$P" "$WORK/lock-ready" <<'PYLOCK' &
from pathlib import Path
import fcntl,sys,time
p=Path(sys.argv[1])/'.loomy/logs/content-policy.lock'
with p.open('r+') as f:
 fcntl.flock(f,fcntl.LOCK_EX); Path(sys.argv[2]).touch(); time.sleep(1.4)
PYLOCK
locker=$!
while [[ ! -f "$WORK/lock-ready" ]]; do sleep 0.02; done
now="$(date +%s)"
for i in 1 2 3 4; do state_save "wait$i" running "$$" "$now" 0 >"$WORK/wait$i" 2>&1 & done
wait "$locker"; wait
check 'four contended bridge saves survive a lock held longer than one second' python3 - "$P" <<'PYLOCK'
from pathlib import Path
import sys
p=Path(sys.argv[1])/'.loomy/memory'
assert len(list((p/'receipts-v1').glob('[!.]*.json')))==4
assert len(list((p/'private-results-v1').glob('[!.]*.json')))==4
PYLOCK
# Session continuity must read both old and projected journals, including hook
# duplicates and malformed unrelated rows, without treating an old start as new.
project session-order
check 'session continuity uses JSON values for legacy and projected starts' python3 - "$REPO" "$P" <<'PYSESSION'
import json, pathlib, subprocess, sys
repo, root = map(pathlib.Path, sys.argv[1:])
journal = root/'.loomy/logs/events.jsonl'
def start(tool, ts):
    return dict(ts=ts, type='session', event='start', tool=tool, session=tool)
claude = start('claude', '2026-10-01T08:00:00Z')
codex = start('codex', '2026-10-02T09:00:00.125Z')
hook = start('codex', '2026-10-02T09:00:01Z')
later = start('codex', '2026-10-03T09:00:00Z')
for ordered in (False, True):
    for rows, expected in (([], ''), ([hook], ''), ([claude, codex, hook], 'claude'),
                           ([claude, codex, later], 'codex'),
                           ([codex, claude], 'codex')):
        journal.write_text(''.join(json.dumps(row, sort_keys=ordered)+'\n' for row in rows)
                           +'invalid json\n[]\n'
                           +json.dumps(dict(type='session', event='start', tool='codex', ts='invalid'))+'\n')
        output = subprocess.check_output(['bash', '-c',
            'source "$1/scripts/lib/memory.sh"; loomy_memory_previous_tool "$2"',
            '_', str(repo), str(root)], text=True)
        assert output == expected, (ordered, rows, output, expected)
PYSESSION
# Fractional seconds keep their weight in the 300 s grouping, and a nested object's "tool" is not the row's tool.
project session-fractions
check 'session continuity keeps fractional seconds and reads only the top-level tool' python3 - "$REPO" "$P" <<'PYFRAC'
import json, pathlib, subprocess, sys
repo, root = map(pathlib.Path, sys.argv[1:])
journal = root/'.loomy/logs/events.jsonl'
def start(tool, ts, **extra):
    return dict(ts=ts, type='session', event='start', tool=tool, session=tool, **extra)
def previous(rows):
    journal.write_text(''.join(json.dumps(r)+'\n' for r in rows))
    return subprocess.check_output(['bash', '-c', 'source "$1/scripts/lib/memory.sh"; loomy_memory_previous_tool "$2"',
                                    '_', str(repo), str(root)], text=True)
claude = start('claude', '2026-10-01T10:00:00Z')
a = start('codex', '2026-10-01T10:30:00.100Z')
b_far = start('codex', '2026-10-01T10:35:00.900Z')   # 300.8 s after a: a separate session
b_near = start('codex', '2026-10-01T10:35:00.050Z')  # 299.95 s after a: the same session
assert previous([claude, a, b_far]) == 'codex'
assert previous([claude, a, b_near]) == 'claude'
nested = start('codex', '2026-10-01T10:40:00Z', meta=dict(tool='claude'))
assert previous([claude, a, nested]) == 'codex'
other = start('codex', '2026-10-01T10:41:00Z')
other['tool'] = 'gemini'; other['meta'] = dict(tool='claude')   # unknown top-level tool: the row does not count
assert previous([claude, a, other]) == 'claude'
PYFRAC
# Group-writable parents (umask 002). Private group = group name equals the user name and nobody else
# is a member; shared groups (macOS staff) and world write are always refused.
check 'directory group rule: private group accepted, shared group, other members and world write refused' perl -e '
  require shift; no warnings "redefine"; my $u=(getpwuid($<))[0];
  my %g=(private=>[$u,""],alone=>[$u,$u],shared=>["staff",""],crowd=>[$u,"$u other"]);
  my $cur; local *Loomy::ContentPolicy::_group_info=sub {@{$g{$cur}}};
  my $gid=(getpwuid($<))[3];
  my $bad=sub {my ($mode,$name,$lenient,$g)=@_; $cur=$name; return Loomy::ContentPolicy::_dir_unsafe($mode,$g//$gid,$lenient)};
  die "private group refused" if $bad->(0775,"private",1) || $bad->(0775,"alone",1);
  die "shared group accepted" unless $bad->(0775,"shared",1);
  die "extra member accepted" unless $bad->(0775,"crowd",1);
  die "world write accepted" unless $bad->(0777,"private",1) && $bad->(0757,"private",1);
  die "foreign primary gid accepted" unless $bad->(0775,"private",1,$gid+4242);
  die "strict directory accepted group write" unless $bad->(0775,"private",0);
  die "private mode refused" if $bad->(0755,"shared",1) || $bad->(0700,"shared",0);
' "$REPO/scripts/lib/content-policy.pl"
mode_of() { python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "$1"; }
if [[ "$(id -gn)" == "$(id -un)" ]]; then group_kind=private; else group_kind=shared; fi
project umask-group; policy
chmod 0700 "$P/.loomy/logs"; rm -rf "$P/.loomy/memory"
(umask 002; loomy_memory_state_init "$P")
check 'memory directory is created private under umask 002' test "$(mode_of "$P/.loomy/memory")" = 0o700
chmod 0775 "$P/.loomy"
(umask 002; save group-one) >"$OUT" 2>&1
if [[ "$group_kind" == private ]]; then
  check 'umask 002 with the private group: bridge save, count, digest and show work' bash -c '
    source "$1/scripts/lib/memory.sh"; [[ -f "$2/.loomy/memory/receipts-v1/group-one.json" ]] \
      && [[ "$(umask 002; loomy_memory_count "$2")" == 1 ]] && [[ "$(umask 002; loomy_memory_digest "$2")" == *group-one* ]] \
      && [[ "$(umask 002; loomy_memory_show "$2" 1)" == *"private summary"* ]]' _ "$REPO" "$P"
  chmod 0775 "$P/.loomy/memory"
  check 'a 0.17.6 group-writable memory directory stays usable with the private group' bash -c '
    source "$1/scripts/lib/memory.sh"; [[ "$(loomy_memory_count "$2")" == 1 ]]' _ "$REPO" "$P"
  chmod 0700 "$P/.loomy/memory"
else
  check 'umask 002 with a shared group: group-writable .loomy is refused, nothing is saved' bash -c '
    source "$1/scripts/lib/memory.sh"; [[ ! -e "$2/.loomy/memory/receipts-v1/group-one.json" ]] && ! loomy_memory_count "$2" >/dev/null 2>&1' _ "$REPO" "$P"
  check 'shared group: the content backend names the unsafe directory' bash -c '
    s=$(perl "$1/scripts/lib/content-policy.pl" results "$2" off 2>&1); [[ "$s" == *"unsafe directory: "*".loomy (group/world writable)"* ]]' _ "$REPO" "$P"
  chmod 0755 "$P/.loomy"
  (umask 002; save group-one) >"$OUT" 2>&1
  check 'shared group: once .loomy is not group-writable, umask 002 saves, counts and digests' bash -c '
    source "$1/scripts/lib/memory.sh"; [[ -f "$2/.loomy/memory/receipts-v1/group-one.json" ]] \
      && [[ "$(umask 002; loomy_memory_count "$2")" == 1 ]] && [[ "$(umask 002; loomy_memory_digest "$2")" == *group-one* ]]' _ "$REPO" "$P"
  chmod 0775 "$P/.loomy/memory"
  check 'shared group: a group-writable memory directory is refused' bash -c '
    source "$1/scripts/lib/memory.sh"; ! loomy_memory_count "$2" >/dev/null 2>&1' _ "$REPO" "$P"
  chmod 0700 "$P/.loomy/memory"
fi
chmod 0777 "$P/.loomy"
check 'world-writable .loomy is always refused' bash -c 'source "$1/scripts/lib/memory.sh"; ! loomy_memory_count "$2" >/dev/null 2>&1' _ "$REPO" "$P"
check 'unsafe .loomy: the memory backend names the absolute directory and the chmod remedy' bash -c '
  source "$1/scripts/lib/memory.sh"; s=$(_lm_backend count "$2" 2>&1 >/dev/null)
  [[ "$s" == *"Unsafe directory: $2/.loomy (group or world writable)"* && "$s" == *"chmod g-w,o-w '"'"'$2/.loomy'"'"'"* && "$s" != *"Content operation failed"* ]]' _ "$REPO" "$P"
chmod 0755 "$P/.loomy"; chmod 0777 "$P/.loomy/memory"
check 'unsafe memory directory: the backend names it with its absolute path, not the relative name' bash -c '
  source "$1/scripts/lib/memory.sh"; s=$(_lm_backend count "$2" 2>&1 >/dev/null)
  [[ "$s" == *"Unsafe directory: $2/.loomy/memory (group or world writable)"* ]]' _ "$REPO" "$P"
chmod 0700 "$P/.loomy/memory"

# A resume descriptor's free-text reason must survive clean_text unchanged: C1 controls and bidi are refused at storage.
project descriptor-why; policy
valid_why="$(printf '%s\0' reviewer codex gpt-6.1-sol high read-only equilibre why '' '' '' | _lm_backend descriptor "$P")"
for why in 'a\u009bb' 'a\u009db' 'a\u202eb' 'a\u009b2J \u009d52;c;x\u202e'; do
  bad="$(printf '%s' "$valid_why" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["options"]["why"]=json.loads("\""+sys.argv[1]+"\""); print(json.dumps(d))' "$why")"
  check "stored descriptor with a reason containing $why is refused" bash -c '
    source "$1/scripts/lib/memory.sh"; ! { printf "%s\0" "$3" reviewer codex | _lm_backend descriptor-env "$2"; } >/dev/null 2>&1' _ "$REPO" "$P" "$bad"
done
check 'descriptor still accepts a clean reason' bash -c '
  source "$1/scripts/lib/memory.sh"; printf "%s\0" reviewer codex gpt-6.1-sol high read-only equilibre "plain reason" "" "" "" | _lm_backend descriptor "$2" >/dev/null' _ "$REPO" "$P"
# A raw --why over 200 characters is cut after trimming: the stored reason must be stable under a second clean_text.
for kind in ws200 pairs cjk exact200 len201 len201ws; do
  why="$(python3 -c '
import sys
k=sys.argv[1]
print({"ws200":"a"*199+" b b b b b","pairs":"a "*150,"cjk":"日本語 "*80,"exact200":"x"*200,"len201":"y"*201,"len201ws":"z"*199+"  q"}[k],end="")' "$kind")"
  check "descriptor is built from a long raw reason ($kind) and is stable" bash -c '
    source "$1/scripts/lib/memory.sh"; d=$(printf "%s\0" reviewer codex gpt-6.1-sol high read-only equilibre "$3" "" "" "" | _lm_backend descriptor "$2") || exit 1
    w=$(printf "%s" "$d" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"options\"][\"why\"],end=\"\")"); [[ -n "$w" && "${#w}" -le 200 && "$w" != *" " ]] || exit 1
    printf "%s\0" "$d" reviewer codex | _lm_backend descriptor-env "$2" >/dev/null' _ "$REPO" "$P" "$why"
done

# memory show prints agent-written text: terminal controls never reach the user's terminal.
project show-escape; policy
save esc ok $'task \033]52;c;SECRET\a \033[31mred\033[0m \xc2\x9b2J \xe2\x80\xaerev\x01' $'SUMMARY: ok\nFINDINGS:\n- result \033]8;;http://x\033\\link\033]8;;\033\\ \x07 bell\ttab'
check 'memory show strips ANSI/OSC/bidi and escapes other C0/C1 in task and result' python3 - "$REPO" "$P" <<'PYSHOW'
import subprocess, sys
repo, root = sys.argv[1:]
out = subprocess.check_output(['bash', '-c', 'source "$1/scripts/lib/memory.sh"; loomy_memory_show "$2" 1', '_', repo, root])
text = out.decode('utf-8')
task, result = text.split('## Task')[1].split('## Result')
assert not any(c in task + result for c in '\x1b\x07\x9b‮\x01'), repr(text)
assert 'red' in task and 'rev' in task and '\\x01' in task, repr(task)
assert 'link' in result and '\\x07' in result and 'bell\ttab' in result and 'http://x' not in result, repr(result)
PYSHOW
mkdir -p "$P/.loomy/memory/delegations"; chmod 0700 "$P/.loomy/memory/delegations"
printf 'legacy \033]0;title\007 \033[2J \302\233' >"$P/.loomy/memory/delegations/2026-01-01-legacy.md"
printf '31m ok\n' >>"$P/.loomy/memory/delegations/2026-01-01-legacy.md"
check 'legacy memory output is escaped too' python3 - "$REPO" "$P" <<'PYLEGACY'
import subprocess, sys
repo, root = sys.argv[1:]
out = subprocess.check_output(['bash', '-c', 'source "$1/scripts/lib/memory.sh"; loomy_memory_legacy "$2" 1', '_', repo, root]).decode('utf-8')
assert '\x1b' not in out and '\x07' not in out and '\x9b' not in out and 'legacy' in out and 'ok' in out, repr(out)
PYLEGACY

printf '\nContent memory: %s passed, %s failed\n' "$PASS" "$FAIL"
test_guard_gate || FAIL=$((FAIL+1))
((FAIL==0))

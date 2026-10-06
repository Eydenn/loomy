#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Integrity of a Loomy project. The pieces Loomy can set up by itself, without the lead agent, are created at init and
# checked again at every launch (loomy commands, the start of every Claude Code session), so that a setup interrupted
# midway never leaves the project working silently wrong: routing documents, the role subagents, and the orchestration
# rule in AGENTS.md / CLAUDE.md. Existing files are never overwritten (only the managed block between Loomy's markers
# is kept up to date). Older projects are migrated from .ai/ to .loomy/docs/. To be sourced after models.sh. Bash 3.2.

# shellcheck source=memory.sh
source "$(dirname "${BASH_SOURCE[0]}")/memory.sh"

LP_DONE=()   # what the last repair did (one short line each)
LP_RENAME_MAP="'ai-assess'=>'loomy-assess', 'ai-audit'=>'loomy-audit', 'ai-catalog-check'=>'loomy-catalog-check', 'ai-context'=>'loomy-context', 'ai-doctor'=>'loomy-doctor', 'ai-effort'=>'loomy-effort', 'ai-feedback'=>'loomy-feedback', 'ai-home'=>'loomy-home', 'ai-local-writer'=>'loomy-local-writer', 'ai-log'=>'loomy-log', 'ai-models'=>'loomy-models', 'ai-privacy'=>'loomy-privacy', 'ai-report'=>'loomy-report', 'ai-review'=>'loomy-review', 'ai-route'=>'loomy-route', 'ai-start'=>'loomy-start', 'ai-stats'=>'loomy-stats', 'ai-status'=>'loomy-status', 'ai-statusline'=>'loomy-statusline', 'ai-task'=>'loomy-task', 'ai-tree'=>'loomy-tree', 'delegate-to-claude'=>'loomy-delegate-claude', 'delegate-to-codex'=>'loomy-delegate-codex', 'detect-ai-tools'=>'loomy-detect-tools', 'init-wizard'=>'loomy-init-wizard', 'install-into-project'=>'loomy-install-project', 'install-security-audit'=>'loomy-install-security-audit', 'create-hybrid-worktrees'=>'loomy-worktrees'"

# _lp_doc_lang <root>: fr or en, the language of the project's documents (brief: doc_language).
_lp_doc_lang() { local l; l="$(_ai_brief_get "$1/.loomy/brief.md" doc_language 2>/dev/null)"; [[ "$l" == fr ]] && echo fr || echo en; }

# _lp_templates <root>: the template folder in the project's language (its own copy first).
_lp_templates() {
  if [[ -d "$1/.loomy/templates" ]]; then echo "$1/.loomy/templates"; return 0; fi
  local base="${LOOMY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  if [[ "$(_lp_doc_lang "$1")" == fr && -d "$base/fr/templates" ]]; then echo "$base/fr/templates"; else echo "$base/templates"; fi
}

# loomy_project_migrate <root>: .ai/ (Loomy before 0.9) → .loomy/docs/, references updated in the agents' files.
loomy_project_migrate() {
  local r="$1" f
  [[ -d "$r/.ai" && ! -e "$r/.loomy/docs" && -d "$r/.loomy" ]] || return 0
  if git -C "$r" ls-files --error-unmatch .ai >/dev/null 2>&1 || [[ -n "$(git -C "$r" ls-files .ai 2>/dev/null | head -1)" ]]; then
    git -C "$r" mv .ai .loomy/docs >/dev/null 2>&1 || mv "$r/.ai" "$r/.loomy/docs"
  else
    mv "$r/.ai" "$r/.loomy/docs"
  fi
  if command -v perl >/dev/null 2>&1; then
    for f in "$r/AGENTS.md" "$r/CLAUDE.md" "$r/PROJECT.md" "$r/ARCHITECTURE.md" "$r/START.md" "$r"/.claude/agents/*.md "$r"/.loomy/docs/*.md; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      grep -q '\.ai/' "$f" 2>/dev/null || continue
      perl -pi -e 's{(?<![\w./-])\.ai/}{.loomy/docs/}g' "$f" 2>/dev/null || true
    done
  fi
  LP_DONE+=(".ai/ → .loomy/docs/")
}

# Old script names (before Loomy 0.10) → loomy-* names, for the references in the project's files.
LP_RENAME_PERL='my %m = (__MAP__); my $re = join("|", map { quotemeta } sort { length($b) <=> length($a) } keys %m); s{(?:(?<=scripts/)|(?<![\w./-]))($re)\.sh(?![\w.-])}{$m{$1}.sh}g; s{(?<![\w-])delegate-to-(?=<|\*)}{loomy-delegate-}g;'

# loomy_project_rename_scripts <root>: relays under the loomy-* names, and the old names replaced in the hooks and the
# agents' files. The old relays stay (they keep working through the installed Loomy's compatibility scripts until 1.0).
loomy_project_rename_scripts() {
  local r="$1" f n base did=0
  [[ -f "$r/.loomy/scripts/_loomy.sh" ]] || return 0
  base="${LOOMY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  for f in "$base"/scripts/loomy-*.sh; do
    n="$(basename "$f")"; [[ -e "$r/.loomy/scripts/$n" ]] && continue
    printf '#!/usr/bin/env bash\n# Loomy relay: runs %s from the installed Loomy (see _loomy.sh).\n. "$(dirname "$0")/_loomy.sh" && _loomy_run %s "$@"\n' "$n" "$n" >"$r/.loomy/scripts/$n" 2>/dev/null \
      && chmod +x "$r/.loomy/scripts/$n" 2>/dev/null && did=1
  done
  command -v perl >/dev/null 2>&1 || return 0
  for f in "$r/AGENTS.md" "$r/CLAUDE.md" "$r/PROJECT.md" "$r/ARCHITECTURE.md" "$r/START.md" "$r/.claude/settings.json" \
           "$r/.codex/hooks.json" "$r"/.claude/agents/*.md "$r"/.loomy/docs/*.md; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    grep -qE '(ai-[a-z-]+|delegate-to-[a-z<*]+|detect-ai-tools|init-wizard|install-into-project|install-security-audit|create-hybrid-worktrees)(\.sh|>|\*)' "$f" 2>/dev/null || continue
    cp "$f" "$f.loomy-tmp" 2>/dev/null || continue
    perl -pi -e "${LP_RENAME_PERL/__MAP__/$LP_RENAME_MAP}" "$f" 2>/dev/null || true
    cmp -s "$f" "$f.loomy-tmp" || did=1
    rm -f "$f.loomy-tmp"
  done
  (( did )) && LP_DONE+=("scripts → loomy-*")
  return 0
}

# _lp_block <root>: the managed orchestration block, in the project's language.
_lp_block() {
  echo "<!-- loomy:orchestration:start · managed by Loomy, updated automatically -->"
  if [[ "$(_lp_doc_lang "$1")" == fr ]]; then
    cat <<'FR'
## Orchestration (Loomy)

Tu es l'**orchestrateur**. Chaque demande sur ce projet (fonctionnalité, bug, retour ou correction de l'utilisateur) passe par toi et est routée : tu planifies, délègues, vérifies et décides.

- Confie chaque travail à son rôle selon `.loomy/scripts/loomy-route.sh` (matrice dans `.loomy/docs/AI_MODEL_ROUTING.md`) : il indique pour chaque rôle s'il passe par un sous-agent de `.claude/agents/` ou par un pont `.loomy/scripts/loomy-delegate-<outil>.sh <rôle> "…"`.
- Le coût d'abord : donne chaque tâche au rôle le moins cher capable de la faire de façon fiable (exécutant, explorateur, développeur avant architecte ou débogueur) ; garde ton propre modèle pour planifier, décider, intégrer et relire.
- Ne fais toi-même que la coordination, les décisions et les retouches triviales ; ne corrige jamais directement un retour de l'utilisateur quand un rôle doit le prendre.
- Travail conséquent : `loomy task "…"` ; vérification indépendante d'un changement : `loomy review`.
- Mémoire partagée : tiens `.loomy/memory/STATE.md` à jour (fait, en cours, décisions, suite ; en anglais, en style télégraphique, 40 lignes au plus, en remplaçant ce qui est dépassé : il est écrit pour les modèles, au moindre coût) après chaque étape importante et avant de finir une session. C'est ce qui garde le fil d'une session à l'autre, après un compactage et entre Claude Code et Codex. Les résultats complets des délégations sont dans `.loomy/memory/delegations/` : pour donner des constats à un rôle, indique-lui le fichier plutôt que d'en recopier le contenu.
- Si la mise en place Loomy n'est pas terminée (`START.md` encore présent), termine-la d'abord.
FR
  else
    cat <<'EN'
## Orchestration (Loomy)

You are the **lead agent**. Every request in this project (a feature, a bug, the user's feedback or fixes) goes through you and is routed: you plan, delegate, check and decide.

- Hand each piece of work to its role following `.loomy/scripts/loomy-route.sh` (matrix in `.loomy/docs/AI_MODEL_ROUTING.md`): it says for each role whether it goes to a subagent in `.claude/agents/` or through a bridge, `.loomy/scripts/loomy-delegate-<tool>.sh <role> "…"`.
- Cost first: give each task to the cheapest role that does it reliably (executor, explorer, developer before architect or debugger); keep your own model for planning, decisions, integration and review.
- Do yourself only coordination, decisions and trivial edits; never fix the user's feedback inline when a role should take it.
- Bigger work: `loomy task "…"`; independent check of a change: `loomy review`.
- Shared memory: keep `.loomy/memory/STATE.md` up to date (done, in progress, decisions, next; English, telegraphic, 40 lines at most, replacing what is outdated: it is written for the models, at the lowest cost) after each important step and before ending a session. This is what keeps the thread from one session to the next, after a compaction, and between Claude Code and Codex. The full results of the delegations are in `.loomy/memory/delegations/`: to give findings to a role, point it to the file rather than copying its content.
- If the Loomy setup is unfinished (`START.md` still present), finish it first.
EN
  fi
  echo "<!-- loomy:orchestration:end -->"
}

# _lp_ensure_block <file> <root>: the managed block present and current in that file (created after its first heading).
_lp_ensure_block() {
  local f="$1" r="$2" blk tmp
  [[ -f "$f" && ! -L "$f" ]] || return 0
  blk="$(_lp_block "$r")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/loomy-block.XXXXXX")" || return 0
  if grep -q '<!-- loomy:orchestration:start' "$f"; then
    LP_BLK="$blk" awk '/<!-- loomy:orchestration:start/ { print ENVIRON["LP_BLK"]; skip = 1; next } skip && /<!-- loomy:orchestration:end -->/ { skip = 0; next } !skip' "$f" >"$tmp"
  else
    LP_BLK="$blk" awk 'BEGIN { done = 0 } { print } !done && /^# / { print ""; print ENVIRON["LP_BLK"]; done = 1 } END { if (!done) { print ""; print ENVIRON["LP_BLK"] } }' "$f" >"$tmp"
  fi
  if ! cmp -s "$tmp" "$f"; then cat "$tmp" >"$f"; LP_DONE+=("$(basename "$f"): orchestration rule"); fi
  rm -f "$tmp"
}

# loomy_project_repair <root>: creates what is missing among the pieces Loomy owns; LP_DONE lists what was done.
loomy_project_repair() {
  local r="$1" tpl docs f route lead tmpd n
  LP_DONE=()
  [[ -f "$r/.loomy/brief.md" ]] || return 0
  loomy_project_migrate "$r"
  loomy_project_rename_scripts "$r"
  tpl="$(_lp_templates "$r")"; docs="$r/.loomy/docs"
  route="$(dirname "${BASH_SOURCE[0]}")/../loomy-route.sh"
  mkdir -p "$docs"
  # Routing, workflow and orchestration documents (the agent may refine them; never overwritten).
  for f in WORKFLOW ORCHESTRATION MODEL_ROUTING; do
    [[ -f "$docs/AI_$f.md" || ! -f "$tpl/$f.md" ]] && continue
    if [[ "$f" == MODEL_ROUTING ]]; then
      # The last section is the matrix resolved for this project.
      { awk '/^## / { last = NR } { line[NR] = $0 } END { for (i = 1; i <= (last ? last : NR); i++) print line[i] }' "$tpl/$f.md"
        echo ""; bash "$route" --root "$r" markdown 2>/dev/null; } >"$docs/AI_$f.md"
    else
      cp "$tpl/$f.md" "$docs/AI_$f.md"
    fi
    LP_DONE+=(".loomy/docs/AI_$f.md")
  done
  # Role subagents for a Claude lead: only the missing ones (a customised subagent stays as it is).
  ai_detect_env "$r" 2>/dev/null || true
  lead="${AI_ENV#hybrid-}"
  if [[ "$lead" == claude ]]; then
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/loomy-agents.XXXXXX")" || tmpd=""
    if [[ -n "$tmpd" ]] && bash "$route" --root "$r" claude-agents "$tmpd" >/dev/null 2>&1; then
      mkdir -p "$r/.claude/agents"; n=0
      for f in "$tmpd"/*.md; do
        [[ -f "$f" && ! -e "$r/.claude/agents/$(basename "$f")" ]] || continue
        cp "$f" "$r/.claude/agents/"; n=$(( n + 1 ))
      done
      (( n > 0 )) && LP_DONE+=(".claude/agents/: $n subagent(s)")
    fi
    [[ -n "$tmpd" ]] && rm -rf "$tmpd"
  fi
  # Shared memory: the work state file, and the delegation results kept out of Git (findings can be sensitive).
  if [[ ! -f "$(loomy_memory_dir "$r")/STATE.md" ]]; then
    loomy_memory_state_init "$r"; [[ -f "$(loomy_memory_dir "$r")/STATE.md" ]] && LP_DONE+=(".loomy/memory/STATE.md")
  fi
  if { [[ -f "$r/.gitignore" ]] || git -C "$r" rev-parse --is-inside-work-tree >/dev/null 2>&1; } \
     && ! grep -qxF '.loomy/memory/delegations/' "$r/.gitignore" 2>/dev/null; then
    printf '\n# Loomy: delegation results (shared memory, may hold sensitive findings)\n.loomy/memory/delegations/\n' >>"$r/.gitignore"
  fi
  # The orchestration rule where the agents read it.
  _lp_ensure_block "$r/AGENTS.md" "$r"
  _lp_ensure_block "$r/CLAUDE.md" "$r"
  return 0
}

# loomy_bootstrap_unfinished <root>: true while START.md is still there or the recorded phase is not done.
loomy_bootstrap_unfinished() {
  local p
  p="$(sed -n 's/^phase=//p' "$1/.loomy/state" 2>/dev/null | head -1)"
  [[ -f "$1/START.md" ]] && return 0
  [[ -n "$p" && "$p" != "done" ]]
}

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

# ---- History and work files: never versioned in the project repository (whatever the AI-files mode). One list,
# used by the managed .gitignore block, the doctor check and the private backup. Only rules and docs may be versioned.
LOOMY_HISTORY_BEGIN="# >>> Loomy: local history and work files, never versioned"
LOOMY_HISTORY_END="# <<< Loomy"
LP_GI_CHANGED=0

# loomy_history_paths: .gitignore patterns of the history / work / local state files, one per line.
loomy_history_paths() {
  cat <<'LIST'
.loomy/logs/
.loomy/memory/
.loomy/docs/HANDOFF.md
.loomy/state
.loomy/tasks/
.loomy/TASKS.md
.loomy/*.state
.loomy/**/*.tmp
.loomy/**/*.tmp.*
.loomy/*-prompt.txt
.loomy/audit.md
.loomy/audits/
.loomy/reviews/
.loomy/assessment.md
.loomy/brief.previous.md
.loomy/failover
.loomy/failover.lock
.loomy/relay.notice
.loomy/ai.git/
.loomy/restore-backup-*/
.loomy/skills.lock.d/
.loomy/.skills.lock.*
LIST
}

# loomy_history_block: the managed .gitignore block.
loomy_history_block() { echo "$LOOMY_HISTORY_BEGIN"; loomy_history_paths; echo "$LOOMY_HISTORY_END"; }

# loomy_history_pathspecs: the same list as Git :(glob) pathspecs (a directory pattern becomes dir/**; a plain pathspec
# would recurse: scripts/*.sh matches scripts/lib/x.sh), for git ls-files and git rm --cached.
loomy_history_pathspecs() {
  local p
  while IFS= read -r p; do
    if [[ "$p" == */ ]]; then printf ':(glob)%s**\n' "$p"; else printf ':(glob)%s\n' "$p"; fi
  done < <(loomy_history_paths)
}

# loomy_gitignore_sync <root>: writes the managed block at the END of the project's .gitignore (only in a Git
# repository or when a .gitignore exists), so that it wins over the user's earlier lines (a negation placed before it
# cannot re-include a history file). A block is managed only when both markers are present, in order; the user's lines
# are never removed or edited (an orphan marker stays as it is and a fresh block is appended). The older single Loomy
# lines are dropped. CRLF files keep their line ending. LP_GI_CHANGED is 1 when the file was modified.
loomy_gitignore_sync() {
  local r="$1" f="$1/.gitignore" src blk tmp
  LP_GI_CHANGED=0
  [[ ! -L "$f" ]] || return 0
  if [[ ! -f "$f" ]] && ! git -C "$r" rev-parse --is-inside-work-tree >/dev/null 2>&1; then return 0; fi
  blk="$(mktemp "${TMPDIR:-/tmp}/loomy-gi.XXXXXX")" || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/loomy-gi.XXXXXX")" || { rm -f "$blk"; return 0; }
  loomy_history_block >"$blk"
  src="$f"; [[ -f "$f" ]] || src=/dev/null
  awk -v blk="$blk" -v b="$LOOMY_HISTORY_BEGIN" -v e="$LOOMY_HISTORY_END" '
    { raw[NR] = $0; l = $0; sub(/\r$/, "", l); t[NR] = l; if (!crlf && $0 ~ /\r$/) crlf = 1 }
    END {
      eol = crlf ? "\r" : ""
      lb = 0
      for (i = 1; i <= NR; i++) {
        if (t[i] == b) lb = i
        else if (t[i] == e && lb) { for (j = lb; j <= i; j++) del[j] = 1; lb = 0 }
      }
      # older single lines: comment + path, dropped with the blank line that preceded them
      for (i = 1; i <= NR; i++) {
        if (t[i] ~ /^# Loomy ?: (local activity log|journal d|delegation results|résultats des délégations)/) {
          del[i] = 1
          if (t[i + 1] == ".loomy/logs/" || t[i + 1] == ".loomy/memory/delegations/") del[i + 1] = 1
          if (i > 1 && t[i - 1] == "" && !del[i - 1]) del[i - 1] = 1
        }
      }
      n = 0
      for (i = 1; i <= NR; i++) if (!del[i]) out[++n] = raw[i]
      while (n > 0 && out[n] ~ /^\r?$/) n--
      for (i = 1; i <= n; i++) print out[i]
      if (n > 0) print eol
      while ((getline x < blk) > 0) print x eol
      close(blk)
    }
  ' "$src" >"$tmp" 2>/dev/null || true
  if [[ -s "$tmp" ]] && ! cmp -s "$tmp" "$src" 2>/dev/null; then
    cat "$tmp" >"$f" && LP_GI_CHANGED=1
  fi
  rm -f "$blk" "$tmp"
  return 0
}

# loomy_history_tracked <root>: history / work files tracked by the project repository (one path per line).
loomy_history_tracked() {
  local specs=() p
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  while IFS= read -r p; do specs+=("$p"); done < <(loomy_history_pathspecs)
  git -C "$1" ls-files -- "${specs[@]}" 2>/dev/null || true
  return 0
}

# _lp_doc_lang <root>: fr or en, the language of the project's documents (brief: doc_language).
_lp_doc_lang() { local l; l="$(_ai_brief_get "$1/.loomy/brief.md" doc_language 2>/dev/null)"; [[ "$l" == fr ]] && echo fr || echo en; }

# _lp_templates <root>: the template folder in the project's language (its own copy first).
_lp_templates() {
  if [[ -d "$1/.loomy/templates" ]]; then echo "$1/.loomy/templates"; return 0; fi
  local base="${LOOMY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  if [[ "$(_lp_doc_lang "$1")" == fr && -d "$base/fr/templates" ]]; then echo "$base/fr/templates"; else echo "$base/templates"; fi
}

# _lp_agent_untouched <subagent> <generated>: true when the subagent differs from the generated one only by its model
# and effort lines, and its model is one Loomy routes (a chain of the catalog or the built-in one).
_lp_agent_untouched() {
  local m chains
  diff -q <(grep -vE '^(model|effort):' "$1") <(grep -vE '^(model|effort):' "$2") >/dev/null 2>&1 || return 1
  m="$(sed -n 's/^model:[[:space:]]*//p' "$1" | head -1 | tr -d '[:space:]')"
  [[ -n "$m" ]] || return 1
  chains=" $AI_CHAIN_CLAUDE_TOP $AI_CHAIN_CLAUDE_MID $AI_CHAIN_CLAUDE_FAST claude-haiku-4-5 claude-sonnet-5 claude-opus-5 claude-opus-4-8 "
  [[ "$chains" == *" $m "* ]]
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
  local r="$1" f n m base did=0
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
  # The relays under the old names (Loomy relay files only, never a script of the project) are removed once their
  # loomy-* replacement is there.
  for f in "$r"/.loomy/scripts/ai-*.sh "$r"/.loomy/scripts/delegate-to-*.sh "$r"/.loomy/scripts/detect-ai-tools.sh \
           "$r"/.loomy/scripts/init-wizard.sh "$r"/.loomy/scripts/install-into-project.sh "$r"/.loomy/scripts/install-security-audit.sh \
           "$r"/.loomy/scripts/create-hybrid-worktrees.sh; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    n="$(basename "$f")"
    # Exactly the relay Loomy generated for that name (a customised file stays), and its loomy-* replacement in place.
    [[ "$(cat "$f")" == "$(printf '#!/usr/bin/env bash\n# Loomy relay: runs %s from the installed Loomy (see _loomy.sh).\n. "$(dirname "$0")/_loomy.sh" && _loomy_run %s "$@"' "$n" "$n")" ]] || continue
    m="$(printf '%s' "$n" | perl -pe "${LP_RENAME_PERL/__MAP__/$LP_RENAME_MAP}" 2>/dev/null)"
    [[ -n "$m" && "$m" != "$n" && -x "$r/.loomy/scripts/$m" ]] || continue
    rm -f "$f" && did=1
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
- Contexte fiable : après chaque demande terminée et vérifiée, mets à jour la documentation durable qu'elle touche (`PROJECT.md`, `ARCHITECTURE.md`, un ADR dans `docs/decisions/` pour une décision importante), puis fais un commit cohérent (un par demande, message clair) si le brief autorise les commits ; sinon prépare-le et signale-le. Ne pousse que si le brief l'autorise. Le dépôt, ses commits et sa documentation sont la mémoire durable du projet.
- Mémoire partagée : tiens `.loomy/memory/STATE.md` à jour (fait, en cours, décisions, suite ; en anglais, en style télégraphique, 40 lignes au plus, en remplaçant ce qui est dépassé : il est écrit pour les modèles, au moindre coût) après chaque étape importante et avant de finir une session. C'est ce qui garde le fil d'une session à l'autre, après un compactage et entre Claude Code et Codex. Les résultats complets des délégations sont dans `.loomy/memory/delegations/` : pour donner des constats à un rôle, indique-lui le fichier plutôt que d'en recopier le contenu.
- Un problème qui vient de Loomy lui-même (pas du projet) : prépare le retour avec `loomy feedback --print "…"` et propose-le à l'utilisateur ; il ne part jamais sans son accord.
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
- Reliable context: after each finished and verified request, update the durable documentation it touches (`PROJECT.md`, `ARCHITECTURE.md`, an ADR in `docs/decisions/` for an important decision), then make one coherent commit (one per request, clear message) if the brief allows commits; otherwise prepare it and say so. Push only if the brief allows it. The repository, its commits and its documentation are the project's durable memory.
- Shared memory: keep `.loomy/memory/STATE.md` up to date (done, in progress, decisions, next; English, telegraphic, 40 lines at most, replacing what is outdated: it is written for the models, at the lowest cost) after each important step and before ending a session. This is what keeps the thread from one session to the next, after a compaction, and between Claude Code and Codex. The full results of the delegations are in `.loomy/memory/delegations/`: to give findings to a role, point it to the file rather than copying its content.
- A problem coming from Loomy itself (not the project): prepare the feedback with `loomy feedback --print "…"` and offer it to the user; it is never sent without their approval.
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
  local r="$1" tpl docs f route lead tmpd n u dest
  LP_DONE=()
  [[ -f "$r/.loomy/brief.md" ]] || return 0
  loomy_project_migrate "$r"
  loomy_project_rename_scripts "$r"
  # Existing projects gain missing native-agent hooks without rewriting user settings.
  # shellcheck source=hooks.sh
  source "$(dirname "${BASH_SOURCE[0]}")/hooks.sh"
  loomy_claude_hooks_merge "$r" || true
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
  # Role subagents for a Claude lead: the missing ones are added; an untouched one follows the routing (new model,
  # loomy effort). Untouched: same text as generated apart from its model and effort lines, and a model Loomy routes
  # (a hand-written "model: opus" or "inherit", or any other change, keeps the subagent as it is).
  ai_detect_env "$r" 2>/dev/null || true
  lead="${AI_ENV#hybrid-}"
  if [[ "$lead" == claude ]]; then
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/loomy-agents.XXXXXX")" || tmpd=""
    if [[ -n "$tmpd" ]] && bash "$route" --root "$r" claude-agents "$tmpd" >/dev/null 2>&1; then
      mkdir -p "$r/.claude/agents"; n=0; u=0
      for f in "$tmpd"/*.md; do
        [[ -f "$f" ]] || continue
        dest="$r/.claude/agents/$(basename "$f")"
        if [[ ! -e "$dest" ]]; then cp "$f" "$dest"; n=$(( n + 1 ))
        elif [[ -f "$dest" && ! -L "$dest" ]] && ! cmp -s "$f" "$dest" && _lp_agent_untouched "$dest" "$f"; then
          cp "$f" "$dest"; u=$(( u + 1 ))
        fi
      done
      (( n > 0 )) && LP_DONE+=(".claude/agents/: $n subagent(s)")
      (( u > 0 )) && LP_DONE+=(".claude/agents/: $u subagent(s) moved to the current routing")
    fi
    [[ -n "$tmpd" ]] && rm -rf "$tmpd"
  fi
  # Shared memory: the work state file, and the delegation results kept out of Git (findings can be sensitive).
  if [[ ! -f "$(loomy_memory_dir "$r")/STATE.md" ]]; then
    loomy_memory_state_init "$r"; [[ -f "$(loomy_memory_dir "$r")/STATE.md" ]] && LP_DONE+=(".loomy/memory/STATE.md")
  fi
  # History and work files stay out of the project repository, whatever the AI-files mode.
  loomy_gitignore_sync "$r"; [[ "$LP_GI_CHANGED" == 1 ]] && LP_DONE+=(".gitignore: Loomy history and work files")
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

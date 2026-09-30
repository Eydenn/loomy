<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/loomy-dark.svg">
  <img alt="Loomy" src="docs/assets/loomy-light.svg" width="340">
</picture>

**Start and structure your projects with Codex and Claude Code.**
A questionnaire to frame the project, a repository structure ready for agents, a lead agent on the best model that delegates to dedicated roles, and live tracking in your terminal.

![version](https://img.shields.io/badge/version-0.7.3-7F77DD?style=for-the-badge)
![status](https://img.shields.io/badge/status-pre--release-BA7517?style=for-the-badge)
![bash](https://img.shields.io/badge/bash-3.2%2B-1D9E75?style=for-the-badge&logo=gnubash&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude_Code-%E2%89%A5_2.1.280-D85A30?style=for-the-badge)
![Codex](https://img.shields.io/badge/Codex_CLI-%E2%89%A5_0.155-185FA5?style=for-the-badge)

🇬🇧 English · [🇫🇷 Français](README.fr.md)

</div>

> [!NOTE]
> Loomy's interface, questionnaire and generated project files are in French. This page is an English overview.
>
> **Pre-release.** Loomy stays at 0.x until the whole flow has been validated in real conditions. The stable release comes after a release-candidate phase validated by testers.

---

## ⚡ Quick start

**1. Install Loomy** (once; npm, bun or script: see "Installation")

```bash
HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install eydenn/tap/loomy
```

**2. Check your machine** (once)

```bash
loomy doctor --fix --live
```

**3. Create the project and answer the questionnaire**, from any folder

```bash
loomy init
```

`loomy init` offers to create a folder named after the project (name editable), to use the current folder, or another location. `loomy init my-project` creates the folder directly. At the end, it offers to open the lead agent session.

**4. Reopen the lead agent session** later, from the project folder

```bash
loomy start
```

**5. Follow live**, in a second terminal

```bash
loomy watch
```

> [!TIP]
> From then on, just type **`loomy`** in the project folder: it shows where the project stands, what is expected from you, and offers to open or resume the session, follow live, or see the status.

---

## 📦 Installation

Every method installs the same `loomy` command. The repository is private, so they all use your GitHub credentials (`gh auth login`).

🍺 **Homebrew** (recommended on macOS)

```bash
HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install eydenn/tap/loomy
```

📦 **npm**

```bash
npm install -g github:Eydenn/loomy
```

🥟 **bun**

```bash
gh release download -R Eydenn/loomy -p 'loomy-*.tgz' -D /tmp/loomy && bun add -g /tmp/loomy/loomy-*.tgz
```

🐚 **Shell script**

```bash
gh repo clone Eydenn/loomy ~/Tools/loomy && ~/Tools/loomy/install.sh
```

**Update**, whatever the method:

```bash
loomy update
```

Several installs on the same machine (for example Homebrew and npm)? To see which one is used and how to remove the others:

```bash
loomy version --all
```

> [!TIP]
> `loomy update` detects how Loomy was installed and runs the right command. Homebrew downloads inside a sandbox that cannot reach the macOS keychain, so the GitHub token is passed through `HOMEBREW_GITHUB_API_TOKEN` for the download only; `loomy update` does this for you. bun cannot read a private GitHub repository, so it installs the release archive, which `gh` downloads with your credentials. For npm, the update goes into the same folder as the original install, even if you switched Node versions (nvm) since.

---

## 🧭 How it works

```mermaid
flowchart LR
  A["🩺 Check<br/>loomy doctor"]:::check --> B["📝 Questionnaire<br/>loomy init"]:::step
  B --> C["🧭 Routing<br/>loomy route"]:::route
  C --> D["🎯 Lead agent<br/>follows START.md"]:::lead
  D --> E["📜 Journal<br/>every delegation"]:::step
  E --> F["📈 Tracking<br/>loomy watch"]:::check
  classDef step fill:#F1EFE8,stroke:#888780,color:#2C2C2A
  classDef check fill:#E1F5EE,stroke:#1D9E75,color:#085041
  classDef route fill:#FAEEDA,stroke:#BA7517,color:#633806
  classDef lead fill:#EEEDFE,stroke:#534AB7,color:#26215C
```

1. **Check.** Verifies CLI versions, finds Codex even when it is bundled inside the ChatGPT app, checks model availability, and offers fixes.
2. **Questionnaire.** Thirteen questions grouped by theme, each showing the consequence of every option: project type, stage, risk, AI mode, lead tool, budget, Git permissions. The first time, a fourteenth asks for your Claude and ChatGPT subscriptions. For a new project, a template (SaaS web app, landing page, REST API, CLI, email templates) prefills the answers and gives the lead agent a starting structure. ← goes back to the previous question; in a text field, Tab turns the suggestion into editable text (project name, repository name…).
3. **Routing.** Turns the brief and the installed tools into a role → model → effort matrix, with automatic fallback when a CLI is missing.
4. **Lead agent.** The main session follows `START.md`:

   <kbd>Discover</kbd> → <kbd>Interview</kbd> → <kbd>Propose</kbd> → <kbd>✋ Approve</kbd> → <kbd>Build</kbd> → <kbd>Verify</kbd> → <kbd>Document</kbd> → <kbd>Commit</kbd> → <kbd>Retire</kbd>

   It delegates the work to dedicated roles and never moves on without your approval.
5. **Journal and tracking.** Every delegation is recorded (model, effort, duration, tokens, cost) as soon as it starts. You follow it live in the terminal.

---

## 🚀 Moving your project forward

Once `loomy init` is done, everything goes through the **lead agent**: a Claude Code or Codex session on the best model, which follows `START.md` and then the project rules. It delegates to the dedicated roles.

### 1. Open or resume its session

The simplest: **`loomy`** in the project folder, then "Ouvrir ou reprendre la session".

| Where | How |
|---|---|
| 🖥️&nbsp;**Terminal,&nbsp;with&nbsp;Loomy** | `loomy start`: a menu to **resume** this folder's last session (with its history) or open a **new** one with the prompt that fits the project phase. `--resume` and `--new` go straight there. |
| ⌨️&nbsp;**Terminal,&nbsp;by&nbsp;hand** | Claude Code: `claude --continue` to resume; Codex: `codex resume --last`. For a new session, `loomy start --print` shows the exact command (model and effort) and copies the prompt. |
| 🪟&nbsp;**Desktop&nbsp;apps** | In the Claude app (Code tab) or the Codex app: open the **project folder**, pick the model and effort shown by `loomy start --print`, paste the prompt it copied. To resume, reopen the project conversation in the app. |

> [!NOTE]
> Resuming is automatic. With Claude Code, a hook installed by `loomy init` hands the context (phase, what you need to do, latest delegations) to every session opened in the project, and notes when it closes; in private mode, it also backs up the AI files. Codex gets the same hooks through `.codex/hooks.json`: the first time it runs in the project, it asks you to trust the folder and then to approve the Loomy hooks; accept both to turn on automatic resuming. Until then, `AGENTS.md` and the `loomy start` prompt ask it to read the context itself.
>
> Sessions stay on the machine where they were opened. On another machine, `loomy start` opens a new session: the lead agent rereads `START.md`, the brief and the recorded phase, and picks up where the project is. In an app, allow the lead agent to run the `.loomy/scripts/` scripts: that is how it delegates to the other tool and records phases.

### 2. Follow the phases, and know when it is your turn

`loomy watch`, in a second terminal, shows the current phase, **what the agent is doing** and **what you need to do**: answer its questions (Interview), approve its proposal (Approval), review the diffs and the commit.

### 3. Then: day-to-day development

After the bootstrap, `START.md` is gone and the lead agent follows `AGENTS.md` and `CLAUDE.md`.

- **`loomy task "…"`**: a named task (a feature, a bug, a refactor).
  - Its phases are plan → approval → build → verification → commit, followed in `loomy watch` with duration, delegations and cost.
  - The lead agent keeps the plan and a progress checklist in `.loomy/tasks/<n>-<name>.md`, so a long task can be resumed with `loomy task --resume`.
  - `.loomy/TASKS.md` lists every task, and `loomy task` alone shows the list.
- **`loomy review`**: an on-demand cross review of the current branch, or of the uncommitted changes. In hybrid mode it is done by the other model family, read-only, and saved in `.loomy/reviews/`.
- **`loomy report`**: the project's figures (bootstrap, tasks, delegations by role and model, tokens, cost).
  - `--md` writes it as Markdown in `docs/reports/`, to keep in the repository.
  - `--all` compares every Loomy project on the machine.
- **`loomy models`**: the model chains in use and the new models to evaluate. You can put a new model at the head of its chain with up to two fallbacks, switch to low-cost mode (`--thrifty on`: the fallbacks first), or suggest it on GitHub (`--issue`, one issue per model, no duplicates).

`loomy start` still opens a free session. One clear request per session; ask for a proposal before any large change; ask for a security review on sensitive topics.

### Kept up to date by itself

- **At launch.** `loomy`, `loomy start`, `loomy init`, `loomy task`, `loomy audit` and `loomy review` check the following, without slowing anything down (remote versions are cached once a day):
  - is there a newer Loomy?
  - is Claude Code or Codex too old for the routed models, or does it not start?
- **One question.** If something is needed, one question, then everything is done in one go and the command goes on. Loomy restarts itself after updating.
- **The model catalog** is updated silently.
- **Older projects** get the relays of new commands automatically.
- **Turning it off:** `loomy config set auto_update no`.

**Repair that insists.** `loomy doctor --fix` (and the question at launch) bring Claude Code and Codex to a working version, whatever the install method (official installer, npm, Homebrew, desktop app). Steps are tried in order, each one checked before going on:
1. update in place, with the install's own method;
2. reinstall with that method;
3. removal of an older copy that hides a recent one in the PATH (the classic "the update changed nothing");
4. clean reinstall: every removable copy, then the official installer.

Settings, logins and conversations (`~/.claude`, `~/.codex`) are never touched. Each step is logged in `~/.config/loomy/logs/repair-<tool>.log`. `loomy doctor` lists every copy found in the PATH, with its method and version.

### 4. Update, resume or reset

| Need | Command |
|---|---|
| Update&nbsp;Loomy | `loomy update`: every project benefits right away (its scripts are relays to the installed Loomy); `loomy init --update` is only for new document templates, and once for pre-0.3 projects (keeps brief, phase and journal) |
| Project&nbsp;already&nbsp;initialized | `loomy init` offers: resume, update, redo the questionnaire, reset |
| Redo&nbsp;the&nbsp;questionnaire | `loomy brief` |
| Restart&nbsp;the&nbsp;bootstrap | `loomy init --reset`: START.md copied again, phase reset, questionnaire rerun with your previous answers |

---

## 🔒 AI files: versioned, local or private

The files that guide the agents (`AGENTS.md`, `CLAUDE.md`, `.ai/`, `.claude/`, `.codex/`, `.loomy/`, `START.md`) are your working rules. GitHub sets visibility **per repository**, not per file: a public repository shows everything in it. The questionnaire asks where to keep them, with a default based on your repository.

The questionnaire also offers to **create the project's GitHub repository**, private or public, with a name taken from the project name that you confirm or edit. In separate private repository mode, the AI files repository name (`<repo>-ai`) is confirmed too, both together. An existing repository with a different name is flagged, with the rename command; Loomy never renames anything itself.

| Mode | For | What happens |
|---|---|---|
| **Versioned** | private repository *(default)* | they live in the repository: available everywhere, read by online agents |
| **Local** | public repository, no backup | excluded through `.git/info/exclude` (invisible in the repository); lost if you change machines |
| **Separate private repository** | public repository *(recommended)* | excluded from the project and backed up in a private GitHub repository `<project>-ai` that tracks only these files |

See the mode and the backup state:

```bash
loomy privacy
```

Switch mode (one of the three):

```bash
loomy privacy versioned
```

```bash
loomy privacy local
```

```bash
loomy privacy private
```

Back up the AI files to the private repository (the lead agent also does it at the end of each step):

```bash
loomy privacy sync
```

On another machine, after cloning the project, get its AI files back:

```bash
loomy privacy restore <your-account>/<project>-ai
```

> [!WARNING]
> A file already pushed to a public repository stays in its history. When you switch to local or private, `loomy privacy` lists the files still tracked and gives the command to stop tracking them without deleting them from your disk. `--remote <URL>` lets you use another host than GitHub for the private repository.

---

## 📈 Live tracking

Everything happens in the terminal, with no dependency. **Nothing starts on its own**: you start tracking when you want, in a second terminal.

| Command | View |
|---|---|
| <code>loomy&nbsp;status</code> | Snapshot: phases, running delegations, activity, cost per model, subscriptions, Git |
| <code>loomy&nbsp;watch&nbsp;[N]</code> | 🖥️ The same screen refreshed every second (or every N seconds): running delegation with spinner, timer and estimated progress, highlighted changes, notification (macOS) and bell on each phase, failure or end of bootstrap. Keys: `q` quit, `c` compact or full view, `l` journal, `s` open the session. Compact view in a small terminal |
| <code>loomy&nbsp;start&nbsp;--watch</code> | 🪟 The lead agent session and live tracking side by side (or stacked in a narrow terminal), through tmux or iTerm2; tracking closes with the session |
| <code>loomy&nbsp;log&nbsp;[-n&nbsp;N]&nbsp;[-f]</code> | Readable journal in local time, optionally streamed (`--raw`: raw JSON); `--since YYYY-MM-DD` reaches into monthly archives; `--csv` exports costs |

**What is live.** The screen rereads the project every 2 seconds. Delegations to Claude or Codex appear as soon as they start, with their timer, then their cost; an interrupted one disappears on its own. The phase changes when the lead agent records it (`START.md` asks it to at each step). Work the lead agent does itself, in its session, is not journaled: you follow it in its session.

The journal (`.loomy/logs/events.jsonl`) stays on your machine and is excluded from Git automatically. `LOOMY_JOURNAL=0` disables it, `LOOMY_JOURNAL_TASKS=0` leaves task text out of it.

### 💳 Claude and ChatGPT subscriptions

Loomy knows whether you pay per use (API) or by subscription, tool by tool:

| Plan | What Loomy shows |
|---|---|
| API | the real **cost** (Claude) or an estimate from tokens (Codex), per task and per month |
| Claude&nbsp;Pro&nbsp;·&nbsp;Max&nbsp;5x&nbsp;·&nbsp;Max&nbsp;20x&nbsp;·&nbsp;Team | the **share of your quota in use**: 5-hour and weekly windows, with their reset time; **tokens** per task instead of dollars |
| ChatGPT&nbsp;Plus&nbsp;·&nbsp;Pro&nbsp;·&nbsp;Business | the same, from the windows Codex reports |

```text
◇  PLANS  quota for subscriptions, cost for the API
│  Claude          Claude Pro · 5 h 42 % (resets 12:57) · week 86 % (resets Thu 23:17)
│  Codex           ChatGPT Business · week 12 % (resets Wed 19:30)
```

`loomy watch` notifies you when a quota crosses 80 %, then 95 %.

**Automatic switch near the end of a quota.** From 95 % of a subscription quota (or when the tool reports its limit reached), the work moves to the other tool, if it is installed and has room left:
- a delegation to Codex (executor, reviewer…) is run by Claude, on the model and effort the routing gives that role on the Claude side, and vice versa;
- a role that writes, moved to Claude, gets accepted edits and shell commands only inside Claude Code's sandbox (the project folder, no network), like Codex's `workspace-write` sandbox; read-only roles stay read-only;
- the lead agent receives the same kind of answer as usual; the switch is announced, logged (⇄ in `status`, `log` and `stats`) and shown in the plans section;
- `loomy start` opens the lead agent session on the other tool when its own is nearly exhausted (`LOOMY_NO_SWITCH=1 loomy start` to keep it);
- no ping-pong: a switched delegation never switches back, and nothing moves when both tools are exhausted.

Threshold: `loomy config set quota_switch 90` (a percentage), or `off` to never switch.

Where the figures come from, without network or credentials:
- **Codex** writes its quota into its own session logs (`~/.codex/sessions`); Loomy reads the latest reading.
- **Claude Code** gives its status line command a documented `rate_limits` field. `loomy init` adds a small Loomy status line to the project (`.claude/settings.json`) that saves it, then shows **your own status line** if you have one (an existing project status line is never replaced). The Claude quota appears once a session has answered in a Loomy project.

Claude plan: `api`, `pro`, `max5`, `max20`, `team` or `enterprise`

```bash
loomy config set plan_claude max20
```

ChatGPT / Codex plan: `api`, `plus`, `pro100`, `pro200`, `business` or `enterprise`

```bash
loomy config set plan_codex pro200
```

Custom plan price ($ per month), used by `loomy stats` to compare with the API value of your work

```bash
loomy config set plan_claude_price 180
```

### 📊 Detailed statistics

```bash
loomy stats
```

Delegations and success rate, total and average durations, tokens (in, from cache, out), and Claude Code's own work (lead agent, sub-agents), then by role, by model (with the cache share) and by day, and your plans. With a subscription, amounts show as `≈$…`: what the work would cost through the API, covered by the plan, next to its monthly price. `--days 7` or `--since YYYY-MM-DD` for a period; `loomy log --csv` for the raw figures.

---

## 🎯 The lead agent and its roles

The main session, the **lead agent**, keeps the best reasoning to plan, delegate, decide and verify. The rest of the work goes to dedicated roles.

| Role | 🟠 Full Claude | 🔵 Full Codex | 🟣 Hybrid, Claude lead | 🟣 Hybrid, Codex lead |
|---|---|---|---|---|
| 🎯&nbsp;**Lead&nbsp;agent** | Opus 5.5 · high | Sol 6.1 · high | **Opus 5.5 · high** | Sol 6.1 · high |
| 🏛️&nbsp;Architect | Opus 5.5 · high | Sol 6.1 · high | Opus 5.5 · high | Opus 5.5 · high ⇄ |
| 🐞&nbsp;Debugger | Opus 5.5 · high | Sol 6.1 · xhigh | Opus 5.5 · high | Opus 5.5 · high ⇄ |
| 🔒&nbsp;Security | Opus 5.5 · high | Sol 6.1 · high | Opus 5.5 · high | Opus 5.5 · high ⇄ |
| 🔍&nbsp;Reviewer | Sonnet 5.5 · high | Sol 6.1 · high | Sol 6.1 · high ⇄ | Sonnet 5.5 · high ⇄ |
| 🛠️&nbsp;Developer | Sonnet 5.5 · medium | Sol 6.1 · high | Sonnet 5.5 · medium | Sol 6.1 · high |
| ⚙️&nbsp;Executor | Sonnet 5.5 · medium | **Luna · max** | **Luna · max** ⇄ | **Luna · max** |
| 🔎&nbsp;Explorer | Haiku 4.5 · low | Luna · low | Haiku 4.5 · low | Luna · low |
| 📚&nbsp;Documenter | Sonnet 5.5 · low | Sol 6.1 · low | Sonnet 5.5 · low | Sol 6.1 · low |

<sub>Balanced profile. ⇄ = role run by the other tool, through a bridge.</sub>

**Budget profiles.** The lead agent always stays on the top model; only role efforts and models change:
- **Thrifty:** Claude lead on Sonnet 5.5 `medium` (Codex lead on Sol 6.1 `medium`), specialists at `medium`, execution on fast models;
- **Balanced (default):** the matrix above;
- **Max quality:** lead agent and specialists at `xhigh`, reviews on the top model, execution on Sol or Sonnet `high`.

**Fallbacks.** If the mode asks for both tools and one CLI is missing, routing falls back to the full matrix of the available tool. If the lead tool is missing, the other one leads.

---

### 🧾 Structured delegations

Agents normally exchange tasks and results in prose. With **structured delegations** (a questionnaire choice, recommended), they use fixed fields instead: fewer tokens, nothing lost in the wording, and results the lead agent and the bridges can check.

```text
GOAL / SCOPE / FILES / ACCEPTANCE                          ← the lead agent's task
STATUS: done | partial | blocked                           ← every role's answer
SUMMARY · FINDINGS (path:line, evidence) · FILES · CHECKS · RISKS · NEXT
```

The bridges add this contract to their prompt, generated Claude subagents carry it, and the lead agent is told to act on `STATUS`. The log records the outcome: `loomy status` and `loomy log` mark ◐ partial and ■ blocked results, `loomy stats` shows how many answers followed the format. Projects set up before this option keep free text; switch any project with `loomy brief` (questionnaire again) or for all of them with `loomy config set delegation_format structured` (`auto`: each project's choice).

This is a text protocol that works with Claude and Codex as they are. Exchanging internal model states ("latent communication") is still research: it needs access to the models' internals, which the Claude and Codex products don't offer.

---

## 📊 Why this split

<sub>Analysis of 2026-09-23. "AA" = independent measurements by Artificial Analysis. Details, caveats and sources (in French): <a href="docs/MODEL_CATALOG.md">docs/MODEL_CATALOG.md</a>.</sub>

| Model | 💵 Price ($ per million tokens, in / out) | Cost per AA task | AA Coding Agent Index | Terminal-Bench 4.0 | 🏷️ Role |
|---|---|---|---|---|---|
| GPT&#8209;6&#8209;Luna | **0.10 / 0.50** | **$0.07** | 41 | 🔻 13 % | executor, explorer |
| GPT&#8209;6.1&#8209;Sol | 2 / 10 | about $1.50 per DeepSWE task | — | DeepSWE 75.2 % (vendor) | every Codex role except execution, from 0.7.2 |
| GPT&#8209;6&#8209;Sol | 2 / 10 | $0.13 → $1.06 | 57 | 43 % | fallback for GPT-6.1 Sol |
| GPT&#8209;6&#8209;Astra | 10 / 50 | $0.82 → $3.26 | **62** | 59 % | fallback at the top tier, or forced: `loomy config set model.codex.top gpt-6-astra` |
| Claude&nbsp;Sonnet&nbsp;5.5 | 2 / 10 | $0.41 → $7.60 | — | 70.6 % (vendor) | developer, reviewer (Claude), Thrifty lead agent |
| Claude&nbsp;Opus&nbsp;5.5 | 4 / 20 | $0.55 → $5.98 | not published | **59.6 %** | 🏆 lead agent and specialists |
| Claude&nbsp;Fable&nbsp;5.1 | 10 / 50 | $7.63 | 62 | 55.8 % | ❌ superseded by Opus 5.5 |

- 🥇 **Opus 5.5 is the best lead agent.** It ranks first on the AA Intelligence Index and leads agentic work. At high effort it costs less per task than Astra at max, for a better score.
- ⚙️ **GPT-6-Luna max is the best-value executor, not an autonomous agent.**
  - It scores 66.6 % on bounded fixes for $0.22, against $2.74 for Sol.
  - On long autonomous terminal work it drops to 13 %.
  - So it executes precise tickets under the lead agent, nothing more.
- 🐎 **GPT-6.1 Sol runs the Codex side.** It matches Astra on DeepSWE (75.2 % against 74.8 %) for about a fifth of the cost, and Astra was found less reliable lately in real use: Astra stays as its fallback, and can be forced with `loomy config set model.codex.top gpt-6-astra` (`auto` to go back).

---

## ✅ Prerequisites

| | 🟢 Minimum | ⭐ Ideal |
|---|---|---|
| **System** | macOS, bash ≥ 3.2 (the macOS one works), `git`; Linux: tested automatically (CI), not yet validated in real use | + `gh` logged in |
| **AI** | **one** CLI: Claude Code ≥ 2.1.280 **or** Codex ≥ 0.155, logged in | **both**, installed in the terminal and detected by `loomy doctor`: hybrid mode |
| **Models** | those of your tool | all answer `loomy doctor --live` |
| **Comfort** | none (built-in questionnaire, no dependency) | clipboard, to copy the start prompt |

**Install Claude Code and Codex in the terminal.** `loomy doctor` shows what it detects and prints these commands for a missing CLI; `loomy doctor --fix` offers to run them for you.

**Claude Code** (official installer)

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

or with Homebrew

```bash
brew install --cask claude-code
```

**Codex** (official installer)

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

or with Homebrew

```bash
brew install --cask codex
```

Then run `claude`, then `codex`, once each to log in (Claude Pro, Max, Team plan or Console account; ChatGPT account for Codex), and check with `loomy doctor --live`.

---

## 🛠️ Commands

| Command | Purpose |
|---|---|
| 🏠&nbsp;<code>loomy</code> | home: where the project stands, what is expected, and the next step in one choice (outside a project: create one) |
| 📦&nbsp;<code>loomy&nbsp;init&nbsp;[dir]</code> | creates the folder if needed (or offers to create it from the project name), then initializes the project, new or existing: questionnaire, then structure set up by the lead agent; on an initialized project: resume, `--update`, `--reset` (`--no-wizard`, `--yes`, `--answers`; existing Git project: `--no-branch` to stay on the current branch) |
| 📝&nbsp;<code>loomy&nbsp;brief</code> | reruns the questionnaire for the current project |
| 🔒&nbsp;<code>loomy&nbsp;privacy</code> | AI files visibility: `versioned`, `local`, `private`; `sync`, `restore` for the private repository |
| ▶️&nbsp;<code>loomy&nbsp;start</code> | starts or resumes the lead agent session (`--resume`, `--new`, `--print`, `--watch`) |
| 🩺&nbsp;<code>loomy&nbsp;doctor</code> | checks prerequisites (`--fix` fixes, GitHub included: installs `gh`, logs in, checks git access to the Loomy repository; `--live` tests every model) |
| 💬&nbsp;<code>loomy&nbsp;feedback</code> | reports a bug or an idea: prefilled GitHub issue (versions, anonymized project state, no name, goal or task text), sent only after your approval; `--print` shows the text |
| 🧭&nbsp;<code>loomy&nbsp;route</code> | role → model → effort matrix · `lead` · `get <role>` · `markdown` · `all` · `claude-agents` · `codex-profiles` |
| 🔀&nbsp;<code>loomy&nbsp;delegate&nbsp;codex&nbsp;&lt;role&gt;&nbsp;"…"</code> | hands a role to Codex (executor, developer, documenter can write; the others are read-only) |
| 🔀&nbsp;<code>loomy&nbsp;delegate&nbsp;claude&nbsp;&lt;role&gt;&nbsp;"…"</code> | hands a role to Claude, read-only (architect, debugger, security, reviewer, explorer) |
| 🔬&nbsp;<code>loomy&nbsp;assess</code> | assessment of an existing project, without AI: stack, commands, tests, CI, conventions, Git history, sensitive areas, debt (`.loomy/assessment.md`; `--print` to only show it) |
| ✅&nbsp;<code>loomy&nbsp;task&nbsp;"…"</code> | a named task for the lead agent: plan, approval, build, verification, commit, followed in `watch`; without argument, the list; `--resume`, `--print` |
| 🔍&nbsp;<code>loomy&nbsp;review</code> | on-demand cross review of the current branch (`[base]`) or of uncommitted changes (`--working`, `--staged`), read-only, saved in `.loomy/reviews/` |
| 🧾&nbsp;<code>loomy&nbsp;report</code> | project figures: bootstrap, tasks, delegations by role and model, tokens, cost; `--md [dir]` Markdown in `docs/reports/`; `--all` every project |
| 🧬&nbsp;<code>loomy&nbsp;models</code> | model chains and new models to evaluate; head of a chain with two fallbacks (this machine), `--thrifty on\|off`, `--issue` (GitHub suggestion) |
| 🛡️&nbsp;<code>loomy&nbsp;audit</code> | security audit of an existing Git repository, a mission rather than a project (see below): `--resume`, `--print`, `--yes`, `--scope`, `--depth quick\|standard\|deep`, `--fixes report\|plan\|branch` |
| 📈&nbsp;<code>loomy&nbsp;status</code>&nbsp;·&nbsp;<code>loomy&nbsp;watch</code>&nbsp;·&nbsp;<code>loomy&nbsp;log</code> | tracking (see above) |
| 📊&nbsp;<code>loomy&nbsp;stats</code> | detailed statistics: by role, model and day, durations, tokens, cost or quota (`--days N`, `--since YYYY-MM-DD`) |
| 🎚️&nbsp;<code>loomy&nbsp;effort</code> | reasoning effort of the lead agent for this project (`loomy effort low`, menu without argument), or of a role (`loomy effort executor high`); `--list`, `--reset`; applied at the next `loomy start` |
| ⚙️&nbsp;<code>loomy&nbsp;config</code> | preferences (`list`, `get`, `set`): `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`yes`: `loomy start` always opens tracking alongside), `notify` (`no`: no notifications in `loomy watch`), `quota_switch` (95 by default: from this share of a subscription quota, work moves to the other tool; `off`: never), `delegation_format` (`structured`, `free` or `auto`: each project's choice), `lang` (`fr`, `en` or `auto`: interface language, detected by default) |
| 🌳&nbsp;<code>loomy&nbsp;worktrees&nbsp;&lt;task&gt;</code> | two separate worktrees for parallel mode |
| 🔄&nbsp;<code>loomy&nbsp;update</code>&nbsp;·&nbsp;<code>loomy&nbsp;version</code> | updates Loomy, for every project at once; `update --catalog`: only the model and price catalog; `version --all` lists every install |
| 🗑️&nbsp;<code>loomy&nbsp;uninstall</code> | shows how to uninstall Loomy for your install method, and how to remove it from a project |
| ❓&nbsp;<code>loomy&nbsp;help&nbsp;[command]</code> | general help, or help for one command |

Tests: `tests/run.sh` runs every command in real conditions (bash, git, a pseudo-terminal for the questionnaire) with stubbed `claude` and `codex` CLIs, so no network and no tokens.

---

## 🤝 Collaboration modes

| Mode | Principle | When |
|---|---|---|
| 🧍&nbsp;**SOLO** | a single tool does everything | small projects, tight budget |
| 👀&nbsp;**REVIEW** | one implements, the other reviews the diff | substantial changes |
| 🔁&nbsp;**HANDOFF** | clean checkpoint + `.ai/HANDOFF.md`, the other takes over | switching tools midway |
| 🌳&nbsp;**PARALLEL** | two worktrees, disjoint scopes | truly independent work |
| 🎯&nbsp;**ORCHESTRATED** | the lead agent delegates each role to the best model of both families | **recommended** when both tools are installed |

---

## 📚 Going further

<details>
<summary><b>📁 What the bootstrap generates in your project</b></summary>

```text
my-project/
├── AGENTS.md                  # Codex entry point (short)
├── CLAUDE.md                  # Claude Code entry point (short)
├── PROJECT.md                 # product intent, scope, constraints
├── ARCHITECTURE.md            # when useful
├── .ai/
│   ├── AI_WORKFLOW.md         # shared collaboration contract
│   ├── AI_ORCHESTRATION.md    # cross-model delegation rules
│   ├── AI_MODEL_ROUTING.md    # role → model → effort matrix
│   └── HANDOFF.md             # temporary, during a handoff
├── .claude/agents/            # generated subagents (model + effort)
├── .loomy/                    # relays, templates, brief, state and log (logs/ ignored by Git)
└── docs/decisions/            # ADRs, only for important decisions
```

</details>

<details>
<summary><b>🌐 Languages</b></summary>

<br>

Loomy speaks English, and French when your system language is French (`LC_ALL`, `LC_MESSAGES`, `LANG`, then the macOS system language). Force it with `loomy config set lang fr|en|auto` or `LOOMY_LANG`.

The language also picks the documents the agents read (`START.md`, templates, roles, skills: French copies live in `fr/`), the startup brief and the delegation prompts. The project documentation language is a separate questionnaire answer.

For contributors: interface strings are written in English in the code (`t "English sentence"`); the French translations live in `scripts/lib/i18n/fr.tsv`, compiled by `tools/i18n-build.sh`. `tools/i18n-missing.sh` lists the sentences not translated yet, and the tests fail while any is missing.

</details>

<details>
<summary><b>🏗️ Existing project, security audit, end of the bootstrap</b></summary>

<br>

- **Existing project.** Run `loomy init` in the repository. Loomy switches to a dedicated `loomy/adopt` branch (the current one stays untouched, uncommitted work stays as it is), writes an assessment without AI (`.loomy/assessment.md`: stack, real commands, tests, CI, conventions, Git history, sensitive areas, debt), and the lead agent proposes an adoption plan: `PROJECT.md` and `ARCHITECTURE.md` rebuilt from the code, `AGENTS.md` and `CLAUDE.md` aligned with the repository's commands, roles sized to its risk. Nothing existing is overwritten, no application code changes without your approval, and merging back goes through a pull request you accept.
- **Security audit.** It runs on demand, with the official Cloudflare skill. Install it with `.loomy/scripts/install-security-audit.sh --global`, then ask for a full audit without code changes.
- **End of the bootstrap.** `START.md` is archived in `.ai/bootstrap/` or deleted, as you chose. It has no authority afterwards.

</details>

<details>
<summary><b>🔄 Updating the model catalog</b></summary>

<br>

The catalog lives in `catalog/models.conf` (published, fetched by `loomy update --catalog`) and `scripts/lib/models.sh` (built-in values): model chains per tier, prices, minimum CLI versions. The update protocol is in `docs/MODEL_CATALOG.md`.

To try another model on a single machine without changing anything: `AI_MODEL_CODEX_FAST=gpt-6-sol loomy route`, or pin it with `loomy config set model.codex.fast gpt-6-sol`. If the Codex CLI is installed somewhere unusual, give its path with `LOOMY_CODEX_BIN`.

</details>

<details>
<summary><b>📦 Repository content</b></summary>

```text
loomy/
├── bin/loomy                  # single command
├── install.sh · package.json  # shell, npm and bun install
├── START.md · VERSION · CHANGELOG.md · SECURITY.md · README.md · README.fr.md
├── scripts/
│   ├── install-into-project.sh · init-wizard.sh · ai-doctor.sh · ai-route.sh · ai-status.sh
│   ├── delegate-to-claude.sh · delegate-to-codex.sh · detect-ai-tools.sh
│   ├── create-hybrid-worktrees.sh · install-security-audit.sh
│   └── lib/                   # ui.sh · i18n.sh · models.sh · journal.sh · config.sh · i18n/fr.tsv
├── templates/                 # AGENTS, CLAUDE, WORKFLOW, ORCHESTRATION, MODEL_ROUTING, HANDOFF, PROJECT, ARCHITECTURE, ADR
│   └── claude-agents/         # architect, debugger, developer, documenter, executor, explorer, reviewer, security
├── skills/project-bootstrap/  # SKILL.md + references
├── agents/ROLE-CATALOG.md · external-skills/security-audit.md
├── fr/                        # French copies of START.md, templates, agents and skills
├── catalog/models.conf · docs/DESIGN.md · docs/MODEL_CATALOG.md
├── tools/                     # i18n-build.sh · i18n-missing.sh
└── tests/run.sh · tests/stubs/  # test suite without network
```

</details>

---

## 🛡️ Security audit

`loomy audit` audits an existing Git repository, Loomy project or not. It is a mission with a report as its deliverable, not a project to build.
- **Questions**: scope, depth (quick, standard, deep), and deliverables: report only, report and fix plan, or fixes as well on a `loomy/audit-fixes` branch.
- **Method**: [Cloudflare's official security-audit skill](https://github.com/cloudflare/security-audit-skill) (MIT), installed for this repository only when you agree.
- **Team**, through Loomy's bridges, every delegation logged:
  - the auditor (security role: Opus 5.5, or GPT-6.1 Sol with a Codex lead) leads;
  - an explorer maps the attack surface, on a rigorous model (Sonnet 5.5 medium, or GPT-6-Sol): a missed entry point is never analysed;
  - Claude Sonnet 5.5 at high effort, rigorous, re-checks every finding independently;
  - the other model family (GPT-6-Sol) gives a second opinion on Critical and High findings;
  - a fast writer (GPT-6-Luna) drafts the report and the fix plan as findings get validated, from validated facts only; the auditor reviews every draft. Without Codex, a local model served by [LM Studio](https://lmstudio.ai) takes this role when one answers (text only, nothing leaves the machine, logged at no cost).
- **Phases**, followed in `loomy watch` like a bootstrap: scope → analysis → validation of findings → report → fix plan → fixes.
- **Report**: `REPORT.md` and `FIX_PLAN.md` go to `.loomy/audits/<date>-security/`, kept out of Git, because they can describe exploitable weaknesses. Your branches are never touched and nothing is pushed.

---

## 🔐 Security

What Loomy guarantees (your project never pushed or deleted without you, existing projects untouched, catalog read as data, untrusted project files sanitised, private temporary files) and how to report a vulnerability: [SECURITY.md](SECURITY.md).

---

## 🔮 Roadmap

| Status | Feature |
|---|---|
| ✅&nbsp;0.1 | `loomy` command, questionnaire, doctor, lead + roles routing, bridges, journal, live terminal tracking (full screen, `start --watch`, notifications), per-project effort, subscriptions, Homebrew, npm, bun and shell installs, test suite |
| ✅&nbsp;0.2 | **Consolidate, before testers arrive**: done |
| ✅ | `loomy start --watch` joins an open session instead of closing it; temporary scripts cleaned up; platforms stated accurately (macOS, Linux tested automatically) |
| ✅ | macOS and Linux tests on every push (GitHub Actions) |
| ✅ | `loomy feedback`: prefilled GitHub issue (version, doctor, end of journal, anonymized brief) |
| ✅ | Simpler tester install: `loomy doctor --fix` chains the `gh` steps |
| ✅&nbsp;0.3 | **Harden**: done |
| ✅ | No more script copies in each project: a link to the installed Loomy; `loomy init --update` only for template changes |
| ✅ | Model and price catalog updated without a new release (`loomy update --catalog`), warning when a routed model disappears |
| ✅ | Real costs: Claude Code lead (`Stop` hook) and sub-agents (`SubagentStop` hook), measured from the transcript at list price; CSV export |
| ✅ | Monthly journal archive, `loomy log --since` |
| ✅&nbsp;0.3.5 | **Fixed-frame interface**: header (logo, project, context), a body that alone changes, footer (keys, version); the home screen opens status, journal, visibility and help inside the frame; nothing piles up in the terminal |
| ✅&nbsp;0.3.7 | **Autonomy and stop points** in generated instructions (`AGENTS.md`, `CLAUDE.md`): the agent moves on alone within a bounded task and stops before anything destructive, following Anthropic's Opus 5.5 guidance |
| ✅&nbsp;0.3.8 | **Fast-changing models**: per-tier fallback chains in the catalog (newest first, automatic fallback for those without access), availability learned on each machine (`doctor --live`, a refused delegation), pinnable model (`loomy config set model.claude.mid …`), role balance editable from the catalog, new catalog announced; protocol in `docs/MODEL_CATALOG.md` |
| ✅&nbsp;0.4 | **English and French interface** |
| ✅ | Language detected automatically (`LC_ALL`, `LC_MESSAGES`, `LANG`, then the system language on macOS): French when it starts with `fr`, **English by default** otherwise or when nothing is detectable (macOS and Linux); setting `loomy config set lang fr\|en\|auto` |
| ✅ | Every interface text goes through a dictionary, migrated screen by screen: frame and home, `watch` and `status`, `start` and `effort`, questionnaire and setup, doctor, help and messages |
| ✅ | Project document language suggested from the detected language; test covering both languages |
| ✅&nbsp;0.4.1 | **English first**: code, help, agent documents (`START.md`, templates, roles, skills), startup brief, delegation prompts, README and changelog in English; French is a translation (`scripts/lib/i18n/fr.tsv`, `fr/`) used when French is detected |
| ✅&nbsp;0.5 | **Adopting an existing project** |
| ✅ | `loomy init` on an already developed, versioned project (Git, remote, branches): nothing is overwritten, everything goes through a dedicated branch and an approval |
| ✅ | Initial assessment (`loomy assess`): languages, frameworks, structure, dependencies, tests, CI, code conventions, existing docs, Git history (activity, sensitive areas, authors), debt and risks spotted |
| ✅ | Initial adaptation from that assessment: `PROJECT.md`, `ARCHITECTURE.md` and decisions rebuilt from the code, `AGENTS.md` and `CLAUDE.md` aligned with the repository's conventions (test, lint, build commands), roles, routing and effort tuned to the project's size and risk |
| ✅ | Adoption plan reviewed before any commit: what was understood, what remains to confirm, prioritized recommendations |
| ✅&nbsp;0.5.1 | Screen-by-screen check of every command, in English and French |
| ✅&nbsp;0.5.2 | Security and robustness review ([SECURITY.md](SECURITY.md)) |
| ✅&nbsp;0.5.3 | **Real subscription quotas**: share of the Claude and Codex quotas in use (5-hour and weekly windows) instead of dollars with a subscription, tokens per task, alerts at 80 % and 95 %; `loomy stats` for detailed statistics |
| ✅&nbsp;0.5.4 | **Automatic switch near the end of a quota**: from 95 % of a subscription quota, the roles (and a new lead agent session) move to the other tool with a suitable model, writing roles inside Claude Code's sandbox; `quota_switch` setting |
| ✅&nbsp;0.5.5 | **structured delegations** (optional, chosen in the questionnaire): tasks and results as fixed fields, checked by the bridges, outcomes in status, log and stats; Codex CLI found again after a ChatGPT app update |
| ✅&nbsp;0.5.6 | **existing GitHub repository**: a taken name is detected in the questionnaire; another name, or the repository linked (its content fetched, setup on a `loomy/setup` branch to reconcile by pull request), never overwritten |
| ✅&nbsp;0.5.7 | **Tab edits a suggestion** in text fields (project name, repository name…); taken repository name: `<name>-loomy` suggested |
| ✅&nbsp;0.5.8 | **Claude Sonnet 5.5** heads everyday Claude work (Sonnet 5 as fallback); lead agents unchanged |
| ✅&nbsp;0.5.9 | **Thrifty profile: Sonnet 5.5 as the Claude lead agent** (`medium`), Opus kept for the hard roles; checked in a real orchestration test |
| ✅&nbsp;0.6.0 | **Security audit** (`loomy audit`): a mission with its own phases followed in `loomy watch`, Cloudflare's security-audit skill, a multi-agent team (auditor, explorer, Sonnet 5.5 high validator, cross review), report and fix plan kept out of Git, fixes on a branch when allowed |
| ✅&nbsp;0.6.1 | audit team entirely on rigorous models (explorer on Sonnet 5.5 or GPT-6-Sol) |
| ✅&nbsp;0.6.2 | first local model use: the audit writer falls back to LM Studio when Codex is not available (text only, nothing leaves the machine) |
| ✅&nbsp;0.7.0 | **Day-to-day work after bootstrap** |
| ✅ | `loomy task "…"`: a named task handed to the lead, tracked in `watch` (phases, cost, duration), through approval and commit; a progress file per task (`.loomy/tasks/`, index in `.loomy/TASKS.md`) kept by the agent during long tasks |
| ✅ | `loomy models`: spots new models to evaluate (Codex model list, vendor APIs when a key is set, published catalog), puts one at the head of its chain with up to two fallbacks, a low-cost mode that prefers fallbacks; a GitHub suggestion issue per new model (`models` label, no duplicates) |
| ✅ | `loomy review`: on-demand cross review of the current branch or diff |
| ✅ | Project templates (SaaS web app, landing page, REST API, CLI, email templates) that prefill the brief and give a starting structure |
| ✅ | `loomy report`: project summary (tasks, costs, delegations), cross-project comparison, Markdown file to keep in the repository |
| ✅&nbsp;0.7.1 | **GPT-6.1 Sol** heads everyday Codex work (GPT-6 Sol as fallback) |
| ✅&nbsp;0.7.2 | **GPT-6.1 Sol for every Codex role** except execution; Astra as fallback, or forced with `loomy config set model.codex.top gpt-6-astra` |
| ✅&nbsp;0.7.3 | **Current version** · **kept up to date by itself**: one question at launch updates Loomy, Claude Code and Codex; a repair that insists, up to a clean reinstall |
| 🎯&nbsp;RC | **Release candidate: validation in real conditions** |
| | Tester feedback (`loomy feedback`) processed |
| | Questionnaire and UI split into smaller modules, tests grouped by topic |
| | Configurable color theme (`loomy config`) for terminals that don't render bold |
| | Short README ("5 minutes to start"), full reference separately |
| | Public repository and token-free Homebrew, when decided |
| 💡 | **3D game project type (Three.js)**, validated by a test ([test notes](docs/THREEJS_GAME_TEST.md)): the questionnaire offers [threejs-game-skills](https://github.com/majidmanzarpour/threejs-game-skills) (MIT, Majid Manzarpour) installed for the project; gameplay by Sonnet 5.5 and Luna, a graphics pass by Opus with its AAA graphics skill; the director skill stays a tool of the lead agent; optional paid asset APIs flagged |
| 💡 | [Jev](https://github.com/WXK-AI/jev-opus) integration: Opus 5.5 effort readjusted at every step during Claude delegations, when Jev is installed |
| 💡 | Local model through [LM Studio](https://lmstudio.ai) (to be decided): a role run on a local model, for confidential code or to save on mechanical tasks (API cost, or subscription quota), its work reviewed by the lead; most likely by reusing a Codex profile pointed at LM Studio rather than a third model family. Tested on 2026-09-28 with `qwen/qwen3.8-27b` on an M3 Max with 48 GB: feasible through Codex and Claude Code (small task done in about 2.5 min when the delegation runs light) — [test notes](docs/LOCAL_MODEL_TEST.md). Not for judging code in security audits, which stays on the most rigorous models (Opus 5.5, Sonnet 5.5, GPT-6-Sol). First use shipped in 0.6.2: the audit writer falls back to the local model when Codex is not available |

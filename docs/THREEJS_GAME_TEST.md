# Three.js game test: threejs-game-skills in a Loomy project

Feasibility test for a future "3D game (Three.js)" project type. Loomy's code was not changed for it.

## Source

[majidmanzarpour/threejs-game-skills](https://github.com/majidmanzarpour/threejs-game-skills) (MIT, by Majid Manzarpour), commit `8286774`. Nine skills for Codex and Claude Code:
- `threejs-game-director`, which routes to the others;
- gameplay systems, AAA-style graphics, game UI, debug and profiling, QA and release;
- optional 3D, image and audio generation through paid APIs (Tripo, Gemini, ElevenLabs), only when their keys are set.

It ships a Vite + TypeScript + Three.js scaffold, a seeded random generator, test hooks and Playwright templates.

Points to handle in an integration:
- the director also orchestrates, so in a Loomy project it must stay a tool of the lead agent;
- its credential probe sources the user's shell startup files, but prints only SET or MISSING;
- its installer targets the global skill folders by default, so Loomy should install per project.

## Setup (2026-09-29)

- **Project**: a hybrid Loomy project with a Claude lead, local only.
- **Skills**: installed per project in `.claude/skills` and `.agents/skills`, nothing global.
- **Game**: "Lumen Drift". Steer a paper-kite spirit over a mirror sea at twilight, collect light motes, avoid dark wisps, in a 90-second run.
- **Assets**: procedural only, no paid API.
- **Machine**: MacBook Pro M3 Max, 48 GB.

## Results

| Pass | Who | Time | Cost | Result |
|---|---|---|---|---|
| 1. Playable game | Sonnet 5.5 `medium` lead (Thrifty profile), game code delegated to GPT-6-Luna `max` (partial, completed by the lead) | 23 min | $0.54 | Playable, build and Playwright smoke test pass; look washed out (too much fog and bloom) |
| 2. Graphics pass | Opus 5.5 `medium`, with `threejs-aaa-graphics-builder` (visual scorecard, authoring order) | 6 min | $1.62 | Real twilight scene: contrasted dusk sky, reflective sea, floating islands with crystals, painted paper kite, restrained bloom; 36 draw calls, about 21k triangles |

The scorecard was filled by eye, without the skill's canvas inspector:
- art direction from 1 to 2.5 out of 3;
- hero (the kite) from 1 to 2;
- obstacles still weak at 1.5.

60 fps on real hardware was not measured: the test browser renders without a GPU.

## Findings

- **Cohabitation works.** The Loomy lead agent orchestrates, and the director skill was used as a method, not as a second orchestrator.
- **The graphics skill makes the difference, not the director.** When the lead skipped the specialist skills to save tokens, the result was playable but plain. The AAA graphics pass turned it into a showcase scene for about $1.60.
- **Recommended split for a Three.js game project:**
  - gameplay loop: Sonnet 5.5 plus the Luna executor;
  - graphics: a dedicated pass by Opus with `threejs-aaa-graphics-builder` and its scorecard;
  - QA: the pack's Playwright templates.
- **The bootstrap phases matter.** The test skipped them, so `loomy watch` stayed on "Discovery". A real project type keeps interview, proposal and approval (art direction, scope), then build and verification with the skills.

## Next step

Roadmap: a "3D game (Three.js)" project type in the questionnaire. It installs the pack for the project, with a note on the optional paid APIs. The routing puts the graphics pass on Opus. The generated instructions keep the director as a tool of the lead agent. The source and the license are credited.

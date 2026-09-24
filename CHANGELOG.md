# Journal des modifications

Loomy reste en 0.x tant que l'ensemble n'a pas été validé en conditions réelles. La 1.0.0 viendra après cette validation.

## 0.1.0 — 2026-09-24

Première pré-version, 100 % terminal.

### Contenu
- **Commande `loomy`** : `init`, `brief`, `doctor`, `route`, `delegate`, `status`, `watch`, `log`, `config`, `worktrees`, `update`, `version`.
- **Installation** : Homebrew (tap privé), npm, bun (archive de la release) et script shell. `loomy update` détecte la méthode utilisée.
- **Questionnaire** (`loomy init`, `loomy brief`) : douze questions en français, chacune avec la conséquence de chaque choix ; une treizième, la première fois, pour les forfaits Claude et ChatGPT. Mode non interactif (`--yes`, `--answers`) et affichage avec ou sans gum.
- **Diagnostic** (`loomy doctor`) : versions minimales des CLI, CLI Codex livrée avec les apps ChatGPT et Codex, corrections guidées (`--fix`) et appel réel de chaque modèle routé (`--live`).
- **Routage orchestrateur + rôles** : l'orchestrateur sur le meilleur modèle, huit rôles sur le modèle et l'effort fiables les moins chers, trois profils de budget, quatre environnements (full Claude, full Codex, hybride avec l'un ou l'autre en lead) et repli automatique si une CLI manque. Justification dans `docs/MODEL_CATALOG.md`.
- **Bridges** : `delegate-to-codex.sh` (rôles qui écrivent en sandbox `workspace-write`, les autres en lecture seule) et `delegate-to-claude.sh` (lecture seule).
- **Journal** (`.loomy/logs/events.jsonl`, local, exclu de Git) : début et fin de chaque délégation avec rôle, modèle, effort, durée, tokens et coût (réel pour Claude, estimé pour Codex), et changements de phase.
- **Suivi en direct dans le terminal** (`loomy status`, `loomy watch`) : phases, délégations en cours avec leur chrono, coût par modèle, forfaits (coût API, ou valeur consommée face au prix de l'abonnement), dernières délégations, Git.
- **Suite de tests** (`tests/run.sh`) : chaque commande en conditions réelles, sans réseau ni token, grâce à des doublures de `claude` et `codex`.

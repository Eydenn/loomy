# Notes de conception

Loomy sépare le comportement temporaire du bootstrap des instructions permanentes du dépôt.

- `START.md` : contrat temporaire d'installation et d'orchestration.
- `templates/AGENTS.md` : règles compactes du projet pour Codex.
- `templates/CLAUDE.md` : couche de compatibilité compacte pour Claude Code.
- `skills/project-bootstrap/` : workflow réutilisable, avec des références chargées progressivement.
- `external-skills/` : intégrations qui doivent rester à jour avec leur source d'origine.
- `scripts/` : outils d'installation déterministes.
- `scripts/init-wizard.sh` : questionnaire terminal qui recueille les réponses faciles et à fort impact avant de dépenser le moindre token. Il écrit `.loomy/brief.md`, que l'agent traite comme un entretien déjà mené. `ai-status.sh` rend visibles les phases du bootstrap et l'activité des délégations.
- `scripts/lib/models.sh` et `ai-route.sh` : le moteur de routage de l'orchestrateur et des rôles. C'est la source de vérité unique sur le modèle et l'effort de chaque rôle dans chaque environnement. Sa justification est dans `docs/MODEL_CATALOG.md`.
- `ai-doctor.sh` : vérifie que la machine peut réellement faire tourner les modèles routés avant de dépenser des tokens sur le bootstrap.

- `bin/loomy` : point d'entrée unique, installé par npm, bun, Homebrew ou `install.sh`. Il appelle les scripts ci-dessus sur le projet courant.
- `scripts/lib/journal.sh` : journal d'activité local (`.loomy/logs/events.jsonl`). Les bridges y écrivent un événement au début de chaque délégation (avec le pid du bridge) et un à la fin (même identifiant) ; `ai-status.sh` en déduit les délégations en cours et écarte celles dont le processus a disparu. Le suivi reste dans le terminal (`loomy watch`), sans dépendance, et ne démarre jamais tout seul.
- `scripts/lib/config.sh` : préférences de l'utilisateur (`~/.config/loomy/config`) : forfaits Claude et Codex, pour rapporter la valeur API consommée au prix de l'abonnement.
- `scripts/lib/phases.sh` : les dix phases du bootstrap, avec pour chacune ce que fait l'orchestrateur et ce que l'utilisateur doit faire. Source unique pour `loomy status`, `loomy watch` et `loomy start`.
- `scripts/ai-start.sh` (`loomy start`) : ouvre ou reprend la session de l'orchestrateur. Il retrouve la session précédente du dossier sur la machine (Claude range ses conversations par dossier, Codex note le dossier de chaque session) et choisit le prompt selon la phase.
- `scripts/install-into-project.sh` (`loomy init`) : sur un projet déjà initialisé, propose de reprendre, mettre à jour (`--update`, brief, phase et journal conservés) ou réinitialiser (`--reset`).
- `scripts/ai-privacy.sh` et `scripts/lib/privacy.sh` (`loomy privacy`) : visibilité des fichiers IA. Mode local : exclusion dans `.git/info/exclude`, propre à la copie et invisible dans le dépôt. Mode privé : un second dépôt Git (`.loomy/ai.git`) dont le dossier de travail est le projet lui-même et qui ne suit que les fichiers IA ; pas de copie, `sync` rejoue les changements par-dessus ceux d'une autre machine avant d'envoyer.
- `scripts/ai-context.sh` : contexte de reprise (phase, attentes, délégations, Git, fichiers IA). Installé par `loomy init` comme hooks `SessionStart` et `SessionEnd` de Claude Code (`.claude/settings.json`) et de Codex (`.codex/hooks.json`, même format), fusionnés avec un fichier existant. Codex n'exécute les hooks d'un projet qu'une fois le dossier jugé de confiance et les hooks approuvés (il le demande au premier lancement) ; la commande du hook Codex remonte depuis le dossier de la session jusqu'au projet Loomy. Les ouvertures et fermetures de session vont dans le journal ; `loomy start` note aussi les sessions Codex, dont le processus reprend son pid après `exec`.
- `scripts/ai-home.sh` : `loomy` sans argument, l'accueil qui mène à l'action suivante.
- Nom technique du projet (`slug` dans le brief, `loomy_slug`) : une seule source pour le dossier créé, le dépôt GitHub (`repo_name`) et le dépôt privé des fichiers IA (`ai_repo_name`).
- `tests/run.sh` : suite de tests de bout en bout, sans réseau ni token (doublures de `claude` et `codex` dans `tests/stubs/`).

La conception évite volontairement de précharger tous les rôles spécialisés ou un gros workflow de sécurité dans chaque session.

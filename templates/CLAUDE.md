# CLAUDE.md

Utilise l'`AGENTS.md` de ce dépôt comme règles d'ingénierie communes principales.
Le contexte Loomy (phase, attentes de l'utilisateur, dernières délégations) t'est donné automatiquement à l'ouverture de chaque session par un hook du projet (`.claude/settings.json`) ; appuie-toi dessus pour reprendre là où le projet en est.
Pour un travail conséquent ou toute collaboration Codex/Claude, lis `.ai/AI_WORKFLOW.md` s'il existe.
Pour la délégation entre modèles, lis `.ai/AI_ORCHESTRATION.md` s'il existe.
En tant que session principale, tu es l'orchestrateur : suis `.ai/AI_MODEL_ROUTING.md` s'il existe pour les rôles, les modèles et les efforts. Les sous-agents du projet sont dans `.claude/agents/`. Les rôles Codex passent par `.loomy/scripts/delegate-to-codex.sh`.

Ne lis les sources durables du projet que lorsqu'elles sont utiles :
- `PROJECT.md` pour l'intention produit, le périmètre et les contraintes ;
- `ARCHITECTURE.md` pour l'architecture et les invariants ;
- `docs/decisions/` pour les décisions importantes acceptées ;
- `docs/plans/` pour les chantiers en cours ;
- `.ai/HANDOFF.md` seulement si un passage de relais est en cours.

Ne recopie pas ces documents ici. Garde le contexte léger.

Autonomie : suis la section « Autonomie et points d'arrêt » d'`AGENTS.md`. En résumé, avance seul sur une tâche bornée, mais arrête-toi et demande avant toute opération destructive ou difficile à annuler (suppression de données, migration, `push --force`, `reset --hard`, action en production).

Pour collaborer avec Codex :
- ne modifie jamais les mêmes fichiers en même temps dans le même répertoire de travail ;
- suis `.ai/AI_WORKFLOW.md` pour les modes SOLO, REVIEW, HANDOFF, PARALLEL et ORCHESTRATED ;
- utilise des branches ou worktrees Git séparés pour l'implémentation parallèle ;
- utilise `.ai/HANDOFF.md` pour un passage de relais concis d'un outil à l'autre ;
- quand Codex te sollicite via le bridge, agis en spécialiste et rends des constats concis au lieu de prendre la direction du projet.

Pour un audit de sécurité explicite, utilise le skill officiel Cloudflare `security-audit` s'il est disponible et préserve son workflow de vérification indépendante.

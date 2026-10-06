# AI_WORKFLOW.md

## Objectif
Contrat de fonctionnement commun à Codex et Claude Code dans ce dépôt.
`AGENTS.md` et `CLAUDE.md` sont de simples points d'entrée propres à chaque outil.

## Mode par défaut
Un seul agent principal à la fois par répertoire de travail.
N'utilise les deux modèles que si une relecture indépendante, une expertise spécialisée, l'isolation du contexte, un passage de relais explicite ou des chantiers réellement indépendants justifient le surcoût.

Ne laisse jamais Codex et Claude modifier les mêmes fichiers en même temps dans le même répertoire de travail.

## Source de vérité commune
Par ordre de priorité :
1. l'instruction actuelle de l'utilisateur ;
2. les instructions du dépôt (`AGENTS.md`, `CLAUDE.md`, ce fichier, `.loomy/docs/AI_ORCHESTRATION.md`) ;
3. le code, la configuration et les schémas exécutables ;
4. les tests ;
5. `PROJECT.md` et `ARCHITECTURE.md` ;
6. les ADR acceptées ;
7. le reste de la documentation maintenue.

Signale les contradictions au lieu de trancher silencieusement.

## Modes de travail

### SOLO
Un seul agent principal mène l'investigation, l'implémentation et la vérification.
Pour les tâches petites ou très liées.

### REVIEW
L'agent A implémente. L'agent B relit de façon indépendante le diff ou le commit réel.
Le relecteur cherche des défauts concrets : régressions, cas limites oubliés, sécurité, tests, complexité inutile.
Il ne réimplémente pas, sauf demande.

### HANDOFF
L'agent A s'arrête à un point de contrôle propre et rédige `.loomy/docs/HANDOFF.md`.
L'agent B vérifie l'état du dépôt et reprend.
Supprime ou mets à jour les passages de relais périmés.

### PARALLEL
Branches ou worktrees Git séparés, avec des périmètres qui ne se chevauchent pas.
Chaque agent vérifie et committe son chantier avant l'intégration.
Relance les critères de qualité du projet après l'intégration.

### ORCHESTRATED
L'orchestrateur sollicite l'autre modèle comme spécialiste, selon `.loomy/docs/AI_ORCHESTRATION.md`.
Usage habituel : relecture, architecture, débogage, second avis sécurité, recherche ciblée.
Le spécialiste rend ses constats ; l'orchestrateur vérifie, décide et intègre.

## Coordination Git
Nommage de branches suggéré :
- `codex/<tâche>`
- `claude/<tâche>`

Avant un travail parallèle :
1. crée un commit de base propre ;
2. définis qui possède quels fichiers ou domaines ;
3. crée des worktrees ou branches séparés ;
4. donne aux deux agents le même brief et les mêmes critères d'acceptation ;
5. exige que chacun committe avant l'intégration.

Ne compte jamais sur des changements non commités comme seul moyen de passer le relais.

## Contenu d'un passage de relais
N'y consigne que :
- l'objectif ;
- le travail terminé ;
- les fichiers modifiés et le commit ;
- les vérifications et leurs résultats ;
- les problèmes et risques ouverts ;
- l'action suivante exacte.

Ne colle pas l'historique de conversation et ne recopie pas la documentation du dépôt.

## Planification et délégation
- SIMPLE : inspecter → implémenter → vérifier.
- STANDARD : plan court → implémenter → vérifier → relecture indépendante facultative.
- COMPLEX ou risque HIGH : chantiers explicites → périmètres isolés → vérification → relecture indépendante → intégration.

N'utilise sous-agents ou appels entre modèles que si leur valeur dépasse le coût de coordination et de tokens.

## Discipline de contexte et de tokens
- Cherche avant de lire largement.
- Ne lis que les fichiers et sections utiles.
- Réutilise la documentation durable plutôt que de raconter l'historique.
- Ne charge pas de skills sans rapport.
- Préfère des fichiers d'état ou de relais concis à la relecture de conversations.
- Garde les fichiers d'instructions racine courts.
- Préfère un appel ciblé à un autre modèle plutôt que des allers-retours répétés.
- Choisis le modèle et l'effort les moins chers qui font la tâche de façon fiable (`.loomy/docs/AI_MODEL_ROUTING.md`) ; monte en gamme sur preuve, pas par défaut.

## Vérification
Aucun agent n'annonce un succès sans avoir lancé les vérifications pertinentes.
Commence par des vérifications ciblées, puis types, lint, tests, build et diagnostics du framework selon le besoin.
Pour un travail intégré, relance les vérifications sur la branche intégrée.

## Sécurité
Pour l'implémentation courante, applique une revue de sécurité proportionnée.
Pour un audit de sécurité ou une recherche de vulnérabilités explicite, préfère le skill officiel Cloudflare `security-audit` et préserve ses exigences de vérification indépendante et de sandbox.

## Fin d'une tâche multi-agents
Une tâche multi-agents n'est terminée que lorsque :
- les conflits de périmètre sont résolus ;
- le code intégré est vérifié ;
- les remarques de relecture sont traitées ou explicitement acceptées ;
- la documentation durable concernée est mise à jour (`PROJECT.md`, `ARCHITECTURE.md`, ADR) ;
- les fichiers de relais temporaires sont supprimés ou à jour ;
- l'état Git est propre, ou son état est documenté volontairement.

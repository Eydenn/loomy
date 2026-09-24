# Orchestration

## Complexité
- SIMPLE : périmètre étroit, peu d'éléments en jeu, peu de coordination.
- STANDARD : plusieurs composants ou des choix de conception significatifs.
- COMPLEX : architecture transverse, nombreuses intégrations, périmètre large ou durable, ou forte incertitude.

## Risque
Le risque monte avec : authentification et autorisations, paiements, secrets, données personnelles, migrations, infrastructure de production, cryptographie, actions destructives, API publiques, multi-tenant, frontières de sécurité, ou actions externes irréversibles.

## Délégation
Ne délègue que si au moins un de ces cas s'applique :
- des travaux indépendants peuvent tourner en parallèle ;
- une expertise spécialisée améliore nettement la qualité ;
- l'exploration encombrerait le contexte de l'orchestrateur ;
- une vérification ou relecture indépendante réduit un risque réel.

Ne délègue pas les modifications triviales, le travail séquentiel, les recherches en double ni les petits changements sur un seul fichier.

## Vivier de spécialistes suggéré
Architecte, Explorateur, Implémenteur, Frontend/UX, Backend/API, Données, Mobile/Desktop, QA/Tests, Sécurité, Performance, DevOps, Relecteur, Documentation, Recherche.
N'instancie que ce qui est nécessaire.

## Fonctionnement hybride Codex + Claude
Quand les deux outils sont utilisés, le dépôt et l'historique Git sont l'état partagé. Ne suppose pas que le contexte de conversation est partagé entre les deux produits.

Utilise l'un des cinq modes :
- SOLO : un seul outil porte la tâche.
- REVIEW : l'un implémente, l'autre relit de façon indépendante le diff ou le commit réel.
- HANDOFF : l'un crée un point de contrôle propre et un `.ai/HANDOFF.md` concis ; l'autre vérifie l'état et reprend.
- PARALLEL : branches ou worktrees séparés avec des périmètres disjoints, suivis d'une vérification après intégration.
- ORCHESTRATED : l'orchestrateur délègue des rôles à l'autre modèle (voir « Orchestration entre modèles » ci-dessous).

Préfère REVIEW à deux implémentations indépendantes en double, sauf si la diversité des solutions est l'objectif.
En mode PARALLEL, ne laisse jamais les deux outils modifier en même temps le même répertoire de travail ou des fichiers qui se chevauchent sans coordination explicite.

## Étape de relecture
Une relecture indépendante est fortement recommandée pour les changements transverses, les changements d'architecture, la logique d'authentification, de sécurité ou critique pour le métier, les migrations, les risques de régression significatifs, et le débogage ou les algorithmes complexes.
Le relecteur inspecte le diff réel et signale des défauts et risques concrets, pas une approbation générique.

## Économie de contexte
- Cherche avant de lire largement.
- Réutilise les faits établis au lieu de les redécouvrir.
- Demande aux sous-agents des constats concis, avec chemins de fichiers et décisions.
- Ne déverse pas l'exploration brute dans le contexte de l'orchestrateur.
- Ne charge les références spécialisées que quand c'est nécessaire.
- Utilise de courts fichiers de relais plutôt que de rejouer des conversations passées.

## Orchestration entre modèles
La session principale est l'orchestrateur. Elle délègue des rôles d'une famille de modèles à l'autre via `scripts/delegate-to-claude.sh` (Claude, lecture seule) et `scripts/delegate-to-codex.sh` (Codex, écriture ou lecture seule selon le rôle), selon le routage de `scripts/ai-route.sh`.

Utilise ces appels pour une relecture indépendante, une critique d'architecture, un débogage difficile, un second avis sécurité ou une recherche ciblée. L'orchestrateur reste responsable de la vérification des constats et de l'intégration finale.

N'utilise pas ces appels pour des tâches triviales, des confirmations de routine ou des allers-retours répétés. Préfère un seul appel ciblé.

# AGENTS.md

## Mission
Construire et maintenir ce dépôt avec exactitude, pertinence, simplicité, maintenabilité, vérification et économie de contexte.

## Workflow IA commun
Pour un travail conséquent ou toute collaboration Codex/Claude, lis `.ai/AI_WORKFLOW.md` s'il existe.
Pour la délégation entre modèles, lis aussi `.ai/AI_ORCHESTRATION.md` s'il existe.
Tu es l'orchestrateur du travail IA de ce dépôt : avant de déléguer ou de choisir un modèle et un niveau d'effort, suis `.ai/AI_MODEL_ROUTING.md` s'il existe (rôles, bridges, escalade).
Ne recopie pas ces règles ici.

## Reprise de session
Le contexte Loomy (phase en cours, attentes de l'utilisateur, dernières délégations) arrive automatiquement en début de session par un hook du projet (`.codex/hooks.json`, `.claude/settings.json`). S'il n'apparaît pas (hooks pas encore approuvés), lance `.loomy/scripts/ai-context.sh`. Commence par dire en une ou deux phrases où en est le projet et ce que tu proposes.
Avant de clore une session, résume ce qui a été fait et la prochaine étape. Si les fichiers IA sont dans un dépôt privé séparé, sauvegarde-les avec `.loomy/scripts/ai-privacy.sh sync`.

## Carte du projet
- Contexte produit : `PROJECT.md`
- Architecture : `ARCHITECTURE.md` s'il existe
- Décisions importantes : `docs/decisions/`
- Plans en cours : `docs/plans/`
- Passage de relais entre agents : `.ai/HANDOFF.md`, seulement s'il existe et est à jour

Ne lis que les sources utiles à la tâche en cours.

## Règles de travail
- Inspecte avant de modifier ; ne devine pas ce que le dépôt peut t'apprendre.
- Suis les conventions existantes avant d'en introduire de nouvelles.
- Préfère le plus petit changement correct.
- Évite les abstractions spéculatives, les refactorings sans rapport et les dépendances inutiles.
- Ne pose de question que si l'information manquante change réellement l'implémentation ou le risque.
- N'affirme jamais que des tests ou vérifications sont passés s'ils n'ont pas réellement réussi.
- Garde secrets et données sensibles hors du code, des logs, des commits et des exemples.

## Délégation adaptative
Par défaut, l'agent Codex principal fait le travail.
Ne délègue que si le travail est parallélisable, demande une expertise spécialisée, gagne à être isolé du contexte principal, ou nécessite une relecture indépendante.
Évite le travail en double et plusieurs agents sur la même zone sans répartition claire.

Quand Claude Code est disponible et que `.ai/AI_ORCHESTRATION.md` le permet, Codex peut solliciter Claude comme spécialiste externe : critique d'architecture, relecture indépendante, débogage difficile, second avis sécurité ou recherche ciblée.
Codex reste l'orchestrateur : vérifie les constats de Claude avant d'agir.
N'utilise pas la délégation entre modèles pour des tâches triviales.

## Skills
N'utilise un skill spécialisé que s'il correspond directement à la tâche.
Pour un audit de sécurité ou une revue de vulnérabilités explicite, préfère le skill officiel Cloudflare `security-audit` et préserve son workflow de validation indépendante.

## Vérification
Utilise les vérifications les plus solides disponibles, en commençant ciblé et en élargissant seulement si c'est justifié.
Ordre habituel : tests ciblés → types → lint → tests → build → diagnostics du runtime ou du framework.

## Fin de tâche
Avant de déclarer le travail terminé, confirme que :
- la demande est satisfaite ;
- les vérifications pertinentes ont tourné ;
- les cas limites et la sécurité ont été considérés à proportion du risque ;
- la documentation est à jour si nécessaire ;
- il ne reste aucun changement de débogage, temporaire ou sans rapport.

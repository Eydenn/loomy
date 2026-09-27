# AI_MODEL_ROUTING.md

## Principe
L'**orchestrateur** (la session principale) dispose du meilleur raisonnement : il planifie, découpe, délègue, décide, intègre et vérifie.
Le travail lui-même va à des **rôles dédiés**, chacun sur le modèle et l'effort les moins chers qui le font de façon fiable.

Ce fichier est la source de vérité unique pour les choix de modèles et d'effort dans ce dépôt.
Il est généré par le moteur de routage de Loomy : régénère-le plutôt que de modifier la matrice à la main.

```bash
.loomy/scripts/ai-route.sh              # matrice colorée du projet
.loomy/scripts/ai-route.sh markdown     # la matrice ci-dessous
.loomy/scripts/ai-route.sh get executor # un seul rôle, pour les scripts
```

## Rôles
| Rôle | Périmètre | Modifie des fichiers |
|---|---|---|
| lead (orchestrateur) | plan, découpage, délégation, décisions, intégration, vérification finale | oui |
| architect (architecte) | architecture, specs, ADR, arbitrages | non |
| debugger (débogueur) | bugs difficiles, longues tâches en terminal, migrations | non (propose le correctif) |
| security (sécurité) | revue de sécurité ciblée (auth, paiements, données, secrets) | non |
| reviewer (relecteur) | relecture de diff : régressions, cas limites, tests manquants | non |
| developer (développeur) | features et correctifs courants dans un périmètre convenu | oui |
| executor (exécutant) | tickets précis et bornés, tests, modifications mécaniques en masse | oui |
| explorer (explorateur) | recherche dans le code, cartographie, résumés, logs | non |
| documenter (documentaliste) | README, docs, changelogs | oui (docs uniquement) |

## Règles de l'orchestrateur
1. Décide avant de déléguer : chaque tâche déléguée a un périmètre, des critères d'acceptation et la liste des fichiers concernés.
2. Délègue l'exécution ; ne dépense pas des tokens du meilleur modèle en modifications en masse, recherches ou changements mécaniques.
3. Vérifie chaque résultat délégué au regard du dépôt et lance toi-même les vérifications avant de l'accepter.
4. Ne fais jamais tourner deux rôles qui écrivent sur les mêmes fichiers en même temps dans un même répertoire de travail.
5. Monte d'un cran (exécutant → développeur → orchestrateur, ou effort +1) après deux vérifications échouées, un résultat contredit par le dépôt, ou un périmètre qui s'avère transverse. Ne boucle jamais sur un modèle bon marché.
6. Tout travail à risque HIGH (authentification, permissions, paiements, données personnelles, migrations, infrastructure de production, cryptographie, opérations destructives) passe par le rôle sécurité avant l'intégration.

## Environnements et replis
L'environnement se déduit du brief (`ai_mode`, `ai_lead`) et des CLI réellement installées :

- **Full Claude Code** : tous les rôles tournent sur des modèles Claude, comme sous-agents dans `.claude/agents/`.
- **Full Codex** : tous les rôles tournent sur des modèles GPT-6, via `delegate-to-codex.sh <rôle>`, qui lance `codex exec` sur le modèle routé.
- **Hybride, lead Claude** : l'orchestrateur tourne sur Opus 5.5. L'exécution part vers GPT-6-Luna via `delegate-to-codex.sh executor`, et la revue croisée via `delegate-to-codex.sh reviewer`.
- **Hybride, lead Codex** : l'orchestrateur tourne sur GPT-6-Astra. L'architecture, la sécurité et le débogage difficile partent vers Opus 5.5 via `delegate-to-claude.sh` (lecture seule), et la revue vers Sonnet 5.

Si le mode demande les deux outils mais qu'un seul est installé, le routage bascule automatiquement sur la matrice complète de cet outil.

En hybride :
- la revue vient toujours de l'autre famille de modèles ;
- l'architecte, la sécurité et le débogueur tournent toujours sur Claude ;
- l'exécutant tourne toujours sur Codex ;
- l'explorateur, le développeur et le documentaliste restent sur l'outil principal, ce qui évite le coût d'un bridge.

## Profil de budget
L'orchestrateur reste toujours sur le meilleur modèle. Le profil ne change que les efforts et les modèles des rôles :

- `econome` : spécialistes et orchestrateur en `medium`, rôles d'exécution sur les modèles rapides ;
- `equilibre` (par défaut) : la matrice ci-dessous ;
- `qualite` : orchestrateur et spécialistes en `xhigh`, revues sur le meilleur modèle, exécutant sur le modèle intermédiaire.

## Matrice résolue pour ce projet
<!-- Remplacer cette section par la sortie de : .loomy/scripts/ai-route.sh markdown -->

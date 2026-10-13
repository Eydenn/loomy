# AI_ORCHESTRATION.md

## Objectif
Contrat d'orchestration entre modèles pour ce dépôt.

La session principale est l'**orchestrateur**. Elle porte la tâche de bout en bout. Elle délègue un rôle à l'autre famille de modèles quand `.loomy/docs/AI_MODEL_ROUTING.md` l'y envoie ; sinon, elle le confie à ses propres sous-agents natifs.

## Politique par défaut
Ne délègue que si c'est clairement utile : un modèle moins cher capable de faire le travail de façon fiable, un spécialiste qui décidera mieux, une relecture indépendante, ou l'isolation du contexte.

Ne délègue pas les modifications triviales, les recherches simples dont l'orchestrateur a déjà le contexte, ni les tâches qu'il a déjà résolues avec assurance.

## Bridges
Les deux bridges lisent le modèle et l'effort de chaque rôle dans le moteur de routage (`loomy-route.sh`).

### Codex → Claude : `loomy-delegate-claude.sh` (lecture seule)
Pour un lead Codex uniquement. Un lead Claude exécute ses rôles Claude comme sous-agents natifs (`.claude/agents/<rôle>.md`, outil Agent, en arrière-plan pour les tâches indépendantes) : le `claude -p` sans interface du bridge refuse toute commande shell non pré-approuvée, un rôle qui doit lancer des mesures ou des scripts n'y fonctionnerait pas.

```bash
.loomy/scripts/loomy-delegate-claude.sh <architect|debugger|security|reviewer|explorer> "<tâche>"
```
Claude inspecte et rend compte ; ses outils de modification de fichiers sont désactivés. Surcharges : `DELEGATE_CLAUDE_MODEL`, `DELEGATE_CLAUDE_EFFORT`, `DELEGATE_CLAUDE_MAX_TURNS`.

### Claude → Codex : `loomy-delegate-codex.sh`
```bash
.loomy/scripts/loomy-delegate-codex.sh <executor|developer|documenter> "<tâche>"   # sandbox workspace-write
.loomy/scripts/loomy-delegate-codex.sh <reviewer|explorer|debugger|architect|security> "<tâche>"  # sandbox read-only
```
Les rôles qui écrivent modifient le répertoire de travail ; le script liste les fichiers changés. Surcharges : `DELEGATE_CODEX_MODEL`, `DELEGATE_CODEX_EFFORT`.

Choisis le rôle d'après l'intention du travail (conception → architecte, implémentation → développeur ou exécutant, relecture → relecteur, etc.), pas d'après le modèle que l'utilisateur nomme. Quand l'utilisateur nomme un modèle ou un effort (« une conception par Sol high »), garde le rôle et passe-les en options : `--model <id> --effort <niveau> --why "user request"` ; ajoute `--write` quand ce rôle doit produire des fichiers (un document de conception, par exemple). L'option l'emporte sur le routage et le journal l'enregistre comme demandée et hors routage.

Un refus réel du fournisseur (quota, crédits ou débit), ou un quota à 100 % / atteint, passe le rôle à l’autre fournisseur disponible une fois. Les modèles partagent le quota de leur fournisseur ; ne réessaie pas un modèle voisin ni un repli non validé.

Disponibilité des fournisseurs : le code 75 signifie en pause, pas terminé. Lis `resume_at` (epoch Unix) dans l’événement final, attends cette heure, puis relance automatiquement le même rôle, la même tâche et les mêmes options depuis `.loomy/memory/delegations/<id>.md`. Ne continue pas le travail dépendant et ne choisis pas un modèle plus faible pendant l’attente ; si une nouvelle pause survient, recommence au nouveau reset. Relis les fichiers déjà modifiés avant la relance.

Un orchestrateur Codex lance les rôles Codex en sous-agents natifs sur leurs modèles et efforts routés ; le pont Codex sert à un lead Claude.

## Délégations structurées
Quand le brief indique `delegation_format: structured` (choix du questionnaire, ou `loomy config set delegation_format structured`), tâches et résultats s'échangent en champs fixes, sans prose : moins de tokens, rien de perdu dans la formulation, et des résultats que les bridges vérifient.

Rédige chaque tâche déléguée ainsi :
```
GOAL: le résultat attendu, en une phrase
SCOPE: ce qui peut être touché, et ce qui ne doit pas l'être
FILES: les fichiers ou dossiers concernés
ACCEPTANCE: les vérifications qui prouvent que c'est fait
```

Chaque rôle répond (les bridges ajoutent ce contrat à leur prompt ; les sous-agents Claude générés le portent aussi) :
```
STATUS: done | partial | blocked
SUMMARY: une ou deux phrases
FINDINGS:
- [high|medium|low] chemin:ligne — fait, avec sa preuve
FILES:
- chemin — ce qui a changé (ou : none)
CHECKS:
- `commande` — passed | failed | not run
RISKS:
- risque ouvert (ou : none)
NEXT: ce que l'orchestrateur doit faire de ce résultat
```

Agis selon STATUS : `partial` ou `blocked` signifie que la tâche n'est pas terminée ; lis RISKS et NEXT avant de décider. Le journal enregistre le résultat (◐ partiel, ■ bloqué dans `loomy status`), et `loomy stats` indique combien de réponses ont respecté le format.

## Responsabilités de l'orchestrateur
- décider si une délégation est justifiée ;
- rédiger la tâche déléguée avec son périmètre, ses fichiers et ses critères d'acceptation ;
- ne jamais modifier de fichiers pendant qu'un délégué écrit dans le même répertoire de travail ;
- vérifier les constats et relire les diffs au regard du dépôt (`git diff`) avant de les accepter ;
- lancer les critères de qualité sur le résultat intégré ;
- donner la réponse finale à l'utilisateur.

Le résultat d'un délégué n'est qu'un avis tant que l'orchestrateur ne l'a pas vérifié.

## Journal d'activité
Les deux bridges journalisent chaque appel dans `.loomy/logs/events.jsonl` (modèle, effort, durée, tokens, coût réel ou estimé). Ce journal alimente `loomy status` et `loomy watch`. L'utilisateur ouvre ou reprend la session de l'orchestrateur avec `loomy start`. Lance les tâches indépendantes des bridges en arrière-plan, conserve leurs PID et attends tous les résultats avant intégration ou fermeture de la session ; les tâches dépendantes restent séquentielles. Annonce chaque délégation à l'utilisateur avant de la lancer (rôle, modèle, tâche, durée indicative) et son résultat après (statut, durée) : pendant qu'elle tourne, il ne voit qu'un indicateur d'attente. Il reste local (ignoré par Git). `LOOMY_JOURNAL=0` le désactive, `LOOMY_JOURNAL_TASKS=0` n'y enregistre pas le texte des tâches.

## Protocole de relecture
1. Indique au relecteur le diff, le commit ou les fichiers réels.
2. Demande uniquement des défauts concrets, avec gravité, raison et preuve.
3. L'orchestrateur vérifie chaque constat important avant de modifier le code.
4. Relance les vérifications pertinentes après les corrections.

Évite les relectures génériques du type « ça a l'air bien » et les réimplémentations en double.

## Garde-fous de tokens et de coût
- Préfère un appel délégué ciblé à des allers-retours conversationnels.
- Garde les consignes cadrées. Laisse le délégué lire le dépôt au lieu de lui coller du code.
- Monte en gamme sur preuve (vérifications échouées, contradictions), pas par défaut.

## Mode parallèle
Pour une vraie implémentation parallèle, donne à chaque outil son propre worktree et sa branche Git (`loomy-worktrees.sh`), avec des périmètres disjoints. Après l'intégration, relance les critères de qualité sur la branche intégrée.

## Demandes en parallèle

- Découpe chaque demande en sous-tâches indépendantes aux fichiers disjoints. Lance-les ensemble, en sous-agents natifs ou en ponts en arrière-plan, jusqu’à `max_parallel` (configuration ; 4 par défaut), puis attends tous les résultats et vérifie-les avant intégration. Si des fichiers se chevauchent, utilise un worktree par sous-tâche (`loomy worktrees <tâche> --count N`). Après intégration, lance revue, sécurité et documentation en parallèle sur des périmètres disjoints ; attends tous les résultats avant de terminer. Conserve les efforts routés (max là où il est configuré).
- Un lead de la famille X lance les rôles de cette famille en sous-agents natifs (Codex : spawn natif ; Claude : `.claude/agents/<rôle>.md`, outil Agent). Utilise `.loomy/scripts/loomy-delegate-<outil>.sh` uniquement entre familles. Applique ce plan à chaque message utilisateur.

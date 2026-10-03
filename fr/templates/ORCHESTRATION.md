# AI_ORCHESTRATION.md

## Objectif
Contrat d'orchestration entre modèles pour ce dépôt.

La session principale est l'**orchestrateur**. Elle porte la tâche de bout en bout. Elle délègue un rôle à l'autre famille de modèles quand `.loomy/docs/AI_MODEL_ROUTING.md` l'y envoie ; sinon, elle le confie à ses propres sous-agents ou fait le travail elle-même.

## Politique par défaut
Ne délègue que si c'est clairement utile : un modèle moins cher capable de faire le travail de façon fiable, un spécialiste qui décidera mieux, une relecture indépendante, ou l'isolation du contexte.

Ne délègue pas les modifications triviales, les recherches simples dont l'orchestrateur a déjà le contexte, ni les tâches qu'il a déjà résolues avec assurance.

## Bridges
Les deux bridges lisent le modèle et l'effort de chaque rôle dans le moteur de routage (`ai-route.sh`).

### Codex → Claude : `delegate-to-claude.sh` (lecture seule)
Pour un lead Codex uniquement. Un lead Claude exécute ses rôles Claude comme sous-agents natifs (`.claude/agents/<rôle>.md`, outil Agent, au premier plan) : le `claude -p` sans interface du bridge refuse toute commande shell non pré-approuvée, un rôle qui doit lancer des mesures ou des scripts n'y fonctionnerait pas.

```bash
.loomy/scripts/delegate-to-claude.sh <architect|debugger|security|reviewer|explorer> "<tâche>"
```
Claude inspecte et rend compte ; ses outils de modification de fichiers sont désactivés. Surcharges : `DELEGATE_CLAUDE_MODEL`, `DELEGATE_CLAUDE_EFFORT`, `DELEGATE_CLAUDE_MAX_TURNS`.

### Claude → Codex : `delegate-to-codex.sh`
```bash
.loomy/scripts/delegate-to-codex.sh <executor|developer|documenter> "<tâche>"   # sandbox workspace-write
.loomy/scripts/delegate-to-codex.sh <reviewer|explorer|debugger|architect|security> "<tâche>"  # sandbox read-only
```
Les rôles qui écrivent modifient le répertoire de travail ; le script liste les fichiers changés. Surcharges : `DELEGATE_CODEX_MODEL`, `DELEGATE_CODEX_EFFORT`.

En fin de quota d'abonnement (95 % par défaut), un bridge peut confier le rôle à l'autre outil, avec le modèle que le routage prévoit pour ce rôle de ce côté ; il l'annonce sur stderr et le journalise. Rien ne change pour toi : même appel, même type de réponse ; vérifie le résultat comme d'habitude.

Un orchestrateur Codex utilise aussi `delegate-to-codex.sh` pour faire tourner un rôle sur son propre modèle routé, par exemple GPT-6-Luna en max pour l'exécutant.

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
Les deux bridges journalisent chaque appel dans `.loomy/logs/events.jsonl` (modèle, effort, durée, tokens, coût réel ou estimé). Ce journal alimente `loomy status` et `loomy watch`. L'utilisateur ouvre ou reprend la session de l'orchestrateur avec `loomy start`. Lance toujours les bridges au premier plan et attends leur résultat : en arrière-plan, une délégation est interrompue si la session se ferme. Annonce chaque délégation à l'utilisateur avant de la lancer (rôle, modèle, tâche, durée indicative) et son résultat après (statut, durée) : pendant qu'elle tourne, il ne voit qu'un indicateur d'attente. Il reste local (ignoré par Git). `LOOMY_JOURNAL=0` le désactive, `LOOMY_JOURNAL_TASKS=0` n'y enregistre pas le texte des tâches.

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
Pour une vraie implémentation parallèle, donne à chaque outil son propre worktree et sa branche Git (`create-hybrid-worktrees.sh`), avec des périmètres disjoints. Après l'intégration, relance les critères de qualité sur la branche intégrée.

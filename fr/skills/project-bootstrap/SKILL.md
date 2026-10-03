---
name: project-bootstrap
description: Initialise ou ré-initialise un dépôt logiciel avec un workflow adaptatif (découverte, entretien, validation), des instructions hybrides Codex + Claude Code, des agents et skills choisis, une documentation durable du projet et de l'architecture, des critères de vérification, des points de contrôle Git et le retrait du bootstrap. À utiliser pour créer un nouveau projet, transformer un dépôt vide en projet fonctionnel, standardiser un dépôt existant, ou quand l'utilisateur demande d'initialiser, bootstrapper ou démarrer ce projet.
---

# Bootstrap de projet

Utilise le `START.md` du dépôt comme plan de contrôle temporaire s'il existe.
Sinon, suis le même cycle de vie décrit ici.

## Cycle de vie

1. Découvrir à moindre coût avant de poser des questions.
2. Ne poser que les questions à fort impact encore ouvertes.
3. Présenter une proposition de projet concise.
4. Exiger une validation explicite avant de créer le projet, sauf si l'utilisateur y a renoncé.
5. Construire le projet cohérent minimal.
6. Ne configurer que les agents, skills et outils utiles.
7. Configurer le fonctionnement IA (SOLO, HYBRID, ORCHESTRATED ou PARALLEL) selon les besoins du projet.
8. Vérifier avec de vraies vérifications.
9. Consigner le contexte durable dans la documentation du projet.
10. Committer quand c'est autorisé et possible.
11. Archiver ou supprimer les instructions de bootstrap.

## Équipe adaptative

Par défaut, l'orchestrateur travaille seul. N'ajoute des spécialistes que si le parallélisme, l'expertise, l'isolation du contexte ou une relecture indépendante apportent une valeur claire. Évite la multiplication des rôles.

Quand Codex et Claude Code sont tous deux utilisés, préfère un fichier de workflow commun et de fins points d'entrée propres à chaque outil, plutôt que de dupliquer un gros jeu d'instructions.

Lis `references/orchestration.md` pour décider de la complexité, du risque, de la délégation, de la relecture, de la collaboration Codex/Claude, de l'orchestration entre modèles et du budget de tokens.
Lis `references/documentation.md` pour générer les fichiers permanents du projet.
Lis `references/model-routing.md` pour choisir les modèles, l'effort de raisonnement ou les niveaux des sous-agents.
Ne lis `references/security.md` que pour une architecture sensible en sécurité ou une demande explicite d'audit.

## Structure d'un projet hybride

Pour un projet qui utilisera les deux outils, préfère :

```text
AGENTS.md
CLAUDE.md
.loomy/docs/AI_WORKFLOW.md
.loomy/docs/AI_ORCHESTRATION.md  # si la délégation entre modèles est activée
.loomy/docs/AI_MODEL_ROUTING.md  # matrice rôle → modèle → effort
.claude/agents/          # uniquement les sous-agents Claude retenus
PROJECT.md
ARCHITECTURE.md          # si justifié
.loomy/docs/HANDOFF.md           # uniquement pendant un passage de relais
```

Ne laisse pas Codex et Claude modifier les mêmes fichiers en même temps dans un même répertoire de travail. Utilise des worktrees ou branches Git séparés pour l'implémentation parallèle, ou fais implémenter un outil et relire l'autre.

## Discipline de production

Garde les instructions permanentes du projet compactes.
Préfère le chargement progressif plutôt que de copier de longues instructions dans `AGENTS.md` ou `CLAUDE.md`.
Ne génère que les fichiers justifiés par la complexité du projet.

## Vérification

N'annonce jamais une vérification comme passée sans l'avoir lancée.
Quand c'est possible, commence par des vérifications ciblées avant les suites complètes.
Après avoir intégré des chantiers parallèles, relance les vérifications pertinentes sur le résultat intégré.

## Audits de sécurité

Pour un audit de sécurité explicite, préfère le skill officiel Cloudflare `security-audit`. Ne réimplémente pas une checklist plus faible si le skill est disponible. Préserve la validation indépendante et les limites d'exécution sûres.

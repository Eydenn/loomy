# Journal des modifications

Loomy reste en 0.x tant que l'ensemble n'a pas été validé en conditions réelles. La 1.0.0 viendra après cette validation.

## 0.1.3 — 2026-09-24

### Modifié
- **Aide de `loomy`** structurée comme le questionnaire : logo, groupes Projet / Suivi / Machine, commandes en gras, arguments en couleur, descriptions alignées et repliées à la largeur du terminal (sous la commande en dessous de 80 colonnes). Écrite sur la sortie standard, sans couleurs quand elle est redirigée.
- `--help` fonctionne pour chaque commande, y compris `log`, `config`, `delegate` et `worktrees`.

### Corrigé
- `loomy worktrees --help` créait deux worktrees nommés « --help » : l'aide est maintenant gérée, et un nom de tâche doit commencer par une lettre ou un chiffre.
- L'aide mentionnait encore `loomy route json`, supprimé.

## 0.1.2 — 2026-09-24

### Modifié
- **Nouveau rendu du questionnaire**, sans dépendance (gum n'est plus utilisé) :
  - questions groupées par thème (Projet, Exigences, Équipe IA, Livrables, Forfaits), groupes terminés repliés sur une ligne ;
  - chaque question en carte : pourquoi elle compte, les options, et un encadré « Ce que ça implique » qui suit l'option survolée ;
  - retour à la question précédente avec ←, réponse déjà donnée conservée ;
  - récapitulatif et étapes suivantes dans le même style.
- **Logo** : grille de pixels façon terminal, dans le README (thème clair et sombre) et en tête des commandes `loomy` (demi-blocs, invite et curseur en violet).
- `loomy doctor --live` teste tous les modèles de chaque CLI installée ; un échec n'est bloquant que pour un modèle utilisé par le projet.
- README : colonnes Méthode, Rôle et Modèle sans retour à la ligne ; mise à jour résumée sous le tableau d'installation.

### Corrigé
- Un dossier vide était détecté comme « projet existant » à cause du `.gitignore` ajouté par Loomy.
- Sans terminal (sortie redirigée), l'affichage écrivait « /dev/tty: Device not configured ».
- Tests : les environnements de routage sont réellement vérifiés un par un ; nouveau test du retour arrière dans le questionnaire.

## 0.1.1 — 2026-09-24

### Corrigé
- Installation Homebrew : depuis Homebrew 7, le téléchargement se fait dans un bac à sable sans accès au trousseau macOS, et le dépôt privé ne pouvait plus être cloné. La formule reçoit maintenant le jeton GitHub par `HOMEBREW_GITHUB_API_TOKEN`, le temps du téléchargement seulement ; `loomy update` le fournit automatiquement à partir de `gh auth token`.

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

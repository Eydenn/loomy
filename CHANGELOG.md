# Journal des modifications

Loomy reste en 0.x tant que l'ensemble n'a pas été validé en conditions réelles. La 1.0.0 viendra après cette validation.

## 0.1.19 — 2026-09-25

### Modifié
- **Interface plein écran, mise à jour sur place.** Les commandes interactives (`loomy`, `loomy init`, `loomy start`, `loomy watch`, menus) s'affichent dans l'écran alternatif du terminal, comme une application : chaque mise à jour redessine le même écran, rien ne s'empile dans l'historique à faire défiler, et les lignes trop longues sont coupées au lieu de passer à la ligne. En sortant, l'écran normal revient avec, une seule fois, le dernier écran affiché. `LOOMY_NO_CLEAR=1` garde l'ancien affichage ligne à ligne.
- `loomy watch` : `q` pour quitter (Ctrl-C marche toujours) ; plus aucune copie de l'écran dans l'historique à chaque rafraîchissement.

## 0.1.18 — 2026-09-25

### Corrigé
- Fichier `VERSION` de la 0.1.17 mal formé.

## 0.1.17 — 2026-09-25

### Corrigé
- **Projet créé dans un dossier qui est déjà dans un dépôt Git** (par exemple `~/Projets`) : `loomy init` propose un dépôt Git propre au projet (recommandé), ou de rester dans le dépôt parent (monorepo). Avant, le dépôt GitHub échouait sans explication.
- La raison d'un échec de `gh repo create` est affichée.

### Ajouté
- `loomy init` dans un dossier qui est lui-même un projet Loomy : nouvelle option « Créer un nouveau projet dans un sous-dossier ».

## 0.1.16 — 2026-09-24

### Corrigé
Défauts révélés par un parcours complet réel (init, orchestrateur, délégations, commit, push) :
- Une frappe rapide pendant une question s'affichait en vrac à l'écran : l'écho du terminal est coupé pendant les questions.
- Un dossier neuf était détecté comme « projet existant » à cause des dossiers `.claude/` et `.codex/` créés par Loomy.
- Hors locale UTF-8, un texte tronqué pouvait couper un caractère accentué : Loomy choisit une locale UTF-8 disponible.
- Les agents sont invités à lancer les délégations au premier plan (START.md, ORCHESTRATION.md, contexte de reprise) : en arrière-plan, elles s'arrêtaient à la fermeture de la session.

## 0.1.15 — 2026-09-24

### Ajouté
- **Reprise automatique avec Codex aussi.** `loomy init` installe les mêmes hooks pour Codex (`.codex/hooks.json`) : contexte transmis à l'ouverture, session notée à l'ouverture et à la fermeture, sauvegarde des fichiers IA en mode dépôt privé. Vérifié avec les vraies CLI Codex et Claude Code. Codex demande, au premier lancement, de faire confiance au dossier puis d'approuver les hooks ; `loomy start` le rappelle.
- `.codex/` fait partie des fichiers IA (modes local et dépôt privé).

## 0.1.14 — 2026-09-24

### Ajouté
- **Reprise automatique des sessions.** `loomy init` installe des hooks Claude Code (`.claude/settings.json`, fusionnés avec un fichier existant) : chaque session ouverte dans le projet reçoit d'office le contexte Loomy (phase, attentes de l'utilisateur, dernières délégations, Git), et sa fermeture est notée ; en mode dépôt privé, les fichiers IA sont sauvegardés à la fermeture. Codex lit ce contexte (`.loomy/scripts/ai-context.sh`) à la demande d'`AGENTS.md` et du prompt de `loomy start`.
- **`loomy` sans argument : accueil.** Dans un projet : où il en est, ce qui est attendu, et un choix pour la suite (ouvrir ou reprendre la session, suivre, statut, fichiers IA). Hors projet : créer un projet, vérifier la machine.
- `loomy status`, `watch` et l'accueil indiquent si la session de l'orchestrateur est ouverte, et depuis quand ; la consigne « À toi » en tient compte.
- **Dépôt GitHub au nom du projet.** Le questionnaire propose de le créer (privé ou public ; jamais en mode `--yes`), avec un nom tiré du projet à valider ou modifier. En mode dépôt privé séparé, le nom du dépôt des fichiers IA est proposé aussi, et les deux sont confirmés ensemble. `loomy privacy private` propose le nom à validation (`--name` pour l'imposer).

### Modifié
- Un seul nom technique pour tout (`slug` dans le brief) : dossier créé, dépôt GitHub, dépôt privé des fichiers IA (auparavant nommé d'après le dossier). Un dépôt existant au nom différent est signalé dans le questionnaire et le brief, sans être renommé.
- `loomy privacy restore` met de côté les fichiers locaux différents (`.loomy/restore-backup-…`) au lieu d'échouer.

## 0.1.13 — 2026-09-24

### Modifié
- **Plus besoin de créer le dossier avant `loomy init`.** Sans dossier indiqué, `loomy init` demande le nom du projet et propose : un nouveau dossier nommé d'après lui (`./nom-du-projet`, sans accents ni espaces), le dossier courant (proposé par défaut s'il est vide ou ressemble à un projet), ou un autre emplacement. `loomy init mon-projet` crée le dossier s'il n'existe pas.
- Fin du questionnaire : rappel du `cd` quand le projet est ailleurs que le dossier de départ, `loomy start` mis en avant, et proposition d'ouvrir tout de suite la session de l'orchestrateur, dans le dossier du projet.
- README : démarrage rapide sans l'étape `mkdir`.

### Corrigé
- Un mot plus long que la largeur d'un encadré (un chemin, par exemple) en débordait : il est maintenant coupé.

## 0.1.12 — 2026-09-24

### Ajouté
- **Visibilité des fichiers IA** (`AGENTS.md`, `CLAUDE.md`, `.ai/`, `.claude/`, `.loomy/`, `START.md`), choisie dans le questionnaire et modifiable avec `loomy privacy` :
  - **versionnés** avec le projet (défaut ; recommandé pour un dépôt privé) ;
  - **locaux** : exclus via `.git/info/exclude`, invisibles dans le dépôt ;
  - **dépôt privé séparé** : exclus du projet et sauvegardés dans un dépôt GitHub privé `<projet>-ai` (ou toute URL avec `--remote`), qui ne suit que ces fichiers, directement dans le dossier du projet. `loomy privacy sync` sauvegarde, `loomy privacy restore` les récupère sur une autre machine.
  Le choix par défaut dépend de la visibilité du dépôt GitHub. Les fichiers encore suivis sont signalés, avec la commande pour arrêter de les suivre sans les supprimer. `loomy status` signale une sauvegarde en retard ou une exclusion absente.
- Le brief transmet le mode à l'orchestrateur : ne jamais forcer l'ajout de ces fichiers, et sauvegarder le dépôt privé en fin d'étape.

## 0.1.11 — 2026-09-24

### Ajouté
- `loomy uninstall` : la commande de désinstallation de chaque installation trouvée, et comment retirer Loomy d'un projet.
- `loomy help <commande>` : aide d'une commande.

### Modifié
- **Frise des phases agrandie** : dix cases larges (█ fait, ▓ en cours, ░ à venir) sur toute la largeur, et le nom de la phase en cours sous sa case.
- Les commandes trouvent le projet Loomy le plus proche en remontant depuis le dossier courant : un projet peut vivre dans un sous-dossier d'un dépôt Git, et `loomy status`, `start`, `brief` et les délégations le retrouvent depuis n'importe quel sous-dossier.

### Corrigé
- `loomy brief` hors d'un projet Loomy créait un brief isolé : il renvoie maintenant vers `loomy init`.
- Refaire le questionnaire en cours de route remettait la phase à « Découverte » : la phase en cours est conservée.
- `loomy init` dans le dossier personnel ou à la racine du disque est refusé.
- `loomy update --help` lançait la mise à jour.

## 0.1.10 — 2026-09-24

### Ajouté
- **Détection des installations** : `loomy version --all` et `loomy doctor` listent chaque `loomy` du PATH (Homebrew, npm, bun, script shell), indiquent celle qui est utilisée et donnent la commande pour retirer les autres. `loomy version` et `loomy update` signalent quand il y en a plusieurs.
- `loomy init`, `brief`, `start`, `status`, `watch` et `doctor` effacent l'écran avant d'afficher (terminal interactif seulement ; `LOOMY_NO_CLEAR=1` pour garder l'historique).

### Modifié
- `loomy update` avec npm réinstalle dans le même dossier que l'installation d'origine, même si la version de Node active a changé (nvm).
- README : une commande par bloc, pour copier directement celle qui convient (démarrage rapide en étapes, une méthode d'installation par bloc, forfaits, installation des CLI).

### Corrigé
- `loomy start` échouait au moment d'ouvrir la session (« tool_label?: unbound variable ») avec le bash de macOS hors locale UTF-8. Toutes les variables suivies d'un caractère accentué sont vérifiées par les tests, qui lancent aussi `loomy start` en locale C.

## 0.1.9 — 2026-09-24

### Corrigé
- Une installation npm faite avec le Node de Homebrew (`/opt/homebrew/lib/node_modules`) était prise pour une installation Homebrew : `loomy update` lançait alors `brew upgrade` et échouait. La détection vérifie d'abord `node_modules`, et ne retient Homebrew que pour une formule installée (`Cellar`).
- `loomy update` appelle Homebrew avec le nom complet de la formule (`eydenn/tap/loomy`) et, en cas d'échec, affiche la méthode détectée et la commande à lancer à la main.

## 0.1.8 — 2026-09-24

### Ajouté
- **`loomy start`** : démarre ou reprend la session de l'orchestrateur. Il détecte une session précédente du projet sur la machine et propose de la reprendre (`claude --continue`, `codex resume --last`) ou d'en ouvrir une nouvelle avec le prompt adapté à la phase : démarrage du bootstrap, reprise à la phase enregistrée, ou travail courant. `--resume`, `--new`, `--print` ; en mode affichage, les consignes pour les apps de bureau.
- **`loomy init` sur un projet déjà initialisé** : au lieu de refuser, propose de reprendre, mettre à jour, refaire le questionnaire ou réinitialiser. Options `--update` (fichiers Loomy du projet mis à niveau ; brief, phase et journal conservés) et `--reset` (bootstrap recommencé, anciennes réponses en valeurs par défaut).
- `loomy update` rappelle de mettre à niveau chaque projet ; `loomy status` signale un projet resté sur une version plus ancienne.

### Modifié
- **Phases guidées** dans `loomy status` et `loomy watch` : frise sur une ligne (●━◉━○…), phase en cours, ce que fait l'orchestrateur et « À toi : » ce que l'utilisateur doit faire ; annotations quand l'activité ou les fichiers IA sont encore vides. Source unique : `scripts/lib/phases.sh`.
- `START.md` demande à l'orchestrateur d'enregistrer chaque phase avant toute autre action et de dire à l'utilisateur ce qu'il attend de lui.
- README : nouvelle section « Avancer dans ton projet » (ouvrir ou reprendre la session dans le terminal ou les apps, phases et rôle de l'utilisateur, développement au quotidien, mise à jour et réinitialisation) ; ce qui est réellement en direct dans le suivi.

### Corrigé
- `loomy start` et la lecture de la phase échouaient sur un projet qui n'avait encore enregistré aucune phase.
- Le type de projet « Autre » s'affichait « other » dans `loomy status`.
- Les sessions sont retrouvées sur le chemin réel du projet (liens symboliques résolus), comme Claude et Codex les enregistrent.

## 0.1.7 — 2026-09-24

### Modifié
- **Prérequis idéal : Claude Code et Codex installés dans le terminal.** `loomy doctor` affiche chaque CLI détectée avec son emplacement ; pour une CLI absente, il donne les commandes officielles d'installation (installateur recommandé, alternative Homebrew ou npm) et la première connexion. `loomy doctor --fix` propose de lancer l'installation.
- README : prérequis idéaux précisés, avec les commandes d'installation des deux CLI.

## 0.1.6 — 2026-09-24

### Modifié
- Description de Loomy réécrite partout (aide, README, npm, GitHub, formule Homebrew) : Loomy démarre et structure les projets (questionnaire, structure prête pour les agents), puis les fait avancer (orchestrateur et rôles dédiés, suivi en direct).
- `loomy init` est décrit pour ce qu'il fait : créer ou initialiser un projet, nouveau ou existant.

## 0.1.5 — 2026-09-24

### Corrigé
- Une installation bun dans un dossier personnalisé (`BUN_INSTALL`) était reconnue comme une installation npm : `loomy update` utilisait alors npm au lieu de bun.
- Tests : la méthode d'installation (npm, bun, Homebrew) est vérifiée pour chaque emplacement.

## 0.1.4 — 2026-09-24

### Modifié
- **Un seul style pour toutes les commandes** : logo, ligne d'ouverture `┌`, sections `◇` en capitales, fil conducteur violet `│` et ligne de fin `└` avec les raccourcis utiles. S'applique à `loomy status` et `loomy watch`, `loomy doctor`, `loomy route`, `loomy worktrees` et `loomy init --no-wizard`, en plus du questionnaire et de l'aide.
- `loomy status` : la frise des phases, qui débordait, devient une barre de progression avec la phase en cours et les suivantes.
- Les messages renvoient aux commandes `loomy` (`loomy route`, `loomy doctor`) plutôt qu'aux scripts internes.
- Les sorties destinées aux machines ou aux agents restent en texte brut : `loomy log`, `loomy config list`, `loomy version`, messages des bridges, `loomy route markdown`.

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

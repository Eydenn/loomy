# Commandes de Loomy

[← README](../README.fr.md)

Chaque commande avec ses variantes et ce qu'elle fait en détail. Dans le terminal : `loomy help <commande>`.

## Projet

### `loomy`

```bash
loomy
```

Accueil : où en est le projet, ce qui est attendu, et la suite en un choix (hors projet : créer un projet)

### `loomy init [dir]`

```bash
loomy init [dossier]
loomy init --update
loomy init --reset
loomy init --no-wizard
loomy init --yes
loomy init --answers <fichier>
loomy init --no-branch
```

Crée le dossier si besoin (ou propose de le créer d'après le nom du projet), puis initialise le projet, nouveau ou existant : questionnaire, puis structure mise en place par l'orchestrateur ; sur un projet déjà initialisé : reprendre, `--update`, `--reset` (`--no-wizard`, `--yes`, `--answers` ; projet Git existant : `--no-branch` pour rester sur la branche courante)

### `loomy brief`

```bash
loomy brief
```

Relance le questionnaire du projet courant

### `loomy assess`

```bash
loomy assess
loomy assess --print
```

État des lieux d'un projet existant, sans IA : stack, commandes, tests, CI, conventions, historique Git, zones sensibles, dette (`.loomy/assessment.md` ; `--print` pour seulement l'afficher)

### `loomy privacy`

```bash
loomy privacy
loomy privacy versioned
loomy privacy local
loomy privacy private
loomy privacy sync
loomy privacy restore
```

Visibilité des fichiers IA : `versioned`, `local`, `private` ; `sync`, `restore` pour le dépôt privé

## Sessions et travail

### `loomy start`

```bash
loomy start
loomy start --resume
loomy start --new
loomy start --print
loomy start --watch
loomy start --no-watch
loomy start --app
```

Démarre ou reprend la session de l'orchestrateur (`--resume`, `--new`, `--print`, `--watch`)

🪟 La session de l'orchestrateur à gauche et le suivi en direct à droite, par défaut (l'un au-dessus de l'autre si le terminal est étroit), via tmux ou iTerm2 ; le suivi se ferme avec la session. `--no-watch`, ou `loomy config set start_watch no`, ouvre la session seule. Dans chaque session, la ligne d'état de Claude Code affiche la phase et les délégations en cours (⟳ n), y compris après ta propre ligne d'état ; une session ouverte sans suivi le signale et propose `loomy watch`

### `loomy task "…"`

```bash
loomy task "…"
loomy task --resume
loomy task --print
```

Une tâche nommée pour l'orchestrateur : plan, validation, construction, vérification, commit, suivie dans `watch` ; sans argument, la liste ; `--resume`, `--print`

### `loomy review`

```bash
loomy review
loomy review --working
loomy review --staged
```

Relecture croisée à la demande de la branche en cours (`[base]`) ou des modifications non commitées (`--working`, `--staged`), en lecture seule, enregistrée dans `.loomy/reviews/`

### `loomy effort`

```bash
loomy effort
loomy effort --list
loomy effort --reset
```

Effort de raisonnement de l'orchestrateur pour ce projet (`loomy effort low`, menu sans argument), ou d'un rôle (`loomy effort executor high`) ; `--list`, `--reset` ; pris en compte au prochain `loomy start`

### `loomy shell-hook [install|remove]`

```bash
loomy shell-hook
loomy shell-hook install
loomy shell-hook remove
```

En option : dans un projet Loomy, `claude` ou `codex` tapé seul (l'outil principal du projet) passe par `loomy start`, donc la session s'ouvre toujours avec le suivi en direct et le contexte ; tout le reste lance la vraie commande. Proposé une fois par `loomy doctor --fix`, jamais installé sans ton accord

### `loomy worktrees <task>`

```bash
loomy worktrees <tâche>
```

Deux worktrees séparés pour le mode parallèle

## Suivi et chiffres

### `loomy status`

```bash
loomy status
```

Instantané : phases, délégations en cours, activité, coûts par modèle, forfaits, Git

### `loomy watch`

```bash
loomy watch [N]
```

🖥️ Le même écran rafraîchi chaque seconde (ou toutes les N secondes) : délégation en cours avec toupie, chrono et avancement estimé, nouveautés mises en évidence, notification (macOS) et bip à chaque phase, échec ou fin de bootstrap. Un journal de session en bas défile au fil des événements, le plus récent mis en évidence. Touches : `q` quitter, `c` vue resserrée ou complète (écran de statut : brief masqué, moins de délégations et de lignes de journal), `l` journal, `t` arbre des agents, `s` ouvrir la session. Vue resserrée d'office dans un petit terminal

### `loomy tree`

```bash
loomy tree
```

🌳 Arbre des agents : l'orchestrateur avec son modèle, son effort, sa session et sa phase ; son conseiller et ses consultations ; chaque rôle avec son modèle, son effort et son état en direct (une impulsion parcourt la branche d'un rôle en cours, puis terminé, durée, tokens) ; le journal de session ; une ligne d'état. Aussi touche `t` de `loomy watch`. Dans une grande fenêtre (124 × 57), il est dessiné en diagramme (boîtes et liaisons animées ; jusqu'à quatre boîtes de rôles, les autres résumés à côté de la vérification finale, groupés par modèle, avec ce que fait chacun), sinon en liste ; `v` bascule, `loomy config set tree_view auto|diagram|list` choisit

### `loomy log`

```bash
loomy log [-n N] [-f]
loomy log --raw
loomy log --since AAAA-MM-JJ
loomy log --csv
```

Journal lisible, à l'heure locale, éventuellement en continu (`--raw` : JSON brut) ; `--since AAAA-MM-JJ` remonte dans les archives mensuelles ; `--csv` exporte les coûts

### `loomy stats`

```bash
loomy stats
loomy stats --days N
loomy stats --since AAAA-MM-JJ
```

Statistiques détaillées : par rôle, modèle et jour, durées, tokens, coût ou quota (`--days N`, `--since AAAA-MM-JJ`)

### `loomy report`

```bash
loomy report
loomy report --md [dossier]
loomy report --all
```

Chiffres du projet : démarrage, tâches, délégations par rôle et par modèle, tokens, coût ; `--md [dossier]` en Markdown dans `docs/reports/` ; `--all` tous les projets

### `loomy memory [show [N]]`

```bash
loomy memory [show [N]]
loomy memory show [N]
```

Mémoire partagée : l'état du travail tenu par l'orchestrateur et les derniers résultats des délégations en bref ; `show [N]` le texte complet de l'un d'eux

## Agents, modèles et skills

### `loomy route`

```bash
loomy route
loomy route lead
loomy route get <rôle>
loomy route markdown
loomy route claude-agents
```

Matrice du projet · `lead` · `get <rôle>` · `markdown` · `all` · `claude-agents` · `codex-profiles`

### `loomy delegate codex <role> "…"`

```bash
loomy delegate codex <rôle> "…"
```

Confie un rôle à Codex (exécutant, développeur, documentaliste en écriture ; les autres en lecture seule)

### `loomy delegate claude <role> "…"`

```bash
loomy delegate claude <rôle> "…"
```

Confie un rôle à Claude en lecture seule (architecte, débogueur, sécurité, relecteur, explorateur)

### `loomy models`

```bash
loomy models
loomy models --thrifty on|off
loomy models --issue
```

Chaînes de modèles et nouveaux modèles à évaluer ; tête de chaîne avec deux replis (cette machine), `--thrifty on|off`, `--issue` (suggestion GitHub)

### `loomy skills [suggest|add|remove|update|catalog]`

```bash
loomy skills [suggest|add|remove|update|catalog]
loomy skills suggest "…"
loomy skills add <nom>
loomy skills remove <nom>
loomy skills update
loomy skills catalog
```

Skills officiels du projet : installés, pourquoi, analyse ; `suggest "…"` pour une tâche, `add`/`remove`, `update`, `catalog`

### `loomy audit`

```bash
loomy audit
loomy audit --resume
loomy audit --print
loomy audit --yes
loomy audit --scope <dossiers>
loomy audit --depth quick|standard|deep
loomy audit --fixes report|plan|branch
```

Audit de sécurité d'un dépôt Git existant, une mission plutôt qu'un projet (voir plus bas) : `--resume`, `--print`, `--yes`, `--scope`, `--depth quick|standard|deep`, `--fixes report|plan|branch`

## Maintenance et aide

### `loomy doctor`

```bash
loomy doctor
loomy doctor --fix
loomy doctor --live
```

Vérifie les prérequis (`--fix` corrige, y compris la CLI GitHub, facultative : installation de `gh` et connexion ; `--live` teste chaque modèle)

### `loomy config`

```bash
loomy config
loomy config list
loomy config get <clé>
loomy config set <clé> <valeur>
```

Préférences : `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`no` : `loomy start` n'ouvre plus le suivi à côté), `start_in` (`app` : `loomy start` ouvre l'app de bureau), `memory` (`off` : la mémoire partagée n'est plus redonnée), `skills` (`auto`, `ask` ou `off`), `notify` (`no` : pas de notifications dans `loomy watch`), `quota_switch` (95 par défaut : à partir de cette part d'un quota d'abonnement, le travail passe à l'autre outil ; `off` : jamais), `delegation_format` (`structured`, `free` ou `auto` : le choix de chaque projet), `lang` (`fr`, `en` ou `auto` : langue de l'interface, détectée par défaut)

### `loomy update` · `loomy version`

```bash
loomy update
loomy update --catalog
loomy version
loomy version --all
```

Mise à jour de Loomy, valable pour tous les projets ; `update --catalog` : seulement le catalogue des modèles et des prix ; `version --all` liste toutes les installations

### `loomy uninstall`

```bash
loomy uninstall
```

Montre comment désinstaller Loomy selon l'installation, et comment le retirer d'un projet

### `loomy feedback`

```bash
loomy feedback
loomy feedback --print
```

Signale un bug ou une idée : issue GitHub pré-remplie (versions, état du projet anonymisé, sans nom, objectif ni texte des tâches), envoyée seulement après ton accord ; `--print` pour voir le texte

### `loomy feedback list`

```bash
loomy feedback list
loomy feedback triage
loomy feedback mark <n> <version>
loomy feedback close <version>
```

Tes retours et où ils en sont : reçu, en cours de traitement, corrigé en X.Y.Z (le lancement signale une fois qu'un de tes retours est corrigé dans la version installée). Mainteneurs : `triage` regroupe les retours ouverts par cause avec une priorité et une réponse proposée (modèle rapide), chaque réponse publiée seulement après accord ; `mark <n> <version>` puis `close <version>` à la release

### `loomy help [command]`

```bash
loomy help [commande]
```

Aide générale, ou aide d'une commande

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
loomy start --lead codex
loomy start --lead claude
loomy start --lead auto
```

Démarre ou reprend la session de l'orchestrateur (`--resume`, `--new`, `--print`, `--watch`)

`--lead codex|claude` choisit temporairement l'outil lead sans modifier le brief et remplace `AI_ROUTE_ENV=hybrid-codex loomy start` pour cet usage. Un changement ouvre une nouvelle session avec le prompt de passation et d'état partagé, même avec `--resume` ; redemander l'outil actif conserve le choix de session et n'ajoute aucun événement de relais. `--lead auto` ou l'outil lead du brief efface le relais et le démarre avec le prompt de retour. Le relais manuel persiste jusqu'au retour explicite, sauf si l'outil actif atteint le seuil de quota et que le lead du brief a de la marge. Un outil absent est refusé (code 2) ; un quota saturé ou une offre à l'usage provoque un avertissement et reste autorisé. Compatible avec `--app` et le suivi ; `--print` affiche un aperçu sans écrire d'état.

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

🖥️ Agents du projet en direct : l'orchestrateur, puis **EN COURS** (sous-agents Claude natifs et passerelles), puis **SESSION**, avec uniquement les rôles terminés de la session courante. Les démarrages sont détectés toutes les 250 ms ; les chronos avancent chaque seconde, même avec un ancien intervalle `N`. Dans la liste live, `v` bascule le regroupement par demande/modèle et mémorise `watch_group` (`request` par défaut). Les extraits respectent `LOOMY_JOURNAL_TASKS=0`. Les touches du pied de page dépendent de la vue : `q` quitte ; `o` ouvre l’orchestrateur actif dans son application, ou un terminal séparé avec suivi (un échec apparaît en bas et le suivi continue) ; `l` ouvre le journal puis revient au statut ; `t` bascule arbre/statut ; `a` ouvre la liste live puis revient au statut. Dans l’arbre, `v` bascule diagramme/liste ; dans la liste live, il regroupe par demande/modèle et mémorise `watch_group`. Dans le statut, `c` bascule compact/complet. `s` ouvre la session hors du panneau de suivi et sans `--until-exit` ; les flèches défilent lorsque le contenu dépasse l’écran. `watch_view` (`tree` par défaut ; `list` choisit la liste live) mémorise la vue choisie avec `t` ou `a`. L’arbre affiche ses boîtes dès 124 colonnes, avec défilement si le terminal est moins haut, et sa propre liste compacte en dessous. Le panneau compact ouvert par `loomy start` démarre dans la liste live. Chaque ligne montre le rôle traduit, l'outil, le modèle réel, le mot et la barre d'effort, le chrono, la tâche et le résultat ; les demandes explicites et écarts au routage sont signalés. Une fenêtre étroite retire dans l'ordre la tâche, le modèle et la barre, en conservant l'outil et le mot d'effort ; les annotations de routage passent sur une ligne indentée si nécessaire. Après la configuration, le bandeau affiche l'état de l'orchestrateur : actif si son processus vit et qu'une demande ou un événement d'usage date de moins de deux minutes. Le rendu change avec le journal ou les fichiers d'état, ou chaque seconde pour les chronos en cours ; au repos, l'horloge reste à l'heure du dernier rendu. Le coût d'un sous-agent natif provient uniquement de son usage, celui d'une passerelle reste dans sa délégation.

### `loomy tree`

```bash
loomy tree
```

🌳 Arbre des agents : l'orchestrateur avec son modèle, son effort, sa session et sa phase ; son conseiller et ses consultations ; chaque rôle avec son modèle, son effort et son état en direct (une impulsion parcourt la branche d'un rôle en cours, puis terminé, durée, tokens) ; le journal de session ; une ligne d'état. `loomy tree --once` affiche une frame de la vue live. Dans une grande fenêtre (124 × 57), il est dessiné en diagramme (boîtes et liaisons animées ; jusqu'à quatre boîtes de rôles), sinon en liste ; `loomy config set tree_view auto|diagram|list` choisit

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
loomy delegate codex <rôle> [options] "…"
```

Confie un rôle à Codex (exécutant, développeur, documentaliste en écriture ; les autres en lecture seule)

### `loomy delegate claude <role> "…"`

```bash
loomy delegate claude <rôle> [options] "…"
```

Confie un rôle à Claude en lecture seule (architecte, débogueur, sécurité, relecteur, explorateur)

Options avant le texte de la tâche (elles l'emportent sur `DELEGATE_*_MODEL` / `DELEGATE_*_EFFORT`) : `--model <id>` (lettres, chiffres, `. _ -` ; pour Claude un id `claude-*` ou `opus`, `sonnet`, `haiku`), `--effort <low|medium|high|xhigh|max>`, `--write` / `--read-only` (remplace le sandbox du rôle ; sur Claude, `--write` est refusé hors basculement de quota), `--why "raison"` (par exemple `user request`). Une option ou une variable utilisée marque la délégation `requested` dans le journal ; ce qui s'écarte du routage du projet (outil, modèle, effort, sandbox) est listé dans `off_routing`, et `why` garde la raison (masquée par `LOOMY_JOURNAL_TASKS=0`). Exemple : `loomy delegate codex architect --model gpt-6.1-sol --effort high --write --why "user request" "…"`.

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

Vérifie les prérequis et signale les fichiers d'historique de Loomy suivis par Git (`--fix` corrige, y compris la CLI GitHub, facultative : installation de `gh` et connexion ; `--live` teste chaque modèle)

### `loomy config`

```bash
loomy config
loomy config list
loomy config get <clé>
loomy config set <clé> <valeur>
```

Préférences : `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`no` : `loomy start` n'ouvre plus le suivi à côté), `start_in` (`app` : `loomy start` ouvre l'app de bureau), `memory` (`off` : la mémoire partagée n'est plus redonnée), `skills` (`auto`, `ask` ou `off`), `notify` (`no` : pas de notifications dans `loomy watch`), `quota_switch` (95 par défaut : à partir de cette part d'un quota d'abonnement, le travail passe à l'autre outil ; `off` : jamais), `lead_failover` (`auto` par défaut : quand le quota du lead est épuisé, l'autre outil prend la main temporairement et `loomy start` enchaîne les sessions ; `off` : jamais), `quota_room` (80 par défaut : l'outil lead reprend la main dès que son quota passe sous cette part), `delegation_format` (`structured`, `free` ou `auto` : le choix de chaque projet), `lang` (`fr`, `en` ou `auto` : langue de l'interface, détectée par défaut)

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

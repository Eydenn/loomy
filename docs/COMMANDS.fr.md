# Commandes de Loomy

[← README](../README.fr.md)

Chaque commande avec ses variantes et ce qu'elle fait en détail. Référence pour Loomy **0.17.10**. Dans le terminal : `loomy help <commande>`.

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
loomy privacy restore <compte/dépôt>
```

Visibilité des fichiers IA : `versioned`, `local`, `private` ; `sync`, `restore` pour le dépôt privé. Ces modes n'autorisent pas la conservation du texte des tâches. Les contrôles de contenu ci-dessous concernent le projet courant ; les worktrees partageant ses logs enregistrés partagent aussi sa politique.

#### `loomy privacy content`

```bash
loomy privacy content
loomy privacy content structural
loomy privacy content legacy-excerpts
```

Affiche la politique effective, sa source et son périmètre projet, ou modifie les futures écritures du journal. En 0.17.8, les nouvelles entrées et les nouveaux instantanés de rotation ne contiennent par défaut que la structure autorisée, sur les projets nouveaux comme mis à jour. Les fichiers et archives existants restent inchangés.

`legacy-excerpts` est une autorisation explicite distincte pour le projet. Elle permet uniquement les champs de premier niveau bornés `task` (200 caractères Unicode), `excerpt` (60), `why` (200), `nickname` (40) et `cwd_relative` (256, à l'intérieur du projet). Elle n'active pas la conservation des tâches/résultats complets.

Élargir une autorisation exige qu'un humain lance directement la commande dans un terminal interactif et confirme le projet, les champs et les limites. Les pipes, `--yes`, hooks et terminaux d'agents gérés ne peuvent pas autoriser cette conservation. Restreindre la politique ou désactiver la capture reste possible sans interaction.

`LOOMY_JOURNAL_CONTENT=structural` impose une restriction temporaire. Sélectionner `legacy-excerpts` par l'environnement exige aussi une autorisation humaine existante et `LOOMY_CONTENT_PROJECT` lié au projet enregistré ; les variables d'environnement ne créent aucune autorisation. `LOOMY_JOURNAL_TASKS=0` interdit la capture automatique des extraits, libellés et tâches/résultats complets, même autorisés. `LOOMY_JOURNAL=0` désactive le journal et la collecte, pas tous les autres documents de travail.

#### `loomy privacy labels` · `loomy privacy label`

```bash
loomy privacy labels
loomy privacy labels recommended
loomy privacy labels set explicit-user,explicit-lead
loomy privacy labels off
loomy privacy label --id <id> [--attempt <id>] [--kind agent|task|session|delegation] "Titre court"
```

`labels` affiche les sources choisies, les limites et les choix de première utilisation. `recommended` autorise les six sources : `explicit-user`, `explicit-lead`, `claude-description`, `codex-path-slug`, `codex-nickname`, `codex-role`. `set` remplace exactement l'ensemble des sources ; tout ajout exige une confirmation humaine. `off` arrête les futures captures sans supprimer les anciens libellés.

Les libellés sont stockés à part du journal : au plus 96 graphèmes / 384 octets UTF-8 par libellé, chaque composant Codex étant limité à 40 caractères ASCII, dans un stockage plafonné à 1 Mio. Claude utilise la `description` bornée d'Agent/Task, jamais son `prompt`. Si le stockage est plein, l'enregistrement est refusé visiblement et le libellé précédent est conservé.

La commande au singulier `label` enregistre un titre délibérément saisi par un humain pour un ID, une tentative et un type précis. Elle exige toujours un terminal humain direct ; elle propose l'autorisation `explicit-user` si elle manque. Le type vaut `agent` par défaut, la tentative vaut l'ID fourni. Les bridges utilisent `--task-label` avec l'autorisation distincte `explicit-lead`.

Après la mise à jour, un projet dont les choix sont en attente reçoit un écran unique à son premier `loomy init` interactif ou `loomy watch` autonome : libellés recommandés à **Oui** par défaut, puis résultats privés avec un **Oui** distinct par défaut. L'écran n'enregistre aucune nouvelle autorisation avant les deux réponses humaines ; une fin d'entrée ou un écran interrompu n'accorde rien. Les refus sont mémorisés. Une décision humaine explicite `privacy labels` acquitte aussi la première utilisation ; désactiver la capture ne rouvre pas le prompt. Un contexte géré/non interactif n'accorde rien et laisse les choix en attente ; le statut affiche au besoin `Libellés de tâche désactivés · lancer loomy privacy labels recommended`.

Arbre/liste, diagramme, statut, journal de session, `loomy log` lisible et récapitulatif résolvent les libellés autorisés. Sans libellé utilisable, un rôle connu affiche sa mission précédée de `Rôle :` ; un rôle inconnu affiche un contexte indisponible. La mission décrit les attributions du rôle, pas un travail terminé. Les anciennes lignes du journal peuvent encore afficher leur texte existant.

#### `loomy privacy results`

```bash
loomy privacy results
loomy privacy results on
loomy privacy results off
```

Affiche ou modifie l'autorisation distincte des tâches/résultats privés complets. La capture reste désactivée jusqu'à la réponse dédiée de première utilisation ou une confirmation humaine explicite `results on` ; accepter les libellés ou les extraits compatibles ne l'active pas. `off` arrête la future capture et conserve les entrées déjà autorisées.

Les nouvelles entrées utilisent des dossiers privés (0700) et des fichiers privés (0600), avec des limites de 200 entrées, 1 Mio par entrée, 16 Mio au total et 30 jours. La rétention s'applique lors des enregistrements. La protection d'une entrée active exige un processus propriétaire vivant et un âge inférieur à 24 heures ; celle d'une entrée en pause dure jusqu'à 30 jours après son heure de réinitialisation/revérification (ou le dernier enregistrement si elle manque). Une entrée trop volumineuse ou un stockage rempli d'entrées protégées entraîne un refus visible. Ces limites ne purgent pas les anciens résultats Markdown. Libellés, reçus et résultats privés sont exclus des dépôts Git du projet et de son compagnon, des synchronisations et du contexte automatique des retours. Les permissions ne les chiffrent pas. Voir [`loomy memory`](#loomy-memory) pour les reçus et résultats disponibles.

#### `loomy privacy inventory`

```bash
loomy privacy inventory [--root DIR] [--json] [--paths] [--git-history] [--host]
```

Inventaire en lecture seule des métadonnées des emplacements connus : nombres de fichiers, octets, catégories de rétention/exposition et couverture incomplète. Il ne lit pas les contenus, ne suit pas les liens arbitraires, ne répare pas les stockages, ne lance pas de collecte, ne copie, n'envoie ni ne supprime de fichiers. La sortie par défaut omet les noms ; `--json` conserve les mêmes champs de métadonnées, tandis que `--paths` ajoute explicitement les chemins locaux échappés et les métadonnées des fichiers.

`--git-history` vérifie les métadonnées de chemins dans l'index et l'historique locaux du projet/compagnon, sans récupération distante ni réécriture. `--host` ajoute les emplacements connus de Loomy sur l'hôte et les fichiers temporaires ; un nom correspondant ne prouve pas qu'un fichier est abandonné. Les transcriptions des fournisseurs, clones distants, sauvegardes et exports à d'autres emplacements restent hors de la couverture démontrée. Un inventaire ne prouve pas l'absence de texte sensible.

Le correctif 0.17.8 couvre les nouvelles écritures et instantanés de rotation du journal, les reçus et la préparation automatique des retours. Les checkpoints/curseurs natifs, fichiers temporaires d'exécution/affichage et diagnostics peuvent encore conserver du texte ou des chemins. `log --raw` et les exports explicites `report --md` gardent leur comportement existant. Ces contrôles ne purgent ni n'assainissent les anciens fichiers, l'historique Git ou les transcriptions gérées par les fournisseurs.

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
loomy start --lead codex --only
loomy start --lead claude --only
```

Démarre ou reprend la session de l'orchestrateur (`--resume`, `--new`, `--print`, `--watch`)

`--lead codex|claude` choisit temporairement l'outil lead sans modifier le brief et remplace `AI_ROUTE_ENV=hybrid-codex loomy start` pour cet usage. Un changement ouvre une nouvelle session avec le prompt de passation et d'état partagé, même avec `--resume` ; redemander l'outil actif conserve le choix de session et n'ajoute aucun événement de relais. `--lead auto` ou l'outil lead du brief efface le relais et le démarre avec le prompt de retour. Le relais manuel persiste jusqu'au retour explicite, sauf si l'outil actif atteint le seuil de quota et que le lead du brief a de la marge. Un outil absent est refusé (code 2) ; un quota saturé ou une offre à l'usage provoque un avertissement et reste autorisé. Compatible avec `--app` et le suivi ; `--print` affiche un aperçu sans écrire d'état.

`--only` route tous les rôles vers le lead explicite pendant la session terminal, sans modifier le brief ni copier le projet. Le choix apparaît dans le suivi et `loomy route`, seuls les descendants héritent du marqueur PID/date de démarrage, et la fin de session retire son propre marqueur. Un autre terminal ou `--lead auto` préserve les autres sessions vivantes. Sans `--lead codex|claude`, le code de sortie est 2. `--print` ne crée pas de marqueur. `--only` conserve le lancement terminal même si `start_in=app` ; `--only --app` est refusé, car l’app ne fournit pas de processus propre à la session.

`--app` et `o` dans le suivi rouvrent le dernier fil Codex du projet (sous-dossiers inclus) ou la dernière session Claude avec `claude --desktop --resume` (CLI ≥ 2.1.285). Une session Claude occupée dans un terminal est refusée avec une indication `/desktop` ; aucune autre fenêtre n’est ouverte. En l’absence de session compatible, avec un ancien CLI Claude ou si le lancement échoue, le lien habituel ouvre une nouvelle conversation avec le prompt pré-rempli, jamais envoyé. Le lead actif d’un relais est respecté.

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

Deux worktrees par défaut ; `--count N` crée N worktrees numérotés partageant le journal live. Découpe les périmètres indépendants, lance-les ensemble, puis attends tous les résultats avant intégration ; revue, sécurité et documentation sont ensuite parallèles.

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

🖥️ Agents du projet en direct : l'orchestrateur, puis **EN COURS** (sous-agents Claude natifs et passerelles), puis **SESSION**, avec uniquement les rôles terminés de la session courante. Les démarrages sont détectés toutes les 250 ms ; les chronos avancent chaque seconde, même avec un ancien intervalle `N`. Dans la liste live, `v` bascule le regroupement par demande/modèle et mémorise `watch_group` (`request` par défaut). Le contexte des tâches suit les [autorisations de confidentialité](#loomy-privacy). Les touches du pied de page dépendent de la vue : `q` quitte ; `o` ouvre l’orchestrateur actif dans son application, ou un terminal séparé avec suivi (un échec apparaît en bas et le suivi continue) ; `l` ouvre le journal puis revient au statut ; `t` bascule arbre/statut ; `a` ouvre la liste live puis revient au statut. Dans l’arbre, `v` bascule diagramme/liste ; dans la liste live, il regroupe par demande/modèle et mémorise `watch_group`. Dans le statut, `c` bascule compact/complet. `s` ouvre la session hors du panneau de suivi et sans `--until-exit` ; les flèches défilent lorsque le contenu dépasse l’écran. `watch_view` (`tree` par défaut ; `list` choisit la liste live) mémorise la vue choisie avec `t` ou `a`. L’arbre affiche ses boîtes dès 124 colonnes, avec défilement si le terminal est moins haut, et sa propre liste compacte en dessous. Le panneau compact ouvert par `loomy start` démarre dans la liste live. Chaque ligne montre le rôle traduit, l'outil, le modèle réel, le mot et la barre d'effort, le chrono, le contexte de tâche et le résultat enregistré ; les demandes explicites et écarts au routage sont signalés. Une fenêtre étroite retire dans l'ordre le contexte de tâche, le modèle et la barre, en conservant l'outil et le mot d'effort ; les annotations de routage passent sur une ligne indentée si nécessaire. Après la configuration, le bandeau affiche l'état de l'orchestrateur : actif si son processus vit et qu'une demande ou un événement d'usage date de moins de deux minutes. Le rendu change avec le journal ou les fichiers d'état, ou chaque seconde pour les chronos en cours ; au repos, l'horloge reste à l'heure du dernier rendu. Le coût d'un sous-agent natif provient uniquement de son usage, celui d'une passerelle reste dans sa délégation.

Les agents Codex natifs sont aussi suivis depuis les fichiers de session locaux
dans `CODEX_HOME` (`~/.codex` par défaut). La découverte est bornée ; la lecture
des événements est incrémentale, donc le rattrapage peut demander plusieurs
passes. La collecte enregistre l'identité du thread et du tour, ainsi que la
dernière activité observée, sans recopier les messages, arguments d'outils ou
conversations. Un résultat absent reste inconnu, pas une tâche réussie ; l'usage
et le coût Codex natif ne sont pas inventés. Voir l'[ADR-0007](adr/0007-native-codex-observability.md) pour les limites.
La phase reste la dernière information enregistrée par l'orchestrateur, pas un avancement déduit automatiquement.

Le modèle et l'effort de la session Codex principale viennent de ses contextes
observés, y compris après un changement. Le rattrapage est signalé séparément ;
une information invalidée est effacée plutôt qu'affichée comme actuelle ou devinée depuis la configuration.

Si plusieurs sessions d'outils restent ouvertes, `LOOMY_WATCH_TOOL=codex loomy watch`
(ou `claude`) choisit explicitement la session affichée. Ce filtre facultatif ne
change ni l'orchestrateur actif ni le routage. Sans valeur valide, le suivi reprend
l'orchestrateur actuel ; `o` efface le filtre lorsqu'il ouvre celui-ci.

Une seule vue par projet collecte l'activité native (le premier `watch`, ou un `status`/`tree` ponctuel pendant son exécution) ; tout autre `watch` affiche `Suit un autre watch · q ferme cette vue`, lit les données enregistrées et n'écrit rien. `q` ne ferme que cette vue ; le propriétaire termine son lot et se libère sur `q`. Ferme le `watch` d'un ancien Loomy avec `q` avant de mettre à jour ou de revenir en arrière.

### `loomy tree`

```bash
loomy tree
```

🌳 Arbre des agents : l'orchestrateur avec son modèle, son effort, sa session et sa phase ; son conseiller et ses consultations ; chaque rôle avec son modèle, son effort et son état en direct (une impulsion parcourt la branche d'un rôle en cours, puis son état de fin enregistré, sa durée et ses tokens lorsqu'ils sont disponibles) ; le journal de session ; une ligne d'état. `loomy tree --once` affiche une frame de la vue live. Dans une grande fenêtre (124 × 57), il est dessiné en diagramme (boîtes et liaisons animées ; jusqu'à quatre boîtes de rôles), sinon en liste ; `loomy config set tree_view auto|diagram|list` choisit. La fin d'une exécution ne prouve pas que les tests ont réussi ; une pause ou un résultat absent ne signifie pas une réussite.

### `loomy log`

```bash
loomy log [-n N] [-f]
loomy log --raw
loomy log --since AAAA-MM-JJ
loomy log --csv
```

Journal lisible, à l'heure locale, éventuellement en continu, avec résolution des libellés autorisés pour les nouvelles entrées. `--since AAAA-MM-JJ` remonte dans les archives mensuelles ; `--csv` exporte les coûts. En 0.17.8, `--raw` émet toujours le JSON original, y compris le texte des anciennes entrées ou du mode compatible ; ce n'est pas un export assaini.

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

Chiffres du projet : démarrage, tâches, délégations par rôle et par modèle, tokens, coût ; `--md [dossier]` écrit du Markdown dans `docs/reports/` ou le dossier choisi ; `--all` tous les projets. Sans option, `report` ne crée aucun fichier Markdown. En 0.17.8, un rapport Markdown explicite peut encore contenir le nom du projet et les titres des tâches ; relis-le avant de le partager.

### `loomy memory`

```bash
loomy memory
loomy memory -n N
loomy memory show [N]
loomy memory show legacy [N]
```

La mémoire partagée conserve l'état du travail et les impasses rédigés par l'orchestrateur, à côté des reçus automatiques des délégations. Les reçus de `.loomy/memory/receipts-v1/` contiennent des faits structurels : ID, rôle/modèle/effort, état, horaires, nombre de fichiers et références autorisées. Ils ne contiennent ni tâche ni résultat complet.

Avec l'[autorisation distincte des résultats privés](#loomy-privacy-results), les tâches/résultats complets et les options structurées de reprise des bridges sont enregistrés dans `.loomy/memory/private-results-v1/`, selon ses limites de rétention. Le résumé résout SUMMARY/NEXT depuis les contenus privés disponibles ; `show [N]` affiche le reçu de même rang et toute tâche/résultat autorisé disponible, avec son descripteur de reprise. Sans contenu conservé, il indique que le résultat n'a pas été conservé ; sans tâche d'origine pour une pause, il indique `tâche d’origine nécessaire pour reprendre`.

Les anciens résultats Markdown sensibles restent séparés, lisibles avec `show legacy [N]` ; la nouvelle politique de capture ne les migre pas, ne les purge pas et ne modifie pas leurs permissions. `loomy config set memory off` désactive l'injection de contexte, pas la rétention ; utilise `loomy privacy results off` pour arrêter les futures captures privées. Aucune de ces commandes ne supprime les fichiers existants.

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

`codex-profiles` affiche des conseils selon la version sans modifier la configuration utilisateur. Avant Codex 0.134, il affiche les anciens profils TOML ; à partir de 0.134 (ou si la version est inconnue), il montre comment Loomy fixe le modèle et l’effort de chaque rôle à chaque appel avec `-m` et `-c model_reasoning_effort=…`. La détection utilise uniquement `codex --version` via le point de lancement de Loomy.

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

Options avant le texte de la tâche (elles l'emportent sur `DELEGATE_*_MODEL` / `DELEGATE_*_EFFORT`) : `--model <id>` (lettres, chiffres, `. _ -` ; pour Claude un id `claude-*` ou `opus`, `sonnet`, `haiku`), `--effort <low|medium|high|xhigh|max>`, `--write` / `--read-only` (remplace la sandbox du rôle ; sur Claude, `--write` est refusé hors basculement de quota), `--why "raison"` (par exemple `user request`), `--task-label "Titre court"`.

Une surcharge de modèle, effort, sandbox ou raison marque la délégation `requested` dans le journal ; les écarts au routage du projet (outil, modèle, effort, sandbox) sont listés dans `off_routing`. La raison est omise des entrées structurelles ; seule une autorisation `legacy-excerpts` permet son champ `why` borné. `--task-label` fournit un titre d'affichage délibéré avec la source `explicit-lead` autorisée par l'humain, dans les limites des libellés ; il ne marque pas à lui seul un écart de routage et n'accorde aucune permission. Ne le déduis jamais automatiquement du corps de la tâche. Exemple : `loomy delegate codex architect --model gpt-6.2-sol --effort high --write --why "user request" --task-label "Revue d'architecture" "…"`.

Disponibilité des fournisseurs : le code 75 signifie en pause. L'événement final enregistre `status: "paused"`, `outcome: "waiting_for_reset"` et `resume_at` (epoch Unix). Atteindre cette heure ne signifie pas que le travail a repris ou réussi. Garde exactement le rôle/fournisseur/modèle/effort/sandbox/options ; après la réinitialisation, relance une seule fois avec la tâche du contexte vivant ou une référence de tâche/résultat privé autorisée. `loomy memory show N` expose le descripteur de reprise structuré d'un bridge conservé, pas une commande exécutable. Vérifie les modifications existantes avant de relancer. Si la tâche et les options d'origine sont indisponibles, signale `tâche d’origine nécessaire pour reprendre` et arrête le travail dépendant ; ne devine jamais et ne choisis pas un modèle moins puissant. À chaque nouvelle pause, utilise son nouveau `resume_at`.

Les délégations se mettent en pause seulement après un refus réel ou à 100 % / limite atteinte ; le seuil de relais préventif configurable du lead reste distinct.

### `loomy models`

```bash
loomy models
loomy models --issue
```

Chaînes de modèles actuels validés et nouveaux candidats à évaluer ; `--issue` propose les candidats sur GitHub. `chain.<famille>.<niveau>` accepte seulement les modèles validés du catalogue pour ce niveau ; les identifiants inconnus sont refusés. `--thrifty` est retiré (code 2) ; le profil de budget Économe continue de baisser l’effort.

La découverte de modèles annoncés peut lancer une sonde quotidienne bornée, en lecture seule/sans outils, jamais pendant une pause du fournisseur. Une sonde réussie ne promeut pas le candidat dans le routage. Le cache local des modèles Codex est indicatif ; une entrée absente avertit sans bloquer un modèle validé.

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

### `loomy hooks [status|repair [--shell]]`

```bash
loomy hooks status
loomy hooks repair
loomy hooks repair --shell
```

Inspection et réparation ciblées des enregistrements de hooks Loomy dans `.claude/settings.json` et `.codex/hooks.json` ; aucun autre fichier du projet, aucune autorisation de contenu, aucun appel à un fournisseur. `status` ne modifie rien et liste, par fournisseur et par événement, `shell`, `natif`, `mixte`, `personnalisé`, `manquant`, `invalide` ou `ambigu`, et si une action est nécessaire. `repair` complète les enregistrements manquants et conserve les enregistrements actifs reconnus, tes propres hooks, matchers, ligne d'état et permissions de fichier ; il indique `modifié` ou `inchangé` par fichier. `repair --shell` rétablit les enregistrements shell reconnus : c'est l'étape à faire avant de revenir à un Loomy plus ancien. `repair` n'agit que dans un projet Loomy et que pour les fournisseurs qu'il utilise (l'autre est signalé comme ignoré) ; `--root DIR` cible un autre projet. Rien n'est réécrit si le fichier est invalide, non sûr ou modifié entre-temps, et tes propres commandes ne sont jamais affichées. L'enregistrement natif n'est pas disponible dans cette version (`--native` est refusé).

Retour en arrière avant un Loomy plus ancien, tant que cette version est installée : `loomy hooks status`, puis `loomy hooks repair --shell`, puis `loomy hooks status` à nouveau ; résous à la main tout événement en conflit qu'il liste, et installe seulement ensuite l'ancienne version. Répéter la mise à jour et la réparation ne duplique pas les enregistrements.

### `loomy doctor`

```bash
loomy doctor
loomy doctor --fix
loomy doctor --live
```

Vérifie les prérequis, le propriétaire du suivi en direct (build, pid, démarrage, époque, ou aucun), la santé de la politique de contenu, un stockage de libellés plein et les fichiers d'historique Loomy suivis par Git (`--fix` corrige, y compris la CLI GitHub, facultative : installation de `gh` et connexion ; `--live` teste chaque modèle). Ces informations de santé ne certifient pas l'absence de texte sensible dans les anciens fichiers.

### `loomy config`

```bash
loomy config
loomy config list
loomy config get <clé>
loomy config set <clé> <valeur>
```

Préférences : `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`no` : `loomy start` n'ouvre plus le suivi à côté), `start_in` (`app` : `loomy start` ouvre l'app de bureau), `memory` (`off` : la mémoire partagée n'est plus redonnée), `skills` (`auto`, `ask` ou `off`), `notify` (`no` : pas de notifications dans `loomy watch`), `quota_switch` (95 par défaut : seuil de relais préventif du lead ; `off` : pas de relais préventif ; les refus réels et les quotas épuisés protègent toujours les délégations), `lead_failover` (`auto` par défaut : quand le quota du lead est épuisé, l'autre outil prend la main temporairement et `loomy start` enchaîne les sessions ; `off` : jamais), `quota_room` (80 par défaut : l'outil lead reprend la main dès que son quota passe sous cette part), `max_parallel` (4 par défaut ; 1–999 agents indépendants ; `auto` rétablit 4), `delegation_format` (`structured`, `free` ou `auto` : le choix de chaque projet), `lang` (`fr`, `en` ou `auto` : langue de l'interface, détectée par défaut)

### `loomy update` · `loomy version`

```bash
loomy update
loomy update --catalog
loomy version
loomy version --all
```

Mise à jour de Loomy, valable pour tous les projets ; `update --catalog` : seulement le catalogue des modèles et des prix ; `version --all` liste toutes les installations

Une mise à jour exécutant encore le code 0.17.6 ne peut pas afficher le nouvel écran d'autorisation. Après la mise à jour, le premier `loomy init` interactif ou `loomy watch` autonome propose les choix encore en attente pour le projet ; un contexte non interactif n'accorde aucune autorisation.

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

Signale un bug ou une idée : issue GitHub préremplie avec les versions, les faits autorisés sur l'état du projet et les 15 derniers événements projetés du journal. Le contexte automatique omet le nom/objectif du projet, le texte des tâches, les libellés, les résultats privés et les chemins du projet ; il ne prépare aucune copie complète du brief ou du journal brut. Ton propre message reste dans l'aperçu. Envoi seulement après ton accord ; `--print` affiche le texte sans publication ni accès réseau.

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

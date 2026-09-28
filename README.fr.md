<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/loomy-dark.svg">
  <img alt="Loomy" src="docs/assets/loomy-light.svg" width="340">
</picture>

**Démarre et structure tes projets avec Codex et Claude Code.**
Un questionnaire pour cadrer le projet, une structure de dépôt prête pour les agents, un orchestrateur sur le meilleur modèle qui délègue à des rôles dédiés, et un suivi en direct dans le terminal.

![version](https://img.shields.io/badge/version-0.5.3-7F77DD?style=for-the-badge)
![statut](https://img.shields.io/badge/statut-pr%C3%A9--version-BA7517?style=for-the-badge)
![bash](https://img.shields.io/badge/bash-3.2%2B-1D9E75?style=for-the-badge&logo=gnubash&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude_Code-%E2%89%A5_2.1.280-D85A30?style=for-the-badge)
![Codex](https://img.shields.io/badge/Codex_CLI-%E2%89%A5_0.155-185FA5?style=for-the-badge)

[🇬🇧 English](README.md) · 🇫🇷 Français

</div>

> [!NOTE]
> **Pré-version.** Loomy reste en 0.x tant que l'ensemble n'a pas été validé en conditions réelles. La version stable viendra après une phase de « release candidate » validée par les testeurs.

---

## ⚡ Démarrage rapide

**1. Installer Loomy** (une fois ; npm, bun ou script : voir « Installation »)

```bash
HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install eydenn/tap/loomy
```

**2. Vérifier la machine** (une fois)

```bash
loomy doctor --fix --live
```

**3. Créer le projet et répondre au questionnaire**, depuis n'importe quel dossier

```bash
loomy init
```

`loomy init` propose de créer un dossier nommé d'après le projet (nom modifiable), d'utiliser le dossier courant, ou un autre emplacement. `loomy init mon-projet` crée directement le dossier. À la fin, il propose d'ouvrir la session de l'orchestrateur.

**4. Rouvrir la session de l'orchestrateur** plus tard, depuis le dossier du projet

```bash
loomy start
```

**5. Suivre en direct**, dans un second terminal

```bash
loomy watch
```

> [!TIP]
> Pour la suite, tape simplement **`loomy`** dans le dossier du projet : il affiche où en est le projet, ce qui est attendu de toi, et propose d'ouvrir ou reprendre la session, de suivre en direct ou de voir le statut.

---

## 📦 Installation

Toutes les méthodes installent la même commande `loomy`. Le dépôt étant privé, elles utilisent tes identifiants GitHub (`gh auth login`).

🍺 **Homebrew** (recommandé sur macOS)

```bash
HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install eydenn/tap/loomy
```

📦 **npm**

```bash
npm install -g github:Eydenn/loomy
```

🥟 **bun**

```bash
gh release download -R Eydenn/loomy -p 'loomy-*.tgz' -D /tmp/loomy && bun add -g /tmp/loomy/loomy-*.tgz
```

🐚 **Script shell**

```bash
gh repo clone Eydenn/loomy ~/Tools/loomy && ~/Tools/loomy/install.sh
```

**Mise à jour**, quelle que soit la méthode :

```bash
loomy update
```

Plusieurs installations sur la même machine (par exemple Homebrew et npm) ? Pour voir celle qui est utilisée et comment retirer les autres :

```bash
loomy version --all
```

> [!TIP]
> `loomy update` détecte la méthode d'installation et utilise la bonne commande. Homebrew télécharge dans un bac à sable qui n'a pas accès au trousseau macOS : le jeton GitHub lui est transmis par `HOMEBREW_GITHUB_API_TOKEN`, le temps du téléchargement seulement, et `loomy update` s'en charge. bun ne sait pas lire un dépôt GitHub privé : il installe l'archive de la release, que `gh` télécharge avec tes identifiants. Pour npm, la mise à jour se fait dans le même dossier que l'installation d'origine, même si tu as changé de version de Node (nvm) entre-temps.

---

## 🧭 Comment ça marche

```mermaid
flowchart LR
  A["🩺 Diagnostic<br/>loomy doctor"]:::check --> B["📝 Questionnaire<br/>loomy init"]:::step
  B --> C["🧭 Routage<br/>loomy route"]:::route
  C --> D["🎯 Orchestrateur<br/>suit START.md"]:::lead
  D --> E["📜 Journal<br/>chaque délégation"]:::step
  E --> F["📈 Suivi<br/>loomy watch"]:::check
  classDef step fill:#F1EFE8,stroke:#888780,color:#2C2C2A
  classDef check fill:#E1F5EE,stroke:#1D9E75,color:#085041
  classDef route fill:#FAEEDA,stroke:#BA7517,color:#633806
  classDef lead fill:#EEEDFE,stroke:#534AB7,color:#26215C
```

1. **Diagnostic.** Vérifie les versions des CLI, trouve Codex même caché dans l'app ChatGPT, contrôle les modèles disponibles, et propose les corrections.
2. **Questionnaire.** Douze questions en français, groupées par thème, chacune avec la conséquence de chaque choix : type de projet, stade, risque, mode IA, outil principal, budget, autorisations Git. La première fois, une treizième demande tes forfaits Claude et ChatGPT. ← revient à la question précédente.
3. **Routage.** Transforme le brief et les outils installés en une matrice rôle → modèle → effort, avec repli automatique si une CLI manque.
4. **Orchestrateur.** La session principale suit `START.md` :

   <kbd>Découverte</kbd> → <kbd>Entretien</kbd> → <kbd>Proposition</kbd> → <kbd>✋ Validation</kbd> → <kbd>Construction</kbd> → <kbd>Vérification</kbd> → <kbd>Documentation</kbd> → <kbd>Commit</kbd> → <kbd>Clôture</kbd>

   Elle délègue le travail aux rôles dédiés et n'avance jamais sans ta validation.
5. **Journal et suivi.** Chaque délégation est enregistrée (modèle, effort, durée, tokens, coût) dès son lancement. Tu la suis en direct dans le terminal.

---

## 🚀 Avancer dans ton projet

Une fois `loomy init` terminé, tout passe par **l'orchestrateur** : une session Claude Code ou Codex, sur le meilleur modèle, qui suit `START.md` puis les règles du projet. Tu lui parles en français, il délègue aux rôles dédiés.

### 1. Ouvrir ou reprendre sa session

Le plus simple : **`loomy`** dans le dossier du projet, puis « Ouvrir ou reprendre la session ».

| Où | Comment |
|---|---|
| 🖥️&nbsp;**Terminal,&nbsp;avec&nbsp;Loomy** | `loomy start` : un menu propose de **reprendre** la dernière session de ce dossier (avec son historique) ou d'en ouvrir une **nouvelle** avec le prompt adapté à la phase du projet. `--resume` et `--new` y vont directement. |
| ⌨️&nbsp;**Terminal,&nbsp;à&nbsp;la&nbsp;main** | Claude Code : `claude --continue` pour reprendre ; Codex : `codex resume --last`. Pour une nouvelle session, `loomy start --print` affiche la commande exacte (modèle et effort) et copie le prompt. |
| 🪟&nbsp;**Apps&nbsp;de&nbsp;bureau** | Dans l'app Claude (onglet Code) ou l'app Codex : ouvre le **dossier du projet**, choisis le modèle et l'effort indiqués par `loomy start --print`, colle le prompt qu'il a copié. Pour reprendre, rouvre la conversation du projet dans l'app. |

> [!NOTE]
> Les sessions restent sur la machine où elles ont été ouvertes. Sur une autre machine, `loomy start` ouvre une nouvelle session : l'orchestrateur relit `START.md`, le brief et la phase enregistrée, et reprend là où le projet en est.
>
> Dans une app, autorise l'orchestrateur à lancer les scripts `.loomy/scripts/` : c'est par eux qu'il délègue à l'autre outil et qu'il enregistre les phases.

**La reprise est automatique.**
- **Claude Code :** à chaque ouverture de session dans le projet (terminal, app, `claude` tapé à la main), un hook installé par `loomy init` lui transmet d'office le contexte : phase, ce que tu dois faire, dernières délégations. Il commence par te dire où en est le projet. À la fermeture, la session est notée ; en mode dépôt privé, les fichiers IA sont sauvegardés.
- **Codex :** même mécanisme, via `.codex/hooks.json`. Au premier lancement dans le projet, Codex te demande de faire confiance au dossier, puis d'approuver les hooks Loomy : accepte les deux, c'est ce qui active la reprise automatique. Tant que ce n'est pas fait, `AGENTS.md` et le prompt de `loomy start` lui demandent de lire le contexte lui-même (`.loomy/scripts/ai-context.sh`).
- **Suivi :** `loomy watch` et `loomy` indiquent si la session de l'orchestrateur est ouverte, et depuis quand.

### 2. Suivre les phases, et savoir quand c'est à toi

`loomy watch`, dans un second terminal, affiche la phase en cours, **ce que fait l'agent** et **ce que tu dois faire**.

| Phase | L'orchestrateur… | À toi |
|---|---|---|
| 1&nbsp;·&nbsp;Brief | attend d'être lancé | `loomy start` |
| 2&nbsp;·&nbsp;Découverte | lit le brief et explore le dossier | rien, garde sa session ouverte |
| 3&nbsp;·&nbsp;Entretien | pose les questions qui manquent | réponds dans sa session |
| 4&nbsp;·&nbsp;Proposition | présente stack, structure et plan | lis, questionne |
| 5&nbsp;·&nbsp;Validation | attend ton feu vert | **valide** ou demande des changements |
| 6&nbsp;·&nbsp;Construction | met en place le projet et délègue | suis les délégations |
| 7&nbsp;·&nbsp;Vérification | tests, relecture croisée, sécurité | regarde les constats remontés |
| 8&nbsp;·&nbsp;Documentation | écrit PROJECT.md, ARCHITECTURE.md, `.ai/` | relis |
| 9&nbsp;·&nbsp;Commit | commit initial, si autorisé | vérifie le commit |
| 10&nbsp;·&nbsp;Clôture | archive ou supprime START.md | rien |

### 3. Ensuite : le développement au quotidien

Le bootstrap terminé, `START.md` disparaît et l'orchestrateur suit `AGENTS.md` et `CLAUDE.md`. Pour chaque évolution :

1. `loomy start`, puis décris ta demande : une fonctionnalité, un bug, un refactor ;
2. l'orchestrateur propose, puis délègue l'exécution, la revue ou la sécurité au rôle adapté ;
3. tu suis avec `loomy watch`, tu relis le diff, tu valides le commit.

> [!TIP]
> **Recommandations.** Une demande claire par session, avec le résultat attendu. Demande une proposition avant tout changement large. Relis chaque diff avant de committer. Pour les sujets sensibles (authentification, paiements, données personnelles), demande explicitement une revue du rôle sécurité.

### 4. Mettre à jour, reprendre ou réinitialiser

| Besoin | Commande |
|---|---|
| Mettre&nbsp;à&nbsp;jour&nbsp;Loomy | `loomy update` : tous tes projets en profitent aussitôt (leurs scripts sont des relais vers le Loomy installé). `loomy init --update` ne sert plus qu'aux nouveaux modèles de documents, et une fois pour les projets d'avant la 0.3 (garde brief, phase et journal) |
| Projet&nbsp;déjà&nbsp;initialisé | `loomy init` propose : reprendre, mettre à jour, refaire le questionnaire, réinitialiser |
| Refaire&nbsp;le&nbsp;questionnaire | `loomy brief` |
| Recommencer&nbsp;le&nbsp;bootstrap | `loomy init --reset` : START.md recopié, phase remise à zéro, questionnaire relancé avec tes anciennes réponses |

---

## 🔒 Fichiers IA : versionnés, locaux ou privés

Les fichiers qui guident les agents (`AGENTS.md`, `CLAUDE.md`, `.ai/`, `.claude/`, `.codex/`, `.loomy/`, `START.md`) sont tes règles de travail. GitHub règle la visibilité **par dépôt**, pas par fichier : un dépôt public montre tout ce qu'il contient. Le questionnaire te demande où les garder, avec une valeur par défaut qui dépend de ton dépôt.

Le questionnaire propose aussi de **créer le dépôt GitHub** du projet, privé ou public. Son nom, tiré du nom du projet, est à valider ou à modifier. En mode dépôt privé séparé, le nom du dépôt des fichiers IA (`<dépôt>-ai`) l'est aussi, et les deux sont confirmés ensemble. Un dépôt existant qui porte un autre nom est signalé, avec la commande pour le renommer ; Loomy ne renomme rien lui-même.

| Mode | Pour qui | Ce qui se passe |
|---|---|---|
| **Versionnés** | dépôt privé *(défaut)* | ils sont dans le dépôt : tu les retrouves partout, les agents en ligne les lisent |
| **Locaux** | dépôt public, sans sauvegarde | exclus via `.git/info/exclude` (invisible dans le dépôt) ; perdus si tu changes de machine |
| **Dépôt privé séparé** | dépôt public *(recommandé)* | exclus du projet et sauvegardés dans un dépôt GitHub privé `<projet>-ai`, qui ne suit que ces fichiers |

Voir le mode et l'état de la sauvegarde :

```bash
loomy privacy
```

Changer de mode (un seul des trois) :

```bash
loomy privacy versioned
```

```bash
loomy privacy local
```

```bash
loomy privacy private
```

Sauvegarder les fichiers IA dans le dépôt privé (l'orchestrateur le fait aussi en fin d'étape) :

```bash
loomy privacy sync
```

Sur une autre machine, après avoir cloné le projet, récupérer ses fichiers IA :

```bash
loomy privacy restore <ton-compte>/<projet>-ai
```

> [!WARNING]
> Un fichier déjà envoyé sur un dépôt public reste dans son historique. Quand tu passes en mode local ou privé, `loomy privacy` liste les fichiers encore suivis et donne la commande pour arrêter de les suivre sans les supprimer de ton disque. `--remote <URL>` permet d'utiliser un autre hébergeur que GitHub pour le dépôt privé.

---

## 📈 Suivi en direct

Tout se passe dans le terminal, sans dépendance. **Rien ne démarre tout seul** : tu lances le suivi quand tu veux, dans un second terminal.

| Commande | Vue |
|---|---|
| <code>loomy&nbsp;status</code> | Instantané : phases, délégations en cours, activité, coûts par modèle, forfaits, Git |
| <code>loomy&nbsp;watch&nbsp;[N]</code> | 🖥️ Le même écran rafraîchi chaque seconde (ou toutes les N secondes) : délégation en cours avec toupie, chrono et avancement estimé, nouveautés mises en évidence, notification (macOS) et bip à chaque phase, échec ou fin de bootstrap. Touches : `q` quitter, `c` vue resserrée ou complète, `l` journal, `s` ouvrir la session. Vue resserrée d'office dans un petit terminal |
| <code>loomy&nbsp;start&nbsp;--watch</code> | 🪟 La session de l'orchestrateur et le suivi en direct côte à côte (ou l'un au-dessus de l'autre si le terminal est étroit), via tmux ou iTerm2 ; le suivi se ferme avec la session |
| <code>loomy&nbsp;log&nbsp;[-n&nbsp;N]&nbsp;[-f]</code> | Journal lisible, à l'heure locale, éventuellement en continu (`--raw` : JSON brut) ; `--since AAAA-MM-JJ` remonte dans les archives mensuelles ; `--csv` exporte les coûts |

**Ce qui est en direct.** L'écran relit le projet toutes les 2 secondes :
- les **délégations** à Claude ou Codex s'affichent dès leur lancement, avec leur chrono, puis leur coût à la fin ; une délégation interrompue disparaît d'elle-même ;
- la **phase** change quand l'orchestrateur l'enregistre (`START.md` le lui demande à chaque étape) ;
- le travail que l'orchestrateur fait lui-même, dans sa session, n'est pas journalisé : c'est dans sa session que tu le suis.

Le journal (`.loomy/logs/events.jsonl`) reste sur ta machine : il est exclu de Git automatiquement. `LOOMY_JOURNAL=0` le désactive, `LOOMY_JOURNAL_TASKS=0` n'y enregistre pas le texte des tâches.

### 💳 Forfaits Claude et ChatGPT

Loomy sait si tu paies à l'usage (API) ou par abonnement, outil par outil :

| Forfait | Ce que Loomy affiche |
|---|---|
| API | le **coût** réel (Claude) ou estimé à partir des tokens (Codex), par tâche et par mois |
| Claude&nbsp;Pro&nbsp;·&nbsp;Max&nbsp;5x&nbsp;·&nbsp;Max&nbsp;20x&nbsp;·&nbsp;Team | la **part de ton quota utilisée** : fenêtres de 5 heures et de la semaine, avec leur heure de remise à zéro ; des **tokens** par tâche plutôt que des dollars |
| ChatGPT&nbsp;Plus&nbsp;·&nbsp;Pro&nbsp;·&nbsp;Business | idem, d'après les fenêtres que rapporte Codex |

```text
◇  FORFAITS  quota pour les abonnements, coût pour l'API
│  Claude          Claude Pro · 5 h 42 % (remise à zéro 12:57) · semaine 86 % (remise à zéro jeu. 23:17)
│  Codex           ChatGPT Business · semaine 12 % (remise à zéro mer. 19:30)
```

`loomy watch` te prévient quand un quota dépasse 80 %, puis 95 %.

D'où viennent les chiffres, sans réseau ni identifiants :
- **Codex** écrit son quota dans ses propres journaux de session (`~/.codex/sessions`) ; Loomy lit le dernier relevé.
- **Claude Code** transmet à sa commande de barre d'état un champ documenté `rate_limits`. `loomy init` ajoute au projet une petite barre d'état Loomy (`.claude/settings.json`) qui l'enregistre, puis affiche **ta propre barre d'état** si tu en as une (une barre d'état déjà définie dans le projet n'est jamais remplacée). Le quota Claude apparaît dès qu'une session a répondu dans un projet Loomy.

Forfait Claude : `api`, `pro`, `max5`, `max20`, `team` ou `enterprise`

```bash
loomy config set plan_claude max20
```

Forfait ChatGPT / Codex : `api`, `plus`, `pro100`, `pro200`, `business` ou `enterprise`

```bash
loomy config set plan_codex pro200
```

Prix personnalisé du forfait (en $ par mois), utilisé par `loomy stats` pour le comparer à la valeur API de ton travail

```bash
loomy config set plan_claude_price 180
```

### 📊 Statistiques détaillées

```bash
loomy stats
```

Délégations et taux de réussite, durées totale et moyenne, tokens (entrée, cache, sortie) et travail propre de Claude Code (orchestrateur, sous-agents), puis par rôle, par modèle (avec la part du cache) et par jour, et tes forfaits. Avec un abonnement, les montants s'affichent en `≈$…` : ce que le travail coûterait via l'API, couvert par le forfait, à côté de son prix mensuel. `--days 7` ou `--since AAAA-MM-JJ` pour une période ; `loomy log --csv` pour les chiffres bruts.

---

## 🎯 L'orchestrateur et ses rôles

La session principale, l'**orchestrateur**, garde le meilleur raisonnement pour planifier, déléguer, décider et vérifier. Le reste du travail est confié à des rôles dédiés.

```mermaid
flowchart TB
  L["🎯 Orchestrateur<br/>Opus 5.5 · high"]:::lead
  L --> AR["🏛️ Architecte<br/>Opus 5.5 · high"]:::deep
  L --> DB["🐞 Débogueur<br/>Opus 5.5 · high"]:::deep
  L --> SE["🔒 Sécurité<br/>Opus 5.5 · high"]:::deep
  L --> RV["🔍 Relecteur<br/>GPT-6-Sol · high ⇄"]:::std
  L --> DV["🛠️ Développeur<br/>Sonnet 5 · medium"]:::std
  L --> EX["⚙️ Exécutant<br/>GPT-6-Luna · max ⇄"]:::fast
  L --> XP["🔎 Explorateur<br/>Haiku 4.5 · low"]:::fast
  L --> DO["📚 Documentaliste<br/>Sonnet 5 · low"]:::std
  classDef lead fill:#534AB7,stroke:#26215C,color:#FFFFFF
  classDef deep fill:#EEEDFE,stroke:#534AB7,color:#26215C
  classDef std fill:#E1F5EE,stroke:#1D9E75,color:#085041
  classDef fast fill:#FAEEDA,stroke:#BA7517,color:#633806
```

<sub>Mode hybride avec Claude Code en lead, profil Équilibré. ⇄ = rôle exécuté par l'autre outil, via un bridge. 🟪 pointe · 🟩 standard · 🟧 rapide.</sub>

### 🗺️ Matrice complète (profil Équilibré)

| Rôle | 🟠 Full Claude | 🔵 Full Codex | 🟣 Hybride, lead Claude | 🟣 Hybride, lead Codex |
|---|---|---|---|---|
| 🎯&nbsp;**Orchestrateur** | Opus 5.5 · high | Astra · high | **Opus 5.5 · high** | Astra · high |
| 🏛️&nbsp;Architecte | Opus 5.5 · high | Astra · high | Opus 5.5 · high | Opus 5.5 · high ⇄ |
| 🐞&nbsp;Débogueur | Opus 5.5 · high | Sol · xhigh | Opus 5.5 · high | Opus 5.5 · high ⇄ |
| 🔒&nbsp;Sécurité | Opus 5.5 · high | Astra · high | Opus 5.5 · high | Opus 5.5 · high ⇄ |
| 🔍&nbsp;Relecteur | Sonnet 5 · high | Sol · high | Sol · high ⇄ | Sonnet 5 · high ⇄ |
| 🛠️&nbsp;Développeur | Sonnet 5 · medium | Sol · high | Sonnet 5 · medium | Sol · high |
| ⚙️&nbsp;Exécutant | Sonnet 5 · medium | **Luna · max** | **Luna · max** ⇄ | **Luna · max** |
| 🔎&nbsp;Explorateur | Haiku 4.5 · low | Luna · low | Haiku 4.5 · low | Luna · low |
| 📚&nbsp;Documentaliste | Sonnet 5 · low | Sol · low | Sonnet 5 · low | Sol · low |

**Profils de budget.** L'orchestrateur reste toujours sur le meilleur modèle ; seuls les efforts et les modèles des rôles changent.

| Profil | Effet |
|---|---|
| 💚&nbsp;Économe | orchestrateur et spécialistes en `medium`, exécution sur les modèles rapides |
| 💛&nbsp;Équilibré&nbsp;*(défaut)* | la matrice ci-dessus |
| ❤️&nbsp;Qualité&nbsp;max | orchestrateur et spécialistes en `xhigh`, revues sur le modèle de pointe, exécution sur Sol ou Sonnet `high` |

> [!NOTE]
> **Replis automatiques.** Si le mode demande les deux outils mais qu'une CLI manque, le routage bascule sur la matrice complète de l'outil disponible. Si l'outil principal manque, c'est l'autre qui orchestre.
>
> **En hybride :**
> - la revue vient toujours de l'autre famille de modèles ;
> - l'architecture, la sécurité et le debug passent toujours par Opus 5.5 ;
> - l'exécution passe toujours par GPT-6-Luna.
>
> Choisis **Claude Code comme outil principal** pour avoir Opus 5.5 en orchestrateur. C'est le choix par défaut du questionnaire.

---

## 📊 Pourquoi cette répartition

<sub>Analyse du 23/09/2026. « AA » = mesures indépendantes d'Artificial Analysis. Détails, limites et sources : <a href="docs/MODEL_CATALOG.md">docs/MODEL_CATALOG.md</a>.</sub>

| Modèle | 💵 Prix ($ par million de tokens, entrée / sortie) | Coût par tâche AA | Indice de codage AA | Terminal-Bench 4.0 | 🏷️ Rôle attribué |
|---|---|---|---|---|---|
| GPT&#8209;6&#8209;Luna | **0,10 / 0,50** | **0,07 $** | 41 | 🔻 13 % | exécutant, explorateur |
| GPT&#8209;6&#8209;Sol | 2 / 10 | 0,13 → 1,06 $ | 57 | 43 % | développeur, relecteur (Codex) |
| GPT&#8209;6&#8209;Astra | 10 / 50 | 0,82 → 3,26 $ | **62** | 59 % | orchestrateur en full Codex |
| Claude&nbsp;Sonnet&nbsp;5 | 2 / 10 | — | — | — | développeur, relecteur (Claude) |
| Claude&nbsp;Opus&nbsp;5.5 | 4 / 20 | 0,55 → 5,98 $ | non publié | **59,6 %** | 🏆 orchestrateur et spécialistes |
| Claude&nbsp;Fable&nbsp;5.1 | 10 / 50 | 7,63 $ | 62 | 55,8 % | ❌ remplacé par Opus 5.5 |

- 🥇 **Opus 5.5, meilleur orchestrateur.** Il est premier de l'indice d'intelligence AA et en tête du travail agentique. En effort high, il coûte moins cher par tâche qu'Astra en max, pour un meilleur score.
- ⚙️ **GPT-6-Luna max, meilleur exécutant, mais pas un agent autonome.**
  - Il fait 66,6 % sur des corrections bornées pour 0,22 $, contre 2,74 $ pour Sol.
  - Sur le travail long et autonome en terminal, il tombe à 13 %.
  - Il exécute donc des tickets précis sous l'orchestrateur, jamais plus.
- 🐎 **GPT-6-Sol, cheval de trait de Codex.** Il égale Opus 5.5 medium sur l'automatisation de workflows pour environ 40 % du coût.

---

## ✅ Prérequis

| | 🟢 Minimum | ⭐ Idéal |
|---|---|---|
| **Système** | macOS, bash ≥ 3.2 (celui de macOS convient), `git` ; Linux : testé automatiquement (intégration continue), pas encore validé en usage réel | + `gh` connecté |
| **IA** | **une** CLI : Claude Code ≥ 2.1.280 **ou** Codex ≥ 0.155, connectée | **les deux**, installées dans le terminal et détectées par `loomy doctor` : mode hybride |
| **Modèles** | ceux de ton outil | tous répondent à `loomy doctor --live` |
| **Confort** | aucun (questionnaire intégré, sans dépendance) | presse-papiers, pour copier le prompt de démarrage |

**Installer Claude Code et Codex dans le terminal.** `loomy doctor` indique ce qui est détecté et affiche ces commandes pour une CLI absente ; `loomy doctor --fix` propose de les lancer pour toi.

**Claude Code** (installateur officiel)

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

ou avec Homebrew

```bash
brew install --cask claude-code
```

**Codex** (installateur officiel)

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

ou avec Homebrew

```bash
brew install --cask codex
```

Lance ensuite `claude`, puis `codex`, une fois chacun pour te connecter (forfait Claude Pro, Max, Team ou compte Console ; compte ChatGPT pour Codex), et vérifie avec `loomy doctor --live`.

> [!IMPORTANT]
> - **Codex livré avec les apps ChatGPT et Codex.** `loomy doctor --fix` le rend accessible sous le nom `codex` grâce à un petit script dans `~/.local/bin`. Un lien symbolique ne marcherait pas : la CLI cherche ses programmes auxiliaires à côté du chemin par lequel on l'appelle.
> - **Claude Code trop ancien.** Les versions antérieures refusent `claude-opus-5-5`. Le diagnostic propose `claude update`.
> - **Session en bac à sable.** Si l'orchestrateur Claude Code tourne dans un bac à sable, autorise `delegate-to-codex.sh` à s'exécuter hors de ce bac à sable quand il le demande.

---

## 🛠️ Commandes

| Commande | Rôle |
|---|---|
| 🏠&nbsp;<code>loomy</code> | accueil : où en est le projet, ce qui est attendu, et la suite en un choix (hors projet : créer un projet) |
| 📦&nbsp;<code>loomy&nbsp;init&nbsp;[dossier]</code> | crée le dossier si besoin (ou propose de le créer d'après le nom du projet), puis initialise le projet, nouveau ou existant : questionnaire, puis structure mise en place par l'orchestrateur ; sur un projet déjà initialisé : reprendre, `--update`, `--reset` (`--no-wizard`, `--yes`, `--answers` ; projet Git existant : `--no-branch` pour rester sur la branche courante) |
| 📝&nbsp;<code>loomy&nbsp;brief</code> | relance le questionnaire du projet courant |
| 🔒&nbsp;<code>loomy&nbsp;privacy</code> | visibilité des fichiers IA : `versioned`, `local`, `private` ; `sync`, `restore` pour le dépôt privé |
| ▶️&nbsp;<code>loomy&nbsp;start</code> | démarre ou reprend la session de l'orchestrateur (`--resume`, `--new`, `--print`, `--watch`) |
| 🩺&nbsp;<code>loomy&nbsp;doctor</code> | vérifie les prérequis (`--fix` corrige, y compris GitHub : installation de `gh`, connexion, accès de git au dépôt Loomy ; `--live` teste chaque modèle) |
| 💬&nbsp;<code>loomy&nbsp;feedback</code> | signale un bug ou une idée : issue GitHub pré-remplie (versions, état du projet anonymisé, sans nom, objectif ni texte des tâches), envoyée seulement après ton accord ; `--print` pour voir le texte |
| 🧭&nbsp;<code>loomy&nbsp;route</code> | matrice du projet · `lead` · `get <rôle>` · `markdown` · `all` · `claude-agents` · `codex-profiles` |
| 🔀&nbsp;<code>loomy&nbsp;delegate&nbsp;codex&nbsp;&lt;rôle&gt;&nbsp;"…"</code> | confie un rôle à Codex (exécutant, développeur, documentaliste en écriture ; les autres en lecture seule) |
| 🔀&nbsp;<code>loomy&nbsp;delegate&nbsp;claude&nbsp;&lt;rôle&gt;&nbsp;"…"</code> | confie un rôle à Claude en lecture seule (architecte, débogueur, sécurité, relecteur, explorateur) |
| 🔬&nbsp;<code>loomy&nbsp;assess</code> | état des lieux d'un projet existant, sans IA : stack, commandes, tests, CI, conventions, historique Git, zones sensibles, dette (`.loomy/assessment.md` ; `--print` pour seulement l'afficher) |
| 📈&nbsp;<code>loomy&nbsp;status</code>&nbsp;·&nbsp;<code>loomy&nbsp;watch</code>&nbsp;·&nbsp;<code>loomy&nbsp;log</code> | suivi (voir ci-dessus) |
| 📊&nbsp;<code>loomy&nbsp;stats</code> | statistiques détaillées : par rôle, modèle et jour, durées, tokens, coût ou quota (`--days N`, `--since AAAA-MM-JJ`) |
| 🎚️&nbsp;<code>loomy&nbsp;effort</code> | effort de raisonnement de l'orchestrateur pour ce projet (`loomy effort low`, menu sans argument), ou d'un rôle (`loomy effort executor high`) ; `--list`, `--reset` ; pris en compte au prochain `loomy start` |
| ⚙️&nbsp;<code>loomy&nbsp;config</code> | préférences : `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`yes` : `loomy start` ouvre toujours le suivi à côté), `notify` (`no` : pas de notifications dans `loomy watch`), `lang` (`fr`, `en` ou `auto` : langue de l'interface, détectée par défaut) |
| 🌳&nbsp;<code>loomy&nbsp;worktrees&nbsp;&lt;tâche&gt;</code> | deux worktrees séparés pour le mode parallèle |
| 🔄&nbsp;<code>loomy&nbsp;update</code>&nbsp;·&nbsp;<code>loomy&nbsp;version</code> | mise à jour de Loomy, valable pour tous les projets ; `update --catalog` : seulement le catalogue des modèles et des prix ; `version --all` liste toutes les installations |
| 🗑️&nbsp;<code>loomy&nbsp;uninstall</code> | montre comment désinstaller Loomy selon l'installation, et comment le retirer d'un projet |
| ❓&nbsp;<code>loomy&nbsp;help&nbsp;[commande]</code> | aide générale, ou aide d'une commande |

<sub>Les commandes trouvent le projet depuis n'importe lequel de ses sous-dossiers, y compris quand le projet Loomy vit dans un sous-dossier d'un dépôt Git plus large. Dans un projet, l'orchestrateur appelle les scripts de <code>.loomy/scripts/</code> : ce sont de petits relais vers le Loomy installé sur la machine (trouvé par <code>$LOOMY_HOME</code>, la commande <code>loomy</code> ou ses emplacements habituels). <code>LOOMY_NO_CLEAR=1</code> garde l'historique du terminal au lieu d'effacer l'écran.</sub>

---

## 🤝 Modes de collaboration

| Mode | Principe | Quand |
|---|---|---|
| 🧍&nbsp;**SOLO** | un seul outil fait tout | petits projets, budget serré |
| 👀&nbsp;**REVIEW** | l'un implémente, l'autre relit le diff | changements substantiels |
| 🔁&nbsp;**HANDOFF** | point d'arrêt propre + `.ai/HANDOFF.md`, l'autre reprend | changement d'outil en cours de route |
| 🌳&nbsp;**PARALLEL** | deux worktrees, périmètres disjoints | chantiers vraiment indépendants |
| 🎯&nbsp;**ORCHESTRATED** | l'orchestrateur délègue chaque rôle au meilleur modèle des deux familles | **recommandé** quand les deux outils sont installés |

---

## 📚 Pour aller plus loin

<details>
<summary><b>📁 Ce que génère le bootstrap dans ton projet</b></summary>

```text
mon-projet/
├── AGENTS.md                  # point d'entrée Codex (court)
├── CLAUDE.md                  # point d'entrée Claude Code (court)
├── PROJECT.md                 # intention produit, périmètre, contraintes
├── ARCHITECTURE.md            # si utile
├── .ai/
│   ├── AI_WORKFLOW.md         # contrat de collaboration commun
│   ├── AI_ORCHESTRATION.md    # règles de délégation entre modèles
│   ├── AI_MODEL_ROUTING.md    # matrice rôle → modèle → effort
│   └── HANDOFF.md             # temporaire, pendant un passage de relais
├── .claude/agents/            # sous-agents générés (modèle + effort)
├── .loomy/                    # scripts, templates, brief, état et journal (logs/ ignoré par Git)
└── docs/decisions/            # ADR, seulement pour les décisions importantes
```

</details>

<details>
<summary><b>🏗️ Projet existant, audit de sécurité, fin du bootstrap</b></summary>

<br>

- **Projet existant.** Lance `loomy init` dans le dépôt. Loomy passe sur une branche dédiée `loomy/adopt` (la branche courante reste intacte, le travail non commité reste tel quel), écrit un état des lieux sans IA (`.loomy/assessment.md` : stack, vraies commandes, tests, CI, conventions, historique Git, zones sensibles, dette), et l'orchestrateur propose un plan d'adoption : `PROJECT.md` et `ARCHITECTURE.md` reconstruits à partir du code, `AGENTS.md` et `CLAUDE.md` alignés sur les commandes du dépôt, rôles dimensionnés selon son risque. Rien d'existant n'est écrasé, aucun code applicatif ne change sans ton accord, et le retour sur la branche d'origine passe par une pull request que tu acceptes.
- **Audit de sécurité.** Il se lance à la demande, avec le skill officiel Cloudflare. Installe-le avec `.loomy/scripts/install-security-audit.sh --global`, puis demande un audit complet sans modification du code.
- **Fin du bootstrap.** `START.md` est archivé dans `.ai/bootstrap/` ou supprimé, selon ton choix. Il n'a plus aucune autorité ensuite.

</details>

<details>
<summary><b>🔄 Mettre à jour le catalogue de modèles</b></summary>

<br>

Tout le catalogue tient dans `scripts/lib/models.sh` : six variables `AI_MODEL_*`, les prix, et les versions minimales des CLI. Quand de nouveaux modèles sortent :

1. mets à jour ces valeurs, et le classement dans `_ai_base` si nécessaire ;
2. lance `loomy doctor --live` ;
3. mets à jour `docs/MODEL_CATALOG.md` et `CHANGELOG.md`.

Pour essayer un autre modèle sur une seule machine, sans rien modifier : `AI_MODEL_CODEX_FAST=gpt-6-sol loomy route`. Si la CLI Codex est installée à un endroit inhabituel, indique son chemin avec `LOOMY_CODEX_BIN`.

</details>

<details>
<summary><b>🧪 Tests</b></summary>

<br>

```bash
tests/run.sh
```

Avec `-v`, la sortie des tests en échec s'affiche.

La suite exerce chaque commande en conditions réelles (bash, git, pseudo-terminal pour le questionnaire), sans réseau ni token : `claude` et `codex` y sont remplacés par des doublures (`tests/stubs/`). Elle couvre l'installation, le questionnaire interactif et non interactif, le routage des 4 environnements × 3 profils, les deux bridges, le journal dans tous ses états, le suivi en direct, le diagnostic avec ou sans CLI, les worktrees et `install.sh`. `shellcheck` et `expect` sont utilisés s'ils sont installés.

</details>

<details>
<summary><b>📦 Contenu du dépôt</b></summary>

```text
loomy/
├── bin/loomy                  # commande unique
├── install.sh · package.json  # installation shell, npm et bun
├── START.md · VERSION · CHANGELOG.md · SECURITY.md · README.md · README.fr.md
├── scripts/
│   ├── install-into-project.sh · init-wizard.sh · ai-doctor.sh · ai-route.sh · ai-status.sh
│   ├── delegate-to-claude.sh · delegate-to-codex.sh · detect-ai-tools.sh
│   ├── create-hybrid-worktrees.sh · install-security-audit.sh
│   └── lib/                   # ui.sh · models.sh · journal.sh · config.sh
├── templates/                 # AGENTS, CLAUDE, WORKFLOW, ORCHESTRATION, MODEL_ROUTING, HANDOFF, PROJECT, ARCHITECTURE, ADR
│   └── claude-agents/         # architect, debugger, developer, documenter, executor, explorer, reviewer, security
├── skills/project-bootstrap/  # SKILL.md + références
├── agents/ROLE-CATALOG.md · external-skills/security-audit.md
├── docs/DESIGN.md · docs/MODEL_CATALOG.md
└── tests/run.sh · tests/stubs/  # suite de tests sans réseau
```

</details>

---

## 🔐 Sécurité

Ce que Loomy garantit (rien n'est poussé ni supprimé sans toi, projets existants intacts, catalogue lu comme de simples données, fichiers de projet non fiables assainis, fichiers temporaires privés) et comment signaler une faille : [SECURITY.md](SECURITY.md) (en anglais).

---

## 🔮 Feuille de route

| Statut | Fonctionnalité |
|---|---|
| ✅&nbsp;0.1 | Commande `loomy`, questionnaire, diagnostic, routage orchestrateur + rôles, bridges, journal, suivi terminal en direct (plein écran, `start --watch`, notifications), effort réglable par projet, forfaits, installation Homebrew, npm, bun et shell, suite de tests |
| ✅&nbsp;0.2 | **Consolider, avant l'arrivée des testeurs** : fait |
| ✅ | `loomy start --watch` rejoint une session déjà ouverte au lieu de la fermer ; nettoyage des scripts temporaires ; plateformes annoncées au plus juste (macOS, Linux testé automatiquement) |
| ✅ | Tests macOS et Linux à chaque push (GitHub Actions) |
| ✅ | `loomy feedback` : issue GitHub pré-remplie (version, diagnostic, fin du journal, brief anonymisé) |
| ✅ | Installation des testeurs simplifiée : `loomy doctor --fix` enchaîne les étapes `gh` |
| ✅&nbsp;0.3 | **Fiabiliser** : fait |
| ✅ | Plus de copie des scripts dans chaque projet : un lien vers le Loomy installé ; `loomy init --update` réservé aux changements de templates |
| ✅ | Catalogue de modèles et de prix mis à jour sans nouvelle version (`loomy update --catalog`), alerte si un modèle routé disparaît |
| ✅ | Coûts réels : orchestrateur Claude Code (hook `Stop`) et sous-agents (hook `SubagentStop`), mesurés dans la transcription au prix public ; export CSV |
| ✅ | Journal archivé chaque mois, `loomy log --since` |
| ✅&nbsp;0.3.5 | **Interface à cadre fixe** : en-tête (logo, projet, contexte), corps qui seul change, pied (touches, version) ; l'accueil ouvre statut, journal, visibilité et aide dans le cadre ; rien ne s'empile dans le terminal |
| ✅&nbsp;0.3.7 | **Autonomie et points d'arrêt** dans les instructions générées (`AGENTS.md`, `CLAUDE.md`) : l'agent avance seul sur une tâche bornée et s'arrête avant toute opération destructive, selon les recommandations Anthropic pour Opus 5.5 |
| ✅&nbsp;0.3.8 | **Modèles qui changent souvent** : chaînes de repli par niveau dans le catalogue (le plus récent d'abord, repli automatique pour qui n'y a pas accès), disponibilité apprise sur chaque machine (`doctor --live`, refus d'une délégation), modèle épinglable (`loomy config set model.claude.mid …`), répartition des rôles modifiable par le catalogue, nouveau catalogue signalé ; protocole dans `docs/MODEL_CATALOG.md` |
| ✅&nbsp;0.4 | **Interface en anglais et en français** |
| ✅ | Langue détectée automatiquement (`LC_ALL`, `LC_MESSAGES`, `LANG`, puis langue du système sous macOS) : français si elle commence par `fr`, **anglais par défaut** sinon ou si rien n'est détectable (macOS comme Linux) ; réglage `loomy config set lang fr\|en\|auto` |
| ✅ | Tous les textes de l'interface passent par un dictionnaire, migrés écran par écran : cadre et accueil, `watch` et `status`, `start` et `effort`, questionnaire et mise en place, diagnostic, aide et messages |
| ✅ | Langue des documents du projet proposée d'après la langue détectée ; test de couverture des deux langues |
| ✅&nbsp;0.4.1 | **L'anglais d'abord** : code, aide, documents des agents (`START.md`, templates, rôles, skills), brief de démarrage, prompts de délégation, README et journal des modifications en anglais ; le français est une traduction (`scripts/lib/i18n/fr.tsv`, `fr/`), utilisée quand le français est détecté |
| ✅&nbsp;0.5 | **Adopter un projet existant** |
| ✅ | `loomy init` sur un projet déjà développé et versionné (Git, dépôt distant, branches) : rien n'est écrasé, tout passe par une branche dédiée et une validation |
| ✅ | État des lieux (`loomy assess`) : langages, frameworks, structure, dépendances, tests, CI, conventions de code, documentation existante, historique Git (activité, zones sensibles, auteurs), dette et risques repérés |
| ✅ | Adaptation initiale d'après cet état des lieux : `PROJECT.md`, `ARCHITECTURE.md` et décisions reconstitués à partir du code, `AGENTS.md` et `CLAUDE.md` alignés sur les conventions du dépôt (commandes de test, de lint, de build), rôles, routage et effort ajustés à la taille et au risque du projet |
| ✅ | Plan d'adoption relu avant tout commit : ce qui a été compris, ce qui reste à confirmer, recommandations priorisées |
| ✅&nbsp;0.5.1 | Vérification écran par écran de toutes les commandes, en anglais et en français |
| ✅&nbsp;0.5.2 | Revue de sécurité et de robustesse ([SECURITY.md](SECURITY.md)) |
| ✅&nbsp;0.5.3 | **Version actuelle** · **quotas réels des abonnements** : part des quotas Claude et Codex utilisée (fenêtres de 5 heures et de la semaine) au lieu des dollars avec un abonnement, tokens par tâche, alertes à 80 % et 95 % ; `loomy stats` pour des statistiques détaillées |
| 🔜 | **Le quotidien après le bootstrap** |
| | `loomy task "…"` : une tâche nommée, confiée à l'orchestrateur, suivie dans `watch` (phases, coût, durée), jusqu'à la validation et au commit ; fichier d'avancement (`TASKS.md`) tenu par l'agent pendant les tâches longues |
| | `loomy models` : repère les nouveaux modèles à évaluer (liste des modèles de Codex, API des éditeurs si une clé est configurée, catalogue publié), propose de les placer en tête de chaîne avec jusqu'à deux replis (ex. Opus 6 → Opus 5.5 → Opus 5), et un mode économe qui préfère les replis ; ouvre sur GitHub un ticket de suggestion par nouveau modèle (étiquette `modèles`, sans doublon : ticket existant retrouvé et complété plutôt que recréé), pour évaluation avant publication du catalogue |
| | `loomy review` : revue croisée à la demande sur la branche ou le diff en cours |
| | Modèles de projet (web, API, CLI, e-mails…) qui pré-remplissent le brief et la structure |
| | `loomy report` : bilan d'un projet (tâches, coûts, délégations), comparaison entre projets, page HTML à partager |
| 🎯&nbsp;RC | **Release candidate : validation en conditions réelles** |
| | Retours des testeurs (`loomy feedback`) traités |
| | Questionnaire et interface découpés en modules plus petits, tests répartis par thème |
| | Thème de couleurs réglable (`loomy config`), pour les terminaux qui n'affichent pas le gras |
| | README court (« 5 minutes pour démarrer »), référence complète à part |
| | Dépôt public et Homebrew sans jeton, sur décision |
| 💡 | Intégration de [Jev](https://github.com/WXK-AI/jev-opus) : effort d'Opus 5.5 réajusté à chaque étape pendant les délégations Claude, quand Jev est installé |

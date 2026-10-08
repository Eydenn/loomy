# LOOMY — BOOTSTRAP TEMPORAIRE

> Statut : `BOOTSTRAP_PENDING`
> Ce fichier est temporaire. Son autorité prend fin une fois le bootstrap terminé.

## Objectif

Transformer ce dépôt en un projet bien cadré, documenté et testable, avec une équipe adaptative d'agents et de sous-agents, et uniquement les skills et capacités réellement utiles.

Le but est d'obtenir le maximum de valeur fiable avec le minimum de contexte, d'agents, de fichiers, de dépendances et de tokens superflus.

## Comportement obligatoire du bootstrap

Quand on te demande d'initialiser ce projet, ne génère **pas** immédiatement de code applicatif.

Suis ces phases dans l'ordre :

1. Découverte
2. Entretien
3. Proposition
4. Attente d'une validation explicite
5. Construction
6. Vérification
7. Documentation
8. Commit
9. Archivage de ce fichier

Ne saute pas l'étape de validation avant de créer le projet, sauf si l'utilisateur te le demande explicitement.

---

## Suivi de l'avancement

Au début de chaque phase, **avant toute autre action**, enregistre-la : l'utilisateur la voit aussitôt dans `loomy watch`, avec ce qui est attendu de lui.

```bash
.loomy/scripts/loomy-status.sh set <discover|interview|propose|approve|build|verify|document|commit|retire|done>
```

Si le script est absent, ignore cette étape sans le signaler.

À chaque changement de phase, annonce-la à l'utilisateur sur une ligne qui commence par le numéro de phase, puis dis en une phrase ce que tu fais maintenant et ce que tu attends de lui (réponses, validation, relecture) : il ne doit jamais se demander si c'est à lui d'agir. Exemple :

> **Phase 6/10 · Construction**. Je mets en place la structure, puis je confie la rédaction à Codex. Rien à faire de ton côté pour l'instant.

Pendant un long travail, l'utilisateur ne voit qu'un indicateur d'attente : donne-lui des repères.
- **Avant chaque délégation**, une ligne : rôle, modèle, ce qui est demandé, durée indicative. Exemple : « → Je confie la rédaction des e-mails à l'exécutant Codex (gpt-6-luna), 1 à 3 min. »
- **Après chaque délégation**, une ligne : résultat et durée. Exemple : « ✓ Exécutant terminé en 1 min 41 s : 4 fichiers créés. Je vérifie. »
- Entre deux étapes longues, une ligne de progression suffit (« 3 fichiers sur 5 relus »). Pas de pavé : l'utilisateur doit pouvoir suivre d'un coup d'œil.

Si la session a été interrompue, l'utilisateur la reprend avec `loomy start` ; une nouvelle session reprend à la phase enregistrée dans `.loomy/state`. Avec Claude Code, le contexte de reprise (`.loomy/scripts/loomy-context.sh`) est injecté automatiquement à l'ouverture de chaque session ; avec Codex, lance ce script en début de session.

Codex reçoit le même contexte par `.codex/hooks.json`, une fois ses hooks approuvés au premier lancement. Quand tu génères `.claude/settings.json` ou `.codex/`, conserve les hooks Loomy déjà présents (`loomy-context.sh`).

Chaque délégation passée par les bridges (`loomy-delegate-claude.sh`, `loomy-delegate-codex.sh`) est journalisée automatiquement dans `.loomy/logs/events.jsonl` : rôle, modèle, effort, durée, tokens, coût. L'utilisateur suit ce journal en direct dans le terminal (`loomy watch`). Tu n'as rien à lancer pour cela.

---

## Projet existant (adoption)

Quand `.loomy/brief.md` indique `repo: existing`, tu adoptes un projet qui vit déjà : son code, son historique et ses habitudes passent en premier. Les phases restent les mêmes, avec ces règles.

**Règles de base**
- Lis d'abord `.loomy/assessment.md` : des faits recueillis sans IA (stack, commandes, tests, CI, conventions, historique Git, zones sensibles, dette). S'il manque ou date, lance `.loomy/scripts/loomy-assess.sh`.
- Si `adopt_branch` est renseigné dans le brief, travaille **uniquement sur cette branche**. La `base_branch` reste intacte : ne fusionne jamais dedans, ne la pousse pas, ne réécris pas son historique, jamais de push forcé. Ne renomme ni ne supprime les branches, tags ou remotes existants.
- Rien d'existant n'est écrasé. Un `README`, `AGENTS.md`, `CLAUDE.md`, une documentation ou une configuration existants sont complétés ou fusionnés, jamais remplacés ; montre le diff de toute modification.
- Les changements non commités présents à l'arrivée de Loomy appartiennent à l'utilisateur : ne les indexe et ne les committe jamais.
- Aucune modification du code applicatif pendant l'adoption, sauf accord explicite de l'utilisateur.

**Découverte.** Confirme l'état des lieux en lisant le code : points d'entrée, modules principaux, modèle de données, façon dont les tests et le build tournent vraiment. Lis de façon ciblée, pas tout.

**Entretien.** Ne demande que ce que le code et l'historique ne disent pas : intention et utilisateurs, travaux en cours, ce qui ne doit pas changer, points douloureux connus.

**Proposition : un plan d'adoption**, validé avant toute écriture :
- `PROJECT.md` reconstruit à partir du README, du code et de l'historique ; `ARCHITECTURE.md` à partir du code réel ; des ADR seulement pour les décisions visibles dans le code ou l'historique qu'on pourrait remettre en cause ;
- `AGENTS.md` et `CLAUDE.md` alignés sur les vraies commandes du dépôt (test, lint, build) et ses conventions, pas des génériques ;
- rôles, routage et effort dimensionnés selon la taille et le risque du projet (voir l'état des lieux), avec le rôle sécurité sur les zones sensibles ;
- les changements de standardisation (outillage, CI, tests), listés à part, chacun facultatif et justifié.

**Construction et vérification.** N'écris que les documents et la configuration IA validés. Lance les commandes de test, lint et build existantes pour établir la situation de départ : un échec déjà présent est signalé comme tel, pas corrigé sans accord.

**Commit.** Si c'est autorisé, committe sur la branche d'adoption (`chore: adopt Loomy`), ne pousse que cette branche et seulement si c'est autorisé, puis propose à l'utilisateur une pull request vers `base_branch` (`gh pr create --base <base_branch> --head <adopt_branch>`) ou une fusion qu'il fera lui-même.

---

## Phase 1 — Découverte

Si `.loomy/brief.md` existe, lis-le en premier. Il contient les réponses de l'utilisateur au questionnaire du terminal (`loomy-init-wizard.sh`) :
- objectif et type de projet ;
- caractéristiques clés (`traits` : comptes, paiements, données sensibles, gros volumes, flux externes, API publique…), stade et risque estimé ;
- les vérifications imposées par chaque caractéristique, et des recommandations à proposer à l'utilisateur (jamais appliquées sans son accord) ;
- mode IA et outil principal ;
- profil de budget des modèles ;
- langue de la documentation et sort de ce fichier ;
- autorisations de commit et de push.

Traite-le comme un entretien déjà mené : confirme-le en une ligne, ne repose pas ces questions, et signale tout ce que le dépôt contredit.

Inspecte le dépôt avant de poser des questions.

Établis uniquement ce qui se déduit facilement des fichiers existants :

- dépôt vide ou existant ;
- état Git actuel ;
- README et instructions existants ;
- stack détectée, gestionnaire de paquets, runtimes et configuration ;
- tests, lint, formatage, vérification de types et CI existants ;
- `AGENTS.md`, `CLAUDE.md`, skills, outillage MCP ou configuration d'agents existants ;
- contraintes évidentes imposées par le code actuel.

Ne lis pas tout le dépôt sauf nécessité.
N'installe pas de dépendances et ne modifie aucun fichier du projet pendant cette phase.

---

## Phase 2 — Entretien adaptatif

Passe en mode planification uniquement.

Pose le **plus petit ensemble de questions à fort impact** nécessaire pour lever les ambiguïtés importantes.
N'utilise pas de questionnaire figé et ne pose pas de questions dont la réponse se déduit déjà du dépôt, de `.loomy/brief.md` ou de la demande initiale.

Clarifie toujours, quand c'est pertinent :

- l'objectif du produit ou du projet ;
- les utilisateurs cibles ;
- les plateformes et environnements visés ;
- le MVP ou le périmètre demandé ;
- les contraintes techniques fortes ;
- les besoins en données, stockage, backend et API ;
- l'authentification, les données sensibles et les contraintes de sécurité ;
- le fonctionnement hors ligne ou en ligne ;
- la cible de déploiement ou de distribution ;
- les priorités de qualité : vitesse, maintenabilité, accessibilité, performance, coût ;
- les systèmes ou API existants à intégrer.

Ne pose de questions spécifiques au domaine que si elles changent l'architecture ou l'implémentation.
Exemples :

- Mobile : Expo ou natif, iOS/Android, hors ligne, notifications, stores.
- Web/SaaS : authentification, multi-tenant, paiements, hébergement, SEO.
- Desktop : OS cibles, accès au système de fichiers, mises à jour automatiques, signature et distribution.
- CLI/bibliothèque : stabilité de l'API publique, runtimes supportés, packaging.
- IA/LLM : contraintes de modèle ou de fournisseur, exposition des données, limites des prompts et des outils, évaluation.

Préfère une seule série de questions concise. N'en pose une deuxième que si les réponses révèlent une nouvelle ambiguïté importante.

---

## Phase 3 — Proposition de projet

Avant toute modification du projet, présente une proposition concise contenant :

### Produit
- Objectif
- Utilisateurs principaux
- Périmètre initial
- Non-objectifs explicites, si utile

### Direction technique
- Stack proposée
- Style d'architecture
- Dépendances clés uniquement
- Persistance et intégrations
- Stratégie de déploiement ou de distribution, si pertinent

Pour un projet **Données et analyse** (`type: data`), structure la proposition en pipeline : ingestion → stockage brut (jamais modifié) → transformations versionnées → jeux de données analytiques → livrables (rapports, tableaux de bord, outil, API, modèles, comme dans le brief). Dimensionne la stack selon le volume (`detail2`) : Python avec Polars pour des mégaoctets, DuckDB ou Polars sur Parquet pour des gigaoctets, un entrepôt ou un moteur distribué pour des téraoctets. Prévois des tests de qualité des données et la traçabilité de chaque chiffre publié. Les agents ne reçoivent jamais le jeu de données complet : schémas, statistiques et échantillons anonymisés seulement ; avec des données sensibles, ce qui doit voir des valeurs réelles passe par un modèle local, ou par aucun modèle.

### Profil d'exécution
Classe en interne et indique :

- Complexité : `SIMPLE | STANDARD | COMPLEX`
- Risque : `LOW | MEDIUM | HIGH`

Le risque augmente avec : authentification, permissions, paiements, données personnelles ou sensibles, migrations, infrastructure de production, opérations destructives, cryptographie, logique critique pour la sécurité, ou changements transverses importants.

### Mode de fonctionnement IA
Détecte les CLI IA disponibles avec `.loomy/scripts/loomy-detect-tools.sh` s'il existe.
Détermine le mode par défaut du projet :

- `SOLO` : un seul agent de code à la fois ;
- `HYBRID` : Codex et Claude peuvent tous deux intervenir sur le dépôt ;
- `ORCHESTRATED` : un agent principal peut solliciter l'autre modèle comme spécialiste ;
- `PARALLEL` : les deux travaillent en même temps sur des branches ou worktrees isolés.

Si Codex et Claude sont tous deux susceptibles d'être utilisés, choisis `HYBRID` par défaut.
Ne suppose pas qu'ils partagent directement le contexte de conversation. Coordonne-les par le dépôt, les points de contrôle Git, `.loomy/docs/AI_WORKFLOW.md`, et `.loomy/docs/HANDOFF.md` quand un passage de relais explicite est nécessaire.
Pour une implémentation parallèle, exige des branches ou worktrees Git séparés et des périmètres qui ne se chevauchent pas.

### Équipe d'agents adaptative
Utilise `.loomy/agents/ROLE-CATALOG.md` comme source de rôles réutilisables s'il existe. Ne matérialise les rôles choisis dans `.loomy/docs/agents/` que si des fichiers de rôle explicites améliorent l'outil utilisé ; sinon, garde les rôles implicites.

Ne propose que des rôles qui apportent une valeur claire.
Rôles possibles :

- Agent principal / orchestrateur
- Explorateur
- Architecte
- Implémenteur
- Frontend / UI / UX
- Backend / API
- Données / base de données
- Spécialiste mobile ou desktop
- Tests / QA
- Sécurité
- Performance
- DevOps
- Relecteur
- Documentation
- Recherche

N'instancie pas tous les rôles par défaut.
N'utilise un sous-agent que si le travail est parallélisable, spécialisé, gagne à être isolé du contexte principal, ou bénéficie d'une relecture indépendante.

### Routage des modèles
Tu es l'**orchestrateur** (agent principal) : garde pour toi la planification, les décisions, l'intégration et la vérification, et délègue le travail aux rôles dédiés (architecte, débogueur, sécurité, relecteur, développeur, exécutant, explorateur, documentaliste).

Lance `.loomy/scripts/loomy-route.sh` et inclus sa matrice dans la proposition. Pour cette machine et ce brief, elle détermine :
- l'environnement : full Claude, full Codex, ou hybride avec l'un ou l'autre en lead, avec repli automatique si une CLI manque ;
- le profil de budget ;
- le modèle, l'effort et le mode d'appel de chaque rôle.

N'invente pas de noms de modèles : le moteur de routage et `.loomy/scripts/loomy-doctor.sh` font foi.

Adapte à la taille du projet : un projet SIMPLE/LOW peut se contenter de l'orchestrateur, d'un explorateur et d'un exécutant ou d'un développeur.

### Skills et outils
Liste uniquement les skills et outils à activer pour ce projet.
Préfère les skills spécialisés existants plutôt que de recréer leur workflow.
Ne charge pas de skills sans rapport « au cas où ».

### Plan de documentation
Ne propose que les documents durables dont le projet a besoin.
Candidats :

- `AGENTS.md`
- `CLAUDE.md`
- `PROJECT.md`
- `ARCHITECTURE.md`
- `README.md`
- `docs/decisions/`
- `docs/plans/`

### Critères de qualité
Indique les vérifications concrètes attendues avant de considérer le travail terminé, par exemple :

- vérification de types ;
- lint ;
- tests ciblés ;
- suite de tests complète quand c'est justifié ;
- build ;
- commande de diagnostic propre au framework ;
- revue de sécurité quand c'est pertinent.

Demande ensuite une validation explicite de la proposition.

---

## Phase 4 — Construction après validation

Après validation :

1. Crée ou adapte la structure du projet.
2. Génère les instructions IA du projet à partir des templates de `.loomy/templates/` s'ils existent.
3. Ne crée que la documentation justifiée par la proposition.
4. Installe et configure l'outillage minimal adapté.
5. Crée le plus petit squelette cohérent d'application ou de bibliothèque qui prouve que la mise en place fonctionne.
6. Ajoute les tests et vérifications adaptés à la stack.
7. Évite les fonctionnalités spéculatives et les dépendances sans rapport.

### Instructions de projet obligatoires

Génère à la racine un `AGENTS.md` concis pour Codex, avec les faits propres au projet et les règles de travail.
Génère `CLAUDE.md` pour Claude Code, comme une fine couche de compatibilité.
Génère `.loomy/docs/AI_WORKFLOW.md` à partir du template de workflow commun, pour que Codex et Claude suivent le même contrat de coordination sans dupliquer de longues instructions.
Si un usage hybride est prévu, prévois `.loomy/docs/HANDOFF.md` comme fichier de coordination éphémère, pas comme mémoire permanente du projet.

L'`AGENTS.md` généré reprend la section « Autonomie et points d'arrêt » du template : quand avancer seul, et quand s'arrêter pour demander (toujours avant une opération destructive ou difficile à annuler). Adapte-la au projet (ex. commandes de migration, environnements de production), sans l'affaiblir.

Garde les fichiers d'instructions permanents courts. Les connaissances détaillées vont dans `PROJECT.md`, `ARCHITECTURE.md`, les ADR ou des skills spécialisés, et ne se chargent que lorsqu'elles sont utiles.

### Mise en place hybride Codex + Claude

Quand le mode hybride est choisi :

1. Crée `AGENTS.md` à la racine pour Codex.
2. Crée `CLAUDE.md` à la racine pour Claude Code.
3. `.loomy/docs/AI_WORKFLOW.md` et `.loomy/docs/AI_ORCHESTRATION.md` ont déjà été créés par Loomy à partir de ses templates : adapte-les au projet, ne les recrée pas.
4. Dans `AGENTS.md` et `CLAUDE.md`, garde le bloc entre les repères `<!-- loomy:orchestration -->` : Loomy l'entretient (il est remis à la session suivante s'il disparaît).
5. Ne crée pas `.loomy/docs/HANDOFF.md` tant qu'aucun passage de relais réel n'est en cours.
6. Pour le travail parallèle, utilise des branches ou worktrees isolés ; ne laisse jamais les deux outils modifier le même répertoire de travail en même temps.
7. Quand l'implémentation parallèle n'est pas nécessaire, préfère qu'un outil implémente et que l'autre relise, pour un contrôle croisé à forte valeur.
8. La délégation entre modèles suit le routage de `loomy-route.sh`. Avec un lead Codex, les rôles Claude passent par `.loomy/scripts/loomy-delegate-claude.sh` (spécialiste Claude en lecture seule). Avec un lead Claude, les rôles Claude sont les sous-agents natifs de `.claude/agents/` (outil Agent) : n'utilise pas `loomy-delegate-claude.sh`, son `claude -p` sans interface refuse toute commande shell non pré-approuvée. Les rôles Codex (exécutant, développeur, relecteur…) passent par `.loomy/scripts/loomy-delegate-codex.sh`. L'orchestrateur valide chaque résultat avant d'agir. Lance toujours ces scripts **au premier plan** et attends leur fin : une délégation lancée en arrière-plan est interrompue si la session se ferme.
9. N'utilise pas les appels entre modèles pour des tâches triviales ni pour faire confirmer automatiquement chaque décision.

### Mise en place du routage des modèles

Quand le routage est validé :

1. `.loomy/docs/AI_MODEL_ROUTING.md` existe déjà (créé par Loomy avec la matrice résolue). Si le routage validé diffère, régénère sa dernière section avec la sortie de `.loomy/scripts/loomy-route.sh markdown`.
2. Si l'outil principal est Claude Code, les sous-agents de rôle sont déjà dans `.claude/agents/` (créés par Loomy, modèle et effort renseignés). Supprime les rôles que la proposition n'a pas retenus ; adapte les autres au projet si c'est utile.
3. Si Codex est utilisé, les rôles passent par `loomy-delegate-codex.sh <rôle>`, qui ne demande aucune configuration. Pour des sessions Codex interactives par rôle, donne à l'utilisateur la sortie de `loomy-route.sh codex-profiles`. Ne modifie jamais le `~/.codex/config.toml` global de l'utilisateur sans son accord explicite.
4. Donne à l'utilisateur la commande de lancement de l'orchestrateur (`loomy-route.sh lead`) pour ses prochaines sessions.

---

## Phase 5 — Vérification

Avant de terminer, lance les vérifications les plus solides disponibles pour le projet initialisé.

Ordre préféré :

1. vérifications ciblées ;
2. vérification de types ;
3. lint ;
4. tests ;
5. build ;
6. diagnostics du framework ou du runtime ;
7. test manuel rapide quand c'est pertinent.

N'affirme jamais qu'une vérification est passée si elle n'a pas réellement réussi.
Distingue clairement `vérifié`, `déduit` et `non testé`.

Si une vérification échoue, diagnostique et corrige la cause avant de continuer, dans la mesure du raisonnable.

---

## Phase 6 — Documentation et mémoire

Ne conserve que les informations durables.

### `PROJECT.md`
Consigne l'intention produit, les utilisateurs, le périmètre, les contraintes, les non-objectifs et les exigences importantes.

### `ARCHITECTURE.md`
À créer seulement si l'architecture n'est pas triviale. Consigne la stack, les frontières entre modules, les flux principaux, la persistance, les intégrations, le modèle de build et de déploiement, et les invariants importants.

### ADR
Crée `docs/decisions/NNN-*.md` uniquement pour les décisions que de futurs développeurs ou agents pourraient raisonnablement remettre en cause, et dont la justification compte.
Pas d'ADR pour les choix triviaux.

### Plans
N'utilise `docs/plans/` que pour les chantiers importants en cours. N'accumule pas de plans périmés.

---

## Phase 7 — Sécurité

L'audit de sécurité se fait **à la demande** ; il n'est pas chargé en permanence.

Quand l'utilisateur demande explicitement un audit de sécurité, une revue de vulnérabilités, une revue du code façon test d'intrusion, ou équivalent :

1. Préfère le skill officiel Cloudflare `security-audit` s'il est disponible.
2. S'il n'est pas installé, utilise `.loomy/scripts/loomy-install-security-audit.sh` s'il existe, ou suis `.loomy/external-skills/security-audit.md`.
3. Préserve les garanties importantes du workflow Cloudflare :
   - reconnaissance à partir du code source ;
   - registre de couverture déterministe ;
   - agents de recherche isolés ;
   - vérificateur indépendant et neuf pour chaque candidat ;
   - séparation `confirmed`, `needs_validation`, `rejected` ;
   - validation et rapport structurés ;
   - aucune exécution de code contrôlé par la cible sans sandbox imposée par l'OS.
4. Ne présente pas des écarts génériques aux bonnes pratiques comme des vulnérabilités confirmées.
5. Ne modifie pas le code audité pendant l'audit, sauf si l'utilisateur demande séparément une correction après avoir lu les résultats.

Pour le travail d'implémentation courant, applique un raisonnement de sécurité proportionné sans charger tout le workflow d'audit.

---

## Phase 8 — Point de contrôle Git

Avant de committer :

- inspecte `git status` ;
- vérifie qu'aucun secret, fichier généré inutile, artefact de débogage ou fichier sans rapport n'est inclus ;
- vérifie que le `.gitignore` est adapté ;
- résume ce qui va être commité.

Ne committe que si c'est autorisé : `commit_after_setup: yes` dans `.loomy/brief.md`, ou accord explicite de l'utilisateur dans la conversation. Crée alors le commit initial uniquement si toutes les vérifications sont passées, avec un message concis comme :

`chore: initialize project`

Ne pousse que si le brief contient `push_after_commit: yes` ou si l'utilisateur le demande explicitement, vers le remote indiqué, sur la branche courante. Jamais de push forcé. Sans autorisation, laisse le travail prêt et résume ce que l'utilisateur doit committer ou pousser.

Si l'identité Git, la signature, la politique du dépôt ou les permissions bloquent le commit, laisse le dépôt prêt (fichiers indexés si pertinent) et décris précisément le blocage. N'invente jamais un succès.

---

## Phase 9 — Retrait de ce fichier

Après une initialisation réussie :

1. Crée `.loomy/docs/bootstrap/` si la complexité du projet justifie de garder l'historique du bootstrap.
2. Déplace ce fichier vers `.loomy/docs/bootstrap/START.completed.md`, **ou supprime-le** si l'utilisateur a choisi de ne pas garder l'historique.
3. S'il est archivé, ajoute en tête les informations de fin :
   - statut `COMPLETED` ;
   - date de fin ;
   - identifiant du commit initial s'il existe.
4. Vérifie que les fichiers permanents du projet ne dépendent plus de ce document.
5. Lance `.loomy/scripts/loomy-status.sh set done`.

Une fois terminé, ce fichier n'a **plus aucune autorité** sur le travail futur.

Font autorité, dans l'ordre :

1. l'instruction actuelle de l'utilisateur ;
2. `AGENTS.md`, `CLAUDE.md`, `.loomy/docs/AI_WORKFLOW.md` et `.loomy/docs/AI_MODEL_ROUTING.md` du projet ;
3. le code exécutable, les schémas et la configuration ;
4. les tests ;
5. `PROJECT.md`, `ARCHITECTURE.md` et les ADR en vigueur ;
6. le reste de la documentation maintenue.

---

## Discipline de tokens et de contexte

Traite le contexte comme une ressource limitée.

- Cherche avant de lire largement.
- Ne lis que les parties utiles des fichiers.
- Ne relis pas des fichiers qui n'ont pas changé.
- N'utilise des sous-agents que si leur valeur dépasse le coût de la délégation.
- Demande aux agents des constats, décisions, chemins de fichiers et risques, pas des récits verbeux.
- Ne recopie ni la demande de l'utilisateur ni la documentation du dépôt.
- Préfère le chargement progressif : ne charge les consignes spécialisées que quand la tâche en a besoin.
- Préfère un plan décisif à une liste de nombreuses alternatives faibles.
- Garde `AGENTS.md` concis ; n'en fais pas un fourre-tout.

## Directive principale

`COMPRENDRE → DÉCOUVRIR → DEMANDER → PROPOSER → VALIDER → CONSTRUIRE → VÉRIFIER → RELIRE → DOCUMENTER → COMMITTER → RETIRER LE BOOTSTRAP`

Adapte le processus au projet. Ne crée jamais de processus pour lui-même.

# Catalogue des modèles et justification du routage

Vérifié le **23/09/2026**. Le moteur de routage (`scripts/lib/models.sh`) applique les conclusions ci-dessous.
Les modèles changent toutes les quelques semaines : voir [Mettre à jour le catalogue](#mettre-à-jour-le-catalogue).

Les sources sont listées à la fin. « AA » désigne Artificial Analysis (mesures indépendantes). « Éditeur » désigne les chiffres publiés par OpenAI ou Anthropic.

## Prix et performances mesurées

| Modèle | Prix entrée / sortie ($ par million de tokens) | Lecture cache | Coût par tâche de l'indice d'intelligence AA (selon l'effort) | Indice de codage agentique AA | Terminal-Bench 4.0 | Positionnement |
|---|---|---|---|---|---|---|
| GPT-6-Luna | 0,10 / 0,50 | 0,01 | **0,07 $** (max) | 41 | 13 % | exécutant capable le moins cher |
| GPT-6-Sol | 2 / 10 | 0,20 | 0,13 $ (low) → 1,06 $ (max) | 57 (2,99 $/tâche) | 43 % | cheval de trait |
| GPT-6-Astra | 10 / 50 (fast 20 / 100) | 1,00 | 0,82 $ (low) → 3,26 $ (max) | **62** (7,09 $/tâche) | 59 % | modèle de pointe d'OpenAI, pilotage d'interfaces |
| Claude Haiku 4.5 | 1 / 5 | 0,10 | non mesuré | non mesuré | non mesuré | sous-agents Claude rapides |
| Claude Sonnet 5 | 2 / 10 | 0,20 | pas encore comparé aux GPT-6 | non mesuré | non mesuré | travail courant côté Claude |
| Claude Opus 5.5 | 4 / 20 (fast 8 / 40) | 0,20 | 0,55 $ (low) → 5,98 $ (max) ; intelligence de 42 à **58, 1ᵉʳ** | pas encore publié | **59,6 %** (éditeur : 66,4 %) | meilleur raisonnement et meilleur travail agentique |
| Claude Fable 5.1 | 10 / 50 | 0,25 | 7,63 $ (max) | 62 | 55,8 % (éditeur) | remplacé par Opus 5.5 |

## Constats qui guident le routage

1. **GPT-6-Luna (max) est le meilleur exécutant en rapport qualité/prix, mais pas un agent autonome.**
   - Force : sur DeepSWE v1.1 (éditeur), des corrections bornées dans de vrais dépôts, Luna max obtient 66,6 % pour 0,22 $ par tâche, contre 68,8 % pour 2,74 $ avec Sol max. Soit 12 fois moins cher pour 2 points de moins.
   - Faiblesse : sur le travail long et autonome en terminal (Terminal-Bench 4.0, AA), il tombe à 13 %. Son indice de codage agentique est de 41, et quand il ne sait pas, il répond faux au lieu de s'abstenir dans 77 % des cas.
   - Conséquence : Luna obtient le rôle d'**exécutant** (tickets bornés sous un orchestrateur), jamais celui d'orchestrateur.
2. **Claude Opus 5.5 est le meilleur orchestrateur.**
   - Il est 1ᵉʳ de l'indice d'intelligence AA (58 en max).
   - Il domine le travail de bureau agentique : GDPval-AA 1846 Elo, AA-Briefcase 1822 Elo.
   - Il égale Astra sur Terminal-Bench (59,6 %). En effort medium, il bat déjà Sol en max (52,5 % contre 43,9 %).
   - En effort high, il obtient 53,6 pour 1,82 $ par tâche. Astra en max obtient 53 pour 3,26 $.
3. **Opus 5.5 rend Fable 5.1 inutile.** Il fait mieux sur la plupart des benchmarks, pour environ 40 % du prix.
4. **GPT-6-Sol est le cheval de trait de Codex.**
   - Sur l'automatisation de workflows métier (AutomationBench-AA), il égale Opus 5.5 en medium, 61,6 % contre 61,2 %, pour environ 40 % du coût.
   - Réserves : il recule par rapport à GPT-5.6-Sol sur DeepSWE (72,7 % → 68,8 %) et sur GDPval (environ −100 Elo).
5. **GPT-6-Astra est le meilleur repli pour le travail approfondi en full Codex**, et il domine le pilotage d'interfaces graphiques : OSWorld 2.0 73,5 %, contre 64,4 % pour Sol.
6. **Sonnet 5 et Sol coûtent le même prix (2 $ / 10 $).** Aucune comparaison indépendante directe n'existe encore, donc chacun reste sur son propre outil.
7. **Opus 5.5 produit environ 1,6 fois plus de tokens de sortie** qu'Opus 5 en effort max. Sa baisse de prix garde le coût par tâche stable, d'où un effort plafonné à `high` pour le travail spécialisé courant.

## Matrice des rôles qui en découle (profil Équilibré)

| Rôle | Full Claude Code | Full Codex | Hybride, lead Claude | Hybride, lead Codex | Pourquoi |
|---|---|---|---|---|---|
| Orchestrateur | Opus 5.5 high | Astra high | Opus 5.5 high | Astra high | meilleur raisonnement pour planifier, déléguer et vérifier |
| Architecte | Opus 5.5 high | Astra high | Opus 5.5 high | Opus 5.5 high (bridge) | Opus domine le raisonnement et le travail de bureau |
| Débogueur | Opus 5.5 high | Sol xhigh | Opus 5.5 high | Opus 5.5 high (bridge) | Terminal-Bench : Opus 59,6 %, Sol 43 % |
| Sécurité | Opus 5.5 high | Astra high | Opus 5.5 high | Opus 5.5 high (bridge) | jugement à fort enjeu |
| Relecteur | Sonnet 5 high | Sol high | Sol high (Codex) | Sonnet 5 high (Claude) | revue croisée entre familles en hybride |
| Développeur | Sonnet 5 medium | Sol high | Sonnet 5 medium | Sol high | même prix ; reste sur l'outil principal |
| Exécutant | Sonnet 5 medium | Luna max | Luna max (Codex) | Luna max | DeepSWE 66,6 % pour 0,22 $ |
| Explorateur | Haiku 4.5 low | Luna low | Haiku 4.5 low | Luna low | recherches peu coûteuses, sur l'outil principal |
| Documentaliste | Sonnet 5 low | Sol low | Sonnet 5 low | Sol low | l'exactitude avant le prix (Luna se trompe trop souvent) |

Profils :
- `econome` baisse d'un cran l'effort de l'orchestrateur et des spécialistes.
- `qualite` le monte d'un cran (le débogueur full Codex passe sur Astra xhigh), place les revues sur le meilleur modèle et passe l'exécutant sur Sol ou Sonnet high.

Lancez `ai-route.sh --profile <profil> all` pour voir les matrices exactes.

## Limites
- **Données récentes :** les modèles sont sortis le 22/09/2026.
- **Comparaisons des éditeurs :** les graphiques de lancement d'OpenAI se comparent à Opus 5, pas à Opus 5.5.
- **Chiffres manquants :** l'indice de codage agentique AA n'est pas encore publié pour Opus 5.5 et Sonnet 5.
- **Effets de l'outillage :** les benchmarks agentiques mesurent un modèle avec son outillage, donc des scores issus d'outillages différents ne sont pas strictement comparables.
- **Abonnements :** avec les forfaits Claude ou ChatGPT, le « coût » correspond à la consommation de quota. Les rapports entre modèles restent valables.

## Mettre à jour le catalogue

Les modèles changent souvent : le catalogue se met à jour **sans nouvelle version de Loomy**. Le fichier de référence est `catalog/models.conf`, dans le dépôt ; chacun le récupère avec `loomy update --catalog`, et `loomy` (accueil) comme `loomy doctor` signalent quand un catalogue plus récent est publié.

### Format de `catalog/models.conf`

Une valeur par ligne, lue strictement (jamais exécutée) :

```
date=2026-10-15                                   # obligatoire : un catalogue n'est utilisé que s'il est plus récent
model.claude.mid=claude-sonnet-5-5, claude-sonnet-5   # chaîne : le premier modèle disponible est utilisé
model.codex.top=gpt-6-5-astra, gpt-6-astra            # les suivants servent de repli
price.claude-sonnet-5-5=2 10 0.20                 # $ par million de tokens : entrée, sortie, lecture de cache
route.claude.explorer=MID low                     # facultatif : rééquilibrer un rôle (niveau TOP|MID|FAST, effort)
```

### Chaînes de repli : tout le monde n'a pas accès aux derniers modèles

Chaque niveau (top, mid, fast) de chaque outil est une **chaîne**, du modèle le plus récent au plus ancien. Sur chaque machine, Loomy prend le premier modèle **disponible** :
- **Codex** : la liste locale des modèles de Codex (`~/.codex/models_cache.json`) fait foi ;
- **Claude** : `loomy doctor --live` teste chaque modèle des chaînes et retient le résultat (`~/.config/loomy/models.state`) ;
- **en cours de route** : quand une délégation est refusée (« modèle inexistant ou pas d'accès »), le modèle est noté indisponible et la délégation repart aussitôt sur le suivant de sa chaîne.

Un modèle noté indisponible le reste jusqu'au prochain `loomy doctor --live` (après un changement de forfait, par exemple).

### Priorités (de la plus forte à la plus faible)

1. Variable d'environnement `AI_MODEL_<CLAUDE|CODEX>_<TOP|MID|FAST>` (un essai ponctuel) ;
2. modèle épinglé sur la machine : `loomy config set model.claude.mid <modèle>` (`auto` pour revenir au catalogue) ;
3. chaîne du catalogue téléchargé, s'il est plus récent que celui livré avec Loomy ;
4. chaîne intégrée à Loomy (`scripts/lib/models.sh`).

L'effort se règle à part, par projet et par rôle : `loomy effort`.

### Protocole à la sortie d'un nouveau modèle

1. **Ajouter le modèle en tête de sa chaîne**, sans retirer l'ancien (repli pour ceux qui n'y ont pas accès) : `model.claude.mid=claude-sonnet-5-5, claude-sonnet-5`.
2. **Ajouter son prix** : `price.<modèle>=…`.
3. **Revoir la répartition** si le nouveau modèle change l'équilibre (ex. un Haiku 5 assez bon pour l'explorateur, un Sonnet 5.5 pour le relecteur) : lignes `route.…`, et ce document (tableaux, constats).
4. **Changer la date** : `date=AAAA-MM-JJ`.
5. **Vérifier** : `loomy doctor --live` (chaque modèle des chaînes répond-il ?), puis `bash tests/run.sh`.
6. **Publier** : commit et push sur `main`. Chacun le reçoit avec `loomy update --catalog` ; l'accueil le leur signale.
7. **Plus tard**, quand l'ancien modèle n'est plus proposé nulle part : le retirer de la chaîne, et reporter la nouvelle chaîne dans `scripts/lib/models.sh` (valeurs intégrées) à la version suivante de Loomy. Un test vérifie que le catalogue du dépôt et les valeurs intégrées restent cohérents.

Pour essayer un modèle sur une machine sans rien modifier : `AI_MODEL_CODEX_FAST=gpt-6-sol loomy route`.

## Sources
- [Lancement de GPT-6 Sol et Luna (VentureBeat)](https://venturebeat.com/technology/openai-releases-gpt-6-sol-and-luna-models-slashing-api-costs-50-or-more)
- [GPT-6 Sol et Luna repoussent la frontière coût/efficacité (Artificial Analysis)](https://artificialanalysis.ai/articles/gpt-6-sol-and-luna-push-the-cost-efficiency-frontier)
- [Benchmark de GPT-6 Astra (Artificial Analysis)](https://artificialanalysis.ai/articles/benchmarking-gpt-6-astra)
- [Claude Opus 5.5 prend la première place (Artificial Analysis)](https://artificialanalysis.ai/articles/claude-opus-5-5)
- [Claude Opus 5.5 par niveau d'effort (Artificial Analysis)](https://artificialanalysis.ai/models/releases/claude-opus-5-5)
- [Lancement d'Opus 5.5 par Anthropic (VentureBeat)](https://venturebeat.com/technology/anthropic-releases-claude-opus-5-5-beating-fable-5-1-on-key-agentic-benchmarks-at-60-cheaper-api-price)
- [Comparatif GPT-6 Sol et Luna (Kingy AI)](https://kingy.ai/blog/gpt-6-sol-luna-specs-benchmarks-pricing-comparison/)
- [GPT-6 Sol contre Claude Sonnet 5 (Kingy AI)](https://kingy.ai/blog/gpt-6-sol-vs-claude-sonnet-5/)
- [Coût par tâche GPT-6 Sol contre Claude Opus 5.5 (Digital Applied)](https://www.digitalapplied.com/blog/gpt-6-sol-vs-claude-opus-5-5-cost-benchmarks)
- [Tarifs de l'API Claude (Anthropic)](https://platform.claude.com/docs/en/about-claude/pricing)
- Catalogue local des modèles Codex (`~/.codex/models_cache.json`), et tests réels avec `ai-doctor.sh --live` le 23/09/2026.

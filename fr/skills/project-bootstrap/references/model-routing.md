# Routage des modèles

Objectif : le meilleur raisonnement pour l'orchestrateur (session principale), et le modèle fiable le moins cher pour chaque morceau de travail.

## Rôles
lead (orchestrateur), architect, debugger, security, reviewer, developer, executor, explorer, documenter. Voir `templates/MODEL_ROUTING.md` pour leur périmètre et leurs règles.

## Source de vérité
`scripts/lib/models.sh` contient le catalogue des modèles et les règles de routage. Utilise `scripts/loomy-route.sh` pour les lire :
- `loomy-route.sh` pour la matrice colorée ;
- `loomy-route.sh markdown` ou `all` pour les tableaux ;
- `loomy-route.sh get <rôle>` pour les scripts ;
- `loomy-route.sh claude-agents` pour générer `.claude/agents/` ;
- `loomy-route.sh codex-profiles` pour les profils Codex ;
- `loomy-route.sh lead` pour la commande de lancement de l'orchestrateur.

## Environnements
- Full Claude Code et full Codex sont les replis à un seul outil.
- En hybride :
  - l'architecte, la sécurité et le débogueur tournent sur Claude Opus ;
  - l'exécutant tourne sur Codex GPT-6-Luna en max ;
  - la revue vient de l'autre famille que l'outil principal ;
  - l'explorateur, le développeur et le documentaliste restent sur l'outil principal.

## Profils de budget
L'orchestrateur reste toujours sur le meilleur modèle. `econome` baisse les efforts, `equilibre` est le profil par défaut, et `qualite` monte les efforts et place les revues sur le meilleur modèle.

## Vérification
`scripts/loomy-doctor.sh` contrôle les versions des CLI, la disponibilité des modèles et, avec `--live`, la réponse réelle de chaque modèle routé.

## Escalade
Monter d'un cran (exécutant → développeur → orchestrateur, ou effort +1) après deux vérifications échouées ou des preuves qui contredisent le résultat. Ne jamais boucler sur un modèle bon marché.

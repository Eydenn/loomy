# Passage de relais IA

Statut : ACTIF
De : <Codex|Claude>
Vers : <Codex|Claude>
Branche/worktree : <nom/chemin>
Commit : <hash ou AUCUN>

## Objectif
<un paragraphe concis>

## Terminé
- <élément terminé>

## Fichiers modifiés
- `<chemin>` — <pourquoi>

## Vérification
- `<commande>` — OK | ÉCHEC | NON LANCÉ

## Impasses (Dead ends)
Avant le relais, consigne les approches rejetées avec preuve dans le fichier partagé `.loomy/memory/STATE.md` sous `## Dead ends`, de la plus ancienne à la plus récente :
- <approach> — <why it died> (<evidence path or ref>) · do not retry without a new reason

Garde STATE dans les 40 lignes (`loomy memory` archive les plus anciennes dans `.loomy/memory/DEAD-ENDS.md`). Le prochain lead doit consulter les deux fichiers avant de proposer une approche ; ne jamais en retenter une sans préciser la nouvelle raison.

## Problèmes et risques ouverts
- <seulement les points importants non résolus>

## Action suivante
<l'étape exacte que l'agent qui reprend doit faire>

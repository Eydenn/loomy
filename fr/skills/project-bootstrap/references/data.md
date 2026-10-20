# Données et analyse

Ne charge cette référence que pour un projet Données et analyse (`type: data` dans `.loomy/brief.md`). Applique ces règles pendant la découverte et la proposition, puis consigne-les dans les instructions permanentes du projet avant de retirer START.md.

## Une preuve pour chaque chiffre

Chaque chiffre d'un livrable provient de code exécuté et versionné : une requête ou un script et sa sortie conservée. Un modèle ne donne jamais un nombre de mémoire et ne remplace pas l'exécution par du calcul mental. Si le calcul n'a pas été exécuté, indique que le chiffre n'est pas calculé.

Les rapports, notebooks, tableaux de bord et évaluations de modèles citent le script producteur (chemin et révision), le fichier de sortie et l'instantané des données (identifiant immuable ou somme de contrôle et période). Versionne le code et conserve des sorties reproductibles ; ne committe pas de données brutes privées pour rendre un rapport reproductible. Garde les instantanés bruts inchangés et consigne la commande, les paramètres, les dépendances et les transformations nécessaires pour reproduire les résultats.

## Validation temporelle

Quand les données sont temporelles, valide sur une période réservée, séparée dans le temps, jamais avec un découpage aléatoire : le mélange laisse fuiter les informations du futur dans le passé. Consigne le champ temporel, la date de coupure et les périodes d'entraînement et de validation avant d'ajuster ou de choisir un résultat. Les périodes antérieures servent au développement ; la période réservée ultérieure reste intacte jusqu'à la validation. N'ajuste que sur les périodes antérieures et n'utilise que les informations disponibles à chaque date de prédiction.

L'agent qui propose un résultat n'est pas celui qui le valide. Utilise le routage existant (`loomy route get reviewer`) pour une revue croisée indépendante ; en SOLO, utilise un rôle/modèle différent de la même famille dans un contexte de relecture séparé. Si le relecteur routé a produit le résultat, route un autre relecteur indépendant. Le relecteur réexécute le code producteur sur l'instantané cité, vérifie les sorties conservées et la date de coupure, puis signale les écarts et les fuites. Sans validation indépendante, indique que le résultat n'est pas validé.

Pour des données non temporelles, choisis et documente un protocole de validation sur des données réservées adapté ; n'invente pas d'axe temporel.

## Les données restent locales

Les agents reçoivent des schémas, des statistiques et des échantillons anonymisés, jamais le jeu de données complet, quel que soit le volume. Les scripts locaux traitent l'intégralité des données ; leurs sorties montrées aux agents doivent aussi respecter cette limite. Garde les valeurs brutes privées hors des prompts, journaux et livrables. Avec des données sensibles, tout traitement de valeurs réelles par un modèle passe par un modèle local, ou par aucun modèle ; cela n'assouplit pas la limite sur le jeu de données complet.

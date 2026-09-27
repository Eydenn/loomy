# Intégration de la sécurité

Applique un raisonnement de sécurité proportionné pour les tâches d'ingénierie courantes.
N'utilise le workflow complet Cloudflare `security-audit` que pour une demande explicite d'audit ou de revue de vulnérabilités, ou quand l'utilisateur demande des livrables de sécurité.

Source officielle :
https://github.com/cloudflare/security-audit-skill

Installation recommandée :

```bash
npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit --global
```

Loomy fournit aussi `.loomy/scripts/install-security-audit.sh`.

Préserve ces garanties du workflow officiel :
- reconnaissance à partir du code source et cartographie des frontières de confiance ;
- registre de couverture déterministe ;
- recherche guidée par la couverture, avec des agents isolés ;
- agent de validation indépendant et neuf pour chaque constat candidat ;
- résultats séparés en `confirmed`, `needs_validation` et `rejected` ;
- validateurs et rapports structurés ;
- aucune exécution de code contrôlé par la cible si les protections de sandbox requises manquent ;
- aucun sondage des systèmes de production ou partagés par défaut ;
- aucune gravité attribuée aux éléments `needs_validation` non résolus.

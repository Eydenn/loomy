# Intégration du skill Cloudflare security-audit

Source : https://github.com/cloudflare/security-audit-skill
Licence : MIT (voir le dépôt d'origine)

Loomy n'embarque volontairement pas de copie figée du skill d'origine. Installe ou mets à jour le skill officiel à la demande, pour que les audits utilisent le workflow à jour.

## Installation globale

```bash
./.loomy/scripts/install-security-audit.sh --global
```

## Installation pour le projet ou les outils courants

```bash
./.loomy/scripts/install-security-audit.sh
```

Commande d'origine équivalente :

```bash
npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit
```

À utiliser pour les audits de sécurité explicites, les revues de vulnérabilités ou les tests d'intrusion sur le code source.

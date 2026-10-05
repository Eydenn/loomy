# Cloudflare security-audit skill integration

Source: https://github.com/cloudflare/security-audit-skill
License: MIT (see the original repository)

Loomy deliberately doesn't ship a frozen copy of the original skill. Install or update the official skill on demand, so that audits use the current workflow.

## Global install

```bash
./.loomy/scripts/loomy-install-security-audit.sh --global
```

## Install for the project or the current tools

```bash
./.loomy/scripts/loomy-install-security-audit.sh
```

Equivalent original command:

```bash
npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit
```

Use for explicit security audits, vulnerability reviews or penetration testing on source code.

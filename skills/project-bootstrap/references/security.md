# Security integration

Apply proportionate security reasoning for everyday engineering tasks.
Only use the full Cloudflare `security-audit` workflow for an explicit audit or vulnerability review request, or when the user asks for security deliverables.

Official source:
https://github.com/cloudflare/security-audit-skill

Recommended install:

```bash
npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit --global
```

Loomy also provides `.loomy/scripts/loomy-install-security-audit.sh`.

Keep these guarantees of the official workflow:
- reconnaissance from the source code and mapping of trust boundaries;
- deterministic coverage register;
- coverage-driven research, with isolated agents;
- independent, fresh validation agent for each candidate finding;
- results separated into `confirmed`, `needs_validation` and `rejected`;
- structured validators and reports;
- no execution of target-controlled code when the required sandbox protections are missing;
- no probing of production or shared systems by default;
- no severity assigned to unresolved `needs_validation` items.

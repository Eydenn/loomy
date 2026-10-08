# ADR-0002: Interface strings in English, French compiled from a dictionary

Status: Accepted (2026-09-27)

## Context
Loomy 0.4.0 (2026-09-27) added a French interface next to the English one. Its first dictionary used the French sentence as the key, with English as the translation. Release 0.4.1, the same day, reversed this ("English first"). The tool is meant for an international audience, and the code, keys, docs and commits are written in English. French stays a supported translation, picked when the system language starts with `fr` (`loomy config set lang fr|en|auto`, or `LOOMY_LANG`). Bash 3.2 has no associative arrays (ADR-0001), and screens such as `loomy watch` are redrawn every second.

## Decision
- Strings are English in the code: `t "English sentence" [printf arguments]` (`tv` writes into a variable without a subshell). The English sentence is the key.
- French lives in `scripts/lib/i18n/fr.tsv`, one `English<TAB>French` pair per line. `tools/i18n-build.sh` compiles it into `scripts/lib/i18n/fr.sh`, a `_t_fr` function made of a single `case`, which is fast in bash 3.2. The build refuses a line without a tab and a duplicated sentence.
- A sentence with no translation is shown in English rather than breaking the display. `tools/i18n-missing.sh` lists what is not translated yet; the tests check that the compiled file is up to date and that coverage is complete.
- `--help` texts, the startup brief, delegation prompts and bridge messages go through the same dictionary. The documents agents read are English, with French copies in `fr/` installed when French is detected. `README.md` and `README.fr.md` keep the same structure.

## Consequences
- Adding a string means adding a line to `fr.tsv` and rebuilding `fr.sh`; both files are committed.
- Changing an English sentence changes its key, so the translation must follow.
- A lookup is a `case` match with no process started, which keeps full-screen views responsive.
- The build step uses `python3`, a development tool and not a runtime dependency.

## Alternatives considered
- French as the key (0.4.0): rejected the same day, in favour of English first.
- Dictionary files read at runtime with `grep` or `awk`: a process per string, too slow for views redrawn every second.
- `gettext`: an external dependency, against ADR-0001.
- English only: simplest, but French users are a target audience.

# CLAUDE.md

## Git conventions

- The default branch is `main`.
- Name branches with a standard type prefix, never `claude/`:
  `feat/`, `fix/`, `docs/`, `chore/`, `refactor/`, `test/`, `ci/`, `perf/`,
  followed by a short kebab-case description (e.g. `feat/pre-push-hook`, `fix/bundle-verify`).
- Open PRs from those branches into `main`, filling in every section of
  `.github/pull_request_template.md`, including `## Antidote` (CI checks it).

## Checks before pushing

```bash
shellcheck skills/antidote/scripts/antidote tests/test_antidote.sh ci/check-antidote.sh
bash tests/test_antidote.sh
```

See CONTRIBUTING.md for the rest.

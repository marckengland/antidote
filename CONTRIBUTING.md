# Contributing

Thanks for helping make agents safer to hand the keys to.

## Layout

```
skills/antidote/SKILL.md              instructions the agent follows
skills/antidote/references/recipes.md per-platform snapshot / cure / test recipes
skills/antidote/scripts/antidote      the git helper (bash + git, no other deps)
tests/test_antidote.sh                end-to-end tests against a real local remote
.claude-plugin/                       Claude Code plugin + marketplace manifests
```

## Branches

Branch from `main` and name the branch with a type prefix: `feat/`, `fix/`,
`docs/`, `chore/`, `refactor/`, `test/`, `ci/` or `perf/`, then a short
kebab-case description (e.g. `fix/bundle-verify`).

## Before opening a PR

```bash
shellcheck skills/antidote/scripts/antidote tests/test_antidote.sh
bash tests/test_antidote.sh            # or: bash tests/test_antidote.sh test_name ...
```

- Every cure the helper prints must be covered by a test that actually runs it
  and checks the result. A cure nobody has run is not an antidote.
- Keep the script portable: bash 3.2 (macOS) and git 2.23+, no other tools
  beyond POSIX `awk`, `sort`, `wc`.
- Keep `SKILL.md` short; detail belongs in `references/`.
- Recipes must be accurate. If a command depends on a platform's current policy
  (e.g. npm's unpublish window), say so and link or name the policy.


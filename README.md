# antidote

**Every poison needs an antidote.**

An [Agent Skill](https://agentskills.io) that makes coding agents prepare,
verify and write down a way to undo a risky change *before* they make it. That
covers pushing to `main`, merging a PR, force-pushing, rewriting history,
deleting branches, running migrations, deploying, publishing a package, or
rotating secrets.

When you make a poison, you make sure the antidote is ready first. Agents move
fast and push confidently; this skill makes them stop for ten seconds and answer
*"if this goes wrong, what exactly do we run?"*, with real commit hashes and
tested commands rather than "we can always revert".

## What the agent does

1. **Assess the toxicity.** Harmless, toxic or lethal, decided by who else sees
   the change, whether one command can undo it, and whether it destroys data.
2. **Brew the antidote.** Snapshot the state to return to and generate the exact
   cure commands.
3. **Test it.** Verify the snapshot and, for lethal changes, rehearse the cure.
4. **Write it down.** An `## Antidote` section in the PR or in its message to you.
5. **Administer the poison** and watch for the symptoms it defined up front.
6. **Cure** if symptoms appear: roll forward first, rewind with
   `--force-with-lease` only when safe, and ask you before anything lethal.

See [`skills/antidote/SKILL.md`](skills/antidote/SKILL.md) for the full
instructions and [`references/recipes.md`](skills/antidote/references/recipes.md)
for databases, deploys, packages, infra, config and secrets.

## The `antidote` helper

For git operations the skill ships a small dependency-free script (bash + git):

```console
$ antidote prepare --op push --target origin/main --note "release 2.3"
# Antidote 20261002-101500-7c0437c
...
| origin/main before | `ae2ae1a…` | `refs/antidote/20261002-101500-7c0437c/target` |

## Cure

### Option A: roll forward (safe on shared branches, keeps history)
    git switch -c antidote/cure-20261002-101500-7c0437c origin/main
    git restore --source=ae2ae1a… --staged --worktree -- :/
    git commit -m "Restore main to ae2ae1a (antidote 20261002-101500-7c0437c)"
    git push origin HEAD:main

### Option B: rewind (only if nobody else has pulled origin/main since)
    git push --force-with-lease=refs/heads/main:7c0437c… origin ae2ae1a…:refs/heads/main
```

| Command | What it does |
|---|---|
| `prepare --op OP [--target R/B] [--head REV] [--note T] [--bundle] [--no-fetch]` | Ask the remote where the target is now, pin it plus HEAD and uncommitted work under `refs/antidote/<id>/`, print the cure. `OP` is `push` (default), `merge`, `force-push`, `rewrite` or `delete-branch`. |
| `verify [id]` | Check the snapshot still resolves, the bundle (if any) is valid, and whether the remote moved since. Non-zero exit if unusable. |
| `show [id]` / `list` | Print a recipe / list antidotes. |
| `drop <id>` / `prune [--keep N]` | Remove antidotes and their refs. |
| `install-hook` | Install a `pre-push` hook that blocks pushes to protected branches without a matching antidote. |

Snapshots are plain git refs, so they survive `git gc`, rebases and branch
deletion. Records live in `.git/antidote/` and are never committed or pushed.
Every cure in the recipes is exercised end-to-end by the test suite against a
real remote.

### The guardrail

```bash
antidote install-hook
git config --add antidote.protect 'hotfix/*'   # optional; defaults: main master trunk develop release/* production prod
```

A push or deletion on a protected branch is refused unless an antidote was
prepared for exactly that push: same branch, same "before" commit on the
remote, same commit being pushed. Prepare again after new commits. Skip once
with `ANTIDOTE_SKIP=1 git push ...`.

## Install

**Claude Code (plugin):**

```text
/plugin marketplace add marckengland/antidote
/plugin install antidote@antidote
```

**Claude Code (plain skill):** copy `skills/antidote` into `~/.claude/skills/`
(all projects) or `.claude/skills/` (one project):

```bash
git clone https://github.com/marckengland/antidote
cp -r antidote/skills/antidote ~/.claude/skills/
```

**Other agents:** any agent that supports the Agent Skills format (a folder with
a `SKILL.md`) can load `skills/antidote` the same way. Agents without skill
support can be pointed at `SKILL.md` from their instructions file (`AGENTS.md`,
`.cursor/rules`, etc.).

**Just the CLI:** put `skills/antidote/scripts/antidote` on your `PATH`.

Requires bash and git 2.23 or newer.

## Contributing

Issues and PRs welcome, especially new recipes for platforms you know well. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)

#!/usr/bin/env bash
# End-to-end tests for skills/antidote/scripts/antidote.
# Each test runs in a fresh temp dir with a bare "remote" and a clone, and
# actually executes the cure commands from the recipe to prove they work.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ANTIDOTE="$ROOT/skills/antidote/scripts/antidote"
PASS=0
FAIL=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1 HOME=/nonexistent-antidote-home

setup() {
  WORK=$(mktemp -d)
  git init --quiet --bare --initial-branch=main "$WORK/remote.git"
  git clone --quiet "$WORK/remote.git" "$WORK/repo" 2>/dev/null
  cd "$WORK/repo"
  git checkout --quiet -b main 2>/dev/null || true
  echo one > a.txt
  git add a.txt
  git commit --quiet -m one
  git push --quiet -u origin main 2>/dev/null
}

teardown() { cd /; rm -rf "$WORK"; }

# `! cmd` never trips set -e, so assert failures explicitly.
refute() {
  if "$@"; then echo "expected to fail: $*" >&2; return 1; fi
}

remote_main() { git ls-remote origin refs/heads/main | cut -f1; }

# Pull the indented command lines out of a "### <heading>" section of a recipe.
section_cmds() {
  awk -v h="$2" '
    /^#/ { on = (/^### / && index($0, h) > 0); next }
    on && /^    / { sub(/^    /, ""); print }
  ' "$1"
}

run() {
  local name=$1
  setup
  # Not inside `if`: bash ignores set -e in a condition context.
  set +e
  ( set -ex; "$name" ) > "$WORK/log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name"; sed 's/^/     /' "$WORK/log"
  fi
  teardown
}

# ---------------------------------------------------------------------------

test_push_rollforward_restores_tree() {
  local before; before=$(remote_main)
  echo bad > a.txt; echo new > b.txt; git add -A; git commit --quiet -m bad
  "$ANTIDOTE" prepare --op push > recipe.md 2>/dev/null
  git push --quiet origin main 2>/dev/null
  section_cmds recipe.md "Option A" | grep -v '^git log' > cure.sh
  grep -q "git restore --source=$before" cure.sh
  bash -e cure.sh >/dev/null 2>&1
  git fetch --quiet origin
  [ "$(git rev-parse "origin/main^{tree}")" = "$(git rev-parse "$before^{tree}")" ]
  [ ! -e b.txt ]   # files added by the bad push are gone too
}

test_push_rewind_uses_lease() {
  local before; before=$(remote_main)
  echo bad > a.txt; git commit --quiet -am bad
  "$ANTIDOTE" prepare --op push > recipe.md 2>/dev/null
  git push --quiet origin main 2>/dev/null
  bash -e <(section_cmds recipe.md "Option B") 2>/dev/null
  [ "$(remote_main)" = "$before" ]
}

test_rewind_refuses_if_someone_pushed_on_top() {
  echo bad > a.txt; git commit --quiet -am bad
  "$ANTIDOTE" prepare --op push > recipe.md 2>/dev/null
  git push --quiet origin main 2>/dev/null
  git clone --quiet "$WORK/remote.git" "$WORK/other" 2>/dev/null
  (cd "$WORK/other" && echo theirs > c.txt && git add c.txt && git commit --quiet -m theirs && git push --quiet origin main 2>/dev/null)
  git fetch --quiet origin
  local tip; tip=$(remote_main)
  refute bash -e <(section_cmds recipe.md "Option B") 2>/dev/null
  [ "$(remote_main)" = "$tip" ]
}

test_force_push_restore() {
  echo two > a.txt; git commit --quiet -am two; git push --quiet origin main 2>/dev/null
  local before; before=$(remote_main)
  git reset --quiet --hard HEAD~1
  echo rewritten > a.txt; git commit --quiet -am rewritten
  "$ANTIDOTE" prepare --op force-push > recipe.md 2>/dev/null
  git push --quiet --force origin main 2>/dev/null
  section_cmds recipe.md "force-push lost work" | grep -v '^git log' > cure.sh
  bash -e cure.sh 2>/dev/null
  [ "$(remote_main)" = "$before" ]
}

test_rewrite_reset_restore() {
  echo two > a.txt; git commit --quiet -am two
  local before; before=$(git rev-parse HEAD)
  "$ANTIDOTE" prepare --op rewrite --no-fetch > recipe.md 2>/dev/null
  git reset --quiet --hard HEAD~1
  git reflog expire --expire=now --all && git gc --quiet --prune=now
  # The antidote ref must have kept the commit alive through gc.
  git cat-file -e "$before^{commit}"
  section_cmds recipe.md "rewrite" | grep '^git reset' > cure.sh
  bash -e cure.sh >/dev/null
  [ "$(git rev-parse HEAD)" = "$before" ]
}

test_delete_branch_restore() {
  git push --quiet origin main:feature 2>/dev/null
  local before; before=$(git ls-remote origin refs/heads/feature | cut -f1)
  "$ANTIDOTE" prepare --op delete-branch --target origin/feature > recipe.md 2>/dev/null
  git push --quiet origin --delete feature 2>/dev/null
  section_cmds recipe.md "Restore the deleted branch" | head -n 1 > cure.sh
  bash -e cure.sh 2>/dev/null
  [ "$(git ls-remote origin refs/heads/feature | cut -f1)" = "$before" ]
}

test_new_branch_cure_deletes_it() {
  git switch --quiet -c feature
  echo f > f.txt; git add f.txt; git commit --quiet -m f
  "$ANTIDOTE" prepare --op push --target origin/feature > recipe.md 2>/dev/null
  grep -q 'branch did not exist' recipe.md
  git push --quiet origin feature 2>/dev/null
  bash -e <(section_cmds recipe.md "should not exist") 2>/dev/null
  [ -z "$(git ls-remote origin refs/heads/feature)" ]
}

test_merge_requires_target() {
  refute "$ANTIDOTE" prepare --op merge 2>/dev/null
  "$ANTIDOTE" prepare --op merge --target origin/main > recipe.md 2>/dev/null
  grep -q 'git revert -m 1' recipe.md
}

test_uncommitted_changes_snapshot() {
  echo wip > a.txt
  "$ANTIDOTE" prepare --op rewrite --no-fetch > recipe.md 2>/dev/null
  git reset --quiet --hard
  [ "$(cat a.txt)" = one ]
  bash -e <(section_cmds recipe.md "uncommitted") >/dev/null
  [ "$(cat a.txt)" = wip ]
}

test_verify_ok_and_detects_damage() {
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  "$ANTIDOTE" verify | grep 'is ready' >/dev/null
  local id; id=$("$ANTIDOTE" list 2>/dev/null | awk 'NR==2 {print $1}')
  git update-ref -d "refs/antidote/$id/head"
  refute "$ANTIDOTE" verify "$id" >/dev/null
}

test_verify_warns_when_remote_moved() {
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  git clone --quiet "$WORK/remote.git" "$WORK/other" 2>/dev/null
  (cd "$WORK/other" && echo x > x.txt && git add x.txt && git commit --quiet -m x && git push --quiet origin main 2>/dev/null)
  "$ANTIDOTE" verify | grep '^WARN .*moved since' >/dev/null
}

test_bundle() {
  "$ANTIDOTE" prepare --op push --bundle > /dev/null 2>&1
  "$ANTIDOTE" verify --no-fetch | grep "^OK    bundle" >/dev/null
}

test_offline_falls_back_to_cached_ref() {
  git remote set-url origin "$WORK/does-not-exist.git"
  "$ANTIDOTE" prepare --op push > recipe.md 2>err.txt
  grep -q 'could not reach' err.txt
  grep -q 'may be stale' recipe.md
  grep -q "$(git rev-parse origin/main)" recipe.md
}

test_guard_blocks_then_allows() {
  "$ANTIDOTE" install-hook 2>/dev/null
  echo two > a.txt; git commit --quiet -am two
  refute git push --quiet origin main 2>err.txt
  grep -q 'blocked push to protected branch main' err.txt
  "$ANTIDOTE" prepare --op push > /dev/null 2>&1
  git push --quiet origin main 2>/dev/null
  # A later commit is not covered by the old antidote.
  echo three > a.txt; git commit --quiet -am three
  refute git push --quiet origin main 2>/dev/null
  ANTIDOTE_SKIP=1 git push --quiet origin main 2>/dev/null
}

test_guard_ignores_unprotected_and_honours_config() {
  "$ANTIDOTE" install-hook 2>/dev/null
  git switch --quiet -c feature
  echo f > f.txt; git add f.txt; git commit --quiet -m f
  git push --quiet origin feature 2>/dev/null
  git config --add antidote.protect 'feat*'
  echo g > f.txt; git commit --quiet -am g
  refute git push --quiet origin feature 2>/dev/null
}

test_guard_covers_branch_deletion() {
  "$ANTIDOTE" install-hook 2>/dev/null
  git push --quiet origin main:release/1.0 2>/dev/null || ANTIDOTE_SKIP=1 git push --quiet origin main:release/1.0 2>/dev/null
  refute git push --quiet origin --delete release/1.0 2>/dev/null
  "$ANTIDOTE" prepare --op delete-branch --target origin/release/1.0 > /dev/null 2>&1
  git push --quiet origin --delete release/1.0 2>/dev/null
}

test_install_hook_does_not_clobber() {
  mkdir -p .git/hooks; printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-push
  refute "$ANTIDOTE" install-hook 2>/dev/null
  "$ANTIDOTE" install-hook --force 2>/dev/null
  grep -q 'antidote' .git/hooks/pre-push
}

test_prune_and_drop() {
  local i
  for i in 1 2 3; do "$ANTIDOTE" prepare --op push --no-fetch --note "n$i" > /dev/null 2>&1; done
  [ "$("$ANTIDOTE" list 2>/dev/null | tail -n +2 | wc -l)" -eq 3 ]
  "$ANTIDOTE" prune --keep 1 2>/dev/null
  [ "$("$ANTIDOTE" list 2>/dev/null | tail -n +2 | wc -l)" -eq 1 ]
  "$ANTIDOTE" list 2>/dev/null | grep n3 >/dev/null
  local id; id=$("$ANTIDOTE" list 2>/dev/null | awk 'NR==2 {print $1}')
  "$ANTIDOTE" drop "$id" 2>/dev/null
  [ -z "$(git for-each-ref refs/antidote/)" ]
}

test_works_from_linked_worktree() {
  git worktree add --quiet "$WORK/wt" -b side 2>/dev/null
  (cd "$WORK/wt" && "$ANTIDOTE" prepare --op rewrite --no-fetch > /dev/null 2>&1)
  "$ANTIDOTE" list 2>/dev/null | grep rewrite >/dev/null
}

test_refuses_outside_repo_and_empty_repo() {
  refute git -C "$WORK" status >/dev/null 2>&1   # sanity: $WORK is not a repo
  (cd "$WORK" && refute "$ANTIDOTE" prepare 2>/dev/null)
  git init --quiet "$WORK/empty"
  (cd "$WORK/empty" && refute "$ANTIDOTE" prepare 2>/dev/null)
}

# ---------------------------------------------------------------------------

tests=$(declare -F | awk '{print $3}' | grep '^test_')
if [ $# -gt 0 ]; then tests="$*"; fi
for t in $tests; do run "$t"; done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# Fail a pull request whose description has no filled-in "## Antidote" section.
# Used by the composite action in action.yml; everything comes in through env:
#
#   PR_BODY        pull request description
#   PR_BASE        base branch name (empty outside pull_request events)
#   PR_LABELS      JSON array of label names
#   BASE_BRANCHES  space-separated globs of base branches that need an antidote
#   SKIP_LABEL     label that waives the check
#   MIN_LENGTH     minimum non-whitespace characters in the section
set -euo pipefail

say()   { printf '%s\n' "$*"; }
fail()  { say "::error title=Antidote missing::$*"; summary "❌ $*"; exit 1; }
pass()  { say "$*"; summary "✅ $*"; exit 0; }
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '### Antidote check\n\n%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

base=${PR_BASE:-}
[ -n "$base" ] || pass "Not a pull request; nothing to check."

matched=0
set -f
for p in ${BASE_BRANCHES:-main master}; do
  # shellcheck disable=SC2254 # $p is a glob pattern on purpose
  case $base in $p) matched=1 ;; esac
done
set +f
[ "$matched" = 1 ] || pass "Base branch '$base' does not require an antidote."

skip=${SKIP_LABEL:-}
if [ -n "$skip" ] && printf '%s' "${PR_LABELS:-[]}" | grep -F "\"$skip\"" >/dev/null; then
  pass "Label '$skip' is set; antidote waived."
fi

# The section runs from an "Antidote" heading to the next heading of the same
# or a higher level. HTML comments and bare "**Label:**" lines (an unfilled
# template) do not count.
section=$(printf '%s\n' "${PR_BODY:-}" | tr -d '\r' | awk '
  /<!--/ { incomment = 1 }
  incomment { if (/-->/) incomment = 0; next }
  !on && /^#+[ \t]+[Aa]ntidote([ \t:].*)?$/ { on = 1; match($0, /^#+/); level = RLENGTH; next }
  on && /^#+[ \t]/ { match($0, /^#+/); if (RLENGTH <= level) exit }
  on && /^[ \t]*\*\*[^*]+:\*\*[ \t]*$/ { next }
  on { print }
')

heading=$(printf '%s\n' "${PR_BODY:-}" | grep -E '^#+[[:space:]]+[Aa]ntidote([[:space:]:].*)?$' || true)
[ -n "$heading" ] || fail "PRs into '$base' need an '## Antidote' section in the description: the risk, the state before, the exact cure, and how it was tested. For a harmless change, say why in one line. Waive with the '$skip' label."

chars=$(printf '%s' "$section" | tr -d '[:space:]' | wc -c | tr -d ' ')
min=${MIN_LENGTH:-20}
[ "$chars" -ge "$min" ] || fail "The '## Antidote' section is empty or still the template ($chars of at least $min characters filled in). Fill in the risk, the state before, the cure and how it was tested."

pass "Antidote section present ($chars characters)."

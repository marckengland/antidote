#!/usr/bin/env python3
"""Claude Code PreToolUse hook: every poison needs an antidote.

Looks at Bash commands and PR-merge tool calls before they run:

* ``git push ...``: asks git itself what the push would change by running the
  same push with ``--dry-run`` and the antidote pre-push guard. If a protected
  branch would change without a matching antidote, the call is denied and the
  agent is told how to prepare one. Nothing is pushed.
* ``git push --no-verify``, ``ANTIDOTE_SKIP=1 git push``, ``git -c core.hooksPath=...
  push``: these bypass the guard, so the user is asked to approve.
* ``gh pr merge`` and MCP ``merge_pull_request`` tools: denied unless
  ``antidote covers --op merge`` finds a fresh merge antidote for the PR's base.

Anything it cannot understand is allowed: the git pre-push hook
(``antidote install-hook``) is the backstop. Disable per repository with
``git config antidote.enabled false``, or everywhere with ANTIDOTE_HOOK=off.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ANTIDOTE = os.environ.get("ANTIDOTE_BIN") or os.path.normpath(
    os.path.join(HERE, "..", "skills", "antidote", "scripts", "antidote")
)
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OPERATORS = set(";&|()")
# gh pr merge flags that take a value (so their value is not the PR selector).
GH_VALUE_FLAGS = {
    "-t", "--subject", "-b", "--body", "-F", "--body-file", "-A",
    "--author-email", "--match-head-commit", "-R", "--repo",
}
# git global options that take a separate value.
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def decide(decision, reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def run(cmd, cwd, env=None, timeout=60):
    try:
        return subprocess.run(
            cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def enabled(cwd):
    if os.environ.get("ANTIDOTE_HOOK", "").lower() in ("off", "0", "false"):
        return False
    r = run(["git", "config", "--bool", "antidote.enabled"], cwd)
    return not (r and r.stdout.strip() == "false")


def segments(command):
    """Split a shell command into simple commands (lists of words)."""
    lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    seg = []
    for tok in lex:
        if tok and set(tok) <= OPERATORS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def check_push(git_opts, args, env_prefix, cwd):
    bypass = (
        "--no-verify" in args
        or env_prefix.get("ANTIDOTE_SKIP") == "1"
        or any(o.startswith("core.hooksPath") for o in git_opts)
    )
    if bypass:
        decide("ask", "This git push skips the antidote pre-push guard. Allow it only if "
                      "you have approved pushing without an antidote.")

    push_args = [a for a in args if a not in ("-u", "--set-upstream", "--dry-run", "-n")]
    with tempfile.TemporaryDirectory() as hooks:
        hook = os.path.join(hooks, "pre-push")
        with open(hook, "w") as f:
            f.write("#!/bin/sh\nexec %s guard \"$@\"\n" % shlex.quote(ANTIDOTE))
        os.chmod(hook, 0o755)
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", **env_prefix)
        env.pop("ANTIDOTE_SKIP", None)
        r = run(["git", *git_opts, "-c", "core.hooksPath=" + hooks,
                 "push", "--dry-run", *push_args], cwd, env=env)
    if r is None or "blocked push to protected branch" not in r.stderr:
        return  # allowed, or git failed for some other reason the real push will report
    lines = r.stderr.splitlines()
    start = next(i for i, l in enumerate(lines) if "blocked push" in l)
    decide("deny", "\n".join(l for l in lines[start:] if not l.startswith("error:")))


def pr_base(selector, repo, cwd):
    cmd = ["gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName"]
    if selector:
        cmd.insert(3, selector)
    if repo:
        cmd += ["-R", repo]
    r = run(cmd, cwd, timeout=30)
    return r.stdout.strip() if r and r.returncode == 0 else ""


def check_merge(selector, repo, cwd):
    base = pr_base(selector, repo, cwd)
    r = run([ANTIDOTE, "covers", "--op", "merge"] + (["--branch", base] if base else []), cwd)
    if r is None or r.returncode == 0:
        return
    target = "origin/" + (base or "<base-branch>")
    decide("deny",
           "No antidote for this PR merge. %s\nPrepare one, put it in the PR description, "
           "then merge again:\n  %s prepare --op merge --target %s --note \"merge PR %s\""
           % (r.stderr.strip(), ANTIDOTE, target, selector or ""))


def check_bash(command, cwd):
    try:
        segs = list(segments(command))
    except ValueError:
        return  # unbalanced quotes etc.: let the shell complain
    for words in segs:
        env_prefix = {}
        while words and (words[0] == "env" or ASSIGNMENT.match(words[0])):
            if words[0] != "env":
                k, v = words[0].split("=", 1)
                env_prefix[k] = v
            words = words[1:]
        if not words:
            continue
        prog = os.path.basename(words[0])
        if prog == "cd" and len(words) > 1:
            cwd = os.path.join(cwd, os.path.expanduser(words[1]))
        elif prog == "git":
            opts, i = [], 1
            while i < len(words) and words[i].startswith("-"):
                if words[i] in GIT_VALUE_OPTS and i + 1 < len(words):
                    opts += words[i:i + 2]
                    i += 2
                else:
                    opts.append(words[i])
                    i += 1
            if i < len(words) and words[i] == "push" and enabled(cwd):
                check_push(opts, words[i + 1:], env_prefix, cwd)
        elif prog == "gh" and words[1:3] == ["pr", "merge"] and enabled(cwd):
            selector, repo, rest = "", "", words[3:]
            j = 0
            while j < len(rest):
                if rest[j] in GH_VALUE_FLAGS:
                    if rest[j] in ("-R", "--repo") and j + 1 < len(rest):
                        repo = rest[j + 1]
                    j += 2
                    continue
                if rest[j].startswith("--repo="):
                    repo = rest[j].split("=", 1)[1]
                elif not rest[j].startswith("-") and not selector:
                    selector = rest[j]
                j += 1
            check_merge(selector, repo, cwd)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    cwd = data.get("cwd") or os.getcwd()
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    if tool == "Bash":
        check_bash(tool_input.get("command", ""), cwd)
    elif tool.endswith("merge_pull_request") and enabled(cwd):
        owner, repo = tool_input.get("owner"), tool_input.get("repo")
        number = tool_input.get("pullNumber") or tool_input.get("pull_number")
        check_merge(str(number or ""), "%s/%s" % (owner, repo) if owner and repo else "", cwd)


if __name__ == "__main__":
    main()

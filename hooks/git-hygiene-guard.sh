#!/bin/bash
# git-hygiene-guard.sh — PreToolUse hook (Bash matcher).
# Enforces the git hygiene playbook (~/.claude/docs/git-hygiene-playbook.md):
# main is merge-only. Blocks `git commit` when the target repo is on main/master,
# EXCEPT when a squash-merge/merge is in progress (landing) or the repo has no
# commits yet (bootstrapping a new repo).

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Neutralize quoted string arguments before deciding whether a git-commit is
# being INVOKED. A `git commit` inside quotes is data, not a command — e.g. a
# task brief dispatched to a worker via `herdr pane run <pane> "...git commit..."`,
# or an echoed/heredoc string. Replace each quoted run with a placeholder token
# so an unquoted `git ... commit` (incl. `git -C <path> commit`) still matches,
# while quoted occurrences do not. Target extraction below still uses the raw
# $cmd so real `-C <path>` / `cd <dir>` targets are read correctly.
scan=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"/Q/g')
scan=$(printf '%s' "$scan" | sed -E "s/'[^']*'/Q/g")

# Only inspect commands that actually invoke `git ... commit`.
if ! printf '%s' "$scan" | grep -Eq '(^|[;&|[:space:]()])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$)'; then
  exit 0
fi

# Directory git will run in: session cwd, overridden by a leading `cd <dir> &&`
# or an explicit `git -C <dir>`.
dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
cd_target=$(printf '%s' "$cmd" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:];&|]+))[[:space:]]*(&&|;).*/\2\3\4/p")
[ -n "$cd_target" ] && dir=$cd_target
c_target=$(printf '%s' "$cmd" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+))[[:space:]].*commit.*/\2\3\4/p")
[ -n "$c_target" ] && dir=$c_target
case $dir in "~"*) dir="$HOME${dir#\~}" ;; esac

git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

branch=$(git -C "$dir" symbolic-ref --short -q HEAD)
gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)

if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
  # Branch commits are fine in linked worktrees; in the PRIMARY checkout they
  # mean someone did `checkout -b` there instead of creating a worktree.
  if [ -n "$branch" ] && [ "$gitdir" = "$common" ] && git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Git hygiene playbook: branch work does not happen in the primary checkout (git checkout -b there is not the worktree flow). Switch the primary checkout back to main, create a worktree workspace (herdr worktree create --cwd <repo> --branch <name> --no-focus --json), and do the work there. Playbook: ~/.claude/docs/git-hygiene-playbook.md"}}
JSON
    exit 0
  fi
  exit 0
fi
# Landing: `git merge --squash` writes SQUASH_MSG. Deliberately NOT excepting
# MERGE_HEAD/MERGE_MSG — a plain merge commit on main is not the squash-only flow.
if [ -f "$gitdir/SQUASH_MSG" ]; then
  exit 0
fi
# Bootstrapping: repo with no commits yet.
git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1 || exit 0

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Git hygiene playbook: main is merge-only — direct commits on main are blocked. Create a worktree first (herdr worktree create --cwd <repo> --branch feat/<slug>), commit there, then land with `git merge --squash <branch>` + `git commit` (squash-merge commits ARE allowed by this hook). Playbook: ~/.claude/docs/git-hygiene-playbook.md"}}
JSON
exit 0

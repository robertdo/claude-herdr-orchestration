#!/bin/bash
# git-hygiene-guard.sh — PreToolUse hook (Bash matcher).
#
# BEST-EFFORT LINTER, NOT ENFORCEMENT. This hook pattern-matches the literal
# `Bash` tool command string and denies `git commit` when the target repo is
# on main/master (except an empty repo's first commit). That catches the
# common ACCIDENTAL slip — a plain `git commit` on main — before it runs,
# with a message pointing at the sanctioned path (bin/land.sh).
#
# It is not, and must not be read as, an enforcement boundary: the input is
# Turing-complete shell, so "does this string eventually move
# refs/heads/main" is undecidable in general. Interpreter indirection
# (`sh -c "..."`), quoting (`"git" commit`, `\git commit`), non-`commit`
# porcelain and plumbing that also move the branch (`merge`, `pull`,
# `cherry-pick`, `commit-tree` + `update-ref`, `branch -f`), a non-leading
# `cd`, `GIT_DIR=` retargeting, and detached HEAD all defeat it — verified,
# not hypothetical. Do not add cases chasing that list; each one raises
# false-positive risk without making the predicate decidable. For structural,
# spelling- and tool-immune enforcement, see the git-level hook at
# hooks/git-repo/reference-transaction (opt-in per repo — install-repo.sh).

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
#
# sed applies each `s///` per LINE, so a quoted argument that itself spans
# multiple lines (a multi-line -m message, for instance) never got replaced
# by a plain `sed 's/"[^"]*"/.../'` pass: the opening quote's line has no
# closing quote on it, and vice versa, so the text between them — which can
# contain the literal words "git commit" — survived unmasked and could trip
# the grep below on prose that never invokes git at all. Fold real newlines
# into a placeholder byte first so the whole command is one sed "line" (and
# unfold after), rather than trying to make sed itself multi-line-aware: the
# textbook `N;$!ba` slurp idiom is a trap here — on BSD/macOS sed, `N` at
# end-of-input with nothing left to append drops pattern space instead of
# auto-printing it (GNU sed prints either way), so that idiom silently empties
# the *common* single-line case instead of the multi-line one it was meant to
# fix.
scan=$(printf '%s' "$cmd" | tr '\n' '\001' | sed -E 's/"[^"]*"/Q/g' | tr '\001' '\n')
scan=$(printf '%s' "$scan" | tr '\n' '\001' | sed -E "s/'[^']*'/Q/g" | tr '\001' '\n')

# Only inspect commands that actually invoke `git ... commit`. The optional
# `-c key=value` alternative handles that flag specifically (it takes its
# value as a separate token, unlike other single-token flags) since agents
# pass it routinely (e.g. `-c user.email=...`) and it would otherwise slip
# past the generic flag-token pattern below.
if ! printf '%s' "$scan" | grep -Eq '(^|[;&|[:space:]()])git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?((-c[[:space:]]+[^[:space:]]+|-[^[:space:]]+)[[:space:]]+)*commit([[:space:]]|$)'; then
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
# Bootstrapping: repo with no commits yet.
git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1 || exit 0

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Git hygiene playbook: main is merge-only — direct commits on main are blocked, with no exception for a manual `git merge --squash` + `git commit` (this hook cannot tell that apart from an accidental direct commit, and the blessed path no longer produces one). Create a worktree first (herdr worktree create --cwd <repo> --branch feat/<slug>), commit there, then land with bin/land.sh <branch>. Playbook: ~/.claude/docs/git-hygiene-playbook.md"}}
JSON
exit 0

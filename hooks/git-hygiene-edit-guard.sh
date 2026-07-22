#!/bin/bash
# git-hygiene-edit-guard.sh — PreToolUse hook (Edit|Write|NotebookEdit).
# Enforces the git hygiene playbook: the PRIMARY checkout of a repo is never
# edited (work happens in linked worktrees), and a session whose cwd is one
# checkout does not edit files in a different checkout of the same repo
# (orchestrators dispatch workers; they don't implement).
# Exempt: files outside any git repo, files under ~/.claude (tooling), and
# repos with no commits yet (bootstrapping).

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -z "$f" ] && exit 0
case $f in "$HOME/.claude/"*) exit 0 ;; esac

d=$(dirname "$f")
while [ ! -d "$d" ] && [ "$d" != "/" ]; do d=$(dirname "$d"); done
git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git -C "$d" rev-parse -q --verify HEAD >/dev/null 2>&1 || exit 0

gitdir=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

if [ "$gitdir" = "$common" ]; then
  # Primary checkout: never edited, on any branch.
  deny "Git hygiene playbook: the primary checkout is never edited directly — not even on a branch. Create a worktree workspace (herdr worktree create --cwd <repo> --branch <type>/<slug> --no-focus --json) and dispatch a worker Claude inside it per the orchestrator model. Playbook: ~/.claude/docs/git-hygiene-playbook.md"
fi

# Linked worktree: allow only if the session's cwd is inside this same worktree.
tl=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
case $cwd in "$tl"|"$tl"/*) exit 0 ;; esac
# cwd elsewhere — meddling only if cwd belongs to the same repo family.
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cwd_common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ "$cwd_common" = "$common" ]; then
    deny "Git hygiene playbook: you are the ORCHESTRATOR (your cwd is a different checkout of this repo) — do not edit worktree files yourself. Dispatch a worker Claude in that worktree workspace (herdr pane run <pane> claude, then submit the task) and supervise via ~/.claude/bin/herdr-watch-agent.sh. Playbook: ~/.claude/docs/git-hygiene-playbook.md"
  fi
fi
exit 0

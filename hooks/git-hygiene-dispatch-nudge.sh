#!/bin/bash
# git-hygiene-dispatch-nudge.sh — UserPromptSubmit hook.
# When the session's cwd is the PRIMARY checkout of a git repo (the ORCHESTRATOR,
# not a worker in a linked worktree) and the prompt reads as feature / design /
# implementation intent, inject a reminder to DISPATCH the work to a worktree
# worker instead of brainstorming / speccing / planning / implementing inline on
# main (playbook: "Orchestrator = scoping only" / "Worker = the entire lifecycle").
#
# A NUDGE, not a block: it only adds context, and the note itself says to ignore
# it for questions / reads / non-feature chat. Primary-checkout detection mirrors
# git-hygiene-edit-guard.sh (absolute-git-dir == git-common-dir). Exits silently
# in linked worktrees (design work there is correct), non-git dirs, and repos
# with no commits.

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
[ -z "$prompt" ] && exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -z "$cwd" ] && exit 0

# Retrospective / explanatory questions are not work requests.
printf '%s' "$prompt" | grep -Eiq '^[[:space:]]*(why[[:space:]]|how come|explain|what[[:space:]]+(happened|caused|went[[:space:]]+wrong|broke))' && exit 0

# Only in a git repo, and only the PRIMARY checkout (orchestrator). A linked
# worktree has gitdir != common — that's a worker, where design work belongs.
git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git -C "$cwd" rev-parse -q --verify HEAD >/dev/null 2>&1 || exit 0
gitdir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ "$gitdir" = "$common" ] || exit 0

# Feature / design / implementation intent?
printf '%s' "$prompt" | grep -Eiq 'brainstorm|(^|[^a-z])(implement|architect|scaffold|prototype|refactor|incorporate)|let.?s[[:space:]]+(build|design|add|create|write|make|work|figure|spec|plan|do|prototype|scaffold|refactor|implement|incorporate|redesign)|how[[:space:]].*(implement|build|design|architect|incorporate|approach|structure|handle)|add[[:space:]]+(support[[:space:]]+for|a[[:space:]]+(new[[:space:]]+)?(feature|mode|endpoint|component|page|screen|command|rule|option)|an[[:space:]])|(design|build|create|redesign)[[:space:]]+([a-z]+[[:space:]]+){0,4}(feature|component|endpoint|page|screen|system|module|flow|mode|command|rule|handler|service|integration|game|ui|api|dashboard|form|scene|physics|loader|menu|level|animation)' || exit 0

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[git-hygiene] cwd is a repo's PRIMARY checkout, so you are the ORCHESTRATOR and this prompt reads as feature/design/implementation work. Per ~/.claude/docs/git-hygiene-playbook.md: first SCOPE — ask the user whatever clarifying questions you need to pin down the goal, constraints, and blast radius, then use the answers to size the worker (model + effort) and write a complete, self-contained brief. Asking is expected, not a delay — a well-scoped brief is what makes dispatch smart. Clarify only enough to dispatch well; don't design it yourself — the design happens in the worker's pane. Then DISPATCH — create a worktree (herdr worktree create --cwd <repo> --branch <type>/<slug> --no-focus --json) and launch a worker that runs brainstorming/design/spec/plan/implementation in its own pane, which you converse with via herdr pane run. Do NOT brainstorm, spec, plan, or implement inline in the main checkout. If this is only a question, a read, a config/tooling tweak, or non-feature chat, ignore this note."}}
JSON
exit 0

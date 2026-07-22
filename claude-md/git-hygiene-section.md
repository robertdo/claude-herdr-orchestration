<!--
Paste this whole section into your ~/.claude/CLAUDE.md (global) or a project CLAUDE.md.
It is the "soft" layer: the doctrine the model reads every session. The hooks are the
"hard" layer that enforces it. install.sh appends this for you (marker-guarded) — you
only need to do this by hand if you install manually.

`~/src` below is just where the author keeps repos; nothing hardcodes it. Adjust the
heading to wherever your repos live.
-->

# Git hygiene (all repos under ~/src)

Full playbook: `~/.claude/docs/git-hygiene-playbook.md`. The rules, uniform for every repo
with a branch literally named `main` or `master` (a differently named default branch is
unguarded):

1. **Always worktree.** Every change — feature, fix, typo — happens on a branch in a herdr
   worktree, never in the main checkout. Hooks catch the common slips: file edits in the
   primary checkout on any branch, direct commits on main, and branch commits in the primary
   checkout. Absolute, no exceptions (a fresh repo's first commit is the one thing the hooks
   allow inline). When a hook denies you, create a worktree and route per rule 2 below.
2. **Route who implements on discovery and volume, not importance.** The worktree is
   non-negotiable; who works inside it is not. Pick the cheapest tier that fits:
   - **Tier 1 — self-edit.** You already know the exact change: worktree, edit, commit, land.
   - **Tier 2 — worktree-isolated subagent.** Needs discovery/volume, modest blast radius:
     Agent tool with `isolation: "worktree"`. Unvalidated without a git remote — see playbook.
   - **Tier 3 — dispatch a herdr pane worker.** Real blast radius, long horizon, or parallel
     work: you're the ORCHESTRATOR — scope, dispatch, supervise without blocking, land. Never
     implement yourself, even at the worktree's path. Mechanics, sizing, and the dispatch
     gotchas are in the playbook.
3. **Land via `bin/land.sh <branch>`.** Rebases onto main automatically, verifies, builds the
   landing commit as an object, prints the diff, fast-forwards main, cleans up.
4. **Cleanup is automatic on landing.** Abandoning instead: `herdr worktree remove --workspace
   <id> --force` then `git branch -D <branch>`.
5. **Deploy is separate.** Merging makes main deployable; never auto-deploy after a merge.
6. Non-git directories are exempt.

**Enforcement is layered and none of it is a security boundary** — from a best-effort Bash
linter through a structural git-level guard to (unimplemented) remote branch protection. Full
breakdown, including what each layer does and does not catch: the playbook.

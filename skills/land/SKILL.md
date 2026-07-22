---
name: land
description: Use when a feature/fix/chore branch (usually in a herdr or git worktree) is finished and should be merged into main — "land this", "merge this branch", "this feature is done" — or when abandoning a branch whose worktree needs cleanup.
---

# Land a branch

Run from the repo's primary checkout:

```bash
bin/land.sh <branch>
```

For flags, refusals, and recovery, run `bin/land.sh --help` and read its failure messages —
they're the source of truth for this script's behavior. Full doctrine, including how to
abandon a branch instead of landing it: `~/.claude/docs/git-hygiene-playbook.md`.

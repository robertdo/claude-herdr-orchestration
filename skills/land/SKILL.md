---
name: land
description: Use when a feature/fix/chore branch (usually in a herdr or git worktree) is finished and should be merged into main — "land this", "merge this branch", "this feature is done" — or when abandoning a branch whose worktree needs cleanup.
---

# Land a branch

Main is merge-only and deployable by construction. Landing = rebase → test → review → squash-merge → cleanup, always in that order — the mechanics are scripted; only the judgment calls below are yours. Full playbook: `~/.claude/docs/git-hygiene-playbook.md`.

## Run it

```bash
bin/land.sh <branch>
```

Run from the repo's primary checkout (it refuses otherwise). Flags: `--dry-run` stops after the diff, before merging or cleaning up; `-m "<message>"` sets the landing commit's message.

The script rebases the branch onto main inside its worktree, runs the project's tests (or build/lint if there's no test suite), prints `git diff main...HEAD`, re-checks that main hasn't moved since the rebase, squash-merges, cleans up the worktree and branch, and prints the landing commit's hash as its last line.

**Your job:** read the diff it prints before trusting the merge — that judgment call isn't automatable. Then handle whatever it refuses:

| Refusal | Why | Fix |
|---|---|---|
| branch is main | main can't land onto itself | pass the actual branch name |
| branch worktree is dirty | uncommitted changes wouldn't be part of the squash | commit first — WIP commits are fine, squash erases them |
| main has tracked modifications | they'd pollute the landing commit | commit or stash them on main first |
| main has untracked files | reported, not fatal — `git merge --squash` only stages the branch's own changes | ignore, or clean up separately if they don't belong |
| rebase conflict | must be resolved in the worktree, never on main | resolve there, then re-run `bin/land.sh <branch>` |
| race check fails | another branch landed while this one was rebased | re-run `bin/land.sh <branch>` — it rebases fresh against the new main |

## Abandoning a branch

No landing needed — clean up directly:
- herdr workspace (`HERDR_ENV=1`): `herdr worktree remove --workspace <id> --force` (id via `herdr worktree list`)
- plain git worktree: `git worktree remove <path>`
- then `git branch -D <branch>`

## Common mistakes

| Mistake | Fix |
|---|---|
| Running `bin/land.sh` from inside the worktree | Run it from the repo's primary checkout — it refuses otherwise |
| Skipping the diff review | Read Step 3's output (or use `--dry-run` first) before trusting the merge |
| Treating a race-check failure as an error to work around | It means main moved — just re-run `bin/land.sh <branch>`, glancing at what landed first |
| Deploying right after merging | Deploy only on explicit request |

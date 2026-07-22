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

Run from the repo's primary checkout, on main/master (it refuses otherwise — set `LAND_MAIN_BRANCH=<branch>` if this checkout is deliberately meant to land onto something else). Flags: `--dry-run` stops before merging/cleanup, but still rebases the branch and runs its tests — it's dry for main, not for the branch worktree; `-m "<message>"` sets the landing commit's message.

The script rebases the branch onto main inside its own worktree (pinning the tested commit's SHA), runs the project's tests (or build/lint if there's no test suite — loudly, if there's neither), prints `git diff main...HEAD`, re-checks that main hasn't moved or gotten dirty and that the branch hasn't advanced since testing, squash-merges the pinned SHA, verifies the landing commit's diff matches exactly (rolling itself back if not), cleans up the worktree and branch, and prints the landing commit's hash as its last line. If the branch has no effective changes vs main after rebase, it says so, cleans up the worktree/branch anyway, and exits without touching main.

### Timeout

Rebase + the full test suite can take minutes. Invoke `bin/land.sh` with a generous timeout, not a short agent-harness default (e.g. a 120s Bash tool timeout). If it's killed anyway:
- **SIGINT/SIGTERM** (what most timeouts send): the script traps these, reports what state it was in, and — for a mid-rebase kill — aborts the rebase itself so the worktree comes back clean.
- **SIGKILL**, or any death the trap didn't survive: re-running `bin/land.sh <branch>` notices leftover state (a staged squash on main, an in-progress rebase in the worktree) in preflight and refuses with recovery instructions, rather than compounding it.
- If a squash is left staged on main (`.git/SQUASH_MSG` present), recover with `git reset --merge` — **not** `git merge --abort`, which fails (`fatal: There is no merge to abort`) because `git merge --squash` never sets `MERGE_HEAD`.

**Your job:** read the diff it prints before trusting the merge — that judgment call isn't automatable. Then handle whatever it refuses:

| Refusal | Why | Fix |
|---|---|---|
| branch is main | main can't land onto itself | pass the actual branch name |
| primary checkout isn't main/master | landing would silently go to the wrong branch | switch the primary checkout to main, or set `LAND_MAIN_BRANCH=<branch>` if that's deliberate |
| branch worktree is dirty | uncommitted changes wouldn't be part of the squash | commit first — WIP commits are fine, squash erases them |
| branch worktree has a rebase/merge/cherry-pick in progress | land.sh won't abort in-progress work that isn't its own | finish or abort it yourself in the worktree, then re-run |
| main has tracked modifications | they'd pollute the landing commit | commit or stash them on main first |
| main has untracked files | reported, not fatal — `git merge --squash` only stages the branch's own changes | ignore, or clean up separately if they don't belong |
| main has an in-progress git operation (`SQUASH_MSG`/`MERGE_HEAD`/rebase) | leftover from an interrupted land.sh run, or an unrelated manual operation | `git reset --merge` (or finish the unrelated operation), then re-run |
| rebase conflict | must be resolved in the worktree, never on main | resolve there, then re-run `bin/land.sh <branch>` |
| race check fails (main moved) | another branch landed while this one was rebased | re-run `bin/land.sh <branch>` — it rebases fresh against the new main |
| branch advanced after tests ran | the new commit(s) weren't tested | re-run `bin/land.sh <branch>` so they get tested too |

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

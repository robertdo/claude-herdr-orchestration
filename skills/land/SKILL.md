---
name: land
description: Use when a feature/fix/chore branch (usually in a herdr or git worktree) is finished and should be merged into main — "land this", "merge this branch", "this feature is done" — or when abandoning a branch whose worktree needs cleanup.
---

# Land a branch

Main is merge-only and deployable by construction. Landing = verify → build the landing commit → fast-forward → clean up. The mechanics are scripted; only the judgment calls below are yours. Full playbook: `~/.claude/docs/git-hygiene-playbook.md`.

## Run it

```bash
bin/land.sh <branch>
```

Run from the repo's primary checkout, on main/master (it refuses otherwise — set `LAND_MAIN_BRANCH=<branch>` if this checkout is deliberately meant to land onto something else).

| Flag | Effect |
|---|---|
| `--dry-run` | build and print the candidate commit, then stop — main is never touched and there is nothing to clean up |
| `--no-tests` | land with no verification; **required** if the script finds no test suite |
| `--check '<cmd>'` | run `<cmd>` in the worktree instead of auto-detecting (env: `LAND_CHECK_CMD`) |
| `-m '<message>'` | landing commit message (multi-line bodies are fine) |

It runs the project's tests, builds the landing commit as an object (`git commit-tree` over the branch's tree, parented on main's tip), prints its diff, fast-forwards main onto it, removes the worktree and branch, and prints the landing commit's SHA. **stdout is only that SHA** — progress, the diff, and test output all go to stderr.

## Three things to know

**It rebases automatically.** If the branch doesn't already contain main, land.sh rebases it onto main's tip inside its own worktree — an isolated checkout, so a conflict there can't touch main — before anything is tested or built. A conflict leaves the rebase **in progress** in the worktree: resolve it there, finish the rebase, then re-run `bin/land.sh <branch>`. Re-running before you finish refuses rather than destroying anything — a paused rebase looks detached, so land.sh can't find the worktree until the rebase is finished or aborted.

**Review is retrospective.** Without `--dry-run` the diff is printed and the landing proceeds in the same run: you are reading what just landed, not approving what is about to. The script is called non-interactively by agents, so it never prompts. `--dry-run` is the real gate — it builds and prints the candidate and stops, and the candidate SHA it prints stays landable by hand (`git merge --ff-only <sha>`) for as long as main hasn't moved. If you want a gate, run `--dry-run` first.

**The landing commit skips your repo's commit hooks and is usually unsigned.** `git commit-tree` does not run `pre-commit` or `commit-msg`. Content validation isn't really lost — the branch's own commits already ran `pre-commit` over this exact tree, and the landing commit's tree is that tree, byte for byte. The gap is the landing *message*: a `commit-msg` hook never sees it. Signing is honoured only when `commit.gpgsign` is set, in which case the script passes `-S`. If you depend on a `commit-msg` hook or on unconditional signing, land by hand.

## Killed mid-run?

Nothing to recover. Until the final fast-forward the script has created only a candidate commit object, which is unreferenced and inert — main's index and working tree are never touched. Killed mid-rebase is equally harmless: the branch's worktree is left mid-rebase and main is untouched — finish or abort the rebase in the worktree, then re-run. Re-run it. (Give it a generous timeout anyway; the test suite can take minutes.)

## Refusals

| Refusal | Why | Fix |
|---|---|---|
| rebase onto main conflicts | can't safely land unrebased content | resolve the conflicts in the worktree, `git rebase --continue` (or `--skip`/`--abort`), then re-run |
| branch worktree has a paused/conflicted rebase, merge, or cherry-pick | auto-rebasing over it could destroy work that's only recoverable via reflog | finish or abort that operation in the worktree first |
| no test suite, and no `--check` | it will not silently land unverified code | give it `--check '<cmd>'`, or state the omission with `--no-tests` |
| branch is main | main can't land onto itself | pass the actual branch name |
| primary checkout isn't main/master | landing would silently go to the wrong branch | switch to main, or set `LAND_MAIN_BRANCH=<branch>` |
| branch worktree is dirty | uncommitted changes wouldn't be in the squash | commit first — WIP commits are fine, squash erases them |
| main has tracked modifications | they aren't the script's to clobber | commit or stash them on main first |
| main has untracked files | reported, not fatal — they can't enter the landing commit | ignore, or clean up separately |
| fast-forward failed | main moved, or its working tree is in the way | nothing landed; re-run — land.sh rebases the branch onto the new main automatically |
| branch advanced during the run | the new commits weren't verified | re-run so they get tested too |
| run from inside a worktree | it lands *onto* the primary checkout | run it from there |

Cleanup is best-effort and runs *after* the landing is published: if it fails, the landing still succeeded and the script says so and prints the manual commands. It will never delete a branch that advanced past the SHA it landed.

## Abandoning a branch

No landing needed — clean up directly:
- herdr workspace (`HERDR_ENV=1`): `herdr worktree remove --workspace <id> --force` (id via `herdr worktree list`)
- plain git worktree: `git worktree remove <path>`
- then `git branch -D <branch>`

## Common mistakes

| Mistake | Fix |
|---|---|
| Running `bin/land.sh` from inside the worktree | Run it from the repo's primary checkout — it refuses otherwise |
| Expecting the printed diff to be a gate | It isn't. Use `--dry-run` first if you want to approve before landing |
| Reaching for `--no-tests` when a check exists | Use `--check '<cmd>'` — `--no-tests` is for projects with genuinely nothing to run |
| Treating a fast-forward failure as an error to work around | It means main moved — just re-run; land.sh rebases onto the new main automatically |
| Aborting a conflicted rebase yourself and expecting the conflicts to still be there | land.sh leaves conflicts **in progress** on purpose — resolve them in the worktree, don't abort unless you mean to discard the rebase |
| Deploying right after merging | Deploy only on explicit request |

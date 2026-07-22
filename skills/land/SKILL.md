---
name: land
description: Use when a feature/fix/chore branch (usually in a herdr or git worktree) is finished and should be merged into main — "land this", "merge this branch", "this feature is done" — or when abandoning a branch whose worktree needs cleanup.
---

# Land a branch

Main is merge-only and deployable by construction. A landing is rebase → test → review → squash-merge → cleanup, always in that order. Full playbook: `~/.claude/docs/git-hygiene-playbook.md`.

## Sequence (every step, in order)

0. **Identify** the branch, its worktree path, and the repo's main checkout. Refuse to land if the branch to land IS main, if the branch worktree is dirty (commit first — WIP commits are fine, squash erases them), or if the MAIN checkout is dirty (`git status --porcelain` in the primary checkout must be empty — stray files there would pollute the landing; surface them to the user instead).
1. **Rebase** in the worktree: `git rebase main` (with a remote, fetch first and rebase the fresh main). Resolve conflicts here, never on main.
2. **Test** in the worktree, after the rebase: run the project's suite (look for a test script like `run-tests.sh`, package.json scripts, a Makefile, or CLAUDE.md instructions). No suite → build/lint instead and say "no test suite" in the land commit message.
3. **Review** `git diff main...HEAD` — check for leftover debug code, secrets, and unintended files.
4. **Land from the main checkout:**
   ```bash
   git merge --squash <branch>
   git commit -m "<feat|fix|chore>: <summary>"
   ```
   One clean commit; the message describes the change, not the journey. (The git-hygiene hook blocks normal commits on main but allows squash-merge commits.)
   **Race check first:** confirm main's HEAD is still the commit you rebased onto (`git -C <main-checkout> rev-parse HEAD` vs the rebase base). If another branch landed in between, go back to step 1 — rebase and retest against the new main. Never squash-merge onto a main you didn't test against.
5. **Clean up immediately** — cleanup is part of landing, not a later chore:
   - herdr workspace (`HERDR_ENV=1`): `herdr worktree remove --workspace <id> --force` (id via `herdr worktree list`)
   - plain git worktree: `git worktree remove <path>`
   - then `git branch -D <branch>`
6. **Report** the landing commit hash and stop. Merge = deployable; deploying is a separate deliberate step, only when explicitly requested.

## Abandoning a branch

Skip steps 1–4; run step 5 only.

## Common mistakes

| Mistake | Fix |
|---|---|
| Plain merge or `merge --no-ff` | Squash only — WIP commits must not reach main history |
| Skipping the test run | Tests run after rebase, before merging — every landing |
| Testing before rebasing | Rebase first; test what will actually land on main |
| Leaving the worktree/branch behind | Step 5 always runs, including for abandoned branches |
| Deploying right after merging | Deploy only on explicit request |

# claude-herdr-hygiene

**Worktree-per-change git hygiene for [Claude Code](https://claude.com/claude-code), guarded by hooks and orchestrated with [herdr](https://herdr.dev/) worktrees.**

Every change happens in a worktree on a branch, landed into `main` as a single squash-merged commit — so `main` stays a clean, linear history by construction, not by discipline. Claude Code hooks catch the common accidental slips — a direct `git commit` on main, a direct edit to the primary checkout — so a long session can't drift into them. They're guardrails against careless agents, not a security boundary against adversarial ones; see [What this does and does not enforce](#what-this-does-and-does-not-enforce).

---

## The problem

Let an AI coding agent work directly in your repo's main checkout and three things go wrong:

1. It commits straight to `main`, so `main` stops being a clean, deployable line.
2. It edits files in place — no isolation, no branch, no reviewable history.
3. Long "let's build X" sessions accrete half-finished, uncommittable mess.

Discipline-by-reminder doesn't survive a long session. This repo backs the doctrine with hooks that catch the two most common slips before they happen — not a guarantee nothing can go wrong, but a real floor under the discipline.

## How it works — two layers

**Soft layer (doctrine).** A `# Git hygiene` section for your `CLAUDE.md` plus the full [playbook](docs/git-hygiene-playbook.md). This is what the model reads: always work in a worktree, orchestrate don't implement, land via `bin/land.sh`, clean up immediately. The playbook is the normative source for the rules themselves — this README doesn't restate them.

**Hard layer (two hooks).** These run `PreToolUse`, before the tool executes, so catching the two most common drift patterns doesn't depend on the model remembering the doctrine:

| Hook | Event | What it does |
|---|---|---|
| `git-hygiene-guard.sh` | `PreToolUse` / Bash | A best-effort linter, not enforcement: blocks `git commit` on `main`/`master` (except an empty repo's first commit — no exception for a manual squash-merge), and blocks branch commits made in a primary checkout. |
| `git-hygiene-edit-guard.sh` | `PreToolUse` / Edit·Write·NotebookEdit | Blocks file edits inside a repo's **primary** checkout — forcing the work into a worktree. Exempts non-repo files, `~/.claude/**`, and repos with no commits yet. |

The commit guard decides by pattern-matching the literal `Bash` command string — a structurally weaker approach, since shell can express the same operation in unbounded ways. The edit guard is sounder: it resolves the target file's checkout via git itself and compares it against the calling agent's cwd, no string-parsing involved. Both are still guardrails against a careless agent taking the obvious wrong action, not a security boundary against one that's trying to get around them — for different reasons in each case. Full bypass list and rationale: the playbook's ["What this does and does not enforce"](docs/git-hygiene-playbook.md#what-this-does-and-does-not-enforce).

**Plus two helpers:**
- **`/land` skill**, backed by `bin/land.sh` — the landing sequence: rebase onto main automatically → run tests (auto-detected, or `--check`/`--no-tests`) → build the landing commit as an object (`git commit-tree`, off the branch's own tree — main's index and working tree are never touched) → print the diff → fast-forward main onto it (`git merge --ff-only`) → clean up. Review is retrospective in the default run (the merge happens in the same invocation that prints the diff); `--dry-run` is the actual gate. Refuses a dirty branch worktree, tracked changes on main, or landing with no verification found (unless `--no-tests` says the omission is deliberate).
- **`herdr-watch-agent.sh`** — lets an orchestrator background-watch a dispatched worker and get woken when it finishes/blocks, instead of foreground-waiting.

## What this does and does not enforce

**Does:** catch, before execution, the two most common ways a long session drifts — a direct `git commit` on `main`/`master`, and a direct edit to the primary checkout — with a clear error message and zero cost to the normal workflow.

**Does not:** stop a command or edit aimed around it. The commit guard is a text pattern-match over an unbounded input language (Turing-complete shell), so it has verified bypasses (interpreter indirection, non-`commit` porcelain/plumbing, `GIT_DIR` retargeting, detached HEAD, and deliberately no exception for a manual squash-merge). The edit guard is sound in approach but narrow in scope (only three tools, containing-directory classification, textual `cwd` comparison). Neither closes the tool surface — any MCP server or script that writes files or shells out bypasses both — and both can be disarmed by an edit to `~/.claude/**`, which is exempt. Neither touches your own terminal (see [Caveats](#caveats)).

The full bypass-by-bypass breakdown, the deliberate asymmetry between this guard and the per-repository one below, and the remote-branch-protection option that *is* an actual privilege boundary all live in the playbook's ["What this does and does not enforce"](docs/git-hygiene-playbook.md#what-this-does-and-does-not-enforce) — this section is the summary, that one is the reference.

For a stronger floor than either — one that does not depend on which *tool* issued the command — see [The per-repository git guard](#the-per-repository-git-guard) below.

## The per-repository git guard

`hooks/git-repo/reference-transaction` is a **git** hook, not a Claude Code hook, and it is installed **per repository** rather than into `~/.claude`. `install.sh` does not touch it; it is opt-in, one repo at a time:

```bash
./install-repo.sh /path/to/repo     # default: the current directory
./install-repo.sh --uninstall /path/to/repo
```

Git runs it inside every ref transaction, and hands it the exact old SHA, new SHA and ref name — nothing else. That is what makes it categorically different from the commit guard above, which pattern-matches a shell command string. **This hook cannot be defeated by how the command is spelled or by which tool ran it**: `sh -c`, `\git`, plumbing (`update-ref`, `commit-tree`), `GIT_DIR=` retargeting, an MCP server's `execute_shell_command`, a Makefile, your own terminal — all arrive as the same three fields. It lives in the repo's *common* git dir, so it covers every worktree of that repo at once.

### What it enforces

For the protected branch only, a ref update is allowed **only** when the new commit has exactly one parent **and** that parent is the old value — a fast-forward by exactly one commit, which is the shape `bin/land.sh` produces. Creating the branch from nothing (fresh repo, clone) is allowed.

Everything else is refused, verified by the test suite: deleting the branch, history rewrites, `git commit --amend`, `git reset --hard` backwards, `git merge` fast-forwarding a **multi-commit** branch, `git pull`, real merge commits (two parents), and jumps to an unrelated commit via `git update-ref` / `git branch -f`. Every other ref in the repository — feature branches, tags, `refs/stash`, remote-tracking refs, notes — passes through untouched.

Protect a differently-named branch (this **replaces** the `main`/`master` default; repeat the flag to list several):

```bash
git config --add hygiene.protectedBranch trunk
```

Do something the guard refuses, deliberately, for exactly one command:

```bash
HYGIENE_ALLOW_REF_UPDATE=1 git pull
```

The escape hatch is documented on purpose. You will legitimately need it — to `git pull` on main after pushing from another machine, or to undo a mistake — and a named, greppable hatch is strictly better than one people discover by deleting the hook.

### What it does **not** enforce

- **Not provenance.** It cannot tell a squash landing from a plain `git commit` made directly on the protected branch: both produce exactly one new single-parent commit whose parent is the old tip. It enforces **linearity and single-commit advance**, not "only landings reach `main`". This is not fixable with a token or marker file written by the landing script — that is forgeable state, reproducible by anything running as the same user, and it would recreate the pattern this repo is removing. `run-tests.sh` asserts the permissive behaviour explicitly so nobody can quietly start claiming otherwise.
- **Not a security boundary.** Anything running as your uid can delete the hook, point `core.hooksPath` elsewhere, or edit it. The ceiling is *"the same user cannot do it by accident"*, not *"cannot"*.
- **It protects the ref, not your checkout.** Git finishes a merge or a `reset --hard` in the index and working tree *before* it tries to move the ref, so a refusal leaves `main` correct but the checkout mid-merge or reset — `git merge --abort` / `git reset --hard main` to recover.
- **Deletion has one deliberate blind spot.** `git gc` and `git pack-refs` prune loose ref files, which git reports to the hook as deleting the protected branch; refusing that would make the repository impossible to garbage-collect. The hook allows a deletion only when it carries the pack-refs signature (a real old SHA, the loose file still present, and a surviving `packed-refs` entry at that same SHA). Every genuine delete path — `git branch -D`, `git update-ref -d` with or without an old value, packed or loose — is refused, and the suite tests all of them.
- **It is local.** It governs one clone. Pushes to a shared remote are governed by that remote's own hooks or branch protection, not by this.

`install-repo.sh` is idempotent, backs up whatever it replaces, refuses rather than clobbering a `reference-transaction` hook that isn't ours (`--as <name>` installs alongside it for chaining), and refuses rather than reporting a fake success when `core.hooksPath` points somewhere `.git/hooks` isn't read (`--hooks-dir <dir>` installs where git actually looks).

> This repository does **not** install the guard into itself. A wrong version of it here would reject the very landings needed to fix it, so turning it on is a deliberate decision, and `run-tests.sh` asserts it is off.

## The orchestrator / worker model

The session sitting in a repo's **main checkout is the orchestrator**: it scopes the work, dispatches a worker into its own worktree, supervises without blocking, and lands when the worker is done. It never implements. The **worker** owns the entire lifecycle in its one worktree — design, spec, plan, implementation, tests — landed in a single squash. One worktree, one worker, one landing.

This is an operating rule, not architecture — the full model (the three routing tiers, dispatch mechanics, sizing, supervision) is in the `CLAUDE.md` section and the playbook's ["orchestrator model"](docs/git-hygiene-playbook.md#the-orchestrator-model-who-does-the-work-tier-3-in-detail); this README doesn't restate it.

> Bootstrapping a brand-new repo is the one operation done inline (there's no repo to make a worktree from yet) — which is exactly why the commit guard exempts a repo with no commits.

## Requirements

- **Claude Code** (this is built on its hook system).
- **git** and **jq** — required. The hooks parse their input with `jq`.
- **herdr** — *optional*. It powers the full dispatch/supervise flow. Without it the hooks still catch the same worktree/main violations; the "dispatch a worker into its own pane" step degrades to a plain `git worktree add` with the session doing the work itself. You get most of the value with zero herdr.

## Install

```bash
git clone https://github.com/<you>/claude-herdr-hygiene
cd claude-herdr-hygiene
./install.sh                 # installs into ~/.claude
```

`install.sh` is **idempotent and additive** — safe to re-run, and it never clobbers your existing config:

- copies the hooks, watcher, playbook, and `/land` skill into `~/.claude/`;
- **merges** the two hooks into `~/.claude/settings.json`, backing it up first (`settings.json.bak-<timestamp>`) and skipping any hook already present;
- **appends** the git-hygiene section to `~/.claude/CLAUDE.md` between markers, backing it up first.

Install into a non-default location with `./install.sh /path/to/.claude` (or `CLAUDE_DIR=… ./install.sh`).

**After installing:** new Claude Code sessions pick up the hooks automatically. An already-running session needs `/hooks` opened once (reloads config) or a restart before they fire.

## What gets installed where

| In this repo | Installed to |
|---|---|
| `hooks/*.sh` | `~/.claude/hooks/` |
| `bin/herdr-watch-agent.sh` | `~/.claude/bin/` |
| `bin/land.sh` | `~/.claude/bin/` |
| `docs/git-hygiene-playbook.md` | `~/.claude/docs/` |
| `skills/land/SKILL.md` | `~/.claude/skills/land/` |
| (hook entries) | merged into `~/.claude/settings.json` |
| `claude-md/git-hygiene-section.md` | merged into `~/.claude/CLAUDE.md` (block replaced on re-run) |

## Manual install

Prefer not to run the script? Copy the file groups above into `~/.claude/`, then merge the two hook entries `install.sh` defines for `git-hygiene-guard.sh` (matcher `Bash`) and `git-hygiene-edit-guard.sh` (matcher `Edit|Write|NotebookEdit`) into your `settings.json` — `install.sh` is the one definition of those entries; read its `jq` filter for the exact JSON — and paste `claude-md/git-hygiene-section.md` into your `CLAUDE.md`.

## Uninstall

Open `/hooks` and disable the two, or remove their entries from `settings.json` and delete the block between the `claude-herdr-hygiene` markers in `CLAUDE.md`. The `.bak-<timestamp>` files the installer left behind let you revert wholesale.

If you installed before this repo dropped `git-hygiene-dispatch-nudge.sh` (a `UserPromptSubmit` hook that nudged the session to dispatch instead of implementing inline — folded into the edit guard's coverage, since the edit guard already blocks the consequential mistake), it's now a stale hook: delete `~/.claude/hooks/git-hygiene-dispatch-nudge.sh` and its entry under `hooks.UserPromptSubmit` in `~/.claude/settings.json` by hand. `install.sh` does not remove it for you.

## Caveats

- **Hooks govern Claude Code sessions only** — never your own terminal. A manual `git commit` on main from your shell is *not* blocked (by design; this constrains the agent, not you).
- **`~/src`** in the docs is just where the author keeps repos. Nothing hardcodes it — the hooks detect the primary checkout from git itself, so enforcement works for a repo anywhere.
- **Model routing is not shipped.** The playbook says "size the worker's model + effort to the task"; *which* model/effort is a personal policy the author keeps separately. Plug in your own.

## License

[MIT](LICENSE).

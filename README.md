# claude-herdr-hygiene

**Worktree-per-change git hygiene for [Claude Code](https://claude.com/claude-code), enforced by hooks and orchestrated with [herdr](https://herdr.dev/) worktrees.**

Every change happens in a worktree on a branch; `main` only ever receives tested, squash-merged commits — so **main is deployable by construction, not by discipline**. Claude Code hooks enforce this physically, so a long session can't drift into committing on main or editing the primary checkout in place.

---

## The problem

Let an AI coding agent work directly in your repo's main checkout and three things go wrong:

1. It commits straight to `main`, so `main` stops being a clean, deployable line.
2. It edits files in place — no isolation, no branch, no reviewable history.
3. Long "let's build X" sessions accrete half-finished, uncommittable mess.

Discipline-by-reminder doesn't survive a long session. This repo makes the discipline *physical*.

## How it works — two layers

**Soft layer (doctrine).** A `# Git hygiene` section for your `CLAUDE.md` plus the full [playbook](docs/git-hygiene-playbook.md). This is what the model reads: always work in a worktree, orchestrate don't implement, land via squash, clean up immediately.

**Hard layer (three hooks).** These run inside every Claude Code session and can't be talked out of:

| Hook | Event | What it does |
|---|---|---|
| `git-hygiene-guard.sh` | `PreToolUse` / Bash | Blocks `git commit` on `main`/`master` (except squash-merge landings and empty-repo bootstrap), and blocks branch commits made in a primary checkout. |
| `git-hygiene-edit-guard.sh` | `PreToolUse` / Edit·Write·NotebookEdit | Blocks file edits inside a repo's **primary** checkout — forcing the work into a worktree. Exempts non-repo files, `~/.claude/**`, and repos with no commits yet. |
| `git-hygiene-dispatch-nudge.sh` | `UserPromptSubmit` | A **nudge, not a block**: when a feature/design/build request lands in a primary checkout, it reminds the session to *scope then dispatch* to a worker instead of implementing inline. Silent in worktrees, non-repos, and for plain questions. |

**Plus two helpers:**
- **`/land` skill** — the landing sequence: rebase → test → review → squash-merge → cleanup, with the safety checks (dirty-checkout refusal, race re-check against a concurrently-landed main).
- **`herdr-watch-agent.sh`** — lets an orchestrator background-watch a dispatched worker and get woken when it finishes/blocks, instead of foreground-waiting.

## The orchestrator / worker model

The session sitting in a repo's **main checkout is the orchestrator**. It never implements. It:

1. **Scopes** — asks you whatever clarifying questions it needs to size the work (a well-scoped brief is what makes dispatch smart).
2. **Dispatches** — `herdr worktree create` + launches a Claude worker *inside* the worktree with a self-contained brief.
3. **Supervises without blocking** — starts `herdr-watch-agent.sh` in the background and ends its turn, staying free to talk to you and dispatch more workers in parallel.
4. **Lands** — runs `/land` when the worker is done.

The **worker** owns the entire lifecycle in its one worktree — design, spec, plan, implementation, tests — landed in a single squash. One worktree, one worker, one landing.

> Bootstrapping a brand-new repo is the one operation done inline (there's no repo to make a worktree from yet) — which is exactly why the commit guard exempts a repo with no commits.

## Requirements

- **Claude Code** (this is built on its hook system).
- **git** and **jq** — required. The hooks parse their input with `jq`.
- **herdr** — *optional*. It powers the full dispatch/supervise flow. Without it the hooks still enforce all the worktree/main discipline; the "dispatch a worker into its own pane" step degrades to a plain `git worktree add` with the session doing the work itself. You get most of the value with zero herdr.

## Install

```bash
git clone https://github.com/<you>/claude-herdr-hygiene
cd claude-herdr-hygiene
./install.sh                 # installs into ~/.claude
```

`install.sh` is **idempotent and additive** — safe to re-run, and it never clobbers your existing config:

- copies the hooks, watcher, playbook, and `/land` skill into `~/.claude/`;
- **merges** the three hooks into `~/.claude/settings.json`, backing it up first (`settings.json.bak-<timestamp>`) and skipping any hook already present;
- **appends** the git-hygiene section to `~/.claude/CLAUDE.md` between markers, backing it up first.

Install into a non-default location with `./install.sh /path/to/.claude` (or `CLAUDE_DIR=… ./install.sh`).

**After installing:** new Claude Code sessions pick up the hooks automatically. An already-running session needs `/hooks` opened once (reloads config) or a restart before they fire.

## What gets installed where

| In this repo | Installed to |
|---|---|
| `hooks/*.sh` | `~/.claude/hooks/` |
| `bin/herdr-watch-agent.sh` | `~/.claude/bin/` |
| `docs/git-hygiene-playbook.md` | `~/.claude/docs/` |
| `skills/land/SKILL.md` | `~/.claude/skills/land/` |
| `settings/hooks-snippet.json` | merged into `~/.claude/settings.json` |
| `claude-md/git-hygiene-section.md` | appended to `~/.claude/CLAUDE.md` |

## Manual install

Prefer not to run the script? Copy the four file groups above into `~/.claude/`, then merge `settings/hooks-snippet.json` into your `settings.json` (adjust `$HOME` to your absolute path if your shell doesn't expand it in hook commands) and paste `claude-md/git-hygiene-section.md` into your `CLAUDE.md`.

## Uninstall

Open `/hooks` and disable the three, or remove their entries from `settings.json` and delete the block between the `claude-herdr-hygiene` markers in `CLAUDE.md`. The `.bak-<timestamp>` files the installer left behind let you revert wholesale.

## Caveats

- **Hooks govern Claude Code sessions only** — never your own terminal. A manual `git commit` on main from your shell is *not* blocked (by design; this constrains the agent, not you).
- **`~/src`** in the docs is just where the author keeps repos. Nothing hardcodes it — the hooks detect the primary checkout from git itself, so enforcement works for a repo anywhere.
- **Model routing is not shipped.** The playbook says "size the worker's model + effort to the task"; *which* model/effort is a personal policy the author keeps separately. Plug in your own.

## License

[MIT](LICENSE).

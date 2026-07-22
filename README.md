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

**Soft layer (doctrine).** A `# Git hygiene` section for your `CLAUDE.md` plus the full [playbook](docs/git-hygiene-playbook.md). This is what the model reads: always work in a worktree, orchestrate don't implement, land via squash, clean up immediately.

**Hard layer (three hooks).** These run pre-execution inside every Claude Code session, so catching the two most common drift patterns doesn't depend on the model remembering the doctrine:

| Hook | Event | What it does |
|---|---|---|
| `git-hygiene-guard.sh` | `PreToolUse` / Bash | Blocks `git commit` on `main`/`master` (except squash-merge landings and empty-repo bootstrap), and blocks branch commits made in a primary checkout. |
| `git-hygiene-edit-guard.sh` | `PreToolUse` / Edit·Write·NotebookEdit | Blocks file edits inside a repo's **primary** checkout — forcing the work into a worktree. Exempts non-repo files, `~/.claude/**`, and repos with no commits yet. |
| `git-hygiene-dispatch-nudge.sh` | `UserPromptSubmit` | A **nudge, not a block**: when a feature/design/build request lands in a primary checkout, it reminds the session to *scope then dispatch* to a worker instead of implementing inline. Silent in worktrees, non-repos, and for plain questions. |

The commit guard decides by pattern-matching the literal `Bash` command string — a structurally weaker approach, since shell can express the same operation in unbounded ways. The edit guard is sounder: it resolves the target file's checkout via git itself and compares it against the calling agent's cwd, no string-parsing involved. Both are still guardrails against a careless agent taking the obvious wrong action, not a security boundary against one that's trying to get around them — for different reasons in each case. See [What this does and does not enforce](#what-this-does-and-does-not-enforce) for the specifics.

**Plus two helpers:**
- **`/land` skill** — the landing sequence: rebase → test → review → squash-merge → cleanup, with the safety checks (dirty-checkout refusal, race re-check against a concurrently-landed main).
- **`herdr-watch-agent.sh`** — lets an orchestrator background-watch a dispatched worker and get woken when it finishes/blocks, instead of foreground-waiting.

## What this does and does not enforce

**Does:** catch, before execution, the two most common ways a long session drifts — a direct `git commit` on `main`/`master`, and a direct edit to the primary checkout — with a clear error message and zero cost to the normal workflow.

**Does not — commit guard:** stop a command aimed around it. Verified bypasses include quoting/interpreter indirection (`sh -c "git commit -m x"`, `\git commit`), non-`commit` porcelain and plumbing on main (`git merge`, `git pull`, `git cherry-pick`, `git revert`, `git commit-tree` + `git update-ref`), a non-leading `cd` in a compound command, `GIT_DIR` retargeting, detached HEAD in the primary checkout (it exempts branch commits by branch *name*, and detached HEAD has none), and branches not literally named `main`/`master`.

**Does not — edit guard:** its path-and-cwd resolution is sound, but narrower — it only sees `Edit`/`Write`/`NotebookEdit`, it classifies a target by its containing directory (so a final-component symlink pointing outside the worktree isn't caught), and it compares `cwd` to the worktree path as text (so a path that's the same directory via a different spelling, e.g. macOS's `/tmp` vs. `/private/tmp`, can produce a false denial).

Two gaps matter more than any single bypass, and apply to both guards:
- **The tool surface isn't closed.** The hooks match only `Bash` and `Edit`/`Write`/`NotebookEdit`. Any other tool that can run a shell command or write a file — an MCP server exposing `execute_shell_command` or `create_text_file`, for instance — bypasses both guards entirely, as do `sed -i`, shell redirects, `patch`, `git apply`, and build/format scripts.
- **The hooks can disarm themselves.** The edit guard exempts `~/.claude/**`, which is where the hooks and `settings.json` live — one edit there turns off enforcement, in the same session.

Neither guard touches your own terminal — a `git commit` or file edit you type by hand isn't in scope (see [Caveats](#caveats)).

For a real security boundary, see the playbook's ["What this does and does not enforce"](docs/git-hygiene-playbook.md#what-this-does-and-does-not-enforce) for the git-level-hooks and remote-branch-protection options (not implemented in this repo).

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
- **herdr** — *optional*. It powers the full dispatch/supervise flow. Without it the hooks still catch the same worktree/main violations; the "dispatch a worker into its own pane" step degrades to a plain `git worktree add` with the session doing the work itself. You get most of the value with zero herdr.

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
| `bin/land.sh` | `~/.claude/bin/` |
| `docs/git-hygiene-playbook.md` | `~/.claude/docs/` |
| `skills/land/SKILL.md` | `~/.claude/skills/land/` |
| `settings/hooks-snippet.json` | merged into `~/.claude/settings.json` |
| `claude-md/git-hygiene-section.md` | merged into `~/.claude/CLAUDE.md` (block replaced on re-run) |

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

# Git Hygiene Playbook — Claude + herdr

*Applies uniformly to every git repo you work in. (The author keeps repos under `~/src`, but the hooks don't hardcode that path — they detect the primary checkout from git itself.) Non-git directories are exempt. The enforcement hooks below only recognize branches literally named `main` or `master` — a repo with a differently named default branch is unguarded.*

**The system in one line:** every change happens in a herdr worktree on a branch, landed as a single squash-merged commit — so main stays a clean, linear history by construction, not by discipline. Landing via `bin/land.sh` runs tests as part of that path, but nothing *enforces* landing through the script — a hook-permitted `git merge --squash` + `git commit` reaches main without running them. See "What this does and does not enforce" below.

## 1. The prime rule

Every change — feature, fix, typo — gets its own herdr worktree-workspace on a branch. **Main is merge-only.** No judgment calls, no thresholds.

```
herdr worktree create --cwd <repo> --branch <name>
```

is the universal first step of any work.

- Uniform everywhere: real apps and throwaway prototypes get the same rule. Consistency is the point — one habit, zero decisions.
- Claude's behavior: a Claude session asked to change code while sitting in a main checkout creates (or asks to create) a worktree first. Claude never edits or commits in main's checkout directly.
- Parallel agents never share a checkout. One worktree = one concern.

**Enforcement hooks (all Claude Code sessions).** Two hard guards — added after a session satisfied the letter of the commit hook by doing `git checkout -b` in the primary checkout, working there, and squash-landing — plus one soft nudge:
- `git-hygiene-edit-guard.sh` (Edit/Write/NotebookEdit): file edits inside a repo's *primary* checkout are denied on any branch; edits in a linked worktree are denied when the session's cwd is a different checkout of the same repo (orchestrator meddling). Exempt: non-repo files, `~/.claude/**`, repos with no commits.
- `git-hygiene-guard.sh` (Bash): `git commit` denied on main/master in any checkout (except squash-merge/merge landings and empty-repo bootstrap), and denied on non-main branches when in the primary checkout.
- `git-hygiene-dispatch-nudge.sh` (UserPromptSubmit): a NUDGE, not a block — when a prompt in a primary checkout reads as feature/design/build work, it reminds the session to scope-then-dispatch to a worker instead of implementing inline. Silent in linked worktrees, non-repos, and for plain questions.

### What this does and does not enforce

The two guards take genuinely different approaches, and their limits are different in kind — one is structurally unsound, the other is sound but narrow. Both are **guardrails against careless agents, not a security boundary against adversarial ones**. That's not a small caveat, but it's not a reason to skip them either: catching a plain `git commit` on main and a direct edit to the primary checkout, pre-execution, with a good error message, at zero workflow cost, is genuinely valuable — it stops the two most common ways a long session drifts.

**Does:** deny, before execution, a direct `git commit` on `main`/`master` (outside a squash-merge landing or empty-repo bootstrap) and a direct file edit inside the primary checkout, on any branch.

**Does not — the commit guard (`git-hygiene-guard.sh`, Bash) is structurally unsound, not merely buggy.** It decides whether a command is a forbidden git operation by pattern-matching the literal command string, and the input language is Turing-complete shell — "does this string eventually move `refs/heads/main`" is undecidable in general. Verified bypasses:
- Quoting/interpreter indirection: `sh -c "git commit -m x"`, `"git" commit`, `'git' commit`, `\git commit` — the guard scans the literal command string, so anything that reaches `git commit` through another layer of interpretation isn't recognized as `git commit`.
- Flag values: `git -c user.name=x commit` — the flag-group regex expects `-c` to be immediately followed by `commit` but instead consumes the flag's value and misses. This one fires *accidentally*, not just adversarially — agents pass `-c` routinely.
- Non-`commit` porcelain and plumbing that also move `main`: `git merge` (a plain fast-forward is the likely *accidental* case here, and it sails straight through), `git pull`, `git cherry-pick`, `git revert`, `git commit-tree` + `git update-ref refs/heads/main`, `git branch -f main`.
- Non-leading `cd`: `true; cd /repo && git commit` — the guard resolves its target directory from the session cwd or a leading `cd`, so it inspects the wrong repo.
- Env retargeting: `GIT_DIR=/repo/.git git commit`, run from a non-repo cwd.
- Two-step state fabrication: `touch .git/SQUASH_MSG` (allowed — it's not a commit), then `git commit` on main (allowed — the guard sees `SQUASH_MSG` and assumes a landing in progress).
- Detached HEAD in the primary checkout is entirely exempt. The guard derives `branch` from `git symbolic-ref --short -q HEAD`, which is empty in detached HEAD; the primary-checkout branch-commit deny only fires when `[ -n "$branch" ]`, so an empty branch name skips it and the command exits allowed — regardless of checkout.
- Only branches literally named `main`/`master` are recognized at all.

**Does not — the edit guard (`git-hygiene-edit-guard.sh`, Edit/Write/NotebookEdit) is sound in approach, narrower in scope.** It doesn't parse strings: it resolves the target file's directory, asks git which checkout that directory belongs to (`--absolute-git-dir` vs. `--git-common-dir`), and for a linked worktree compares that against the calling agent's `cwd`. A primary-checkout edit is denied unconditionally — there's no branch check to route around, so (unlike the commit guard) detached HEAD gives no exemption here. Its real limits are scope and path resolution, not string-parsing:
- Tool scope: it matches only `Edit`/`Write`/`NotebookEdit`. Any other write path — `sed -i`, shell redirects, `patch`, `git apply`, formatters, build scripts, an MCP server's file/shell tools — never reaches it.
- Parent-directory classification: it classifies by walking up from `dirname` of the target path to the nearest existing directory, then asks git about *that* directory — so if the file path's final component is itself a symlink pointing outside the worktree, the guard classifies the (in-worktree) containing directory while the actual write lands wherever the symlink resolves.
- Textual cwd comparison: the linked-worktree check (`case $cwd in "$tl"|"$tl"/*)`) compares the hook payload's `cwd` against git's toplevel path as strings, not after resolving symlinks — a `cwd` that names the same directory via a different but equivalent path (e.g. macOS's `/tmp` vs. `/private/tmp`) can mismatch and produce a false denial.

**The tool surface is not closed.** The hooks are `PreToolUse` matchers scoped to specific tools — `Bash` for the commit guard, `Edit`/`Write`/`NotebookEdit` for the edit guard. Any other tool that can run a shell command or write a file bypasses both, completely: an MCP server exposing file or shell tools (e.g. serena's `create_text_file`, `replace_content`, `execute_shell_command`), `sed -i`, shell redirects, `patch`, `git apply`, formatters, and build scripts never reach either guard.

**The hooks can disarm themselves.** The edit guard exempts `~/.claude/**` — the exact directory the hooks and `settings.json` live in. One `Edit` to the guard script, or to `settings.json`, turns off enforcement, effective immediately, in the same session.

**Hooks govern Claude Code sessions only — never your own terminal.** A `git commit` typed directly into your shell, or a file edited by hand, isn't touched by any of this; it constrains the agent, not you.

**For hard enforcement** (documented here as options, not implemented in this repo):
- **Git-level hooks** (`pre-commit`, `pre-merge-commit`, `reference-transaction`) run inside git itself, so they're immune to command-spelling tricks and see every tool that ultimately invokes `git` — closing the tool-surface gap above. They're still deletable or edit-around-able by any process running as the same user, so they don't close the self-disarm gap.
- **Remote branch protection** with squash-only merges enforced server-side is the only boundary a same-uid local process can't remove — it's the actual privilege boundary if you need one.

### Three tiers of change (who does the work)

Rule 1 above (always worktree) is absolute — it's cheap and it's what protects main. Who *executes inside* that worktree is a separate question, and it does not get the same absolute answer.

**Route on discovery and volume, not on importance or how small the diff looks.** A one-line typo fix and a security patch can both be Tier 1, if the acting session already knows the exact change to make. A large but fully-scoped mechanical rename can be Tier 2. Delegation earns its overhead on volume and repetition, not on stakes — briefing a subagent to make an edit you have already fully specified costs more than making it yourself.

- **Tier 1 — self-edit in a worktree.** Use when the acting session already knows the exact change (no discovery needed). Create the worktree, move the session's own cwd into it (`EnterWorktree(path: <worktree>)`), edit and commit directly, then `ExitWorktree(action: "keep")` and land with `bin/land.sh`. No second agent, no watcher, no turn boundary. Permitted by the cwd mechanism below.
- **Tier 2 — delegate to an in-session subagent with worktree isolation.** Use when the change needs discovery, volume, or repetition but has modest blast radius. Claude Code's Agent tool with `model: haiku|sonnet` and `isolation: "worktree"` pins the subagent's cwd inside its own worktree, so the guard permits its edits. One tool call; no watcher, no transcript review, no turn boundary.
  **Status: unvalidated — do not treat as proven.**
  - Untested whether `isolation: "worktree"` works in a repo with **no git remote**. Claude Code's `EnterWorktree` docs say `worktree.baseRef` defaults to `fresh`, branching from `origin/<default-branch>` — a remote-less repo has no `origin`, so this may fail or silently fall back to HEAD.
  - `isolation: "worktree"` creates a **Claude-native worktree under `.claude/worktrees/`**, not a herdr workspace — it will not appear in `herdr worktree list`, and cleanup is `git worktree remove`, not `herdr worktree remove`.
- **Tier 3 — dispatch a herdr pane worker.** Use when there is real blast radius, a long horizon, or parallel work to run. This is the flow detailed in "The orchestrator model" below, unchanged.

**Why the worktree requirement is absolute but the dispatch requirement isn't — verified by reading `hooks/git-hygiene-edit-guard.sh`:**
- **Lines 28-31:** if the target file is in the repo's PRIMARY checkout, the edit is denied unconditionally. No agent — main session or subagent — can edit the primary checkout. The worktree requirement is therefore non-negotiable and stays absolute for all three tiers.
- **Lines 34-36:** for a LINKED worktree the hook reads `.cwd` from the hook payload (the *acting agent's* cwd) and allows the edit when that cwd is inside the worktree toplevel: `case $cwd in "$tl"|"$tl"/*) exit 0 ;;`
- **Lines 38-43:** it denies only when the acting agent's cwd is a *different* checkout of the same repo ("orchestrator meddling").

The guard is **cwd-based, not agent-identity-based**: any agent whose cwd sits inside the worktree may edit it directly. That's the fact that legitimizes Tiers 1 and 2 — both keep the acting agent's cwd inside the worktree throughout, so the guard never fires. Tier 3 exists for when volume, blast radius, or parallelism make dispatch worth its overhead anyway.

### The orchestrator model (who does the work) — Tier 3 in detail

The session in the repo's main checkout is the **orchestrator** — it never implements. It creates the worktree workspace, launches a Claude agent *inside* it, hands over the task, and supervises. Doing the work yourself from the main-checkout session — even at the worktree's path — violates the model. (Decided 2026-07-21 after exactly that failure.) Refined 2026-07-22 to separate the **worktree requirement** (integrity; cheap; non-negotiable) from the **dispatch requirement** (cost/context/parallelism; scales with the change) — see "Three tiers of change" above; this section is Tier 3's mechanics specifically.

Verified dispatch sequence (requires `HERDR_ENV=1`):

```bash
herdr worktree create --cwd <repo> --branch <type>/<slug> --no-focus --json
# parse .result.root_pane.pane_id and .result.workspace.workspace_id
herdr pane run <pane> "claude"                                    # interactive Claude in the worktree
herdr wait agent-status <pane> --status idle --timeout 30000
herdr pane run <pane> "<full task prompt, self-contained>"
herdr wait agent-status <pane> --status working --timeout 30000
```

**Worker sizing: two independent dials (model + effort).** The orchestrator sizes each dispatch on model (capability) and effort (reasoning depth) separately — it has the task description and no stake in doing the work itself, so this judgment belongs here. **Size the worker on both dials, explicitly.** Dispatch the cheapest model that clears the task's hardest requirement (importance ≠ difficulty — most work does not need your top-tier model; reserve that for the genuinely hard tail), and set effort to match reasoning depth (`high` is a sane default; `xhigh` only for the hardest architecture/debug). Pass `--model` and `--effort` explicitly — your harness default is not the right dispatch default. (The author drives this from a personal model-routing policy that isn't shipped here; plug in your own.)

Escalation is by replacement, not persistence: if a worker grinds, kill it and relaunch on a stronger combo. Workers don't self-escalate upward — but they routinely delegate downward: the dispatched premium model is the worker's *ceiling*, used for planning, design, and the hard parts, while routine subtasks (boilerplate implementation, bulk edits, test scaffolding, searches) run on cheaper subagents. An opus/fable worker that does its own bulk renames is overspending.

**Feature lifecycle: one worktree, one worker, one landing.** Skills that produce repo artifacts (a brainstorming/spec skill, implementation plans) compose with the orchestrator model as follows — decided after a session spun up a worktree just to commit a spec, returned to main to write a plan, then dispatched a second worktree to implement:

- *Orchestrator = scoping only.* Before dispatch it asks the user whatever clarifying questions it needs to pin down the goal, constraints, and blast radius, then uses the answers to size the model/effort dials and write a complete self-contained brief. Asking is expected, not a delay — a well-scoped brief is what makes dispatch smart and lets the worker deliver without pestering. It clarifies only enough to dispatch well; it does NOT brainstorm designs, author specs, or write plans — that happens in the worker's pane.
- *Worker = the entire lifecycle, one worktree.* The dispatch prompt carries the task plus whatever scope was clarified. The worker runs design (brainstorming with the user directly in its pane when design input is needed — `blocked` status signals this), commits the spec as its first worktree commit (e.g. `docs/superpowers/specs/...`), plans, implements, tests — all on the one branch, landed in one squash.
- *Never* dispatch a worker whose only job is committing a document, and *never* alternate orchestrator-side authoring with worker dispatches inside one feature.

**Supervise without blocking.** After confirming `working`, the orchestrator must NOT foreground-wait on the worker — that holds the session hostage and prevents the user from talking to it or dispatching parallel work. Instead it starts a watcher as a background task and ends its turn:

```bash
bash ~/.claude/bin/herdr-watch-agent.sh <pane>    # Bash run_in_background: true
```

The watcher exits (waking the orchestrator) when the worker reaches a terminal state, printing which: `done`/`idle` → review via `herdr pane read <pane> --source recent-unwrapped --lines 120` — status is attention, not success, so review the transcript before landing — then the **orchestrator** runs `/land` — landing removes the workspace, which ends the worktree agent, so the worktree agent must not land itself. `blocked` → read the worker's question, answer via `pane run`, restart the watcher. `gone` → the pane closed underneath; investigate. `timeout` (4h cap) → inspect the pane; restart the watcher if work is legitimately still running. One watcher per worker pane — never start a second watcher on a pane that already has one; parallel workers each get their own worktree, worker, and watcher. A worker's own subagents operate inside the worker's worktree under the worker's coordination — that's fine (one branch, one coordinator); what parallel workers must never do is share a checkout with *each other*.

Fallback when herdr isn't available (`HERDR_ENV` unset): the session does the work itself in a plain git worktree (`git worktree add`), still never in the main checkout.

## 2. Branch + worktree naming

- `feat/<slug>` — new functionality
- `fix/<slug>` — bug fixes
- `chore/<slug>` — maintenance, deps, config, docs

The slug doubles as the worktree directory name under `~/src/.worktrees/<repo>/`, so the herdr sidebar reads as a live work inventory.

## 3. On-branch freedom

Inside the worktree, commit as messily as you like — WIP commits, checkpoints, experiments. Squash-merge erases branch history, so branch commits are save-points, not published history. This is what makes "always worktree" cheap: no per-commit ceremony.

## 4. Landing (the merge gate)

Scripted as `bin/land.sh <branch>` (see `skills/land/SKILL.md` for the flags and the refusal table) — it does, in order:

1. **Refuse to rebase.** The branch must *already* contain main. If it doesn't, the script stops and prints the exact `git rebase` to run inside the worktree. Rebasing is a preparation step you do, deliberately, where conflicts belong — never something the landing path does on your behalf. This is the single biggest reason the script is simple: conflict resolution, abort, and recovery are not in it at all.
2. **Verify** — run the project's test suite (auto-detected), or an explicit `--check '<cmd>'`. If there is nothing to run, it **refuses** rather than landing unverified code; `--no-tests` is how you say the omission is deliberate, and it gets recorded in the commit message.
3. **Build the landing commit as an object.** `git commit-tree <branch's tree> -p <main's tip>` produces the finished commit without touching main's index or working tree. Its tree *is* the tested branch tree, by construction — content on main cannot leak into it, and there is nothing to verify after the fact.
4. **Print the diff, then fast-forward.** Review here is retrospective: without `--dry-run` the script proceeds to `git merge --ff-only` in the same run, so you're reading what just landed, not approving what's about to. `--dry-run` is the actual gate — it builds and prints the candidate and stops, and prints a SHA you can land by hand later. One clean commit per change; the message describes the change, not the journey (`-m` sets it). No PRs required for solo work; open one when you want that record.

**This repo is self-verifying.** It ships its own `run-tests.sh` at the root — 146 assertions covering `bin/land.sh`'s behaviour against throwaway git repos, plus a lint sweep over every shell script here — and `run-tests.sh` is the first thing land.sh's detection ladder looks for. So landings in *this* repo really do run tests, including the landing of a change to land.sh itself. Run it directly any time: `./run-tests.sh` (~15s, no network).

**Why this shape.** Nothing is mutated until the fast-forward, so the script is abortable at any point with zero cleanup: kill it and re-run, no recovery protocol, no wreckage for the next run to detect. And if main advanced while the tests ran, `--ff-only` fails on its own — the safety is git's, not a hand-written race check. The tradeoff is that `commit-tree` doesn't run the repo's `pre-commit`/`commit-msg` hooks and signs only when `commit.gpgsign` is set; see `skills/land/SKILL.md` for why the content-validation half of that is mostly moot and the message half isn't.

## 5. Cleanup — immediately, not eventually

`bin/land.sh` runs this automatically as its last step when landing. For an abandoned branch (no landing), run it yourself:

```
herdr worktree remove --workspace <id> --force
git branch -D <name>
```

A worktree never outlives its merge or its abandonment. Cleanup is part of landing, not a separate chore — this is the direct fix for stale-worktree pileup.

## 6. Deploying

Merge makes main **deployable**; deploying is a separate, deliberate act (run your deploy step when chosen). Batch several merges into one deploy freely.

Corollaries:
- Never deploy from a branch.
- Never "quick-fix in prod" — a hotfix goes worktree → land → deploy like everything else. The path is fast precisely because it's always the same path.

## 7. Long-running branches

If a branch lives more than a day or two, rebase it on main regularly — drift is the tax on the worktree model, and frequent rebases keep it small. `bin/land.sh` refuses to land a branch that doesn't already contain main, so this stops being optional hygiene and becomes the thing you do right before landing anyway. Prefer landing small slices over one giant branch.

## Lifecycle summary

```
herdr worktree create ──► work (Tier 1/2/3, messy commits OK)
        ──► [rebase on main, in the worktree, when main has moved]
        ──► bin/land.sh (verify ──► build candidate ──► review ──► fast-forward ──► cleanup)
        ──► [deploy, when chosen]
```

## Encoding status

Encoded as: CLAUDE.md rules (soft), two PreToolUse guards + one UserPromptSubmit dispatch-nudge (see "Enforcement hooks" above), the `/land` skill backed by `bin/land.sh`, the three-tier routing model (this document, mirrored in `claude-md/git-hygiene-section.md`), and the background watcher. This playbook remains the source of truth; when doctrine changes, update it and the encodings together.

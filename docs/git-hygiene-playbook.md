# Git Hygiene Playbook — Claude + herdr

*Applies uniformly to every git repo you work in. (The author keeps repos under `~/src`, but the hooks don't hardcode that path — they detect the primary checkout from git itself.) Non-git directories are exempt.*

**The system in one line:** every change happens in a herdr worktree on a branch; main only ever receives tested, squash-merged commits — so main is deployable by construction, not by discipline.

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
- Limits: Bash file writes (`sed -i`, redirects) bypass the edit guard but their commits are still caught; hooks govern Claude Code sessions only, never your own terminal.

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

Scripted as `bin/land.sh <branch>` (see `skills/land/SKILL.md` for the refusal table) — it does, in order:

1. **Rebase** on latest main — surface conflicts in the worktree, never on main; the script aborts the rebase automatically on conflict rather than leaving it mid-resolution.
2. **Test** — run the suite; if the project has none, the degraded equivalent (build / lint), and say so in the commit message.
3. **Self-review** the diff — printed for you to read before it merges; `--dry-run` stops here, before any merge or cleanup.
4. **Race-check** that main hasn't moved since the rebase, then **squash-merge locally** into main — one clean commit per change; message describes the change, not the journey (`-m` sets it explicitly). No PRs required for solo work; open a PR instead when you want that record.

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

If a branch lives more than a day or two, rebase it on main regularly — drift is the tax on the worktree model, and frequent rebases keep it small. Prefer landing small slices over one giant branch.

## Lifecycle summary

```
herdr worktree create ──► work (Tier 1/2/3, messy commits OK)
        ──► bin/land.sh (rebase ──► test ──► review ──► squash-merge ──► cleanup)
        ──► [deploy, when chosen]
```

## Encoding status

Encoded as: CLAUDE.md rules (soft), two PreToolUse guards + one UserPromptSubmit dispatch-nudge (see "Enforcement hooks" above), the `/land` skill backed by `bin/land.sh`, the three-tier routing model (this document, mirrored in `claude-md/git-hygiene-section.md`), and the background watcher. This playbook remains the source of truth; when doctrine changes, update it and the encodings together.

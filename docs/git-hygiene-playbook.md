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

### The orchestrator model (who does the work)

The session in the repo's main checkout is the **orchestrator** — it never implements. It creates the worktree workspace, launches a Claude agent *inside* it, hands over the task, and supervises. Doing the work yourself from the main-checkout session — even at the worktree's path — violates the model. (Decided 2026-07-21 after exactly that failure.)

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

To land a branch, in order:

1. **Rebase** on latest main — surface conflicts in the worktree, never on main.
2. **Test** — run the suite; if the project has none, the degraded equivalent (build / lint / manual smoke), and say so in the commit message.
3. **Self-review** the diff (use a code-review skill/tool for anything non-trivial).
4. **Squash-merge locally** into main — one clean commit per change; message describes the change, not the journey. No PRs required for solo work; open a PR instead when you want that record.

## 5. Cleanup — immediately, not eventually

The moment a branch lands (or an experiment is abandoned):

```
herdr worktree remove --workspace <id> --force
git branch -D <name>
```

A worktree never outlives its merge. Cleanup is part of landing, not a separate chore — this is the direct fix for stale-worktree pileup.

## 6. Deploying

Merge makes main **deployable**; deploying is a separate, deliberate act (run your deploy step when chosen). Batch several merges into one deploy freely.

Corollaries:
- Never deploy from a branch.
- Never "quick-fix in prod" — a hotfix goes worktree → land → deploy like everything else. The path is fast precisely because it's always the same path.

## 7. Long-running branches

If a branch lives more than a day or two, rebase it on main regularly — drift is the tax on the worktree model, and frequent rebases keep it small. Prefer landing small slices over one giant branch.

## Lifecycle summary

```
herdr worktree create ──► work (messy commits OK) ──► rebase ──► test ──► review
        ──► squash-merge to main ──► remove worktree + delete branch ──► [deploy, when chosen]
```

## Encoding status

Encoded as: CLAUDE.md rules (soft), two PreToolUse guards + one UserPromptSubmit dispatch-nudge (see "Enforcement hooks" above), the `/land` skill, and the background watcher. This playbook remains the source of truth; when doctrine changes, update it and the encodings together.

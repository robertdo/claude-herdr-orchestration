# Model routing — the framework

This repo's git hygiene answers *who executes the work and where* — the three tiers, keyed on
discovery and volume, that put every change in a worktree. This document answers the orthogonal
question: **which model runs a task, and how hard should it think?** The two are independent.
A Tier 3 dispatch and a Tier 1 self-edit each still need a model and an effort level chosen for
them; conflating "how big is the blast radius" with "how capable a model does it need" is a
category error the two pillars are deliberately kept apart to avoid.

What follows is model-agnostic and provider-agnostic on purpose. It is the machinery; the values
you plug in — your actual models, subscriptions, and quotas — are yours. A worked, real-world
instance is in [`model-routing-example.md`](model-routing-example.md), kept separate precisely
because it dates and this doesn't.

## Prime directive

**Route each task to the cheapest resource that clears its quality bar, sized to the task's
HARDEST requirement — not its average, and not its importance.** Importance ≠ difficulty: a
high-stakes one-line config change is still easy, and a throwaway prototype of a novel algorithm
is still hard. Size to the single hardest thing the task demands, because that is what a
too-weak choice will fail on.

The failure mode this prevents is defaulting every task to your best model "to be safe." That is
not safe — it is expensive, and on a rationed resource it is actively harmful, because it spends
a scarce allowance on work a cheaper tier would have finished correctly, leaving less of it for
the work that genuinely needs it.

## The scarcity gradient

Order your resources from most-rationed to most-abundant, and push each task as far toward the
abundant end as its quality bar allows. The exact ordering is personal — it depends on what you
pay for and what each subscription's quota economics are — but the shape is universal:

```
most scarce  ─────────────────────────────────────────────►  most abundant
 apex model      premium tiers        cheap/fast tiers       metered / off-subscription
 (rationed,      (capable, still       (mechanical,           (no quota pressure, but
  reserve it)     metered)             bulk, latency)          real per-token cost)
```

**The single biggest lever is moving an entire task off your most-rationed pool.** One task
routed to an abundant resource conserves more of the scarce one than any amount of effort-tuning
within it. Identify which of your resources is the true bottleneck — usually a weekly or 5-hour
allowance on your best model, not dollars — and treat keeping work *off* it as the primary
objective, with per-task tuning as secondary.

A subtlety worth stating: "cheapest" means cheapest on your *binding* constraint. If a model is
metered (real dollars) but off your rationed subscription pool, it may be the cheaper choice for
high-volume work even though it costs literal money, because it doesn't deplete the allowance
that actually limits you. Know which constraint binds before calling anything cheap.

## Two independent dials

Every routing decision sets two dials separately. Confusing them is the most common mistake.

### Dial 1 — capability tier (which model)

Size to the hardest requirement, per the prime directive. Reserve your apex model for the
**genuinely hard tail** — and be strict about what qualifies, because this is the dial that
spends your scarcest resource. A task earns the apex tier only when it is actually hard *and*
hits at least one of:

- **novel architecture / no prior art** — you are inventing the shape, not copying one;
- **high blast radius × low reversibility** — migrations, auth, concurrency, money, data: where
  an early wrong turn is expensive to undo;
- **large-context integration with many interacting invariants at once** — note the emphasis:
  raw context *size* is not a trigger, interaction complexity is. A huge but mechanical sweep is
  not apex work; a small change that must hold six invariants simultaneously is;
- **gnarly diagnosis after cheap fixes have already failed** — you've spent the easy attempts;
- **long-horizon plan where an early wrong turn compounds** — the cost of a mistake grows with
  distance from it.

**Precedence: a hard trigger wins.** If the work is genuinely hard, it goes to the apex tier even
when it would *also* suit a cheaper or more-abundant bucket (high volume, a terminal-heavy
workflow). Never trade correctness on hard work to conserve quota — conservation is for work
that is already beneath the hard bar. Everything below that bar is a routine routing decision:
established pattern → a mid tier; mechanical/bulk/codemod → a cheap tier; and so on.

### Dial 2 — reasoning effort (how hard it thinks)

Where your models expose an effort or thinking-depth control, it is a **separate** dial from
capability, and it tracks **reasoning depth, not importance**. Overthinking hurts easy tasks;
a lookup answered at maximum depth is slower and no better.

- lookup / mechanical → lowest
- well-specified → medium
- standard feature / complex → high (a sane default for real work)
- hardest architecture / debugging → maximum

Not every model has this dial. Cheaper/smaller models often have no effort setting at all — for
those, tier is the only lever, and passing an effort flag is silently ignored. Know which of your
models actually respond to it.

### How the two dials interact

The interaction is where routing gets its leverage:

- **Reasoning-deep but within a cheaper model's ceiling → raise EFFORT before tier.** A cheaper
  model at high effort often beats a premium model at low effort, for a fraction of the scarce
  quota. Exhaust the effort dial on a cheaper tier before escalating capability.
- **Capability-hard but shallow → raise TIER, leave effort low.** Some tasks need a smarter model
  but not deeper thinking; buy the capability without paying for depth you won't use.

### What the dials actually buy — measured

An empirical note, because the two dials are easy to conflate in the other direction too — by
assuming effort is a latency knob. In one multi-hour session of ~11 real dispatches across a
capability ladder, measuring per-turn responsiveness:

- **Tier separated cleanly.** Per-turn latency stepped ~0.6s (cheap) → ~3s (mid) → ~5s (premium),
  with no overlap between tiers.
- **Effort did not separate from noise.** A single mid-tier task run at *medium* landed dead
  center of the *high*-effort range for the same tier — the effort difference was smaller than
  the task-to-task spread within one effort level.
- **Wall-clock was driven by turn count, not thinking depth.** Task duration correlated with the
  number of tool-loop turns (which scales with task scope and how much the worker had to
  rediscover), not with the effort setting.

The lesson, stated generally: **if you want a task to go faster, drop a capability tier or
tighten the brief so it needs fewer turns — do not reach for lower effort expecting speed.**
Effort buys reasoning depth; it is not a throughput control, and lowering it trades quality for
a latency saving that may not exist. (n is small and the metric includes tool execution, so
treat the magnitudes as illustrative and the *ordering* as the finding.)

## Lever 2 — the intra-session delegation ladder

Routing is not only a per-task decision made once at dispatch. Inside a single session, the
driving model should continuously delegate *downward* — running cheap subtasks on cheaper
subagents rather than doing everything itself at its own tier.

**Keep on the driver's model:** planning, architecture, diagnosis, integration decisions, final
review, judgment calls — anything that needs the context the driver is already holding.

**Push down to a cheaper worker** (a subagent pinned to a cheaper model, a lightweight task
runner, a read-only search agent): boilerplate of an already-designed piece, bulk edits and
codemods, search-and-recon fan-out, test and fixture scaffolding, routine docs.

The test is mechanical: **self-contained instruction + cheaply verifiable → push down; needs the
driver's current reasoning → keep.** A premium model typing boilerplate a cheap one could produce
is the same overspend as defaulting every task to the apex tier, one level down.

## Harness is a capability choice, not a billing choice

If you drive models through more than one harness (a native CLI, a multi-provider runtime, a
plugin), note that **when a model costs the same regardless of how you drive it, the harness
decision is purely about capability.** Billing usually follows the *authentication path*, not the
harness: if two harnesses both authenticate into the same subscription, they spend the same
bucket, and you should choose between them on what each does better — not on a billing difference
that isn't there.

Decide harness on role:

- **Component** (an advisor, subagent, or step *inside* another session) → whichever harness can
  actually be embedded as a component; a native single-session CLI usually cannot.
- **Driver** (owns a task end-to-end) → the native CLI for the newest model features and tightest
  tool-use fidelity, or a multi-provider runtime when you want live review, stale-patch
  rejection, cross-provider composition, or supervised reliability more than the first-party edge.

## The framework as a decision tree

The same logic, drawn so gaps and precedence are visible at a glance. Model names are
placeholders — substitute your own ladder.

```
DIAL 1 — WHICH MODEL / TIER
 New task
    ├─ Trivial? lookup, one-liner, single Q&A ──────────────► cheapest tier
    └─ Not trivial. What is the HARDEST requirement?
       (size to hardest, not average — importance ≠ difficulty)
          ├─ Genuinely hard AND ≥1 of:
          │     • novel architecture / no prior art
          │     • high blast radius × low reversibility
          │     • many interacting invariants at once (size alone is NOT a trigger)
          │     • gnarly diagnosis, cheap fixes already failed
          │     • long-horizon plan, early wrong turn compounds
          │                                          ─────────► APEX tier, max effort
          │     PRECEDENCE: this branch wins even when a cheaper/abundant
          │     bucket would also fit. Never trade correctness for quota.
          └─ Beneath the apex bar:
                ├─ high mechanical VOLUME ───────────────────► cheap/abundant tier
                ├─ established pattern to copy ──────────────► mid tier
                ├─ well-specified, small blast radius ───────► mid tier, high effort
                └─ established pattern, deep reasoning ──────► premium tier

DIAL 2 — EFFORT (independent; reasoning depth, NOT importance; where supported)
   lookup/mechanical → low · well-specified → medium
   standard/complex  → high · hardest architecture/debug → max
   Reasoning-deep but within a cheaper model's ceiling → raise EFFORT before tier
   Capability-hard but shallow                         → raise TIER, leave effort low

DIAL 3 — HARNESS (capability only, when the model costs the same either way)
   COMPONENT inside another session → the harness that can be embedded
   DRIVER                           → native CLI (newest features, tool fidelity)
                                      or multi-provider runtime (live review,
                                      cross-provider, supervised reliability)

SEPARATE QUESTION — WHO EXECUTES / WHERE
   Not this framework. That is the git-hygiene tiers, keyed on DISCOVERY and
   VOLUME, never on diff size:
     know the exact change      → Tier 1  self-edit in a worktree
     needs discovery or volume  → Tier 2  worktree-isolated subagent
     real blast radius/parallel → Tier 3  dispatched worker
   Every change gets a worktree regardless. Model choice and execution locus
   are orthogonal — the two pillars answer different questions.
```

## Relationship to the git-hygiene pillar

The orchestrator described in the [playbook](git-hygiene-playbook.md) is where both pillars meet.
The session sitting in a repo's main checkout scopes each unit of work, then makes two
independent calls: **which tier executes it** (git hygiene — self-edit, isolated subagent, or
dispatched worker) and **which model + effort that execution uses** (this framework). It has the
task description and no stake in doing the work itself, so it is well-placed to size both. A
dispatched worker's model is its *ceiling*, not its floor: it too should delegate its own routine
subtasks downward per Lever 2.

Neither pillar's answer determines the other. A trivial change you already understand is Tier 1,
but if it touches money or auth you may still hand it to a premium model; a large mechanical sweep
is Tier 2 or 3 by volume, but runs on a cheap tier by capability. Keep the questions separate.

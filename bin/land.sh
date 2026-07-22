#!/bin/bash
# land.sh — land a branch into main: rebase, test, review, squash-merge, cleanup.
# Encodes the sequence in skills/land/SKILL.md; see docs/git-hygiene-playbook.md
# for the rationale behind each refusal below.
#
# Usage: bin/land.sh <branch> [--dry-run] [-m <message>]
#
# Run from the repo's PRIMARY checkout (never from inside a worktree). Entirely
# local — never fetches or pushes. Lands only onto a primary checkout that is
# on main/master (override with LAND_MAIN_BRANCH=<branch> if this checkout is
# meant to land onto something else).
#
# This can run for minutes (rebase + full test suite) — invoke it with a
# timeout comfortably longer than that, not a short default. See "Timeout"
# in skills/land/SKILL.md for what happens (and how to recover) if it's
# killed mid-run.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bin/land.sh <branch> [--dry-run] [-m <message>]

Run from the repo's primary checkout. Rebases <branch> onto main inside its
own worktree, runs the project's tests (or build/lint if there is no test
suite), prints the diff for review, then — unless --dry-run — squash-merges
into main and removes the worktree + branch.

--dry-run still rebases the branch and runs its tests (that's what makes the
diff and test result trustworthy); it is dry only for main: no merge, no
commit, no cleanup.
EOF
}

fail() { printf 'land.sh: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1" >&2; }

# check_main_clean [verbose] — fails if main has tracked modifications; with
# "verbose", also reports (non-fatally) any untracked files. Called once in
# preflight and again immediately before the squash-merge, since minutes of
# rebase+test can pass in between and main is not ours to leave polluted.
check_main_clean() {
  local mode="${1:-quiet}"
  local status tracked untracked
  status=$(git -C "$main_dir" status --porcelain)
  if [ -n "$status" ]; then
    tracked=$(printf '%s\n' "$status" | grep -v '^??' || true)
    untracked=$(printf '%s\n' "$status" | grep '^??' || true)
    if [ -n "$tracked" ]; then
      fail "main checkout has tracked modifications — commit or stash them before landing:
$tracked"
    fi
    if [ -n "$untracked" ] && [ "$mode" = "verbose" ]; then
      info "note: main checkout has untracked files (not fatal — squash-merge only stages the branch's changes):"
      info "$untracked"
    fi
  fi
}

# do_cleanup — remove the branch's worktree (herdr workspace if applicable)
# and delete the branch. Shared by the normal post-commit path and the
# empty-diff (nothing to land) path.
do_cleanup() {
  info "Step 5: cleanup"
  local workspace_id
  workspace_id=""
  if [ -n "${HERDR_ENV:-}" ] && command -v herdr >/dev/null 2>&1; then
    workspace_id=$(herdr worktree list --cwd "$main_dir" --json 2>/dev/null \
      | jq -r --arg p "$worktree_path" '.result.worktrees[]? | select(.path == $p) | .open_workspace_id // empty' 2>/dev/null || true)
  fi
  if [ -n "$workspace_id" ]; then
    info "removing herdr workspace $workspace_id"
    herdr worktree remove --workspace "$workspace_id" --force
  else
    info "removing worktree at $worktree_path"
    git -C "$main_dir" worktree remove "$worktree_path" --force
  fi
  git -C "$main_dir" branch -D "$branch"
}

# report_interrupted_state / on_exit / on_signal — signal & error safety net.
# `state` tracks how dangerous the moment is. NOT SIGKILL-proof (nothing is),
# but covers `set -e` errors and SIGINT/SIGTERM (what a harness timeout
# sends): it leaves things in as-recoverable-as-possible shape and explains
# how to finish or roll back by hand. The preflight wreckage checks above
# cover the SIGKILL case: if this never got to run, the next invocation
# refuses instead of compounding the mess.
#
# A plain `trap ... EXIT` is not enough on its own: bash defers a pending
# EXIT trap until any currently-running foreground command (e.g. `git
# commit` blocked in a slow hook) returns, but by then the signal has
# already been delivered and bash's default disposition for an untrapped
# TERM/INT can kill the process before the EXIT trap gets a chance to run.
# Trapping TERM/INT explicitly, reporting immediately, then re-raising the
# signal after clearing our own traps is the reliable pattern.
reported=0
report_interrupted_state() {
  [ "$reported" -eq 1 ] && return
  reported=1
  case "$state" in
    rebasing)
      info ""
      info "land.sh: interrupted while rebasing $branch — aborting the rebase to leave the worktree clean."
      git -C "$worktree_path" rebase --abort 2>/dev/null || true
      ;;
    merging)
      info ""
      info "land.sh: interrupted between 'git merge --squash' and 'git commit' — $main_dir may have a squash staged."
      info "Recover with: git -C \"$main_dir\" reset --merge   (git merge --abort will NOT work — squash never sets MERGE_HEAD)"
      info "Then re-run: bin/land.sh $branch"
      ;;
    committed)
      info ""
      info "land.sh: landing commit $land_sha is on $main_branch, but cleanup did not finish."
      info "Finish manually: git -C \"$main_dir\" worktree remove \"$worktree_path\" --force && git -C \"$main_dir\" branch -D $branch"
      ;;
    cleanup-empty)
      info ""
      info "land.sh: interrupted while cleaning up $branch after finding no effective changes to land — $main_branch was not touched."
      info "Finish manually: git -C \"$main_dir\" worktree remove \"$worktree_path\" --force && git -C \"$main_dir\" branch -D $branch"
      ;;
  esac
}
on_exit() {
  local ec=$?
  [ "$ec" -ne 0 ] && report_interrupted_state
  exit "$ec"
}
on_signal() {
  local sig="$1"
  report_interrupted_state
  trap - EXIT INT TERM
  kill -s "$sig" "$$"
}

branch=""
dry_run=0
message=""

main_dir=""
main_branch=""
worktree_path=""
base_sha=""
branch_sha=""
land_sha=""
state="preflight"
trap on_exit EXIT
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -m) message="${2:?land.sh: -m requires a message}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "land.sh: unknown option: $1" >&2; usage; exit 1 ;;
    *)
      [ -z "$branch" ] || { echo "land.sh: unexpected argument: $1" >&2; usage; exit 1; }
      branch="$1"; shift ;;
  esac
done
[ -n "$branch" ] || { usage; exit 1; }

# ---- Step 0: preflight -----------------------------------------------------

main_dir=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not inside a git repository"
main_gitdir=$(git -C "$main_dir" rev-parse --absolute-git-dir)
main_common=$(git -C "$main_dir" rev-parse --path-format=absolute --git-common-dir)
[ "$main_gitdir" = "$main_common" ] || fail "run bin/land.sh from the repo's primary checkout, not a worktree"

if [ -f "$main_gitdir/SQUASH_MSG" ] || [ -f "$main_gitdir/MERGE_HEAD" ] || [ -f "$main_gitdir/CHERRY_PICK_HEAD" ] \
  || [ -d "$main_gitdir/rebase-merge" ] || [ -d "$main_gitdir/rebase-apply" ]; then
  fail "main checkout has an in-progress git operation (likely a previous land.sh run was interrupted mid-merge) — recover with: git -C $main_dir reset --merge   (NOT 'git merge --abort' — squash merges never set MERGE_HEAD). Then re-run: bin/land.sh $branch"
fi

main_branch=$(git -C "$main_dir" branch --show-current)
[ -n "$main_branch" ] || fail "main checkout is not on a branch (detached HEAD?)"
case "$main_branch" in
  main|master) : ;;
  *)
    [ -n "${LAND_MAIN_BRANCH:-}" ] && [ "$main_branch" = "$LAND_MAIN_BRANCH" ] || \
      fail "primary checkout is on '$main_branch', not main/master — land.sh refuses to land onto anything else (this is what stops a landing from silently going to the wrong branch). Switch the primary checkout to main, or set LAND_MAIN_BRANCH=$main_branch to explicitly allow landing onto it."
    ;;
esac
[ "$branch" != "$main_branch" ] || fail "cannot land $main_branch onto itself"

worktree_path=$(git -C "$main_dir" worktree list --porcelain | awk -v want="refs/heads/$branch" '
  /^worktree / { path = substr($0, 10) }
  /^branch /   { if ($2 == want) { print path; found = 1 } }
  END { exit !found }
') || true

if [ -z "$worktree_path" ]; then
  # A worktree paused mid-rebase reports "detached" instead of "branch ..."
  # in porcelain output (the branch itself is checked out nowhere until the
  # rebase finishes), so the lookup above finds nothing for it. Scan every
  # worktree's rebase state before concluding there simply is no worktree.
  while IFS= read -r candidate; do
    candidate_gitdir=$(git -C "$candidate" rev-parse --absolute-git-dir 2>/dev/null) || continue
    for head_name_file in "$candidate_gitdir/rebase-merge/head-name" "$candidate_gitdir/rebase-apply/head-name"; do
      if [ -f "$head_name_file" ] && [ "$(cat "$head_name_file")" = "refs/heads/$branch" ]; then
        fail "branch worktree at $candidate has a rebase already in progress for $branch — land.sh refuses to touch it (it would abort in-progress work that isn't its own). Finish or abort it yourself inside the worktree, then re-run: bin/land.sh $branch"
      fi
    done
  done < <(git -C "$main_dir" worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')
  fail "no worktree found for branch $branch (git worktree list)"
fi

worktree_gitdir=$(git -C "$worktree_path" rev-parse --absolute-git-dir)
if [ -d "$worktree_gitdir/rebase-merge" ] || [ -d "$worktree_gitdir/rebase-apply" ] \
  || [ -f "$worktree_gitdir/MERGE_HEAD" ] || [ -f "$worktree_gitdir/CHERRY_PICK_HEAD" ]; then
  fail "branch worktree at $worktree_path already has a rebase/merge/cherry-pick in progress — land.sh refuses to touch it (it would abort in-progress work that isn't its own). Finish or abort it yourself inside the worktree, then re-run: bin/land.sh $branch"
fi

if [ -n "$(git -C "$worktree_path" status --porcelain)" ]; then
  fail "branch worktree at $worktree_path is dirty — commit your work first (WIP commits are fine, squash erases them)"
fi

check_main_clean verbose

# ---- Step 1: rebase --------------------------------------------------------

info "Step 1: rebase $branch onto $main_branch"
base_sha=$(git -C "$main_dir" rev-parse "refs/heads/$main_branch")

state=rebasing
if ! git -C "$worktree_path" rebase "refs/heads/$main_branch"; then
  git -C "$worktree_path" rebase --abort 2>/dev/null || true
  state=idle
  fail "rebase of $branch onto $main_branch hit conflicts (aborted, worktree left clean). Resolve them inside the worktree ($worktree_path) — never on main — then re-run: bin/land.sh $branch"
fi
state=idle
# Pin the tested SHA now: everything from here on lands exactly this commit,
# never whatever the branch ref happens to point to later.
branch_sha=$(git -C "$worktree_path" rev-parse HEAD)

# ---- Step 2: tests ----------------------------------------------------------

tests_ran="no test suite"
if [ -f "$worktree_path/run-tests.sh" ]; then
  info "Step 2: running run-tests.sh"
  ( cd "$worktree_path" && ./run-tests.sh )
  tests_ran="run-tests.sh"
elif [ -f "$worktree_path/package.json" ] && jq -e '.scripts.test' "$worktree_path/package.json" >/dev/null 2>&1; then
  info "Step 2: running npm test"
  ( cd "$worktree_path" && npm test )
  tests_ran="npm test"
elif [ -f "$worktree_path/Makefile" ] && grep -qE '^test:' "$worktree_path/Makefile"; then
  info "Step 2: running make test"
  ( cd "$worktree_path" && make test )
  tests_ran="make test"
elif [ -f "$worktree_path/go.mod" ]; then
  info "Step 2: running go test ./..."
  ( cd "$worktree_path" && go test ./... )
  tests_ran="go test ./..."
elif [ -f "$worktree_path/Cargo.toml" ]; then
  info "Step 2: running cargo test"
  ( cd "$worktree_path" && cargo test )
  tests_ran="cargo test"
elif command -v pytest >/dev/null 2>&1 && { [ -f "$worktree_path/pytest.ini" ] || [ -f "$worktree_path/pyproject.toml" ] \
  || [ -f "$worktree_path/setup.cfg" ] || [ -f "$worktree_path/tox.ini" ]; }; then
  info "Step 2: running pytest"
  ( cd "$worktree_path" && pytest )
  tests_ran="pytest"
elif [ -f "$worktree_path/gradlew" ]; then
  info "Step 2: running ./gradlew test"
  ( cd "$worktree_path" && ./gradlew test )
  tests_ran="./gradlew test"
elif { [ -f "$worktree_path/build.gradle" ] || [ -f "$worktree_path/build.gradle.kts" ]; } && command -v gradle >/dev/null 2>&1; then
  info "Step 2: running gradle test"
  ( cd "$worktree_path" && gradle test )
  tests_ran="gradle test"
elif [ -f "$worktree_path/mvnw" ]; then
  info "Step 2: running ./mvnw test"
  ( cd "$worktree_path" && ./mvnw test )
  tests_ran="./mvnw test"
elif [ -f "$worktree_path/pom.xml" ] && command -v mvn >/dev/null 2>&1; then
  info "Step 2: running mvn test"
  ( cd "$worktree_path" && mvn test )
  tests_ran="mvn test"
else
  info "Step 2: no recognized test suite found"
  if [ -f "$worktree_path/package.json" ] && jq -e '.scripts.build' "$worktree_path/package.json" >/dev/null 2>&1; then
    info "  falling back to: npm run build"
    ( cd "$worktree_path" && npm run build )
    tests_ran="no test suite (ran npm run build)"
  elif [ -f "$worktree_path/package.json" ] && jq -e '.scripts.lint' "$worktree_path/package.json" >/dev/null 2>&1; then
    info "  falling back to: npm run lint"
    ( cd "$worktree_path" && npm run lint )
    tests_ran="no test suite (ran npm run lint)"
  elif [ -f "$worktree_path/Makefile" ] && grep -qE '^(build|lint):' "$worktree_path/Makefile"; then
    fallback_target=$(grep -oE '^(build|lint):' "$worktree_path/Makefile" | head -1 | tr -d ':')
    info "  falling back to: make $fallback_target"
    ( cd "$worktree_path" && make "$fallback_target" )
    tests_ran="no test suite (ran make $fallback_target)"
  else
    info "  no build/lint fallback found either"
    info "=================================================================="
    info "WARNING: landing $branch with NO verification at all — no test suite,"
    info "build, or lint step was found or run. $main_branch will receive untested code."
    info "=================================================================="
  fi
fi

# ---- Step 3: review ---------------------------------------------------------

info "Step 3: diff $main_branch...HEAD"
diff_output=$(git -C "$worktree_path" diff "refs/heads/$main_branch...HEAD")
printf '%s\n' "$diff_output"

if [ "$dry_run" -eq 1 ]; then
  info "--dry-run: stopping after review (no merge, no cleanup)."
  exit 0
fi

if [ -z "$diff_output" ]; then
  info "$branch has no effective changes vs $main_branch after rebase — nothing to land."
  state=cleanup-empty
  do_cleanup
  state=idle
  info "cleaned up $branch (nothing was committed to $main_branch)."
  exit 0
fi

# ---- Step 4: race check, then land ------------------------------------------

info "Step 4: race check"
current_main_sha=$(git -C "$main_dir" rev-parse "refs/heads/$main_branch")
if [ "$current_main_sha" != "$base_sha" ]; then
  fail "main advanced since rebase (was $base_sha, now $current_main_sha) — another branch landed. Re-run: bin/land.sh $branch"
fi

current_branch_sha=$(git -C "$worktree_path" rev-parse "refs/heads/$branch")
if [ "$current_branch_sha" != "$branch_sha" ]; then
  fail "$branch advanced from $branch_sha to $current_branch_sha after tests ran — the new commit(s) are untested. Re-run: bin/land.sh $branch"
fi

type="chore"; slug="$branch"
case "$branch" in
  feat/*|fix/*|chore/*) type="${branch%%/*}"; slug="${branch#*/}" ;;
esac
default_subject="$type: land $slug"
commit_msg="${message:-$default_subject}"
case "$tests_ran" in
  "no test suite"*) commit_msg="$commit_msg

$tests_ran" ;;
esac

# Re-check main's cleanliness right here, immediately before the merge — the
# preflight check above can be minutes stale by now, and this is the last
# chance to catch content someone staged on main while rebase+tests ran.
check_main_clean quiet

info "Step 4: squash-merging $branch into $main_branch"
state=merging
if ! git -C "$main_dir" merge --squash "$branch_sha"; then
  state=idle
  fail "squash-merge conflicted unexpectedly after a clean rebase — resolve in $main_dir manually (git -C $main_dir reset --merge to cancel); do not leave main mid-merge."
fi
git -C "$main_dir" commit -m "$commit_msg"
land_sha=$(git -C "$main_dir" rev-parse HEAD)
state=idle

# Belt-and-suspenders: confirm the landing commit's diff is exactly the
# branch's diff. If main picked up anything else (a TOCTOU between the
# check above and the merge, a hook side effect, anything), roll back the
# commit we just made — it's local, unpublished, and ours to undo — rather
# than let unreviewed content sit on main.
expected_diff=$(git -C "$main_dir" diff "$base_sha" "$branch_sha")
actual_diff=$(git -C "$main_dir" diff "$base_sha" "$land_sha")
if [ "$actual_diff" != "$expected_diff" ]; then
  git -C "$main_dir" reset --hard "$base_sha"
  fail "landing commit $land_sha did not exactly match $branch's changes (main picked up unexpected content) — rolled back $main_branch to $base_sha. This should not happen; re-run bin/land.sh $branch."
fi

# ---- Step 5: cleanup ---------------------------------------------------------

state=committed
do_cleanup
state=idle

# ---- Step 6: report ----------------------------------------------------------

printf '%s\n' "$land_sha"

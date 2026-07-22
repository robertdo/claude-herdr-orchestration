#!/bin/bash
# land.sh — land a finished branch onto main as one squash commit.
#
# Usage: bin/land.sh <branch> [--dry-run] [--no-tests] [--check <cmd>] [-m <msg>]
#
# Run from the repo's PRIMARY checkout (never from inside a worktree). Entirely
# local — never fetches or pushes. Lands only onto a primary checkout that is on
# main/master (override with LAND_MAIN_BRANCH=<branch> if this checkout is meant
# to land onto something else).
#
# HOW IT LANDS, AND WHY THAT SHAPE. The landing commit is built as an object —
#
#     candidate = git commit-tree <branch's tree> -p <main's tip>
#
# — and then fast-forwarded into place. The primary checkout's index and working
# tree are never touched. So there is no window in which main holds a half-staged
# squash, nothing to verify after the fact (the candidate's tree IS the tested
# branch tree, by construction — dirty content on main cannot leak into it), and
# nothing to roll back: until the final `merge --ff-only` this script has mutated
# nothing and can be killed at any point with zero cleanup. If main advanced
# concurrently the fast-forward simply fails, on its own.
#
# IT DOES NOT REBASE. A branch that does not already contain main is refused,
# with the command to run. Rebasing is a preparation step you do in the worktree;
# keeping it out of here is what removes the abort/recovery machinery entirely.
#
# REVIEW IS RETROSPECTIVE. Without --dry-run the diff is printed and the landing
# proceeds in the same run — you are reading what just landed, not approving what
# is about to. land.sh is called non-interactively by agents, so it never prompts.
# --dry-run is the real gate: it builds and prints the candidate and stops, and
# the candidate SHA it prints stays landable by hand (`git merge --ff-only <sha>`)
# for as long as main has not moved.
#
# OUTPUT CONTRACT. stdout carries the landing commit's SHA and nothing else —
# callers read it. Everything a human reads (progress, the review diff, the check
# command's own output) goes to stderr.
#
# HOOKS AND SIGNING. `git commit-tree` does not run the repo's `pre-commit` or
# `commit-msg` hooks. The branch's own commits already ran `pre-commit` over this
# exact tree, so content validation is not lost; the landing *message* is the real
# gap. The commit is signed only when `commit.gpgsign` is set. See skills/land/SKILL.md.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bin/land.sh <branch> [--dry-run] [--no-tests] [--check <cmd>] [-m <message>]

Run from the repo's primary checkout. Verifies <branch>, builds the landing
commit as an object, prints its diff, then — unless --dry-run — fast-forwards
main onto it and removes the worktree and branch.

  --dry-run     build and print the candidate; never touch main, never clean up
  --no-tests    land with no verification (required when none is detected)
  --check CMD   run CMD in the worktree instead of auto-detecting (env: LAND_CHECK_CMD)
  -m MESSAGE    landing commit message

land.sh never rebases: if <branch> does not already contain main it refuses and
prints the command to run.
EOF
}

fail() { printf 'land.sh: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1" >&2; }

# detect_check — echo the project's verification command, or return 1 if there
# is none. Detection order is most-specific-first; each entry names a command
# rather than running one, so the caller runs it exactly once, in the worktree.
detect_check() {
  local w="$worktree_path"
  if   [ -f "$w/run-tests.sh" ]; then echo "./run-tests.sh"
  elif [ -f "$w/package.json" ] && jq -e '.scripts.test' "$w/package.json" >/dev/null 2>&1; then echo "npm test"
  elif [ -f "$w/Makefile" ] && grep -qE '^test:' "$w/Makefile"; then echo "make test"
  elif [ -f "$w/go.mod" ]; then echo "go test ./..."
  elif [ -f "$w/Cargo.toml" ]; then echo "cargo test"
  elif command -v pytest >/dev/null 2>&1 && { [ -f "$w/pytest.ini" ] || [ -f "$w/pyproject.toml" ] \
    || [ -f "$w/setup.cfg" ] || [ -f "$w/tox.ini" ]; }; then echo "pytest"
  elif [ -f "$w/gradlew" ]; then echo "./gradlew test"
  elif { [ -f "$w/build.gradle" ] || [ -f "$w/build.gradle.kts" ]; } && command -v gradle >/dev/null 2>&1; then echo "gradle test"
  elif [ -f "$w/mvnw" ]; then echo "./mvnw test"
  elif [ -f "$w/pom.xml" ] && command -v mvn >/dev/null 2>&1; then echo "mvn test"
  else return 1
  fi
}

# cleanup — teardown AFTER the landing is published, so it is best-effort by
# definition: the change is on main whether or not this succeeds. It refuses to
# delete a branch that advanced past the SHA that was landed, so commits that
# never reached main are never destroyed.
cleanup() {
  local ws="" tip=""
  if [ -n "${HERDR_ENV:-}" ] && command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ws=$(herdr worktree list --cwd "$main_dir" --json 2>/dev/null \
      | jq -r --arg p "$worktree_path" '.result.worktrees[]? | select(.path == $p) | .open_workspace_id // empty' 2>/dev/null || true)
  fi
  if [ -n "$ws" ]; then
    herdr worktree remove --workspace "$ws" --force \
      || info "note: could not remove herdr workspace $ws — remove it with: herdr worktree remove --workspace $ws --force"
  else
    git -C "$main_dir" worktree remove "$worktree_path" --force \
      || info "note: could not remove worktree — remove it with: git -C \"$main_dir\" worktree remove \"$worktree_path\" --force"
  fi
  tip=$(git -C "$main_dir" rev-parse --verify --quiet "refs/heads/$branch" || true)
  if [ -z "$tip" ]; then
    :
  elif [ "$tip" != "$branch_sha" ]; then
    info "note: NOT deleting $branch — it advanced to $tip after $branch_sha was landed, so those commits are not on $main_branch."
  else
    git -C "$main_dir" branch -D "$branch" >/dev/null \
      || info "note: could not delete $branch — delete it with: git -C \"$main_dir\" branch -D $branch"
  fi
}

branch=""; dry_run=0; message=""; no_tests=0; check_cmd="${LAND_CHECK_CMD:-}"; check_explicit=0
if [ -n "$check_cmd" ]; then check_explicit=1; fi

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --no-tests) no_tests=1; shift ;;
    --check) check_cmd="${2:?land.sh: --check requires a command}"; check_explicit=1; shift 2 ;;
    -m) message="${2:?land.sh: -m requires a message}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "land.sh: unknown option: $1" >&2; usage; exit 1 ;;
    *) [ -z "$branch" ] || { echo "land.sh: unexpected argument: $1" >&2; usage; exit 1; }
       branch="$1"; shift ;;
  esac
done
[ -n "$branch" ] || { usage; exit 1; }
[ "$no_tests" -eq 0 ] || [ "$check_explicit" -eq 0 ] || fail "--no-tests and an explicit check command are mutually exclusive"

# ---- preflight ---------------------------------------------------------------

main_dir=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not inside a git repository"
[ "$(git -C "$main_dir" rev-parse --absolute-git-dir)" = "$(git -C "$main_dir" rev-parse --path-format=absolute --git-common-dir)" ] \
  || fail "run bin/land.sh from the repo's primary checkout, not a worktree"

main_branch=$(git -C "$main_dir" branch --show-current)
[ -n "$main_branch" ] || fail "main checkout is not on a branch (detached HEAD?)"
case "$main_branch" in
  main|master) : ;;
  *) [ -n "${LAND_MAIN_BRANCH:-}" ] && [ "$main_branch" = "$LAND_MAIN_BRANCH" ] || fail \
       "primary checkout is on '$main_branch', not main/master — land.sh refuses to land onto anything else (this is what stops a landing from silently going to the wrong branch). Switch the primary checkout to main, or set LAND_MAIN_BRANCH=$main_branch to allow it explicitly." ;;
esac
[ "$branch" != "$main_branch" ] || fail "cannot land $main_branch onto itself"

# Refs are qualified as refs/heads/<name> everywhere so a same-named tag can
# never be resolved in a branch's place.
branch_sha=$(git -C "$main_dir" rev-parse --verify --quiet "refs/heads/$branch") \
  || fail "no branch named $branch"
base_sha=$(git -C "$main_dir" rev-parse --verify "refs/heads/$main_branch")

worktree_path=$(git -C "$main_dir" worktree list --porcelain | awk -v want="refs/heads/$branch" '
  /^worktree / { path = substr($0, 10) }
  /^branch /   { if ($2 == want) { print path; found = 1 } }
  END { exit !found }
') || fail "no worktree found for branch $branch (git worktree list). A worktree paused mid-rebase reports as detached and will not be found here — finish or abort that rebase first."

[ -z "$(git -C "$worktree_path" status --porcelain)" ] \
  || fail "branch worktree at $worktree_path is dirty — commit your work first (WIP commits are fine, squash erases them)"

# Tracked modifications in main are fatal; untracked files are reported only.
# They cannot reach the landing commit (its tree comes from the branch, not from
# main's index) but they are not ours to clobber, and a fast-forward that would
# overwrite one will refuse anyway.
main_status=$(git -C "$main_dir" status --porcelain)
if [ -n "$main_status" ]; then
  tracked=$(printf '%s\n' "$main_status" | grep -v '^??' || true)
  untracked=$(printf '%s\n' "$main_status" | grep '^??' || true)
  [ -z "$tracked" ] || fail "main checkout has tracked modifications — commit or stash them before landing:
$tracked"
  [ -z "$untracked" ] || { info "note: main checkout has untracked files (not fatal — they cannot enter the landing commit):"; info "$untracked"; }
fi

# ---- 1: the branch must already contain main ---------------------------------

git -C "$main_dir" merge-base --is-ancestor "$base_sha" "$branch_sha" || fail \
  "$branch does not contain $main_branch ($base_sha) — land.sh does not rebase. Update the branch in its own worktree, then re-run:
  git -C \"$worktree_path\" rebase refs/heads/$main_branch
  bin/land.sh $branch"

if [ "$(git -C "$main_dir" rev-parse "$branch_sha^{tree}")" = "$(git -C "$main_dir" rev-parse "$base_sha^{tree}")" ]; then
  info "$branch has no effective changes vs $main_branch — nothing to land."
  [ "$dry_run" -eq 0 ] || exit 0
  cleanup || info "note: cleanup did not finish."
  info "cleaned up $branch ($main_branch was not touched)."
  exit 0
fi

# ---- 2: verify ----------------------------------------------------------------

if [ "$no_tests" -eq 1 ]; then
  info "Step 2: --no-tests — landing with NO verification at all"
elif [ "$check_explicit" -eq 0 ]; then
  check_cmd=$(detect_check) || fail \
    "no test suite, and no --check command given — land.sh will not silently land unverified code onto $main_branch. Either give it something to run (--check '<cmd>', or LAND_CHECK_CMD=...), or state the omission deliberately with --no-tests."
fi
if [ "$no_tests" -eq 0 ]; then
  info "Step 2: running $check_cmd"
  ( cd "$worktree_path" && bash -c "$check_cmd" ) >&2
fi

# The branch is not ours alone: anything committed while the suite ran is
# untested, and landing it would silently launder it past the check above.
tip=$(git -C "$main_dir" rev-parse --verify "refs/heads/$branch")
[ "$tip" = "$branch_sha" ] || fail "$branch advanced from $branch_sha to $tip while land.sh ran — the new commit(s) are unverified. Re-run: bin/land.sh $branch"

# ---- 3: build the candidate ---------------------------------------------------

kind="chore"; slug="$branch"
case "$branch" in feat/*|fix/*|chore/*) kind="${branch%%/*}"; slug="${branch#*/}" ;; esac
commit_msg="${message:-$kind: land $slug}"
[ "$no_tests" -eq 0 ] || commit_msg="$commit_msg

Landed with --no-tests: no verification was run."

# commit-tree builds the object and nothing else — no index, no working tree, no
# ref. Everything above this line is still abortable with zero cleanup, and so is
# this. -S only when the repo asks for signed commits, since commit-tree does not
# read commit.gpgsign itself the way `git commit` does.
tree=$(git -C "$main_dir" rev-parse "$branch_sha^{tree}")
if [ "$(git -C "$main_dir" config --bool --get commit.gpgsign 2>/dev/null || echo false)" = "true" ]; then
  candidate=$(printf '%s\n' "$commit_msg" | git -C "$main_dir" commit-tree -S "$tree" -p "$base_sha")
else
  candidate=$(printf '%s\n' "$commit_msg" | git -C "$main_dir" commit-tree "$tree" -p "$base_sha")
fi

info "Step 3: diff $main_branch..$branch (candidate $candidate)"
git -C "$main_dir" --no-pager diff "$base_sha" "$candidate" >&2

if [ "$dry_run" -eq 1 ]; then
  info "--dry-run: candidate $candidate built and not landed. $main_branch is untouched and nothing needs cleaning up."
  info "To land exactly this, while $main_branch is still at $base_sha: git -C \"$main_dir\" merge --ff-only $candidate"
  exit 0
fi

# ---- 4: publish ----------------------------------------------------------------

info "Step 4: fast-forwarding $main_branch onto the candidate (review above is retrospective)"
git -C "$main_dir" merge --ff-only "$candidate" >/dev/null || fail \
  "fast-forward of $main_branch onto $candidate failed — $main_branch moved or its working tree is in the way. Nothing was landed and nothing needs cleaning up; re-run bin/land.sh $branch once $branch contains the new $main_branch."

# ---- 5: cleanup (best-effort; the landing already succeeded) --------------------

info "Step 5: cleanup"
cleanup || info "note: cleanup did not finish — the landing SUCCEEDED regardless ($candidate is on $main_branch)."

printf '%s\n' "$candidate"

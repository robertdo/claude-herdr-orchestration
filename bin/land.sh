#!/bin/bash
# land.sh — land a branch into main: rebase, test, review, squash-merge, cleanup.
# Encodes the sequence in skills/land/SKILL.md; see docs/git-hygiene-playbook.md
# for the rationale behind each refusal below.
#
# Usage: bin/land.sh <branch> [--dry-run] [-m <message>]
#
# Run from the repo's PRIMARY checkout (never from inside a worktree). Works
# with or without a git remote.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bin/land.sh <branch> [--dry-run] [-m <message>]

Run from the repo's primary checkout. Rebases <branch> onto main inside its
own worktree, runs the project's tests (or build/lint if there is no test
suite), prints the diff for review, then — unless --dry-run — squash-merges
into main and removes the worktree + branch.
EOF
}

fail() { printf 'land.sh: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1" >&2; }

branch=""
dry_run=0
message=""

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

main_branch=$(git -C "$main_dir" branch --show-current)
[ -n "$main_branch" ] || fail "main checkout is not on a branch (detached HEAD?)"
[ "$branch" != "$main_branch" ] || fail "cannot land $main_branch onto itself"

worktree_path=$(git -C "$main_dir" worktree list --porcelain | awk -v want="refs/heads/$branch" '
  /^worktree / { path = $2 }
  /^branch /   { if ($2 == want) { print path; found = 1 } }
  END { exit !found }
') || fail "no worktree found for branch $branch (git worktree list)"

if [ -n "$(git -C "$worktree_path" status --porcelain)" ]; then
  fail "branch worktree at $worktree_path is dirty — commit your work first (WIP commits are fine, squash erases them)"
fi

main_status=$(git -C "$main_dir" status --porcelain)
if [ -n "$main_status" ]; then
  main_tracked=$(printf '%s\n' "$main_status" | grep -v '^??' || true)
  main_untracked=$(printf '%s\n' "$main_status" | grep '^??' || true)
  if [ -n "$main_tracked" ]; then
    fail "main checkout has tracked modifications — commit or stash them before landing:
$main_tracked"
  fi
  if [ -n "$main_untracked" ]; then
    info "note: main checkout has untracked files (not fatal — squash-merge only stages the branch's changes):"
    info "$main_untracked"
  fi
fi

# ---- Step 1: rebase --------------------------------------------------------

info "Step 1: rebase $branch onto $main_branch"
base_sha=$(git -C "$main_dir" rev-parse "$main_branch")

if git -C "$main_dir" remote | grep -q .; then
  git -C "$worktree_path" fetch --quiet
fi

if ! git -C "$worktree_path" rebase "$main_branch"; then
  git -C "$worktree_path" rebase --abort 2>/dev/null || true
  fail "rebase of $branch onto $main_branch hit conflicts (aborted, worktree left clean). Resolve them inside the worktree ($worktree_path) — never on main — then re-run: bin/land.sh $branch"
fi

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
else
  info "Step 2: no test suite found"
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
  fi
fi

# ---- Step 3: review ---------------------------------------------------------

info "Step 3: diff $main_branch...HEAD"
git -C "$worktree_path" diff "$main_branch...HEAD"

if [ "$dry_run" -eq 1 ]; then
  info "--dry-run: stopping after review (no merge, no cleanup)"
  exit 0
fi

# ---- Step 4: race check, then land ------------------------------------------

info "Step 4: race check"
current_main_sha=$(git -C "$main_dir" rev-parse "$main_branch")
if [ "$current_main_sha" != "$base_sha" ]; then
  fail "main advanced since rebase (was $base_sha, now $current_main_sha) — another branch landed. Re-run: bin/land.sh $branch"
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

info "Step 4: squash-merging $branch into $main_branch"
if ! git -C "$main_dir" merge --squash "$branch"; then
  fail "squash-merge conflicted unexpectedly after a clean rebase — resolve in $main_dir manually (git -C $main_dir merge --abort to cancel); do not leave main mid-merge."
fi
git -C "$main_dir" commit -m "$commit_msg"
land_sha=$(git -C "$main_dir" rev-parse HEAD)

# ---- Step 5: cleanup ---------------------------------------------------------

info "Step 5: cleanup"
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

# ---- Step 6: report ----------------------------------------------------------

printf '%s\n' "$land_sha"

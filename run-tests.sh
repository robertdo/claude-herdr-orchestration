#!/bin/bash
# run-tests.sh — this repo's own test suite.
#
#   ./run-tests.sh            run everything; non-zero exit on any failure
#   LAND_TESTS_KEEP=1 ./run-tests.sh   keep the throwaway fixtures for inspection
#
# Two parts: static checks over every shell script in the repo, then a
# behavioural suite for bin/land.sh that builds throwaway git repos under
# $TMPDIR and lands branches in them for real. It never touches a repo outside
# $TMPDIR, never reaches the network, and removes its fixtures on exit.
#
# bin/land.sh looks for run-tests.sh first in its own test-discovery ladder, so
# this file is what makes landings in this repo actually verify something.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
LAND="$REPO_ROOT/bin/land.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/land-tests.XXXXXX")
SETUPLOG="$ROOT/setup.log"
EMPTY_TEMPLATE="$ROOT/empty-template"
mkdir -p "$EMPTY_TEMPLATE"
SECONDS=0

# Fixture repos are disposable and self-contained; drop them unless asked not to.
cleanup_fixtures() {
  if [ "${LAND_TESTS_KEEP:-0}" = "1" ]; then
    printf 'fixtures kept at: %s\n' "$ROOT"
  elif [ -n "${ROOT:-}" ] && [ -d "$ROOT" ]; then
    chmod -R u+w "$ROOT" 2>/dev/null
    rm -rf "$ROOT"
  fi
}
trap cleanup_fixtures EXIT

# land.sh only consults herdr when HERDR_ENV is set; keep the suite on the plain
# git path so it behaves identically inside and outside a herdr session.
unset HERDR_ENV

pass=0; failn=0; skipped=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { failn=$((failn+1)); printf '  FAIL  %s\n' "$1"; }
skip() { skipped=$((skipped+1)); printf '  skip  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

# ---------------------------------------------------------------------------
echo "== 0. static checks =="
# ---------------------------------------------------------------------------

# The per-repo git hook has no .sh suffix (git requires the exact name
# `reference-transaction`), so it is named explicitly rather than globbed.
shell_scripts=$(cd "$REPO_ROOT" && ls ./*.sh ./bin/*.sh ./hooks/*.sh ./hooks/git-repo/reference-transaction 2>/dev/null)
check "found the repo's shell scripts" "$([ -n "$shell_scripts" ] && echo yes)" "yes"

# The guard rejects any move of main that is not a one-commit fast-forward, so a
# wrong version of it installed HERE would reject the very landing needed to fix
# it. Installing it into this repo is a deliberate decision, not a side effect of
# running the tests; everything below installs it only into $ROOT fixtures.
own_hooks=$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/hooks
check "the guard is NOT installed into this repository" \
  "$([ -e "$own_hooks/reference-transaction" ] && echo installed || echo absent)" "absent"

for f in $shell_scripts; do
  check "bash -n $f" "$(cd "$REPO_ROOT" && /bin/bash -n "$f" 2>&1 | head -1)" ""
  check "executable: $f" "$([ -x "$REPO_ROOT/${f#./}" ] && echo yes || echo no)" "yes"
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in $shell_scripts; do
    # SC1010 fires falsely on bin/herdr-watch-agent.sh, which loops over the
    # literal word "done" as a status value. That file is not this change's to
    # edit; the durable fix is a `# shellcheck disable=SC1010` directive in it.
    excl=""
    case "$f" in */herdr-watch-agent.sh) excl="-e SC1010" ;; esac
    # shellcheck disable=SC2086  # $excl is a deliberate word-split flag pair
    check "shellcheck $f" "$(cd "$REPO_ROOT" && shellcheck -S warning $excl "$f" 2>&1 | head -1)" ""
  done
else
  skip "shellcheck (not installed)"
fi

# ---------------------------------------------------------------------------
# bin/land.sh behaviour. Every fixture is a fresh repo under $ROOT with a
# primary checkout on main and a linked worktree holding branch feat/x, one
# commit ahead. Config is pinned per repo (identity, signing, hooks path, empty
# init template) so the suite is unaffected by the developer's global git config.
# ---------------------------------------------------------------------------

mkrepo() {
  local d repo wt
  d=$(mktemp -d "$ROOT/r.XXXXXX")
  repo="$d/repo"; wt="$d/wt"
  {
    git init -q -b main --template="$EMPTY_TEMPLATE" "$repo"
    git -C "$repo" config user.email dev@example.com
    git -C "$repo" config user.name 'Dev Example'
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config core.hooksPath "$repo/.git/hooks"
    mkdir -p "$repo/.git/hooks"
    echo base > "$repo/file.txt"
    if [ "${1:-}" != "--no-suite" ]; then
      printf '#!/bin/sh\necho SUITE-RAN\n' > "$repo/run-tests.sh"
      chmod +x "$repo/run-tests.sh"
    fi
    git -C "$repo" add -A
    git -C "$repo" commit -qm init
    git -C "$repo" worktree add -q -b feat/x "$wt"
    echo changed > "$wt/file.txt"
    git -C "$wt" add -A
    git -C "$wt" commit -qm work
  } >>"$SETUPLOG" 2>&1 || { echo "FIXTURE SETUP FAILED (see $SETUPLOG)" >&2; exit 99; }
  echo "$repo"
}
wtof() { echo "${1%/repo}/wt"; }
run()  { local d="$1"; shift; ( cd "$d" && bash "$LAND" "$@" ); }

echo "== 1. a successful landing =="
repo=$(mkrepo); wt=$(wtof "$repo")
before=$(git -C "$repo" rev-parse main)
btip=$(git -C "$repo" rev-parse refs/heads/feat/x)
btree=$(git -C "$repo" rev-parse 'refs/heads/feat/x^{tree}')
out=$(run "$repo" feat/x 2>"$ROOT/err1"); rc=$?
check "exit 0" "$rc" "0"
check "stdout is exactly one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
check "stdout is the landing sha" "$out" "$(git -C "$repo" rev-parse main)"
check "exactly one commit added" "$(git -C "$repo" rev-list --count "$before"..main)" "1"
check "parent is the pinned base" "$(git -C "$repo" rev-parse main^)" "$before"
check "landing tree == branch tree" "$(git -C "$repo" rev-parse 'main^{tree}')" "$btree"
check "branch tip not reachable (squashed)" "$(git -C "$repo" merge-base --is-ancestor "$btip" main 2>/dev/null && echo reachable || echo squashed)" "squashed"
check "content really landed" "$(cat "$repo/file.txt")" "changed"
check "the suite ran" "$(grep -c SUITE-RAN "$ROOT/err1")" "1"
check "worktree removed" "$([ -d "$wt" ] && echo present || echo gone)" "gone"
check "branch deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x || echo none)" "none"
check "default message" "$(git -C "$repo" log -1 --format=%s main)" "feat: land x"
check "author" "$(git -C "$repo" log -1 --format='%an <%ae>' main)" "Dev Example <dev@example.com>"
check "committer" "$(git -C "$repo" log -1 --format='%cn <%ce>' main)" "Dev Example <dev@example.com>"
check "author date set" "$([ -n "$(git -C "$repo" log -1 --format=%aI main)" ] && echo yes)" "yes"
check "single parent (linear)" "$(git -C "$repo" log -1 --format=%P main | wc -w | tr -d ' ')" "1"
check "object graph sound" "$(git -C "$repo" fsck --no-progress --no-dangling 2>&1 | wc -l | tr -d ' ')" "0"
check "main checkout left clean" "$(git -C "$repo" status --porcelain)" ""

echo "== 1b. multi-line -m message =="
repo=$(mkrepo)
run "$repo" feat/x -m 'feat: subject line

Body paragraph one.
Body line two.' >/dev/null 2>&1
check "subject" "$(git -C "$repo" log -1 --format=%s main)" "feat: subject line"
check "body preserved" "$(git -C "$repo" log -1 --format=%b main)" "Body paragraph one.
Body line two."

echo "== 2. a branch behind main is rebased automatically and lands =="
repo=$(mkrepo); wt=$(wtof "$repo")
echo other > "$repo/other.txt"
git -C "$repo" add -A >>"$SETUPLOG" 2>&1; git -C "$repo" commit -qm 'main moved' >>"$SETUPLOG" 2>&1
newbase=$(git -C "$repo" rev-parse main)
sha=$(run "$repo" feat/x 2>"$ROOT/err2"); rc=$?
check "exit 0" "$rc" "0"
check "says it rebased" "$(grep -c 'rebasing it onto' "$ROOT/err2")" "1"
check "landed" "$(git -C "$repo" rev-parse main)" "$sha"
check "landed onto the new main tip (not the stale pinned one)" "$(git -C "$repo" rev-parse main^)" "$newbase"
check "worktree removed after landing" "$([ -d "$wt" ] && echo present || echo gone)" "gone"

echo "== 2b. tests run against POST-rebase content, and the landed tree is pinned to it =="
repo=$(mkrepo); wt=$(wtof "$repo")
echo mainonly > "$repo/main-only.txt"
git -C "$repo" add -A >>"$SETUPLOG" 2>&1; git -C "$repo" commit -qm 'main advances' >>"$SETUPLOG" 2>&1
# the check command itself asserts it can see main-only.txt (which only exists
# post-rebase) and the branch's own change; if tests ran before the rebase (or
# the rebase never happened), this check fails and land.sh exits nonzero.
sha=$(run "$repo" feat/x --check "git rev-parse HEAD > $ROOT/postrebase-head; [ -f main-only.txt ] && grep -q changed file.txt" 2>"$ROOT/err2b"); rc=$?
check "exit 0 (the check saw post-rebase content, proving tests ran after the rebase)" "$rc" "0"
postrebase_head=$(cat "$ROOT/postrebase-head" 2>/dev/null)
check "captured a post-rebase HEAD sha" "$([ -n "$postrebase_head" ] && echo yes)" "yes"
check "landing tree == the actual post-rebase worktree tree (proves branch_sha was re-pinned)" \
  "$(git -C "$repo" rev-parse 'main^{tree}')" "$(git -C "$repo" rev-parse "$postrebase_head^{tree}" 2>/dev/null)"
check "landed tree includes main's new file" "$([ -e "$repo/main-only.txt" ] && echo yes)" "yes"
check "landed tree still has the branch's own change" "$(cat "$repo/file.txt")" "changed"

echo "== 3. refuses a dirty branch worktree =="
repo=$(mkrepo); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
echo dirty >> "$wt/file.txt"
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says dirty" "$(printf '%s' "$err" | grep -c 'is dirty')" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"

echo "== 4. refuses when the primary checkout is not on main =="
repo=$(mkrepo)
git -C "$repo" switch -q -c side
before=$(git -C "$repo" rev-parse side)
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "names the branch" "$(printf '%s' "$err" | grep -c "primary checkout is on 'side'")" "1"
check "side untouched" "$(git -C "$repo" rev-parse side)" "$before"
sha=$(LAND_MAIN_BRANCH=side run "$repo" feat/x 2>/dev/null); rc=$?
check "LAND_MAIN_BRANCH override lands" "$rc" "0"
check "landed onto side" "$(git -C "$repo" rev-parse side)" "$sha"
check "main not moved" "$(git -C "$repo" rev-parse main)" "$before"

echo "== 5. refuses tracked modifications in main =="
repo=$(mkrepo); before=$(git -C "$repo" rev-parse main)
echo meddled > "$repo/file.txt"
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says tracked modifications" "$(printf '%s' "$err" | grep -c 'tracked modifications')" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
check "the user's edit is preserved" "$(cat "$repo/file.txt")" "meddled"

echo "== 5b. staged content on main counts as a tracked modification =="
repo=$(mkrepo)
echo sneaky > "$repo/sneaky.txt"; git -C "$repo" add sneaky.txt
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says tracked modifications" "$(printf '%s' "$err" | grep -c 'tracked modifications')" "1"

echo "== 6. untracked files in main do not block =="
repo=$(mkrepo)
echo scratch > "$repo/scratch.log"
sha=$(run "$repo" feat/x 2>"$ROOT/err6"); rc=$?
check "exit 0" "$rc" "0"
check "reported non-fatally" "$(grep -c 'untracked files' "$ROOT/err6")" "1"
check "landed" "$(git -C "$repo" rev-parse main)" "$sha"
check "untracked file survived" "$(cat "$repo/scratch.log")" "scratch"
check "untracked file not in the landing commit" "$(git -C "$repo" show --stat --format= main | grep -c scratch.log)" "0"

echo "== 7. refuses when no verification is found =="
repo=$(mkrepo --no-suite); before=$(git -C "$repo" rev-parse main)
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says no test suite" "$(printf '%s' "$err" | grep -c 'no test suite')" "1"
check "names --no-tests" "$(printf '%s' "$err" | grep -c -- '--no-tests')" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
sha=$(run "$repo" feat/x --no-tests 2>/dev/null); rc=$?
check "--no-tests lands" "$rc" "0"
check "records the omission in the body" "$(git -C "$repo" log -1 --format=%b main)" "Landed with --no-tests: no verification was run."

echo "== 7b. an explicit check overrides detection =="
repo=$(mkrepo); before=$(git -C "$repo" rev-parse main)
err=$(run "$repo" feat/x --check 'echo CUSTOM-RAN; exit 3' 2>&1 >/dev/null); rc=$?
check "nonzero exit when the check fails" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
check "custom command ran" "$([ "$(printf '%s' "$err" | grep -c CUSTOM-RAN)" -ge 1 ] && echo yes)" "yes"
check "detected suite did not run" "$(printf '%s' "$err" | grep -c SUITE-RAN)" "0"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
repo=$(mkrepo)
err=$(LAND_CHECK_CMD='echo ENV-RAN' run "$repo" feat/x 2>&1 >/dev/null)
check "LAND_CHECK_CMD honoured" "$([ "$(printf '%s' "$err" | grep -c ENV-RAN)" -ge 1 ] && echo yes)" "yes"
check "LAND_CHECK_CMD beats detection" "$(printf '%s' "$err" | grep -c SUITE-RAN)" "0"
repo=$(mkrepo); before=$(git -C "$repo" rev-parse main)
err=$(run "$repo" feat/x --check 'true' --no-tests 2>&1 >/dev/null); rc=$?
check "--no-tests + --check is a usage error" "$rc" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"

echo "== 7c. a failing detected suite blocks the landing =="
repo=$(mkrepo); before=$(git -C "$repo" rev-parse main); wt=$(wtof "$repo")
printf '#!/bin/sh\nexit 1\n' > "$wt/run-tests.sh"
git -C "$wt" add -A >>"$SETUPLOG" 2>&1; git -C "$wt" commit -qm 'break suite' >>"$SETUPLOG" 2>&1
rc=0; run "$repo" feat/x >/dev/null 2>&1 || rc=$?
check "nonzero exit" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
check "worktree not removed" "$([ -d "$wt" ] && echo present)" "present"
check "branch not deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x >/dev/null && echo alive)" "alive"

echo "== 8. main advancing mid-run: the --ff-only failure path =="
repo=$(mkrepo); wt=$(wtof "$repo")
# the check command advances main while land.sh runs, i.e. after base_sha is pinned
err=$(run "$repo" feat/x --check "git -C '$repo' commit -q --allow-empty -m interloper" 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "reports the failed fast-forward" "$(printf '%s' "$err" | grep -c 'fast-forward of main')" "1"
check "says nothing was landed" "$(printf '%s' "$err" | grep -c 'Nothing was landed')" "1"
check "main holds only the interloper" "$(git -C "$repo" log -1 --format=%s main)" "interloper"
check "no landing commit exists" "$(git -C "$repo" log --format=%s main | grep -c 'feat: land')" "0"
check "worktree not removed" "$([ -d "$wt" ] && echo present)" "present"
check "branch not deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x >/dev/null && echo alive)" "alive"
check "main checkout left clean" "$(git -C "$repo" status --porcelain)" ""
check "no interrupted-merge wreckage" "$({ [ -f "$repo/.git/MERGE_HEAD" ] || [ -f "$repo/.git/SQUASH_MSG" ]; } && echo wreckage || echo clean)" "clean"
sha=$(run "$repo" feat/x 2>/dev/null); rc=$?
check "recovers on re-run (auto-rebased onto the interloper, no manual rebase needed)" "$rc" "0"
check "main == landed sha" "$(git -C "$repo" rev-parse main)" "$sha"

echo "== 8b. the branch advancing mid-run is refused =="
repo=$(mkrepo); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
err=$(run "$repo" feat/x --check "git -C '$wt' commit -q --allow-empty -m unverified" 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says the branch advanced" "$(printf '%s' "$err" | grep -c 'advanced from')" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"

echo "== 9. a same-named tag cannot hijack the branch =="
repo=$(mkrepo)
btree9=$(git -C "$repo" rev-parse 'refs/heads/feat/x^{tree}')
# a decoy commit with poisoned content, tagged with the branch's exact name
pb=$(echo POISON | git -C "$repo" hash-object -w --stdin)
pt=$(printf '100644 blob %s\tpoison.txt\n' "$pb" | git -C "$repo" mktree)
decoy=$(echo decoy | git -C "$repo" commit-tree "$pt" -p "$(git -C "$repo" rev-parse main)")
git -C "$repo" tag feat/x "$decoy"
check "tag and branch disagree" "$([ "$(git -C "$repo" rev-parse refs/tags/feat/x)" != "$(git -C "$repo" rev-parse refs/heads/feat/x)" ] && echo yes)" "yes"
sha=$(run "$repo" feat/x 2>/dev/null); rc=$?
check "exit 0" "$rc" "0"
check "landed the branch's content" "$(cat "$repo/file.txt")" "changed"
check "did not land the tag's content" "$([ -e "$repo/poison.txt" ] && echo poisoned || echo clean)" "clean"
check "landing tree == branch tree" "$(git -C "$repo" rev-parse "$sha^{tree}")" "$btree9"
check "landing tree != tag tree" "$([ "$(git -C "$repo" rev-parse "$sha^{tree}")" = "$(git -C "$repo" rev-parse "$decoy^{tree}")" ] && echo hijacked || echo safe)" "safe"

echo "== 10. --dry-run mutates nothing =="
repo=$(mkrepo); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
out=$(run "$repo" feat/x --dry-run 2>"$ROOT/err10"); rc=$?
check "exit 0" "$rc" "0"
cand=$(grep -oE 'candidate [0-9a-f]{40}' "$ROOT/err10" | head -1 | awk '{print $2}')
check "candidate sha printed" "$([ -n "$cand" ] && echo yes)" "yes"
check "candidate object exists" "$(git -C "$repo" cat-file -t "$cand")" "commit"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
check "worktree kept" "$([ -d "$wt" ] && echo present)" "present"
check "branch kept" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x >/dev/null && echo alive)" "alive"
check "main checkout clean" "$(git -C "$repo" status --porcelain)" ""
check "diff printed to stderr" "$(grep -c '^+changed' "$ROOT/err10")" "1"
check "nothing printed to stdout" "$out" ""
check "tells you how to land it by hand" "$(grep -c 'merge --ff-only' "$ROOT/err10")" "1"
git -C "$repo" merge --ff-only "$cand" >>"$SETUPLOG" 2>&1
check "the printed candidate is landable by hand" "$(git -C "$repo" rev-parse main)" "$cand"

echo "== 11. an empty change lands nothing =="
repo=$(mkrepo); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
git -C "$wt" revert --no-edit HEAD >>"$SETUPLOG" 2>&1 || { echo "revert fixture failed" >&2; exit 99; }
check "revert really equalised the trees" "$(git -C "$repo" rev-parse 'refs/heads/feat/x^{tree}')" "$(git -C "$repo" rev-parse 'main^{tree}')"
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 0" "$rc" "0"
check "says nothing to land" "$(printf '%s' "$err" | grep -c 'nothing to land')" "1"
check "no empty commit on main" "$(git -C "$repo" rev-parse main)" "$before"
check "worktree cleaned up" "$([ -d "$wt" ] && echo present || echo gone)" "gone"
check "branch deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x || echo none)" "none"

echo "== 12. cleanup never deletes a branch that advanced past the landed sha =="
repo=$(mkrepo); wt=$(wtof "$repo")
# post-merge fires on the fast-forward: after publication, before cleanup
printf '#!/bin/sh\ngit -C "%s" commit -q --allow-empty -m late-work\n' "$wt" > "$repo/.git/hooks/post-merge"
chmod +x "$repo/.git/hooks/post-merge"
sha=$(run "$repo" feat/x 2>"$ROOT/err12"); rc=$?
check "the landing still succeeded" "$rc" "0"
check "main == landed sha" "$(git -C "$repo" rev-parse main)" "$sha"
check "branch not deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x >/dev/null && echo alive || echo gone)" "alive"
check "said why it kept the branch" "$(grep -c 'NOT deleting feat/x' "$ROOT/err12")" "1"
check "the late commit survived" "$(git -C "$repo" log -1 --format=%s refs/heads/feat/x)" "late-work"

echo "== 13. refuses to run from inside a worktree =="
repo=$(mkrepo); wt=$(wtof "$repo")
err=$(run "$wt" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says primary checkout" "$(printf '%s' "$err" | grep -c 'primary checkout, not a worktree')" "1"

echo "== 14. refuses main-onto-itself and unknown branches =="
repo=$(mkrepo)
err=$(run "$repo" main 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says onto itself" "$(printf '%s' "$err" | grep -c 'onto itself')" "1"
err=$(run "$repo" feat/nope 2>&1 >/dev/null); rc=$?
check "unknown branch exit 1" "$rc" "1"
check "says no branch named" "$(printf '%s' "$err" | grep -c 'no branch named')" "1"

echo "== 15. commit-tree does not run commit hooks (documented tradeoff) =="
repo=$(mkrepo)
printf '#!/bin/sh\necho PRECOMMIT-RAN >&2\nexit 1\n' > "$repo/.git/hooks/pre-commit"
printf '#!/bin/sh\necho COMMITMSG-RAN >&2\nexit 1\n' > "$repo/.git/hooks/commit-msg"
chmod +x "$repo/.git/hooks/pre-commit" "$repo/.git/hooks/commit-msg"
sha=$(run "$repo" feat/x 2>"$ROOT/err15"); rc=$?
check "lands despite hooks that would reject" "$rc" "0"
check "pre-commit did not run" "$(grep -c PRECOMMIT-RAN "$ROOT/err15")" "0"
check "commit-msg did not run" "$(grep -c COMMITMSG-RAN "$ROOT/err15")" "0"
check "main == landed sha" "$(git -C "$repo" rev-parse main)" "$sha"

echo "== 16. commit.gpgsign is honoured; a signing failure lands nothing =="
repo=$(mkrepo); before=$(git -C "$repo" rev-parse main); wt=$(wtof "$repo")
git -C "$repo" config commit.gpgsign true
git -C "$repo" config gpg.program /nonexistent-gpg-binary
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "signing was attempted (nonzero exit)" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
check "main untouched by a failed signature" "$(git -C "$repo" rev-parse main)" "$before"
check "no wreckage on main" "$(git -C "$repo" status --porcelain)" ""
check "worktree not removed" "$([ -d "$wt" ] && echo present)" "present"
check "branch not deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x >/dev/null && echo alive)" "alive"
git -C "$repo" config commit.gpgsign false
sha=$(run "$repo" feat/x 2>/dev/null); rc=$?
check "lands once signing is not demanded" "$rc" "0"
check "the resulting commit is unsigned" "$(git -C "$repo" log -1 --format=%G? main)" "N"

echo "== 17. a rebase conflict is left in progress and lands nothing =="
repo=$(mkrepo); wt=$(wtof "$repo")
echo mainconflict > "$repo/file.txt"
git -C "$repo" add -A >>"$SETUPLOG" 2>&1; git -C "$repo" commit -qm 'main conflicts' >>"$SETUPLOG" 2>&1
before=$(git -C "$repo" rev-parse main)
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "says the rebase is left IN PROGRESS" "$(printf '%s' "$err" | grep -c 'IN PROGRESS')" "1"
check "tells the user to resolve (matches the behaviour: nothing was aborted)" "$(printf '%s' "$err" | grep -c 'resolve the conflicts')" "1"
check "names the re-run command" "$(printf '%s' "$err" | grep -c 'bin/land.sh feat/x')" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
check "worktree not removed" "$([ -d "$wt" ] && echo present)" "present"
check "branch not deleted" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x >/dev/null && echo alive)" "alive"
rd=$(git -C "$wt" rev-parse --path-format=absolute --git-path rebase-merge 2>/dev/null)
ra=$(git -C "$wt" rev-parse --path-format=absolute --git-path rebase-apply 2>/dev/null)
check "the worktree is genuinely left mid-rebase" "$({ [ -d "$rd" ] || [ -d "$ra" ]; } && echo yes || echo no)" "yes"

echo "== 17b. re-running before finishing the conflict refuses, not destroys =="
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "refuses because the paused rebase reports as detached" "$(printf '%s' "$err" | grep -c 'no worktree found for branch')" "1"
check "main still untouched" "$(git -C "$repo" rev-parse main)" "$before"
check "worktree still not destroyed" "$([ -d "$wt" ] && echo present)" "present"
echo resolved > "$wt/file.txt"
git -C "$wt" add file.txt >>"$SETUPLOG" 2>&1
GIT_EDITOR=true git -C "$wt" rebase --continue >>"$SETUPLOG" 2>&1
sha=$(run "$repo" feat/x 2>/dev/null); rc=$?
check "lands once the user finishes the rebase" "$rc" "0"
check "main == landed sha" "$(git -C "$repo" rev-parse main)" "$sha"
check "the resolved content landed" "$(cat "$repo/file.txt")" "resolved"

echo "== 18. a worktree paused mid interactive-rebase (clean status) is refused, not destroyed =="
repo=$(mkrepo); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
seqeditor="$ROOT/seqeditor.sh"
cat > "$seqeditor" <<'EOF'
#!/bin/sh
# turn the first "pick" into "edit" so the rebase pauses right after that commit
awk 'NR==1{sub(/^pick/,"edit")}{print}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
EOF
chmod +x "$seqeditor"
GIT_SEQUENCE_EDITOR="$seqeditor" git -C "$wt" rebase -i HEAD~1 >>"$SETUPLOG" 2>&1 || true
check "fixture is valid: rebase paused with a clean worktree" "$(git -C "$wt" status --porcelain)" ""
err=$(run "$repo" feat/x 2>&1 >/dev/null); rc=$?
check "exit 1" "$rc" "1"
check "refuses (paused rebase reports as detached, clean status notwithstanding)" "$(printf '%s' "$err" | grep -c 'no worktree found for branch')" "1"
check "main untouched" "$(git -C "$repo" rev-parse main)" "$before"
check "worktree not destroyed" "$([ -d "$wt" ] && echo present)" "present"
git -C "$wt" rebase --abort >>"$SETUPLOG" 2>&1 || true

# ---------------------------------------------------------------------------
# hooks/git-repo/reference-transaction — the per-repository git-level guard —
# and install-repo.sh, which installs it. Git runs this hook inside every ref
# transaction, so these tests drive real git commands and assert on what the
# refs did, not on what any command string looked like.
#
# Every install below targets a throwaway repo under $ROOT. Section 0 asserts
# the guard is never installed into this repository itself.
# ---------------------------------------------------------------------------

INSTALL_REPO="$REPO_ROOT/install-repo.sh"

# mkguarded — an mkrepo fixture with the guard installed. mkrepo pins
# core.hooksPath to the repo's own .git/hooks, which is the same directory the
# installer would pick anyway, so this also exercises the benign-hooksPath path.
mkguarded() {
  local repo; repo=$(mkrepo)
  bash "$INSTALL_REPO" "$repo" >>"$SETUPLOG" 2>&1 \
    || { echo "GUARD FIXTURE SETUP FAILED (see $SETUPLOG)" >&2; exit 99; }
  echo "$repo"
}

# mkplain — a minimal repo with NO core.hooksPath and no .git/hooks directory,
# for the installer's own tests.
mkplain() {
  local d; d=$(mktemp -d "$ROOT/i.XXXXXX")
  {
    git init -q -b main --template="$EMPTY_TEMPLATE" "$d/repo"
    git -C "$d/repo" config user.email dev@example.com
    git -C "$d/repo" config user.name 'Dev Example'
    git -C "$d/repo" commit -q --allow-empty -m init
  } >>"$SETUPLOG" 2>&1 || { echo "PLAIN FIXTURE SETUP FAILED (see $SETUPLOG)" >&2; exit 99; }
  echo "$d/repo"
}

# grun — run a git command in a fixture, capture everything to $ROOT/gerr, echo
# the exit status. denied() turns that status into a word the checks compare.
grun()   { local d="$1"; shift; ( cd "$d" && git "$@" ) >"$ROOT/gerr" 2>&1; echo $?; }
denied() { if [ "$1" -ne 0 ]; then echo denied; else echo allowed; fi; }
inst()   { bash "$INSTALL_REPO" "$@" >"$ROOT/ierr" 2>&1; echo $?; }

echo "== 19. the guard installed: bin/land.sh still lands =="
repo=$(mkguarded); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
check "hook installed and executable" "$([ -x "$repo/.git/hooks/reference-transaction" ] && echo yes || echo no)" "yes"
out=$(run "$repo" feat/x 2>"$ROOT/err19"); rc=$?
check "exit 0 — the guard does not break the sanctioned path" "$rc" "0"
check "main == landed sha" "$(git -C "$repo" rev-parse main)" "$out"
check "exactly one commit added" "$(git -C "$repo" rev-list --count "$before"..main)" "1"
check "content really landed" "$(cat "$repo/file.txt")" "changed"
check "the branch was still deletable (unprotected refs are untouched)" "$(git -C "$repo" rev-parse --verify --quiet refs/heads/feat/x || echo none)" "none"
check "worktree removed" "$([ -d "$wt" ] && echo present || echo gone)" "gone"

# the rebase path: land.sh rebases the branch in its own worktree first, which
# must also survive the guard.
repo=$(mkguarded)
echo other > "$repo/other.txt"
git -C "$repo" add -A >>"$SETUPLOG" 2>&1; git -C "$repo" commit -qm 'main moved' >>"$SETUPLOG" 2>&1
newbase=$(git -C "$repo" rev-parse main)
sha=$(run "$repo" feat/x 2>"$ROOT/err19b"); rc=$?
check "a landing that needed a rebase still lands" "$rc" "0"
check "landed onto the new tip" "$(git -C "$repo" rev-parse main^)" "$newbase"

echo "== 20. the guard denies every move of main that is not a one-commit fast-forward =="
repo=$(mkguarded); wt=$(wtof "$repo"); before=$(git -C "$repo" rev-parse main)
# a second branch commit, so a fast-forward would advance main by two
echo more > "$wt/file2.txt"
git -C "$wt" add -A >>"$SETUPLOG" 2>&1; git -C "$wt" commit -qm work2 >>"$SETUPLOG" 2>&1

rc=$(grun "$repo" merge --ff-only feat/x)
check "git merge --ff-only of a MULTI-commit branch is denied" "$(denied "$rc")" "denied"
check "  git reports the hook aborted it" "$(grep -c 'aborted by hook' "$ROOT/gerr")" "1"
check "  the message says why" "$(grep -c 'reason:' "$ROOT/gerr")" "1"
check "  the message names the escape hatch" "$(grep -c 'HYGIENE_ALLOW_REF_UPDATE' "$ROOT/gerr")" "1"
check "  main untouched" "$(git -C "$repo" rev-parse main)" "$before"
git -C "$repo" reset -q --hard "$before" >>"$SETUPLOG" 2>&1

rc=$(grun "$repo" merge --no-ff --no-edit -m merge feat/x)
check "a real merge commit (two parents) is denied" "$(denied "$rc")" "denied"
check "  it names the parent count" "$(grep -c 'is a merge commit' "$ROOT/gerr")" "1"
check "  main untouched" "$(git -C "$repo" rev-parse main)" "$before"
# Honest about the blast radius: git finishes the merge in the index/worktree
# BEFORE it tries to move the ref, so a denial leaves the checkout mid-merge for
# the user to `git merge --abort`. The guard protects the ref, not the checkout.
check "  git is left mid-merge, which the user must abort (documented)" "$([ -f "$repo/.git/MERGE_HEAD" ] && echo mid-merge || echo clean)" "mid-merge"
git -C "$repo" merge --abort >>"$SETUPLOG" 2>&1
git -C "$repo" reset -q --hard "$before" >>"$SETUPLOG" 2>&1
git -C "$repo" clean -qfd >>"$SETUPLOG" 2>&1

# git pull: a fast-forward of more than one commit arriving over the network path
pullsrc="$ROOT/pullsrc"
git clone -q "$repo" "$pullsrc" >>"$SETUPLOG" 2>&1
git -C "$pullsrc" config user.email dev@example.com >>"$SETUPLOG" 2>&1
git -C "$pullsrc" config user.name 'Dev Example' >>"$SETUPLOG" 2>&1
git -C "$pullsrc" commit -q --allow-empty -m p1 >>"$SETUPLOG" 2>&1
git -C "$pullsrc" commit -q --allow-empty -m p2 >>"$SETUPLOG" 2>&1
rc=$(grun "$repo" pull --no-rebase "$pullsrc" main)
check "git pull advancing main by two commits is denied" "$(denied "$rc")" "denied"
check "  main untouched" "$(git -C "$repo" rev-parse main)" "$before"

# an unrelated commit, built as an object so it shares no history with main
unrel=$(printf 'unrelated\n' | git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'main^{tree}')")
rc=$(grun "$repo" update-ref refs/heads/main "$unrel")
check "git update-ref to an unrelated commit is denied" "$(denied "$rc")" "denied"
check "  main untouched" "$(git -C "$repo" rev-parse main)" "$before"

# reset --hard needs main checked out; branch -f/-D need it NOT to be, because
# git refuses those on the current branch before the hook is ever consulted.
echo second > "$repo/second.txt"
git -C "$repo" add -A >>"$SETUPLOG" 2>&1
git -C "$repo" commit -qm second >>"$SETUPLOG" 2>&1
twoback=$(git -C "$repo" rev-parse main~1)
now=$(git -C "$repo" rev-parse main)
rc=$(grun "$repo" reset --hard "$twoback")
check "git reset --hard to an older commit is denied" "$(denied "$rc")" "denied"
check "  main untouched" "$(git -C "$repo" rev-parse main)" "$now"
check "  the working tree WAS reset, which the user must undo (documented)" "$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')" "1"
git -C "$repo" reset -q --hard main >>"$SETUPLOG" 2>&1

git -C "$repo" switch -q -c side >>"$SETUPLOG" 2>&1
rc=$(grun "$repo" branch -f main "$unrel")
check "git branch -f main <unrelated> is denied" "$(denied "$rc")" "denied"
check "  main untouched" "$(git -C "$repo" rev-parse main)" "$now"
rc=$(grun "$repo" branch -D main)
check "deleting the protected branch is denied" "$(denied "$rc")" "denied"
check "  it says the branch would be deleted" "$(grep -c 'deletes the protected branch' "$ROOT/gerr")" "1"
check "  main still exists" "$(git -C "$repo" rev-parse main)" "$now"
rc=$(grun "$repo" update-ref -d refs/heads/main "$now")
check "git update-ref -d with an explicit old sha is denied too" "$(denied "$rc")" "denied"
check "  main still exists" "$(git -C "$repo" rev-parse main)" "$now"
rc=$(grun "$repo" update-ref -d refs/heads/main)
check "git update-ref -d with no old sha is denied too" "$(denied "$rc")" "denied"
check "  main still exists" "$(git -C "$repo" rev-parse main)" "$now"

echo "== 21. KNOWN LIMITATION (not an oversight): a direct commit on main is ALLOWED =="
# A squash landing and a plain `git commit` on main both produce exactly one new
# single-parent commit whose parent is the old tip. The hook sees only the ref
# transaction, so it CANNOT tell them apart. It enforces linearity and
# single-commit advance, NOT provenance. Asserting the honest behaviour here
# means any future claim to the contrary breaks this test.
repo=$(mkguarded); before=$(git -C "$repo" rev-parse main)
echo direct > "$repo/direct.txt"
git -C "$repo" add -A >>"$SETUPLOG" 2>&1
rc=$(grun "$repo" commit -qm 'straight onto main')
check "a direct single commit on main is allowed" "$(denied "$rc")" "allowed"
check "  main advanced by exactly one" "$(git -C "$repo" rev-list --count "$before"..main)" "1"
# --amend with no edits at all can reproduce a byte-identical commit object
# within the same second, which is a genuine no-op; change the message so the
# new object really is different and the rewrite is visible.
rc=$(grun "$repo" commit -q --amend -m 'amended in place')
check "but amending it is denied (that is a rewrite)" "$(denied "$rc")" "denied"
check "  main still holds the original message" "$(git -C "$repo" log -1 --format=%s main)" "straight onto main"

echo "== 22. everything that is not the protected branch is untouched =="
repo=$(mkguarded); wt=$(wtof "$repo")
rc=$(grun "$wt" commit -q --allow-empty -m 'inside a linked worktree')
check "commits on a feature branch in a LINKED worktree are unaffected" "$(denied "$rc")" "allowed"
rc=$(grun "$repo" switch -q -c another)
check "creating a branch in the primary checkout is unaffected" "$(denied "$rc")" "allowed"
rc=$(grun "$repo" commit -q --allow-empty -m 'on a feature branch in the primary checkout')
check "committing on it is unaffected" "$(denied "$rc")" "allowed"
git -C "$repo" switch -q main >>"$SETUPLOG" 2>&1
rc=$(grun "$repo" branch -D another)
check "deleting an unprotected branch is unaffected" "$(denied "$rc")" "allowed"
rc=$(grun "$repo" tag v1)
check "creating a tag is unaffected" "$(denied "$rc")" "allowed"
rc=$(grun "$repo" tag -d v1)
check "deleting a tag is unaffected" "$(denied "$rc")" "allowed"
echo stashed > "$repo/file.txt"
rc=$(grun "$repo" stash)
check "git stash is unaffected" "$(denied "$rc")" "allowed"
rc=$(grun "$repo" stash pop)
check "git stash pop is unaffected" "$(denied "$rc")" "allowed"
git -C "$repo" checkout -q -- . >>"$SETUPLOG" 2>&1
mainsha=$(git -C "$repo" rev-parse main)
# gc/pack-refs report the pruning of every loose ref — the protected branch
# included — as a deletion. Denying that would make the repo ungarbage-collectable.
rc=$(grun "$repo" gc --prune=now -q)
check "git gc works (its loose-ref pruning is not mistaken for a delete)" "$(denied "$rc")" "allowed"
check "  main survived gc" "$(git -C "$repo" rev-parse main)" "$mainsha"
rc=$(grun "$repo" pack-refs --all)
check "git pack-refs --all works" "$(denied "$rc")" "allowed"
check "  main survived packing" "$(git -C "$repo" rev-parse main)" "$mainsha"
rc=$(grun "$repo" gc --prune=now -q)
check "git gc works again once refs are packed" "$(denied "$rc")" "allowed"
rc=$(grun "$repo" branch -D main)
check "and a real delete is STILL denied on a packed ref" "$(denied "$rc")" "denied"
fetchsrc="$ROOT/fetchsrc"
git clone -q "$repo" "$fetchsrc" >>"$SETUPLOG" 2>&1
git -C "$fetchsrc" commit -q --allow-empty -m remote-work \
  --author='Dev Example <dev@example.com>' >>"$SETUPLOG" 2>&1
git -C "$repo" remote add origin "$fetchsrc" >>"$SETUPLOG" 2>&1
rc=$(grun "$repo" fetch -q origin)
check "git fetch is unaffected (remote-tracking refs are not protected)" "$(denied "$rc")" "allowed"
check "  it really fetched" "$(git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null && echo yes || echo no)" "yes"
check "  main untouched by the fetch" "$(git -C "$repo" rev-parse main)" "$mainsha"
check "  object graph still sound" "$(git -C "$repo" fsck --no-progress --no-dangling 2>&1 | wc -l | tr -d ' ')" "0"

echo "== 23. the escape hatch, and the protected-branch override =="
repo=$(mkguarded); before=$(git -C "$repo" rev-parse main)
unrel=$(printf 'unrelated\n' | git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'main^{tree}')")
rc=$(grun "$repo" update-ref refs/heads/main "$unrel")
check "the operation is denied without the escape hatch" "$(denied "$rc")" "denied"
rc=$( cd "$repo" && HYGIENE_ALLOW_REF_UPDATE=1 git update-ref refs/heads/main "$unrel" >"$ROOT/gerr" 2>&1; echo $? )
check "HYGIENE_ALLOW_REF_UPDATE=1 permits it" "$(denied "$rc")" "allowed"
check "  and it really moved" "$(git -C "$repo" rev-parse main)" "$unrel"
rc=$(grun "$repo" update-ref refs/heads/main "$before")
check "the hatch is per-invocation — the next command is guarded again" "$(denied "$rc")" "denied"

repo=$(mkguarded)
git -C "$repo" config hygiene.protectedBranch trunk >>"$SETUPLOG" 2>&1
git -C "$repo" branch trunk >>"$SETUPLOG" 2>&1
git -C "$repo" switch -q -c parking >>"$SETUPLOG" 2>&1
unrel=$(printf 'unrelated\n' | git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'main^{tree}')")
rc=$(grun "$repo" branch -f trunk "$unrel")
check "hygiene.protectedBranch protects a branch called anything" "$(denied "$rc")" "denied"
rc=$(grun "$repo" branch -f main "$unrel")
check "and the override REPLACES the main/master default" "$(denied "$rc")" "allowed"

echo "== 24. install-repo.sh =="
repo=$(mkplain)
hooks="$repo/.git/hooks"
rc=$(inst "$repo")
check "fresh install exits 0" "$rc" "0"
check "it created the hooks directory" "$([ -d "$hooks" ] && echo yes || echo no)" "yes"
check "the hook is there and executable" "$([ -x "$hooks/reference-transaction" ] && echo yes || echo no)" "yes"
check "it is byte-identical to the source" "$(cmp -s "$REPO_ROOT/hooks/git-repo/reference-transaction" "$hooks/reference-transaction" && echo same || echo differs)" "same"
check "it says where it went" "$(grep -c 'installed' "$ROOT/ierr")" "1"
check "it names the escape hatch" "$(grep -c 'HYGIENE_ALLOW_REF_UPDATE' "$ROOT/ierr")" "1"
check "the installed hook actually fires" "$(denied "$(grun "$repo" update-ref refs/heads/main "$(printf 'x\n' | git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'main^{tree}')")")")" "denied"

rc=$(inst "$repo")
check "re-running is idempotent (exit 0)" "$rc" "0"
check "  it reports an update, not a fresh install" "$(grep -c 'updated' "$ROOT/ierr")" "1"
check "  still byte-identical" "$(cmp -s "$REPO_ROOT/hooks/git-repo/reference-transaction" "$hooks/reference-transaction" && echo same || echo differs)" "same"
check "  an unchanged file leaves no backup" "$(ls "$hooks"/reference-transaction.bak-* 2>/dev/null | wc -l | tr -d ' ')" "0"

printf '#!/bin/sh\n# locally tweaked copy\n%s\n' "# reference-transaction — a git-level guard that keeps a protected branch linear." > "$hooks/reference-transaction"
rc=$(inst "$repo")
check "replacing a MODIFIED copy of ours still works" "$rc" "0"
check "  and backs the old one up" "$(ls "$hooks"/reference-transaction.bak-* 2>/dev/null | wc -l | tr -d ' ')" "1"

check "uninstall removes it" "$(inst --uninstall "$repo")" "0"
check "  the hook is gone" "$([ -e "$hooks/reference-transaction" ] && echo present || echo gone)" "gone"
check "uninstalling twice is not an error" "$(inst --uninstall "$repo")" "0"

repo=$(mkplain); hooks="$repo/.git/hooks"
mkdir -p "$hooks"
printf '#!/bin/sh\n# somebody else already had one of these\nexit 0\n' > "$hooks/reference-transaction"
foreign=$(cat "$hooks/reference-transaction")
rc=$(inst "$repo")
check "a foreign hook is refused, not clobbered" "$([ "$rc" -ne 0 ] && echo refused || echo clobbered)" "refused"
check "  the foreign hook is byte-for-byte untouched" "$(cat "$hooks/reference-transaction")" "$foreign"
check "  it explains the stdin-is-consumed-once problem" "$(grep -c 'consumed once' "$ROOT/ierr")" "1"
check "  it offers --as for chaining" "$(grep -c -- '--as reference-transaction.hygiene' "$ROOT/ierr")" "1"
check "uninstall refuses a foreign hook too" "$([ "$(inst --uninstall "$repo")" -ne 0 ] && echo refused || echo deleted)" "refused"
rc=$(inst --as reference-transaction.hygiene "$repo")
check "--as installs alongside it" "$rc" "0"
check "  ours is there under the alternate name" "$([ -x "$hooks/reference-transaction.hygiene" ] && echo yes || echo no)" "yes"
check "  and it warns git will not run it directly" "$(grep -c 'will NOT run it directly' "$ROOT/ierr")" "1"

# core.hooksPath elsewhere: .git/hooks is not consulted at all, so installing
# there would be a success that changes nothing.
repo=$(mkplain); hooks="$repo/.git/hooks"
elsewhere="$(dirname "$repo")/elsewhere"; mkdir -p "$elsewhere"
git -C "$repo" config core.hooksPath "$elsewhere" >>"$SETUPLOG" 2>&1
rc=$(inst "$repo")
check "core.hooksPath pointing elsewhere is refused, not silently ignored" "$([ "$rc" -ne 0 ] && echo refused || echo faked-success)" "refused"
check "  it names core.hooksPath" "$([ "$(grep -c 'core.hooksPath' "$ROOT/ierr")" -ge 1 ] && echo yes)" "yes"
check "  it prints the --hooks-dir command to use instead" "$(grep -c -- '--hooks-dir' "$ROOT/ierr")" "1"
check "  nothing was written to the ignored .git/hooks" "$([ -e "$hooks/reference-transaction" ] && echo written || echo untouched)" "untouched"
rc=$(inst --hooks-dir "$elsewhere" "$repo")
check "--hooks-dir installs where git actually looks" "$rc" "0"
check "  and the hook fires from there" "$(denied "$(grun "$repo" update-ref refs/heads/main "$(printf 'y\n' | git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'main^{tree}')")")")" "denied"

check "a non-repository target is refused" "$([ "$(inst "$ROOT")" -ne 0 ] && echo refused || echo accepted)" "refused"

# ---------------------------------------------------------------------------
# hooks/git-hygiene-guard.sh — the Bash PreToolUse commit linter (the OTHER
# guard: a Claude Code hook, not a git hook). It reads a JSON payload on
# stdin ({cwd, tool_input:{command}}) and emits either nothing (allow) or a
# JSON deny decision on stdout, so it's directly testable without going
# through Claude Code, bin/land.sh, or a real PreToolUse dispatch at all.
# ---------------------------------------------------------------------------

GUARD="$REPO_ROOT/hooks/git-hygiene-guard.sh"

# guard_run — feed the guard a {cwd, command} payload, echo whatever it wrote
# to stdout (empty string == allow; a JSON blob == deny).
guard_run() {
  local cwd="$1" cmd="$2"
  jq -n --arg cwd "$cwd" --arg cmd "$cmd" '{cwd:$cwd, tool_input:{command:$cmd}}' | bash "$GUARD"
}
guard_verdict() { [ -n "$(guard_run "$1" "$2")" ] && echo denied || echo allowed; }

echo "== 25. hooks/git-hygiene-guard.sh (Bash PreToolUse commit linter) =="

repo=$(mkrepo); wt=$(wtof "$repo")

out=$(guard_run "$repo" 'git commit -m x')
check "a direct commit on the protected branch is denied" "$([ -n "$out" ] && echo denied || echo allowed)" "denied"
check "  the denial names bin/land.sh" "$(printf '%s' "$out" | grep -c 'bin/land.sh')" "1"

touch "$repo/.git/SQUASH_MSG"
check "the SQUASH_MSG two-step no longer authorises a commit" "$(guard_verdict "$repo" 'git commit -m x')" "denied"
rm -f "$repo/.git/SQUASH_MSG"

cmd='bash /path/to/land-runner.sh some/branch -m "prose that mentions
git commit and git merge --abort
in the body"'
check "a quoted argument that merely mentions a git operation is not denied (fix #2 regression)" \
  "$(guard_verdict "$repo" "$cmd")" "allowed"

check "git -c key=value commit on the protected branch is denied (fix #3)" \
  "$(guard_verdict "$repo" 'git -c user.email=x@y commit -m x')" "denied"

check "a commit on a branch inside a linked worktree is not denied" \
  "$(guard_verdict "$wt" 'git commit -m x')" "allowed"

bare=$(mktemp -d "$ROOT/b.XXXXXX")
git init -q -b main "$bare" >>"$SETUPLOG" 2>&1
check "the empty-repo bootstrap exception still works" \
  "$(guard_verdict "$bare" 'git commit -m init')" "allowed"

echo
echo "=============================================="
if [ "$failn" -eq 0 ]; then
  printf 'PASS  %s assertions' "$pass"
else
  printf 'FAIL  %s failed of %s assertions' "$failn" "$((pass + failn))"
fi
[ "$skipped" -gt 0 ] && printf ', %s skipped' "$skipped"
printf '  (%ss)\n' "$SECONDS"
[ "$failn" -eq 0 ]

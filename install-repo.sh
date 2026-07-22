#!/bin/bash
# install-repo.sh — install the per-repository reference-transaction guard.
#
#   ./install-repo.sh [<repo>]              install into <repo> (default: cwd)
#   ./install-repo.sh --uninstall [<repo>]  remove it again
#   ./install-repo.sh --as <name> [<repo>]  install under a different hook name,
#                                           so an existing hook can chain to it
#   ./install-repo.sh --hooks-dir <dir> ... install into <dir> explicitly
#
# This is separate from install.sh on purpose. install.sh sets up the Claude Code
# hooks in ~/.claude, once, for every session. This one installs a git hook into
# ONE repository's git dir — git itself runs it, for every tool and every user of
# that repo. See the README for what it does and does not enforce.
set -euo pipefail

SRC_NAME="reference-transaction"
SRC="$(cd "$(dirname "$0")" && pwd)/hooks/git-repo/$SRC_NAME"
# Every copy carries this line, so we can tell our hook from someone else's and
# refuse to clobber theirs.
MARKER="reference-transaction — a git-level guard that keeps a protected branch linear."

fail() { printf 'install-repo.sh: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: install-repo.sh [<repo>] [--uninstall] [--as <name>] [--hooks-dir <dir>]

Installs the reference-transaction guard into <repo> (default: the current
directory). The hook lives in the repo's common git dir, so it applies to every
worktree of that repo at once.

  --uninstall        remove the hook again (refuses if it is not ours)
  --as NAME          install under a different hook name, so an existing
                     reference-transaction hook can chain to it
  --hooks-dir DIR    install into DIR instead of <repo>/.git/hooks

Re-running is idempotent: it updates our hook in place, backing up what it
replaces. It refuses rather than clobbering a reference-transaction hook that
is not ours, and refuses rather than reporting a fake success when
core.hooksPath points somewhere else.
EOF
}

target="."; uninstall=0; hooks_dir=""; hook_name="$SRC_NAME"
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) uninstall=1; shift ;;
    --hooks-dir) hooks_dir="${2:?install-repo.sh: --hooks-dir requires a directory}"; shift 2 ;;
    --as) hook_name="${2:?install-repo.sh: --as requires a hook name}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "install-repo.sh: unknown option: $1" >&2; usage; exit 1 ;;
    *) target="$1"; shift ;;
  esac
done

[ -f "$SRC" ] || fail "cannot find the hook to install at $SRC"
[ -d "$target" ] || fail "no such directory: $target"

# Two paths can name the same directory (macOS /tmp vs /private/tmp, symlinked
# checkouts), and comparing them as text is how the edit guard in this repo
# produces false denials. Resolve physically before comparing.
realdir() { (cd "$1" 2>/dev/null && pwd -P) || return 1; }

# ---- locate the hooks directory git will actually consult -------------------
# The target may be a linked worktree; hooks live in the COMMON git dir, which is
# also why this hook applies to every worktree of the repo at once.

common=$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || fail "$target is not inside a git repository"
common=$(realdir "$common") || fail "cannot resolve the git dir of $target"
default_hooks="$common/hooks"

if [ -n "$hooks_dir" ]; then
  [ -d "$hooks_dir" ] || fail "--hooks-dir $hooks_dir does not exist"
  dest_dir=$(realdir "$hooks_dir")
else
  # core.hooksPath, when set, REPLACES .git/hooks entirely — installing into
  # .git/hooks would then be a success that does nothing at all. Report it
  # instead of lying. (A hooksPath that resolves to .git/hooks anyway is common
  # and harmless, so that case proceeds silently.)
  configured=$(git -C "$target" config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$configured" ]; then
    case "$configured" in
      /*) resolved="$configured" ;;
      # Relative values are resolved by git against the directory the hooks run
      # in, i.e. the top of the working tree.
      *)  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || echo "$target")
          resolved="$top/$configured" ;;
    esac
    resolved_real=$(realdir "$resolved" || echo "$resolved")
    if [ "$resolved_real" != "$default_hooks" ]; then
      fail "core.hooksPath is set to '$configured' in this repo's config, so git does
NOT read $default_hooks — installing there would report success and change nothing.

Install into the directory git actually reads:
  $0 --hooks-dir '$resolved_real' '$target'

or unset the override first:
  git -C '$target' config --unset core.hooksPath"
    fi
  fi
  dest_dir="$default_hooks"
fi

mkdir -p "$dest_dir"
dest="$dest_dir/$hook_name"

is_ours() { [ -f "$1" ] && grep -qF "$MARKER" "$1"; }

# ---- uninstall ---------------------------------------------------------------

if [ "$uninstall" -eq 1 ]; then
  if [ ! -e "$dest" ]; then
    info "nothing to uninstall: $dest does not exist"
    exit 0
  fi
  if ! is_ours "$dest"; then
    fail "$dest is not our hook — refusing to delete it. Remove it by hand if you mean to."
  fi
  rm -f "$dest"
  info "removed $dest"
  exit 0
fi

# ---- refuse to clobber a foreign hook ----------------------------------------

if [ -e "$dest" ] && ! is_ours "$dest"; then
  fail "$dest already exists and is not ours — refusing to overwrite it.

A reference-transaction hook reads its ref list from stdin, and stdin can only be
consumed once, so two hooks cannot simply be run back to back. To run both,
install ours under another name:

  $0 --as reference-transaction.hygiene '$target'

then make your existing hook replay stdin into each one:

  payload=\$(cat)
  printf '%s\n' \"\$payload\" | \"\$(dirname \"\$0\")/reference-transaction.hygiene\" \"\$@\" || exit \$?
  # ... your own checks, also fed from \"\$payload\" ...

Or move yours aside and re-run this installer."
fi

# ---- install ------------------------------------------------------------------
# Back up the file we are about to replace even when it is ours: a previous
# version may have been edited in place, and this is the only copy of it.

action="installed"
if [ -e "$dest" ]; then
  action="updated"
  if ! cmp -s "$SRC" "$dest"; then
    backup="$dest.bak-$(date +%Y%m%d%H%M%S)"
    cp -p "$dest" "$backup"
    info "backed up the previous version to $backup"
  fi
fi

cp "$SRC" "$dest.tmp.$$"
chmod +x "$dest.tmp.$$"
mv -f "$dest.tmp.$$" "$dest"

info "$action $dest"
if [ "$hook_name" = "$SRC_NAME" ]; then
  branches=$(git -C "$target" config --get-all hygiene.protectedBranch 2>/dev/null | tr '\n' ' ' || true)
  info "protecting: ${branches:-main master (default)}"
  info "escape hatch: HYGIENE_ALLOW_REF_UPDATE=1 <git command>"
  info "uninstall:   rm '$dest'"
else
  info "note: installed under a non-default name, so git will NOT run it directly."
  info "      Chain to it from your own $SRC_NAME hook (see --help)."
fi

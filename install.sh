#!/usr/bin/env bash
# install.sh — install claude-herdr-hygiene into your Claude Code config.
#
# Idempotent and additive: safe to re-run (it upgrades files in place and only
# adds settings/CLAUDE.md entries that aren't already there). It backs up
# settings.json and CLAUDE.md before touching them.
#
# Usage:
#   ./install.sh                 # install into ~/.claude
#   ./install.sh /path/to/.claude
#   CLAUDE_DIR=/path/to/.claude ./install.sh
#
# What it does:
#   • copies hooks/, bin/, docs/, skills/land/ into <claude-dir>/
#   • merges the three hooks into <claude-dir>/settings.json  (backup first)
#   • installs/replaces the git-hygiene section in <claude-dir>/CLAUDE.md (backup first)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${1:-${CLAUDE_DIR:-$HOME/.claude}}"
TS="$(date +%Y%m%d-%H%M%S)"

say()  { printf '  • %s\n' "$1"; }
head() { printf '\n%s\n' "$1"; }

# ---- dependency checks -----------------------------------------------------
head "Checking dependencies"
missing=0
for dep in git jq; do
  if command -v "$dep" >/dev/null 2>&1; then say "$dep found"; else
    printf '  ✗ %s is REQUIRED and not found\n' "$dep"; missing=1
  fi
done
[ "$missing" -eq 0 ] || { echo "Install the missing required dependencies and re-run." >&2; exit 1; }
if command -v herdr >/dev/null 2>&1; then
  say "herdr found (full orchestrator/dispatch flow available)"
else
  say "herdr NOT found — optional. The hooks still enforce worktree/main discipline;"
  say "  the dispatch-to-a-worker flow degrades to plain 'git worktree add' (see README)."
fi

# ---- resolve claude dir to an absolute path --------------------------------
mkdir -p "$CLAUDE_DIR"
CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd)"
head "Installing into: $CLAUDE_DIR"

# ---- copy files ------------------------------------------------------------
mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/bin" "$CLAUDE_DIR/docs" "$CLAUDE_DIR/skills/land"
cp "$REPO_DIR"/hooks/git-hygiene-guard.sh          "$CLAUDE_DIR/hooks/"
cp "$REPO_DIR"/hooks/git-hygiene-edit-guard.sh     "$CLAUDE_DIR/hooks/"
cp "$REPO_DIR"/hooks/git-hygiene-dispatch-nudge.sh "$CLAUDE_DIR/hooks/"
cp "$REPO_DIR"/bin/herdr-watch-agent.sh            "$CLAUDE_DIR/bin/"
cp "$REPO_DIR"/bin/land.sh                         "$CLAUDE_DIR/bin/"
cp "$REPO_DIR"/docs/git-hygiene-playbook.md        "$CLAUDE_DIR/docs/"
cp "$REPO_DIR"/skills/land/SKILL.md                "$CLAUDE_DIR/skills/land/"
chmod +x "$CLAUDE_DIR"/hooks/git-hygiene-*.sh "$CLAUDE_DIR"/bin/herdr-watch-agent.sh "$CLAUDE_DIR"/bin/land.sh
say "copied hooks, watcher, land script, playbook, and /land skill"

# ---- merge hooks into settings.json ----------------------------------------
SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "  ✗ $SETTINGS is not valid JSON — fix it and re-run; refusing to touch it." >&2
  exit 1
fi
cp "$SETTINGS" "$SETTINGS.bak-$TS"

GUARD="bash $CLAUDE_DIR/hooks/git-hygiene-guard.sh"
EDIT="bash $CLAUDE_DIR/hooks/git-hygiene-edit-guard.sh"
NUDGE="bash $CLAUDE_DIR/hooks/git-hygiene-dispatch-nudge.sh"

jq \
  --arg guard "$GUARD" --arg edit "$EDIT" --arg nudge "$NUDGE" '
  # identity = an entry whose hooks[] contains a command mentioning this script;
  # such an entry is replaced wholesale (fixes wrong matcher/path/timeout/wrapper)
  # rather than treated as "already done" — a matching filename is not enough.
  def upsert($arr; $sub; $entry):
    ($arr | map(.hooks // [] | any(.command? // "" | contains($sub))) | index(true)) as $idx
    | if $idx == null then $arr + [$entry] else $arr | .[$idx] = $entry end;
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (.hooks.PreToolUse // [])
  | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
  | .hooks.PreToolUse = upsert(.hooks.PreToolUse; "git-hygiene-guard.sh";
      {matcher:"Bash",hooks:[{type:"command",command:$guard,timeout:10,statusMessage:"git hygiene check"}]})
  | .hooks.PreToolUse = upsert(.hooks.PreToolUse; "git-hygiene-edit-guard.sh";
      {matcher:"Edit|Write|NotebookEdit",hooks:[{type:"command",command:$edit,timeout:10,statusMessage:"git hygiene edit check"}]})
  | .hooks.UserPromptSubmit = upsert(.hooks.UserPromptSubmit; "git-hygiene-dispatch-nudge.sh";
      {hooks:[{type:"command",command:$nudge,timeout:10,statusMessage:"git hygiene dispatch check"}]})
' "$SETTINGS.bak-$TS" > "$SETTINGS"
say "merged 3 hooks into settings.json (backup: settings.json.bak-$TS)"

# ---- install/replace CLAUDE.md section -------------------------------------
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SECTION="$REPO_DIR/claude-md/git-hygiene-section.md"
BEGIN="<!-- BEGIN claude-herdr-hygiene -->"
END="<!-- END claude-herdr-hygiene -->"

# Lines outside the exact BEGIN/END markers (used both to detect corruption
# and, after a rewrite, to prove nothing outside the block moved).
claude_md_outside() {
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { inblock = 1; next }
    $0 == end   { inblock = 0; next }
    !inblock    { print }
  ' "$1"
}
claude_md_inside() {
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { inblock = 1; next }
    $0 == end   { inblock = 0; next }
    inblock     { print }
  ' "$1"
}

begin_count=0
end_count=0
if [ -f "$CLAUDE_MD" ]; then
  begin_count=$(grep -Fc "$BEGIN" "$CLAUDE_MD" || true)
  end_count=$(grep -Fc "$END" "$CLAUDE_MD" || true)
fi

if [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
  # No trace of the section at all — safe to append fresh.
  [ -f "$CLAUDE_MD" ] && cp "$CLAUDE_MD" "$CLAUDE_MD.bak-$TS"
  { printf '\n%s\n' "$BEGIN"; cat "$SECTION"; printf '%s\n' "$END"; } >> "$CLAUDE_MD"
  if [ -f "$CLAUDE_MD.bak-$TS" ]; then
    say "appended git-hygiene section to CLAUDE.md (backup: CLAUDE.md.bak-$TS)"
  else
    say "created CLAUDE.md with the git-hygiene section"
  fi
else
  # Something marker-like exists. Detection and replacement must use the
  # identical rule (an exact whole-line match) so they can never disagree —
  # validate strictly, on the untouched file, before writing anything.
  problem=""
  if [ "$begin_count" -ne 1 ]; then
    problem="found $begin_count line(s) containing the BEGIN marker text (need exactly 1)"
  elif [ "$end_count" -ne 1 ]; then
    problem="found $end_count line(s) containing the END marker text (need exactly 1)"
  elif ! grep -Fxq "$BEGIN" "$CLAUDE_MD"; then
    problem="the BEGIN marker line doesn't match exactly (trailing whitespace or extra text) — expected exactly: $BEGIN"
  elif ! grep -Fxq "$END" "$CLAUDE_MD"; then
    problem="the END marker line doesn't match exactly (trailing whitespace or extra text) — expected exactly: $END"
  else
    begin_line=$(grep -Fxn "$BEGIN" "$CLAUDE_MD" | awk -F: 'NR==1{print $1}')
    end_line=$(grep -Fxn "$END" "$CLAUDE_MD" | awk -F: 'NR==1{print $1}')
    if [ "$end_line" -le "$begin_line" ]; then
      problem="the END marker (line $end_line) does not appear after the BEGIN marker (line $begin_line)"
    fi
  fi

  if [ -n "$problem" ]; then
    printf '  ✗ CLAUDE.md has git-hygiene markers install.sh cannot safely replace:\n' >&2
    printf '      %s\n' "$problem" >&2
    printf '    Fix or remove the markers in %s by hand, then re-run. File left untouched.\n' "$CLAUDE_MD" >&2
    exit 1
  fi

  cp "$CLAUDE_MD" "$CLAUDE_MD.bak-$TS"
  WORK="$(mktemp -d)"
  awk -v begin="$BEGIN" -v end="$END" -v section="$SECTION" '
    $0 == begin { print; while ((getline line < section) > 0) print line; close(section); skipping = 1; next }
    $0 == end   { print; skipping = 0; next }
    skipping    { next }
    { print }
  ' "$CLAUDE_MD.bak-$TS" > "$WORK/new-CLAUDE.md"

  # Verify the outcome rather than assume it: exactly one BEGIN/END, the
  # block between them equals the current section, everything else unchanged.
  verify_ok=1
  new_begin=$(grep -Fxc "$BEGIN" "$WORK/new-CLAUDE.md" || true)
  new_end=$(grep -Fxc "$END" "$WORK/new-CLAUDE.md" || true)
  { [ "$new_begin" -eq 1 ] && [ "$new_end" -eq 1 ]; } || verify_ok=0
  if [ "$verify_ok" -eq 1 ]; then
    claude_md_inside "$WORK/new-CLAUDE.md" > "$WORK/inside-new"
    diff -q "$WORK/inside-new" "$SECTION" >/dev/null 2>&1 || verify_ok=0
  fi
  if [ "$verify_ok" -eq 1 ]; then
    claude_md_outside "$CLAUDE_MD.bak-$TS" > "$WORK/outside-before"
    claude_md_outside "$WORK/new-CLAUDE.md" > "$WORK/outside-after"
    diff -q "$WORK/outside-before" "$WORK/outside-after" >/dev/null 2>&1 || verify_ok=0
  fi

  if [ "$verify_ok" -eq 1 ]; then
    cp "$WORK/new-CLAUDE.md" "$CLAUDE_MD"
    rm -rf "$WORK"
    say "replaced git-hygiene section in CLAUDE.md (backup: CLAUDE.md.bak-$TS)"
  else
    cp "$CLAUDE_MD.bak-$TS" "$CLAUDE_MD"
    rm -rf "$WORK"
    printf '  ✗ post-write verification failed rewriting CLAUDE.md — restored from backup (%s). This indicates a bug in install.sh; please report it.\n' "$CLAUDE_MD.bak-$TS" >&2
    exit 1
  fi
fi

# ---- done ------------------------------------------------------------------
head "Done."
cat <<EOF
  Reload note: hooks registered in settings.json are picked up by NEW Claude Code
  sessions automatically. An already-running session needs '/hooks' opened once
  (reloads config) or a restart before these fire.

  Review or disable any hook anytime with '/hooks'. Uninstall: see README.
EOF

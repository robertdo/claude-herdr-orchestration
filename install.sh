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
#   • appends the git-hygiene section to <claude-dir>/CLAUDE.md (backup first)
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
cp "$REPO_DIR"/docs/git-hygiene-playbook.md        "$CLAUDE_DIR/docs/"
cp "$REPO_DIR"/skills/land/SKILL.md                "$CLAUDE_DIR/skills/land/"
chmod +x "$CLAUDE_DIR"/hooks/git-hygiene-*.sh "$CLAUDE_DIR"/bin/herdr-watch-agent.sh
say "copied hooks, watcher, playbook, and /land skill"

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
  def cmds: [(.hooks // {}) | .. | objects | select(has("command")) | .command];
  def present($sub): (cmds | any(contains($sub)));
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (.hooks.PreToolUse // [])
  | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
  | (if present("git-hygiene-guard.sh") then .
     else .hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$guard,timeout:10,statusMessage:"git hygiene check"}]}] end)
  | (if present("git-hygiene-edit-guard.sh") then .
     else .hooks.PreToolUse += [{matcher:"Edit|Write|NotebookEdit",hooks:[{type:"command",command:$edit,timeout:10,statusMessage:"git hygiene edit check"}]}] end)
  | (if present("git-hygiene-dispatch-nudge.sh") then .
     else .hooks.UserPromptSubmit += [{hooks:[{type:"command",command:$nudge,timeout:10,statusMessage:"git hygiene dispatch check"}]}] end)
' "$SETTINGS.bak-$TS" > "$SETTINGS"
say "merged 3 hooks into settings.json (backup: settings.json.bak-$TS)"

# ---- append CLAUDE.md section ----------------------------------------------
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SECTION="$REPO_DIR/claude-md/git-hygiene-section.md"
BEGIN="<!-- BEGIN claude-herdr-hygiene -->"
END="<!-- END claude-herdr-hygiene -->"
if [ -f "$CLAUDE_MD" ] && grep -qF "$BEGIN" "$CLAUDE_MD"; then
  say "CLAUDE.md already has the git-hygiene section — skipped"
else
  [ -f "$CLAUDE_MD" ] && cp "$CLAUDE_MD" "$CLAUDE_MD.bak-$TS"
  { printf '\n%s\n' "$BEGIN"; cat "$SECTION"; printf '%s\n' "$END"; } >> "$CLAUDE_MD"
  if [ -f "$CLAUDE_MD.bak-$TS" ]; then
    say "appended git-hygiene section to CLAUDE.md (backup: CLAUDE.md.bak-$TS)"
  else
    say "created CLAUDE.md with the git-hygiene section"
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

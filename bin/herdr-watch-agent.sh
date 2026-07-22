#!/bin/bash
# herdr-watch-agent.sh <pane_id> [max_seconds]
# Blocks until the agent in <pane_id> reaches a terminal attention state, then
# prints it: "done"/"idle" (finished), "blocked" (needs input), "gone" (pane
# closed). Orchestrator sessions run this as a BACKGROUND Bash task after
# dispatching a worker, so the session stays free for the user and for
# dispatching more workers in parallel; the watcher exiting wakes the session.
# Call only after confirming the worker reached "working", otherwise the
# pre-task "idle" state matches immediately.
pane=$1
max=${2:-14400}
[ -n "$pane" ] || { echo "usage: herdr-watch-agent.sh <pane_id> [max_seconds]" >&2; exit 2; }
start=$(date +%s)
while :; do
  herdr pane get "$pane" >/dev/null 2>&1 || { echo "gone"; exit 1; }
  for s in done blocked idle; do
    if herdr wait agent-status "$pane" --status "$s" --timeout 15000 >/dev/null 2>&1; then
      echo "$s"
      exit 0
    fi
  done
  [ $(( $(date +%s) - start )) -ge "$max" ] && { echo "timeout"; exit 1; }
done

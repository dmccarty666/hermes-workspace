#!/usr/bin/env bash
# orchestrator-heartbeat.sh — single-tick driver for the hermes-memory orchestrator
#
# Invoked by cron every 30 minutes. Spawns a fresh `hermes -p hm-orchestrator`
# process with the heartbeat prompt and a hard timeout. The SOUL governs
# behavior; this script is just plumbing.
#
# The cron job that calls this can be created via `cronjob(action='create', ...)`
# OR via direct crontab. See docs/KANBAN_OPERATIONS.md §10 for the canonical
# enable/disable procedure.
#
# Manual invocations:
#   ./orchestrator-heartbeat.sh                    # run once, log to STDOUT
#   ./orchestrator-heartbeat.sh --dry-run          # print what would be run, exit
#   ./orchestrator-heartbeat.sh --verbose          # also print prompt
#
# Exit codes:
#   0 — tick ran cleanly
#   1 — internal error
#   2 — invocation error (bad args, etc.)
#   3 — guard tripped (lock file present, cooldown not met) — NOT an error

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ORCH_DIR="${PROJECT_DIR}/orchestrator"
LOCK_FILE="${ORCH_DIR}/.lock"
LOG_FILE="${ORCH_DIR}/heartbeat.log"
HARD_TIMEOUT_SECONDS=900   # 15 min — generous; orchestrator should finish in <2 min

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

dry_run=0
verbose=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        --verbose) verbose=1 ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

if [[ ! -d "$ORCH_DIR" ]]; then
    echo "ERROR: orchestrator dir missing: $ORCH_DIR" >&2
    exit 1
fi

if [[ ! -f "${ORCH_DIR}/GOAL.md" ]]; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') tick: skipped (no GOAL.md)" >> "$LOG_FILE"
    exit 0
fi

# Lock guard — if another tick is in progress, bail
if [[ -f "$LOCK_FILE" ]]; then
    lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE") ))
    if [[ $lock_age -lt 1800 ]]; then
        echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') tick: skipped (lock held, age ${lock_age}s)" >> "$LOG_FILE"
        exit 3
    fi
    # Lock older than 30 min → previous tick likely crashed, take over
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') tick: stale lock removed (age ${lock_age}s)" >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
fi

# ---------------------------------------------------------------------------
# Compose the prompt
# ---------------------------------------------------------------------------

# The orchestrator's SOUL.md does the heavy lifting. We just hand it the
# instruction to run a tick. Keep this prompt tiny and stable — changing it
# changes orchestrator behavior across all ticks, which is high-leverage.

read -r -d '' PROMPT <<'EOF' || true
You are the hermes-memory orchestrator. Run one tick per your SOUL.md.

Workflow:
  1. Read orchestrator/GOAL.md and orchestrator/STATE.md (under
     ~/.hermes/PROJECTS/hermes-memory/).
  2. Check cooldown (last_heartbeat > 10 min ago).
  3. Acquire the lock file (already touched by the heartbeat script —
     verify it exists; if not, create it).
  4. Inspect the board (hermes kanban ls / show / diagnostics).
  5. Decide ONE primary action per the state machine.
  6. Identify any side-state issues per SOUL §4.
  7. Take at most 3 actions in priority order.
  8. Update STATE.md (new heartbeat, new state if transitioned, current side
     issues).
  9. Append exactly one entry to HISTORY.md.
 10. Remove the lock file.
 11. Exit.

Stay within your tool surface (SOUL §10). When in doubt, escalate via
send_message to telegram. Never auto-approve human decisions. Never write
code or modify Plan.md / PRD.md / TDD.md / ADRs / GOAL.md.

If anything is unclear or the state file doesn't parse cleanly, append a
HISTORY entry noting the issue, ping David (urgency=attention), remove the
lock, and exit.
EOF

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------

if [[ $dry_run -eq 1 ]]; then
    echo "Would run:"
    echo "  hermes -p hm-orchestrator chat -q '<prompt>' (timeout=${HARD_TIMEOUT_SECONDS}s)"
    if [[ $verbose -eq 1 ]]; then
        echo
        echo "Prompt:"
        echo "$PROMPT"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Run the tick
# ---------------------------------------------------------------------------

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

tick_started=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
echo "$tick_started tick: starting" >> "$LOG_FILE"

# Run hermes in a fresh process with a hard timeout. Capture exit code.
# stdout/stderr land in the heartbeat.log file.
set +e
timeout "${HARD_TIMEOUT_SECONDS}" \
    hermes -p hm-orchestrator chat -q "$PROMPT" \
    >> "$LOG_FILE" 2>&1
exit_code=$?
set -e

tick_ended=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

case $exit_code in
    0)
        echo "$tick_ended tick: completed cleanly" >> "$LOG_FILE"
        ;;
    124)
        echo "$tick_ended tick: TIMED OUT after ${HARD_TIMEOUT_SECONDS}s" >> "$LOG_FILE"
        # Worth flagging — but don't try to escalate from this script.
        # The orchestrator should detect missing-heartbeat via its own logic on next run.
        ;;
    *)
        echo "$tick_ended tick: hermes exited with code $exit_code" >> "$LOG_FILE"
        ;;
esac

# Lock cleanup happens via trap.
exit $exit_code

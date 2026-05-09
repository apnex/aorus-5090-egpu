#!/usr/bin/env bash
# close-path-probe.sh — controlled close-path observability experiment.
#
# Purpose: deliberately exercise the close-path on /dev/nvidia0 with
# Patch 0029 instrumentation active, capturing baseline + post-trigger
# state for diff analysis. Use this to characterise what the close
# path actually does to PMC_BOOT_0 / WPR2 / LnkSta / AER state — the
# "what changed across close that breaks the next open" question.
#
# Methodology:
#   1. Capture baseline state via state-capture.sh
#   2. Drain GPU consumers (persistenced + uvm-keepalive)
#   3. Capture pre-trigger snapshot
#   4. Trigger close-path: nvidia-smi -L (opens, queries, closes)
#   5. Wait for any recovery to settle (~20s)
#   6. Capture post-trigger snapshot
#   7. Restart consumers
#   8. Run state-capture-diff vs baseline
#   9. Run event-capture against the trigger window to evaluate hypotheses
#
# Output: archive/close-path-probes/<run-id>/ with all dossiers.

set -u

REPO_ROOT="${REPO_ROOT:-/root/aorus-5090-egpu}"
[[ -r /usr/local/lib/aorus-egpu/common.sh ]] && source /usr/local/lib/aorus-egpu/common.sh
GPU_BDF="${EGPU_BDF:-0000:04:00.0}"
SYSFS="/sys/bus/pci/devices/$GPU_BDF"
RUN_ID="$(date -Iseconds | tr ':' '-')"
RUN_DIR="$REPO_ROOT/archive/close-path-probes/$RUN_ID"
WAIT_SETTLE=20

if [[ "$EUID" -ne 0 ]]; then
    echo "close-path-probe.sh must be run as root" >&2
    exit 1
fi

if [[ ! -d "$SYSFS" ]]; then
    echo "GPU not present at $SYSFS — eGPU disconnected?" >&2
    exit 1
fi

mkdir -p "$RUN_DIR"

step() { printf '\n=== %s ===\n' "$*" | tee -a "$RUN_DIR/run.log"; }
log() { printf '%s\n' "$*" | tee -a "$RUN_DIR/run.log"; }

step "preflight"
log "GPU BDF: $GPU_BDF"
log "Run ID:  $RUN_ID"
log "Output:  $RUN_DIR"
log ""
log "Pre-trigger M-recover counters:"
log "  fires:        $(cat $SYSFS/aorus_lever_m_fires 2>/dev/null || echo n/a)"
log "  successes:    $(cat $SYSFS/aorus_lever_m_successes 2>/dev/null || echo n/a)"
log "  surrenders:   $(cat $SYSFS/aorus_lever_m_surrenders 2>/dev/null || echo n/a)"

step "step 1: baseline state-capture"
"$REPO_ROOT/tools/state-capture/state-capture.sh" 2>&1 | tee -a "$RUN_DIR/run.log" || true
# Find the most-recent state-capture dossier and link it.
recent_state=$(ls -1dt "$REPO_ROOT"/archive/state-captures/*/ 2>/dev/null | head -1 | sed 's:/$::')
if [[ -n "$recent_state" ]]; then
    ln -sfn "$recent_state" "$RUN_DIR/01-baseline-state"
    log "linked baseline state -> $recent_state"
fi

step "step 2: drain GPU consumers"
systemctl stop nvidia-persistenced 2>&1 | tee -a "$RUN_DIR/run.log" || true
systemctl stop aorus-egpu-uvm-keepalive 2>&1 | tee -a "$RUN_DIR/run.log" || true
sleep 1
log "remaining /dev/nvidia* holders:"
lsof /dev/nvidia* 2>/dev/null | tee -a "$RUN_DIR/run.log" || log "(none)"

step "step 3: pre-trigger dmesg snapshot"
dmesg > "$RUN_DIR/02-dmesg-pre-trigger.log"
log "saved $(wc -l < "$RUN_DIR/02-dmesg-pre-trigger.log") lines"

step "step 4: trigger close-path"
log "running nvidia-smi -L (opens /dev/nvidia0, queries, closes)"
nvidia-smi -L > "$RUN_DIR/03-nvidia-smi-output.log" 2>&1 || true
log "exit code: $?"
log "output:"
cat "$RUN_DIR/03-nvidia-smi-output.log" | sed 's/^/  /' | tee -a "$RUN_DIR/run.log"

step "step 5: settle (${WAIT_SETTLE}s)"
sleep "$WAIT_SETTLE"

step "step 6: post-trigger dmesg snapshot"
dmesg > "$RUN_DIR/04-dmesg-post-trigger.log"
log "saved $(wc -l < "$RUN_DIR/04-dmesg-post-trigger.log") lines"
log "delta: $(($(wc -l < "$RUN_DIR/04-dmesg-post-trigger.log") - $(wc -l < "$RUN_DIR/02-dmesg-pre-trigger.log"))) new lines"

step "step 7: dmesg delta — close-path + M-recover events"
diff "$RUN_DIR/02-dmesg-pre-trigger.log" "$RUN_DIR/04-dmesg-post-trigger.log" \
    | grep -E "^>" \
    | grep -iE "AORUS Lever|nvidia 0000:04|NVRM" \
    | tee "$RUN_DIR/05-dmesg-delta-relevant.log" || true

step "step 8: post-trigger state-capture"
"$REPO_ROOT/tools/state-capture/state-capture.sh" 2>&1 | tee -a "$RUN_DIR/run.log" || true
recent_state2=$(ls -1dt "$REPO_ROOT"/archive/state-captures/*/ 2>/dev/null | head -1 | sed 's:/$::')
if [[ -n "$recent_state2" && "$recent_state2" != "$recent_state" ]]; then
    ln -sfn "$recent_state2" "$RUN_DIR/06-post-trigger-state"
    log "linked post-trigger state -> $recent_state2"
fi

step "step 9: state diff (baseline vs post-trigger)"
if [[ -n "$recent_state" && -n "$recent_state2" && "$recent_state" != "$recent_state2" ]]; then
    "$REPO_ROOT/tools/state-capture/state-capture-diff.sh" \
        "$recent_state" "$recent_state2" > "$RUN_DIR/07-state-diff.log" 2>&1 || true
    log "saved state diff to 07-state-diff.log"
fi

step "step 10: event-capture for this window"
"$REPO_ROOT/tools/event-capture/event-capture.sh" \
    --experiment "close-path-probe-$RUN_ID" \
    --hypothesis close-path-lifecycle \
    --hypothesis close-path-wedge-cycle 2>&1 | tee -a "$RUN_DIR/run.log" || true
recent_event=$(ls -1dt "$REPO_ROOT"/archive/event-captures/close-path-probe-* 2>/dev/null | head -1)
if [[ -n "$recent_event" ]]; then
    ln -sfn "$recent_event" "$RUN_DIR/08-event-capture"
    log "linked event capture -> $recent_event"
fi

step "step 11: restore GPU consumers"
systemctl start aorus-egpu-uvm-keepalive 2>&1 | tee -a "$RUN_DIR/run.log" || true
systemctl start nvidia-persistenced 2>&1 | tee -a "$RUN_DIR/run.log" || true
sleep 2

step "step 12: post-restore counters"
log "Post-trigger M-recover counters:"
log "  fires:        $(cat $SYSFS/aorus_lever_m_fires 2>/dev/null || echo n/a)"
log "  successes:    $(cat $SYSFS/aorus_lever_m_successes 2>/dev/null || echo n/a)"
log "  surrenders:   $(cat $SYSFS/aorus_lever_m_surrenders 2>/dev/null || echo n/a)"

step "summary"
log "Run dossier: $RUN_DIR"
log "Inspect:"
log "  - 02-dmesg-pre-trigger.log    state before nvidia-smi"
log "  - 04-dmesg-post-trigger.log   state after nvidia-smi"
log "  - 05-dmesg-delta-relevant.log close-path + M-recover events the trigger produced"
log "  - 07-state-diff.log           sysfs/PCI state diff baseline vs post"
log "  - 08-event-capture/           hypothesis verdicts"

exit 0

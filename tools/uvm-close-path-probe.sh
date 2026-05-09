#!/usr/bin/env bash
# uvm-close-path-probe.sh — controlled UVM close-path observability experiment.
#
# Purpose: deliberately exercise /dev/nvidia-uvm's close path with Patch 0030
# instrumentation active, capturing full state diff across the open->close
# lifecycle. UVM-side analogue of close-path-probe.sh.
#
# Methodology:
#   1. Capture baseline state-capture
#   2. Drain UVM consumers (uvm-keepalive holds /dev/nvidia-uvm + tools)
#      (we leave persistenced up — it doesn't hold UVM, and stopping it
#       would conflate two close-paths in one experiment)
#   3. Capture pre-trigger dmesg
#   4. Trigger UVM close-path: run cuda-driver-api-smoke-test.py — does
#      cuInit + cuCtxCreate + cuMemAlloc + cleanup + exit. The exit closes
#      /dev/nvidia-uvm. If usage_count was 0 before (uvm-keepalive drained),
#      this is the first-after-LAST-CLOSE; the smoke test process is the
#      LAST-CLOSE on its own exit.
#   5. Wait for any teardown to settle (~20s)
#   6. Capture post-trigger dmesg + state-capture
#   7. Restore uvm-keepalive
#   8. Diff state vs baseline + run event-capture
#
# Output: archive/uvm-close-path-probes/<run-id>/

set -u

REPO_ROOT="${REPO_ROOT:-/root/aorus-5090-egpu}"
[[ -r /usr/local/lib/aorus-egpu/common.sh ]] && source /usr/local/lib/aorus-egpu/common.sh
GPU_BDF="${EGPU_BDF:-0000:04:00.0}"
SYSFS="/sys/bus/pci/devices/$GPU_BDF"
SMOKE_TEST="$REPO_ROOT/tools/cuda-driver-api-smoke-test.py"
RUN_ID="$(date -Iseconds | tr ':' '-')"
RUN_DIR="$REPO_ROOT/archive/uvm-close-path-probes/$RUN_ID"
WAIT_SETTLE=20

if [[ "$EUID" -ne 0 ]]; then
    echo "uvm-close-path-probe.sh must be run as root" >&2
    exit 1
fi

if [[ ! -d "$SYSFS" ]]; then
    echo "GPU not present at $SYSFS — eGPU disconnected?" >&2
    exit 1
fi

if [[ ! -x "$SMOKE_TEST" ]]; then
    echo "smoke test missing or not executable: $SMOKE_TEST" >&2
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
recent_state=$(ls -1dt "$REPO_ROOT"/archive/state-captures/*/ 2>/dev/null | head -1 | sed 's:/$::')
[[ -n "$recent_state" ]] && ln -sfn "$recent_state" "$RUN_DIR/01-baseline-state"

step "step 2: drain UVM consumers"
log "stopping aorus-egpu-uvm-keepalive (the sleep that holds /dev/nvidia-uvm + tools)"
systemctl stop aorus-egpu-uvm-keepalive 2>&1 | tee -a "$RUN_DIR/run.log" || true
log "stopping ollama (if running) — its runners can hold UVM"
systemctl stop ollama 2>&1 | tee -a "$RUN_DIR/run.log" || true
sleep 1
log "remaining /dev/nvidia-uvm* holders:"
lsof /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null | tee -a "$RUN_DIR/run.log" || log "(none)"

step "step 3: pre-trigger dmesg snapshot"
dmesg > "$RUN_DIR/02-dmesg-pre-trigger.log"
log "saved $(wc -l < "$RUN_DIR/02-dmesg-pre-trigger.log") lines"

step "step 4: trigger UVM close-path via cuda-driver-api-smoke-test"
log "running $SMOKE_TEST"
"$SMOKE_TEST" > "$RUN_DIR/03-smoke-test-output.log" 2>&1
rc=$?
log "exit code: $rc"
log "output:"
sed 's/^/  /' "$RUN_DIR/03-smoke-test-output.log" | tee -a "$RUN_DIR/run.log"

step "step 5: settle (${WAIT_SETTLE}s)"
sleep "$WAIT_SETTLE"

step "step 6: post-trigger dmesg snapshot"
dmesg > "$RUN_DIR/04-dmesg-post-trigger.log"
log "delta: $(($(wc -l < "$RUN_DIR/04-dmesg-post-trigger.log") - $(wc -l < "$RUN_DIR/02-dmesg-pre-trigger.log"))) new lines"

step "step 7: dmesg delta — UVM close-path + M-recover events"
diff "$RUN_DIR/02-dmesg-pre-trigger.log" "$RUN_DIR/04-dmesg-post-trigger.log" \
    | grep -E "^>" \
    | grep -iE "AORUS UVM|UVM-DIAG|AORUS Lever|nvidia 0000:04|NVRM" \
    | tee "$RUN_DIR/05-dmesg-delta-relevant.log" || true

step "step 8: post-trigger state-capture"
"$REPO_ROOT/tools/state-capture/state-capture.sh" 2>&1 | tee -a "$RUN_DIR/run.log" || true
recent_state2=$(ls -1dt "$REPO_ROOT"/archive/state-captures/*/ 2>/dev/null | head -1 | sed 's:/$::')
if [[ -n "$recent_state2" && "$recent_state2" != "$recent_state" ]]; then
    ln -sfn "$recent_state2" "$RUN_DIR/06-post-trigger-state"
fi

step "step 9: state diff (baseline vs post-trigger)"
if [[ -n "$recent_state" && -n "$recent_state2" && "$recent_state" != "$recent_state2" ]]; then
    "$REPO_ROOT/tools/state-capture/state-capture-diff.sh" \
        "$recent_state" "$recent_state2" > "$RUN_DIR/07-state-diff.log" 2>&1 || true
    log "saved state diff to 07-state-diff.log"
fi

step "step 10: restore UVM consumers"
systemctl start aorus-egpu-uvm-keepalive 2>&1 | tee -a "$RUN_DIR/run.log" || true
systemctl start ollama 2>&1 | tee -a "$RUN_DIR/run.log" || true
sleep 2

step "step 11: post-restore counters"
log "Post-trigger M-recover counters:"
log "  fires:        $(cat $SYSFS/aorus_lever_m_fires 2>/dev/null || echo n/a)"
log "  successes:    $(cat $SYSFS/aorus_lever_m_successes 2>/dev/null || echo n/a)"
log "  surrenders:   $(cat $SYSFS/aorus_lever_m_surrenders 2>/dev/null || echo n/a)"

step "summary"
log "Run dossier: $RUN_DIR"
log "Inspect:"
log "  - 03-smoke-test-output.log    cuda smoke output (cuInit / cuMemAlloc results)"
log "  - 04-dmesg-post-trigger.log   full post-trigger dmesg"
log "  - 05-dmesg-delta-relevant.log UVM [CLOSE], [UVM-DIAG], M-recover events"
log "  - 07-state-diff.log           sysfs/PCI state diff baseline vs post"
log "  - 01-baseline-state /         06-post-trigger-state"

exit 0

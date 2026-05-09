#!/usr/bin/env bash
# uvm-churn-probe.sh — UVM rapid-churn + delayed-reopen close-path probe.
#
# Mimics the 2026-05-02 freeze pattern that uvm-keepalive was originally
# built to mitigate (Problem 4 in architecture.md):
#   - 4× cuda-smoke runs in rapid succession (the ollama daemon's
#     "discovery" pattern: 4 runner subprocesses spawned + exited at
#     startup, each closing /dev/nvidia-uvm)
#   - 60s idle gap (typical wait before an unrelated process opens UVM)
#   - 1× final cuda-smoke (the "next opener" — historically the wedge
#     moment when UVM open-count went 0→1 after a prior LAST-CLOSE)
#
# Companion to uvm-close-path-probe.sh (single-shot). This script tests
# whether ANY of the timing patterns from the historical freeze
# reproduce on the current driver build with Patch 0030 instrumentation.
# n=3 of these constitutes the "rapid-churn + delayed-reopen" coverage
# needed to confidently retire uvm-keepalive.
#
# Output: archive/uvm-churn-probes/<run-id>/

set -u

REPO_ROOT="${REPO_ROOT:-/root/aorus-5090-egpu}"
[[ -r /usr/local/lib/aorus-egpu/common.sh ]] && source /usr/local/lib/aorus-egpu/common.sh
GPU_BDF="${EGPU_BDF:-0000:04:00.0}"
SYSFS="/sys/bus/pci/devices/$GPU_BDF"
SMOKE_TEST="$REPO_ROOT/tools/cuda-driver-api-smoke-test.py"
RUN_ID="$(date -Iseconds | tr ':' '-')"
RUN_DIR="$REPO_ROOT/archive/uvm-churn-probes/$RUN_ID"
RAPID_RUNS=4
IDLE_GAP_SEC=60
WAIT_SETTLE=20

if [[ "$EUID" -ne 0 ]]; then
    echo "uvm-churn-probe.sh must be run as root" >&2
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

read_counters() {
    printf 'fires=%s successes=%s surrenders=%s' \
        "$(cat $SYSFS/aorus_lever_m_fires 2>/dev/null || echo n/a)" \
        "$(cat $SYSFS/aorus_lever_m_successes 2>/dev/null || echo n/a)" \
        "$(cat $SYSFS/aorus_lever_m_surrenders 2>/dev/null || echo n/a)"
}

step "preflight"
log "GPU BDF: $GPU_BDF"
log "Run ID:  $RUN_ID"
log "Output:  $RUN_DIR"
log "Pattern: $RAPID_RUNS× rapid + ${IDLE_GAP_SEC}s idle + 1× delayed"
log ""
log "Pre-trigger M-recover: $(read_counters)"

step "step 1: drain UVM consumers"
systemctl stop aorus-egpu-uvm-keepalive 2>&1 | tee -a "$RUN_DIR/run.log" || true
systemctl stop ollama 2>&1 | tee -a "$RUN_DIR/run.log" || true
sleep 1
log "remaining /dev/nvidia-uvm* holders:"
lsof /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null | tee -a "$RUN_DIR/run.log" || log "(none)"

step "step 2: pre-trigger dmesg snapshot"
dmesg > "$RUN_DIR/02-dmesg-pre-trigger.log"
log "saved $(wc -l < "$RUN_DIR/02-dmesg-pre-trigger.log") lines"

step "step 3: rapid-churn phase ($RAPID_RUNS× cuda-smoke back-to-back)"
for i in $(seq 1 "$RAPID_RUNS"); do
    log "--- rapid run #$i ---"
    "$SMOKE_TEST" > "$RUN_DIR/03-rapid-${i}-output.log" 2>&1
    rc=$?
    last=$(tail -1 "$RUN_DIR/03-rapid-${i}-output.log")
    log "rapid #$i: rc=$rc last_line=\"$last\""
    if [[ $rc -ne 0 ]]; then
        log "WARNING: rapid run #$i FAILED — continuing to capture full sequence"
    fi
done
log "rapid phase counters: $(read_counters)"

step "step 4: idle gap (${IDLE_GAP_SEC}s) — mimics 2026-05-02 \"unrelated process opens UVM minutes later\""
sleep "$IDLE_GAP_SEC"
log "idle phase counters: $(read_counters)"

step "step 5: delayed-reopen phase (1× cuda-smoke after idle)"
"$SMOKE_TEST" > "$RUN_DIR/05-delayed-output.log" 2>&1
rc=$?
last=$(tail -1 "$RUN_DIR/05-delayed-output.log")
log "delayed: rc=$rc last_line=\"$last\""

step "step 6: settle (${WAIT_SETTLE}s)"
sleep "$WAIT_SETTLE"

step "step 7: post-trigger dmesg snapshot"
dmesg > "$RUN_DIR/07-dmesg-post-trigger.log"
log "delta: $(($(wc -l < "$RUN_DIR/07-dmesg-post-trigger.log") - $(wc -l < "$RUN_DIR/02-dmesg-pre-trigger.log"))) new lines"

step "step 8: dmesg delta — UVM + close-path + M-recover events"
diff "$RUN_DIR/02-dmesg-pre-trigger.log" "$RUN_DIR/07-dmesg-post-trigger.log" \
    | grep -E "^>" \
    | grep -iE "AORUS UVM|UVM-DIAG|AORUS Lever|nvidia 0000:04|NVRM" \
    > "$RUN_DIR/08-dmesg-delta-relevant.log" || true
log "events captured: $(wc -l < "$RUN_DIR/08-dmesg-delta-relevant.log")"

step "step 9: count UVM LAST-CLOSE events in delta"
LAST_CLOSE_COUNT=$(grep -c "(LAST-CLOSE)" "$RUN_DIR/08-dmesg-delta-relevant.log")
log "LAST-CLOSE events: $LAST_CLOSE_COUNT"
log "uvm-pre-destroy:   $(grep -c 'uvm-pre-destroy' "$RUN_DIR/08-dmesg-delta-relevant.log")"
log "uvm-post-destroy:  $(grep -c 'uvm-post-destroy' "$RUN_DIR/08-dmesg-delta-relevant.log")"

step "step 10: WPR2 + LnkSta state across LAST-CLOSE events"
grep "UVM-DIAG" "$RUN_DIR/08-dmesg-delta-relevant.log" \
    | sed -E 's/.*site=([^ ]+).*WPR2=([^ ]+).*GPU_LnkSta=([^ ]+) Br_LnkSta=([^ ]+).*/  \1: WPR2=\2 GPU=\3 Br=\4/' \
    | tee "$RUN_DIR/09-state-summary.log"

step "step 11: restore UVM consumers"
systemctl start aorus-egpu-uvm-keepalive 2>&1 | tee -a "$RUN_DIR/run.log" || true
systemctl start ollama 2>&1 | tee -a "$RUN_DIR/run.log" || true
sleep 2

step "step 12: post-restore counters"
log "Final M-recover: $(read_counters)"

step "summary"
log "Run dossier: $RUN_DIR"
log "Pattern produced $LAST_CLOSE_COUNT UVM LAST-CLOSE events across $RAPID_RUNS+1=$((RAPID_RUNS+1)) cuda-smoke invocations + 1 delayed reopen"
log ""
log "Inspect:"
log "  - 03-rapid-N-output.log      output of rapid phase runs"
log "  - 05-delayed-output.log      output of delayed-reopen run"
log "  - 08-dmesg-delta-relevant.log full event timeline"
log "  - 09-state-summary.log        WPR2/LnkSta state at each UVM-DIAG site"

exit 0

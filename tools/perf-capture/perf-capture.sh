#!/usr/bin/env bash
# perf-capture.sh — standardised performance test with rich telemetry.
#
# Third tool in the matched-pair forensic family:
#
#   state-capture  = STATE snapshot (sysfs/PCI/debugfs at one moment)
#   event-capture  = EVENTS over time (kernel logs + hypothesis verdicts)
#   perf-capture   = PERFORMANCE under named workload (this tool)
#
# Each invocation produces a dossier containing:
#   - pre/post state captures (symlinks to companion dossiers)
#   - event capture spanning the test window
#   - per-iteration raw workload output
#   - metrics CSV
#   - sysfs sampler CSV
#   - human-readable summary + verdict
#   - self-contained reproduction.sh
#
# Workloads are pluggable: drop a file into workloads/<name>.sh that defines
#   WORKLOAD_NAME, WORKLOAD_DESC, WORKLOAD_CMD, WORKLOAD_ITERATION_TIMEOUT,
#   METRICS_REGEX, METRICS_UNIT
# and it's auto-discovered.
#
# Usage:
#   sudo perf-capture.sh \
#       --experiment <name> \
#       --workload <workload-id> \
#       [--duration <secs>] \
#       [--samples-interval <secs>] \
#       [--changed key=value]    # repeatable
#
# Output: archive/perf-captures/<exp-name>-<timestamp>/
#
# Compare two dossiers:
#   ./perf-capture-diff.sh dossier_A dossier_B

set -u
shopt -s nullglob

if [[ "$EUID" -ne 0 ]]; then
    echo "perf-capture.sh must run as root (state-capture + sysfs writes)." >&2
    exit 1
fi

# ---- Paths ----
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="${REPO_ROOT:-/root/aorus-5090-egpu}"
WORKLOADS_DIR="$SCRIPT_DIR/workloads"
STATE_CAPTURE="$REPO_ROOT/tools/state-capture/state-capture.sh"
EVENT_CAPTURE="$REPO_ROOT/tools/event-capture/event-capture.sh"

# ---- Args ----
EXPERIMENT=""
WORKLOAD=""
DURATION_OVERRIDE=""
SAMPLES_INTERVAL=15
CHANGED=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --experiment)        EXPERIMENT="$2"; shift 2 ;;
        --workload)          WORKLOAD="$2"; shift 2 ;;
        --duration)          DURATION_OVERRIDE="$2"; shift 2 ;;
        --samples-interval)  SAMPLES_INTERVAL="$2"; shift 2 ;;
        --changed)           CHANGED+=("$2"); shift 2 ;;
        --help|-h)
            sed -n '2,30p' "$0" | sed 's|^# \?||'
            echo
            echo "Available workloads:"
            for w in "$WORKLOADS_DIR"/*.sh; do
                [[ -f "$w" ]] || continue
                ( . "$w"; printf '  %-30s %s\n' "$WORKLOAD_NAME" "$WORKLOAD_DESC" )
            done
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$EXPERIMENT" ]] && { echo "--experiment required" >&2; exit 1; }
[[ -z "$WORKLOAD" ]] && { echo "--workload required" >&2; exit 1; }

WORKLOAD_FILE="$WORKLOADS_DIR/${WORKLOAD}.sh"
[[ -f "$WORKLOAD_FILE" ]] || { echo "workload not found: $WORKLOAD_FILE" >&2; exit 1; }

# ---- Source workload definition ----
WORKLOAD_NAME=""
WORKLOAD_DESC=""
WORKLOAD_CMD=""
WORKLOAD_ITERATION_TIMEOUT=120
WORKLOAD_INTER_ITERATION_DELAY=0  # seconds to sleep between iters (cooling)
METRICS_REGEX=''
METRICS_UNIT="unit"
WORKLOAD_DURATION=420   # default 7 min
. "$WORKLOAD_FILE"
DURATION="${DURATION_OVERRIDE:-$WORKLOAD_DURATION}"

# ---- Output dossier ----
TIMESTAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
HOSTNAME=$(hostname)
OUT="$REPO_ROOT/archive/perf-captures/${EXPERIMENT}-${TIMESTAMP}"
mkdir -p "$OUT/20-iterations"

step() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
step "experiment=$EXPERIMENT workload=$WORKLOAD duration=${DURATION}s"
step "output: $OUT"

# ---- 00 Meta ----
{
    printf 'experiment_name=%s\n' "$EXPERIMENT"
    printf 'workload=%s\n' "$WORKLOAD"
    printf 'workload_desc=%s\n' "$WORKLOAD_DESC"
    printf 'workload_cmd=%s\n' "$WORKLOAD_CMD"
    printf 'workload_iteration_timeout=%s\n' "$WORKLOAD_ITERATION_TIMEOUT"
    printf 'duration_cap=%s\n' "$DURATION"
    printf 'samples_interval=%s\n' "$SAMPLES_INTERVAL"
    printf 'timestamp_utc=%s\n' "$TIMESTAMP"
    printf 'hostname=%s\n' "$HOSTNAME"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
    if command -v modinfo >/dev/null 2>&1; then
        printf 'nvidia_srcversion=%s\n' "$(modinfo nvidia 2>/dev/null | awk '/^srcversion:/ {print $2}')"
        printf 'nvidia_version=%s\n'    "$(modinfo nvidia 2>/dev/null | awk '/^version:/ {print $2}')"
    fi
    if [[ ${#CHANGED[@]} -gt 0 ]]; then
        printf '\n--- changes vs baseline ---\n'
        for c in "${CHANGED[@]}"; do printf '%s\n' "$c"; done
    fi
} > "$OUT/00-meta.txt"

# ---- 10 Pre-state capture ----
step "10 pre-state capture"
PRE_OUT_DIR=$("$STATE_CAPTURE" 2>&1 | awk '/Output directory:/ {print $NF}')
[[ -d "$PRE_OUT_DIR" ]] && ln -sfn "$PRE_OUT_DIR" "$OUT/10-pre-state"

# ---- 31 Background sysfs sampler ----
SAMPLER_LOG="$OUT/31-sysfs-sampler.csv"
echo "epoch_utc,qwd_cycles,qwd_detections,lever_m_fires,rmInit_OK,rmInit_FAIL,GSP_LOCKDOWN,AER_cor" > "$SAMPLER_LOG"
NV_BDF=$(for d in /sys/bus/pci/devices/*; do
    [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x10de" ]] && basename "$d" && break
done)
SAMPLER_PID=""
if [[ -n "$NV_BDF" ]]; then
    (
        SYSFS="/sys/bus/pci/devices/$NV_BDF"
        while true; do
            e=$(date +%s)
            c=$(cat "$SYSFS/aorus_qwatchdog_cycles" 2>/dev/null || echo "?")
            d=$(cat "$SYSFS/aorus_qwatchdog_detections" 2>/dev/null || echo "?")
            f=$(cat "$SYSFS/aorus_lever_m_fires" 2>/dev/null || echo "?")
            ok=$(journalctl -k -b 0 2>/dev/null | grep -c "site=post-rmInit-OK")
            ff=$(journalctl -k -b 0 2>/dev/null | grep -c "site=post-rmInit-FAIL")
            gl=$(journalctl -k -b 0 2>/dev/null | grep -c GSP_LOCKDOWN_NOTICE)
            ae=$(journalctl -k -b 0 2>/dev/null | grep -c "pcieport.*AER:.*Corrected")
            echo "$e,$c,$d,$f,$ok,$ff,$gl,$ae" >> "$SAMPLER_LOG"
            sleep "$SAMPLES_INTERVAL"
        done
    ) &
    SAMPLER_PID=$!
    step "31 sysfs sampler started (PID $SAMPLER_PID, every ${SAMPLES_INTERVAL}s)"
fi

# ---- 20 Run iterations ----
METRICS_CSV="$OUT/30-metrics.csv"
echo "iteration,epoch_utc,metric_name,value,unit" > "$METRICS_CSV"

START=$(date +%s)
END=$((START + DURATION))
ITER=0
WORKLOAD_EXIT=0

step "20 starting workload loop ($WORKLOAD)"
while [[ $(date +%s) -lt $END ]]; do
    ITER=$((ITER + 1))
    ITER_FILE=$(printf "%s/20-iterations/iter-%03d.txt" "$OUT" "$ITER")
    NOW=$(date +%s)

    {
        printf '## iteration %d  start_epoch_utc=%s\n' "$ITER" "$NOW"
        printf '## cmd: %s\n\n' "$WORKLOAD_CMD"
        timeout "$WORKLOAD_ITERATION_TIMEOUT" bash -c "$WORKLOAD_CMD" 2>&1
        rc=$?
        printf '\n## exit_rc=%d end_epoch_utc=%s\n' "$rc" "$(date +%s)"
        if [[ $rc -ne 0 ]]; then WORKLOAD_EXIT=$rc; fi
    } > "$ITER_FILE"

    # Extract metrics from this iteration
    if [[ -n "$METRICS_REGEX" ]]; then
        grep -E "$METRICS_REGEX" "$ITER_FILE" 2>/dev/null | while read -r line; do
            mname=$(echo "$line" | sed -E "s/.*${METRICS_REGEX}.*/\\1/" | head -1 || true)
            mval=$(echo  "$line" | sed -E "s/.*${METRICS_REGEX}.*/\\2/" | head -1 || true)
            [[ -n "$mname" && -n "$mval" ]] && \
                printf '%d,%s,%s,%s,%s\n' "$ITER" "$NOW" "$mname" "$mval" "$METRICS_UNIT" >> "$METRICS_CSV"
        done
    fi

    # Time check
    [[ $(date +%s) -ge $END ]] && break

    # Inter-iteration cooling delay (lets CPU cool between bursts)
    if [[ "$WORKLOAD_INTER_ITERATION_DELAY" -gt 0 ]]; then
        # Don't sleep past the deadline
        REMAINING=$((END - $(date +%s)))
        SLEEP_FOR=$WORKLOAD_INTER_ITERATION_DELAY
        [[ $SLEEP_FOR -gt $REMAINING ]] && SLEEP_FOR=$REMAINING
        [[ $SLEEP_FOR -gt 0 ]] && sleep "$SLEEP_FOR"
    fi
done

ELAPSED=$(($(date +%s) - START))
step "20 completed $ITER iterations in ${ELAPSED}s"

# ---- Stop sampler ----
if [[ -n "$SAMPLER_PID" ]]; then
    kill "$SAMPLER_PID" 2>/dev/null
    wait "$SAMPLER_PID" 2>/dev/null
    step "31 sampler stopped, $(wc -l < "$SAMPLER_LOG") sample rows"
fi

# ---- 11 Post-state capture ----
step "11 post-state capture"
POST_OUT_DIR=$("$STATE_CAPTURE" 2>&1 | awk '/Output directory:/ {print $NF}')
[[ -d "$POST_OUT_DIR" ]] && ln -sfn "$POST_OUT_DIR" "$OUT/11-post-state"

# ---- 12 Event capture spanning the test window ----
step "12 event capture (since test start)"
EVENT_EXP="${EXPERIMENT}-events"
EC_ARGS=(--experiment "$EVENT_EXP")
EC_ARGS+=(--changed "perf-capture-parent=${EXPERIMENT}-${TIMESTAMP}")
EC_ARGS+=(--changed "workload=$WORKLOAD")
for c in "${CHANGED[@]}"; do EC_ARGS+=(--changed "$c"); done
EVT_OUT_DIR=$("$EVENT_CAPTURE" "${EC_ARGS[@]}" 2>&1 | awk '/Full capture at:/ {print $NF}')
[[ -d "$EVT_OUT_DIR" ]] && ln -sfn "$EVT_OUT_DIR" "$OUT/12-event-capture"

# ---- 40 Verdict ----
PRE_DETECTIONS=$(head -2 "$SAMPLER_LOG" | tail -1 | cut -d, -f3)
POST_DETECTIONS=$(tail -1 "$SAMPLER_LOG" | cut -d, -f3)
PRE_LEVERM=$(head -2 "$SAMPLER_LOG" | tail -1 | cut -d, -f4)
POST_LEVERM=$(tail -1 "$SAMPLER_LOG" | cut -d, -f4)
PRE_GSP=$(head -2 "$SAMPLER_LOG" | tail -1 | cut -d, -f7)
POST_GSP=$(tail -1 "$SAMPLER_LOG" | cut -d, -f7)
PRE_FAIL=$(head -2 "$SAMPLER_LOG" | tail -1 | cut -d, -f6)
POST_FAIL=$(tail -1 "$SAMPLER_LOG" | cut -d, -f6)

VERDICT="PASS"
NOTES=()
if [[ "${POST_DETECTIONS:-0}" -gt "${PRE_DETECTIONS:-0}" ]]; then
    VERDICT="MODE-B-CAUGHT"
    NOTES+=("qwd_detections incremented: $PRE_DETECTIONS -> $POST_DETECTIONS")
fi
if [[ "${POST_LEVERM:-0}" -gt "${PRE_LEVERM:-0}" ]]; then
    VERDICT="MODE-B-CAUGHT"
    NOTES+=("lever_m_fires incremented: $PRE_LEVERM -> $POST_LEVERM")
fi
if [[ "${POST_GSP:-0}" -gt "${PRE_GSP:-0}" ]]; then
    VERDICT="FAIL-GSP-LOCKDOWN"
    NOTES+=("GSP_LOCKDOWN fired during test: +$((POST_GSP - PRE_GSP))")
fi
if [[ "${POST_FAIL:-0}" -gt "${PRE_FAIL:-0}" ]]; then
    VERDICT="FAIL-RMINIT"
    NOTES+=("rmInit_FAIL fired during test: +$((POST_FAIL - PRE_FAIL))")
fi
if [[ $WORKLOAD_EXIT -ne 0 ]]; then
    [[ "$VERDICT" == "PASS" ]] && VERDICT="WARN-NONZERO-EXIT"
    NOTES+=("workload non-zero exit at some iteration: rc=$WORKLOAD_EXIT")
fi

{
    printf 'verdict=%s\n' "$VERDICT"
    printf 'iterations_completed=%s\n' "$ITER"
    printf 'elapsed_seconds=%s\n' "$ELAPSED"
    printf 'qwd_detections_delta=%s\n' "$((POST_DETECTIONS - PRE_DETECTIONS))"
    printf 'lever_m_fires_delta=%s\n' "$((POST_LEVERM - PRE_LEVERM))"
    printf 'gsp_lockdown_delta=%s\n' "$((POST_GSP - PRE_GSP))"
    printf 'rminit_fail_delta=%s\n' "$((POST_FAIL - PRE_FAIL))"
    if [[ ${#NOTES[@]} -gt 0 ]]; then
        printf '\nnotes:\n'
        for n in "${NOTES[@]}"; do printf '  - %s\n' "$n"; done
    fi
} > "$OUT/40-verdict.txt"

# ---- 99 Summary (human-readable) ----
{
    printf '=== perf-capture summary ===\n'
    printf 'experiment:          %s\n' "$EXPERIMENT"
    printf 'workload:            %s — %s\n' "$WORKLOAD" "$WORKLOAD_DESC"
    printf 'duration:            %ss (cap %ss)\n' "$ELAPSED" "$DURATION"
    printf 'iterations completed: %s\n' "$ITER"
    printf '\n=== verdict: %s ===\n' "$VERDICT"
    cat "$OUT/40-verdict.txt"
    printf '\n=== metrics summary ===\n'
    if [[ -s "$METRICS_CSV" ]] && [[ $(wc -l < "$METRICS_CSV") -gt 1 ]]; then
        # Per-metric: count, mean, min, max
        awk -F, 'NR>1 {n[$3]++; sum[$3]+=$4; if(min[$3]==""||$4<min[$3]) min[$3]=$4; if($4>max[$3]) max[$3]=$4}
                 END {for (m in n) printf "  %-40s n=%d mean=%.3f min=%.3f max=%.3f\n", m, n[m], sum[m]/n[m], min[m], max[m]}' \
            "$METRICS_CSV"
    else
        printf '  (no metrics extracted — workload metric regex may not match output)\n'
    fi
    printf '\n=== artifacts ===\n'
    printf '  pre-state:    %s\n' "$OUT/10-pre-state"
    printf '  post-state:   %s\n' "$OUT/11-post-state"
    printf '  event:        %s\n' "$OUT/12-event-capture"
    printf '  iterations:   %s/20-iterations/\n' "$OUT"
    printf '  metrics:      %s\n' "$METRICS_CSV"
    printf '  sysfs sampler: %s\n' "$SAMPLER_LOG"
    printf '  reproduction: %s/reproduction.sh\n' "$OUT"
} > "$OUT/99-summary.txt"

# ---- reproduction.sh ----
{
    printf '#!/usr/bin/env bash\n'
    printf '# Reproduce perf-capture experiment %s captured %s.\n' "$EXPERIMENT" "$TIMESTAMP"
    printf '# Captured on host=%s kernel=%s\n' "$HOSTNAME" "$(uname -r)"
    printf '# nvidia srcversion at capture: %s\n\n' "$(modinfo nvidia 2>/dev/null | awk '/^srcversion:/ {print $2}')"
    printf 'set -e\n'
    printf 'sudo %s \\\n' "$SCRIPT_DIR/perf-capture.sh"
    printf '    --experiment "%s-repro" \\\n' "$EXPERIMENT"
    printf '    --workload %s \\\n' "$WORKLOAD"
    printf '    --duration %s \\\n' "$DURATION"
    printf '    --samples-interval %s' "$SAMPLES_INTERVAL"
    for c in "${CHANGED[@]}"; do printf ' \\\n    --changed %q' "$c"; done
    printf '\n'
} > "$OUT/reproduction.sh"
chmod +x "$OUT/reproduction.sh"

step "DONE — verdict: $VERDICT"
cat "$OUT/99-summary.txt"
printf '\nFull dossier: %s\n' "$OUT"

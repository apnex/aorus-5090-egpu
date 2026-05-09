#!/usr/bin/env bash
# event-capture.sh — capture kernel/userspace events + analyze against
# named hypotheses. Companion to tools/state-capture/state-capture.sh:
#
#   forensics    = STATE snapshot (sysfs/PCI/debugfs at one moment)
#   event-capture = EVENTS over time (kernel log streams + per-hypothesis verdicts)
#
# Designed for: any Linux investigation where you want to ask
#   "did hypothesis X fire during this boot/window?"
# Generic across subsystems (thunderbolt, nvidia, pcie, boltd, ...) and
# hypotheses (extensible — drop a new file in hypotheses/).
#
# Read-only (only reads journals, writes captures to repo archive/).
#
# Usage:
#   sudo /root/aorus-5090-egpu/tools/event-capture/event-capture.sh \
#       --experiment <name> \
#       [--hypothesis h1,h2,...]   (default: all)
#       [--subsystem s1,s2,...]    (default: all)
#       [--since boot|<journalctl-time-spec>]   (default: boot)
#       [--changed "key=value"]    (one --changed per change vs baseline)
#
# Examples:
#   # Default: all hypotheses, all subsystems, current boot
#   sudo .../event-capture.sh --experiment B1-baseline-portB
#
#   # Specific hypotheses + record what changed vs baseline
#   sudo .../event-capture.sh --experiment B1-dyndbg-portA \
#       --hypothesis h19,h20,h21 \
#       --changed 'cmdline=thunderbolt.dyndbg=+pflm' \
#       --changed 'port=A'

set -u
shopt -s nullglob

if [[ "$EUID" -ne 0 ]]; then
    echo "must run as root (needs to read full kernel log)" >&2
    exit 1
fi

# ---- Defaults + arg parsing ----
REPO_ROOT="${REPO_ROOT:-/root/aorus-5090-egpu}"
TOOL_DIR="$REPO_ROOT/tools/event-capture"
EXP_NAME=""
HYPOTHESES=""
SUBSYSTEMS=""
SINCE="boot"
CHANGED=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --experiment) EXP_NAME="$2"; shift 2 ;;
        --hypothesis) HYPOTHESES="$2"; shift 2 ;;
        --subsystem)  SUBSYSTEMS="$2"; shift 2 ;;
        --since)      SINCE="$2"; shift 2 ;;
        --changed)    CHANGED+=("$2"); shift 2 ;;
        -h|--help)
            sed -n '2,28p' "$0"; exit 0 ;;
        *)
            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$EXP_NAME" ]]; then
    echo "--experiment <name> required" >&2
    exit 2
fi

# Validate experiment name (used in path; restrict to safe chars)
if ! [[ "$EXP_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "experiment name must match [A-Za-z0-9._-]+ (got: $EXP_NAME)" >&2
    exit 2
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
HOSTNAME=$(hostname)
OUT="$REPO_ROOT/archive/event-captures/${EXP_NAME}-${TIMESTAMP}"
mkdir -p "$OUT"/{10-raw,20-filtered,30-hypotheses}

# ---- Discover available hypotheses + subsystems ----
all_hypotheses() {
    for f in "$TOOL_DIR/hypotheses"/*.sh; do
        bn=$(basename "$f" .sh)
        echo "$bn"
    done
}

all_subsystems() {
    for f in "$TOOL_DIR/subsystems"/*.sh; do
        bn=$(basename "$f" .sh)
        echo "$bn"
    done
}

# Resolve "all" or default to all
if [[ -z "$HYPOTHESES" ]]; then
    HYPOTHESES=$(all_hypotheses | paste -sd,)
fi
if [[ -z "$SUBSYSTEMS" ]]; then
    SUBSYSTEMS=$(all_subsystems | paste -sd,)
fi

step() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$1" >&2; }

step "Output directory: $OUT"
step "Hypotheses: $HYPOTHESES"
step "Subsystems: $SUBSYSTEMS"

# ---- 00 META ----
step "00 meta — capturing context"
{
    printf 'experiment_name=%s\n' "$EXP_NAME"
    printf 'timestamp_utc=%s\n' "$TIMESTAMP"
    printf 'hostname=%s\n' "$HOSTNAME"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'os_release=%s\n' "$(grep -oE 'PRETTY_NAME="[^"]+"' /etc/os-release | head -1)"
    printf 'since=%s\n' "$SINCE"
    printf 'hypotheses_to_test=%s\n' "$HYPOTHESES"
    printf 'subsystems_filtered=%s\n' "$SUBSYSTEMS"
    # Detect active TB domains (helpful context)
    active=""
    for d in /sys/bus/thunderbolt/devices/domain*; do
        [[ -d "$d" ]] || continue
        dn=$(basename "$d" | sed 's/domain//')
        for dev in /sys/bus/thunderbolt/devices/${dn}-[0-9]*; do
            [[ -d "$dev" ]] || continue
            bn=$(basename "$dev")
            [[ "$bn" =~ ^[0-9]+-0$ ]] && continue
            [[ "$(cat "$dev/authorized" 2>/dev/null)" == "1" ]] && active+="${dn},"
        done
    done
    printf 'active_tb_domains=%s\n' "${active%,}"

    if [[ ${#CHANGED[@]} -gt 0 ]]; then
        printf '\n--- changes vs baseline ---\n'
        for c in "${CHANGED[@]}"; do
            printf '%s\n' "$c"
        done
    fi

    printf '\n--- /proc/cmdline ---\n%s\n' "$(cat /proc/cmdline)"
} > "$OUT/00-meta.txt"

# ---- 10 RAW ----
step "10 raw — capturing full logs"
JCT_ARGS=()
case "$SINCE" in
    boot) JCT_ARGS=(-b 0) ;;
    boot:*) JCT_ARGS=(-b "${SINCE#boot:}") ;;
    *)    JCT_ARGS=(--since "$SINCE") ;;
esac

# Use --output=short-monotonic for kernel log so timestamps survive any
# clock adjustments during boot (timesync, RTC correction). Each entry
# starts with [SECONDS.MICROSECONDS] since boot — stable + diff-friendly.
# full-journal.log keeps default format for human reading.
journalctl -k "${JCT_ARGS[@]}" --no-pager --output=short-monotonic > "$OUT/10-raw/full-kernel.log" 2>/dev/null
journalctl    "${JCT_ARGS[@]}" --no-pager > "$OUT/10-raw/full-journal.log" 2>/dev/null
cp /proc/cmdline "$OUT/10-raw/current-cmdline.txt" 2>/dev/null
echo "captured $(wc -l < "$OUT/10-raw/full-kernel.log") kernel log lines, $(wc -l < "$OUT/10-raw/full-journal.log") full journal lines" >&2

# ---- 20 FILTERED (per subsystem) ----
step "20 filtered — applying subsystem filters"
IFS=',' read -ra SUBSYS_ARR <<< "$SUBSYSTEMS"
for s in "${SUBSYS_ARR[@]}"; do
    sf="$TOOL_DIR/subsystems/${s}.sh"
    if [[ ! -f "$sf" ]]; then
        echo "  WARN: subsystem '$s' has no filter file at $sf — skipping" >&2
        continue
    fi
    # shellcheck disable=SC1090
    source "$sf"
    if [[ ${#FILTER_PATTERNS[@]} -eq 0 ]]; then
        echo "  WARN: subsystem '$s' defines no FILTER_PATTERNS — skipping" >&2
        continue
    fi
    # Combine patterns into one egrep
    pat=$(printf '%s|' "${FILTER_PATTERNS[@]}"); pat="${pat%|}"
    grep -E "$pat" "$OUT/10-raw/full-kernel.log" > "$OUT/20-filtered/${s}.log" 2>/dev/null
    # Also include service journal entries if pattern matches
    grep -E "$pat" "$OUT/10-raw/full-journal.log" >> "$OUT/20-filtered/${s}.log" 2>/dev/null
    # Deduplicate while preserving order
    awk '!seen[$0]++' "$OUT/20-filtered/${s}.log" > "$OUT/20-filtered/${s}.log.tmp" \
        && mv "$OUT/20-filtered/${s}.log.tmp" "$OUT/20-filtered/${s}.log"
    echo "  $s: $(wc -l < "$OUT/20-filtered/${s}.log") lines" >&2
    unset FILTER_PATTERNS SUBSYSTEM_NAME SUBSYSTEM_DESC
done

# ---- 30 HYPOTHESES (per-hypothesis verdict) ----
step "30 hypotheses — running per-hypothesis analysis"
IFS=',' read -ra HYP_ARR <<< "$HYPOTHESES"
declare -A VERDICT_BY_ID
declare -A HITS_BY_ID
declare -A DESC_BY_ID
for h in "${HYP_ARR[@]}"; do
    hf="$TOOL_DIR/hypotheses/${h}.sh"
    if [[ ! -f "$hf" ]]; then
        echo "  WARN: hypothesis '$h' has no file at $hf — skipping" >&2
        continue
    fi
    # shellcheck disable=SC1090
    source "$hf"

    : "${HYPOTHESIS_ID:?missing in $hf}"
    : "${HYPOTHESIS_DESC:?missing in $hf}"
    : "${HYPOTHESIS_SUBSYSTEM:?missing in $hf}"
    SIGNATURES_FIRED=("${SIGNATURES_FIRED[@]:-}")
    SIGNATURES_NEGATIVE=("${SIGNATURES_NEGATIVE[@]:-}")
    MIN_HITS_FIRED="${MIN_HITS_FIRED:-1}"

    sub_log="$OUT/20-filtered/${HYPOTHESIS_SUBSYSTEM}.log"
    if [[ ! -f "$sub_log" ]]; then
        # Fall back to full kernel log
        sub_log="$OUT/10-raw/full-kernel.log"
    fi

    fired_hits=0
    fired_evidence=""
    for sig in "${SIGNATURES_FIRED[@]}"; do
        [[ -z "$sig" ]] && continue
        matches=$(grep -E "$sig" "$sub_log" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            n=$(echo "$matches" | wc -l)
            fired_hits=$((fired_hits + n))
            fired_evidence+=$'\n'"--- signature: $sig ($n hits) ---"$'\n'"$matches"
        fi
    done

    neg_hits=0
    neg_evidence=""
    for sig in "${SIGNATURES_NEGATIVE[@]}"; do
        [[ -z "$sig" ]] && continue
        matches=$(grep -E "$sig" "$sub_log" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            n=$(echo "$matches" | wc -l)
            neg_hits=$((neg_hits + n))
            neg_evidence+=$'\n'"--- negative signature: $sig ($n hits) ---"$'\n'"$matches"
        fi
    done

    # Verdict logic
    if [[ $fired_hits -ge $MIN_HITS_FIRED ]]; then
        verdict="FIRED"
    elif [[ $neg_hits -gt 0 ]]; then
        verdict="NOT-FIRED"
    else
        verdict="INCONCLUSIVE"
    fi

    # Write verdict file
    {
        printf 'hypothesis_id=%s\n' "$HYPOTHESIS_ID"
        printf 'hypothesis_desc=%s\n' "$HYPOTHESIS_DESC"
        printf 'hypothesis_ref=%s\n' "${HYPOTHESIS_REF:-}"
        printf 'hypothesis_subsystem=%s\n' "$HYPOTHESIS_SUBSYSTEM"
        printf 'verdict=%s\n' "$verdict"
        printf 'fired_hits=%s\n' "$fired_hits"
        printf 'negative_hits=%s\n' "$neg_hits"
        printf 'min_hits_fired=%s\n' "$MIN_HITS_FIRED"
    } > "$OUT/30-hypotheses/${h}-verdict.txt"

    # Write evidence file (log lines that triggered fired/negative)
    {
        printf 'Evidence for %s (%s)\n' "$HYPOTHESIS_ID" "$HYPOTHESIS_DESC"
        printf '=== Verdict: %s (%d fired hits, %d negative hits) ===\n' \
            "$verdict" "$fired_hits" "$neg_hits"
        if [[ -n "$fired_evidence" ]]; then
            printf '\n=== FIRED-signature matches ===%s\n' "$fired_evidence"
        else
            printf '\n=== FIRED-signature matches: NONE ===\n'
        fi
        if [[ -n "$neg_evidence" ]]; then
            printf '\n=== NEGATIVE-signature matches ===%s\n' "$neg_evidence"
        fi
    } > "$OUT/30-hypotheses/${h}-evidence.txt"

    VERDICT_BY_ID[$HYPOTHESIS_ID]="$verdict"
    HITS_BY_ID[$HYPOTHESIS_ID]="$fired_hits"
    DESC_BY_ID[$HYPOTHESIS_ID]="$HYPOTHESIS_DESC"

    echo "  $HYPOTHESIS_ID: $verdict ($fired_hits fired hits)" >&2

    unset HYPOTHESIS_ID HYPOTHESIS_DESC HYPOTHESIS_REF HYPOTHESIS_SUBSYSTEM
    unset SIGNATURES_FIRED SIGNATURES_NEGATIVE MIN_HITS_FIRED
done

# ---- 99 SUMMARY ----
step "99 summary — generating roll-up"
{
    printf '=== Event Capture Summary ===\n'
    printf 'Experiment: %s\n' "$EXP_NAME"
    printf 'Captured:   %s\n' "$TIMESTAMP"
    printf 'Host:       %s / %s\n' "$HOSTNAME" "$(uname -r)"
    if [[ ${#CHANGED[@]} -gt 0 ]]; then
        printf 'Changes vs baseline:\n'
        for c in "${CHANGED[@]}"; do printf '  %s\n' "$c"; done
    fi
    printf '\n=== Hypothesis Verdicts ===\n'
    printf '%-6s  %-12s  %-7s  %s\n' "ID" "VERDICT" "HITS" "DESCRIPTION"
    printf '%-6s  %-12s  %-7s  %s\n' "------" "------------" "-------" "-----------"
    for id in "${!VERDICT_BY_ID[@]}"; do
        printf '%-6s  %-12s  %-7s  %s\n' \
            "$id" "${VERDICT_BY_ID[$id]}" "${HITS_BY_ID[$id]}" "${DESC_BY_ID[$id]}"
    done | sort
    printf '\n=== Notable counts (auto-detected) ===\n'
    grepcount() { grep -c "$1" "$OUT/10-raw/full-kernel.log" 2>/dev/null; }
    printf 'GSP_LOCKDOWN_NOTICE: %s\n' "$(grepcount GSP_LOCKDOWN_NOTICE)"
    printf 'rmInit FAIL count:   %s\n' "$(grepcount 'site=post-rmInit-FAIL')"
    printf 'rmInit OK count:     %s\n' "$(grepcount 'site=post-rmInit-OK')"
    printf 'AER cor events:      %s\n' "$(grepcount 'pcieport.*AER:.*Corrected\|aer.*Corrected error received')"
    printf 'TB tunnel events:    %s\n' "$(grepcount 'thunderbolt.*tunnel')"
    printf '\n=== Cross-references ===\n'
    printf 'Detail:    %s/30-hypotheses/<id>-evidence.txt\n' "$OUT"
    printf 'Raw logs:  %s/10-raw/\n' "$OUT"
    printf 'Filtered:  %s/20-filtered/\n' "$OUT"
} > "$OUT/99-summary.txt"

# Auto-generate the timeline if the helper is alongside this script.
TIMELINE_EXTRACT="$(dirname "$0")/timeline-extract.sh"
if [[ -x "$TIMELINE_EXTRACT" ]]; then
    "$TIMELINE_EXTRACT" "$OUT" >/dev/null 2>&1 && \
        step "timeline.txt generated"
fi

step "DONE"
cat "$OUT/99-summary.txt"
printf '\nFull capture at: %s\n' "$OUT"
[[ -f "$OUT/timeline.txt" ]] && printf 'Timeline:        %s/timeline.txt\n' "$OUT"

#!/usr/bin/env bash
# tools/observability-evidence.sh
#
# Per-boot evidence collector for the
# `aorus-egpu-observability-watchdog.service` retirement decision.
#
# The retirement question:
# does the in-driver Lever Q-watchdog cover every Mode B incident the userspace
# observability watchdog would catch?
# If yes, the userspace watchdog is redundant and can retire.
# Evidence comes from per-boot snapshots over n>=5 cold-cold-boots.
#
# Usage:
#   sudo ./tools/observability-evidence.sh             # capture this boot
#   sudo ./tools/observability-evidence.sh --summary   # tally all snapshots
#   sudo ./tools/observability-evidence.sh --rerun     # force re-capture
#
# Output: archive/observability-evidence/<boot-iso>.log per boot.
# Idempotent — won't overwrite an existing capture for the current boot
# unless --rerun is passed.
#
# Verdict categories
# (the bottom-line classification is the most important part of each snapshot):
#
#   CLEAN-BOOT
#     — no M-recover fires, no Q-watchdog detections, no observability-
#       watchdog wedge events, no Xid / fallen-off / uncorrectable AER.
#       Retirement-safe (positive evidence).
#
#   Q-WATCHDOG-CAUGHT-MODEB
#     — Lever Q-watchdog fired (in-driver) and the observability watchdog
#       also logged the same event;
#       in-driver mechanism caught it first;
#       userspace is redundant.
#       Retirement-safe.
#
#   OBSERVABILITY-CAUGHT-MISSED-MODEB
#     — observability watchdog fired but Q-watchdog DID NOT;
#       the userspace watchdog caught something the in-driver mechanism missed.
#       RETIREMENT-BLOCKING — investigate before retiring.
#
#   M-RECOVER-FIRED-OK
#     — Lever M-recover fired (post-rmInit-FAIL or AER) and recovery succeeded.
#       Orthogonal to observability retirement;
#       captured for completeness.
#
#   M-RECOVER-FIRED-AND-SURRENDERED
#     — recovery hit MaxAttempts gate;
#       inspect manually.
#
# Retirement gate: n>=5 consecutive cold-cold-boots with verdict in
# { CLEAN-BOOT, Q-WATCHDOG-CAUGHT-MODEB, M-RECOVER-FIRED-OK }
# and zero OBSERVABILITY-CAUGHT-MISSED-MODEB.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/archive/observability-evidence}"
GPU_BDF="${GPU_BDF:-0000:04:00.0}"

MODE="capture"
FORCE_RERUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) MODE="summary" ;;
        --rerun)   FORCE_RERUN=1 ;;
        -h|--help) sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

# ANSI colour for terminal
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_OK=''; C_WARN=''; C_FAIL=''; C_RESET=''
fi

read_or_dash() {
    local f="$1"
    [[ -r "$f" ]] && cat "$f" || echo "-"
}

# Boot-tag from kernel btime (constant across boot lifetime; idempotent
# when re-run within the same boot).
btime_to_iso() {
    local btime
    btime=$(awk '/^btime / {print $2}' /proc/stat)
    date -Iseconds -d "@$btime"
}

mode_summary() {
    if [[ ! -d "$EVIDENCE_DIR" ]]; then
        echo "No evidence directory at $EVIDENCE_DIR yet."
        echo "Run without --summary on a few cold-cold-boots first."
        exit 0
    fi
    echo "Observability-watchdog retirement evidence summary"
    printf 'Source: %s\n\n' "$EVIDENCE_DIR"
    local n=0 retire_safe=0 blocking=0 unknown=0
    for f in "$EVIDENCE_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        local verdict
        verdict=$(grep -oE '^Verdict: [A-Z-]+' "$f" 2>/dev/null | head -1 | awk '{print $2}')
        verdict="${verdict:-UNKNOWN}"
        printf '  %s  %s\n' "$(basename "$f" .log)" "$verdict"
        case "$verdict" in
            CLEAN-BOOT|Q-WATCHDOG-CAUGHT-MODEB|M-RECOVER-FIRED-OK)
                retire_safe=$((retire_safe + 1)) ;;
            OBSERVABILITY-CAUGHT-MISSED-MODEB)
                blocking=$((blocking + 1)) ;;
            *)
                unknown=$((unknown + 1)) ;;
        esac
    done
    echo
    printf 'Total snapshots:           %d\n' "$n"
    printf '%sRetire-safe%s:                %d\n' "$C_OK"  "$C_RESET" "$retire_safe"
    printf '%sRetirement-BLOCKING%s:        %d  (any > 0 means cannot retire yet)\n' "$C_FAIL" "$C_RESET" "$blocking"
    printf 'Unknown / needs review:    %d\n' "$unknown"
    echo
    if [[ $blocking -eq 0 && $retire_safe -ge 5 ]]; then
        printf '%s✓ Retirement gate met (n>=5 retire-safe, 0 blocking)%s\n' "$C_OK" "$C_RESET"
        echo '  → safe to retire aorus-egpu-observability-watchdog.service'
    elif [[ $blocking -gt 0 ]]; then
        printf '%s✗ Retirement BLOCKED — observability caught Mode B that Q-watchdog missed%s\n' "$C_FAIL" "$C_RESET"
        echo '  → review the OBSERVABILITY-CAUGHT-MISSED-MODEB snapshot(s) above'
    else
        printf '%s⚠ Pending — %d/5 retire-safe boots collected so far%s\n' "$C_WARN" "$retire_safe" "$C_RESET"
    fi
}

mode_capture() {
    local boot_iso
    boot_iso=$(btime_to_iso)
    local boot_tag
    boot_tag=${boot_iso//:/}      # filename-friendly
    boot_tag=${boot_tag//+/}
    local out="$EVIDENCE_DIR/${boot_tag}.log"

    if [[ -f "$out" && $FORCE_RERUN -ne 1 ]]; then
        echo "snapshot already exists: $out"
        echo "(use --rerun to overwrite)"
        exit 0
    fi

    mkdir -p "$EVIDENCE_DIR"

    {
        echo "# Observability-watchdog retirement-evidence snapshot"
        echo "snapshot_time: $(date -Iseconds)"
        echo "boot_time:     $boot_iso (btime=$(awk '/^btime / {print $2}' /proc/stat))"
        printf 'uptime_s:      %d\n' "$(awk '{print int($1)}' /proc/uptime)"
        echo "kernel:        $(uname -r)"
        echo

        echo "## Module identity"
        modinfo nvidia 2>/dev/null | grep -E '^(filename|version|srcversion):' | sed 's/^/  /'
        echo

        echo "## Lever M-recover counters (in-driver)"
        echo "  fires:        $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_lever_m_fires)"
        echo "  successes:    $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_lever_m_successes)"
        echo "  surrenders:   $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_lever_m_surrenders)"
        echo "  last_fire_jf: $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_lever_m_last_fire_jiffies)"
        echo

        echo "## Lever Q-watchdog counters (in-driver Mode B detection)"
        echo "  cycles:        $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_qwatchdog_cycles)"
        echo "  detections:    $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_qwatchdog_detections)"
        echo "  last_detection_jf: $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_qwatchdog_last_detection_jiffies)"
        echo "  last_pmc_boot_0: $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_qwatchdog_last_pmc_boot_0)"
        echo "  last_aer_summary: $(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_qwatchdog_last_aer_summary)"
        echo

        echo "## Observability-watchdog journal (this boot)"
        if systemctl list-unit-files aorus-egpu-observability-watchdog.service >/dev/null 2>&1; then
            local owd_status
            owd_status=$(systemctl is-active aorus-egpu-observability-watchdog.service 2>&1)
            echo "  service state: $owd_status"
            # Filter to lines emitted by the binary itself (drop systemd[1]
            # lifecycle messages whose unit-description text mentions
            # "Mode B silent freeze SysRq capture").
            # Match on identifier prefix `aorus-egpu-observability-watchdog[<pid>]:`.
            local owd_lines
            owd_lines=$(journalctl -u aorus-egpu-observability-watchdog.service -b --no-pager \
                    --output=cat --identifier=aorus-egpu-observability-watchdog 2>/dev/null \
                | grep -ciE 'wedge|mode.b|fallen-off|FIRED|sysrq' || true)
            echo "  wedge-pattern lines this boot (binary-only): $owd_lines"
            if [[ $owd_lines -gt 0 ]]; then
                echo "  (sample wedge-pattern lines:)"
                journalctl -u aorus-egpu-observability-watchdog.service -b --no-pager \
                    --output=cat --identifier=aorus-egpu-observability-watchdog 2>/dev/null \
                    | grep -iE 'wedge|mode.b|fallen-off|FIRED|sysrq' | head -3 | sed 's/^/    /'
            fi
        else
            echo "  service not installed (already retired? early-stage repo?)"
        fi
        echo

        echo "## Kernel signals (this boot)"
        local xid_count fallen_count nvrm_fail aer_unc
        xid_count=$(dmesg 2>/dev/null | grep -ciE '^\s*\[.*NVRM:.*Xid' || true)
        fallen_count=$(dmesg 2>/dev/null | grep -ciE 'fallen[- ]off|gpu.*lost|disconnected' || true)
        nvrm_fail=$(dmesg 2>/dev/null | grep -ciE 'NVRM.*Failed|RmInitAdapter failed' || true)
        aer_unc=$(dmesg 2>/dev/null | grep -ciE 'aer.*Uncorrectable|Severity.*Fatal' || true)
        echo "  Xid events:                    $xid_count"
        echo "  fallen-off / gpu-lost lines:   $fallen_count"
        echo "  NVRM-Failed / RmInit-fail:     $nvrm_fail"
        echo "  AER uncorrectable / fatal:     $aer_unc"
        echo

        echo "## M-recover dmesg events (this boot)"
        local mr_events
        mr_events=$(dmesg 2>/dev/null | grep -E 'AORUS Lever M-recover.*(scheduling|RECOVERED|READY|PERMANENT|surrender|rate-limited|kill-switch)' || true)
        if [[ -z "$mr_events" ]]; then
            echo "  (none — M-recover did not fire)"
        else
            echo "$mr_events" | head -10 | sed 's/^/  /'
        fi
        echo

        echo "## Q-watchdog dmesg events (this boot)"
        local qw_events
        qw_events=$(dmesg 2>/dev/null | grep -E 'Q-watchdog.*(detected|MMIO probe|conv)' || true)
        if [[ -z "$qw_events" ]]; then
            echo "  (none — Q-watchdog did not fire detection)"
        else
            echo "$qw_events" | head -10 | sed 's/^/  /'
        fi
        echo

        echo "## GPU functional check"
        local smi_out
        smi_out=$(timeout 5 nvidia-smi -L 2>&1 | head -1)
        echo "  nvidia-smi: $smi_out"
        echo

        # ---- Verdict computation ----
        local mr_fires_n=0 qw_dets_n=0 owd_lines_n=0
        mr_fires_n=$(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_lever_m_fires)
        [[ "$mr_fires_n" == "-" ]] && mr_fires_n=0
        qw_dets_n=$(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_qwatchdog_detections)
        [[ "$qw_dets_n" == "-" ]] && qw_dets_n=0
        owd_lines_n=$(journalctl -u aorus-egpu-observability-watchdog.service -b --no-pager \
                --output=cat --identifier=aorus-egpu-observability-watchdog 2>/dev/null \
            | grep -ciE 'wedge|mode.b|fallen-off|FIRED|sysrq' || true)
        owd_lines_n="${owd_lines_n:-0}"

        local mr_surrenders_n=0
        mr_surrenders_n=$(read_or_dash /sys/bus/pci/devices/$GPU_BDF/tb_egpu_lever_m_surrenders)
        [[ "$mr_surrenders_n" == "-" ]] && mr_surrenders_n=0

        echo "## Verdict"
        local verdict
        if (( mr_surrenders_n > 0 )); then
            verdict="M-RECOVER-FIRED-AND-SURRENDERED"
        elif (( owd_lines_n > 0 && qw_dets_n == 0 )); then
            verdict="OBSERVABILITY-CAUGHT-MISSED-MODEB"
        elif (( qw_dets_n > 0 )); then
            verdict="Q-WATCHDOG-CAUGHT-MODEB"
        elif (( mr_fires_n > 0 )); then
            verdict="M-RECOVER-FIRED-OK"
        elif (( xid_count + fallen_count + nvrm_fail + aer_unc + owd_lines_n == 0 )); then
            verdict="CLEAN-BOOT"
        else
            verdict="NEEDS-REVIEW"
        fi
        echo "Verdict: $verdict"

        case "$verdict" in
            CLEAN-BOOT)                          echo "  → retire-safe (positive evidence)" ;;
            Q-WATCHDOG-CAUGHT-MODEB)             echo "  → retire-safe (in-driver Q-watchdog covered it; userspace redundant)" ;;
            M-RECOVER-FIRED-OK)                  echo "  → orthogonal (recovery happened; not directly relevant to observability question)" ;;
            OBSERVABILITY-CAUGHT-MISSED-MODEB)   echo "  → RETIREMENT-BLOCKING (investigate this boot before retiring observability-watchdog)" ;;
            M-RECOVER-FIRED-AND-SURRENDERED)     echo "  → INSPECT MANUALLY" ;;
            *)                                   echo "  → manual review needed" ;;
        esac
    } > "$out"

    echo "wrote $out"
    echo
    grep -E "^Verdict:" "$out"
    grep -E "^  →" "$out"
}

case "$MODE" in
    capture) mode_capture ;;
    summary) mode_summary ;;
esac

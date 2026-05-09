#!/usr/bin/env bash
# timeline-extract.sh — derive a timing timeline from an event-capture dossier.
#
# For deep A-vs-B comparison: parse the raw kernel log, pick out named
# landmark events (TB authorize → tunnel up → bridge probe → GPU probe →
# nvidia bind → rmInit → first GSP_LOCKDOWN → link demote), and emit
# monotonic seconds + delta-from-prev for each.
#
# Output: <DOSSIER>/timeline.txt
#
# Supports both timestamp formats:
#   monotonic  "[12345.678901] kernel: ..."  (preferred, since 2026-05-08)
#   wall-clock "May 08 09:37:30 host kernel: ..."  (legacy dossiers)
#
# Usage:
#   ./timeline-extract.sh <event-capture-dossier-dir>

set -u
shopt -s nullglob

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <event-capture-dossier>" >&2
    exit 1
fi

DOSSIER="$1"
LOG="$DOSSIER/10-raw/full-kernel.log"
OUT="$DOSSIER/timeline.txt"

if [[ ! -f "$LOG" ]]; then
    echo "Not an event-capture dossier (missing 10-raw/full-kernel.log): $DOSSIER" >&2
    exit 2
fi

# Detect timestamp format by sniffing the first non-blank line.
# Monotonic format: "[    1.234567] ..."  — note kernel pads with spaces inside [].
# Wall-clock format: "May 08 09:37:30 host kernel: ..."
FIRST_LINE=$(head -5 "$LOG" | grep -m1 -E '^\[[ 0-9]+\.[0-9]+\]|^[A-Z][a-z][a-z] +[0-9]+ +[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
if [[ "$FIRST_LINE" =~ ^\[ ]]; then
    TS_FORMAT=monotonic
elif [[ -n "$FIRST_LINE" ]]; then
    TS_FORMAT=wallclock
else
    TS_FORMAT=unknown
fi

# Each landmark = label|regex (first match in log wins).
declare -a LANDMARKS=(
    "kernel_boot_start|Linux version "
    "tb_acpi_register|ACPI: bus type thunderbolt registered"
    "tb_nhi0_probe|thunderbolt 0000:00:0d\.2: total paths"
    "tb_nhi1_probe|thunderbolt 0000:00:0d\.3: total paths"
    "tb_acpi_link_created|tb_acpi_add_link.*created link"
    "tb_domain_added|thunderbolt 0000:00:0d\.[23]: NHI initialized"
    "tb_security_set|thunderbolt 0000:00:0d\.[23]: security level set"
    "tb_first_device_found|thunderbolt [01]-1: new device found"
    "tb_aorus_named|GIGABYTE AORUS RTX5090 AI BOX"
    "tb_retimer_found|new retimer found"
    "tb_wait_for_port_first|tb_wait_for_port:.*is connected, link is up"
    "tb_unplugged_first|tb_wait_for_port:.*is unplugged"
    "tb_switch_reset|tb_switch_reset:"
    "pcieport_aer_enabled|pcieport 0000:00:07\.0: AER: enabled"
    "pci_bridge_03_probe|pci 0000:03:00\.0:.*type 01"
    "pci_gpu_enumerated|pci 0000:0[0-9a-f]:00\.0:.*\[10de:"
    "nvidia_module_load|nvidia: module verification|NVIDIA: loading"
    "nvrm_first_diag|AORUS Lever M-recover \[DIAG\]: site=probe-end"
    "nvrm_startdev_first|AORUS Lever M-recover \[DIAG\]: site=startdev-entry"
    "nvrm_pre_rminit_first|AORUS Lever M-recover \[DIAG\]: site=pre-rmInit"
    "nvrm_post_rminit_first|AORUS Lever M-recover \[DIAG\]: site=post-rmInit"
    "gsp_first_lockdown|GSP_LOCKDOWN_NOTICE"
    "gsp_init_done|GSP_INIT_DONE"
    "rminit_failed_first|RmInitAdapter failed"
    "link_demote_to_gen1|Br_LnkSta=0x7041"
    "link_at_gen3|Br_LnkSta=0x7043"
    "wpr2_set|WPR2=0x07f4a000"
    "uvm_loaded|nvidia_uvm:.*loaded|UVM: loading"
)

declare -a COUNTERS=(
    "gsp_lockdown_count|GSP_LOCKDOWN_NOTICE"
    "rminit_fail_count|site=post-rmInit-FAIL"
    "rminit_ok_count|site=post-rmInit-OK"
    "tb_wait_for_port_calls|tb_wait_for_port:"
    "aer_corrected_count|pcieport.*AER:.*Corrected"
    "tb_unplugged_count|tb_wait_for_port:.*is unplugged"
    "rminit_failed_msg_count|RmInitAdapter failed"
)

# Extract timestamp as float seconds from a log line, regardless of format.
# Returns empty string if no match.
extract_first_secs() {
    local pattern="$1"
    local line
    line=$(grep -m1 -E "$pattern" "$LOG" 2>/dev/null) || return
    [[ -z "$line" ]] && return

    case "$TS_FORMAT" in
        monotonic)
            # "[    NNNNN.NNNNNN] ..." — extract bracketed float (leading spaces ok)
            echo "$line" | sed -nE 's/^\[[ ]*([0-9]+\.[0-9]+)\].*/\1/p'
            ;;
        wallclock)
            # "Mon DD HH:MM:SS ..." — convert HH:MM:SS to seconds, but warn:
            # may be unstable if clock jumped during boot.
            echo "$line" | awk '{
                for (i=1;i<=NF;i++)
                    if ($i ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
                        split($i, t, ":")
                        printf "%d.000000\n", t[1]*3600 + t[2]*60 + t[3]
                        exit
                    }
            }'
            ;;
    esac
}

count_pattern() {
    local pattern="$1"
    local n
    n=$(grep -cE "$pattern" "$LOG" 2>/dev/null) || n=0
    printf '%s\n' "${n:-0}"
}

# Format a delta in seconds as Δ_pretty.
format_delta() {
    local d="$1"
    awk -v d="$d" 'BEGIN { if (d == 0) printf "+0.000s"; else printf "+%.3fs", d }'
}

{
    printf '# Timeline — extracted from %s\n' "$LOG"
    printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Timestamp format: %s\n\n' "$TS_FORMAT"
    if [[ "$TS_FORMAT" == "wallclock" ]]; then
        printf '# WARNING: legacy dossier with wall-clock timestamps. Deltas may\n'
        printf '#   show artifacts if the system clock jumped during boot (e.g.,\n'
        printf '#   NTP sync, RTC correction). Re-capture with newer event-capture.sh\n'
        printf '#   for monotonic timestamps if comparing closely.\n\n'
    fi

    printf '== Landmarks (first occurrence) ==\n'
    printf '%-30s  %-14s  %-12s\n' "EVENT" "TIME" "Δ-prev"
    printf -- '-%.0s' {1..70}; printf '\n'

    prev_secs=""
    for lm in "${LANDMARKS[@]}"; do
        label="${lm%%|*}"
        rgx="${lm#*|}"
        secs=$(extract_first_secs "$rgx")
        if [[ -z "$secs" ]]; then
            printf '%-30s  %-14s  %-12s\n' "$label" "—" "—"
            continue
        fi
        if [[ -n "$prev_secs" ]]; then
            delta=$(awk -v a="$secs" -v b="$prev_secs" 'BEGIN { printf "%.6f", a - b }')
            delta_str=$(format_delta "$delta")
        else
            delta_str="(start)"
        fi
        printf '%-30s  %-14s  %-12s\n' "$label" "$secs" "$delta_str"
        prev_secs="$secs"
    done

    printf '\n== Counters ==\n'
    printf '%-30s  %s\n' "EVENT" "COUNT"
    printf -- '-%.0s' {1..50}; printf '\n'
    for c in "${COUNTERS[@]}"; do
        label="${c%%|*}"
        rgx="${c#*|}"
        n=$(count_pattern "$rgx")
        printf '%-30s  %s\n' "$label" "$n"
    done

    printf '\n== Notable derived deltas ==\n'
    pair_delta() {
        local label="$1" pat_a="$2" pat_b="$3"
        local a b
        a=$(extract_first_secs "$pat_a")
        b=$(extract_first_secs "$pat_b")
        if [[ -n "$a" && -n "$b" ]]; then
            d=$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.3f", b - a }')
            printf '%-45s  %ss\n' "$label" "$d"
        fi
    }
    pair_delta "TB_ACPI_register → TB_device_found"   "ACPI: bus type thunderbolt registered" "thunderbolt 0-1: new device found"
    pair_delta "TB_device_found → first_GSP_LOCKDOWN" "thunderbolt 0-1: new device found" "GSP_LOCKDOWN_NOTICE"
    pair_delta "tb_acpi_register → first_NVRM_DIAG"   "ACPI: bus type thunderbolt registered" "AORUS Lever M-recover \[DIAG\]: site=probe-end"
    pair_delta "pre-rmInit → post-rmInit-FAIL"        "site=pre-rmInit" "site=post-rmInit-FAIL"
    pair_delta "pre-rmInit → first GSP_LOCKDOWN"      "site=pre-rmInit" "GSP_LOCKDOWN_NOTICE"
    pair_delta "kernel_boot → first_NVRM_DIAG"        "Linux version " "AORUS Lever M-recover \[DIAG\]: site=probe-end"
} > "$OUT"

printf 'Wrote: %s\n' "$OUT"
printf 'Format detected: %s\n' "$TS_FORMAT"

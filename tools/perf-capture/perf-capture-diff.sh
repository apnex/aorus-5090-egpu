#!/usr/bin/env bash
# perf-capture-diff.sh — compare two perf-capture dossiers.
#
# Side-by-side metrics + verdict + sysfs counter delta. Mirrors the
# pattern of state-capture-diff.sh and event-capture-diff.sh.
#
# Usage:
#   ./perf-capture-diff.sh <dossier_A> <dossier_B>

set -u

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <dossier_A> <dossier_B>" >&2
    exit 1
fi

A="$1"
B="$2"
[[ -d "$A" ]] || { echo "Not a dossier: $A" >&2; exit 2; }
[[ -d "$B" ]] || { echo "Not a dossier: $B" >&2; exit 2; }

printf '=== perf-capture-diff ===\n'
printf '  A: %s\n' "$(basename "$A")"
printf '  B: %s\n' "$(basename "$B")"
printf '\n=== meta diff ===\n'
diff <(grep -v '^timestamp_utc' "$A/00-meta.txt" 2>/dev/null) \
     <(grep -v '^timestamp_utc' "$B/00-meta.txt" 2>/dev/null) \
     | head -40

printf '\n=== verdict diff ===\n'
printf '%-15s  %-30s  %-30s\n' "FIELD" "A" "B"
printf -- '-%.0s' {1..80}; printf '\n'
for f in verdict iterations_completed elapsed_seconds qwd_detections_delta lever_m_fires_delta gsp_lockdown_delta rminit_fail_delta; do
    av=$(grep "^$f=" "$A/40-verdict.txt" 2>/dev/null | cut -d= -f2)
    bv=$(grep "^$f=" "$B/40-verdict.txt" 2>/dev/null | cut -d= -f2)
    flag=""
    [[ "$av" != "$bv" ]] && flag="  CHANGED"
    printf '%-15s  %-30s  %-30s%s\n' "$f" "${av:-—}" "${bv:-—}" "$flag"
done

printf '\n=== metrics summary diff (mean per metric) ===\n'
printf '%-40s  %-15s  %-15s  %s\n' "METRIC" "A_mean" "B_mean" "delta_pct"
printf -- '-%.0s' {1..90}; printf '\n'
A_METRICS="$A/30-metrics.csv"
B_METRICS="$B/30-metrics.csv"
if [[ -f "$A_METRICS" && -f "$B_METRICS" ]]; then
    join -t, -1 1 -2 1 \
        <(awk -F, 'NR>1 {sum[$3]+=$4; n[$3]++} END {for (m in n) printf "%s,%.4f\n", m, sum[m]/n[m]}' "$A_METRICS" | sort) \
        <(awk -F, 'NR>1 {sum[$3]+=$4; n[$3]++} END {for (m in n) printf "%s,%.4f\n", m, sum[m]/n[m]}' "$B_METRICS" | sort) \
    | awk -F, '{
        delta = ($3 == 0) ? 0 : (($3 - $2) / $2) * 100
        flag = (delta > 5 || delta < -5) ? "  *" : ""
        printf "%-40s  %-15s  %-15s  %+.1f%%%s\n", $1, $2, $3, delta, flag
    }'
else
    printf '  (one or both dossiers missing metrics CSV)\n'
fi

printf '\n=== sysfs sampler — counter trajectory comparison ===\n'
A_SAMP="$A/31-sysfs-sampler.csv"
B_SAMP="$B/31-sysfs-sampler.csv"
for tag in "A" "B"; do
    [[ "$tag" == "A" ]] && f="$A_SAMP" || f="$B_SAMP"
    [[ -f "$f" ]] || continue
    printf '\n%s sampler (first/last):\n' "$tag"
    head -2 "$f" | tail -1 | awk -F, '{print "  start: cycles="$2" detections="$3" lever_m="$4" gsp="$7" aer_cor="$8}'
    tail -1 "$f"  | awk -F, '{print "  end:   cycles="$2" detections="$3" lever_m="$4" gsp="$7" aer_cor="$8}'
done

printf '\n=== verdict notes ===\n'
printf '%s notes:\n' "A"
grep -A20 '^notes:' "$A/40-verdict.txt" 2>/dev/null | tail -n +2 | head
printf '\n%s notes:\n' "B"
grep -A20 '^notes:' "$B/40-verdict.txt" 2>/dev/null | tail -n +2 | head

printf '\n=== detail commands ===\n'
printf '  diff metrics CSV:  diff <(sort %s) <(sort %s)\n' "$A_METRICS" "$B_METRICS"
printf '  diff sampler CSV:  diff %s %s\n' "$A_SAMP" "$B_SAMP"
printf '  diff state-pre:    state-capture-diff %s/10-pre-state %s/10-pre-state\n' "$A" "$B"
printf '  diff state-post:   state-capture-diff %s/11-post-state %s/11-post-state\n' "$A" "$B"
printf '  diff events:       event-capture-diff %s/12-event-capture %s/12-event-capture\n' "$A" "$B"

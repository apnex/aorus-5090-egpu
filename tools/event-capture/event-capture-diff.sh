#!/usr/bin/env bash
# event-capture-diff.sh — compare two event-capture dossiers
#
# Usage:
#   event-capture-diff.sh <dossier_A> <dossier_B>
#
# Output:
#   - Verdict diff per hypothesis
#   - Notable count differences (GSP_LOCKDOWN, rmInit FAIL, etc.)
#   - Pointers to detailed log diffs

set -u

A="${1:-}"
B="${2:-}"

if [[ -z "$A" || -z "$B" ]]; then
    echo "usage: $0 <dossier_A> <dossier_B>" >&2
    exit 1
fi
if [[ ! -d "$A" || ! -d "$B" ]]; then
    echo "both arguments must be event-capture dossier directories" >&2
    exit 1
fi

A_NAME=$(basename "$A")
B_NAME=$(basename "$B")

printf '=== Event Capture Diff ===\n'
printf '  A: %s\n' "$A_NAME"
printf '  B: %s\n' "$B_NAME"
printf '\n'

printf '=== Hypothesis verdict diff ===\n'
printf '%-20s  %-12s  %-12s\n' "HYPOTHESIS" "A" "B"
printf '%-20s  %-12s  %-12s\n' "----------" "-" "-"

# Collect verdicts from both sides
declare -A va vb
for v in "$A"/30-hypotheses/*-verdict.txt; do
    [[ -f "$v" ]] || continue
    id=$(grep '^hypothesis_id=' "$v" | cut -d= -f2)
    verdict=$(grep '^verdict=' "$v" | cut -d= -f2)
    va[$id]="$verdict"
done
for v in "$B"/30-hypotheses/*-verdict.txt; do
    [[ -f "$v" ]] || continue
    id=$(grep '^hypothesis_id=' "$v" | cut -d= -f2)
    verdict=$(grep '^verdict=' "$v" | cut -d= -f2)
    vb[$id]="$verdict"
done

# Print all hypothesis IDs from either side, marking diffs
all_ids=$(printf '%s\n%s\n' "${!va[@]}" "${!vb[@]}" | sort -u)
for id in $all_ids; do
    [[ -z "$id" ]] && continue
    val_a="${va[$id]:-MISSING}"
    val_b="${vb[$id]:-MISSING}"
    marker="  "
    [[ "$val_a" != "$val_b" ]] && marker="* "
    printf '%s%-18s  %-12s  %-12s\n' "$marker" "$id" "$val_a" "$val_b"
done

printf '\n=== Notable count diff ===\n'
gc() { grep -c "$1" "$2" 2>/dev/null; }
for metric in 'GSP_LOCKDOWN_NOTICE' 'site=post-rmInit-FAIL' 'site=post-rmInit-OK' 'AER.*Cor'; do
    ca=$(gc "$metric" "$A/10-raw/full-kernel.log")
    cb=$(gc "$metric" "$B/10-raw/full-kernel.log")
    ca=${ca:-0}; cb=${cb:-0}
    delta=$((cb - ca))
    sign=""
    [[ $delta -gt 0 ]] && sign="+"
    printf '  %-30s  A=%5s  B=%5s  Δ=%s%s\n' "$metric" "$ca" "$cb" "$sign" "$delta"
done

printf '\n=== Meta diff (changes vs baseline) ===\n'
diff <(grep -E '^(experiment|kernel_cmdline|active_tb_domains|changed)' "$A/00-meta.txt" 2>/dev/null) \
     <(grep -E '^(experiment|kernel_cmdline|active_tb_domains|changed)' "$B/00-meta.txt" 2>/dev/null) \
     | head -40

printf '\n=== Suggested deep-dive commands ===\n'
printf 'Per-subsystem log diff:\n'
for s in thunderbolt nvidia pcie boltd; do
    if [[ -f "$A/20-filtered/${s}.log" && -f "$B/20-filtered/${s}.log" ]]; then
        printf '  diff -u %s/20-filtered/%s.log %s/20-filtered/%s.log\n' "$A" "$s" "$B" "$s"
    fi
done
printf 'Per-hypothesis evidence comparison (only changed verdicts shown above):\n'
for id in $all_ids; do
    [[ -z "$id" ]] && continue
    [[ "${va[$id]:-}" == "${vb[$id]:-}" ]] && continue
    # find the file (lowercase id with prefix)
    fa=$(ls "$A/30-hypotheses/"*-evidence.txt 2>/dev/null | xargs grep -l "hypothesis_id=$id" 2>/dev/null | head -1)
    fb=$(ls "$B/30-hypotheses/"*-evidence.txt 2>/dev/null | xargs grep -l "hypothesis_id=$id" 2>/dev/null | head -1)
    [[ -n "$fa" && -n "$fb" ]] && printf '  diff -u %s %s   # %s\n' "$fa" "$fb" "$id"
done

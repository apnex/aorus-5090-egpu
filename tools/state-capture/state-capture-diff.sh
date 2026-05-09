#!/usr/bin/env bash
# state-capture-diff.sh — compare two state-capture dossiers
#
# Sibling to event-capture-diff.sh.
#
# Usage:
#   state-capture-diff.sh <dossier_A> <dossier_B>
#
# Prints structured per-section diffs:
#   - 00-meta context (kernel, host, hypotheses, etc.)
#   - 01-summary topology
#   - Per-NHI PCI config (lspci -vv equivalence)
#   - Per-domain sysfs attributes
#   - Per-TB-device sysfs attributes
#   - DROM binary equivalence (cmp -l)
#   - Module parameter changes
#   - Cmdline changes
#   - ACPI path differences

set -u

A="${1:-}"
B="${2:-}"

if [[ -z "$A" || -z "$B" ]]; then
    echo "usage: $0 <dossier_A> <dossier_B>" >&2
    exit 1
fi
if [[ ! -d "$A" || ! -d "$B" ]]; then
    echo "both arguments must be state-capture dossier directories" >&2
    exit 1
fi

A_NAME=$(basename "$A")
B_NAME=$(basename "$B")

printf '=== State Capture Diff ===\n'
printf '  A: %s\n' "$A_NAME"
printf '  B: %s\n' "$B_NAME"

section() { printf '\n=== %s ===\n' "$1"; }

# ---- 00 meta diff ----
section '00-meta.txt diff'
diff "$A/00-meta.txt" "$B/00-meta.txt" 2>&1 | head -30 \
    || echo '(identical)'

# ---- 01 summary diff ----
section '01-summary.txt diff'
diff "$A/01-summary.txt" "$B/01-summary.txt" 2>&1 | head -40 \
    || echo '(identical)'

# ---- 12 NHI sysfs diff (per-file) ----
section '12-nhi-sysfs/ — per-NHI sysfs attributes'
for f in "$A"/12-nhi-sysfs/*.txt; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    if [[ -f "$B/12-nhi-sysfs/$bn" ]]; then
        out=$(diff "$f" "$B/12-nhi-sysfs/$bn" 2>&1)
        if [[ -z "$out" ]]; then
            printf '  %s: identical\n' "$bn"
        else
            printf '  %s: DIFF (%d lines)\n' "$bn" "$(echo "$out" | wc -l)"
        fi
    else
        printf '  %s: only in A\n' "$bn"
    fi
done
for f in "$B"/12-nhi-sysfs/*.txt; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    [[ -f "$A/12-nhi-sysfs/$bn" ]] || printf '  %s: only in B\n' "$bn"
done

# ---- 20 domain sysfs ----
section '20-domain-sysfs/ — TB domain attributes'
for f in "$A"/20-domain-sysfs/*.txt; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    if [[ -f "$B/20-domain-sysfs/$bn" ]]; then
        out=$(diff "$f" "$B/20-domain-sysfs/$bn" 2>&1)
        if [[ -z "$out" ]]; then
            printf '  %s: identical\n' "$bn"
        else
            printf '  %s: DIFF\n' "$bn"
            printf '%s\n' "$out" | head -20 | sed 's/^/    /'
        fi
    fi
done

# ---- 30 TB device sysfs (presence + identity) ----
section '30-tb-device-sysfs/ — TB device presence'
echo "  Files only in A:"
diff -q "$A/30-tb-device-sysfs/" "$B/30-tb-device-sysfs/" 2>/dev/null \
    | grep "Only in $A" | sed 's/^/    /'
echo "  Files only in B:"
diff -q "$A/30-tb-device-sysfs/" "$B/30-tb-device-sysfs/" 2>/dev/null \
    | grep "Only in $B" | sed 's/^/    /'

# ---- 41 DROM binary diff (most informative for silicon comparison) ----
section '41-debugfs-drom-*.bin — DROM byte-level comparison'
for f in "$A"/41-debugfs-drom-*.bin; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    if [[ -f "$B/$bn" ]]; then
        if cmp -s "$f" "$B/$bn"; then
            printf '  %s: BIT-IDENTICAL\n' "$bn"
        else
            n=$(cmp -l "$f" "$B/$bn" 2>/dev/null | wc -l)
            printf '  %s: %d byte differences\n' "$bn" "$n"
        fi
    else
        printf '  %s: only in A\n' "$bn"
    fi
done
for f in "$B"/41-debugfs-drom-*.bin; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    [[ -f "$A/$bn" ]] || printf '  %s: only in B\n' "$bn"
done

# ---- 50 ACPI paths ----
section '50-acpi-paths.txt diff'
diff "$A/50-acpi-paths.txt" "$B/50-acpi-paths.txt" 2>&1 | head -20 \
    || echo '(identical)'

# ---- 60 module params ----
section '60-module-params.txt diff'
diff "$A/60-module-params.txt" "$B/60-module-params.txt" 2>&1 | head -20 \
    || echo '(identical)'

# ---- 61 cmdline ----
section '61-cmdline.txt diff'
diff "$A/61-cmdline.txt" "$B/61-cmdline.txt" 2>&1 | head -10 \
    || echo '(identical)'

# ---- 80 boltctl ----
section '80-boltctl/ summary'
for sub in list.txt domains.txt; do
    if [[ -f "$A/80-boltctl/$sub" && -f "$B/80-boltctl/$sub" ]]; then
        out=$(diff "$A/80-boltctl/$sub" "$B/80-boltctl/$sub" 2>&1)
        if [[ -z "$out" ]]; then
            printf '  %s: identical\n' "$sub"
        else
            printf '  %s: DIFF (%d lines)\n' "$sub" "$(echo "$out" | wc -l)"
        fi
    fi
done

# ---- Summary roll-up ----
section 'Summary'
printf 'Sections that DIFFER materially:\n'
material=()
[[ -n "$(diff -q "$A/00-meta.txt" "$B/00-meta.txt" 2>/dev/null)" ]] && material+=('meta')
[[ -n "$(diff -q "$A/01-summary.txt" "$B/01-summary.txt" 2>/dev/null)" ]] && material+=('topology-summary')
[[ -n "$(diff -q "$A/50-acpi-paths.txt" "$B/50-acpi-paths.txt" 2>/dev/null)" ]] && material+=('acpi-paths')
[[ -n "$(diff -q "$A/60-module-params.txt" "$B/60-module-params.txt" 2>/dev/null)" ]] && material+=('module-params')
[[ -n "$(diff -q "$A/61-cmdline.txt" "$B/61-cmdline.txt" 2>/dev/null)" ]] && material+=('cmdline')
# DROM diffs
for f in "$A"/41-debugfs-drom-*.bin; do
    [[ -f "$f" ]] || continue
    bn=$(basename "$f")
    [[ -f "$B/$bn" ]] || continue
    cmp -s "$f" "$B/$bn" || material+=("DROM:$bn")
done
if [[ ${#material[@]} -eq 0 ]]; then
    printf '  none — dossiers structurally equivalent\n'
else
    for m in "${material[@]}"; do printf '  - %s\n' "$m"; done
fi

printf '\nDeep-dive command suggestions:\n'
printf '  diff -r %s %s | less\n' "$A" "$B"
printf '  cmp -l %s/41-debugfs-drom-0-0.bin %s/41-debugfs-drom-0-0.bin\n' "$A" "$B"

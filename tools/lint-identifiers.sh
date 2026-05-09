#!/usr/bin/env bash
# tools/lint-identifiers.sh
#
# Catches stale-identifier drift across files that get INSTALLED to the
# running system or that the build pipeline reads. These files must use
# the current identifier names because they interact with the running
# driver:
#
#   driver module params:    NVreg_TbEgpu*    (was: NVreg_Aorus*)
#   driver C identifiers:    tb_egpu_*        (was: aorus_*)
#   driver macros:           TB_EGPU_*        (was: AORUS_*)
#   userspace file naming:   aorus-egpu-*     (was: aorus-5090-* / aorus-lever-m-*)
#   driver_override values:  aorus_egpu_*     (was: aorus_5090_*)
#
# Designed to run pre-commit / pre-publish to catch the kind of drift
# that surfaced as runtime failures during the Q3 Tier 2 cutover
# (NVreg_Aorus* in modprobe.d when the driver expects NVreg_TbEgpu*).
#
# Excludes:
#   - archive/ (frozen historical artefacts capture old paths verbatim)
#   - nvidia-open-build/ + .git/ (not in repo)
#   - patches/.disabled-for-rollback/ (RETIRED patches, kept verbatim)
#   - tools/state-capture/, event-capture/, perf-capture/ (forensic tools
#     that capture old paths in their data files)
#   - docs/ (reference docs may include historical examples + design notes
#     that legitimately quote prior identifier names)
#   - README.md historical-content section (Fedora 42 / RPMFusion era)
#   - Memory files (per-session journal entries; not part of repo install)
#   - lib/install-manifest.sh's LEGACY_* arrays (intentionally hold old
#     names for backward-compat cleanup)
#   - apply.sh + remove.sh's references to the LEGACY_* arrays
#   - Project-root path /root/aorus-5090-egpu (contains "aorus-5090-" as
#     a literal substring, not a stale identifier)
#
# Exit codes:
#   0 — clean (no stale identifiers found in install surface)
#   1 — stale identifiers present; review output

set -uo pipefail

cd "$(dirname "$0")/.."

errors=0

# ANSI colour for terminal output
if [[ -t 1 ]]; then
    C_FAIL=$'\033[31m'; C_OK=$'\033[32m'; C_HEAD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_FAIL=''; C_OK=''; C_HEAD=''; C_RESET=''
fi

# Build the list of files to scan. Live install surface only.
mapfile -d '' INSTALL_FILES < <(
    find . -type f \
        \( -path './apply.sh' \
        -o -path './status.sh' \
        -o -path './remove.sh' \
        -o -path './lib/*.sh' \
        -o -path './usr/local/sbin/*' \
        -o -path './usr/local/lib/*' \
        -o -path './etc/modprobe.d/*' \
        -o -path './etc/sysctl.d/*' \
        -o -path './etc/udev/rules.d/*' \
        -o -path './etc/systemd/system/*' \
        -o -path './etc/systemd/system/*/*' \
        -o -path './etc/kernel/*' \
        -o -path './kernel-modules/*/*.c' \
        -o -path './kernel-modules/*/*.h' \
        -o -path './kernel-modules/*/Makefile' \
        -o -path './patches/*.patch' \
        \) \
        -not -path './archive/*' \
        -not -path './.git/*' \
        -not -path './nvidia-open-build*' \
        -not -path './patches/disabled/*' \
        -not -path './patches/.disabled-for-rollback/*' \
        -print0
)

# Common filter — drops legitimate exceptions:
#   - the project root path "aorus-5090-egpu"
#   - apply.sh's vestigial-cleanup string literals
filter_common() {
    grep -v 'aorus-5090-egpu' \
    | grep -v 'aorus-5090-allow-compute-load' \
    | grep -v 'aorus-5090-collect-pci-layout' \
    || true
}

# Filter for userspace-naming patterns (aorus-5090-*, aorus-lever-m-*).
# Additionally excludes lib/install-manifest.sh entirely — its LEGACY_*
# arrays intentionally hold old names for backward-compat cleanup.
filter_userspace_naming() {
    filter_common | grep -v '^./lib/install-manifest.sh:' || true
}

# check_pattern <pattern> <desc> <suggestion> [<filter_func>]
# Default filter is filter_common. Pass a different filter for
# userspace-naming patterns.
check_pattern() {
    local pattern="$1" desc="$2" suggestion="$3" filter_func="${4:-filter_common}"
    local matches
    matches=$(printf '%s\0' "${INSTALL_FILES[@]}" \
        | xargs -0 grep -nE "$pattern" 2>/dev/null \
        | "$filter_func")
    if [[ -n "$matches" ]]; then
        local count
        count=$(echo "$matches" | wc -l)
        printf '\n%s%s%s\n' "$C_FAIL" "❌ $desc" "$C_RESET"
        printf '   %s\n' "$suggestion"
        echo "$matches" | sed 's/^/   /'
        errors=$((errors + count))
    fi
}

printf '%sLinting identifier consistency in install surface%s\n' "$C_HEAD" "$C_RESET"
printf '  (%d files scanned)\n' "${#INSTALL_FILES[@]}"

# --- driver module parameters ---
check_pattern \
    'NVreg_Aorus[A-Z][a-zA-Z]+' \
    'Stale driver module parameter NVreg_Aorus*' \
    'Replace NVreg_Aorus → NVreg_TbEgpu (must match driver patches in patches/)'

# --- driver C identifiers (lowercase, underscore-separated) ---
check_pattern \
    '\baorus_lever_[mnoq][_a-z]*' \
    'Stale C identifier aorus_lever_*' \
    'Replace aorus_lever_ → tb_egpu_lever_ (driver function/variable names)'

check_pattern \
    '\baorus_qwatchdog[_a-z]*' \
    'Stale C identifier aorus_qwatchdog' \
    'Replace aorus_qwatchdog → tb_egpu_qwatchdog'

check_pattern \
    '\baorus_dump_aer' \
    'Stale C identifier aorus_dump_aer' \
    'Replace aorus_dump_aer → tb_egpu_dump_aer'

# --- driver macros (uppercase) ---
check_pattern \
    '\bAORUS_LEVER_M[_A-Z]*' \
    'Stale macro AORUS_LEVER_M*' \
    'Replace AORUS_LEVER_M → TB_EGPU_LEVER_M'

check_pattern \
    '\bAORUS_QWATCHDOG[_A-Z]*' \
    'Stale macro AORUS_QWATCHDOG*' \
    'Replace AORUS_QWATCHDOG → TB_EGPU_QWATCHDOG'

check_pattern \
    '\bAORUS_GPU_STATE' \
    'Stale macro AORUS_GPU_STATE' \
    'Replace AORUS_GPU_STATE → TB_EGPU_GPU_STATE'

# --- userspace driver_override values (script string literals) ---
check_pattern \
    'aorus_5090_(manual|disabled)' \
    'Stale driver_override value aorus_5090_*' \
    'Replace aorus_5090_manual → aorus_egpu_manual, aorus_5090_disabled → aorus_egpu_disabled'

# --- userspace file naming (aorus-5090-*, aorus-lever-m-*) ---
# Use filter_userspace_naming — additionally excludes lib/install-manifest.sh
# whose LEGACY_* arrays legitimately hold old names for backward-compat
# cleanup. The driver-identifier checks above DO scan install-manifest.sh
# (LEGACY_* arrays only hold userspace names, not driver C identifiers).
check_pattern \
    'aorus-5090-[a-z][a-z0-9-]+' \
    'Stale userspace file/service name aorus-5090-*' \
    'Replace aorus-5090- → aorus-egpu- (must NOT touch project root path /root/aorus-5090-egpu)' \
    filter_userspace_naming

check_pattern \
    'aorus-lever-m(-[a-z]|\.|"|'\''|$)' \
    'Stale aorus-lever-m-* userspace name' \
    'Replace aorus-lever-m → aorus-egpu-lever-m' \
    filter_userspace_naming

# Summary
echo
if [[ $errors -gt 0 ]]; then
    printf '%s%d stale-identifier occurrences found.%s See lines above.\n' \
        "$C_FAIL" "$errors" "$C_RESET"
    printf '\nTo fix: edit each flagged file and re-run this script. The repo''s\n'
    printf 'docs/ and archive/ are intentionally excluded — only the live install\n'
    printf 'surface is checked.\n'
    exit 1
else
    printf '%s✓ identifier consistency check passed%s — install surface is clean.\n' \
        "$C_OK" "$C_RESET"
    exit 0
fi

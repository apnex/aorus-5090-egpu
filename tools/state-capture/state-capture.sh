#!/usr/bin/env bash
# state-capture.sh — read-only system state snapshot for TB-eGPU
# investigations. Sibling tool to event-capture.sh:
#
#   state-capture  = STATE snapshot (sysfs/PCI/debugfs at one moment)
#   event-capture  = EVENTS over time (kernel logs + hypothesis verdicts)
#
# Renamed 2026-05-08 from tb-domain-forensics.sh — this is THE
# state-capture tool for all future testing on this project (and on
# similar TB-eGPU hosts).
#
# Purpose: deterministically capture the full kernel/driver/firmware-visible
# state of every Thunderbolt domain and attached device on a Linux host, in
# a structured layout that's diff-friendly across runs.
#
# Designed for: comparing TB domain configurations
#   - Across ports of the same NUC (port A vs port B, when boot is on each)
#   - Across NUCs of the same model (does NUC#1 differ from NUC#2?)
#   - Across kernel versions on the same NUC (regression detection)
#   - Across distros (Fedora vs Ubuntu vs Debian on same hardware)
#
# What it captures (read-only, no /dev/nvidia* access):
#   - Per-NHI PCI config (lspci -vv + raw bytes)
#   - Per-domain sysfs attributes
#   - Per-TB-device sysfs attributes (routers, peripherals, retimers)
#   - DebugFS register dumps + DROM binary
#   - Kernel CONFIG_THUNDERBOLT_* + USB4 options
#   - Module parameter values
#   - Filtered kernel TB events
#   - boltctl device list + detailed info
#   - ACPI paths for TB-related devices
#   - Cmdline TB-related options
#
# Output: a timestamped dossier directory under
#   $REPO/archive/state-captures/<ISO-timestamp>-<hostname>-active<id>/
#
# Usage:
#   sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
#
# Compare two dossiers:
#   /root/aorus-5090-egpu/tools/state-capture/state-capture-diff.sh A B
#
# Re-run before/after any config change you want to study.
#
# Idempotent: each invocation creates a fresh timestamped directory; never
# overwrites existing data.

set -u
shopt -s nullglob

if [[ "$EUID" -ne 0 ]]; then
    echo "This script must run as root (needs to read PCI config + DebugFS)." >&2
    exit 1
fi

# ---- Discover output location ----
REPO_ROOT="${REPO_ROOT:-/root/aorus-5090-egpu}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
HOSTNAME=$(hostname)

# Identify which TB domain is "active" right now (has an authorized peripheral)
# This becomes part of the dossier name for at-a-glance comparison
ACTIVE_DOMAINS=""
for d in /sys/bus/thunderbolt/devices/domain*; do
    [[ -d "$d" ]] || continue
    dn=$(basename "$d" | sed 's/domain//')
    # Look for any authorized non-host TB device under this domain
    for dev in /sys/bus/thunderbolt/devices/${dn}-[0-9]*; do
        [[ -d "$dev" ]] || continue
        bn=$(basename "$dev")
        # Skip the host router itself (always X-0)
        [[ "$bn" =~ ^[0-9]+-0$ ]] && continue
        if [[ -r "$dev/authorized" ]] && [[ "$(cat "$dev/authorized" 2>/dev/null)" == "1" ]]; then
            ACTIVE_DOMAINS+="${dn},"
        fi
    done
done
ACTIVE_DOMAINS="${ACTIVE_DOMAINS%,}"
[[ -z "$ACTIVE_DOMAINS" ]] && ACTIVE_DOMAINS="none"

OUT="$REPO_ROOT/archive/state-captures/${TIMESTAMP}-${HOSTNAME}-active${ACTIVE_DOMAINS}"
mkdir -p "$OUT"

step() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$1" >&2; }
write() { local f="$1"; shift; "$@" > "$OUT/$f" 2>&1; }
writeb() { local f="$1"; shift; "$@" > "$OUT/$f" 2>/dev/null; }

step "Output directory: $OUT"

# ---- 00 META ----
step "00 meta — system context"
{
    printf 'timestamp_utc=%s\n' "$TIMESTAMP"
    printf 'hostname=%s\n' "$HOSTNAME"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'kernel_full=%s\n' "$(uname -a)"
    printf 'os_release=%s\n' "$(grep -oE 'PRETTY_NAME="[^"]+"' /etc/os-release 2>/dev/null | head -1)"
    printf 'cpu=%s\n' "$(grep 'model name' /proc/cpuinfo | head -1 | sed 's/.*: //')"
    printf 'active_tb_domains=%s\n' "$ACTIVE_DOMAINS"
    printf '\n--- dmidecode system info (first lines) ---\n'
    dmidecode -t system 2>/dev/null | head -20
    printf '\n--- dmidecode chassis info ---\n'
    dmidecode -t chassis 2>/dev/null | head -10
    printf '\n--- dmidecode bios info ---\n'
    dmidecode -t bios 2>/dev/null | head -15
} > "$OUT/00-meta.txt"

# ---- 01 SUMMARY (top-line per-domain) ----
step "01 summary — top-line per-domain table"
{
    printf 'TB DOMAINS PRESENT:\n'
    for d in /sys/bus/thunderbolt/devices/domain*; do
        [[ -d "$d" ]] || continue
        dn=$(basename "$d")
        printf '\n--- %s ---\n' "$dn"
        for f in security iommu_dma_protection; do
            [[ -r "$d/$f" ]] && printf '  %s = %s\n' "$f" "$(cat "$d/$f" 2>/dev/null)"
        done
        # Walk children of this domain
        printf '  devices:\n'
        for dev in /sys/bus/thunderbolt/devices/$(echo $dn | sed 's/domain//')-*; do
            [[ -d "$dev" ]] || continue
            bn=$(basename "$dev")
            vend=$(cat "$dev/vendor_name" 2>/dev/null || echo "")
            devn=$(cat "$dev/device_name" 2>/dev/null || echo "")
            auth=$(cat "$dev/authorized" 2>/dev/null || echo "")
            gen=$(cat "$dev/generation" 2>/dev/null || echo "")
            uid=$(cat "$dev/unique_id" 2>/dev/null || echo "")
            printf '    %s: vendor=%s device=%s gen=%s authorized=%s uid=%s\n' \
                "$bn" "$vend" "$devn" "$gen" "$auth" "$uid"
        done
    done
    printf '\nNHI (Native Host Interface) PCI DEVICES:\n'
    for nhi in /sys/bus/pci/drivers/thunderbolt/0000:[0-9a-f]*; do
        [[ -d "$nhi" ]] || continue
        bdf=$(basename "$nhi")
        # Identify which TB domain this NHI belongs to (via symlinked domainN)
        dom_link=""
        for d in "$nhi"/domain*; do
            [[ -L "$d" || -d "$d" ]] && dom_link=$(basename "$d")
        done
        vend=$(cat "$nhi/vendor" 2>/dev/null)
        devid=$(cat "$nhi/device" 2>/dev/null)
        sub_v=$(cat "$nhi/subsystem_vendor" 2>/dev/null)
        sub_d=$(cat "$nhi/subsystem_device" 2>/dev/null)
        rev=$(cat "$nhi/revision" 2>/dev/null)
        irq=$(cat "$nhi/irq" 2>/dev/null)
        numa=$(cat "$nhi/numa_node" 2>/dev/null)
        printf '  %s: vendor=%s device=%s rev=%s subsys=%s:%s irq=%s numa=%s domain=%s\n' \
            "$bdf" "$vend" "$devid" "$rev" "$sub_v" "$sub_d" "$irq" "$numa" "$dom_link"
    done
    printf '\nROOT PORT PCI DEVICES (TB roots are 8086:7ec[2-7]):\n'
    for rp in /sys/bus/pci/devices/0000:00:07.[0-9]; do
        [[ -d "$rp" ]] || continue
        bdf=$(basename "$rp")
        vend=$(cat "$rp/vendor" 2>/dev/null)
        devid=$(cat "$rp/device" 2>/dev/null)
        printf '  %s: vendor=%s device=%s class=%s\n' \
            "$bdf" "$vend" "$devid" "$(cat "$rp/class" 2>/dev/null)"
    done
} > "$OUT/01-summary.txt"

# ---- 10 NHI PCI -vv per controller ----
step "10 NHI PCI -vv"
mkdir -p "$OUT/10-nhi-pci-vv"
for nhi in /sys/bus/pci/drivers/thunderbolt/0000:[0-9a-f]*; do
    [[ -d "$nhi" ]] || continue
    bdf=$(basename "$nhi")
    write "10-nhi-pci-vv/${bdf}.txt" lspci -vv -s "${bdf#0000:}"
done

# ---- 11 NHI raw config space bytes (for byte-level diff) ----
step "11 NHI raw PCI config bytes"
mkdir -p "$OUT/11-nhi-pci-bytes"
for nhi in /sys/bus/pci/drivers/thunderbolt/0000:[0-9a-f]*; do
    [[ -d "$nhi" ]] || continue
    bdf=$(basename "$nhi")
    write "11-nhi-pci-bytes/${bdf}.txt" lspci -xxxxx -s "${bdf#0000:}"
done

# ---- 12 NHI sysfs attributes ----
step "12 NHI sysfs attributes"
mkdir -p "$OUT/12-nhi-sysfs"
for nhi in /sys/bus/pci/drivers/thunderbolt/0000:[0-9a-f]*; do
    [[ -d "$nhi" ]] || continue
    bdf=$(basename "$nhi")
    {
        for f in "$nhi"/*; do
            [[ -f "$f" && -r "$f" ]] || continue
            name=$(basename "$f")
            # Skip known-noisy or large/binary attributes
            [[ "$name" =~ ^(config|resource[0-9]*|rom|driver|firmware_node|iommu|iommu_group|msi_irqs|of_node|power|subsystem|uevent|pools|reset_method)$ ]] && continue
            val=$(cat "$f" 2>/dev/null | head -c 200 | tr -d '\0' | tr '\n' ' ' | head -1)
            [[ -n "$val" ]] && printf '%-30s = %s\n' "$name" "$val"
        done | sort
    } > "$OUT/12-nhi-sysfs/${bdf}.txt"
done

# ---- 20 Domain sysfs ----
step "20 domain sysfs"
mkdir -p "$OUT/20-domain-sysfs"
for d in /sys/bus/thunderbolt/devices/domain*; do
    [[ -d "$d" ]] || continue
    dn=$(basename "$d")
    {
        for f in "$d"/*; do
            [[ -f "$f" && -r "$f" ]] || continue
            name=$(basename "$f")
            [[ "$name" =~ ^(uevent|driver|subsystem|power|of_node)$ ]] && continue
            val=$(cat "$f" 2>/dev/null | head -c 500 | tr -d '\0' | tr '\n' ' ' | head -1)
            [[ -n "$val" ]] && printf '%-30s = %s\n' "$name" "$val"
        done | sort
    } > "$OUT/20-domain-sysfs/${dn}.txt"
done

# ---- 30 TB device sysfs (per router/peripheral/retimer) ----
step "30 TB device sysfs"
mkdir -p "$OUT/30-tb-device-sysfs"
for dev in /sys/bus/thunderbolt/devices/[0-9]*; do
    [[ -d "$dev" ]] || continue
    bn=$(basename "$dev")
    [[ "$bn" =~ ^domain ]] && continue  # skip domains, captured in 20
    {
        for f in "$dev"/*; do
            [[ -f "$f" && -r "$f" ]] || continue
            name=$(basename "$f")
            [[ "$name" =~ ^(uevent|driver|subsystem|power|of_node|nvm_authenticate)$ ]] && continue
            val=$(cat "$f" 2>/dev/null | head -c 200 | tr -d '\0' | tr '\n' ' ' | head -1)
            [[ -n "$val" ]] && printf '%-30s = %s\n' "$name" "$val"
        done | sort
    } > "$OUT/30-tb-device-sysfs/${bn}.txt"
done

# ---- 40 DebugFS registers ----
step "40 DebugFS register dumps"
mkdir -p "$OUT/40-debugfs"
for dev in /sys/kernel/debug/thunderbolt/*; do
    [[ -d "$dev" ]] || continue
    bn=$(basename "$dev")
    mkdir -p "$OUT/40-debugfs/$bn"
    [[ -f "$dev/regs" ]] && cat "$dev/regs" 2>/dev/null > "$OUT/40-debugfs/$bn/regs.txt" || true
    # Per-port subdirs
    for portdir in "$dev"/port*; do
        [[ -d "$portdir" ]] || continue
        pn=$(basename "$portdir")
        mkdir -p "$OUT/40-debugfs/$bn/$pn"
        for pf in regs counters path; do
            [[ -f "$portdir/$pf" ]] && cat "$portdir/$pf" 2>/dev/null > "$OUT/40-debugfs/$bn/$pn/${pf}.txt" || true
        done
    done
done

# ---- 41 DROM (binary, byte-comparable) ----
step "41 DROM binary dumps"
for dev in /sys/kernel/debug/thunderbolt/*; do
    [[ -d "$dev" ]] || continue
    bn=$(basename "$dev")
    [[ -f "$dev/drom" ]] && cat "$dev/drom" > "$OUT/41-debugfs-drom-${bn}.bin" 2>/dev/null || true
done

# ---- 50 ACPI paths for TB-related devices ----
step "50 ACPI paths"
{
    for nhi in /sys/bus/pci/drivers/thunderbolt/0000:[0-9a-f]*; do
        [[ -d "$nhi" ]] || continue
        bdf=$(basename "$nhi")
        printf '%s firmware_node = %s\n' "$bdf" \
            "$(readlink -f "$nhi/firmware_node" 2>/dev/null || echo none)"
        if [[ -r "$nhi/firmware_node/path" ]]; then
            printf '  ACPI path: %s\n' "$(cat "$nhi/firmware_node/path")"
        fi
    done
    for rp in /sys/bus/pci/devices/0000:00:07.[0-9]; do
        [[ -d "$rp" ]] || continue
        bdf=$(basename "$rp")
        printf '%s firmware_node = %s\n' "$bdf" \
            "$(readlink -f "$rp/firmware_node" 2>/dev/null || echo none)"
        if [[ -r "$rp/firmware_node/path" ]]; then
            printf '  ACPI path: %s\n' "$(cat "$rp/firmware_node/path")"
        fi
    done
} > "$OUT/50-acpi-paths.txt"

# ---- 60 Module parameters ----
step "60 thunderbolt module params"
{
    printf '--- modinfo thunderbolt ---\n'
    modinfo thunderbolt 2>/dev/null | grep -E "^(parm|version|filename):"
    printf '\n--- /sys/module/thunderbolt/parameters/* ---\n'
    for p in /sys/module/thunderbolt/parameters/*; do
        [[ -r "$p" ]] || continue
        printf '%-25s = %s\n' "$(basename "$p")" "$(cat "$p" 2>/dev/null)"
    done
    printf '\n--- Kernel CONFIG_USB4_*/CONFIG_THUNDERBOLT_* ---\n'
    grep -E "^CONFIG_(USB4|THUNDERBOLT)" "/boot/config-$(uname -r)" 2>/dev/null
} > "$OUT/60-module-params.txt"

# ---- 61 cmdline TB-related ----
step "61 cmdline TB-related options"
{
    printf 'Full /proc/cmdline:\n%s\n\n' "$(cat /proc/cmdline)"
    printf 'TB / PCIe / IOMMU related tokens:\n'
    tr ' ' '\n' < /proc/cmdline | grep -iE "thunderbolt|tb|pcie_aspm|pcie_port|iommu|pci="
} > "$OUT/61-cmdline.txt"

# ---- 70 Kernel TB events (filtered) ----
step "70 kernel TB events"
{
    journalctl -k -b 0 --no-pager 2>/dev/null \
        | grep -iE "thunderbolt|TBT|tunnel|router|retimer|new device|bolt|0000:00:0[d7]\.|usb4_port|pcieport.*aer" \
        | head -200
} > "$OUT/70-kernel-tb-events.txt"

# ---- 80 boltctl ----
step "80 boltctl state"
mkdir -p "$OUT/80-boltctl"
boltctl list 2>&1 > "$OUT/80-boltctl/list.txt"
boltctl domains 2>&1 > "$OUT/80-boltctl/domains.txt"
# Per-device info
boltctl list 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u | while read uuid; do
    [[ -z "$uuid" ]] && continue
    boltctl info "$uuid" 2>&1 > "$OUT/80-boltctl/info-${uuid}.txt"
done

# ---- 90 Full PCI tree topology ----
step "90 PCI tree topology"
{
    printf '--- lspci -tvnn (full tree) ---\n'
    lspci -tvnn 2>/dev/null
    printf '\n--- lspci -nn (flat) ---\n'
    lspci -nn 2>/dev/null
} > "$OUT/90-pci-tree.txt"

# ---- 91/92 Per-device PCI config (under TB root ports + any nvidia GPU) ----
# Capture every PCI device on the bus segments downstream of TB root ports
# 0000:00:07.0 and 0000:00:07.2, plus any 0x10de GPU (will overlap if eGPU is up).
step "91 per-device lspci -vvxxx (TB-tree + GPU)"
mkdir -p "$OUT/91-pci-config-vvxxx"
mkdir -p "$OUT/92-pci-config-bytes"
collect_bdf=()
# TB root ports themselves
for bdf in 0000:00:07.0 0000:00:07.2; do
    [[ -d "/sys/bus/pci/devices/$bdf" ]] && collect_bdf+=("$bdf")
done
# Everything downstream of those root ports
for bdf in /sys/bus/pci/devices/*; do
    [[ -d "$bdf" ]] || continue
    name=$(basename "$bdf")
    parent_chain=""
    cur="$bdf"
    while :; do
        cur=$(dirname "$(readlink -f "$cur")")
        b=$(basename "$cur")
        [[ "$b" == "pci0000:00" || "$b" == "/" ]] && break
        parent_chain="$parent_chain $b"
    done
    if echo "$parent_chain" | grep -qE '0000:00:07\.[02]'; then
        collect_bdf+=("$name")
    fi
done
# NVIDIA GPUs (any vendor 0x10de, in case detection above missed them)
for d in /sys/bus/pci/devices/*; do
    [[ "$(<"$d/vendor" 2>/dev/null)" == "0x10de" ]] && collect_bdf+=("$(basename "$d")")
done
# De-duplicate
mapfile -t collect_bdf < <(printf '%s\n' "${collect_bdf[@]}" | sort -u)
{
    printf 'Captured BDFs (TB tree + GPUs):\n'
    printf '  %s\n' "${collect_bdf[@]}"
} > "$OUT/91-pci-config-vvxxx/_index.txt"
for bdf in "${collect_bdf[@]}"; do
    [[ -z "$bdf" ]] && continue
    lspci -vvxxx -s "$bdf" 2>/dev/null > "$OUT/91-pci-config-vvxxx/${bdf}.txt"
    # Raw 4KiB ECAM for byte-level diffing
    if [[ -r "/sys/bus/pci/devices/$bdf/config" ]]; then
        cp "/sys/bus/pci/devices/$bdf/config" "$OUT/92-pci-config-bytes/${bdf}.bin" 2>/dev/null
    fi
done

# ---- 93 PCI sysfs resource + power state ----
step "93 PCI sysfs resource + power"
mkdir -p "$OUT/93-pci-sysfs"
for bdf in "${collect_bdf[@]}"; do
    [[ -z "$bdf" ]] && continue
    [[ -d "/sys/bus/pci/devices/$bdf" ]] || continue
    {
        printf '## %s\n' "$bdf"
        for f in vendor device subsystem_vendor subsystem_device class revision \
                 current_link_speed current_link_width max_link_speed max_link_width \
                 enable msi_bus numa_node local_cpus irq d3cold_allowed; do
            [[ -r "/sys/bus/pci/devices/$bdf/$f" ]] && \
                printf '%-25s = %s\n' "$f" "$(cat "/sys/bus/pci/devices/$bdf/$f" 2>/dev/null)"
        done
        printf '\n--- resource (BAR map) ---\n'
        cat "/sys/bus/pci/devices/$bdf/resource" 2>/dev/null
        printf '\n--- power/* ---\n'
        for p in /sys/bus/pci/devices/$bdf/power/*; do
            [[ -r "$p" && -f "$p" ]] || continue
            printf '%-30s = %s\n' "power/$(basename "$p")" "$(cat "$p" 2>/dev/null | head -c 200)"
        done
        printf '\n--- driver bound ---\n'
        if [[ -L "/sys/bus/pci/devices/$bdf/driver" ]]; then
            printf 'driver = %s\n' "$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver")")"
        else
            printf 'driver = (none)\n'
        fi
        printf '\n--- aer_dev_correctable / aer_dev_fatal / aer_dev_nonfatal ---\n'
        for f in aer_dev_correctable aer_dev_fatal aer_dev_nonfatal; do
            [[ -r "/sys/bus/pci/devices/$bdf/$f" ]] && {
                printf '## %s ##\n' "$f"
                cat "/sys/bus/pci/devices/$bdf/$f" 2>/dev/null
                printf '\n'
            }
        done
    } > "$OUT/93-pci-sysfs/${bdf}.txt"
done

# ---- 94 /proc/iomem (memory map) ----
step "94 /proc/iomem"
cat /proc/iomem 2>/dev/null > "$OUT/94-iomem.txt"

# ---- 95 /proc/interrupts (IRQ routing snapshot) ----
step "95 /proc/interrupts"
cat /proc/interrupts 2>/dev/null > "$OUT/95-interrupts.txt"

# ---- 96 IOMMU groups (even with iommu=off, some grouping persists) ----
step "96 IOMMU groups"
{
    if [[ -d /sys/kernel/iommu_groups ]]; then
        for g in /sys/kernel/iommu_groups/*/devices/*; do
            [[ -L "$g" ]] || continue
            grp=$(basename "$(dirname "$(dirname "$g")")")
            dev=$(basename "$g")
            printf 'group=%s device=%s\n' "$grp" "$dev"
        done | sort -V
    else
        printf '(no /sys/kernel/iommu_groups — IOMMU disabled or not supported)\n'
    fi
} > "$OUT/96-iommu-groups.txt"

# ---- 97 PCIe Equalization + Link-Status-2 decoded summary (T1.5) ----
# Surface the per-port equalization history and link-state-2 details from
# the lspci -vv output we already captured in 91-. These are the most
# likely candidates for hidden per-port asymmetry the GSP firmware can
# observe but PCIe AER cannot.
step "97 PCIe Eq + LnkSta2 decoded summary"
mkdir -p "$OUT/97-pcie-eq-decoded"
{
    printf '# Per-device PCIe equalization + link-state-2 summary\n'
    printf '# Extracted from 91-pci-config-vvxxx/<BDF>.txt (already-captured lspci -vv output).\n'
    printf '#\n'
    printf '# Why this matters: PCIe Gen3+ link equalization is per-port, set by BIOS at\n'
    printf '# boot, and persists in registers visible to firmware (incl. NVIDIA GSP) but\n'
    printf '# NOT raised as AER events. If Port A vs Port B differ here, that may explain\n'
    printf '# why GSP firmware behaves differently when the host driver/AER stack sees\n'
    printf '# nothing.\n\n'
    for f in "$OUT/91-pci-config-vvxxx"/*.txt; do
        [[ -f "$f" ]] || continue
        bdf=$(basename "$f" .txt)
        [[ "$bdf" == "_index" ]] && continue
        printf '## %s\n' "$bdf"
        # LnkSta2 / LnkCap2 / LnkCtl2 / LnkCtl3 — Express cap, fields PCIe 4.0 spec §7.5.3
        grep -E "^[[:space:]]+(LnkCap2|LnkCtl2|LnkSta2|LnkCtl3):" "$f" | sed 's/^[[:space:]]*/    /'
        # Receiver Margining (extended cap)
        grep -E "Lane Margining|Capabilities:.*\\[[0-9a-f]+ v.\\] Physical Layer 16\\.0 GT/s" "$f" | sed 's/^[[:space:]]*/    /'
        # Lane Equalization Control entries (Lane Eq Capability extended)
        grep -E "Lane.*Equalization|EqCtrl|Preset|FullSwing|LowFreq|UpstreamPort.*LaneEq|DownstreamPort.*LaneEq|Equalization.*Lane" "$f" | sed 's/^[[:space:]]*/    /' | head -20
        printf '\n'
    done
} > "$OUT/97-pcie-eq-decoded/_summary.txt"

# Additionally, dump the extended config space from 0x100-0x1FF for each
# captured device — this is where Equalization Capability + Lane Margining
# + DPC live. Hex form for direct byte-diffing across ports.
for f in "$OUT/92-pci-config-bytes"/*.bin; do
    [[ -f "$f" ]] || continue
    bdf=$(basename "$f" .bin)
    # Extended config space starts at 0x100. Dump first 256 bytes of it
    # (covers AER + DPC + ATS + Eq Cap + Lane Margining for most devices).
    if [[ $(stat -c%s "$f" 2>/dev/null) -ge 512 ]]; then
        {
            printf '## %s extended config 0x100-0x1FF\n' "$bdf"
            xxd -s 0x100 -l 0x100 -c 16 "$f" 2>/dev/null
        } > "$OUT/97-pcie-eq-decoded/${bdf}-ext-cfg.txt"
    fi
done

# ---- 100 All relevant module parameters (NVIDIA + TB stack) ----
step "100 module parameters (NVIDIA + TB stack)"
mkdir -p "$OUT/100-module-parameters"
for mod in thunderbolt thunderbolt_net nvidia nvidia_uvm nvidia_modeset nvidia_drm; do
    out="$OUT/100-module-parameters/${mod}.txt"
    {
        printf '## modinfo (filename, version, parm) ##\n'
        if modinfo "$mod" 2>/dev/null | grep -E "^(filename|version|parm):" ; then :; else
            printf '(module %s not loadable / not present)\n' "$mod"
        fi
        printf '\n## /sys/module/%s/parameters/* ##\n' "$mod"
        if [[ -d "/sys/module/$mod/parameters" ]]; then
            for p in /sys/module/$mod/parameters/*; do
                [[ -r "$p" ]] || continue
                v=$(cat "$p" 2>/dev/null | tr -d '\0' | head -c 500)
                printf '%-30s = %s\n' "$(basename "$p")" "$v"
            done
        else
            printf '(module %s not currently loaded)\n' "$mod"
        fi
    } > "$out"
done

# ---- 110 Firmware / platform versions ----
step "110 firmware + platform versions"
{
    printf '## DMI / SMBIOS ##\n'
    for f in bios_vendor bios_version bios_date board_vendor board_name product_name product_family sys_vendor; do
        [[ -r "/sys/class/dmi/id/$f" ]] && \
            printf '%-25s = %s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null)"
    done
    if command -v dmidecode >/dev/null 2>&1; then
        printf '\n## dmidecode bios + ec ##\n'
        dmidecode -s bios-version 2>/dev/null | head -1 | xargs -I{} printf 'bios-version = %s\n' "{}"
        dmidecode -s bios-vendor 2>/dev/null | head -1 | xargs -I{} printf 'bios-vendor  = %s\n' "{}"
        dmidecode -s bios-release-date 2>/dev/null | head -1 | xargs -I{} printf 'bios-release = %s\n' "{}"
    fi
    printf '\n## kernel version ##\n'
    uname -a
    printf '\n## NVIDIA driver version (if loaded) ##\n'
    [[ -r /proc/driver/nvidia/version ]] && cat /proc/driver/nvidia/version
    printf '\n## TB host controller PCI revision (probe quirks key off this) ##\n'
    for nhi in 0000:00:0d.2 0000:00:0d.3; do
        [[ -d "/sys/bus/pci/devices/$nhi" ]] || continue
        rev=$(setpci -s "$nhi" REVISION 2>/dev/null)
        printf '%s revision = 0x%s\n' "$nhi" "$rev"
    done
} > "$OUT/110-firmware-versions.txt"

# ---- 120 NVIDIA procfs subtree (T1.6) ----
# /proc/driver/nvidia/* contains driver-applied registry, capabilities,
# warnings, GSP version, registry. None of this is in lspci or sysfs.
step "120 /proc/driver/nvidia subtree"
mkdir -p "$OUT/120-nvidia-procfs"
if [[ -d /proc/driver/nvidia ]]; then
    for f in /proc/driver/nvidia/version \
             /proc/driver/nvidia/params \
             /proc/driver/nvidia/registry \
             /proc/driver/nvidia/suspend \
             /proc/driver/nvidia/suspend_depth; do
        [[ -r "$f" ]] && cp "$f" "$OUT/120-nvidia-procfs/$(basename "$f").txt" 2>/dev/null
    done
    # gpus/<bus>/information has GSP firmware version + GPU info
    for gdir in /proc/driver/nvidia/gpus/*/; do
        [[ -d "$gdir" ]] || continue
        bus=$(basename "$gdir")
        for f in "$gdir"information "$gdir"registry; do
            [[ -r "$f" ]] && cp "$f" "$OUT/120-nvidia-procfs/gpu-${bus}-$(basename "$f").txt" 2>/dev/null
        done
    done
    # capabilities + warnings + patches
    for sub in capabilities warnings patches; do
        if [[ -d "/proc/driver/nvidia/$sub" ]]; then
            for f in /proc/driver/nvidia/$sub/*; do
                [[ -r "$f" && -f "$f" ]] && {
                    cp "$f" "$OUT/120-nvidia-procfs/${sub}-$(basename "$f").txt" 2>/dev/null
                }
            done
        fi
    done
else
    echo "(NVIDIA driver not loaded — /proc/driver/nvidia absent)" \
        > "$OUT/120-nvidia-procfs/_absent.txt"
fi

# ---- 121 TB debugfs port counters (T1.6) ----
# /sys/kernel/debug/thunderbolt/<router>/port<N>/counters has TB-internal
# retransmission / retrain / error counts that don't surface as PCIe AER.
step "121 TB port counters (debugfs)"
mkdir -p "$OUT/121-tb-counters"
if [[ -d /sys/kernel/debug/thunderbolt ]]; then
    for router in /sys/kernel/debug/thunderbolt/*/; do
        [[ -d "$router" ]] || continue
        rname=$(basename "$router")
        for portdir in "$router"port*/; do
            [[ -d "$portdir" ]] || continue
            pname=$(basename "$portdir")
            cnt="$portdir/counters"
            [[ -r "$cnt" ]] && {
                cat "$cnt" 2>/dev/null > "$OUT/121-tb-counters/${rname}-${pname}-counters.txt" 2>/dev/null
            }
        done
    done
else
    echo "(no debugfs thunderbolt access)" > "$OUT/121-tb-counters/_absent.txt"
fi

# ---- 122 RAPL energy snapshot (T1.6) ----
# /sys/class/powercap/intel-rapl/*/energy_uj — per-domain energy counters.
# Comparing snapshots before/after rm_init shows whether SerDes is doing
# extra work on Port A (more retrains = more power).
step "122 RAPL energy snapshot"
{
    printf '## RAPL energy counters at moment of capture (uJ) ##\n'
    printf '## Diff this against another dossier or take two captures ##\n'
    printf '## with a known time delta in between to estimate watts.\n\n'
    for d in /sys/class/powercap/intel-rapl/*/; do
        [[ -d "$d" ]] || continue
        name=$(cat "$d/name" 2>/dev/null)
        energy=$(cat "$d/energy_uj" 2>/dev/null)
        max=$(cat "$d/max_energy_range_uj" 2>/dev/null)
        printf 'domain=%-20s energy_uj=%-20s max_energy_range_uj=%s\n' \
            "$(basename "$d")(${name})" "$energy" "$max"
    done
    printf '\n## Capture timestamp (epoch ns) ##\n'
    date +%s%N
} > "$OUT/122-rapl-energy.txt"

# ---- 124 AORUS driver sysfs counters (T1.7, 2026-05-08) ----
# Patch 0023 (Mode B telemetry S1+S2+S3) added persistent qwatchdog
# detection state and Lever M-recover counters. Capture them so future
# state dossiers automatically include the new telemetry surfaces.
step "124 AORUS driver sysfs counters"
mkdir -p "$OUT/124-aorus-sysfs"
for d in /sys/bus/pci/devices/*; do
    vendor=$(cat "$d/vendor" 2>/dev/null)
    [[ "$vendor" == "0x10de" ]] || continue
    bdf=$(basename "$d")
    # Q-watchdog: cycles, detections (existing) + last_detection_jiffies,
    # last_pmc_boot_0, last_aer_summary (S3 from patch 0023)
    # Lever M-recover: fires, successes, surrenders, last_fire_jiffies
    {
        printf '## %s\n' "$bdf"
        for f in "$d"/aorus_qwatchdog_* "$d"/aorus_lever_m_*; do
            [[ -r "$f" ]] || continue
            name=$(basename "$f")
            printf '\n--- %s ---\n' "$name"
            cat "$f" 2>/dev/null
        done
    } > "$OUT/124-aorus-sysfs/${bdf}.txt"
done

# ---- 123 Thermal zone snapshot (T1.6) ----
# /sys/class/thermal/thermal_zone*/temp — millidegrees C. If Port A's PCIe
# SerDes is more active, package thermals during rm_init may differ.
step "123 thermal zone snapshot"
{
    printf '## Thermal zones at moment of capture (millidegrees C) ##\n\n'
    for tz in /sys/class/thermal/thermal_zone*/; do
        [[ -d "$tz" ]] || continue
        zname=$(basename "$tz")
        type=$(cat "$tz/type" 2>/dev/null)
        temp=$(cat "$tz/temp" 2>/dev/null)
        # Convert to degrees C
        if [[ -n "$temp" && "$temp" =~ ^[0-9-]+$ ]]; then
            tempC=$(awk -v t="$temp" 'BEGIN { printf "%.1f", t/1000 }')
            printf '%-22s type=%-25s temp=%s mC (%.1f°C)\n' "$zname" "$type" "$temp" "$tempC"
        fi
    done
    printf '\n## Capture timestamp (epoch ns) ##\n'
    date +%s%N
} > "$OUT/123-thermal.txt"

# ---- Done ----
step "DONE — dossier: $OUT"
{
    printf '\n=== files captured ===\n'
    find "$OUT" -type f | sort | sed "s|$OUT/||"
    printf '\n=== total size ===\n'
    du -sh "$OUT"
} | tee -a "$OUT/01-summary.txt"

printf '\nTo compare with another dossier:\n'
printf '  diff -r %s OTHER_DOSSIER\n' "$OUT"
printf '  cmp -l %s/41-debugfs-drom-*.bin OTHER_DOSSIER/41-debugfs-drom-*.bin\n' "$OUT"

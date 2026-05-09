# State capture toolkit

Companion to `tools/event-capture/`:

- **`state-capture/`** — STATE snapshot (sysfs/PCI/debugfs at one moment)
- **`event-capture/`** — EVENTS over time (kernel logs + hypothesis verdicts)

Run state capture for "what does the system look like right now?" and
event capture for "did hypothesis X fire during this boot/window?"

Both share the same paired-tool design: a main capture script and a
diff script for comparing two captures.

## Tools

| File | Purpose |
|---|---|
| `state-capture.sh` | Main read-only state snapshot tool |
| `state-capture-diff.sh` | Compare two state dossiers; section-level differences |

## Quick examples

```bash
# Snapshot current state
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh

# Compare two snapshots
/root/aorus-5090-egpu/tools/state-capture/state-capture-diff.sh \
    archive/state-captures/<dossier_A> \
    archive/state-captures/<dossier_B>
```

## What it captures

For every TB domain + attached device on the host (read-only, no
`/dev/nvidia*` access — safe anytime):

- Per-NHI PCI config (lspci -vv + raw config space bytes)
- Per-domain sysfs (security, iommu_dma_protection, etc.)
- Per-TB-device sysfs (rx/tx_speed, lanes, generation, authorized)
- DebugFS register dumps + DROM binary blobs (byte-comparable)
- Kernel `CONFIG_USB4_*` / `CONFIG_THUNDERBOLT_*` build options
- Module parameter current values
- Filtered TB event log
- boltctl device list + per-device info
- ACPI paths for TB-related devices
- Cmdline TB-related options

## Output structure

```
archive/state-captures/<timestamp>-<hostname>-active<domain-id>/
├── 00-meta.txt              # context (kernel, distro, dmidecode summary)
├── 01-summary.txt           # top-line per-domain table
├── 10-nhi-pci-vv/           # per-NHI lspci -vv
├── 11-nhi-pci-bytes/        # per-NHI raw config space
├── 12-nhi-sysfs/            # per-NHI sysfs attributes
├── 20-domain-sysfs/         # per-TB-domain sysfs
├── 30-tb-device-sysfs/      # per-TB-device sysfs
├── 40-debugfs/              # /sys/kernel/debug/thunderbolt
├── 41-debugfs-drom-*.bin    # raw DROM bytes (binary)
├── 50-acpi-paths.txt        # firmware_node paths
├── 60-module-params.txt     # module params + CONFIG_USB4_*
├── 61-cmdline.txt           # /proc/cmdline (filtered)
├── 70-kernel-tb-events.txt  # journalctl -k filtered to TB
└── 80-boltctl/              # boltctl list + per-device info
```

## When to run

Anytime the system is in a "moment of interest":

| Scenario | Why capture |
|---|---|
| Cold-cold-boot completed | Baseline for that boot's configuration |
| Before/after cmdline change | Did config persist as expected? |
| Before/after module reload | Did sysfs change? |
| When system enters unusual state | Snapshot for forensic later |
| After cable swap (different port) | New domain mapping captured |
| Cross-NUC comparison | Bring back to base for comparison |
| New tool / driver release | Regression detection |

## Pairing with event capture

For a complete experimental record, run BOTH:

```bash
sudo /root/aorus-5090-egpu/tools/state-capture/state-capture.sh
sudo /root/aorus-5090-egpu/tools/event-capture/event-capture.sh \
    --experiment <name>
```

Together they constitute the full empirical record:
- State = "what does the world look like now"
- Events = "what happened to get here, did hypothesis X fire"

## See also

- `docs/state-capture-methodology.md` — full methodology + workflows
- `tools/event-capture/` — event capture sibling toolkit
- `docs/thunderbolt-testing.md` — top-level TB testing guide
- `docs/event-capture-methodology.md` — event capture methodology

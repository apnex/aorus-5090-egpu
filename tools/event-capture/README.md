# Event capture toolkit

Companion to `tools/state-capture/state-capture.sh`:

- **`state-capture.sh`** — STATE snapshot (sysfs/PCI/debugfs at one moment)
- **`event-capture/`** — EVENTS over time (kernel/userspace logs, hypothesis-driven analysis)

Run state forensics for "what does the system look like now?" and event capture
for "did hypothesis X fire during this boot/window?"

## Tools

| File | Purpose |
|---|---|
| `event-capture.sh` | Main capture + per-hypothesis analysis tool |
| `event-capture-diff.sh` | Compare two captures, highlight verdict + count deltas |
| `hypotheses/` | Pluggable hypothesis signature files (one per hypothesis) |
| `subsystems/` | Pluggable journal filters (one per subsystem) |

## Quick examples

```bash
# Baseline — current Port B boot, all hypotheses, all subsystems
sudo ./event-capture.sh --experiment baseline-portB

# After a cmdline change, capture and tag the change
sudo ./event-capture.sh --experiment B1-dyndbg-portA \
    --changed 'cmdline=thunderbolt.dyndbg=+pflm' \
    --changed 'port=A'

# Just one hypothesis
sudo ./event-capture.sh --experiment quick-test --hypothesis h19

# Compare two captures
./event-capture-diff.sh \
    archive/event-captures/baseline-portB-... \
    archive/event-captures/B1-dyndbg-portA-...
```

## Output structure

```
archive/event-captures/<exp-name>-<timestamp>/
├── 00-meta.txt           # context: experiment, host, kernel, cmdline, changes
├── 10-raw/
│   ├── full-kernel.log   # journalctl -k -b 0, no filter
│   ├── full-journal.log  # full journal, no filter
│   └── current-cmdline.txt
├── 20-filtered/
│   ├── thunderbolt.log   # per-subsystem filter applied (extensible)
│   ├── nvidia.log
│   ├── pcie.log
│   └── boltd.log
├── 30-hypotheses/
│   ├── <id>-verdict.txt  # FIRED | NOT-FIRED | INCONCLUSIVE + counts
│   └── <id>-evidence.txt # log lines that triggered the verdict
└── 99-summary.txt        # human + grep-able roll-up
```

## Extension

Drop a new file in `hypotheses/` or `subsystems/` and the tool picks it up
automatically. See `hypotheses/README.md` and `subsystems/README.md` for
file formats.

## When to use

- Before/after a cmdline change → did the change make hypothesis X fire/stop firing?
- Port A vs Port B → does the asymmetry trigger different signatures?
- Across kernel versions → did upgrading shift the verdict?
- Across NUCs → does the same hypothesis fire on someone else's hardware?

## Methodology

Full methodology + walkthroughs in `docs/event-capture-methodology.md`.

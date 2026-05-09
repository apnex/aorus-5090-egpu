# perf-capture toolkit

Third tool in the matched-pair forensic family:

| Tool | Purpose |
|---|---|
| `state-capture` | STATE snapshot (sysfs/PCI/debugfs at one moment) |
| `event-capture` | EVENTS over time (kernel logs + hypothesis verdicts) |
| **`perf-capture`** | **PERFORMANCE under named workload** |

Each invocation produces a self-contained dossier with all telemetry +
verdict + reproduction script.

## Tools

| File | Purpose |
|---|---|
| `perf-capture.sh` | Main capture tool — runs a named workload with full telemetry |
| `perf-capture-diff.sh` | Compare two perf dossiers, highlight metric + verdict deltas |
| `workloads/` | Pluggable workload definitions (one file per workload) |

## Quick examples

```bash
# Run today's Mode B field validation with the mode-b-stress workload
sudo ./perf-capture.sh \
    --experiment FT-portA-mode-b-validation \
    --workload mode-b-stress \
    --changed 'port=A' \
    --changed 'patch=0023-v2'

# Compare two captures
./perf-capture-diff.sh \
    archive/perf-captures/baseline-portB-... \
    archive/perf-captures/FT-portA-mode-b-validation-...
```

## Output structure

```
archive/perf-captures/<exp-name>-<timestamp>/
├── 00-meta.txt              # cmdline, srcversion, workload, --changed, time window
├── 10-pre-state             # symlink → state-capture dossier (pre)
├── 11-post-state            # symlink → state-capture dossier (post)
├── 12-event-capture         # symlink → event-capture dossier
├── 20-iterations/
│   ├── iter-001.txt         # per-iteration raw workload output
│   └── iter-NNN.txt
├── 30-metrics.csv           # iteration_id, epoch, metric_name, value, unit
├── 31-sysfs-sampler.csv     # qwd cycles/detections, lever_m, journal counts
├── 40-verdict.txt           # PASS / MODE-B-CAUGHT / FAIL-* + criteria
├── 99-summary.txt           # human-readable
└── reproduction.sh          # self-contained runnable
```

## Adding a new workload

Drop a file `workloads/<name>.sh` defining:

```bash
WORKLOAD_NAME="my-workload"
WORKLOAD_DESC="One-line description"
WORKLOAD_CMD='/path/to/cmd --args'
WORKLOAD_ITERATION_TIMEOUT=120         # seconds per iteration
WORKLOAD_DURATION=420                  # default total wall-time cap
METRICS_REGEX='^line-pattern (\w+) ([0-9.]+)$'  # captures: name, value
METRICS_UNIT="GB/s"                    # or "tokens/sec", "ms", etc.
```

Auto-discovered by `perf-capture.sh --workload <name>`.

## Verdicts (standard)

| Verdict | Criteria |
|---|---|
| `PASS` | All iterations completed; qwd_detections=0; lever_m_fires=0; GSP_LOCKDOWN=0; rmInit_FAIL=0 (vs pre) |
| `MODE-B-CAUGHT` | qwd_detections ≥1 OR lever_m_fires ≥1 increment — patch 0023 telemetry validates! |
| `FAIL-GSP-LOCKDOWN` | GSP_LOCKDOWN_NOTICE fired during test |
| `FAIL-RMINIT` | rmInit_FAIL incremented |
| `WARN-NONZERO-EXIT` | At least one iteration exited non-zero |

## Why this matters

Once we have ≥2 dossiers for the same workload, we can:

- **Reproduce experiments** — `bash reproduction.sh` from any dossier
- **Detect regressions** — diff against last known-good dossier
- **Track perf over time** — same workload, every kernel/driver upgrade
- **Cross-NUC validation** — same workload on different hardware
- **Pre/post patch perf impact** — quantify any patch's perf cost

## Cross-references

- Companion: `tools/state-capture/`, `tools/event-capture/`
- Methodology: `docs/perf-capture-methodology.md`
- Workload examples: `workloads/mode-b-stress.sh`

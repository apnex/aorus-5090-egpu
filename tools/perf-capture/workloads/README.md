# Workloads

Each workload is a sourced bash file that defines a named performance
test. Drop a new file in this directory and it's auto-discovered.

## Current workloads

| File | Description |
|---|---|
| `mode-b-stress.sh` | nvbandwidth bidirectional + CE/SM mix; targets Mode B silent freeze |

## Workload contract

Required variables:

```bash
WORKLOAD_NAME="<id>"           # short identifier; matches filename without .sh
WORKLOAD_DESC="<one-line>"     # human-readable description
WORKLOAD_CMD='<command>'       # command to execute per iteration
WORKLOAD_ITERATION_TIMEOUT=120 # seconds per iteration before timeout kills it
WORKLOAD_DURATION=420          # default total wall-time cap (seconds)
METRICS_REGEX='<regex>'        # captures: \1=metric_name, \2=value
METRICS_UNIT="<unit>"          # default unit string for all metrics from this workload
```

Optional variables (override per-test command-line):
- `WORKLOAD_DURATION` — total wall-time cap (overridable via `--duration`)

## Future workload candidates

Aligned with task list:

| Workload | Task ref | Purpose |
|---|---|---|
| `cold-load-llama-1b.sh` | #74 | ollama llama3.2:1b cold-load timing |
| `cold-load-llama-8b.sh` | #74, #77 | ollama llama3.1:8b cold-load |
| `decode-throughput-llama-8b.sh` | #71 | sustained decode tokens/sec |
| `nvbandwidth-h2d-only.sh` | — | TB tunnel H2D baseline (lower-stress baseline) |
| `nvbandwidth-bidirectional-only.sh` | — | maximum tunnel saturation, narrowest test |
| `cuda-graphs-validate.sh` | #73 | CUDA Graphs perf measurement |

## Adding a workload

1. Copy an existing file as template:
   ```bash
   cp mode-b-stress.sh my-new-workload.sh
   ```

2. Edit the variables. Test by running:
   ```bash
   sudo ../perf-capture.sh --experiment test-my-workload --workload my-new-workload
   ```

3. Verify the metrics CSV has rows (regex matches). If empty, the workload
   command's output didn't match `METRICS_REGEX` — run the command standalone
   and inspect output to refine the regex.

## Heisenbug warning

Per memory `feedback_observability_perturbs_bug.md`: active workloads can
themselves perturb the failure modes we're hunting. The `mode-b-stress`
workload is GPU-active by design (we're trying to trigger Mode B). For
other workloads, prefer minimal-perturbation alternatives where possible.

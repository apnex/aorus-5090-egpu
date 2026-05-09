# Mode B stress workload — LIGHT variant.
#
# Single nvbandwidth H2D CE test with cooling delays between iterations.
# Designed for thermally-constrained hosts (NUC 15 Pro+) where the
# heavier 6-test mix in mode-b-stress.sh saturates multiple CPU cores.
#
# Coverage trade-off:
#   - DMA path (TB tunnel + Copy Engine + GSP firmware): ✓
#   - SM compute / CUDA kernel launch: ✗ (skipped to limit CPU)
#   - Bidirectional concurrency: ✗ (skipped)
#
# Justification: per memory feedback_lever_q_insufficient_for_dma, the
# 2026-05-05 Mode B silent freeze was DMA-path-specific. So exercising
# H2D CE alone covers the most relevant Mode B trigger surface.
#
# Use mode-b-stress.sh (full 6-test mix) when:
#   - Host has thermal headroom (desktop, server)
#   - You need SM/compute path coverage too
#
# Use mode-b-stress-light.sh (this) when:
#   - Host is thermally constrained (NUC, laptop, fanless)
#   - You only care about DMA-path Mode B
#   - You want longer test duration without thermal limits

WORKLOAD_NAME="mode-b-stress-light"
WORKLOAD_DESC="nvbandwidth H2D CE only with cooling delays; thermally-friendly Mode B trigger"

# Single H2D CE test per iteration
WORKLOAD_CMD='/usr/local/bin/nvbandwidth -t 0'

# Single test runs ~12s; defensive 30s cap
WORKLOAD_ITERATION_TIMEOUT=30

# Cooling delay between iterations — gives single-core busy time to dissipate
WORKLOAD_INTER_ITERATION_DELAY=10

# Default duration — 5 min wall-time. With ~22s cycle (12s active + 10s rest)
# yields ~13 iterations.
WORKLOAD_DURATION=300

# Match nvbandwidth's "SUM <test_name> <value>" output
METRICS_REGEX='^SUM[[:space:]]+([a-z_]+)[[:space:]]+([0-9.]+)$'

METRICS_UNIT="GB/s"

# Mode B stress workload — nvbandwidth bidirectional + CE/SM mix.
#
# Purpose: exercise the TB tunnel + GPU compute paths simultaneously to
# trigger any latent Mode B silent-freeze conditions while the patch 0023
# Mode B telemetry (S1 trigger-event AER capture, S2 [DIAG-AER2] sites,
# S3 qwatchdog persistent state) is active.
#
# Tests selected (see `nvbandwidth --list`):
#   0  host_to_device_memcpy_ce              — DMA H2D (Copy Engine)
#   1  device_to_host_memcpy_ce              — DMA D2H
#   2  host_to_device_bidirectional_memcpy_ce — concurrent CE stress
#   16 host_to_device_memcpy_sm              — CUDA kernel + H2D (compute path)
#   17 device_to_host_memcpy_sm              — CUDA kernel + D2H
#   18 host_to_device_bidirectional_memcpy_sm — concurrent SM stress
#
# Coverage: TB tunnel (all), Copy Engine (CE tests), CUDA kernel launch +
# SM compute (SM tests), GSP firmware (both), bidirectional concurrency
# (tests 2, 18 — most aggressive failure trigger).

WORKLOAD_NAME="mode-b-stress"
WORKLOAD_DESC="nvbandwidth bidirectional + CE/SM mix; targets Mode B DMA-path silent freeze under TB tunnel + compute pressure"

# Each iteration runs all 6 tests in sequence.
# nvbandwidth requires repeated `-t` flags rather than comma-separated list.
WORKLOAD_CMD='/usr/local/bin/nvbandwidth -t 0 -t 1 -t 2 -t 16 -t 17 -t 18'

# Each iteration of 6 tests typically takes ~60-90s. Cap at 120s defensive.
WORKLOAD_ITERATION_TIMEOUT=120

# Default duration — 7 minutes wall-time (well under 10-min safety cap).
WORKLOAD_DURATION=420

# Match nvbandwidth's "SUM <test_name> <value>" output line — captures
# both the test name and the bandwidth value.
METRICS_REGEX='^SUM[[:space:]]+([a-z_]+)[[:space:]]+([0-9.]+)$'

METRICS_UNIT="GB/s"

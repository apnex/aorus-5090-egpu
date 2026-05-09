# NVIDIA driver subsystem filter
# Captures NVRM messages, our [DIAG]/[DIAG-AER] telemetry, GSP events.

SUBSYSTEM_NAME="nvidia"
SUBSYSTEM_DESC="NVIDIA driver events (NVRM, RmInit, GSP, [DIAG], M-recover)"

FILTER_PATTERNS=(
    'NVRM:'
    'nvidia'
    '\[DIAG\]'
    '\[DIAG-AER\]'
    'AORUS Lever'
    'GSP_'
    'RmInit'
    'kgsp'
    'rmInit'
    'WPR2'
    'PMC_BOOT'
)

# UVM close-path lifecycle observability (Patch 0030).
#
# Fires when ANY UVM last-close transition happens (aorus_uvm_fd_count
# decrement to 0). Companion to close-path-lifecycle.sh which covers the
# /dev/nvidia0 side. Distinguish from uvm-close-path-wedge-cycle.sh
# which fires only on actual wedge / destabilisation evidence.
#
# Use this to confirm that a controlled experiment (e.g.
# tools/uvm-close-path-probe.sh) actually drove /dev/nvidia-uvm to zero
# fd count and the close path was exercised.
#
# Project ref: docs/architecture.md Problem 4 (UVM close-path bug class)
#              memory/project_close_path_mitigated_2026_05_08.md (UVM-side
#              still PENDING reclassification at time of patch landing)

HYPOTHESIS_ID="UVM-CLOSE-PATH-LIFECYCLE"
HYPOTHESIS_DESC="UVM last-close transition observed (Patch 0030 close-path instrumentation fired)"
HYPOTHESIS_REF="docs/architecture.md#problem-4-the-close-path-bug-also-affects-devnvidia-uvm"
HYPOTHESIS_SUBSYSTEM="nvidia"

SIGNATURES_FIRED=(
    'AORUS UVM \[CLOSE\]: site=uvm-release-exit fd_count=0 \(LAST-CLOSE\)'
    'AORUS UVM \[CLOSE\]: site=uvm-pre-destroy.*\(LAST-CLOSE\)'
    'AORUS UVM \[CLOSE\]: site=uvm-post-destroy.*\(LAST-CLOSE\)'
    'AORUS Lever M-recover \[UVM-DIAG\]:'
)

SIGNATURES_NEGATIVE=()

MIN_HITS_FIRED=1

# Close-path lifecycle observability (Patch 0029).
#
# Fires when ANY last-close transition happens (usage_count==1 → 0).
# This is the close-path counterpart to "rm_init_adapter ran" — pure
# observability that the close-path was exercised. Distinguish from
# the wedge-cycle hypothesis (close-path-wedge-cycle.sh) which fires
# only when the close path correlates with destabilisation.
#
# Use this hypothesis to confirm:
#   - Did a close event happen? (e.g., during a controlled "stop
#     persistenced + run nvidia-smi" experiment)
#   - Was it captured cleanly with full DIAG snapshot?
#
# A boot with persistenced+uvm-keepalive holding fds throughout will
# show 0 close-entry events at LAST-CLOSE — which is the desired
# steady-state production behaviour.

HYPOTHESIS_ID="CLOSE-PATH-LIFECYCLE"
HYPOTHESIS_DESC="Last-close transition observed (open->work->close->reopen instrumentation fired)"
HYPOTHESIS_REF="docs/architecture.md#problem-2-second-open-of-devnvidia0-hard-freezes-the-host"
HYPOTHESIS_SUBSYSTEM="nvidia"

# Any close-path DIAG site firing on the LAST-CLOSE path counts.
SIGNATURES_FIRED=(
    '\[CLOSE\]: site=close-entry.*\(LAST-CLOSE\)'
    '\[CLOSE\]: site=pre-stop.*\(LAST-CLOSE\)'
    '\[CLOSE\]: site=post-shutdown'
    '\[CLOSE\]: site=close-exit.*\(LAST-CLOSE\)'
    'AORUS Lever M-recover \[DIAG\]: site=close-entry'
    'AORUS Lever M-recover \[DIAG\]: site=pre-stop'
    'AORUS Lever M-recover \[DIAG\]: site=post-shutdown'
    'AORUS Lever M-recover \[DIAG\]: site=close-exit'
)

# Negative: the boot completed without any LAST-CLOSE transition,
# i.e. persistenced + uvm-keepalive held things open the whole time.
# (No specific log line — the absence of FIRED matches is the negative.)
SIGNATURES_NEGATIVE=()

MIN_HITS_FIRED=1

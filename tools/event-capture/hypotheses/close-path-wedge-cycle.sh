# Close-path wedge cycle: nvidia-smi or other userspace opens/closes
# /dev/nvidia0, GPU destabilises, link drops, M-recover re-inits.
#
# UPDATED 2026-05-08 (Patch 0029): now matches close-path DIAG sites
# (close-entry, pre-stop, post-shutdown, close-exit) — these fire on
# every last-close transition (usage_count==1 going to 0). Their
# presence indicates a real close-path event happened. Their
# pairing with M-recover firing or post-rmInit-FAIL events would
# indicate the close path triggered destabilisation.
#
# Project ref: feedback_avoid_nvidia_smi_for_state_checks (memory),
#              docs/architecture.md Problem 2 + Problem 4

HYPOTHESIS_ID="CLOSE-PATH-WEDGE"
HYPOTHESIS_DESC="Close-path wedge cycle (nvidia-smi or similar bouncing /dev/nvidia0)"
HYPOTHESIS_REF="memory/feedback_avoid_nvidia_smi_for_state_checks.md"
HYPOTHESIS_SUBSYSTEM="nvidia"

# A real close-path event fires the (LAST-CLOSE) marker and the
# post-shutdown DIAG site. The wedge cycle is identified by close-path
# events combined with M-recover firing or rm_init_adapter retries.
SIGNATURES_FIRED=(
    'site=post-rmInit-FAIL.*WPR2_up=YES'
    'osDevReadReg032.*dead-bus DETECTED'
    'aorus_lever_m_fires.*[1-9]'
    '\[CLOSE\]: site=post-shutdown'
    '\[CLOSE\]: site=close-entry.*\(LAST-CLOSE\)'
    'AORUS Lever M-recover \[DIAG\]: site=post-shutdown'
)

# A clean close-path event with no destabilisation is the "negative"
# case. post-rmInit-OK fires after the close path's next-open.
SIGNATURES_NEGATIVE=(
    'site=post-rmInit-OK'
)

# Multiple post-rmInit-FAIL events suggests cycling.
# A single close + clean reopen counts as 1 close-entry + 1 post-shutdown
# without an associated post-rmInit-FAIL.
MIN_HITS_FIRED=2

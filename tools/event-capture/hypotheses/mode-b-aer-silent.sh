# Mode B detected with empty/clean AER state.
#
# Q-watchdog detected dead bus (PMC_BOOT_0=0xffffffff), but the
# atomically captured AER snapshot at moment of detection shows AER
# subsystem silent — UESta/CESta zero across GPU/bridge/root, no DPC
# trigger. This is the failure mode that motivated Mode B telemetry
# patch 0023: the bus dies but AER doesn't fire.
#
# Empirically observed pattern in B1/B4 dossiers (Port A failures):
#   - GSP_LOCKDOWN cascade fires
#   - rm_init_adapter fails
#   - GPU disappears from MMIO (PMC_BOOT_0=0)
#   - But aer_dev_correctable counters all 0, kernel pcieport AER silent
#
# Project ref: project_port_a_failure_invisible_to_aer_2026_05_08.md,
# patch 0023 design doc docs/mode-b-telemetry-patch-design.md.

HYPOTHESIS_ID="MODE-B-AER-SILENT"
HYPOTHESIS_DESC="Mode B detected (qwatchdog or error_handler) but AER state empty — TB-tunneled silent failure"
HYPOTHESIS_REF="docs/mode-b-telemetry-patch-design.md"
HYPOTHESIS_SUBSYSTEM="nvidia"

# FIRED: trigger-event marker present (S1 dump fired) AND the AER state
# values in the same line/block are all zero/empty. Patch 0023's S1 dump
# format is multi-line; this matches the trigger header line plus a
# follow-up "all zero" pattern.
SIGNATURES_FIRED=(
    'AORUS Mode-B Trigger \[event=qwatchdog-detect\]'
    'AORUS Mode-B Trigger \[event=error-handler\]'
    # AER all-zero pattern — UESta and CESta both 0x00000000 on GPU side
    # at moment of trigger. Match against the GPU line specifically.
    'AORUS Mode-B Trigger.*GPU\(.*UESta=0x00000000 UEMsk=.*CESta=0x00000000'
)

# NOT-FIRED: trigger fired AND non-zero AER state captured (means AER did
# fire, just not surfaced as expected). Or no trigger fired at all
# (no Mode B this boot).
SIGNATURES_NEGATIVE=(
    'AORUS Mode-B Trigger.*GPU\(.*UESta=0x[0-9a-f]*[1-9a-f]'
    'pcieport.*AER:.*Corrected'
    'pcieport.*AER:.*Uncorrected'
)

MIN_HITS_FIRED=1

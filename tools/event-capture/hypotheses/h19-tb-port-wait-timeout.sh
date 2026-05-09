# H19: tb_wait_for_port() 1-second cap is too short on Meteor Lake-P
# cold-cold-boot with TB5/Barlow Ridge retimers.
#
# Source: docs/tb-driver-source-analysis.md § 3 H2/H5
# Code:   drivers/thunderbolt/switch.c:501  (Linux v6.19)
#         retries = 10; while (retries--) { ... msleep(100); }
#
# Failure mode: silent abort via out_rpm_put leaves AORUS half-configured.

HYPOTHESIS_ID="H19"
HYPOTHESIS_DESC="tb_wait_for_port 1s cap too short for cold-boot retimers"
HYPOTHESIS_REF="docs/reliability-hypothesis-ledger.md#h19"
HYPOTHESIS_SUBSYSTEM="thunderbolt"

SIGNATURES_FIRED=(
    'tb_wait_for_port.*timed out'
    'tb_wait_for_port.*max retries'
    'tb_scan_port.*out_rpm_put'
)

SIGNATURES_NEGATIVE=(
    'tb_scan_port.*[Pp]ort [0-9]+ now [Cc]onnected'
    'tb_switch_add: added router'
)

MIN_HITS_FIRED=1

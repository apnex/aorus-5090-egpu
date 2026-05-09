# H20: usb4_switch_configuration_valid() 50ms wait is too short for
# TB5 80G negotiation through Barlow Ridge.
#
# Source: docs/tb-driver-source-analysis.md § 3 H6
# Code:   drivers/thunderbolt/usb4.c:329 (Linux v6.19)
#         tb_switch_wait_for_bit(..., ROUTER_CS_6_CR, 50)

HYPOTHESIS_ID="H20"
HYPOTHESIS_DESC="usb4_switch_configuration_valid 50ms CR-bit wait too short"
HYPOTHESIS_REF="docs/reliability-hypothesis-ledger.md#h20"
HYPOTHESIS_SUBSYSTEM="thunderbolt"

SIGNATURES_FIRED=(
    'usb4_switch_configuration_valid.*[Ff]ail'
    'tb_switch_wait_for_bit.*ROUTER_CS_6'
    'tb_switch_wait_for_bit.*timeout'
    'configuration is not valid'
)

SIGNATURES_NEGATIVE=(
    'usb4_switch_configuration_valid: ok'
)

MIN_HITS_FIRED=1

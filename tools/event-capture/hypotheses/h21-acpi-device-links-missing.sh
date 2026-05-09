# H21: Missing tb_native_add_links() — non-Apple machines lack the
# ACPI device-link guarding that Apple CIO firmware machines have via
# tb_apple_add_links(), causing PM-ordering issues for downstream PCIe
# bridges on one NHI.
#
# Source: docs/tb-driver-source-analysis.md § 3 H1
# Code:   drivers/thunderbolt/acpi.c:91 (Linux v6.19), tb.c:3396 (warn)
# Smoking gun warning text:
#   "device links to tunneled native ports are missing!"

HYPOTHESIS_ID="H21"
HYPOTHESIS_DESC="Missing tb_native_add_links - ACPI device-link asymmetry per NHI"
HYPOTHESIS_REF="docs/reliability-hypothesis-ledger.md#h21"
HYPOTHESIS_SUBSYSTEM="thunderbolt"

SIGNATURES_FIRED=(
    'device links to tunneled native ports are missing'
    'tb_acpi_add_links.*[Nn]ot found'
)

SIGNATURES_NEGATIVE=(
    'tb_acpi_add_links: link added'
)

MIN_HITS_FIRED=1

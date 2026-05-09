# GSP_LOCKDOWN cascade: NVIDIA GSP firmware boot fails, returning
# function 4124 (GSP_LOCKDOWN_NOTICE) instead of expected 4097
# (GSP_INIT_DONE). Common on TB-tunneled Blackwell GPUs when downstream
# PCIe link rate doesn't match TB tunnel capacity.
#
# Project ref: H17, docs/iommu-gsp-lockdown-analysis.md

HYPOTHESIS_ID="GSP-LOCKDOWN"
HYPOTHESIS_DESC="NVIDIA GSP firmware boot returns LOCKDOWN_NOTICE (rate mismatch)"
HYPOTHESIS_REF="docs/iommu-gsp-lockdown-analysis.md"
HYPOTHESIS_SUBSYSTEM="nvidia"

SIGNATURES_FIRED=(
    'GSP_LOCKDOWN_NOTICE'
    'function 4124'
    '_kgspLogRpcSanityCheckFailure'
    'sanity check failed'
)

SIGNATURES_NEGATIVE=(
    'function 4097.*GSP_INIT_DONE'
    'site=post-rmInit-OK'
)

MIN_HITS_FIRED=3   # Cascade is many notices; require 3+ to declare FIRED

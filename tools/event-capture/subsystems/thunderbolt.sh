# Thunderbolt / USB4 subsystem filter
# Captures kernel + userspace events related to TB driver operation.

SUBSYSTEM_NAME="thunderbolt"
SUBSYSTEM_DESC="Linux thunderbolt/USB4 driver events (drivers/thunderbolt/)"

FILTER_PATTERNS=(
    'thunderbolt'
    'TBT[0-9]'
    'usb4_port'
    'tb_(scan|wait|switch|probe|route|domain|tunnel|pci|host|nhi|router)'
    '0000:00:0[d7]\.[0-9]'   # NHI + TB root ports BDFs (Meteor Lake-P)
    'nhi_'
    'icm_'
    'retimer'
    'bolt'
    'router'
    'tunnel'
    'CONNMGR'
    'XDomain'
)

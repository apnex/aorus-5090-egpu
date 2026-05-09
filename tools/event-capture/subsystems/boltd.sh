# Bolt daemon subsystem filter
# Captures TB authorization daemon (bolt) events and ACL operations.

SUBSYSTEM_NAME="boltd"
SUBSYSTEM_DESC="Bolt daemon events (TB device authorization, security policy)"

FILTER_PATTERNS=(
    'boltd'
    'bolt-'
    'thunderbolt.*authoriz'
    '/sys/bus/thunderbolt'
    'org\.freedesktop\.bolt'
)

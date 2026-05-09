# PCIe core + AER subsystem filter
# Captures generic PCIe events, AER reports, link state changes,
# bus enumeration.

SUBSYSTEM_NAME="pcie"
SUBSYSTEM_DESC="PCIe core, AER, bridges, link events"

FILTER_PATTERNS=(
    'pcieport'
    'PCIe'
    'AER:'
    'pci .*Speed'
    'pci .*PCI bridge'
    'pci .*bridge window'
    'PME#'
    'PTM'
    'pci [0-9a-f]+:[0-9a-f]+\.'
    'aer_'
    'pcie_'
    'Link.*[Ss]peed'
    'Correctable Error'
    'Uncorrectable Error'
)

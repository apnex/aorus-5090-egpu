# Subsystem filters

Each `*.sh` file in this directory defines a journal-line filter for a
specific kernel/userspace subsystem. The main `event-capture.sh` script
sources the file and applies the filter to capture per-subsystem log
streams.

## File format

```bash
SUBSYSTEM_NAME="<short-name>"           # required
SUBSYSTEM_DESC="<one-line description>" # required

FILTER_PATTERNS=(                       # required, array of egrep patterns
    'pattern1'                          # any line matching ANY pattern
    'pattern2'                          # is included in the filtered log
    ...
)
```

## How filtering works

Patterns are combined with OR (`|`) into a single egrep call applied to
the captured kernel + journal logs. Lines matching any pattern are
included in `<output>/20-filtered/<subsystem>.log`. Duplicates removed,
order preserved.

## Adding a new subsystem

1. Copy an existing file (e.g., `thunderbolt.sh`) to `<your-name>.sh`
2. Edit `SUBSYSTEM_NAME`, `SUBSYSTEM_DESC`, and `FILTER_PATTERNS`
3. Test: `./event-capture.sh --experiment test --subsystem <your-name>`
4. Verify the filtered log contains what you expect

## Current subsystems

- `thunderbolt.sh` — Linux thunderbolt/USB4 driver events
- `nvidia.sh` — NVIDIA driver events (NVRM, [DIAG], GSP, M-recover)
- `pcie.sh` — PCIe core, AER, link events
- `boltd.sh` — Bolt daemon (TB authorization)

Add more as new investigation areas open.

## Pattern tips

- Patterns are POSIX extended regex (`grep -E`)
- Escape special chars: `\.` `\(` etc.
- Use word boundaries where possible to reduce false positives
- Test patterns first with `journalctl -k -b 0 | grep -E '<pattern>'`
- Be inclusive (over-match is OK; under-match misses events)

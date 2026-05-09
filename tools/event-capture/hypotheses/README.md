# Hypothesis signatures

Each `*.sh` file in this directory defines a hypothesis that the event
capture tool can check against captured logs. Drop a new file in this
directory and the tool picks it up automatically.

## File format

```bash
HYPOTHESIS_ID="<unique-short-id>"           # required, e.g. "H19"
HYPOTHESIS_DESC="<one-line description>"    # required
HYPOTHESIS_REF="<path/to/doc>"              # optional, but encouraged
HYPOTHESIS_SUBSYSTEM="<subsystem-name>"     # required, must match subsystems/<name>.sh

# Patterns whose match indicates the hypothesis FIRED (any one match counts)
SIGNATURES_FIRED=(
    'regex1'
    'regex2'
)

# Patterns whose match indicates the hypothesis was RULED OUT (verdict NOT-FIRED)
SIGNATURES_NEGATIVE=(
    'positive-confirmation-regex'
)

# Minimum total hits across all FIRED signatures to declare FIRED (default 1)
MIN_HITS_FIRED=1
```

## Verdict logic

For each hypothesis, the tool counts hits across FIRED patterns and
NEGATIVE patterns in the relevant subsystem's filtered log:

- `fired_hits >= MIN_HITS_FIRED` → **FIRED**
- Otherwise, `neg_hits > 0` → **NOT-FIRED**
- Otherwise → **INCONCLUSIVE** (no evidence either way)

## Adding a new hypothesis

1. Copy an existing file (e.g., `h19-tb-port-wait-timeout.sh`) to
   `<your-id>.sh`
2. Edit all fields. Ensure `HYPOTHESIS_SUBSYSTEM` references an existing
   filter file under `../subsystems/`
3. Test patterns by running:
   ```bash
   journalctl -k -b 0 | grep -E '<your-fired-pattern>'
   ```
4. Run the tool:
   ```bash
   ./event-capture.sh --experiment hypothesis-test --hypothesis <your-id>
   ```
5. Inspect `<output>/30-hypotheses/<your-id>-evidence.txt` to verify the
   hypothesis fires/doesn't fire as expected on a known scenario

## Pattern tips

- Use POSIX extended regex (egrep)
- Escape `\.` `\(` `\)` `\[` `\]` etc.
- Test on real journal data before committing
- Prefer specific patterns over generic ones (avoid false positives)
- Include the function name when possible — easier to grep across kernel versions

## Current hypotheses

| ID | Description | Doc reference |
|---|---|---|
| `H19` | tb_wait_for_port 1s cap too short | `reliability-hypothesis-ledger.md#h19` |
| `H20` | usb4_switch_configuration_valid 50ms wait too short | `reliability-hypothesis-ledger.md#h20` |
| `H21` | Missing tb_native_add_links — ACPI device-link asymmetry | `reliability-hypothesis-ledger.md#h21` |
| `GSP-LOCKDOWN` | GSP firmware returns LOCKDOWN_NOTICE | `iommu-gsp-lockdown-analysis.md` |
| `CLOSE-PATH-WEDGE` | nvidia-smi or similar bouncing /dev/nvidia0 | `feedback_avoid_nvidia_smi_for_state_checks` |

Add more as new investigation patterns emerge. Each becomes part of the
project's permanent diagnostic surface.

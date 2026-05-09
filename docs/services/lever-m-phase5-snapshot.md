# Service: aorus-egpu-lever-m-phase5-snapshot.service

**Status:** **RETIRED 2026-05-09** — primary purpose (gather n=10 Phase 5
evidence for `wpr2-recovery` retirement) objectively complete on the same day.
Service preserved on disk as documented archive; resurrect via `systemctl enable
--now` for any future Phase-5-style cycle.
**Layer:** L4 (helper at `usr/local/sbin/aorus-egpu-lever-m-phase5-snapshot`) +
L5 (systemd unit) — both PRESERVED in repo + on disk.
**Lifecycle:** 2026-05-08 → 2026-05-09 (~24 hours; mission-complete retirement).

## Purpose (historical)

Captured Lever M-recover state once per boot to a per-boot evidence file.
The accumulating evidence drove the **Phase 5 retirement gate** for
`aorus-egpu-wpr2-recovery.service` — n≥10 boots with `M-RECOVER-NOT-FIRED`
verdict plus matching `no-op,GPU healthy` L4 record gated the L4 helper's formal
retirement.
Mission complete:
gate met 2026-05-09; wpr2-recovery retired the same day; this snapshot service
retired immediately after with no remaining evidence-collection target.

## Resurrection (for future Phase-5-style retirement cycles)

```bash
sudo systemctl enable --now aorus-egpu-lever-m-phase5-snapshot.service
```

When to resurrect:
any future retirement that needs per-boot empirical proof of in-driver recovery
behaviour.
Examples already on the horizon:
retiring `aorus-egpu-observability-watchdog` (needs n=5 cold-cold-boots without
Mode B incidents that the in-driver Q-watchdog missed); validating a future
M-preserve patch; any new lever requiring boot-time empirical proof.

See
[`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md#aorus-egpu-lever-m-phase5-snapshotservice--retired-2026-05-09)
for the full retirement record.

## Mechanism

`Type=oneshot RemainAfterExit=yes`, runs `aorus-egpu-lever-m-phase5-snapshot`
once after boot has stabilised.
Script:

1. Compute boot-tag from `/proc/stat` btime (kernel's authoritative boot epoch —
   constant for the boot lifetime, makes script idempotent across re-runs within
   the same boot)
2. If `archive/phase5-evidence/<boot-tag>.log` already exists, exit 0
   (idempotent)
3. Capture:
   - Module identity (`modinfo nvidia` version + srcversion)
   - Kill-switch state (`/var/lib/aorus-egpu/lever-m-killswitch` + runtime
     sysfs)
   - M-recover counters (`fires`, `successes`, `surrenders`, `last_fire_jf`)
   - `post-rmInit-OK` and `post-rmInit-FAIL` counts from dmesg
   - Close-path event counts (Patch 0029):
     `close-entry`, `pre-stop`, `post-shutdown`, `close-exit`, LAST-CLOSE
     events, `mmio_enabled` and `cor_error_detected` callback fires
   - Filtered M-recover dmesg events (`scheduling recovery`, `RECOVERED`,
     `READY`, `PERMANENT_FAIL`, `rate-limited`, `surrender`, kill-switch engage,
     post-rmInit-OK observed)
   - L4 helper events for this boot (filtered from
     `/var/lib/aorus-egpu/wpr2-recoveries.log` to ISO-timestamped CSV rows ≥
     boot-iso)
   - GPU functional check (`nvidia-smi -L`)
4. Write `## Verdict` line categorising the boot:
   - `M-RECOVER-NOT-FIRED` — clean boot
   - `M-RECOVER-FIRED-OK` — recovery happened cleanly
   - `M-RECOVER-FIRED-AND-SURRENDERED` — recovery hit MaxAttempts gate
   - `M-RECOVER-FIRED-INFLIGHT` — snapshot ran mid-recovery (rare)

Quick survey across all collected snapshots:
```bash
grep -h '^## Verdict' -A1 /root/aorus-5090-egpu/archive/phase5-evidence/*.log
```

## Why we need it today

Phase 5 gate for L4 helper retirement requires accumulated empirical evidence
over n≥10 cold-cold-boots.
Without per-boot snapshots, we'd be reading dmesg manually each boot and
trusting memory — error-prone.
The snapshot service writes structured, parseable, durable evidence per boot.

The snapshots are also useful diagnostically:
any boot that produced unexpected M-recover behaviour leaves a snapshot that can
be inspected post-mortem.

## Configuration and tuning

### Knobs (env vars in helper script)

| Variable | Default | Meaning |
|---|---|---|
| `REPO_ROOT` | `/root/aorus-5090-egpu` | Where evidence files are written (under `archive/phase5-evidence/`) |
| `EVIDENCE_DIR` | `$REPO_ROOT/archive/phase5-evidence` | Override the output directory |
| `GPU_BDF` | `0000:04:00.0` | GPU BDF for sysfs reads |

### Idempotency

Boot-tag derived from `/proc/stat` btime.
Re-running within the same boot reads the existing file's path; if present,
exits 0 without writing.
So `systemctl restart` doesn't clobber a previous capture; deliberate
re-collection requires `rm` on the existing file.

### Output format

Plain text with `## ...` section headers (markdown-friendly but consumed by
`grep`).
Sections are stable across versions; new sections appended at the end.
Verdict line is always last and matches the regex
`^M-RECOVER-(NOT-FIRED|FIRED-OK|FIRED-AND-SURRENDERED|FIRED-INFLIGHT):`.

## Dependencies

**After (ordering):**

- `aorus-egpu-wpr2-recovery.service` — capture L4's outcome
- `nvidia-persistenced.service` — capture state after the first open
- `aorus-egpu-compute-load-nvidia.service` — capture state after bind

**ConditionPathExists:**

- `/sys/bus/pci/devices/0000:04:00.0` — skip if eGPU not connected

## Lifecycle (boot / runtime / shutdown)

| Phase | Action |
|---|---|
| Boot | Runs once at multi-user.target after upstream services settle |
| Runtime | `Type=oneshot RemainAfterExit=yes` — stays "active (exited)" |
| Restart | Idempotent; existing snapshot preserved |
| Shutdown | No action |

`TimeoutStartSec=30` — best-effort observability; never block boot.

## Verification

```bash
systemctl is-active aorus-egpu-lever-m-phase5-snapshot
# active (exited)

ls /root/aorus-5090-egpu/archive/phase5-evidence/
# one file per boot, named <boot-iso>.log

# Latest snapshot
cat $(ls -1t /root/aorus-5090-egpu/archive/phase5-evidence/*.log | head -1)

# Verdict tally across all boots
grep -h '^## Verdict' -A1 /root/aorus-5090-egpu/archive/phase5-evidence/*.log
```

## Architectural destination

This service is a **transitional evidence-collection mechanism**.
Once `aorus-egpu-wpr2-recovery.service` is formally retired (Phase 5 gate met),
the snapshot service has served its purpose.
It can either:

- Be retained as ongoing diagnostic capture (per-boot health check)
- Or retired alongside the L4 helper

The bias is to **retain** — it's cheap (one file per boot, ~1 KB), provides
ongoing observability, and re-purposes naturally if any future regression
appears.

## Retirement criteria

If retired post-Phase-5:

1. `aorus-egpu-wpr2-recovery.service` formally retired
2. `archive/phase5-evidence/` accumulated n≥10 confirmation
3. Decision to stop ongoing diagnostic capture (not the default — bias is to
   retain)

## Retirement procedure

1. `systemctl disable --now aorus-egpu-lever-m-phase5-snapshot.service`
2. Optionally archive `archive/phase5-evidence/` to long-term storage
3. Update this doc's status header

## Resurrection procedure

`systemctl enable --now aorus-egpu-lever-m-phase5-snapshot.service`.
Reboot.
Snapshots resume.

## Files installed / consumed

**Installed by `apply.sh`:**

- `/etc/systemd/system/aorus-egpu-lever-m-phase5-snapshot.service`
- `/usr/local/sbin/aorus-egpu-lever-m-phase5-snapshot`

**Writes:**

- `/root/aorus-5090-egpu/archive/phase5-evidence/<boot-iso>.log` (one per boot)

**Reads:**

- `/proc/stat` (btime)
- `/sys/module/nvidia/parameters/NVreg_TbEgpuLeverM*`
- `/sys/bus/pci/devices/0000:04:00.0/tb_egpu_lever_m_*`
- `/var/lib/aorus-egpu/lever-m-killswitch`
- `/var/lib/aorus-egpu/wpr2-recoveries.log`
- `dmesg` output

## Cross-references

- Phase 5 gate definition:
  [`docs/service-retirement-roadmap.md`](../service-retirement-roadmap.md)
  `aorus-egpu-wpr2-recovery` row
- L4 helper this snapshot tracks:
  [`wpr2-recovery.md`](./wpr2-recovery.md)
- M-recover instrumentation captured:
  [`docs/lever-catalog.md`](../lever-catalog.md) Lever M-recover entry

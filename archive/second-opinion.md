# Second-Opinion Notes On The NVML Freeze

Date: 2026-05-01
Reviewer: separate read-only agent
Source reviewed: `aorus-5090-recovery-plan.md` through the `NVML Ioctl Trace Narrowed The Boundary` section.

These notes are commentary only. No system changes were made.

## Agreement With The Current Plan

- The `NV_ESC_WAIT_OPEN_COMPLETE` (`request=0xc00846da`) finding is the sharpest signal in the whole investigation. It localises the freeze to NVIDIA's deferred / nonblocking open completion path on `/dev/nvidia0`, not to NVML telemetry, not to `nvidia_uvm`, not to `nvidia_drm`, and not to BAR1 sizing.
- `NVreg_EnableNonblockingOpen=0` is a well-targeted next experiment. It directly forces the work that is currently being awaited via `NV_ESC_WAIT_OPEN_COMPLETE` back into the foreground `open()` path. Even if it does not fix the freeze, it should move the hang into `open()` itself, which is a sharper boundary than the current one.

## Possibly Under-Weighted Signal

The single most diagnostic detail in the trace is not just *which* ioctl hangs, but *when* it hangs:

- First `nvmlInit_v2` + `nvmlShutdown` in a freshly loaded driver session: succeeded, with the first `/dev/nvidia0` ioctl returning in ~1.13 s.
- Second `nvmlInit_v2` in the **same driver session** (modules still loaded): hard-froze on the very first `/dev/nvidia0` ioctl, the same `NV_ESC_WAIT_OPEN_COMPLETE`.

That pattern - succeed once, freeze on the second open in the same module-loaded session - is more consistent with a teardown / reinitialisation ordering issue than with a pure first-open initialisation bug. Plausible mechanisms worth keeping in mind:

- A leaked or not-yet-released RM client / GSP RPC channel from the first NVML session, where the second `open()` is waiting for completion of state that the first `nvmlShutdown` did not fully tear down on this Blackwell+TB stack.
- A device file that the kernel side believes is still in a partially-initialised state because the previous nonblocking open completion event was not consumed in the order NVIDIA expects.
- A GSP-side state machine (mandatory on Blackwell per the installed README) that does not survive a userspace close+reopen cleanly when accessed through a Thunderbolt tunnel.

The `NVreg_EnableNonblockingOpen=0` test as written does not distinguish "first open is broken" from "second open in the same session is broken". If it is rerun unchanged, it could either confirm or miss this distinction depending on whether the same probe binary opens NVML twice or only once.

## Suggested Refinement Before The Next Risky Test

If another freeze-risk test is acceptable, consider running the `NVreg_EnableNonblockingOpen=0` probe in two clearly labelled variants, captured via the existing fsynced ioctl tracer:

1. **Single-shot variant.** Load `nvidia` only, run one `nvmlInit_v2` + `nvmlShutdown`, exit. Do not call NVML again in the same driver session. If this succeeds, the foreground-open path works at least once.
2. **Repeat-in-session variant.** Same driver load, same process or a second process, but call `nvmlInit_v2` a second time without unloading the module between calls. This is the case that previously froze on the existing `EnableNonblockingOpen` default. If it still freezes here, the bug is in close/reopen, not in nonblocking deferral itself.

A useful extra control, before reaching for more module parameters, is whether unloading and reloading the modules between NVML cycles avoids the freeze:

```text
modprobe -r nvidia_uvm
modprobe -r nvidia
modprobe --ignore-install nvidia
# then re-run nvmlInit_v2 from a fresh process
```

If freshly reloading the modules between NVML sessions consistently lets `nvmlInit_v2` succeed, that is strong evidence that the failure is per-session state rather than a static initialisation problem, and should change which NVIDIA module parameters are worth trying next (likely client / RM / GSP teardown related rather than open-path related).

## Risk Notes

- Any further NVML-touching test should keep the existing safety latch (`/etc/aorus-5090-allow-compute-load`), `nvidia_drm` block, `i915` DRM ownership, the `aorus_5090_manual` driver override, and the requirement that BAR1 be 32 GiB before binding. None of those should be relaxed for diagnostic convenience.
- Hard freezes during NVML have so far prevented kernel logs from flushing. The fsynced ioctl tracer is currently the only reliable progress signal. Keep using it; do not rely on `journalctl` to bracket the failure.
- `nvidia-smi` should remain off the table as a probe until at least one minimal NVML init/shutdown cycle is reproducible on demand.

## Out Of Scope For This Note

- No changes to driver packaging, kernel parameters, services, udev rules, or scripts were made.
- The CUDA-only working state and the `thunderbolt.host_reset=false` BAR1 fix are accepted as established and are not re-litigated here.

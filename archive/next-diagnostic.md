# AORUS RTX 5090 eGPU Next Diagnostic

Goal: identify why the early-boot correct 32 GiB BAR1 layout is lost during Thunderbolt userspace authorization/hotplug reconfiguration, before loading NVIDIA or calling NVML.

Current known-safe policy:

- Keep `/etc/aorus-5090-allow-compute-load` absent by default.
- Keep all `nvidia*` modules unloaded until a deliberate test.
- Keep `nvidia_drm` blocked; GNOME/display should remain on internal Intel/Arc `i915`.
- Do not run `nvidia-smi`, NVML, `pynvml`, or framework telemetry that uses NVML until the bridge/BAR layout is improved.

Prepared boot-arg experiment:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 thunderbolt.host_reset=false
```

This is already applied to the default boot entry and `/etc/kernel/cmdline`, but it only takes effect after reboot.

A boot-time layout collector is enabled and gated by `/etc/aorus-5090-collect-pci-layout`. It records post-boot data to `/root/aorus-5090-pci-layout/latest.txt` without loading NVIDIA or touching NVML.

## Current Result

The host-reset-disabled cold boot fixed the final authorized PCI layout.

Active boot args:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 thunderbolt.host_reset=false
```

Runtime confirmation:

```text
/sys/module/thunderbolt/parameters/host_reset = N
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-48140fffff [size=33089M]
RTX 5090 BAR1: current size: 32GB
```

Do not remove `thunderbolt.host_reset=false`; it is currently the key fix preserving the 32 GiB BAR1 layout.

## 1. Completed Driver/CUDA Boundary

Base NVIDIA bind and CUDA smoke both succeeded with the 32 GiB BAR1 layout.

Observed state after base bind:

```text
nvidia: loaded
nvidia_uvm: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
BAR1: 0x0000004000000000-0x00000047ffffffff
DRM remains i915 only
```

CUDA smoke result:

```text
cuda smoke gnome test complete
bind_rc=0
uvm_rc=0
smoke_rc=0
cuda_smoke=pass
```

## 2. Resolved: Persistence Mode Bypasses The Reopen Wedge

The `nvidia-persistenced` daemon, run after `aorus-5090-compute-load-nvidia` binds the GPU, holds `/dev/nvidiactl` and four fds on `/dev/nvidia0` for its lifetime. While the daemon is alive, no `nvidia-smi` invocation is ever a "first open after last close", so the close-side teardown that wedges subsequent opens never runs.

Validated on 2026-05-01:

- 5 rapid `nvidia-smi` invocations + 60s idle + 1 `nvidia-smi` + 3 rapid `nvidia-smi --query-gpu=...` invocations. Total 9, all rc=0, no freeze.
- GPU temperature dropped from 50C to 45C across the test window. Fan stayed at 30% under driver control. This is the first confirmed driver-managed thermal behaviour on this stack and matches the AORUS AIB's water-cooling/fan dependence on the NVIDIA driver.
- Module refcount remained at 5 (1 ctl + 4 nvidia0) throughout. No new `Xid`, AER, or hung-task entries in the kernel log.
- `power_state` stayed `D0`; the existing `d3cold_allowed=0` udev policy correctly prevents runtime D3cold while persistence is held.

User-visible target met: `nvidia-smi` runs as many times as wanted, with proprietary userspace 580.142, on the Blackwell-mandatory open kernel module.

Operational caveat: the close-path bug that originally caused the wedge is still present. Persistence mode masks it by never letting the fd count drop. Do not stop `nvidia-persistenced` while `nvidia` is loaded; the next user-process query after persistenced exits will hit the freeze again.

## 3. Pending: Reboot-Persistence Configuration

To make the working state survive reboots:

1. Add a systemd drop-in `/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` with:

```ini
[Unit]
After=aorus-5090-compute-load-nvidia.service
Requires=aorus-5090-compute-load-nvidia.service
```

2. Decide the compute-load latch policy. Options:
   - Make `/etc/aorus-5090-allow-compute-load` a permanent file. Simplest, keeps the existing safety latch as an audit/diagnostic toggle.
   - Remove the latch check from `/usr/local/sbin/aorus-5090-compute-load-nvidia` and rely on the systemd unit's enable state. Cleaner but loses the manual override.
3. Enable both services so they start on boot:

```bash
sudo systemctl enable aorus-5090-compute-load-nvidia.service
sudo systemctl enable nvidia-persistenced.service
```

4. Cold-boot validation run:
   - Boot with the eGPU connected and powered.
   - At a user shell after login, run `nvidia-smi` several times and an idle-then-`nvidia-smi` pass.
   - Confirm `pgrep -x nvidia-persiste` reports the daemon is running, `lsmod | grep '^nvidia'` shows refcount > 0, fan is audibly running (or visible at 30% in `nvidia-smi`), and no `Xid`/AER entries in `journalctl -k -b`.

Risks during the boot validation:

- If `nvidia-persistenced` starts before `aorus-5090-compute-load-nvidia` finishes binding the GPU, persistenced may exit. The drop-in's `After=` and `Requires=` are meant to prevent this; `Requires=` will also fail-stop persistenced if compute-load fails.
- If anything else on the boot path (e.g. nvidia-fallback, gdm, an autostart program) tries to open `/dev/nvidia0` before persistenced has it open, the freeze could trigger before the system is fully up. The existing `nvidia_drm` block, the `aorus_5090_manual` driver_override, the nouveau/nova_core blacklist, and the masked `nvidia-fallback.service` all reduce this risk significantly. A failed boot would manifest as a hang during multi-user.target or display-manager start; hard reset is the recovery.
- A safer first reboot test would run with the latch removed but the services not yet enabled, so the user can manually start the chain after login. If that works, then enable the services and reboot once more.

Do not run additional NVML/freeze-risk diagnostics. The remaining work is configuration, not investigation.

The `NVreg_EnableNonblockingOpen=0` two-init test was run on 2026-05-01 after agent handover and produced a sharper boundary than the previous `NV_ESC_WAIT_OPEN_COMPLETE` finding.

Test outcome:

```text
nvml nonblockoff two-init test started
bind_rc=0
first_nvml_rc=0
stage=before_second_nvml_init
```

First NVML probe completed cleanly:

```text
2026-05-01 14:16:35 before nvmlInit_v2
2026-05-01 14:16:36 after nvmlInit_v2 rc=0
2026-05-01 14:16:36 before nvmlShutdown
2026-05-01 14:16:37 after nvmlShutdown rc=0
```

Ten-second sleep then started the second NVML probe. The ioctl trace ended at:

```text
open64_enter dirfd=-100 path=/dev/nvidia0 flags=0x80802 mode=00
```

There is no matching `open64_exit`. `flags=0x80802` is `O_RDWR | O_NONBLOCK | O_CLOEXEC`; libnvidia-ml uses `O_NONBLOCK` regardless of the module parameter. With `NVreg_EnableNonblockingOpen=0`, the driver foreground-initializes inside `open()` instead of completing via `NV_ESC_WAIT_OPEN_COMPLETE`. The freeze migrated from that ioctl into `open()` itself, exactly as the second-opinion note predicted.

New boundary:

- Freeze is not in NVIDIA's deferred-open scheduler.
- Freeze is not in any later NVML count/handle/telemetry call.
- Freeze occurs on the second open of `/dev/nvidia0` after a previous open+close in the same module-load session.

Module-reload between NVML cycles is also unsafe:

- The previous-boot kernel log shows the test's `modprobe -r nvidia ; modprobe nvidia` cycle ran successfully through unload and through the second NVRM module load message, then the kernel went silent.
- The second NVRM load line is the last entry before the freeze. The persistent kernel/device state that wedges the next open survives `nvidia.ko` removal, which points at GPU/GSP firmware state or an undocumented PCI structure rather than driver-internal caches.

Operational consequences:

- A single NVML cycle per freshly-loaded driver session is currently safe. `nvidia-smi` will succeed exactly once after a fresh `modprobe nvidia`.
- Any second process that opens `/dev/nvidia0` after the first NVML/CUDA process has closed it will hang the host.
- A long-lived NVML or CUDA process that holds `/dev/nvidia0` open for its entire lifetime avoids the close-reopen path and is the safest current usage pattern.

After the forced reboot, the safe baseline is intact:

```text
host_reset: N
BAR1: 0x0000004000000000-0x00000047ffffffff (32 GiB)
nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm: unloaded
GPU driver: none
DRM: i915 only
safety_latch: absent
driver_override: aorus_5090_manual on GPU, aorus_5090_disabled on HDMI audio
```

Test-script verification fix already applied:

- `/root/aorus-5090-run-nvml-nonblockoff-two-init-test` now greps the `aorus-5090-compute-load-nvidia` log for the "NVIDIA nonblocking open was disabled" line instead of grepping `/proc/driver/nvidia/params` for `EnableNonblockingOpen: 0`. The `/proc` interface only mirrors RM/registry parameters, and `/sys/module/nvidia/parameters/` does not exist on this driver build.

Do not rerun the nonblocking-open two-init test unchanged. It cleanly froze the host once, recorded the new boundary, and another identical run adds no information.

## Historical: Pre-Persistence-Mode Diagnostic Options

The options below were considered before `nvidia-persistenced` was tested. Persistence mode (effectively a productionised Option C, using NVIDIA's own daemon rather than a custom probe) made all of these unnecessary. Kept for reference only.

Option A (deferred): treat one NVML cycle per module load as a hard rule and accept the discipline. Concrete form would have been a custom long-lived NVML daemon. `nvidia-persistenced` fills the same role as a vendor-supported binary.

Option B (not run): bind with `NVreg_DynamicPowerManagement=0` and rerun the two-init test. Would have tested whether close-side runtime PM is the wedge trigger. Skip unless persistence-mode regression appears or vendor escalation needs the data.

Option C (effectively run as persistence-mode test): keep `/dev/nvidia0` open across NVML cycles. The validated persistence-mode result is the operational equivalent.

Option D (still useful): vendor escalation with the captured artifacts. Persistence mode masks the bug but does not fix it. A bug report against the open kernel module describing "host hangs in `open()` of `/dev/nvidia0` after a previous open+close on RTX 5090 over Thunderbolt 4" with the existing ioctl trace and previous-boot kernel log remains a good idea, because losing the daemon for any reason re-exposes the freeze. No further freeze risk needed to file.

Baseline commands before any future risky test:

```bash
cat /sys/module/thunderbolt/parameters/host_reset
sudo /usr/local/sbin/aorus-5090-status
```

Expected baseline: `host_reset = N`, BAR1 is 32 GiB, all `nvidia*` modules are unloaded, and `nvidia_drm` is absent.

## Historical Result

The cold-boot PCI resource experiment did not fix the final post-authorization layout.

Current final layout remains bad:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]
RTX 5090 BAR1: current size: 256MB
```

Boot logs show the early firmware/initial PCI enumeration did briefly have the desired layout:

```text
0000:03:00.0 bridge window: 0x4000000000-0x48140fffff
0000:04:00.0 BAR1: 0x4000000000-0x47ffffffff
```

Do not run `/root/aorus-5090-run-nvml-rebar-sweep-test` in the current final layout.

## 1. Latest Finding: Bolt Is Not The Root Cause

The bolt-masked cold boot showed:

- `bolt.service` was masked/inactive.
- No `boltd` process was running.
- The AORUS device existed in Thunderbolt sysfs but stayed unauthorized.
- The RTX 5090 was not present on PCI by the time userspace ran.

Manual sysfs authorization without `boltd` was then tested:

```bash
printf 1 > /sys/bus/thunderbolt/devices/0-1/authorized
```

That safely brought the RTX 5090 back to PCI, but the layout still collapsed to:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]
RTX 5090 BAR1: current size: 256MB
```

Interpretation: `boltd` is not the root cause. The bad layout is produced by the kernel Thunderbolt authorization/hotplug path itself, or by host-router reset/tunnel recreation.

`bolt.service` has been unmasked and is currently `static`/inactive.

## 2. Current Experiment: Thunderbolt Host Reset Disabled

Prepared for the next cold boot:

```text
thunderbolt.host_reset=false
```

Expected active command line after reboot:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 thunderbolt.host_reset=false
```

Goal: test whether preventing the USB4 host-router reset lets the firmware/early-boot 32 GiB BAR1 layout survive the Thunderbolt authorization path.

After cold boot, run before any NVIDIA/NVML test:

```bash
cat /proc/cmdline
cat /sys/module/thunderbolt/parameters/host_reset
sudo /usr/local/sbin/aorus-5090-status
grep -E 'authorized=|Prefetchable memory behind bridge|Region 1:|BAR 1: current size|resource1_resize|pci=realloc|resource_alignment|thunderbolt.host_reset' /root/aorus-5090-pci-layout/latest.txt
```

Success criterion:

```text
/sys/module/thunderbolt/parameters/host_reset = N
RTX 5090 present on PCI
0000:03:00.0 has a large prefetchable window
RTX 5090 BAR1 is 32 GiB, or at least larger than 256 MiB
```

Do not proceed to NVIDIA/NVML unless the final layout is improved.

## Historical Experiment: Bolt Masked

`bolt.service` was masked for one cold boot to test whether `boltd` userspace authorization was what destroyed the early 32 GiB BAR1 layout.

Important details:

- `bolt.service` was masked for the test, then unmasked afterward.
- `/etc/systemd/system/aorus-5090-collect-pci-layout.service` no longer has `Wants=bolt.service`.
- `/usr/local/sbin/aorus-5090-collect-pci-layout` no longer calls `boltctl`, because `boltctl` can D-Bus-activate `boltd`.
- The experiment required a cold boot to take effect.

After the cold boot, do not run `boltctl` before checking PCI layout.

Run:

```bash
systemctl is-active bolt.service || true
sudo /usr/local/sbin/aorus-5090-status
grep -E 'Prefetchable memory behind bridge|Region 1:|BAR 1: current size|pci=realloc|resource_alignment' /root/aorus-5090-pci-layout/latest.txt
```

Success criterion:

```text
bolt.service: inactive or failed because masked
0000:03:00.0 has a large prefetchable window
RTX 5090 BAR1 is 32 GiB, or at least larger than 256 MiB
```

If the 32 GiB layout persists with `bolt.service` masked, the durable fix is likely BIOS/pre-boot Thunderbolt authorization or avoiding post-boot userspace reauthorization for this device.

If the layout still collapses to 256 MiB with `bolt.service` masked, then `boltd` is not the main trigger and the next candidate is a kernel Thunderbolt parameter such as `thunderbolt.host_reset=false`.

After the experiment, restore normal bolt service availability unless a better permanent policy is chosen:

```bash
sudo systemctl unmask bolt.service
```

Do not proceed to NVIDIA/NVML until the final layout, after all Thunderbolt authorization behavior, shows a large enough `0000:03:00.0` prefetchable window and BAR1 above 256 MiB.

## Reference: Original Cold-Boot Checks

### Cold Boot With eGPU Connected

Use a full shutdown/cold boot with the AORUS box connected and powered before boot.

Do not create the compute-load latch during this boot.

### Confirm The New Kernel Args

Run:

```bash
cat /proc/cmdline
sudo /usr/local/sbin/aorus-5090-collect-pci-layout
```

Expected: command line includes:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0
```

### Confirm Safe NVIDIA State

Run:

```bash
sudo /usr/local/sbin/aorus-5090-status
```

Expected before any risky test:

- `safety_latch: absent`
- `nvidia`, `nvidia_uvm`, `nvidia_modeset`, and `nvidia_drm` unloaded
- RTX 5090 present but unbound
- `power_state: D0`
- `power_control: on`
- `d3cold_allowed: 0`
- DRM still only `i915`

### Check Bridge Window Distribution

First inspect the collector output:

```bash
grep -E 'Prefetchable memory behind bridge|Region 1:|BAR 1: current size|pci=realloc' /root/aorus-5090-pci-layout/latest.txt
```

If more context is needed, run:

```bash
lspci -vv -s 03:00.0
lspci -vv -s 03:01.0
lspci -vv -s 03:02.0
lspci -vv -s 03:03.0
lspci -vv -s 04:00.0
```

The key field is `Prefetchable memory behind bridge` for `0000:03:00.0`.

Current bad baseline was:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]
```

Success criterion: `0000:03:00.0` has a much larger prefetchable window, ideally 32 GiB or more. If it is still 288 MiB, do not run NVML.

### Retry ReBAR Sweep Only If The Window Improved

If `0000:03:00.0` has enough prefetchable window space and BAR1 is still not already enlarged, run the guarded ReBAR sweep:

```bash
sudo /root/aorus-5090-run-nvml-rebar-sweep-test
```

This script attempts BAR1 resize before NVIDIA/NVML and only proceeds if a resize above 256 MiB succeeds.

If the window did not improve, skip the script and collect the PCI layout instead.

### Collect Logs If Anything Freezes

After rebooting from any freeze, collect previous-boot logs:

```bash
journalctl -b -1 -k --no-pager -g 'NVRM|Xid|nvidia|nvidia_uvm|nvidia_drm|AER|PCIe Bus Error|DPC|thunderbolt|usb4|watchdog|lockup|hung|thermal|panic|BUG|Oops|fallen off|GPU has fallen|BAR0|BAR 0|BAR 1|resource_alignment|GSP|NVML'
journalctl -b -1 --no-pager -g 'aorus-5090|nvidia-smi|nvidia|NVRM|Xid|gnome-shell|gdm|mutter|wayland|Xwayland|watchdog|lockup|hung|thermal|panic|BUG|Oops|freeze|NVML'
```

## Revert

If the boot-arg experiment causes boot problems, revert from a working boot:

```bash
sudo grubby --update-kernel=DEFAULT --remove-args='pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0' --args='pci=realloc,pcie_bus_perf'
```

Also edit `/etc/kernel/cmdline` back to:

```text
root=UUID=34e34fc2-47b6-41bd-b739-8a1c79788cb2 ro rootflags=subvol=root rhgb quiet module_blacklist=nouveau,nova_core rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core pci=realloc,pcie_bus_perf
```

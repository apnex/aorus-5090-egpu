# AORUS RTX 5090 AI Box Recovery Plan

Date: 2026-04-29
System: Fedora 42
Connection: Thunderbolt 4 / USB4

## Current Findings

- Thunderbolt sees the enclosure as `GIGABYTE AORUS RTX5090 AI BOX`.
- `boltctl` reports the enclosure is `authorized`.
- Link speed is `40 Gb/s` RX and TX.
- PCI sees the GPU as `04:00.0 NVIDIA Corporation GB202 [GeForce RTX 5090]`.
- PCI sees the GPU audio function as `04:00.1 NVIDIA Corporation GB202 High Definition Audio Controller`.
- NVIDIA driver package is installed: `580.142`.
- Secure Boot is disabled.
- `nvidia-smi` fails because it cannot communicate with the NVIDIA driver.
- Kernel logs show the GPU failed during driver probe:
  - `Unable to change power state from D3cold to D0, device inaccessible`
  - `fallen off the bus and is not responding to commands`
- After the failed probe, `lspci -vv -s 04:00.0` reports `!!! Unknown header type 7f`, which suggests PCI config reads are failing.
- The GPU currently exposes `d3cold_allowed=1`.
- Current kernel command line already includes:
  - `rd.driver.blacklist=nouveau,nova_core`
  - `modprobe.blacklist=nouveau,nova_core`
  - `pcie_aspm=off`
  - `pci=pcie_bus_perf`
- `nouveau` still appeared loaded in `lsmod`, so initramfs/module cleanup may still be needed.

## Recommended Resolution Sequence

### 1. Fully Power-Cycle the eGPU

Do this first, because the GPU appears to have fallen off the PCIe bus after a failed D3cold wake.

1. Shut down Fedora completely.
2. Unplug the Thunderbolt cable from the AORUS box.
3. Remove power from the AORUS box for 30-60 seconds.
4. Reconnect power to the AORUS box.
5. Reconnect Thunderbolt.
6. Boot Fedora with the AORUS box already connected.
7. Test:

```bash
nvidia-smi
boltctl
lspci -nnk -s 04:00.0
```

### 2. Disable D3cold for the RTX 5090

If the issue persists, add a udev rule so the GPU is not allowed to enter D3cold.

Create `/etc/udev/rules.d/80-aorus-5090-egpu-power.rules` with:

```udev
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{device}=="0x2b85", TEST=="d3cold_allowed", ATTR{d3cold_allowed}="0"
```

Then reload rules and trigger, or reboot:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=pci
cat /sys/bus/pci/devices/0000:04:00.0/d3cold_allowed
```

Expected value:

```text
0
```

After adding the rule, do another full eGPU power-cycle and boot with the enclosure connected.

### 3. Add `pcie_port_pm=off`

Add the kernel parameter `pcie_port_pm=off` in addition to the existing `pcie_aspm=off pci=pcie_bus_perf`.

On Fedora with GRUB, use:

```bash
sudo grubby --update-kernel=ALL --args="pcie_port_pm=off"
```

Confirm after reboot:

```bash
cat /proc/cmdline
```

Expected command line should include:

```text
pcie_port_pm=off
```

Then test again:

```bash
nvidia-smi
journalctl -k -b --no-pager -g 'nvidia|NVRM|thunderbolt|usb4|D3cold|pcie'
```

### 4. Ensure Nouveau Is Fully Excluded

Nouveau was loaded despite blacklist parameters. If NVIDIA still fails, rebuild initramfs after confirming blacklist configuration.

Check blacklist files:

```bash
grep -R "nouveau\|nova_core" /etc/modprobe.d /usr/lib/modprobe.d
```

Rebuild initramfs for the current kernel:

```bash
sudo dracut --force
```

Reboot and confirm:

```bash
lsmod | grep -E 'nouveau|nova_core'
```

Expected: no output.

### 5. Consider NVIDIA Open Kernel Module

Only try this after the PCIe/D3cold reset path above, because the current failure appears to be a low-level PCI power-state issue.

RPM Fusion packages available:

- `akmod-nvidia-open`
- `kmod-nvidia-open`

Potential switch path:

```bash
sudo dnf swap akmod-nvidia akmod-nvidia-open
sudo akmods --force
sudo dracut --force
sudo reboot
```

After reboot:

```bash
nvidia-smi
modinfo nvidia | head
lspci -nnk -s 04:00.0
```

## Quick Verification Commands

## Changes Applied After Reboot

Applied on 2026-04-29:

- Added `/etc/udev/rules.d/80-aorus-5090-egpu-power.rules` to set `d3cold_allowed=0` for PCI vendor `0x10de`, device `0x2b85`.
- Added `/etc/modprobe.d/blacklist-nouveau.conf` to blacklist `nouveau` and `nova_core`.
- Added kernel arguments to all boot entries:
  - `pcie_port_pm=off`
  - `module_blacklist=nouveau,nova_core`
- Masked `nvidia-fallback.service` so it cannot explicitly load nouveau after an NVIDIA probe failure.
- Rebuilt initramfs with `dracut --force`.
- Confirmed the default boot entry now includes `pcie_port_pm=off module_blacklist=nouveau,nova_core`.
- Confirmed current runtime `d3cold_allowed` for `0000:04:00.0` is `0`.

Live reload was attempted after removing nouveau, but `modprobe nvidia` still failed with `No such device`. `lspci -vv -s 04:00.0` still showed `!!! Unknown header type 7f`, so the GPU/enclosure likely remains wedged until a full eGPU power-cycle and reboot.

Post-restart update:

- Nouveau stayed unloaded and the fallback service did not run.
- The D3cold rule applied: `/sys/bus/pci/devices/0000:04:00.0/d3cold_allowed` was `0`.
- NVIDIA still failed because PCI BAR0 was not assigned:
  - `NVRM: BAR0 is 0M @ 0x0 (PCI:0000:04:00.0)`
  - `pci 0000:04:00.0: BAR 0 [mem size 0x04000000]: failed to assign`
- The kernel explicitly reported: `Some PCI device resources are unassigned, try booting with pci=realloc`.
- Added `pci=realloc,pcie_bus_perf` to all kernel entries, replacing the previous `pci=pcie_bus_perf` argument.

Second post-restart update:

- `pci=realloc,pcie_bus_perf` fixed the BAR allocation issue. BAR0 is now assigned at `0x80000000-0x83ffffff`.
- NVIDIA still fails because the GPU cannot be brought from `D3cold` to `D0`:
  - `Unable to change power state from D3cold to D0, device inaccessible`
  - `fallen off the bus and is not responding to commands`
- Expanded `/etc/udev/rules.d/79-aorus-5090-egpu-power.rules` to keep the Thunderbolt root ports, JHL9480 bridge ports, RTX 5090 GPU function, and RTX 5090 audio function out of D3cold and forced to `power/control=on`.
- Added `/etc/modprobe.d/aorus-5090-egpu-audio.conf`:

```text
options snd_hda_intel enable=1,0 power_save=0 power_save_controller=N
```

This is intended to keep internal audio enabled while preventing the eGPU HDMI-audio function from probing before the NVIDIA display driver wakes the GPU.

- Rebuilt initramfs again with `dracut --force`.
- A live function reset was attempted, but the GPU did not recover:
  - `pci 0000:04:00.0: not ready 65535ms after FLR; giving up`
  - The kernel emitted PCI/SR-IOV/Resizable-BAR UBSAN warnings during reset state restore.
- Avoid further live PCI resets for this boot. Use a full shutdown and AORUS box power-cycle for the next test.

Cold-boot update:

- BAR allocation remains fixed with `pci=realloc,pcie_bus_perf`.
- The eGPU HDMI-audio workaround is active: `snd_hda_intel` probe for `0000:04:00.1` failed with `error -2` rather than binding.
- D3cold is disabled after boot for the Thunderbolt/eGPU path.
- NVIDIA still auto-probed during udev coldplug before the system was fully settled and wedged the GPU again.
- Added `/etc/modprobe.d/aorus-5090-egpu-delayed-nvidia.conf` to prevent automatic PCI modalias probing of:
  - `nvidia`
  - `nvidia_drm`
  - `nvidia_modeset`
  - `nvidia_uvm`
- Added `/usr/local/sbin/aorus-5090-egpu-load-nvidia` to apply eGPU power policy and then explicitly run `modprobe nvidia`.
- Added and enabled `/etc/systemd/system/aorus-5090-egpu-nvidia.service` to run the loader after `bolt.service` and `systemd-udev-settle.service`.
- Disabled `nvidia-powerd.service` to avoid extra early NVIDIA probing/noise while debugging.
- Rebuilt initramfs again with `dracut --force`.
- Verified explicit `modprobe nvidia` still resolves to the installed NVIDIA module despite the alias blacklist.

Delayed-service test update:

- The custom service prevented earlier NVIDIA modalias probing; the first NVIDIA probe came from `aorus-5090-egpu-nvidia.service`.
- The service still ran before `boltd` finished its probing timeout:
  - service started around kernel monotonic `5.76s`
  - NVIDIA probe occurred around `8.04s`
  - `boltd` probing timeout completed around `8.76s`
- Sysfs showed the GPU function was already in `D3cold` after the failed probe:
  - `/sys/bus/pci/devices/0000:04:00.0/power_state` was `D3cold`
  - `/sys/bus/pci/devices/0000:04:00.1/power_state` was `D0`
- Updated `/usr/local/sbin/aorus-5090-egpu-load-nvidia` to:
  - wait an extra 8 seconds after finding the eGPU
  - log the GPU `power_state` before probing
  - wait up to 30 seconds for the GPU to leave `D3cold`
  - skip `modprobe nvidia` if the GPU remains in `D3cold`, avoiding another PCI wedge
- Rebuilt initramfs again with `dracut --force`.

Next test should be another full shutdown and AORUS power-cycle. On the next boot, NVIDIA should not probe during udev coldplug; the custom service should be the first NVIDIA load attempt after the eGPU path has been forced to stay powered.

NVIDIA open-module update:

- The delayed service saw the GPU as `D0` immediately before probing NVIDIA, but the proprietary module still failed and left the GPU in `D3cold` with `Unknown header type 7f`.
- Installed RPM Fusion's open NVIDIA kernel module package: `akmod-nvidia-open`.
- The normal RPM Fusion NVIDIA user-space stack depends on the proprietary `nvidia-kmod` provider, so both proprietary and open kmod packages are currently installed.
- Added `/etc/depmod.d/aorus-5090-nvidia-open.conf` so `modprobe nvidia` prefers `/lib/modules/.../extra/nvidia-open/` over `/lib/modules/.../extra/nvidia/`.
- Verified `modprobe -n -v nvidia` now selects:

```text
/lib/modules/6.19.14-100.fc42.x86_64/extra/nvidia-open/nvidia.ko
```

- Rebuilt initramfs again with `dracut --force`.
- Disabled `nvidia-powerd.service` again after RPM package scripts re-enabled it.
- Next cold boot will test the open NVIDIA kernel module path while keeping the existing delayed-load/power-policy service.

Open-module cold-boot result:

- `modprobe nvidia` selected the open module path, but the probe still failed.
- The custom service saw the GPU as `D0` immediately before probing.
- NVIDIA still reported `Unable to change power state from D3cold to D0` and left PCI config reads in `Unknown header type 7f` state.
- Thunderbolt had fully settled before the probe, so simple timing is no longer the likely cause.
- Updated `/usr/local/sbin/aorus-5090-egpu-load-nvidia` to remove and rescan the eGPU PCI functions after Thunderbolt authorization, then apply power policy and load NVIDIA. This tests whether the early boot PCI device instance is stale because it was enumerated before `boltd` completed authorization.
- Rebuilt initramfs again with `dracut --force`.

Bridge-decode / IOMMU test update:

- After remove/rescan, the GPU config space stayed readable and `power_state` stayed `D0`, but NVIDIA still failed with `fallen off the bus`.
- Found the Thunderbolt switch bridges in the eGPU path had PCI command decode disabled:
  - `0000:02:00.0 COMMAND=0000` (`I/O- Mem- BusMaster-`)
  - `0000:03:00.0 COMMAND=0000` (`I/O- Mem- BusMaster-`)
  - `0000:04:00.0 COMMAND=0003` (`I/O+ Mem+ BusMaster-`)
- A live `setpci` test set those to `COMMAND=0007`; `lspci` then showed `I/O+ Mem+ BusMaster+` on the bridges and GPU.
- Even with bridge decode enabled live, both `nvidia-open` and the proprietary module still failed in the already-failed boot with `fallen off the bus`.
- Added an `enable_pci_decode_path` step to `/usr/local/sbin/aorus-5090-egpu-load-nvidia` so the delayed loader now forces decode on the GPU's PCI ancestor path before NVIDIA probes.
- Added the reversible boot argument `iommu=pt` to test whether the Intel IOMMU translated default domain is part of the Thunderbolt/eGPU failure path.

Cold-boot result with PCI decode + `iommu=pt`:

- Thunderbolt authorization succeeded and `iommu=pt` was active.
- The delayed loader enabled command decode before probing NVIDIA:
  - `0000:02:00.0: 0000 -> 0007`
  - `0000:03:00.0: 0000 -> 0007`
  - `0000:04:00.0: 0000 -> 0007`
- NVIDIA still failed with `fallen off the bus`, but the GPU remained readable afterward in `D0`; this is an improvement over the earlier `Unknown header type 7f` state.
- The service's remove/rescan path caused the eGPU HDMI-audio function to probe again and changed the GPU BAR layout from the initial firmware/kernel enumeration. The initial enumeration had BAR1 assigned as a 32 GiB resizable BAR, while the rescan path left BAR1 at 256 MiB.
- GNOME auto-started `nvidia-settings -l`, which caused extra NVIDIA probe attempts after the service failed.
- Updated `/usr/local/sbin/aorus-5090-egpu-load-nvidia` again to keep the initial PCI enumeration instead of removing/rescanning the eGPU.
- Expanded `/etc/modprobe.d/aorus-5090-egpu-audio.conf` to disable additional `snd_hda_intel` instances:

```text
options snd_hda_intel enable=1,0,0,0,0,0,0,0 power_save=0 power_save_controller=N
```

- Disabled `/etc/xdg/autostart/nvidia-settings-user.desktop` so `nvidia-settings` does not trigger extra probes during login.
- Rebuilt initramfs with `dracut --force`.

Cold-boot result after keeping initial enumeration:

- The initial firmware/kernel enumeration was preserved and eGPU HDMI-audio stayed unbound.
- The loader still waited 8 seconds before applying the power policy. By the time NVIDIA probed, the GPU/tunnel had already entered D3cold:

```text
nvidia 0000:04:00.0: Unable to change power state from D3cold to D0, device inaccessible
```

- After the failed probe, the downstream Thunderbolt bridge showed `Unknown header type 7f`, and `setpci` returned `ffff` for the downstream bridge/GPU.
- Updated `/usr/local/sbin/aorus-5090-egpu-load-nvidia` to:
  - apply D3cold and runtime-PM policy immediately when the service starts
  - enable PCI command decode immediately
  - wait only 3 seconds for `boltd` probing to settle
  - reapply policy/decode just before probing NVIDIA
  - log if any PCI config path component is already inaccessible (`COMMAND=ffff`)

Next action:

1. Shut down Fedora completely.
2. Disconnect Thunderbolt from the AORUS box.
3. Remove AORUS box power for 30-60 seconds.
4. Reconnect AORUS power.
5. Reconnect Thunderbolt.
6. Boot Fedora with the enclosure connected.
7. Run the verification commands below.

Run these after each reboot/change:

```bash
boltctl
lspci -nnk -s 04:00.0
cat /sys/bus/pci/devices/0000:04:00.0/d3cold_allowed
nvidia-smi
journalctl -k -b --no-pager -g 'nvidia|NVRM|nouveau|thunderbolt|usb4|D3cold|pcie'
```

## Success Criteria

- `boltctl` shows the AORUS box as authorized.
- `lspci -nnk -s 04:00.0` shows `Kernel driver in use: nvidia`.
- `nvidia-smi` lists the RTX 5090.
- Kernel logs do not show `fallen off the bus` or `Unable to change power state from D3cold to D0`.

## Proprietary Baseline Reset

Applied after BIOS firmware update and BIOS ASPM disablement:

- Removed the `nvidia-open` packages:
  - `akmod-nvidia-open`
  - `kmod-nvidia-open-6.19.14-100.fc42.x86_64`
- Removed the depmod override that preferred `/extra/nvidia-open`.
- Disabled and removed the custom delayed AORUS NVIDIA loader service/script.
- Removed the custom NVIDIA alias blacklist used by the delayed loader.
- Removed the custom eGPU HDMI-audio `snd_hda_intel` override.
- Removed the custom eGPU D3cold udev rule.
- Removed temporary boot arguments:
  - `pcie_aspm=off`
  - `pcie_port_pm=off`
  - `pci=realloc,pcie_bus_perf`
  - `iommu=pt`
- Kept Nouveau/Nova blacklisting:
  - `module_blacklist=nouveau,nova_core`
  - `rd.driver.blacklist=nouveau,nova_core`
  - `modprobe.blacklist=nouveau,nova_core`
- Rebuilt module metadata and initramfs:
  - `depmod -a`
  - `dracut --force`
- Verified `modprobe -n -v nvidia` now selects the proprietary RPM Fusion module:

```text
insmod /lib/modules/6.19.14-100.fc42.x86_64/extra/nvidia/nvidia.ko.xz
```

- Left `nvidia-settings` user autostart disabled and `nvidia-fallback.service` masked to avoid extra probes/Nouveau fallback while validating the proprietary baseline.

## Proprietary Baseline Cold-Boot Result After BIOS Update

- BIOS firmware was updated externally before this test.
- BIOS ASPM was disabled externally; Native ACPI PCIe was left enabled because the internal Arc GPU requires it.
- Fedora booted `6.19.14-100.fc42.x86_64` with the proprietary RPM Fusion NVIDIA module selected.
- Thunderbolt authorized the AORUS box at 40 Gb/s RX/TX.
- The proprietary NVIDIA module did probe, but failed because BAR0 was not assigned:

```text
NVRM: This PCI I/O region assigned to your NVIDIA device is invalid:
NVRM: BAR0 is 0M @ 0x0 (PCI:0000:04:00.0)
```

- `lspci -vvv -s 04:00.0` showed no Region 0 and only BAR1/BAR3/IO assigned.
- This means the current failure is PCI resource allocation again, not an immediate driver-open-vs-proprietary issue.
- Restored only the PCI resource allocation boot argument, keeping the rest of the proprietary baseline clean:

```text
pci=realloc,pcie_bus_perf
```

- Available kernels are `6.19.14`, `6.17.13`, and `6.17.10`, but only `6.19.14` currently has a prebuilt `kmod-nvidia`. If testing `6.17`, build the NVIDIA akmod for that kernel first.

## Working State

After a cold boot with the proprietary RPM Fusion baseline plus `pci=realloc,pcie_bus_perf`:

- Kernel: `6.19.14-100.fc42.x86_64`
- Active boot arguments relevant to the eGPU:

```text
module_blacklist=nouveau,nova_core rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core pci=realloc,pcie_bus_perf
```

- Thunderbolt authorized the AORUS box at 40 Gb/s RX/TX.
- The RTX 5090 BAR0 was assigned correctly:

```text
Region 0: Memory at 80000000 (32-bit, non-prefetchable) [size=64M]
```

- NVIDIA bound successfully:

```text
Kernel driver in use: nvidia
```

- `nvidia-smi -L` succeeded:

```text
GPU 0: NVIDIA GeForce RTX 5090 (UUID: GPU-90b9424e-7236-fd4d-d903-44e565e1bd42)
```

- Idle telemetry:

```text
temperature.gpu: 48 C
fan.speed: 30 %
power.draw: 28.97 W
pstate: P8
pcie.link.gen.current: 1
pcie.link.width.current: 4
```

- Full `nvidia-smi` reported `18 MiB / 32607 MiB` memory used and `0%` GPU utilization, with `gnome-shell` using a small amount of GPU memory.
- Final installed NVIDIA package stack includes `akmod-nvidia`, `kmod-nvidia-6.19.14-100.fc42.x86_64`, and the standard NVIDIA user-space packages. `akmod-nvidia-open` / `kmod-nvidia-open` remain removed.
- `nvidia-powerd.service` is disabled, `nvidia-persistenced.service` is disabled, and `nvidia-fallback.service` remains masked.

## Compute-Only Target For vLLM

The target use case is NVIDIA CUDA/vLLM compute, while the desktop/display stack should stay on the internal Intel/Arc GPU.

After the reported `glxgears`/desktop freeze, the likely failed boot was journal boot `-5`. It showed:

```text
NVRM: Xid (PCI:0000:04:00): 79, GPU has fallen off the bus.
NVRM: Xid (PCI:0000:04:00): 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)
pcieport 0000:00:07.0: AER: Multiple Uncorrectable (Non-Fatal) error message received from 0000:04:00.0
```

The same boot showed GDM/GNOME adding the NVIDIA DRM device before the Xid, so the failure path may have been GNOME/KMS touching the eGPU rather than `glxgears` alone.

Current boot before reboot still has `gnome-shell` using a small amount of RTX 5090 memory, which is not the desired final state for a compute-only eGPU.

Applied compute-only policy:

- Added `/etc/modprobe.d/aorus-5090-compute-only.conf`:

```text
blacklist nvidia_drm
options nvidia_drm modeset=0 fbdev=0
```

- Added `/etc/udev/rules.d/81-aorus-5090-compute-power.rules` to keep the RTX 5090 GPU and HDMI-audio functions at `power/control=on` and `d3cold_allowed=0`.
- Reloaded udev rules and rebuilt initramfs with `dracut --force`.
- Current live boot cannot unload `nvidia_drm` safely because GNOME is already using it. A reboot is required to validate that NVIDIA stays out of the desktop DRM/KMS path.

Expected post-reboot target:

- `/sys/class/drm/card*` display ownership should be Intel/Arc, not NVIDIA.
- `nvidia_drm` should be absent from `/proc/modules` unless explicitly loaded.
- `nvidia-smi` should still work.
- CUDA/vLLM should use the RTX 5090 through `nvidia`/`nvidia_uvm`, not through desktop GL/KMS offload.

## GNOME Freeze Mitigation: Manual CUDA Load Only

After rebooting with the eGPU connected, GNOME froze around login. The failed boot showed that blocking only `nvidia_drm` was not enough: the base `nvidia` PCI driver still auto-loaded during Thunderbolt/eGPU enumeration before GDM started.

Current mitigation:

- `/etc/modprobe.d/aorus-5090-compute-only.conf` now blocks automatic and normal explicit loading of:
  - `nvidia`
  - `nvidia_modeset`
  - `nvidia_uvm`
  - `nvidia_drm`
- `nvidia_drm` remains hard-blocked so the eGPU cannot create a desktop DRM/KMS device.
- Manual compute loading is available through `/usr/local/sbin/aorus-5090-compute-load-nvidia` and the static service `aorus-5090-compute-load-nvidia.service`.
- The manual loader uses `modprobe --ignore-install nvidia` and `modprobe --ignore-install nvidia_uvm`, then verifies `nvidia_drm` is not loaded.
- Udev rules still keep the RTX 5090 GPU/audio PCI functions out of runtime D3cold when present.
- `dracut --force` was run after the changes so future boots use the same policy.

Expected behavior now:

- It should be safe to boot/log into GNOME with the eGPU disconnected.
- It should be safe to plug the eGPU after GNOME is already running because no NVIDIA module should auto-bind on hotplug.
- `nvidia-smi` will not work immediately after plug-in, by design.
- Start CUDA/vLLM availability manually after login with:

```bash
sudo systemctl start aorus-5090-compute-load-nvidia.service
```

Validation after plug-in, before manual compute load:

```bash
lspci -nnk -d 10de:
lsmod | grep '^nvidia' || true
ls /sys/class/drm
```

Expected before manual compute load: the RTX 5090 appears in `lspci`, but there is no `Kernel driver in use: nvidia`, no `nvidia*` modules are loaded, and no NVIDIA DRM card is added for GNOME.

Validation after manual compute load:

```bash
sudo systemctl start aorus-5090-compute-load-nvidia.service
lsmod | grep '^nvidia'
nvidia-smi
```

Expected after manual compute load: `nvidia` and `nvidia_uvm` are loaded, `nvidia_drm` is not loaded, and `nvidia-smi` lists the RTX 5090 for CUDA/vLLM.

Additional hotplug hardening after testing:

- A hotplug test after GNOME login did not add an NVIDIA DRM card and did not load `nvidia_drm`, but one unwanted base `nvidia` probe still occurred via generic PCI modalias handling and failed because BAR0 was not assigned.
- Added `/etc/udev/rules.d/79-aorus-5090-no-autoload.rules` before `/usr/lib/udev/rules.d/80-drivers.rules` to clear `MODALIAS` on the RTX 5090 GPU/audio PCI functions.
- The same rule sets:
  - GPU `driver_override=aorus_5090_manual`
  - HDMI-audio `driver_override=aorus_5090_disabled`
- Runtime overrides were applied to the currently plugged eGPU, and the NVIDIA HDMI-audio function was unbound from `snd_hda_intel`.
- Current post-override state is no `nvidia`/`nvidia_drm` modules loaded and only the Intel/Arc DRM card in `/sys/class/drm`.
- The current hotplugged eGPU instance has BAR0 unassigned, so CUDA should not be started from this state:

```text
/sys/bus/pci/devices/0000:04:00.0/resource line 1 = 0x0 0x0 0x0
```

- Updated `/usr/local/sbin/aorus-5090-compute-load-nvidia` to refuse NVIDIA loading if BAR0 is unassigned. It exits with:

```text
RTX 5090 BAR0 is unassigned; refusing to load NVIDIA.
Cold boot with the eGPU connected so pci=realloc can allocate BAR0.
```

Likely stable workflow:

1. Keep the eGPU connected before power-on when CUDA/vLLM is needed, so `pci=realloc,pcie_bus_perf` can allocate BAR0 during boot.
2. The new udev/modprobe policy should prevent NVIDIA from binding before GNOME login, avoiding the previous GNOME freeze path.
3. After logging in, run `sudo systemctl start aorus-5090-compute-load-nvidia.service` to load compute-only NVIDIA modules.
4. Verify `nvidia` and `nvidia_uvm` are loaded, `nvidia_drm` is absent, and `nvidia-smi` works.

## NVIDIA Compute Load Is Currently Unsafe

After a cold boot with the eGPU connected and GNOME login working, starting `aorus-5090-compute-load-nvidia.service` caused a whole-system/GNOME freeze and NUC fan ramp according to the user report.

The matching journal boot `-2` ended immediately after:

```text
systemd[1]: Starting aorus-5090-compute-load-nvidia.service - Load AORUS RTX 5090 NVIDIA modules for CUDA compute only...
kernel: nvidia: loading out-of-tree module taints kernel.
kernel: nvidia 0000:04:00.0: enabling device (0000 -> 0003)
kernel: NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  580.142
```

That means even compute-only base `nvidia` driver initialization is unsafe on this stack. Do not start the compute loader during normal GNOME use.

Safety latch added:

- `aorus-5090-compute-load-nvidia.service` now has:

```text
ConditionPathExists=/etc/aorus-5090-allow-compute-load
```

- `/usr/local/sbin/aorus-5090-compute-load-nvidia` also refuses to run unless `/etc/aorus-5090-allow-compute-load` exists.
- `/etc/aorus-5090-allow-compute-load` was removed, and a test `systemctl start aorus-5090-compute-load-nvidia.service` was skipped by systemd without loading NVIDIA.
- Current safe state after cold boot with eGPU connected:
  - RTX 5090 PCI device present.
  - No `nvidia`, `nvidia_uvm`, or `nvidia_drm` modules loaded.
  - No NVIDIA DRM card exposed to GNOME.
  - RTX 5090 HDMI-audio function is unbound from `snd_hda_intel`.

The audio-disable helper was also made tolerant so udev failures do not return an error during boot.

Next diagnostic should not be another GNOME-session NVIDIA load. If NVIDIA driver initialization is tested again, do it only from a non-graphical target or SSH/TTY with GDM stopped, a recovery plan ready, and expectation that the machine may freeze.

## Non-Graphical NVML Freeze Result

The next TTY/non-graphical diagnostic loaded the service successfully, but `nvidia-smi` immediately hard-froze the host and the NUC fan ramped to full speed. This makes `nvidia-smi`/NVML unsafe as telemetry on the current stack.

Applied follow-up safety changes:

- `/usr/local/sbin/aorus-5090-compute-load-nvidia` now loads only the base `nvidia` module and stops after confirming the RTX 5090 is bound to that driver.
- The loader no longer loads `nvidia_uvm` automatically.
- The loader no longer calls `nvidia-smi` or any NVML path.
- The loader restores `driver_override=aorus_5090_manual` after the bind attempt so future automatic reprobes stay blocked.
- Added `/usr/local/sbin/aorus-5090-status`, a sysfs/procfs-only status helper that reports latch state, NVIDIA module state, PCI binding, BAR0, runtime power attributes, and DRM cards without touching NVML.
- The service remains safety-latched behind `/etc/aorus-5090-allow-compute-load`.

Current staged test strategy:

1. Keep automatic NVIDIA loading disabled.
2. Keep `/etc/aorus-5090-allow-compute-load` absent unless deliberately testing from TTY/SSH with GDM stopped.
3. First test only whether the base `nvidia` driver binds and leaves the machine responsive.
4. Use `/usr/local/sbin/aorus-5090-status` for status; do not use `nvidia-smi`.
5. Only consider a separate `nvidia_uvm`/CUDA userspace test after the base-driver bind stage is stable and logs are reviewed.

## Recent Journal Review After NVML Freeze

Follow-up journal review did not find a reliable flushed `nvidia-smi` process marker for the immediate hard freeze. The closest service-start boot ended after the base NVIDIA module began loading, which means the final NVML-triggered failure likely locked the host before userspace or kernel logs were flushed.

Useful retained log signals:

- Repeated AER on the Thunderbolt/root-port path, especially `0000:00:07.0` and downstream eGPU bridges.
- Earlier failing NVIDIA/desktop boots show RM/GSP assertion loops, `Xid 154`, `GPU has fallen off the bus`, `NV_ERR_GPU_IS_LOST`, and `AER: Multiple Uncorrectable (Non-Fatal) error message received from 0000:04:00.0`.
- One later non-NVIDIA boot showed fatal downstream bridge recovery failure: `0000:03:00.0: AER: device recovery failed`.
- Current safe boot remains clean from an NVIDIA-binding perspective: latch absent, `nvidia*` modules unloaded, RTX 5090 unbound, HDMI-audio unbound, BAR0 assigned, and only the Intel `i915` DRM card present.

Interpretation: do not treat the absence of a `nvidia-smi` journal line as evidence that NVML is safe. The user-observed immediate freeze is enough to keep `nvidia-smi` out of all next-stage diagnostics.

## Base NVIDIA Driver Bind Succeeded

The staged non-graphical base-driver bind test succeeded without a freeze.

Observed sequence:

1. Pre-test status showed the latch absent, all `nvidia*` modules unloaded, RTX 5090 unbound, BAR0 assigned, HDMI-audio unbound, and only the Intel `i915` DRM card present.
2. `systemctl isolate multi-user.target` stopped GNOME/GDM, which also disconnected the OpenCode frontend, but the shell command continued.
3. The latch was created temporarily and `aorus-5090-compute-load-nvidia.service` was started.
4. The service returned success and logged:

```text
RTX 5090 is bound to the base nvidia driver.
nvidia_uvm was intentionally not loaded. Do not run nvidia-smi/NVML for this diagnostic stage.
```

5. Post-test status before reboot showed:

```text
nvidia: loaded
nvidia_uvm: unloaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
GPU power_state: D0
GPU driver_override: aorus_5090_manual
drm_cards: card1: i915
```

6. Kernel logs after the bind showed normal NVIDIA module load lines and no new `Xid`, `fallen off the bus`, `NV_ERR_GPU_IS_LOST`, or `nvidia_drm` messages.
7. After reboot, current status returned to the safe policy state: latch absent, all `nvidia*` modules unloaded, RTX 5090 unbound, BAR0 assigned, HDMI-audio unbound, and only `i915` in DRM.

Interpretation: base NVIDIA PCI/RM driver binding is not the immediate freeze trigger when GNOME is stopped and `nvidia_uvm`/NVML are avoided. The next isolation boundary is `nvidia_uvm` loading, still without `nvidia-smi` or CUDA user-space.

## NVIDIA UVM Load Succeeded

The staged non-graphical `nvidia_uvm` load test succeeded without a freeze.

Observed sequence:

1. Pre-test status showed the safe policy state: latch absent, all `nvidia*` modules unloaded, RTX 5090 unbound, BAR0 assigned, HDMI-audio unbound, and only the Intel `i915` DRM card present.
2. GNOME/GDM was stopped with `systemctl isolate multi-user.target`, disconnecting the OpenCode frontend as expected.
3. The base-driver bind service completed successfully.
4. `modprobe --ignore-install nvidia_uvm` returned success.
5. `/root/aorus-5090-uvm-test-status.txt` was written with:

```text
nvidia_uvm test complete
bind_rc=0
uvm_rc=0
```

6. Post-test status before reboot showed:

```text
nvidia: loaded
nvidia_uvm: loaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
GPU power_state: D0
GPU driver_override: aorus_5090_manual
drm_cards: card1: i915
```

7. Previous-boot logs after the test showed normal NVIDIA base-driver load lines and no new `Xid`, `fallen off the bus`, `NV_ERR_GPU_IS_LOST`, `nvidia_drm`, kernel panic, hard lockup, or hung-task markers.
8. After reboot, current status returned to the safe policy state: latch absent, all `nvidia*` modules unloaded, RTX 5090 unbound, BAR0 assigned, HDMI-audio unbound, and only `i915` in DRM.

Interpretation: `nvidia_uvm` loading is not the immediate freeze trigger when GNOME is stopped and NVML is avoided. The next isolation boundary is minimal CUDA Driver API initialization, still without `nvidia-smi`/NVML and without a real workload.

## Minimal CUDA Driver API Init Succeeded

The staged non-graphical CUDA Driver API initialization test succeeded without a freeze.

Test files:

- `/root/aorus-5090-cuda-init-test.py`
- `/root/aorus-5090-run-cuda-init-test`
- `/root/aorus-5090-cuda-init-test-status.txt`
- `/root/aorus-5090-cuda-init-test-output.txt`
- `/root/aorus-5090-cuda-init-test-post-status.txt`
- `/root/aorus-5090-cuda-init-test-kernel.log`

Observed result:

```text
cuda init test complete
bind_rc=0
uvm_rc=0
cuda_rc=0
```

CUDA Driver API output:

```text
cuInit=0
cuDeviceGetCount=0
device_count=1
```

Post-test status showed:

```text
nvidia: loaded
nvidia_uvm: loaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
GPU power_state: D0
GPU driver_override: aorus_5090_manual
drm_cards: card1: i915
```

No `nvidia-smi`/NVML path was used. The captured kernel log showed normal NVIDIA base-driver load lines and no new `Xid`, `fallen off the bus`, `NV_ERR_GPU_IS_LOST`, `nvidia_drm`, kernel panic, hard lockup, or hung-task markers through completion of the CUDA init test.

Interpretation: minimal CUDA Driver API initialization is not the immediate freeze trigger when GNOME is stopped and NVML is avoided. The next isolation boundary is a tiny CUDA runtime/driver workload, still without `nvidia-smi`/NVML and preferably still with GNOME stopped for one more stage.

## GNOME-Running CUDA Smoke Test Succeeded

The CUDA Driver API smoke test also succeeded while GNOME was running, without loading `nvidia_drm` and without using `nvidia-smi`/NVML.

Test files:

- `/root/aorus-5090-cuda-smoke-test.py`
- `/root/aorus-5090-run-cuda-smoke-gnome`
- `/root/aorus-5090-cuda-smoke-gnome-status.txt`
- `/root/aorus-5090-cuda-smoke-gnome-output.txt`
- `/root/aorus-5090-cuda-smoke-gnome-post-status.txt`
- `/root/aorus-5090-cuda-smoke-gnome-kernel.log`

Observed result:

```text
cuda smoke gnome test complete
bind_rc=0
uvm_rc=0
smoke_rc=0
stop_rc=0
```

CUDA smoke output:

```text
cuInit=0
cuDeviceGet=0
device=0
cuCtxCreate=0
cuMemAlloc=0
cuMemsetD8=0
cuCtxSynchronize=0
cuMemcpyDtoH=0
bytes_checked=4096
mismatches=0
cuMemFree=0
cuCtxDestroy=0
cuda_smoke=pass
```

Post-test status showed:

```text
nvidia: loaded
nvidia_uvm: loaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
GPU power_state: D0
GPU driver_override: aorus_5090_manual
drm_cards: card1: i915
```

The service was stopped afterward so systemd no longer considers `aorus-5090-compute-load-nvidia.service` active, but the `nvidia` and `nvidia_uvm` modules intentionally remain loaded for the current session. The latch was removed.

Interpretation: a tiny CUDA workload can coexist with GNOME as long as the RTX 5090 remains compute-only (`nvidia_drm` absent) and NVML is avoided. The next isolation boundary is a minimal framework test, preferably PyTorch if installed, while avoiding NVML-backed telemetry.

## Minimal NVML Probe Froze At `nvmlInit()`

The minimal NVML probe hard-froze the system with full fans, matching the earlier `nvidia-smi` failure mode. The system was rebooted afterward and returned to the safe policy state: latch absent, all `nvidia*` modules unloaded, RTX 5090 unbound, BAR0 assigned, HDMI-audio unbound, and only `i915` in DRM.

The progress marker `/root/aorus-5090-nvml-probe-progress.txt` shows:

```text
2026-05-01 08:57:44 before load libnvidia-ml.so.1
2026-05-01 08:57:44 after load libnvidia-ml.so.1
2026-05-01 08:57:44 before nvmlInit
```

There is no `after nvmlInit` marker. This narrows the failure boundary to `nvmlInit()` itself, before any device count, handle, temperature, fan, power, or utilization query.

Previous-boot journal did not retain useful NVIDIA/RM lines for the freeze, which is consistent with an immediate hard lock before logs flushed.

Interpretation: CUDA compute path is usable in the tested configuration, but NVML initialization is currently unsafe. Treat all of the following as unsafe until proven otherwise:

- `nvidia-smi`
- direct `libnvidia-ml.so.1` / NVML use
- `pynvml` / `nvidia-ml-py`
- framework telemetry paths that call NVML for device count, memory, temperature, utilization, or power

Next work should focus on running ML frameworks with NVML disabled/avoided, then separately investigating why `nvmlInit()` hard-freezes on this Thunderbolt RTX 5090 path.

## NVML Recovery Target And Prepared Mitigations

The target state is now explicitly: `nvidia-smi`/NVML must work. CUDA-only operation is not sufficient for final success because management telemetry is needed for temperature, fan, power, and framework/device monitoring confidence.

GNOME/display isolation is already achieved and should be preserved:

- The internal Intel/Arc path owns DRM as `i915`.
- `nvidia_drm` is hard-blocked and has not loaded during successful compute tests.
- The RTX 5090 is loaded only as a compute device through the base `nvidia` driver and `nvidia_uvm`.

Non-risky inspection after the `nvmlInit()` freeze found:

- No newer Fedora/RPM Fusion NVIDIA or kernel package was offered by `dnf check-update --refresh`.
- Current NVIDIA stack is `580.142` on kernel `6.19.14-100.fc42.x86_64`.
- The installed NVIDIA README says Blackwell and later GPUs are only supported by the open kernel modules, and the open kernel modules depend on GSP. This makes GSP-disable unlikely to be a final fix for RTX 5090, though it remains a useful negative diagnostic.
- The Thunderbolt upstream path was still runtime-power-managed (`power/control=auto`, `d3cold_allowed=1`) on the root/downstream bridges.
- After Thunderbolt authorization/hotplug, the RTX 5090 BAR1 is currently 256 MiB even though the pre-authorization/cold enumeration previously exposed a 32 GiB BAR1 window.

Applied safe hardening:

- Expanded `/etc/udev/rules.d/81-aorus-5090-compute-power.rules` so the Thunderbolt root/downstream bridge path also gets `power/control=on` and `d3cold_allowed=0`.
- Updated `/usr/local/sbin/aorus-5090-compute-load-nvidia` to apply the same upstream PCI power policy immediately before binding NVIDIA.
- Kept GNOME isolation intact; `nvidia_drm` remains blocked.

Prepared controlled risky tests, not yet run:

- `/root/aorus-5090-nvml-init-probe.py`: calls only NVML init/shutdown and writes fsynced progress markers before/after each call.
- `/root/aorus-5090-run-nvml-rebar32-test`: attempts to resize BAR1 to 32 GiB (`resource1_resize` bit `15`), binds base NVIDIA with default GSP, then calls only `nvmlInit()`.
- `/root/aorus-5090-run-nvml-gspoff-test`: diagnostic only; attempts base NVIDIA bind with `NVreg_EnableGpuFirmware=0`, then calls only `nvmlInit()` if binding succeeds.

Recommended next risky test order:

1. Run `/root/aorus-5090-run-nvml-rebar32-test` first, because it keeps the required Blackwell/GSP path and targets the observed BAR1/layout difference.
2. If the ReBAR32 test freezes or fails before NVML, use its marker/status files to identify whether the failure was resize, bind, or `nvmlInit()`.
3. Use the GSP-off test only as a secondary diagnostic; on Blackwell it is expected to fail binding if GSP is mandatory.

## ReBAR32 NVML Test Did Not Reach NVIDIA

The ReBAR32 NVML test returned without freezing, but did not reach NVIDIA binding or NVML.

Result:

```text
nvml rebar32 test complete
resize_rc=1
bind_rc=99
nvml_rc=99
```

Resize log:

```text
before=000000000000ffc0
/root/aorus-5090-run-nvml-rebar32-test: line 38: printf: write error: No space left on device
after=000000000000ffc0
```

Current BAR1 remained 256 MiB:

```text
Region 1: Memory at 4000000000 (64-bit, prefetchable) [disabled] [size=256M]
BAR 1: current size: 256MB, supported: 64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB
```

Interpretation: the current Thunderbolt/hotplug bridge window cannot fit a 32 GiB BAR1 resize. This is a PCI bridge resource-window limitation, not an NVIDIA or NVML result.

Prepared follow-up:

- `/root/aorus-5090-run-nvml-rebar-sweep-test` tries smaller BAR1 sizes from 16 GiB down to 512 MiB and only attempts NVIDIA/NVML if a resize above the current 256 MiB succeeds.

If the sweep also cannot resize above 256 MiB, the standard fix is likely boot-time PCI resource reservation/assignment rather than live resize after Thunderbolt authorization.

## ReBAR Sweep Also Could Not Resize BAR1

The follow-up ReBAR sweep returned without freezing, but no BAR1 size above the current 256 MiB could be assigned.

Result summary:

```text
nvml rebar sweep test complete
bind_rc=99
nvml_rc=99
```

The sweep attempted BAR1 sizes from 16 GiB down to 512 MiB and each write to `resource1_resize` failed before NVIDIA or NVML was reached:

```text
printf: write error: No space left on device
```

Current PCI layout explains the failure:

- The occupied downstream Thunderbolt bridge `0000:03:00.0` only has a 288 MiB prefetchable window: `4000000000-4011ffffff`.
- The RTX 5090 BAR1 is 256 MiB inside that window, with BAR3 consuming another 32 MiB.
- The three empty hotplug downstream bridges `0000:03:01.0`, `0000:03:02.0`, and `0000:03:03.0` each have about 21.8 GiB of prefetchable window space.
- Upstream Thunderbolt windows are already large, about 64 GiB, so the immediate issue is distribution among downstream bridge windows, not total upstream aperture.

Interpretation: live ReBAR resizing cannot proceed because the parent bridge window for the actual GPU port is too small. This must be corrected at boot-time PCI resource assignment, before NVIDIA/NVML tests.

## Boot-Time PCI Resource Experiment Prepared

Kernel parameter documentation confirms two relevant `pci=` options:

- `hpmmioprefsize=nn[KMG]`: fixed prefetchable MMIO reservation for hotplug bridge windows.
- `resource_alignment=[order@]<pci_dev>`: can target a PCI-PCI bridge when resource windows need to be expanded.

Applied on 2026-05-01 to the default Fedora `6.19.14-100.fc42.x86_64` boot entry and `/etc/kernel/cmdline`:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0
```

Intent:

- Keep the already-required `pci=realloc,pcie_bus_perf` behavior.
- Limit oversized prefetchable reservations on empty hotplug downstream ports to 256 MiB.
- Force the occupied downstream bridge `0000:03:00.0` to be reassigned/expanded with a 32 GiB alignment target, so the RTX 5090 BAR1 can potentially resize above 256 MiB.

This does not load NVIDIA and does not affect the current running kernel until reboot.

Revert command if the system does not boot cleanly with this experiment:

```bash
sudo grubby --update-kernel=DEFAULT --remove-args='pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0' --args='pci=realloc,pcie_bus_perf'
```

Also restore `/etc/kernel/cmdline` to use only:

```text
pci=realloc,pcie_bus_perf
```

Next cold-boot checks, before loading NVIDIA or calling NVML:

```bash
cat /proc/cmdline
sudo /usr/local/sbin/aorus-5090-status
lspci -vv -s 03:00.0
lspci -vv -s 03:01.0
lspci -vv -s 04:00.0
```

Success criterion for this stage: `0000:03:00.0` has a substantially larger prefetchable memory window than 288 MiB, preferably enough for a 32 GiB BAR1 plus BAR3. Only after that should the minimal ReBAR/NVML probe be retried.

## Boot-Time PCI Layout Collector Added

Added on 2026-05-01:

- `/usr/local/sbin/aorus-5090-collect-pci-layout`
- `/etc/systemd/system/aorus-5090-collect-pci-layout.service`
- `/etc/aorus-5090-collect-pci-layout` latch file

The collector is enabled and gated by `/etc/aorus-5090-collect-pci-layout`. It records the post-boot PCI layout to `/root/aorus-5090-pci-layout/<timestamp>.txt` and updates `/root/aorus-5090-pci-layout/latest.txt`.

The collector is read-only with respect to NVIDIA: it does not load NVIDIA, does not bind the GPU, does not resize BAR1, and does not call NVML or `nvidia-smi`.

The initial manual collector run captured the pre-reboot baseline, still without the new experimental PCI args active in `/proc/cmdline`:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]
RTX 5090 BAR1: current size: 256MB
```

After the next cold boot, inspect `/root/aorus-5090-pci-layout/latest.txt` first to see whether the experimental args changed the bridge-window distribution.

## Cold-Boot PCI Resource Verification

Verified after cold boot on 2026-05-01.

The experimental boot args were active:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0
```

Safe state remained intact:

- `/etc/aorus-5090-allow-compute-load` absent.
- `nvidia`, `nvidia_uvm`, `nvidia_modeset`, and `nvidia_drm` unloaded.
- RTX 5090 present but unbound.
- DRM remained `i915` only.

Final post-authorization PCI layout did not meet the success criterion:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]
RTX 5090 BAR1: current size: 256MB
```

Do not run the ReBAR/NVML sweep in this state.

Important discovery from the boot log: the early PCI enumeration did briefly have the desired large resource layout before `boltd` userspace authorization/hotplug reconfiguration:

```text
pci 0000:03:00.0: bridge window [mem 0x4000000000-0x48140fffff 64bit pref]
pci 0000:04:00.0: BAR 1 [mem 0x4000000000-0x47ffffffff 64bit pref]
```

That is a 32 GiB BAR1 assignment and a large enough parent bridge window. After `boltd` started and authorized the enclosure, the kernel re-enumerated the Thunderbolt PCIe path with invalid/empty bridge windows, then reallocated it down to the bad layout:

```text
boltd: authorize: finished: ok
pci 0000:03:00.0: bridge configuration invalid ([bus 00-00]), reconfiguring
pci 0000:03:00.0: bridge window [mem 0x4000000000-0x4011ffffff 64bit pref]: assigned
pci 0000:03:00.0: bridge window [mem 0x4000000000-0x4011ffffff 64bit pref]: failed to expand by 0x12000000
pci 0000:04:00.0: BAR 1 [mem 0x4000000000-0x400fffffff 64bit pref]: assigned
```

Interpretation: the hardware/firmware can expose a correct 32 GiB BAR1 layout, but the Linux Thunderbolt userspace authorization/hotplug path replaces it with a 256 MiB BAR1 layout. The next durable fix should target one of these:

- Preserve the firmware/early-boot Thunderbolt PCIe tunnel layout so `boltd` does not tear it down/recreate it after userspace starts.
- Change BIOS/Thunderbolt security/pre-boot authorization behavior if available, so the device is authorized before OS hotplug allocation.
- Find a Linux PCI/Thunderbolt hotplug allocation parameter or policy that forces a larger downstream window during the post-authorization hotplug pass.

Current boot args are not sufficient by themselves for the post-authorization layout.

## Bolt-Masked Cold-Boot Experiment Prepared

Prepared on 2026-05-01:

- Masked `bolt.service` for the next boot.
- Did not stop the currently running `boltd` process to avoid live Thunderbolt teardown.
- Removed `bolt.service` from the PCI layout collector's `Wants=`/`After=` dependencies.
- Removed the `boltctl` call from `/usr/local/sbin/aorus-5090-collect-pci-layout`, because `boltctl` can D-Bus-activate `boltd`.

Current state before reboot:

```text
systemctl is-enabled bolt.service -> masked
systemctl is-active bolt.service -> active
```

This is expected: masking prevents the next start, but does not stop the already-running instance.

Next cold-boot goal: verify whether the early 32 GiB BAR1 layout persists when `boltd` cannot start and authorize/reconfigure the device in userspace.

Do not run `boltctl` before checking the PCI layout on the next boot.

Restore command after the experiment:

```bash
sudo systemctl unmask bolt.service
```

## Bolt-Masked Experiment Result And Host-Reset Experiment Prepared

Verified after cold boot on 2026-05-01:

- `bolt.service` was masked and inactive.
- No `boltd` process was running.
- The AORUS device appeared in Thunderbolt sysfs but stayed unauthorized:

```text
/sys/bus/thunderbolt/devices/0-1/authorized = 0
/sys/bus/thunderbolt/devices/0-1/boot = 0
```

- By the time userspace ran, the RTX 5090 was not present on PCI.
- Kernel logs still showed the early firmware/initial PCI enumeration had the good layout before the Thunderbolt core handled the unauthenticated device:

```text
pci 0000:03:00.0: bridge window [mem 0x4000000000-0x48140fffff 64bit pref]
pci 0000:04:00.0: BAR 1 [mem 0x4000000000-0x47ffffffff 64bit pref]
```

Then a direct sysfs authorization was tested without `boltd` or `boltctl`:

```bash
printf 1 > /sys/bus/thunderbolt/devices/0-1/authorized
```

Result after manual sysfs authorization:

- `bolt.service` remained inactive.
- No `boltd` process was running.
- RTX 5090 returned to PCI safely and remained unbound from NVIDIA.
- The final layout still collapsed to the bad post-authorization state:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-4011ffffff [size=288M]
RTX 5090 BAR1: current size: 256MB
```

Interpretation: `boltd` policy is not the root cause. The regression occurs in the kernel Thunderbolt authorization/hotplug path itself, or in the host-router reset/tunnel recreation around that path.

Restored `bolt.service` availability after the experiment:

```text
systemctl is-enabled bolt.service -> static
systemctl is-active bolt.service -> inactive
```

Prepared next reversible boot-argument experiment:

```text
thunderbolt.host_reset=false
```

This was added to the default boot entry and `/etc/kernel/cmdline`, alongside the existing PCI resource args. Current intended next-boot args:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 thunderbolt.host_reset=false
```

Goal: test whether preventing the Thunderbolt/USB4 host router reset lets the firmware/early-boot 32 GiB BAR1 layout survive the Thunderbolt security/authorization transition.

No NVIDIA/NVML test should be run until after the next cold boot confirms a final large bridge window and BAR1 above 256 MiB.

## Host-Reset Disabled Fixed Final BAR1 Layout

Verified after cold boot on 2026-05-01 with active boot args:

```text
pci=realloc,pcie_bus_perf,hpmmioprefsize=256M,resource_alignment=35@0000:03:00.0 thunderbolt.host_reset=false
```

Runtime confirmation:

```text
/sys/module/thunderbolt/parameters/host_reset = N
bolt.service = active
boltd running
```

Safe NVIDIA state remained intact:

- `/etc/aorus-5090-allow-compute-load` absent.
- `nvidia`, `nvidia_uvm`, `nvidia_modeset`, and `nvidia_drm` unloaded.
- RTX 5090 present but unbound.
- HDMI-audio unbound by policy.
- DRM remained `i915` only.

Final authorized PCI layout now meets the BAR1/resource-window goal:

```text
0000:03:00.0 Prefetchable memory behind bridge: 4000000000-48140fffff [size=33089M]
0000:04:00.0 Region 1: Memory at 4000000000 (64-bit, prefetchable) [disabled] [size=32G]
BAR 1: current size: 32GB, supported: 64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB
```

Interpretation: `thunderbolt.host_reset=false` is the key fix for preserving the firmware/early-boot PCIe tunnel/resource layout through Thunderbolt authorization. `boltd` can run normally once host-router reset is disabled.

The next test should not jump directly to full `nvidia-smi`. Use a staged order:

1. Base NVIDIA bind only, with no NVML.
2. Confirm `nvidia` loaded, `nvidia_drm` absent, and BAR1 remains 32 GiB.
3. Load `nvidia_uvm` and rerun the previous CUDA smoke if needed.
4. Only then retry the minimal NVML init probe.
5. Only if minimal NVML init succeeds, try `nvidia-smi -L`, then full `nvidia-smi`.

## Base NVIDIA And CUDA Still Work With 32 GiB BAR1

After the successful `thunderbolt.host_reset=false` cold boot, the base NVIDIA bind succeeded with the final 32 GiB BAR1 layout intact.

Status after base bind:

```text
nvidia: loaded
nvidia_uvm: unloaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
BAR1: 0x0000004000000000-0x00000047ffffffff
drm_cards: card1: i915
```

`/usr/local/sbin/aorus-5090-compute-load-nvidia` now refuses to bind NVIDIA unless BAR1 is at least 32 GiB. `/usr/local/sbin/aorus-5090-status` now prints BAR1 and `resource1_resize` state.

The CUDA smoke test also succeeded with the 32 GiB BAR1 layout:

```text
cuda smoke gnome test complete
bind_rc=0
uvm_rc=0
smoke_rc=0
stop_rc=0
```

CUDA smoke output:

```text
cuInit=0
cuDeviceGet=0
device=0
cuCtxCreate=0
cuMemAlloc=0
cuMemsetD8=0
cuCtxSynchronize=0
cuMemcpyDtoH=0
bytes_checked=4096
mismatches=0
cuMemFree=0
cuCtxDestroy=0
cuda_smoke=pass
```

Post-CUDA status still showed:

```text
nvidia: loaded
nvidia_uvm: loaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: nvidia
BAR1: 0x0000004000000000-0x00000047ffffffff
drm_cards: card1: i915
```

No new `Xid`, fallen-off-bus, `nvidia_drm`, panic, hard lockup, or hung-task message was captured before the NVML test.

## NVML Still Freezes With 32 GiB BAR1

The minimal NVML init probe still hard-froze the system even after the host-reset fix and 32 GiB BAR1 layout. The machine required a forced reboot.

Progress marker:

```text
2026-05-01 13:31:21 before load libnvidia-ml.so.1
2026-05-01 13:31:21 after load libnvidia-ml.so.1
2026-05-01 13:31:21 before nvmlInit_v2
```

There is no `after nvmlInit_v2` marker.

After forced reboot, the system returned to safe state:

```text
safety_latch: absent
nvidia: unloaded
nvidia_uvm: unloaded
nvidia_modeset: unloaded
nvidia_drm: unloaded
GPU driver: none
BAR1: 0x0000004000000000-0x00000047ffffffff
drm_cards: card1: i915
```

Interpretation: the BAR1/Thunderbolt resource problem is fixed by `thunderbolt.host_reset=false`, but NVML remains a separate hard-freeze boundary inside `nvmlInit_v2`. Treat all NVML callers as unsafe until a new mitigation is identified:

- `nvidia-smi`
- direct `libnvidia-ml.so.1`
- `pynvml` / `nvidia-ml-py`
- framework telemetry paths that initialize NVML

Next investigation should avoid repeated blind NVML attempts. If another risky NVML test is approved, instrument it for the next lower-level boundary, such as a one-shot `strace`/fsynced ioctl trace or a single NVIDIA module-parameter variation, rather than rerunning the same probe unchanged.

## NVML Ioctl Trace Narrowed The Boundary

An `LD_PRELOAD` ioctl tracer was added because `strace` is not installed. It fsyncs each `ioctl_enter` and `ioctl_exit` marker before forwarding to the real `ioctl()`.

The first base-only NVML init/shutdown run succeeded with BAR1 still at 32 GiB and only the base `nvidia` module loaded:

```text
2026-05-01 13:39:28 before load libnvidia-ml.so.1
2026-05-01 13:39:28 after load libnvidia-ml.so.1
2026-05-01 13:39:28 before nvmlInit_v2
2026-05-01 13:39:30 after nvmlInit_v2 rc=0
2026-05-01 13:39:30 before nvmlShutdown
2026-05-01 13:39:30 after nvmlShutdown rc=0
```

The immediately following base-only NVML basic probe froze before it could finish `nvmlInit_v2`:

```text
2026-05-01 13:40:16 before load libnvidia-ml.so.1
2026-05-01 13:40:16 after load libnvidia-ml.so.1
2026-05-01 13:40:16 before nvmlInit_v2
```

The frozen ioctl trace ended at:

```text
pid=4609 tid=4609 ioctl_enter fd=11 path=/dev/nvidia0 request=0xc00846da arg=0x7ffead6d7a80 rc=-999999 errno=0
```

There is no matching `ioctl_exit`. The installed NVIDIA source maps this request to `NV_ESC_WAIT_OPEN_COMPLETE`:

```text
NV_IOCTL_MAGIC='F'
NV_IOCTL_BASE=200
NV_ESC_WAIT_OPEN_COMPLETE=NV_IOCTL_BASE + 18 = 218 = 0xda
```

In the successful base-only run, the same first `/dev/nvidia0` ioctl returned after about 1.13 seconds:

```text
ioctl_enter fd=11 path=/dev/nvidia0 request=0xc00846da
ioctl_exit  fd=11 path=/dev/nvidia0 request=0xc00846da rc=0
```

Interpretation: the freeze is not caused by later NVML device count, handle, name, temperature, fan, power, or utilization calls. It occurs while NVML is waiting for the `/dev/nvidia0` open/initialization path to complete. Because one `nvmlInit_v2`/`nvmlShutdown` succeeded and the next base-only `nvmlInit_v2` froze in the same driver session, the new suspect is post-`nvmlShutdown` / second-open state or NVIDIA's nonblocking-open deferred initialization path, not GNOME, `nvidia_drm`, `nvidia_uvm`, or BAR1 sizing.

Targeted next risky diagnostic, if another freeze-risk test is acceptable: load the base `nvidia` module with `NVreg_EnableNonblockingOpen=0` and run the same fsynced minimal NVML init probe once. That parameter forces `O_NONBLOCK` opens of `/dev/nvidiaN` to initialize in the foreground instead of scheduling NVIDIA's background open path. This may move the hang from `NV_ESC_WAIT_OPEN_COMPLETE` into `open()`, but if the failure is specifically in deferred open completion it could be a useful mitigation or at least a sharper boundary.

Prepared files for that diagnostic:

- `/root/aorus-5090-nvml-ioctl-trace.so`: rebuilt tracer now logs NVIDIA-related `open`, `open64`, `openat`, `openat64`, `close`, and all `ioctl` events with fsync.
- `/usr/local/sbin/aorus-5090-compute-load-nvidia`: now accepts `AORUS_5090_DISABLE_NONBLOCKING_OPEN=1` and passes `NVreg_EnableNonblockingOpen=0` to `modprobe nvidia`.
- `/root/aorus-5090-run-nvml-nonblockoff-two-init-test`: prepared but not run. It requires a clean unloaded NVIDIA state, binds base `nvidia` with nonblocking open disabled, verifies `/proc/driver/nvidia/params` shows `EnableNonblockingOpen: 0`, then runs two separate minimal `nvmlInit_v2`/`nvmlShutdown` probes in the same driver session. This directly tests the observed first-init-success/second-init-freeze pattern.

## Nonblocking-Open Disabled Test Moved The Freeze Into open() Itself

Run on 2026-05-01 after agent handover. The two-init test was executed with `NVreg_EnableNonblockingOpen=0`. The test froze the host on the second NVML probe and required a forced reboot, but the prepared fsynced ioctl tracer captured the new boundary cleanly.

Test script verification fix needed before the run:

- The test originally aborted with `reason=nonblocking_open_not_disabled` (rc=94) on the first attempt because it grepped `/proc/driver/nvidia/params` for `EnableNonblockingOpen: 0`.
- That `/proc` interface only exposes the RM/registry-style parameters, not every `module_param`. On the open kernel module loaded for Blackwell, `NVreg_EnableNonblockingOpen` is not mirrored there.
- `/sys/module/nvidia/parameters/` does not exist on this driver build either; the open kernel module declares its parms with permissions that suppress the sysfs directory entirely.
- The verification was changed to grep the `aorus-5090-compute-load-nvidia` log for the "NVIDIA nonblocking open was disabled" line. The loader uses `set -euo pipefail`, so an unknown module parameter would fail `modprobe` and abort the loader before that line is printed.

Note on driver identity: dmesg reports `NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  580.142`. RPM Fusion's `kmod-nvidia` package on Blackwell ships the open kernel module, even when the proprietary metapackage is installed. This is required by NVIDIA on Blackwell and is not a regression from the earlier `akmod-nvidia-open` swap.

Result of the corrected run:

```text
nvml nonblockoff two-init test started
bind_rc=0
first_nvml_rc=0
stage=before_second_nvml_init
```

First NVML probe progress:

```text
2026-05-01 14:16:35 before load libnvidia-ml.so.1
2026-05-01 14:16:35 after load libnvidia-ml.so.1
2026-05-01 14:16:35 before nvmlInit_v2
2026-05-01 14:16:36 after nvmlInit_v2 rc=0
2026-05-01 14:16:36 before nvmlShutdown
2026-05-01 14:16:37 after nvmlShutdown rc=0
```

Second NVML probe ioctl trace ended at:

```text
open64_enter dirfd=-100 path=/dev/nvidia0 flags=0x80802 mode=00 rc=-999999 errno=0
```

There is no matching `open64_exit`. `flags=0x80802` is `O_RDWR | O_NONBLOCK | O_CLOEXEC`; libnvidia-ml passes `O_NONBLOCK` regardless of the module parameter setting. The module parameter only controls whether the driver foreground-initializes inside `open()` or defers to a background completion path serviced by `NV_ESC_WAIT_OPEN_COMPLETE`.

Interpretation:

- The earlier hang at `NV_ESC_WAIT_OPEN_COMPLETE` (`request=0xc00846da`) was a symptom of deferred-open completion never arriving, not the root cause. With deferral disabled, the same underlying problem now hangs `open()` directly. The previously-suspected NVIDIA nonblocking-open scheduler is therefore not the bug.
- The first `nvmlInit_v2`/`nvmlShutdown` cycle in this driver session fully succeeded. The second NVML probe, which is a new process opening `/dev/nvidia0` again 10 seconds after the first probe closed it, hangs in `open()`.
- The freeze boundary is now: second open of `/dev/nvidia0` after a previous open+close on the same device file in the same module-load session.

Module-reload behavior in the same boot:

- The previous-boot kernel log ended at the second `NVRM: loading NVIDIA UNIX Open Kernel Module` line, immediately after the test's `modprobe -r nvidia ; modprobe nvidia` cycle. The first reload following NVML use is itself the last log line before kernel silence.
- This means a `modprobe -r ; modprobe` reset between NVML cycles is not a safe workaround on this stack: once `/dev/nvidia0` has been opened and closed by NVML, the next module reload also wedges the host. The persistent state survives module unload, suggesting it lives below the module - in the GPU/GSP firmware state or in a PCI/device-private kernel structure that is not torn down by `nvidia.ko` removal.

Useful operational consequence:

- A single NVML cycle per freshly-loaded driver session is safe. `nvidia-smi` will work once after a fresh `modprobe nvidia`. Running it a second time, or any other process that opens `/dev/nvidia0` after the first close, will hard-freeze the host.
- A long-lived NVML/CUDA process that never releases its `/dev/nvidia0` file descriptor avoids the close-then-reopen path entirely. CUDA compute through such a process should remain stable because the open-then-close-then-reopen sequence is what triggers the hang.

Open questions worth one targeted experiment each, not chained together:

- Does `NVreg_DynamicPowerManagement=0` (currently `3`) prevent the close-side teardown that wedges subsequent opens? Plausibly involved because runtime-PM-on-close puts state into the device that the next open must wake up, and the eGPU TB path may not survive that wake transition cleanly.
- Does `NVreg_PreserveVideoMemoryAllocations=0` (currently `1`) change the close path enough to avoid the hang? Less likely to help, more risky on a desktop, but cheap to flip in a TTY-only diagnostic.
- Does explicitly *not closing* `/dev/nvidia0` between NVML init and shutdown across two libnvidia-ml clients prevent the hang? Reproduce-with-fd-keepalive is a userspace-only experiment and could distinguish "close path wedges device" from "second open wedges device".

Do not run another freeze-risk diagnostic without explicit approval. Each freeze costs a forced reboot and reproduces the same boundary cleanly via the existing tracer, so additional unchanged repeats add no information.

## Persistence Mode Resolved The Reopen Wedge

Run on 2026-05-01 after the agent handover and the docs update. The hypothesis was that `nvidia-persistenced`, by holding `/dev/nvidiactl` and `/dev/nvidia0` open for its entire lifetime, would prevent any later `nvidia-smi` invocation from being a "second open after last close" - because no last close ever occurs while the daemon runs.

Correction to an earlier assumption in the plan: the AORUS RTX 5090 AI Box's water cooling and fan are **not** managed by the GPU vBIOS without driver assistance. They only run after the NVIDIA driver loads and binds. This makes "driver loaded continuously" a hard thermal requirement, not just a usability preference. Running for long with the driver unloaded heats the device.

Test sequence from the safe baseline (eGPU connected, BAR1 32 GiB, `host_reset=N`, all `nvidia*` modules unloaded, GPU unbound, latch absent):

1. `aorus-5090-compute-load-nvidia` ran with default flags. Bind succeeded, `nvidia` loaded, GPU bound. Module refcount 0, no `nvidia_uvm`, no `nvidia_drm`.
2. `nvidia-persistenced --verbose` started. It daemonized (the parent shell's `$!` captured the launcher PID, not the daemon PID, which initially looked like an early exit but was actually fork detachment). The daemon ran as a separate PID and reported via syslog:

```text
Verbose syslog connection opened
Started (<pid>)
device 0000:04:00.0 - registered
device 0000:04:00.0 - persistence mode enabled.
device 0000:04:00.0 - NUMA memory onlined.
Local RPC services initialized
```

3. Daemon `/proc/<pid>/fd` showed it holding one fd on `/dev/nvidiactl` and four fds on `/dev/nvidia0`. `lsmod` showed the `nvidia` module refcount at 5.
4. `nvidia-smi` was run five times back to back with one-second sleeps. All five returned rc=0 and produced expected output:

```text
| 0  NVIDIA GeForce RTX 5090   On  |  00000000:04:00.0 Off |  N/A |
| 30%  50C  P8   19W / 575W    |   0MiB / 32607MiB |   0%  Default |
```

5. The system was idled for 60 seconds. `power_state` stayed `D0` (the existing `d3cold_allowed=0` udev policy prevents runtime D3cold). `nvidia-smi` was run once more, then three more times in rapid succession with `--query-gpu=temperature.gpu,fan.speed,power.draw,pstate`. All returned rc=0.
6. Across the 90-second window, GPU temperature dropped from 50C to 45C while persistence mode held; fan stayed at 30% under driver control. This is the first observed evidence on this stack that the AIB's thermal system is being actively driven.
7. Module refcount remained 5 throughout. No new `Xid`, `fallen off the bus`, `NV_ERR_GPU_IS_LOST`, AER, or hung-task entries appeared in the kernel log.

Interpretation:

- The freeze boundary identified earlier ("second open of `/dev/nvidia0` after a previous open+close in the same module-load session") is avoided when persistence mode keeps an open fd alive across `nvidia-smi` invocations. No `nvidia-smi` invocation is ever the first open of a clean device or the cause of a last close, so the close-side teardown that wedges the next open never runs.
- This is a vendor-supported configuration. `nvidia-persistenced` exists for exactly this purpose on workstations and servers that run `nvidia-smi` queries repeatedly. It is not a workaround in the sense of "user-side hack", though it does happen to mask a separate latent bug in the close path.
- The latent bug remains. If anything kills `nvidia-persistenced` while `nvidia` is loaded, the next `nvidia-smi` would again be a "first open after last close" and the freeze risk returns. So persistenced must be treated as load-bearing for thermal and operational stability whenever `nvidia` is bound.

User-visible target met:

- `nvidia-smi` runs as many times as the user wants without freezing.
- Fan and water cooling are active and modulated by the driver.
- The proprietary RPM Fusion userspace (`580.142`) is in use.
- The kernel module is the open kernel module variant required by Blackwell; the proprietary closed kernel module is not available for Blackwell from NVIDIA, so this is the most "proprietary" configuration possible on this GPU.

Pending to make this survive a reboot:

- `nvidia-persistenced.service` must start `After=aorus-5090-compute-load-nvidia.service` and depend on it. A systemd drop-in `/etc/systemd/system/nvidia-persistenced.service.d/aorus-egpu.conf` is the cleanest way.
- The compute-load service currently requires `/etc/aorus-5090-allow-compute-load` to be present at boot. That latch was added when even the first NVIDIA load could freeze the host; with persistence mode now solving the second-open problem, the latch is no longer required for safety - it can become a permanent file or be replaced with the existing `aorus-5090-compute-load-nvidia.service` enable state.
- A cold-boot validation pass is the right next step: enable the services, reboot, and check that `nvidia-smi` works from a fresh login without manual intervention.

Operational notes:

- Do not stop `nvidia-persistenced` while `nvidia` is loaded except as a deliberate diagnostic. Stopping it triggers a last close and, on the next user-process query, a freeze.
- If a future workflow needs to unload `nvidia` (kernel update, driver upgrade, deliberate reset), stop `nvidia-persistenced` first, then unload, then reload, then start persistenced again. The previous-boot kernel log earlier in this plan shows that an unload after NVML use can wedge the subsequent reload, so that sequence is currently risky and should be done with care, ideally from a TTY rather than under GNOME.
- CUDA workloads that maintain a long-lived `cuInit`'d context are expected to be safe alongside persistence. The wedge concern is open/close cycling on `/dev/nvidia0`; persistent CUDA processes do not exhibit that pattern.

# Future investigations

The current configuration works but masks rather than fixes a real bug. This document captures the open threads that could remove the workaround dependency or feed an upstream fix. None of these is required for the system to operate.

## 1. NVreg_DynamicPowerManagement=0 test

**Hypothesis:** even with D3cold blocked at the udev level, the NVIDIA driver's runtime PM path may still drive close-side teardown that wedges the next open of `/dev/nvidia0`. Setting `NVreg_DynamicPowerManagement=0` (current default on this stack: `3`, fine-grained PCIe-level PM) would disable that path entirely.

**Independent confirmation:** A second-opinion AI (Gemini, 2026-05-01) independently recommended this parameter. Its proposed mechanism (D3cold-on-idle wake failure) does not fit our evidence, but the parameter itself is a reasonable thing to test.

**Best case if it works:** persistenced stops being load-bearing. The system would survive `nvidia-smi` invocations even without persistenced running, removing a single point of failure.

**Worst case:** another freeze, no information gained beyond ruling out PM-on-close as the trigger.

**How to run safely:**

1. Cold boot to a clean state with the current configuration and the eGPU connected.
2. Stop persistenced cleanly: `sudo systemctl stop nvidia-persistenced.service`.
3. Unload `nvidia`: `sudo modprobe -r nvidia`. (Note: per the recovery plan, this can wedge after NVML use. Reboot first if NVML has been called this session.)
4. Bind with the variable:

   ```bash
   sudo /usr/local/sbin/aorus-5090-compute-load-nvidia
   # The loader does not currently expose this env var; either:
   #   a) edit the loader to accept AORUS_5090_DISABLE_DYNAMIC_PM=1
   #      and pass NVreg_DynamicPowerManagement=0 to modprobe; or
   #   b) bind once with the script, immediately unload, then manually
   #      modprobe nvidia NVreg_DynamicPowerManagement=0
   ```

5. Without persistenced running, run `nvidia-smi` twice in succession.
6. If both succeed: the parameter is the fix. Persist by adding the option to `/etc/modprobe.d/aorus-5090-compute-only.conf` (alongside the existing options). The compute-load loader can then drop persistenced from the requirement chain.
7. If the second `nvidia-smi` freezes: revert. Persistence-mode remains the only known mitigation.

The loader script already has `AORUS_5090_DISABLE_NONBLOCKING_OPEN` and `AORUS_5090_DISABLE_GSP` env-var hooks; adding `AORUS_5090_DISABLE_DYNAMIC_PM` is a few lines.

## 2. Upstream NVIDIA bug report

The captured artifacts from the 2026-05-01 investigation are unusually well-prepared for an upstream report. The core data is sufficient to identify the bug without further freezes.

**Repository:** https://github.com/NVIDIA/open-gpu-kernel-modules

**Title (suggested):** Kernel hangs in `open()` of `/dev/nvidia0` on second open after a previous open+close, RTX 5090 over Thunderbolt 4, kernel module 580.142

**Body outline:**

- Hardware: NUC 15 Pro+ (Intel TB4 host, JHL9480 retimer), AORUS GeForce RTX 5090 AI Box.
- Software: Fedora 42, kernel 6.19.14-100.fc42.x86_64, RPM Fusion `akmod-nvidia` 580.142 (loads as `NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64 580.142`).
- Reproducer: with `thunderbolt.host_reset=false`, BAR1 stable at 32 GiB, GPU bound to `nvidia`, no other NVIDIA modules loaded:

  ```bash
  python3 -c "import ctypes; n=ctypes.CDLL('libnvidia-ml.so.1'); n.nvmlInit_v2(); n.nvmlShutdown()"
  python3 -c "import ctypes; n=ctypes.CDLL('libnvidia-ml.so.1'); n.nvmlInit_v2()"   # <-- freezes
  ```

  First call returns rc=0 (init+shutdown both succeed). Second call hangs the host inside the kernel `open()` syscall on `/dev/nvidia0`. Forced reboot required.

- Boundary: ioctl trace shows no matching `open64_exit` for `/dev/nvidia0 flags=0x80802 (O_RDWR|O_NONBLOCK|O_CLOEXEC)`.
- Setting `NVreg_EnableNonblockingOpen=0` does not fix; it only relocates the hang from `NV_ESC_WAIT_OPEN_COMPLETE` ioctl into `open()` itself.
- The hang persists across `modprobe -r nvidia ; modprobe nvidia` - so the wedge state survives kernel module unload, suggesting GPU/GSP firmware state or an undocumented per-PCI-device structure.
- Workaround: keep `/dev/nvidia0` open via `nvidia-persistenced` so no "last close" ever runs.

**Attachments to include:**

- `archive/recovery-plan.md`
- `archive/next-diagnostic.md`
- `archive/diagnostic-tests/` (the ioctl tracer source, the test scripts, and the captured progress / ioctl logs from the 2026-05-01 freeze).
- A clean reproducer in 5-10 lines of C or Python.

This bug report does not require any further freeze tests on the user's hardware. All the data already exists.

## 3. Try kernel 6.20+ when available

Recent (2025-2026) Linux kernel work on Thunderbolt power management and PCIe authorization is ongoing. The same bug may have been fixed upstream after 6.19. If a newer kernel becomes available on Fedora 42 (or after a Fedora 43 upgrade), retest:

1. Install the new kernel.
2. Without changing anything else, reboot and run two `nvidia-smi` invocations without persistenced running.
3. If both succeed, the persistenced workaround can be relaxed (or kept as belt-and-suspenders).

## 4. Switcheroo / DRM exposure regression watch

Major Mesa / Wayland / GDM updates have, in the past, changed how `switcheroo-control` discovers GPUs. The current configuration depends on the eGPU not being exposed as a DRM device. After major Fedora updates, verify:

```bash
ls /sys/class/drm/card*
# Expected: card1: i915 only
```

If an NVIDIA DRM card appears, GNOME may still freeze on login. Re-check that `aorus-5090-compute-only.conf` is in place and effective.

## 5. CUDA workload close-path stress

We have only validated `nvidia-smi` (NVML) repeatability, not long-running CUDA workloads. A real vLLM or PyTorch run that hot-loads / unloads models may exercise a different close path. If you observe freezes during normal CUDA use, capture an ioctl trace of the workload using `archive/diagnostic-tests/aorus-5090-nvml-ioctl-trace.so` to identify the close boundary.

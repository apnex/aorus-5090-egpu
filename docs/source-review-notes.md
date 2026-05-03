# Open kernel module source review notes (Lever E)

Working notes from reviewing the NVIDIA open-gpu-kernel-modules source at the
exact tag we run (`595.71.05`). Goal: localise the offending code path that
makes our `cuCtxCreate_v2`-triggers-host-freeze on Blackwell-over-Thunderbolt
on the Linux open module, given Lever G has confirmed the Windows nvlddmkm.sys
path on the same hardware works flawlessly.

Status: 2026-05-03 evening — first pass. Three hypotheses identified, one
concrete additional experimental lever (Lever H — RM-internal timeout
override) found.

## Repository

- Cloned `NVIDIA/open-gpu-kernel-modules`, checked out tag `595.71.05` (matches
  our installed driver byte-for-byte).
- Lives at `/root/nvidia-open-src/` (outside this repo, not committed).
- Two large directory trees:
  - `kernel-open/` (9.2 MB) — kernel module shim layer (nvidia.ko, nvidia-uvm.ko,
    nvidia-drm.ko, etc.)
  - `src/` (119 MB) — the Resource Manager (RM) — the meat of the driver

## Finding 1: eGPU detection has shallow penetration — *not* the bug

The `RmCheckForExternalGpu()` logic in `osinit.c` walks PCIe bridges, looks for
TB3-approved Intel bridges with HotPlug+/Surprise+ slot caps, and on success
sets `PDB_PROP_GPU_IS_EXTERNAL_GPU = TRUE`. PR #984 patches this to add
`NVreg_ForceExternalGpu` which we already enable via `NVreg_RegistryDwords`.

But even with the property set, the rest of the driver only reads it in
**four places**, and they're cosmetic:

| File:line | What it does |
|---|---|
| `osinit.c:400` | On error/RC recovery path, sets `NV_FLAG_IN_SURPRISE_REMOVAL` |
| `osinit.c:1335` | Where the property is set after detection |
| `kern_perf.c` | Skips `pfmreqhndlrStateLoad` (Platform Request Handler) on eGPU |
| `subdevice_ctrl_gpu_kernel.c` | Reports `SURPRISE_REMOVAL_POSSIBLE` to userspace |

Plus one PCI-side gating in `nv-pci.c:2324` — sanity check on device removal
with non-zero usage count, suppressed for eGPU.

**Takeaway:** the eGPU property doesn't change much. The bug is not in
"different code path on eGPU." It must be in code that's broken regardless,
that just happens to manifest on Blackwell × tunneled-PCIe.

## Finding 2: Blackwell-specific code surface is tractably small

UVM Blackwell HAL (`kernel-open/nvidia-uvm/`):

| File | Lines | Purpose |
|---|---:|---|
| `uvm_blackwell.c` | 157 | Arch init properties (TLB sizing, fault buffer params, VA layout) |
| `uvm_blackwell_ce.c` | 77 | Copy Engine validator only — not init/setup |
| `uvm_blackwell_fault_buffer.c` | 122 | Page fault buffer handling |
| `uvm_blackwell_host.c` | 381 | Host channel logic |
| `uvm_blackwell_mmu.c` | 188 | MMU + page tables |

Total Blackwell-specific UVM code: **~1000 lines**. That's a humanly-readable
surface area. Hopper has the same set plus a `uvm_hopper_sec2.c`; Blackwell
absorbs SEC2 elsewhere.

GSP host side has dedicated Blackwell file `kernel_gsp_gb100.c` for
arch-specific bootstrap and reset, plus shared `kernel_gsp.c` (4752+ lines)
and `message_queue_cpu.c` for the CPU↔GSP RPC channel.

`kernel-open/nvidia/nv-pci.c:514` has a comment that flags Blackwell-specific
BAR enumeration handling: *"Starting from Blackwell BAR1 will be the real
BAR1."* This is a known platform-specific change point.

## Finding 3: GSP-RPC default timeout is 2-30s, scaled per platform, overridable

`gpu_timeout.h:40-50`:

```c
#define GPU_TIMEOUT_DEFAULT  0
//
// GPU_TIMEOUT_DEFAULT is different per platform and can range anywhere
// from 2 to 30 secs depending on the GPU Mode and Platform.
//
```

`GPU_TIMEOUT_DEFAULT = 0` is a magic value meaning "use the platform default";
the actual value lives in `pGpu->timeoutData.defaultus` (microseconds).

GSP heartbeat timeouts derive from this default, with a 30% margin:

```c
// kernel_gsp.c:2261
pKernelGsp->gspRmHeartbeatTimeoutMs = defaultTimeoutMs + ((defaultTimeoutMs / 10) * 3);
```

So if the Linux platform default is 4s, GSP heartbeat fires at 5.2s.
TB-tunneled PCIe has higher round-trip latency than internal PCIe; a CUDA
context-create that takes longer than this on the GPU side could cause GSP
to think it's stalled.

**Initialization path** (`gpu_timeout.c:60-83`):

```c
osGetTimeoutParams(pGpu, &timeoutDefault, &(pTD->scale), &(pTD->defaultFlags));
pTD->defaultus = timeoutDefault;
...
pTD->defaultus = gpuScaleTimeout(pGpu, pTD->defaultus);  // platform-scaled
```

So the actual timeout depends on `osGetTimeoutParams` (Linux-specific) and a
HAL-dispatched `gpuScaleTimeout`. Worth chasing both — particularly whether
either has eGPU-aware behaviour.

## Finding 4: There IS a registry override mechanism for RM-internal timeouts

In `nvrm_registry.h:105-124`:

```c
// Change all RM internal timeouts to experiment with Bug 5203024.
#define NV_REG_STR_RM_BUG5203024_OVERRIDE_TIMEOUT        "RmOverrideInternalTimeoutsMs"
//
// Bit fields:
//   Value bits 23:0   — timeout value in ms
//   Bit 31            — set RM default timeout
//   Bit 30            — set RC watchdog timeout
//   Bit 29            — set context-switch timeout
//   Bit 28            — set video-engine timeout
//   Bit 27            — set PMU internal timeout
//   Bit 26            — set FECS watchdog timeout
```

This is **a concrete additional experimental lever (Lever H)**. The mention of
"Bug 5203024" suggests NVIDIA has an internal ticket about timeout tuning.
We can set this via `NVreg_RegistryDwords` exactly the way we set
`RmForceExternalGpu`. Example to bump RM default + RC watchdog to 30s:

```
options nvidia NVreg_RegistryDwords="RmForceExternalGpu=1;RmOverrideInternalTimeoutsMs=0xC0007530"
```

Where `0xC0007530` = bits 31+30 set (`0xC0000000`) + 30000 ms (`0x7530`).

**Why this is interesting for our bug:** if the Linux open module's CUDA-context
init takes longer over TB-tunneled PCIe than the platform default expects,
RM's internal timeout fires while waiting for a GSP-RPC reply, the
recovery path tries to teardown a half-initialized context, and that
teardown deadlocks the kernel. Bumping the timeout would defer the
deadlock-trigger timeout-fire and may produce a clean failure (or even
a clean success) rather than a host hang.

## Hypotheses (ranked)

### H1 — RM/GSP-RPC default timeout fires under TB latency

Plausibility: **medium-high**. Consistent with `nvidia-smi` working (read-only,
short paths) but `cuCtxCreate_v2` failing (long initialization with multiple
GSP RPCs, more likely to exceed the timeout). Consistent with the
"unicorn boot" pattern jciolek reported (#979 comment 14) — same hardware,
sometimes works for hours, sometimes fails immediately, suggesting a
race/timing edge case rather than a hard logic bug.

**Test:** Lever H. Set `NVreg_RegistryDwords` to bump RM default timeout
to 30s. If ollama runs longer / fails differently / no longer hard-locks,
strong evidence. Cheap, fully reversible.

### H2 — Blackwell-specific code path mishandles tunneled-PCIe BAR1 size

Plausibility: **medium**. `nv-pci.c` flags Blackwell-specific BAR layout
changes. Several #979 reporters have BAR1 capped at 256 MB on consumer-BIOS
Linux setups despite the GPU supporting 16 GB resize. CUDA's DMA-map could
have an assumption that breaks when BAR1 is smaller than expected on
Blackwell.

**Test:** read `uvm_blackwell_mmu.c` for BAR1 / DMA-map assumptions. Compare
against `uvm_hopper_mmu.c`. Trace what happens when DMA-map fails on the
context-create path. (Read-only.)

### H3 — Pre-existing close-path bug from Lever B/C/D era is the actual trigger

Plausibility: **low-medium, but cheap to rule out**. We already document
in `architecture.md` that `/dev/nvidia0` and `/dev/nvidia-uvm` close-paths
cause kernel hangs; we mitigate with persistenced + UVM keep-alive. If
the close-path inside the kernel fires DURING `cuCtxCreate_v2`'s error/
retry path, we'd see exactly the silent hang we observe.

**Test:** instrument `osinit.c:400` (the SURPRISE_REMOVAL flag set). If
that path is being hit during normal init (not error), our error-path
hypothesis would localise the trigger. (Read-only first; instrumentation
later.)

## Hypotheses considered and downranked

- **eGPU-gated code paths:** ruled out (Finding 1, only 4 cosmetic read sites).
- **Copy Engine init:** `uvm_blackwell_ce.c` is just an arg validator; CE
  init is shared. Not Blackwell-specific in a way that suggests a bug.
- **GSP firmware bug:** Lever G ruled this out — Windows driver uses the
  same GSP firmware blob on the same GPU, runs cleanly through 27B model
  loads.

## Recommended next steps

1. **Lever H — runtime experiment.** Set `RmOverrideInternalTimeoutsMs` to 30s
   for RM-default + RC watchdog. Reboot, re-run ollama lite test. If freeze
   pattern changes (no hang, longer runs, different error), H1 confirmed.
   ~1 hour of work + reboot, fully reversible (just remove the option).
2. **Continued source review.** Read `uvm_blackwell_mmu.c` (188 lines) end
   to end for BAR/DMA assumptions; read `kgspBootstrap_GB100` or
   `kgspBootstrap_HAL` dispatch for what happens during cuCtxCreate's GSP
   handshake; map the exact RPC sequence. ~1-2 hours, read-only.
3. **`gpuScaleTimeout` on Blackwell.** Check if Blackwell HAL scales the
   default timeout differently than other arches. ~30 min, read-only.
4. **Compare 595.71.05 vs newer driver branches (596+).** Check
   `git log -- src/nvidia/src/kernel/gpu/gsp/` and `git log -- kernel-open/
   nvidia-uvm/uvm_blackwell*` between 595 and HEAD for any Blackwell × TB
   fixes that haven't landed in our branch yet. ~30 min.

## Cross-references in this repo

- `freeze-investigation-plan.md` — top-level investigation plan; Lever E
  (this notes file) is now in-progress. Lever H should be added to the
  plan once we decide whether to run it.
- `architecture.md` — original close-path bug characterization (relevant
  to H3).

## File-and-line index of interesting locations

For future cold-pickup. All paths relative to the cloned repo root.

| Location | What lives here |
|---|---|
| `src/nvidia/arch/nvalloc/unix/src/osinit.c:425-528` | `RmCheckForExternalGpu()` — eGPU detection logic |
| `src/nvidia/arch/nvalloc/unix/src/osinit.c:1335` | Where `PDB_PROP_GPU_IS_EXTERNAL_GPU` is set |
| `src/nvidia/src/kernel/gpu/perf/kern_perf.c` | Platform Request Handler skip-on-eGPU |
| `src/nvidia/inc/kernel/gpu/gpu_timeout.h:40` | `GPU_TIMEOUT_DEFAULT` definition + 2-30s comment |
| `src/nvidia/src/kernel/gpu/gpu_timeout.c:44` | `timeoutInitializeGpuDefault()` |
| `src/nvidia/src/kernel/gpu/gpu_timeout.c:111` | `timeoutRegistryOverride()` |
| `src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c:2261` | GSP heartbeat timeout derivation |
| `src/nvidia/src/kernel/gpu/gsp/message_queue_cpu.c:461` | `GspMsgQueueSendCommand()` — RPC TX with timeout |
| `src/nvidia/interface/nvrm_registry.h:105-124` | `RmOverrideInternalTimeoutsMs` registry key + bit fields |
| `src/nvidia/src/kernel/gpu/gsp/arch/blackwell/kernel_gsp_gb100.c` | Blackwell GSP bootstrap + reset |
| `kernel-open/nvidia-uvm/uvm_blackwell*.c` | Blackwell UVM HAL (~1000 lines total) |
| `kernel-open/nvidia/nv-pci.c:514` | Blackwell-specific BAR layout comment |

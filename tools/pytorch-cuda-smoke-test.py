#!/usr/bin/env python3
"""PyTorch CUDA smoke test for the AORUS RTX 5090 eGPU stack.

Validates the path that vLLM actually uses: torch.cuda runtime init,
device tensor allocation, real CUDA kernels (cuBLAS GEMM), sync, and
deterministic correctness check.

Exits 0 with 'pytorch_smoke=pass' on success. On any failure prints
which step failed and exits non-zero.

Run from inside a venv that has 'torch' installed:
    /root/torch-test/bin/python3 tools/pytorch-cuda-smoke-test.py

Or via the TTY runner:
    tools/tty-pytorch-test.sh
"""
import sys


def fail(stage, exc=None):
    if exc is None:
        print(f"{stage}=FAIL", flush=True)
    else:
        print(f"{stage}=FAIL {type(exc).__name__}: {exc}", flush=True)
    sys.exit(1)


def main():
    # 1. Import torch
    try:
        import torch
    except Exception as e:
        fail("import_torch", e)
    print(f"torch_version={torch.__version__}", flush=True)
    print(f"torch_cuda_version={torch.version.cuda}", flush=True)

    # 2. CUDA available
    if not torch.cuda.is_available():
        fail("cuda_available")
    print("cuda_available=ok", flush=True)

    # 3. Device enumeration
    try:
        dc = torch.cuda.device_count()
    except Exception as e:
        fail("device_count", e)
    print(f"device_count={dc}", flush=True)
    if dc < 1:
        fail("device_count_zero")

    try:
        name = torch.cuda.get_device_name(0)
    except Exception as e:
        fail("device_name", e)
    print(f"device_name={name}", flush=True)

    try:
        cap_major, cap_minor = torch.cuda.get_device_capability(0)
    except Exception as e:
        fail("device_capability", e)
    print(f"compute_capability={cap_major}.{cap_minor}", flush=True)

    d = torch.device("cuda:0")

    # 4. Allocate deterministic tensors on CUDA
    print("before_tensor_alloc=ok", flush=True)
    try:
        a = torch.ones(1024, 1024, device=d, dtype=torch.float32)
        b = torch.ones(1024, 1024, device=d, dtype=torch.float32)
    except Exception as e:
        fail("tensor_alloc", e)
    print("after_tensor_alloc=ok", flush=True)

    # 5. cuBLAS GEMM with deterministic input - product of two ones-matrices
    # of shape NxN is an NxN matrix where every element is N. This avoids
    # comparing against a CPU reference (slow, precision-dependent) while
    # still exercising the actual GEMM kernel.
    print("before_mm=ok", flush=True)
    try:
        c = torch.mm(a, b)
        torch.cuda.synchronize()
    except Exception as e:
        fail("mm_or_sync", e)
    print("after_mm=ok", flush=True)

    # 6. Verify result. Every element should be exactly 1024.0.
    expected = 1024.0
    try:
        actual = c[0, 0].item()
        max_val = c.max().item()
        min_val = c.min().item()
    except Exception as e:
        fail("read_result", e)
    print(f"mm_result_first_element={actual}", flush=True)
    print(f"mm_result_min={min_val} max={max_val}", flush=True)
    if abs(actual - expected) > 0.01 or max_val != actual or min_val != actual:
        fail("mm_result_mismatch")
    print("mm_correct=ok", flush=True)

    # 7. Memory stats
    try:
        alloc = torch.cuda.memory_allocated(0)
        reserved = torch.cuda.memory_reserved(0)
    except Exception as e:
        fail("memory_stats", e)
    print(f"memory_allocated_bytes={alloc}", flush=True)
    print(f"memory_reserved_bytes={reserved}", flush=True)

    # 8. Cleanup. Do NOT call torch.cuda.empty_cache() - we want to validate
    # that the normal del-and-let-GC path works without exercising the cache
    # release code path.
    del a, b, c

    print("pytorch_smoke=pass", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

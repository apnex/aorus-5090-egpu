#!/usr/bin/env python3
import ctypes
import os
import sys
import time


progress_path = sys.argv[1] if len(sys.argv) > 1 else "/root/aorus-5090-nvml-init-probe-progress.txt"


def mark(message):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}\n"
    with open(progress_path, "a", encoding="utf-8") as handle:
        handle.write(line)
        handle.flush()
        os.fsync(handle.fileno())
    print(message, flush=True)


def call(name, fn):
    mark(f"before {name}")
    rc = fn()
    mark(f"after {name} rc={rc}")
    return rc


def main():
    mark("before load libnvidia-ml.so.1")
    nvml = ctypes.CDLL("libnvidia-ml.so.1")
    mark("after load libnvidia-ml.so.1")

    init = getattr(nvml, "nvmlInit_v2", nvml.nvmlInit)
    init.argtypes = []
    init.restype = ctypes.c_int

    shutdown = nvml.nvmlShutdown
    shutdown.argtypes = []
    shutdown.restype = ctypes.c_int

    rc = call(init.__name__, init)
    if rc != 0:
        return rc

    return call("nvmlShutdown", shutdown)


if __name__ == "__main__":
    raise SystemExit(main())

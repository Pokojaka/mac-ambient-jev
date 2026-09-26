from __future__ import annotations

from typing import Any


def begin_cuda_measurement(
    device: str,
    *,
    torch_module: Any | None = None,
):
    if not device.startswith("cuda"):
        return None

    if torch_module is None:
        try:
            import torch as torch_module
        except ImportError:
            return None

    if not torch_module.cuda.is_available():
        return None

    torch_module.cuda.synchronize(device)
    torch_module.cuda.reset_peak_memory_stats(device)
    return torch_module


def end_cuda_measurement(
    device: str,
    token,
) -> float | None:
    if token is None or not device.startswith("cuda"):
        return None

    token.cuda.synchronize(device)
    allocated = token.cuda.max_memory_allocated(device)
    return allocated / (1024 * 1024)

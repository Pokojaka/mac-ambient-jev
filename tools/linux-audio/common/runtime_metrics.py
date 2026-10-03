from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, TypeVar


Model = TypeVar("Model")
Result = TypeVar("Result")

BYTES_PER_MB = 1024 * 1024


def is_cuda_device(device: str) -> bool:
    if device == "cpu":
        return False
    if device == "cuda" or device.startswith("cuda:"):
        return True
    raise ValueError(
        f"unsupported device {device!r}: expected cpu, cuda, or cuda:N"
    )


@dataclass(frozen=True)
class RuntimeMeasurement:
    model_load_seconds: float
    inference_seconds: float
    resident_vram_mb: float | None
    peak_vram_mb: float | None


class CudaMemoryProbe:
    def __init__(self, device: str) -> None:
        import torch

        if not torch.cuda.is_available():
            raise RuntimeError(
                f"device {device!r} was requested but CUDA is unavailable"
            )
        self._cuda: Any = torch.cuda
        self._device = device

    def allocated_mb(self) -> float:
        self._cuda.synchronize(self._device)
        return self._cuda.memory_allocated(self._device) / BYTES_PER_MB

    def reset_peak(self) -> None:
        self._cuda.synchronize(self._device)
        self._cuda.reset_peak_memory_stats(self._device)

    def peak_mb(self) -> float:
        self._cuda.synchronize(self._device)
        return self._cuda.max_memory_allocated(self._device) / BYTES_PER_MB


def measure_load_and_inference(
    *,
    device: str,
    load: Callable[[], Model],
    infer: Callable[[Model], Result],
) -> tuple[Result, RuntimeMeasurement]:
    """Times the cold load and the warm inference separately.

    On CUDA, resident_vram_mb is the allocation right after loading and
    peak_vram_mb is the allocation peak observed during inference.
    """
    probe = CudaMemoryProbe(device) if is_cuda_device(device) else None

    load_started = time.perf_counter()
    model = load()
    loaded = time.perf_counter()
    resident_vram_mb = None
    if probe is not None:
        resident_vram_mb = probe.allocated_mb()
        probe.reset_peak()
    inference_started = time.perf_counter()
    result = infer(model)
    peak_vram_mb = probe.peak_mb() if probe is not None else None
    finished = time.perf_counter()

    return result, RuntimeMeasurement(
        model_load_seconds=loaded - load_started,
        inference_seconds=finished - inference_started,
        resident_vram_mb=resident_vram_mb,
        peak_vram_mb=peak_vram_mb,
    )

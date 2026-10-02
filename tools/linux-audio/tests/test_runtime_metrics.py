from __future__ import annotations

import sys
import types

import pytest

from common.runtime_metrics import measure_load_and_inference


class FakeCuda:
    def __init__(self, *, available: bool = True):
        self.available = available
        self.allocated = 0
        self.peak = 0

    def is_available(self):
        return self.available

    def synchronize(self, device):
        pass

    def memory_allocated(self, device):
        return self.allocated

    def reset_peak_memory_stats(self, device):
        self.peak = self.allocated

    def max_memory_allocated(self, device):
        return self.peak


def install_fake_torch(monkeypatch, cuda: FakeCuda) -> None:
    monkeypatch.setitem(
        sys.modules,
        "torch",
        types.SimpleNamespace(cuda=cuda),
    )


def test_cuda_measurement_separates_resident_and_inference_peak(
    monkeypatch,
):
    cuda = FakeCuda()
    install_fake_torch(monkeypatch, cuda)
    mb = 1024 * 1024

    def load():
        cuda.allocated = 100 * mb
        cuda.peak = 400 * mb
        return "model"

    def infer(model):
        assert model == "model"
        cuda.peak = 250 * mb
        return "result"

    result, measurement = measure_load_and_inference(
        device="cuda:0",
        load=load,
        infer=infer,
    )

    assert result == "result"
    assert measurement.resident_vram_mb == 100.0
    assert measurement.peak_vram_mb == 250.0
    assert measurement.model_load_seconds >= 0
    assert measurement.inference_seconds >= 0


def test_cuda_request_without_cuda_fails_before_loading(monkeypatch):
    install_fake_torch(monkeypatch, FakeCuda(available=False))
    loaded = []

    with pytest.raises(RuntimeError, match="CUDA is unavailable"):
        measure_load_and_inference(
            device="cuda:0",
            load=lambda: loaded.append(True),
            infer=lambda model: model,
        )
    assert loaded == []


def test_cuda_request_without_torch_fails(monkeypatch):
    monkeypatch.setitem(sys.modules, "torch", None)

    with pytest.raises(ImportError):
        measure_load_and_inference(
            device="cuda",
            load=lambda: None,
            infer=lambda model: model,
        )


def test_cpu_measurement_records_no_vram(monkeypatch):
    monkeypatch.setitem(sys.modules, "torch", None)

    result, measurement = measure_load_and_inference(
        device="cpu",
        load=lambda: 2,
        infer=lambda model: model * 3,
    )

    assert result == 6
    assert measurement.resident_vram_mb is None
    assert measurement.peak_vram_mb is None


def test_unsupported_device_is_rejected():
    with pytest.raises(ValueError, match="unsupported device"):
        measure_load_and_inference(
            device="mps",
            load=lambda: None,
            infer=lambda model: model,
        )

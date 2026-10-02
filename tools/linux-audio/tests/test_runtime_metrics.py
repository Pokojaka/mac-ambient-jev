from __future__ import annotations

from common.runtime_metrics import (
    begin_cuda_measurement,
    end_cuda_measurement,
)


class FakeCuda:
    def __init__(self):
        self.calls = []

    def is_available(self):
        return True

    def synchronize(self, device):
        self.calls.append(("sync", device))

    def reset_peak_memory_stats(self, device):
        self.calls.append(("reset", device))

    def max_memory_allocated(self, device):
        self.calls.append(("peak", device))
        return 10 * 1024 * 1024


class FakeTorch:
    def __init__(self):
        self.cuda = FakeCuda()


def test_cuda_measurement_synchronizes_and_reports_peak_mb():
    torch = FakeTorch()

    token = begin_cuda_measurement(
        "cuda:0",
        torch_module=torch,
    )
    assert token is torch
    assert torch.cuda.calls == [
        ("sync", "cuda:0"),
        ("reset", "cuda:0"),
    ]

    peak = end_cuda_measurement(
        "cuda:0",
        token,
    )

    assert peak == 10.0
    assert torch.cuda.calls[-2:] == [
        ("sync", "cuda:0"),
        ("peak", "cuda:0"),
    ]


def test_cpu_measurement_does_not_probe_cuda():
    assert begin_cuda_measurement("cpu") is None
    assert end_cuda_measurement("cpu", None) is None

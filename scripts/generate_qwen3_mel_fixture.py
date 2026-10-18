#!/usr/bin/env python3

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import librosa
import numpy as np

SAMPLE_RATE = 16_000
FFT_SIZE = 400
HOP_SIZE = 160
MEL_COUNT = 128
MINIMUM_LOG_POWER = 1e-10


def make_cases() -> list[tuple[str, np.ndarray]]:
    sine_count = SAMPLE_RATE
    sine_time = np.arange(sine_count, dtype=np.float64) / SAMPLE_RATE
    sine = 0.5 * np.sin(2 * np.pi * 440 * sine_time) + 0.2 * np.sin(2 * np.pi * 1_000 * sine_time)

    chirp_count = 3_791
    chirp_duration = chirp_count / SAMPLE_RATE
    chirp_time = np.arange(chirp_count, dtype=np.float64) / SAMPLE_RATE
    chirp_phase = 2 * np.pi * (
        180 * chirp_time + 0.5 * ((6_200 - 180) / chirp_duration) * chirp_time**2
    )
    chirp = 0.4 * np.sin(chirp_phase)

    short_count = 4_800
    short_time = np.arange(short_count, dtype=np.float64) / SAMPLE_RATE
    short_sine = 0.5 * np.sin(2 * np.pi * 440 * short_time) + 0.2 * np.sin(
        2 * np.pi * 1_000 * short_time
    )
    short_envelope = 1 - short_time / 0.3
    short = short_sine * short_envelope

    last_frame_peak = np.zeros(480, dtype=np.float64)
    last_frame_peak[-1] = 1_000

    minimum_reflect = np.arange(201, dtype=np.float64) / 200 - 0.5

    return [
        ("sine_mix", sine.astype(np.float32)),
        ("chirp", chirp.astype(np.float32)),
        ("short_0_3s", short.astype(np.float32)),
        ("last_frame_peak", last_frame_peak.astype(np.float32)),
        ("minimum_reflect", minimum_reflect.astype(np.float32)),
    ]


def rounded_values(values: np.ndarray) -> list[float]:
    rounded = [round(float(value), 6) for value in values.ravel(order="C")]
    return [0.0 if value == 0 else value for value in rounded]


def make_fixture_case(name: str, input_samples: np.ndarray, mel_filters: np.ndarray, window: np.ndarray) -> dict:
    audio = np.asarray(input_samples, dtype=np.float32)
    sample_count = int(audio.size)
    frame_count = sample_count // HOP_SIZE
    pre_drop_frame_count = frame_count + 1
    if sample_count < FFT_SIZE // 2 + 1:
        raise AssertionError(f"{name} is too short for reflect padding")

    padded_audio = np.pad(audio, (FFT_SIZE // 2, FFT_SIZE // 2), mode="reflect")
    frames = np.stack(
        [
            padded_audio[frame_index * HOP_SIZE : frame_index * HOP_SIZE + FFT_SIZE]
            for frame_index in range(pre_drop_frame_count)
        ]
    ).astype(np.float64, copy=False)
    if frames.shape != (pre_drop_frame_count, FFT_SIZE):
        raise AssertionError(f"{name} has unexpected frame shape: {frames.shape}")

    spectrum = np.fft.rfft(frames * window[np.newaxis, :], n=FFT_SIZE, axis=1)
    power = spectrum.real * spectrum.real + spectrum.imag * spectrum.imag
    mel_power = mel_filters @ power.T
    log_mel = np.log10(np.maximum(mel_power, MINIMUM_LOG_POWER))
    if not np.isfinite(log_mel).all():
        raise AssertionError(f"{name} produced non-finite log-mel values")

    global_max_before_drop = float(np.max(log_mel))
    global_max_retained = float(np.max(log_mel[:, :-1]))
    # The reference stays float64 after float32 input quantization; Float32 runtime tests need 1e-4 tolerance.
    normalized = (np.maximum(log_mel, global_max_before_drop - 8) + 4) / 4
    if not np.isfinite(normalized).all():
        raise AssertionError(f"{name} produced non-finite normalized values")

    sample_bytes = audio.astype(np.dtype("<f4"), copy=False).tobytes(order="C")
    case = {
        "name": name,
        "sample_count": sample_count,
        "frame_count": frame_count,
        "pre_drop_frame_count": pre_drop_frame_count,
        "samples_f32le_base64": base64.b64encode(sample_bytes).decode("ascii"),
        "values": rounded_values(normalized[:, :-1]),
        "dropped_frame_values": rounded_values(normalized[:, -1]),
        "global_max_before_drop": global_max_before_drop,
        "global_max_retained": global_max_retained,
    }
    if len(case["values"]) != MEL_COUNT * frame_count:
        raise AssertionError(f"{name} output length does not match its frame count")
    if len(case["dropped_frame_values"]) != MEL_COUNT:
        raise AssertionError(f"{name} dropped frame does not contain {MEL_COUNT} values")
    return case


def main() -> None:
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError(f"Python 3.12 is required, got {sys.version_info.major}.{sys.version_info.minor}")
    if len(sys.argv) != 1:
        raise RuntimeError("this script does not accept arguments")

    mel_filters = librosa.filters.mel(
        sr=SAMPLE_RATE,
        n_fft=FFT_SIZE,
        n_mels=MEL_COUNT,
        fmin=0,
        fmax=8_000,
        htk=False,
        norm="slaney",
        dtype=np.float32,
    ).astype(np.float64)
    window_indices = np.arange(FFT_SIZE, dtype=np.float64)
    window = 0.5 - 0.5 * np.cos(2 * np.pi * window_indices / FFT_SIZE)

    cases = [make_fixture_case(name, samples, mel_filters, window) for name, samples in make_cases()]
    peak_case = next(case for case in cases if case["name"] == "last_frame_peak")
    if peak_case["global_max_before_drop"] <= peak_case["global_max_retained"]:
        raise AssertionError("last_frame_peak must have a dropped-frame global maximum")

    fixture = {
        "numpy_version": np.__version__,
        "librosa_version": librosa.__version__,
        "sample_rate": SAMPLE_RATE,
        "n_fft": FFT_SIZE,
        "hop": HOP_SIZE,
        "n_mels": MEL_COUNT,
        "cases": cases,
    }
    repository_root = Path(__file__).resolve().parents[1]
    destination = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_mel_golden.json"
    )
    destination.write_text(
        json.dumps(fixture, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(destination)
    for case in cases:
        print(
            f"{case['name']}: samples={case['sample_count']} frames={case['frame_count']} "
            f"pre_drop_frames={case['pre_drop_frame_count']}"
        )
    print(f"numpy={np.__version__} librosa={librosa.__version__}")


if __name__ == "__main__":
    main()

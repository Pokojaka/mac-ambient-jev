#!/usr/bin/env python3

from __future__ import annotations

import base64
import importlib.metadata
import json
import sys
from pathlib import Path

import librosa
import numpy as np
import torch
import whisper
from transformers import WhisperFeatureExtractor

SAMPLE_RATE = 16_000
FFT_SIZE = 400
HOP_SIZE = 160
MEL_COUNT = 128
DIRECT_DEPENDENCIES = {
    "librosa": "0.11.0",
    "numpy": "2.2.6",
    "openai-whisper": "20250625",
    "torch": "2.8.0",
    "transformers": "4.57.1",
}
TRANSFORMERS_SOURCE_URL = (
    "https://raw.githubusercontent.com/huggingface/transformers/v4.57.1/"
    "src/transformers/models/whisper/feature_extraction_whisper.py"
)
WHISPER_SOURCE_URL = "https://raw.githubusercontent.com/openai/whisper/v20250625/whisper/audio.py"
# Float32 torch window/FFT noise differs; this is not a bitwise-parity tolerance.
WHISPER_CROSS_CHECK_TOLERANCE = 5e-5


def installed_versions() -> dict[str, str]:
    versions: dict[str, str] = {}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name")
        if not name:
            raise RuntimeError("installed distribution is missing its package name")
        if name in versions:
            raise RuntimeError(f"duplicate installed distribution name: {name}")
        versions[name] = distribution.version
    return dict(sorted(versions.items(), key=lambda item: item[0].casefold()))


def validate_environment() -> dict[str, str]:
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError(
            f"Python 3.12 is required, got {sys.version_info.major}.{sys.version_info.minor}"
        )

    versions = installed_versions()
    for package, required_version in DIRECT_DEPENDENCIES.items():
        actual_version = versions.get(package)
        if actual_version != required_version:
            raise RuntimeError(
                f"{package}=={required_version} is required, got {actual_version!r}"
            )
    return versions


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

    dropped_only_peak = np.zeros(559, dtype=np.float32)
    dropped_only_peak[-1] = 1_000

    return [
        ("sine_mix", sine.astype(np.float32)),
        ("chirp", chirp.astype(np.float32)),
        ("short_0_3s", short.astype(np.float32)),
        ("last_frame_peak", last_frame_peak.astype(np.float32)),
        ("minimum_reflect", minimum_reflect.astype(np.float32)),
        ("dropped_only_peak", dropped_only_peak),
    ]


def verify_mel_filters(extractor: WhisperFeatureExtractor) -> float:
    extractor_filters = np.asarray(extractor.mel_filters, dtype=np.float64)
    librosa_filters = librosa.filters.mel(
        sr=SAMPLE_RATE,
        n_fft=FFT_SIZE,
        n_mels=MEL_COUNT,
        fmin=0,
        fmax=8_000,
        htk=False,
        norm="slaney",
        dtype=np.float64,
    )
    expected_shape = (FFT_SIZE // 2 + 1, MEL_COUNT)
    if extractor_filters.shape != expected_shape:
        raise RuntimeError(
            f"transformers mel filter shape {extractor_filters.shape} != {expected_shape}"
        )
    librosa_shape = (MEL_COUNT, FFT_SIZE // 2 + 1)
    if librosa_filters.shape != librosa_shape:
        raise RuntimeError(f"librosa mel filter shape {librosa_filters.shape} != {librosa_shape}")
    if not np.isfinite(extractor_filters).all() or not np.isfinite(librosa_filters).all():
        raise RuntimeError("mel filters contain non-finite values")
    librosa_filters = librosa_filters.T
    np.testing.assert_allclose(extractor_filters, librosa_filters, rtol=1e-12, atol=1e-15)
    return float(np.max(np.abs(extractor_filters - librosa_filters)))


def make_fixture_case(
    name: str, input_samples: np.ndarray, extractor: WhisperFeatureExtractor
) -> dict[str, object]:
    audio = np.asarray(input_samples)
    if audio.dtype != np.float32 or audio.ndim != 1 or audio.size == 0:
        raise RuntimeError(f"{name} input must be a non-empty one-dimensional Float32 array")
    if not np.isfinite(audio).all():
        raise RuntimeError(f"{name} input contains non-finite samples")

    official_values = np.asarray(
        extractor._np_extract_fbank_features(audio[np.newaxis, :], device="cpu")[0]
    )
    expected_frame_count = int(audio.size) // HOP_SIZE
    expected_shape = (MEL_COUNT, expected_frame_count)
    if official_values.shape != expected_shape:
        raise RuntimeError(f"{name} output shape {official_values.shape} != {expected_shape}")
    if not np.isfinite(official_values).all():
        raise RuntimeError(f"{name} output contains non-finite values")

    sample_bytes = audio.astype(np.dtype("<f4"), copy=False).tobytes(order="C")
    return {
        "name": name,
        "sample_count": int(audio.size),
        "frame_count": expected_frame_count,
        "samples_f32le_base64": base64.b64encode(sample_bytes).decode("ascii"),
        "values": [float(value) for value in official_values.ravel(order="C")],
    }


def verify_whisper_cross_check(
    cases: list[tuple[str, np.ndarray]],
    fixture_cases: list[dict[str, object]],
) -> float:
    chirp = next(samples for name, samples in cases if name == "chirp")
    official_chirp = next(case for case in fixture_cases if case["name"] == "chirp")
    official_values = np.asarray(official_chirp["values"], dtype=np.float64).reshape(
        MEL_COUNT, int(official_chirp["frame_count"])
    )
    whisper_values = whisper.log_mel_spectrogram(
        torch.from_numpy(chirp), n_mels=MEL_COUNT, padding=0, device="cpu"
    ).detach().cpu().numpy()
    if whisper_values.shape != official_values.shape:
        raise RuntimeError(
            f"openai-whisper chirp shape {whisper_values.shape} != {official_values.shape}"
        )
    if not np.isfinite(whisper_values).all():
        raise RuntimeError("openai-whisper chirp output contains non-finite values")
    max_abs_difference = float(np.max(np.abs(whisper_values - official_values)))
    if max_abs_difference > WHISPER_CROSS_CHECK_TOLERANCE:
        raise RuntimeError(
            "openai-whisper chirp max abs difference "
            f"{max_abs_difference} exceeds {WHISPER_CROSS_CHECK_TOLERANCE:g}"
        )
    return max_abs_difference


def main() -> None:
    versions = validate_environment()
    if len(sys.argv) != 1:
        raise RuntimeError("this script does not accept arguments")

    extractor = WhisperFeatureExtractor(
        feature_size=128,
        sampling_rate=16_000,
        hop_length=160,
        n_fft=400,
        dither=0.0,
    )
    filter_max_abs_difference = verify_mel_filters(extractor)
    cases = make_cases()
    fixture_cases = [make_fixture_case(name, samples, extractor) for name, samples in cases]
    whisper_max_abs_difference = verify_whisper_cross_check(cases, fixture_cases)

    dropped_only_peak = next(case for case in fixture_cases if case["name"] == "dropped_only_peak")
    silence = make_fixture_case("silence_check", np.zeros(559, dtype=np.float32), extractor)
    if dropped_only_peak["values"] != silence["values"]:
        raise RuntimeError("dropped_only_peak retained values differ from same-length silence")
    if dropped_only_peak["values"] != [-1.5] * (MEL_COUNT * 3):
        raise RuntimeError("dropped_only_peak retained values must all equal -1.5")
    fixture = {
        "sample_rate": SAMPLE_RATE,
        "n_fft": FFT_SIZE,
        "hop": HOP_SIZE,
        "n_mels": MEL_COUNT,
        "metadata": {
            "reference_implementation": (
                "transformers 4.57.1 WhisperFeatureExtractor._np_extract_fbank_features; "
                "called explicitly with device='cpu'"
            ),
            "reference_source_url": TRANSFORMERS_SOURCE_URL,
            "versions": {"python": sys.version.split()[0], "distributions": versions},
            "mel_filter_max_abs_difference": filter_max_abs_difference,
            "cross_check": {
                "implementation": "openai-whisper.log_mel_spectrogram",
                "source_url": WHISPER_SOURCE_URL,
                "case": "chirp",
                "tolerance": WHISPER_CROSS_CHECK_TOLERANCE,
                "max_abs_difference": whisper_max_abs_difference,
            },
        },
        "cases": fixture_cases,
    }
    repository_root = Path(__file__).resolve().parents[1]
    destination = (
        repository_root
        / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_mel_golden.json"
    )
    destination.write_text(
        json.dumps(fixture, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    print(destination)
    for case in fixture_cases:
        print(
            f"{case['name']}: samples={case['sample_count']} frames={case['frame_count']}"
        )
    print(f"python={sys.version.split()[0]} distributions={len(versions)}")
    print(f"filter_max_abs_difference={filter_max_abs_difference:.17g}")
    print(f"whisper_max_abs_difference={whisper_max_abs_difference:.17g}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate an independent CPU-only Qwen3-ASR token reference JSON."""
from __future__ import annotations

import argparse
import array
import hashlib
import importlib.metadata
import io
import json
import math
import platform
import struct
import sys
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json"
)
AUDIO_DIRECTORY = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources"
)
MODEL_SIZE = "0.6b"
SAMPLE_RATE = 16_000
HOP_LENGTH = 160
MEL_FEATURES = 128
HIDDEN_SIZE = 1024
MAX_NEW_TOKENS = 448
NO_REPEAT_THRESHOLD_SAMPLES = 15 * SAMPLE_RATE
EXPECTED_CLIPS = (
    ("short", "qwen3_asr_voicevox_short.wav", 52_907, "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9"),
    ("long", "qwen3_asr_voicevox_long.wav", 295_424, "d50f7f2a1fe9665279689e53297772aeb52c43d9068c82ab21b21fa62cac78b2"),
)
REQUIRED_PACKAGES = {
    "numpy": "2.2.6",
    "transformers": "4.57.1",
    "tokenizers": "0.22.2",
    "onnxruntime": "1.31.0",
}
SOURCE_URLS = [
    "https://raw.githubusercontent.com/huggingface/transformers/v4.57.1/src/transformers/models/whisper/feature_extraction_whisper.py",
    "https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0",
    "https://onnxruntime.ai/docs/api/python/api_summary.html",
    "https://www.huggingface.co/docs/tokenizers/python/latest/api/reference.html",
]


class ReferenceError(Exception):
    """A validation or inference failure while generating the reference."""


@dataclass(frozen=True)
class PromptTokens:
    head: tuple[int, ...]
    tail: tuple[int, ...]
    audio_pad_id: int
    stop_token_ids: tuple[int, int]
    audio_text_marker_id: int

    @property
    def audio_offset(self) -> int:
        return len(self.head)


def load_prompt_tokens(tokenizer: Any) -> PromptTokens:
    special_tokens = (
        "<|im_start|>",
        "<|im_end|>",
        "<|audio_start|>",
        "<|audio_pad|>",
        "<|audio_end|>",
        "<|endoftext|>",
        "<asr_text>",
    )
    token_ids: dict[str, int] = {}
    for token in special_tokens:
        try:
            token_id = tokenizer.token_to_id(token)
        except Exception as error:
            raise ReferenceError(f"could not look up tokenizer token {token!r}: {error}") from error
        if token_id is None:
            raise ReferenceError(f"tokenizer is missing required token {token!r}")
        token_ids[token] = token_id

    plain_tokens: dict[str, tuple[int, ...]] = {}
    for text in ("system", "user", "assistant", "\n", "language ja"):
        try:
            plain_tokens[text] = tuple(tokenizer.encode(text, add_special_tokens=False).ids)
        except Exception as error:
            raise ReferenceError(f"could not encode tokenizer text {text!r}: {error}") from error

    head = (
        token_ids["<|im_start|>"],
        *plain_tokens["system"],
        *plain_tokens["\n"],
        token_ids["<|im_end|>"],
        *plain_tokens["\n"],
        token_ids["<|im_start|>"],
        *plain_tokens["user"],
        *plain_tokens["\n"],
        token_ids["<|audio_start|>"],
    )
    tail = (
        token_ids["<|audio_end|>"],
        token_ids["<|im_end|>"],
        *plain_tokens["\n"],
        token_ids["<|im_start|>"],
        *plain_tokens["assistant"],
        *plain_tokens["\n"],
        *plain_tokens["language ja"],
        token_ids["<asr_text>"],
    )
    prompt_tokens = PromptTokens(
        head=head,
        tail=tail,
        audio_pad_id=token_ids["<|audio_pad|>"],
        stop_token_ids=(token_ids["<|im_end|>"], token_ids["<|endoftext|>"]),
        audio_text_marker_id=token_ids["<asr_text>"],
    )

    expected_head = (151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669)
    if prompt_tokens.head != expected_head:
        raise ReferenceError(
            f"prompt head mismatch: expected {expected_head!r}, got {prompt_tokens.head!r}"
        )
    expected_tail = (151670, 151645, 198, 151644, 77091, 198, 11528, 11937, 151704)
    if prompt_tokens.tail != expected_tail:
        raise ReferenceError(
            f"prompt tail mismatch: expected {expected_tail!r}, got {prompt_tokens.tail!r}"
        )
    if prompt_tokens.audio_pad_id != 151676:
        raise ReferenceError(
            f"audio pad ID mismatch: expected 151676, got {prompt_tokens.audio_pad_id!r}"
        )
    if prompt_tokens.stop_token_ids != (151645, 151643):
        raise ReferenceError(
            "stop token IDs mismatch: expected (151645, 151643), "
            f"got {prompt_tokens.stop_token_ids!r}"
        )
    if prompt_tokens.audio_text_marker_id != 151704:
        raise ReferenceError(
            "audio text marker ID mismatch: expected 151704, "
            f"got {prompt_tokens.audio_text_marker_id!r}"
        )
    if prompt_tokens.audio_offset != 9:
        raise ReferenceError(
            f"audio offset mismatch: expected 9, got {prompt_tokens.audio_offset}"
        )
    return prompt_tokens


def build_prompt_ids(audio_token_count: int, prompt_tokens: PromptTokens) -> list[int]:
    if type(audio_token_count) is not int or audio_token_count <= 0:
        raise ValueError("audio_token_count must be a positive integer")
    return (
        list(prompt_tokens.head)
        + [prompt_tokens.audio_pad_id] * audio_token_count
        + list(prompt_tokens.tail)
    )


def no_repeat_ngram_size(sample_count: int) -> int | None:
    if type(sample_count) is not int or sample_count <= 0:
        raise ValueError("sample_count must be a positive integer")
    return 3 if sample_count > NO_REPEAT_THRESHOLD_SAMPLES else None


def select_greedy_token(
    logits: Sequence[float], generated_ids: Sequence[int], use_no_repeat_trigram: bool
) -> int:
    if len(logits) == 0:
        raise ValueError("logits must not be empty")
    values = [float(value) for value in logits]
    if any(math.isnan(value) for value in values):
        raise ValueError("logits contain NaN")

    banned_ids: set[int] = set()
    if use_no_repeat_trigram and len(generated_ids) >= 2:
        suffix = (generated_ids[-2], generated_ids[-1])
        for index in range(len(generated_ids) - 2):
            if (generated_ids[index], generated_ids[index + 1]) == suffix:
                banned_ids.add(generated_ids[index + 2])
    if any(token_id < 0 or token_id >= len(values) for token_id in banned_ids):
        raise ValueError("no-repeat trigram contains an out-of-range token ID")
    for token_id in banned_ids:
        values[token_id] = -math.inf
    return max(range(len(values)), key=values.__getitem__)


def transcript_token_ids(
    generated_ids: Sequence[int], prompt_tokens: PromptTokens
) -> list[int]:
    last_marker_index = -1
    for index, token_id in enumerate(generated_ids):
        if token_id == prompt_tokens.audio_text_marker_id:
            last_marker_index = index
    return [
        token_id
        for token_id in generated_ids[last_marker_index + 1 :]
        if token_id not in prompt_tokens.stop_token_ids
    ]


def greedy_generate(
    initial_logits: Sequence[float],
    next_logits: Callable[[int, int], Sequence[float]],
    sample_count: int,
    prompt_tokens: PromptTokens,
) -> tuple[list[int], bool]:
    if type(sample_count) is not int or sample_count <= 0:
        raise ValueError("sample_count must be a positive integer")
    generated_ids: list[int] = []
    logits = initial_logits
    use_no_repeat_trigram = no_repeat_ngram_size(sample_count) == 3
    while len(generated_ids) < MAX_NEW_TOKENS:
        token_id = select_greedy_token(logits, generated_ids, use_no_repeat_trigram)
        generated_ids.append(token_id)
        if token_id in prompt_tokens.stop_token_ids:
            return generated_ids, False
        if len(generated_ids) == MAX_NEW_TOKENS:
            return generated_ids, True
        logits = next_logits(token_id, len(generated_ids))
    raise AssertionError("generation loop exited without a stop condition")


def installed_versions() -> dict[str, str]:
    versions: dict[str, str] = {}
    normalized_names: set[str] = set()
    try:
        distributions = importlib.metadata.distributions()
        for distribution in distributions:
            name = distribution.metadata.get("Name")
            if not name:
                raise ReferenceError("installed distribution is missing its package name")
            normalized_name = name.casefold()
            if normalized_name in normalized_names:
                raise ReferenceError(f"duplicate installed distribution name: {name}")
            normalized_names.add(normalized_name)
            versions[name] = distribution.version
    except ReferenceError:
        raise
    except Exception as error:
        raise ReferenceError(f"could not inspect installed package versions: {error}") from error
    return dict(sorted(versions.items(), key=lambda item: (item[0].casefold(), item[0])))


def validate_environment() -> dict[str, str]:
    if sys.version_info[:2] != (3, 12):
        raise ReferenceError(
            f"Python 3.12 is required, got {sys.version_info[0]}.{sys.version_info[1]}"
        )
    packages = installed_versions()
    versions_by_normalized_name = {name.casefold(): version for name, version in packages.items()}
    for package, required_version in REQUIRED_PACKAGES.items():
        actual_version = versions_by_normalized_name.get(package.casefold())
        if actual_version != required_version:
            raise ReferenceError(
                f"{package}=={required_version} is required, got {actual_version!r}"
            )
    return packages


def reference_platform() -> dict[str, str]:
    system = platform.system()
    architecture = platform.machine()
    if not isinstance(system, str) or not system.strip():
        raise ReferenceError("platform.system() returned an empty value")
    if not isinstance(architecture, str) or not architecture.strip():
        raise ReferenceError("platform.machine() returned an empty value")
    return {"platform": system, "architecture": architecture}


def validate_model_directory(model_directory: Path) -> Path:
    if not model_directory.is_absolute():
        raise ReferenceError(f"model directory must be an absolute path: {model_directory}")
    try:
        resolved = model_directory.resolve(strict=True)
    except OSError as error:
        raise ReferenceError(f"model directory does not exist: {model_directory}: {error}") from error
    if not resolved.is_dir():
        raise ReferenceError(f"model directory is not a directory: {resolved}")
    return resolved


def validate_output_path(output_path: Path) -> Path:
    if not output_path.is_absolute():
        raise ReferenceError(f"output path must be absolute: {output_path}")
    try:
        resolved = output_path.resolve(strict=False)
        worktree = REPOSITORY_ROOT.resolve(strict=True)
        temporary_root = Path(tempfile.gettempdir()).resolve(strict=True)
    except OSError as error:
        raise ReferenceError(f"could not resolve output path: {error}") from error
    allowed = resolved.is_relative_to(worktree) or resolved.is_relative_to(temporary_root)
    if not allowed:
        raise ReferenceError("output path must be inside this worktree or the system temporary directory")
    if not resolved.parent.is_dir():
        raise ReferenceError(f"output parent directory does not exist: {resolved.parent}")
    if resolved.exists() and not resolved.is_file():
        raise ReferenceError(f"output path is not a regular file: {resolved}")
    return resolved


def load_model_metadata(manifest_path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReferenceError(f"could not read model manifest {manifest_path}: {error}") from error
    model = manifest.get(MODEL_SIZE) if isinstance(manifest, dict) else None
    if not isinstance(model, dict):
        raise ReferenceError(f"model manifest has no {MODEL_SIZE!r} entry")
    repository = model.get("repository")
    commit = model.get("commit")
    files = model.get("files")
    if not isinstance(repository, str) or not repository:
        raise ReferenceError("0.6b model manifest has an invalid repository")
    if not isinstance(commit, str) or not commit:
        raise ReferenceError("0.6b model manifest has an invalid commit")
    if not isinstance(files, list) or len(files) != 6:
        raise ReferenceError("0.6b model manifest must list exactly six files")
    names: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise ReferenceError("0.6b model manifest contains an invalid file entry")
        name = entry.get("name")
        byte_count = entry.get("byteCount")
        sha256 = entry.get("sha256")
        if (
            not isinstance(name, str)
            or not name
            or Path(name).name != name
            or name in (".", "..")
            or name in names
        ):
            raise ReferenceError(f"0.6b model manifest contains an invalid or duplicate file name: {name!r}")
        if type(byte_count) is not int or byte_count < 0:
            raise ReferenceError(f"invalid expected byte count for model file {name}")
        if not isinstance(sha256, str) or len(sha256) != 64 or any(
            character not in "0123456789abcdef" for character in sha256
        ):
            raise ReferenceError(f"invalid expected SHA-256 for model file {name}")
        names.add(name)
    return model


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise ReferenceError(f"could not hash {path}: {error}") from error
    return digest.hexdigest()


def validate_model_files(model_directory: Path, model: Mapping[str, Any]) -> list[dict[str, Any]]:
    verified_files: list[dict[str, Any]] = []
    for entry in model["files"]:
        name = entry["name"]
        path = model_directory / name
        if path.is_symlink() or not path.is_file():
            raise ReferenceError(f"required model file is missing or not a regular file: {path}")
        try:
            actual_byte_count = path.stat().st_size
        except OSError as error:
            raise ReferenceError(f"could not stat model file {path}: {error}") from error
        if actual_byte_count != entry["byteCount"]:
            raise ReferenceError(
                f"model file byte count mismatch for {name}: "
                f"expected {entry['byteCount']}, got {actual_byte_count}"
            )
        actual_sha256 = sha256_file(path)
        if actual_sha256 != entry["sha256"]:
            raise ReferenceError(
                f"model file SHA-256 mismatch for {name}: "
                f"expected {entry['sha256']}, got {actual_sha256}"
            )
        verified_files.append(
            {"name": name, "byte_count": actual_byte_count, "sha256": actual_sha256}
        )
    return verified_files


def parse_pcm16_wav(wav_data: bytes, expected_sample_count: int, clip_id: str) -> bytes:
    if len(wav_data) < 12 or wav_data[:4] != b"RIFF" or wav_data[8:12] != b"WAVE":
        raise ReferenceError(f"{clip_id} WAV is not a complete RIFF/WAVE file")
    riff_size = struct.unpack_from("<I", wav_data, 4)[0]
    if riff_size != len(wav_data) - 8:
        raise ReferenceError(f"{clip_id} WAV RIFF size does not match its file length")
    try:
        with wave.open(io.BytesIO(wav_data), "rb") as wav_file:
            channels = wav_file.getnchannels()
            sample_width = wav_file.getsampwidth()
            sample_rate = wav_file.getframerate()
            frame_count = wav_file.getnframes()
            compression = wav_file.getcomptype()
            if (
                channels != 1
                or sample_width != 2
                or sample_rate != SAMPLE_RATE
                or compression != "NONE"
            ):
                raise ReferenceError(f"{clip_id} WAV must be mono PCM16 at {SAMPLE_RATE} Hz")
            if frame_count != expected_sample_count:
                raise ReferenceError(
                    f"{clip_id} WAV sample count mismatch: expected {expected_sample_count}, got {frame_count}"
                )
            pcm_bytes = wav_file.readframes(frame_count)
    except ReferenceError:
        raise
    except (EOFError, OSError, wave.Error, struct.error) as error:
        raise ReferenceError(f"could not decode {clip_id} WAV: {error}") from error
    if len(pcm_bytes) != frame_count * 2 or len(pcm_bytes) % 2:
        raise ReferenceError(f"{clip_id} WAV has incomplete PCM16 samples")
    return pcm_bytes


def normalize_pcm16_samples(pcm_bytes: bytes) -> array.array[float]:
    if len(pcm_bytes) % 2:
        raise ReferenceError("PCM16 data has an incomplete sample")
    normalized = array.array("f")
    if normalized.itemsize != 4:
        raise ReferenceError("this platform does not provide 32-bit array('f') values")
    for (sample,) in struct.iter_unpack("<h", pcm_bytes):
        normalized.append(sample / 32768.0)
    return normalized


def load_clip_samples(
    resources_directory: Path,
    clip: tuple[str, str, int, str],
    numpy_module: Any,
) -> tuple[Any, str, int]:
    clip_id, filename, sample_count, expected_sha256 = clip
    path = resources_directory / filename
    try:
        wav_data = path.read_bytes()
    except OSError as error:
        raise ReferenceError(f"could not read {clip_id} WAV {path}: {error}") from error
    actual_sha256 = hashlib.sha256(wav_data).hexdigest()
    if actual_sha256 != expected_sha256:
        raise ReferenceError(
            f"{clip_id} WAV SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}"
        )
    pcm_bytes = parse_pcm16_wav(wav_data, sample_count, clip_id)
    normalized_samples = normalize_pcm16_samples(pcm_bytes)
    samples = numpy_module.asarray(normalized_samples, dtype=numpy_module.float32)
    if samples.shape != (sample_count,) or samples.dtype != numpy_module.float32:
        raise ReferenceError(f"{clip_id} normalized samples must be float32[{sample_count}]")
    if not numpy_module.isfinite(samples).all():
        raise ReferenceError(f"{clip_id} normalized samples contain non-finite values")
    return samples, actual_sha256, sample_count


def make_sessions(onnxruntime_module: Any, model_directory: Path) -> tuple[Any, Any, Any]:
    options = onnxruntime_module.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.enable_cpu_mem_arena = True
    providers = ["CPUExecutionProvider"]
    try:
        encoder = onnxruntime_module.InferenceSession(
            str(model_directory / "encoder.onnx"), sess_options=options, providers=providers
        )
        decoder_init = onnxruntime_module.InferenceSession(
            str(model_directory / "decoder_init.int4.onnx"),
            sess_options=options,
            providers=providers,
        )
        decoder_step = onnxruntime_module.InferenceSession(
            str(model_directory / "decoder_step.int4.onnx"),
            sess_options=options,
            providers=providers,
        )
        sessions = (encoder, decoder_init, decoder_step)
        for session in sessions:
            session.disable_fallback()
            if session.get_providers() != providers:
                raise ReferenceError(
                    f"ONNX Runtime did not use CPUExecutionProvider exclusively: {session.get_providers()}"
                )
    except ReferenceError:
        raise
    except Exception as error:
        raise ReferenceError(f"could not create CPU-only ONNX Runtime sessions: {error}") from error
    return encoder, decoder_init, decoder_step


def validate_logits(numpy_module: Any, logits: Any, batch_size: int, sequence_length: int) -> Any:
    values = numpy_module.asarray(logits)
    if (
        values.ndim != 3
        or values.shape[0] != batch_size
        or values.shape[1] != sequence_length
        or values.shape[2] <= 0
    ):
        raise ReferenceError(
            f"logits must have shape [{batch_size},{sequence_length},vocabulary], got {values.shape}"
        )
    if numpy_module.isnan(values).any():
        raise ReferenceError("logits contain NaN")
    return values[0, -1, :]


def validate_cache(numpy_module: Any, keys: Any, values: Any, sequence_length: int) -> tuple[Any, Any]:
    keys_array = numpy_module.asarray(keys)
    values_array = numpy_module.asarray(values)
    for cache_name, cache in (("present_keys", keys_array), ("present_values", values_array)):
        if (
            cache.ndim != 5
            or cache.shape[0] != 28
            or cache.shape[1] != 1
            or cache.shape[2] != 8
            or cache.shape[3] != sequence_length
            or cache.shape[4] != 128
        ):
            raise ReferenceError(
                f"{cache_name} must have shape [28,1,8,{sequence_length},128], got {cache.shape}"
            )
    if keys_array.shape != values_array.shape:
        raise ReferenceError("present_keys and present_values shapes differ")
    return keys_array, values_array


def extract_audio_features(
    numpy_module: Any,
    extractor: Any,
    encoder_session: Any,
    samples: Any,
    sample_count: int,
) -> Any:
    expected_frame_count = sample_count // HOP_LENGTH
    try:
        raw_features = extractor._np_extract_fbank_features(samples[None, :], device="cpu")
    except Exception as error:
        raise ReferenceError(f"WhisperFeatureExtractor mel extraction failed: {error}") from error
    features = numpy_module.asarray(raw_features)
    expected_shape = (1, MEL_FEATURES, expected_frame_count)
    if features.shape != expected_shape:
        raise ReferenceError(f"mel features have shape {features.shape}, expected {expected_shape}")
    if not numpy_module.isfinite(features).all():
        raise ReferenceError("mel features contain non-finite values")
    features = numpy_module.ascontiguousarray(features, dtype=numpy_module.float32)
    if features.shape != expected_shape or features.dtype != numpy_module.float32:
        raise ReferenceError("mel features must be contiguous float32[1,128,frames]")
    try:
        audio_features = encoder_session.run(["audio_features"], {"mel": features})[0]
    except Exception as error:
        raise ReferenceError(f"Qwen3-ASR encoder inference failed: {error}") from error
    audio_features = numpy_module.asarray(audio_features)
    if (
        audio_features.ndim != 3
        or audio_features.shape[0] != 1
        or audio_features.shape[1] <= 0
        or audio_features.shape[2] != HIDDEN_SIZE
        or audio_features.dtype != numpy_module.float32
    ):
        raise ReferenceError(
            "encoder audio_features must be float32[1,N,1024] with N > 0, "
            f"got shape={audio_features.shape}, dtype={audio_features.dtype}"
        )
    if not numpy_module.isfinite(audio_features).all():
        raise ReferenceError("encoder audio_features contain non-finite values")
    return audio_features


def infer_clip(
    numpy_module: Any,
    tokenizer: Any,
    prompt_tokens: PromptTokens,
    embed_tokens: Any,
    decoder_init_session: Any,
    decoder_step_session: Any,
    audio_features: Any,
    sample_count: int,
) -> dict[str, Any]:
    audio_token_count = int(audio_features.shape[1])
    prompt_ids = build_prompt_ids(audio_token_count, prompt_tokens)
    sequence_length = len(prompt_ids)
    input_ids = numpy_module.asarray(prompt_ids, dtype=numpy_module.int64)[numpy_module.newaxis, :]
    position_ids = numpy_module.arange(sequence_length, dtype=numpy_module.int64)[numpy_module.newaxis, :]
    audio_offset = numpy_module.asarray([prompt_tokens.audio_offset], dtype=numpy_module.int64)
    try:
        init_outputs = decoder_init_session.run(
            ["logits", "present_keys", "present_values"],
            {
                "input_ids": input_ids,
                "position_ids": position_ids,
                "audio_offset": audio_offset,
                "audio_features": audio_features,
            },
        )
    except Exception as error:
        raise ReferenceError(f"Qwen3-ASR decoder initialization failed: {error}") from error
    if len(init_outputs) != 3:
        raise ReferenceError("decoder_init must return logits, present_keys, and present_values")
    initial_logits = validate_logits(numpy_module, init_outputs[0], 1, sequence_length)
    cache_keys, cache_values = validate_cache(
        numpy_module, init_outputs[1], init_outputs[2], sequence_length
    )

    def next_logits(last_token_id: int, generated_count: int) -> Any:
        nonlocal cache_keys, cache_values
        position = sequence_length + generated_count - 1
        input_embeds = (
            embed_tokens[last_token_id]
            .astype(numpy_module.float32)
            .reshape(1, 1, HIDDEN_SIZE)
        )
        step_position_ids = numpy_module.asarray([[position]], dtype=numpy_module.int64)
        previous_cache_length = cache_keys.shape[3]
        try:
            step_outputs = decoder_step_session.run(
                ["logits", "present_keys", "present_values"],
                {
                    "input_embeds": input_embeds,
                    "position_ids": step_position_ids,
                    "past_keys": cache_keys,
                    "past_values": cache_values,
                },
            )
        except Exception as error:
            raise ReferenceError(f"Qwen3-ASR decoder step failed: {error}") from error
        if len(step_outputs) != 3:
            raise ReferenceError("decoder_step must return logits, present_keys, and present_values")
        step_logits = validate_logits(numpy_module, step_outputs[0], 1, 1)
        cache_keys, cache_values = validate_cache(
            numpy_module, step_outputs[1], step_outputs[2], previous_cache_length + 1
        )
        return step_logits

    try:
        generated_ids, ended_at_token_cap = greedy_generate(
            initial_logits, next_logits, sample_count, prompt_tokens
        )
    except ValueError as error:
        raise ReferenceError(f"invalid greedy decoder logits: {error}") from error

    try:
        transcript_ids = transcript_token_ids(generated_ids, prompt_tokens)
        known_ids = set(tokenizer.get_vocab(with_added_tokens=True).values())
        unknown_ids = [token_id for token_id in transcript_ids if token_id not in known_ids]
        if unknown_ids:
            raise ReferenceError(f"tokenizer does not know generated token IDs: {unknown_ids!r}")
        text = tokenizer.decode(transcript_ids, skip_special_tokens=True).strip()
    except ReferenceError:
        raise
    except Exception as error:
        raise ReferenceError(f"could not decode generated transcript: {error}") from error
    if "\ufffd" in text:
        raise ReferenceError("decoded transcript contains the Unicode replacement character")
    return {
        "audio_token_count": audio_token_count,
        "prompt_ids": prompt_ids,
        "no_repeat_ngram_size": no_repeat_ngram_size(sample_count),
        "generated_ids": generated_ids,
        "text": text,
        "ended_at_token_cap": ended_at_token_cap,
    }


def generate_reference(model_directory: Path, output_path: Path) -> Path:
    resolved_model_directory = validate_model_directory(model_directory)
    resolved_output_path = validate_output_path(output_path)
    packages = validate_environment()
    model = load_model_metadata(MANIFEST_PATH)
    verified_model_files = validate_model_files(resolved_model_directory, model)

    try:
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer
        from transformers import WhisperFeatureExtractor
    except Exception as error:
        raise ReferenceError(f"could not import pinned inference dependencies: {error}") from error

    tokenizer_path = resolved_model_directory / "tokenizer.json"
    try:
        tokenizer = Tokenizer.from_file(str(tokenizer_path))
    except Exception as error:
        raise ReferenceError(f"could not load tokenizer {tokenizer_path}: {error}") from error
    prompt_tokens = load_prompt_tokens(tokenizer)
    platform_metadata = reference_platform()

    clip_inputs: list[tuple[tuple[str, str, int, str], Any, str]] = []
    for clip in EXPECTED_CLIPS:
        samples, wav_sha256, sample_count = load_clip_samples(AUDIO_DIRECTORY, clip, np)
        clip_inputs.append((clip, samples, wav_sha256))

    try:
        extractor = WhisperFeatureExtractor(
            feature_size=128,
            sampling_rate=16_000,
            hop_length=160,
            n_fft=400,
            dither=0.0,
        )
    except Exception as error:
        raise ReferenceError(f"could not initialize WhisperFeatureExtractor: {error}") from error

    encoder_session, decoder_init_session, decoder_step_session = make_sessions(
        ort, resolved_model_directory
    )
    try:
        embed_tokens = np.memmap(
            resolved_model_directory / "embed_tokens.bin",
            dtype="<f2",
            mode="r",
            shape=(151_936, 1024),
        )
    except (OSError, ValueError) as error:
        raise ReferenceError(f"could not memory-map embed_tokens.bin: {error}") from error

    clips: list[dict[str, Any]] = []
    for clip, samples, wav_sha256 in clip_inputs:
        clip_id, filename, sample_count, _expected_sha256 = clip
        audio_features = extract_audio_features(
            np, extractor, encoder_session, samples, sample_count
        )
        result = infer_clip(
            np,
            tokenizer,
            prompt_tokens,
            embed_tokens,
            decoder_init_session,
            decoder_step_session,
            audio_features,
            sample_count,
        )
        clips.append(
            {
                "id": clip_id,
                "file": filename,
                "sha256": wav_sha256,
                "sample_count": sample_count,
                "frame_count": sample_count // HOP_LENGTH,
                "audio_token_count": result["audio_token_count"],
                "prompt_ids": result["prompt_ids"],
                "no_repeat_ngram_size": result["no_repeat_ngram_size"],
                "generated_ids": result["generated_ids"],
                "text": result["text"],
                "ended_at_token_cap": result["ended_at_token_cap"],
            }
        )

    fixture = {
        "schema_version": 1,
        "model": {
            "size": MODEL_SIZE,
            "repository": model["repository"],
            "commit": model["commit"],
            "files": verified_model_files,
        },
        "reference": {
            "implementation": (
                "WhisperFeatureExtractor._np_extract_fbank_features with ONNX Runtime CPU "
                "encoder/decoder sessions and tokenizers.Tokenizer.decode"
            ),
            "source_urls": SOURCE_URLS,
            "python": sys.version.split()[0],
            "packages": packages,
            "platform": platform_metadata["platform"],
            "architecture": platform_metadata["architecture"],
            "intra_op_threads": 2,
            "inter_op_threads": 1,
            "cpu_memory_arena": True,
            "max_new_tokens": MAX_NEW_TOKENS,
            "audio_offset": prompt_tokens.audio_offset,
        },
        "clips": clips,
    }
    try:
        serialized = json.dumps(
            fixture, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2
        ) + "\n"
    except (TypeError, ValueError) as error:
        raise ReferenceError(f"could not serialize output JSON: {error}") from error
    try:
        with resolved_output_path.open("r", encoding="utf-8", newline="") as existing_file:
            existing_serialized = existing_file.read()
    except FileNotFoundError:
        existing_serialized = None
    except (OSError, UnicodeError) as error:
        raise ReferenceError(
            f"could not read existing output JSON {resolved_output_path}: {error}"
        ) from error

    if existing_serialized == serialized:
        output_status = "unchanged"
    else:
        try:
            resolved_output_path.write_text(serialized, encoding="utf-8", newline="\n")
        except OSError as error:
            raise ReferenceError(
                f"could not write output JSON {resolved_output_path}: {error}"
            ) from error
        output_status = "changed"
    for clip in clips:
        print(f"{clip['id']}: tokens={len(clip['generated_ids'])} text={clip['text']!r}")
    print(f"{output_status}: {resolved_output_path}")
    return resolved_output_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        generate_reference(arguments.model_directory, arguments.output)
    except ReferenceError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Export and accept the pinned portable clause tagger ONNX artifact."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import platform
import shutil
import sys
from pathlib import Path
from typing import Any

MODEL_ID = "sbintuitions/modernbert-ja-30m-multitagger"
MODEL_REVISION = "90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9"
TOKENIZER_SHA256 = "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062"
FIXTURE_SHA256 = "2a359e7f416da5a431c35fe89d6abf8ed413c457c330763b64a59296d273294a"
CONVERTER_SOURCE_SHA256 = "8d2ede7897806df8e03b1aa7ad5adc0b14dacbcab1a1b508245e7522af9c4f3a"
CONVERTER_LOGICAL_SOURCE = "clf/convert.py"
MAX_LEN = 192
MIN_LEN = 2
SEED = 20250614
ORDINARY_PHRASE = "今日は天気がいいですけど明日は雨が降るそうですこれはコピーというか原本を複製する操作です"
TOLERANCE = 1e-3
PROBABILITY_SUM_TOLERANCE = 1e-5
CLS_TOKEN_ID = 6
SEP_TOKEN_ID = 4
COMMA_TOKEN_ID = 275
LICENSE_TEXT = """\
Base model: SB Intuitions modernbert-ja-30m, MIT License, https://huggingface.co/sbintuitions/modernbert-ja-30m/resolve/6a0406481a741f0f74f23c03a8b958acfd276b7c/LICENSE (revision 6a0406481a741f0f74f23c03a8b958acfd276b7c)

MIT License

Copyright (c) 2025 SB Intuitions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
HEADS = ("boundary_probs", "span_probs", "priority_probs")
IDENTITY = {
    "model_id": MODEL_ID,
    "model_revision": MODEL_REVISION,
    "training_status": "trained",
    "tokenizer_sha256": TOKENIZER_SHA256,
    "unit_policy": "btsj-utterance-sentence",
    "encoding_revision": "1",
}
CONTRACT_INPUTS = [{"name": "input_ids", "dtype": "int64", "shape": [1, "seq"]}]
CONTRACT_OUTPUTS = [
    {"name": "boundary_probs", "dtype": "float32", "shape": [1, "seq", 2]},
    {"name": "span_probs", "dtype": "float32", "shape": [1, "seq", 4]},
    {"name": "priority_probs", "dtype": "float32", "shape": [1, 2]},
]
LOCKED_DIRECT_VERSIONS = {
    "torch": "2.12.0",
    "transformers": "5.12.0",
    "onnx": "1.21.0",
    "onnxscript": "0.7.0",
    "onnxruntime": "1.31.0",
    "numpy": "2.5.4",
    "tokenizers": "0.22.2",
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)

    def explicit_path(value: str) -> Path:
        if not value or not value.strip():
            raise argparse.ArgumentTypeError("path arguments must be nonempty")
        return Path(value)

    parser.add_argument("--base-dir", type=explicit_path, required=True)
    parser.add_argument("--checkpoint", type=explicit_path, required=True)
    parser.add_argument("--tokenizer", type=explicit_path, required=True)
    parser.add_argument("--fixture", type=explicit_path, required=True)
    parser.add_argument("--output-dir", type=explicit_path, required=True)
    return parser.parse_args(argv)


def _readable_regular_file(path: Path, label: str) -> Path:
    resolved = path.resolve(strict=False)
    if not resolved.is_file():
        raise FileNotFoundError(f"{label} must be a regular file: {path}")
    if not os.access(resolved, os.R_OK):
        raise ValueError(f"{label} is not readable: {path}")
    try:
        with resolved.open("rb") as stream:
            stream.read(1)
    except OSError as error:
        raise ValueError(f"{label} is not readable: {path}: {error}") from error
    return resolved


def validate_paths(args: argparse.Namespace) -> None:
    """Validate explicit input paths without creating or modifying anything."""
    for name in ("base_dir", "checkpoint", "tokenizer", "fixture", "output_dir"):
        value = getattr(args, name, None)
        if not isinstance(value, Path) or not str(value).strip():
            raise ValueError(f"--{name.replace('_', '-')} must be an explicit nonempty Path")

    base_dir = args.base_dir.resolve(strict=False)
    if not base_dir.is_dir():
        raise FileNotFoundError(f"Base model directory does not exist: {args.base_dir}")
    _readable_regular_file(base_dir / "config.json", "Base config.json")
    _readable_regular_file(base_dir / "model.safetensors", "Base model.safetensors")
    _readable_regular_file(base_dir / "tokenizer.json", "Base tokenizer.json")
    checkpoint = _readable_regular_file(args.checkpoint, "Checkpoint")
    _readable_regular_file(checkpoint.parent / "config.json", "Checkpoint sibling config.json")
    _readable_regular_file(args.tokenizer, "Tokenizer JSON")
    _readable_regular_file(args.fixture, "Fixture JSON")

    # lexists catches a dangling symlink, which Path.exists deliberately does not.
    if os.path.lexists(args.output_dir):
        raise FileExistsError(f"Refusing to replace existing output path: {args.output_dir}")
    output_dir = args.output_dir.resolve(strict=False)
    if not output_dir.parent.is_dir():
        raise FileNotFoundError(f"Output parent directory does not exist: {output_dir.parent}")

    read_only_inputs = {
        base_dir,
        checkpoint.parent.resolve(strict=False),
        args.tokenizer.resolve(strict=False).parent,
        args.fixture.resolve(strict=False).parent,
    }
    for input_dir in read_only_inputs:
        if output_dir == input_dir or output_dir.is_relative_to(input_dir):
            raise ValueError(
                f"Output directory must not be inside a read-only input directory: {input_dir}"
            )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_contract(
    inputs: list[dict[str, Any]], outputs: list[dict[str, Any]]
) -> None:
    """Require the exact ordered graph contract, including one shared `seq` axis."""
    expected_inputs = CONTRACT_INPUTS
    expected_outputs = CONTRACT_OUTPUTS
    for label, actual, expected in (
        ("inputs", inputs, expected_inputs),
        ("outputs", outputs, expected_outputs),
    ):
        if not isinstance(actual, list) or len(actual) != len(expected):
            raise ValueError(f"ONNX {label} must contain exactly {len(expected)} entries")
        for index, (item, spec) in enumerate(zip(actual, expected, strict=True)):
            if not isinstance(item, dict) or set(item) != {"name", "dtype", "shape"}:
                raise ValueError(f"ONNX {label}[{index}] must contain name, dtype, and shape")
            if not isinstance(item["name"], str) or item["name"] != spec["name"]:
                raise ValueError(f"ONNX {label}[{index}] name must be {spec['name']!r}")
            if not isinstance(item["dtype"], str) or item["dtype"] != spec["dtype"]:
                raise ValueError(
                    f"ONNX {label}[{index}] dtype must be {spec['dtype']!r}"
                )
            shape = item["shape"]
            if not isinstance(shape, list) or len(shape) != len(spec["shape"]):
                raise ValueError(f"ONNX {label}[{index}] has an invalid rank")
            for axis, (dimension, expected_dimension) in enumerate(
                zip(shape, spec["shape"], strict=True)
            ):
                if isinstance(dimension, bool) or not isinstance(dimension, (int, str)):
                    raise ValueError(
                        f"ONNX {label}[{index}] axis {axis} has an invalid dimension"
                    )
                if dimension != expected_dimension:
                    raise ValueError(
                        f"ONNX {label}[{index}] axis {axis} must be "
                        f"{expected_dimension!r}, got {dimension!r}"
                    )


def contract_document() -> dict[str, list[dict[str, Any]]]:
    return {
        "inputs": [{**item, "shape": list(item["shape"])} for item in CONTRACT_INPUTS],
        "outputs": [{**item, "shape": list(item["shape"])} for item in CONTRACT_OUTPUTS],
    }


def validate_input_ids(ids: list[int], vocab_size: int) -> None:
    if isinstance(vocab_size, bool) or not isinstance(vocab_size, int) or vocab_size <= 0:
        raise ValueError("vocab_size must be a positive integer")
    if not isinstance(ids, list) or not MIN_LEN <= len(ids) <= MAX_LEN:
        raise ValueError(f"input_ids length must be in {MIN_LEN}...{MAX_LEN}")
    for index, token_id in enumerate(ids):
        if isinstance(token_id, bool) or not isinstance(token_id, int):
            raise ValueError(f"input_ids[{index}] must be an integer, not a boolean")
        if not 0 <= token_id < vocab_size:
            raise ValueError(f"input_ids[{index}]={token_id} is outside 0...{vocab_size - 1}")
    if ids[0] != CLS_TOKEN_ID or ids[-1] != SEP_TOKEN_ID:
        raise ValueError(f"input_ids must begin with CLS={CLS_TOKEN_ID} and end with SEP={SEP_TOKEN_ID}")


def validate_fixture_document(document: Any) -> None:
    expected_keys = set(IDENTITY) | {"cls_token_id", "sep_token_id", "comma_token_id", "fixtures"}
    if not isinstance(document, dict) or set(document) != expected_keys:
        raise ValueError("Fixture document must contain exactly six identity fields and four fixture fields")
    for key, expected in IDENTITY.items():
        if document.get(key) != expected:
            raise ValueError(f"Fixture identity mismatch for {key}: expected {expected!r}")
    for key, expected in (("cls_token_id", CLS_TOKEN_ID), ("sep_token_id", SEP_TOKEN_ID),
                          ("comma_token_id", COMMA_TOKEN_ID)):
        if isinstance(document.get(key), bool) or document.get(key) != expected:
            raise ValueError(f"Fixture {key} must be {expected}")
    fixtures = document.get("fixtures")
    if not isinstance(fixtures, list) or len(fixtures) != 13:
        raise ValueError("Fixture document must contain exactly 13 cases")
    for index, fixture in enumerate(fixtures):
        if not isinstance(fixture, dict):
            raise ValueError(f"Fixture case {index} must be an object")
        ids = fixture.get("input_ids")
        if not isinstance(ids, list) or any(
            isinstance(token_id, bool) or not isinstance(token_id, int) for token_id in ids
        ):
            raise ValueError(f"Fixture case {index} input_ids must be an integer list")
        if len(ids) < MIN_LEN or len(ids) > MAX_LEN or ids[0] != CLS_TOKEN_ID or ids[-1] != SEP_TOKEN_ID:
            raise ValueError(f"Fixture case {index} has invalid length or CLS/SEP IDs")
        for head in HEADS:
            if head not in fixture:
                raise ValueError(f"Fixture case {index} is missing {head}")


def _input_file_record(path: Path, logical_name: str) -> dict[str, Any]:
    return {"logical_name": logical_name, "sha256": sha256_file(path), "size_bytes": path.stat().st_size}


def _source_input_records(args: argparse.Namespace) -> dict[str, dict[str, Any]]:
    repo_root = Path(__file__).resolve().parent.parent
    base_dir = args.base_dir.resolve(strict=True)
    checkpoint = args.checkpoint.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    tokenizer = args.tokenizer.resolve(strict=True)
    inputs = {
        "base_config": _input_file_record(base_dir / "config.json", "base/config.json"),
        "base_weights": _input_file_record(base_dir / "model.safetensors", "base/model.safetensors"),
        "base_tokenizer": _input_file_record(base_dir / "tokenizer.json", "base/tokenizer.json"),
        "checkpoint": _input_file_record(checkpoint, f"checkpoint/{checkpoint.name}"),
        "checkpoint_config": _input_file_record(checkpoint.parent / "config.json", "checkpoint/config.json"),
        "tokenizer": _input_file_record(tokenizer, "tokenizer/tokenizer.json"),
        "fixture": _input_file_record(fixture, "fixture/ClauseTaggerFixtures.json"),
        "exporter": _input_file_record(Path(__file__).resolve(), "scripts/export_clause_tagger_onnx.py"),
        "project_pyproject": _input_file_record(repo_root / "tools/clause-tagger-export/pyproject.toml", "tools/clause-tagger-export/pyproject.toml"),
        "project_lock": _input_file_record(repo_root / "tools/clause-tagger-export/uv.lock", "tools/clause-tagger-export/uv.lock"),
    }
    if inputs["tokenizer"]["sha256"] != TOKENIZER_SHA256:
        raise ValueError(f"Tokenizer SHA-256 mismatch: expected {TOKENIZER_SHA256}, got {inputs['tokenizer']['sha256']}")
    if inputs["fixture"]["sha256"] != FIXTURE_SHA256:
        raise ValueError(f"Fixture SHA-256 mismatch: expected {FIXTURE_SHA256}, got {inputs['fixture']['sha256']}")
    if inputs["base_tokenizer"]["sha256"] != TOKENIZER_SHA256 or inputs["base_tokenizer"]["sha256"] != inputs["tokenizer"]["sha256"]:
        raise ValueError("Base tokenizer.json and supplied tokenizer must both match the pinned tokenizer SHA-256")
    return inputs


def _read_config_json(path: Path, label: str) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Could not read {label} as UTF-8 JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    for key, expected in (("vocab_size", 102400), ("cls_token_id", CLS_TOKEN_ID), ("sep_token_id", SEP_TOKEN_ID)):
        if isinstance(value.get(key), bool) or value.get(key) != expected:
            raise ValueError(f"{label} {key} must be {expected}")
    return value


def _normalized_config_dict(config: Any) -> dict[str, Any]:
    values = config.to_dict()
    ignored = {
        "_name_or_path", "name_or_path", "transformers_version", "torch_dtype", "dtype",
        "_attn_implementation", "_attn_implementation_internal", "global_attn_every_n_layers",
        "gradient_checkpointing", "reference_compile",
    }
    return {key: value for key, value in values.items() if key not in ignored}


def _wrapper_sliding_mask(length: int, window: int, device: Any, torch: Any):
    positions = torch.arange(length, device=device)
    distance = (positions[None, :] - positions[:, None]).abs()
    return ((distance <= window).float() - 1.0)[None, None] * 1e4


def create_model(base_dir: Path):
    """Build a local-only fp32 MultiTagger without importing torch at module load."""
    import torch
    from torch import nn
    from transformers import AutoConfig, AutoModel

    config = AutoConfig.from_pretrained(
        str(base_dir), local_files_only=True, trust_remote_code=False
    )
    config._attn_implementation = "eager"

    class MultiTagger(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.backbone = AutoModel.from_pretrained(
                str(base_dir),
                local_files_only=True,
                trust_remote_code=False,
                use_safetensors=True,
                dtype=torch.float32,
                config=config,
            )
            hidden_size = config.hidden_size
            self.boundary = nn.Linear(hidden_size, 2)
            self.span = nn.Linear(hidden_size, 4)
            self.priority = nn.Linear(hidden_size, 2)

        def forward(self, input_ids):
            window = self.backbone.config.sliding_window
            sliding = _wrapper_sliding_mask(
                input_ids.shape[1], window, input_ids.device, torch
            )
            masks = {"full_attention": None, "sliding_attention": sliding}
            hidden = self.backbone(input_ids=input_ids, attention_mask=masks).last_hidden_state
            return (
                self.boundary(hidden).softmax(-1),
                self.span(hidden).softmax(-1),
                self.priority(hidden[:, 0]).softmax(-1),
            )

    return MultiTagger().to(device="cpu", dtype=torch.float32)


def _state_revision(model: Any) -> str:
    digest = hashlib.sha256()
    for name, value in sorted(model.state_dict().items(), key=lambda item: item[0]):
        name_bytes = name.encode("utf-8")
        tensor_bytes = value.detach().cpu().contiguous().numpy().tobytes(order="C")
        digest.update(len(name_bytes).to_bytes(8, "big"))
        digest.update(name_bytes)
        digest.update(len(tensor_bytes).to_bytes(8, "big"))
        digest.update(tensor_bytes)
    return digest.hexdigest()


def _validate_model_tensors(model: Any, torch: Any, label: str) -> None:
    for name, tensor in list(model.named_parameters()) + list(model.named_buffers()):
        if tensor.is_floating_point():
            if tensor.dtype != torch.float32:
                raise ValueError(f"{label} tensor {name} must be float32, got {tensor.dtype}")
            if not bool(torch.isfinite(tensor).all().item()):
                raise ValueError(f"{label} tensor {name} contains nonfinite values")


def _assert_independent_parameters(left: Any, right: Any) -> None:
    left_parameters = dict(left.named_parameters(remove_duplicate=False))
    right_parameters = dict(right.named_parameters(remove_duplicate=False))
    if set(left_parameters) != set(right_parameters):
        raise ValueError("Export and reference models have different named parameters")
    left_ptrs = {parameter.data_ptr(): name for name, parameter in left_parameters.items()}
    right_ptrs = {parameter.data_ptr(): name for name, parameter in right_parameters.items()}
    shared = set(left_ptrs) & set(right_ptrs)
    if shared:
        names = sorted({left_ptrs[pointer] for pointer in shared} | {right_ptrs[pointer] for pointer in shared})
        raise ValueError(f"Export and reference models share parameter storage: {names}")


def _read_fixture(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            document = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Could not read fixture JSON: {error}") from error
    validate_fixture_document(document)
    return document


def _explicit_reference_mask(length: int, window: int, device: Any, torch: Any):
    # Deliberately independent of the export wrapper's vectorized mask arithmetic.
    rows = [[0.0 if abs(query - key) <= window else -1e4 for key in range(length)]
            for query in range(length)]
    return torch.tensor(rows, dtype=torch.float32, device=device)[None, None]


def _snapshot(value: Any, np: Any, torch: Any):
    if torch.is_tensor(value):
        return value.detach().cpu().numpy().copy()
    return np.asarray(value).copy()


def _eager_reference_outputs(model: Any, input_ids: Any, torch: Any, np: Any):
    config = model.backbone.config
    masks = {
        "full_attention": None,
        "sliding_attention": _explicit_reference_mask(
            int(input_ids.shape[1]), int(config.sliding_window), input_ids.device, torch
        ),
    }
    hidden = model.backbone(input_ids=input_ids, attention_mask=masks).last_hidden_state
    values = (
        model.boundary(hidden).softmax(-1),
        model.span(hidden).softmax(-1),
        model.priority(hidden[:, 0]).softmax(-1),
    )
    return tuple(_snapshot(value, np, torch) for value in values)


def _eager_unmasked_reference_outputs(model: Any, input_ids: Any, torch: Any, np: Any):
    masks = {"full_attention": None, "sliding_attention": None}
    hidden = model.backbone(input_ids=input_ids, attention_mask=masks).last_hidden_state
    values = (
        model.boundary(hidden).softmax(-1),
        model.span(hidden).softmax(-1),
        model.priority(hidden[:, 0]).softmax(-1),
    )
    return tuple(_snapshot(value, np, torch) for value in values)


def _ordinary_and_random_ids(tokenizer: Any, vocab_size: int, length: int,
                             valid_vocab_ids: Any, special_ids: set[int], torch: Any, np: Any):
    ordinary_tokens = tokenizer.encode(ORDINARY_PHRASE, add_special_tokens=False).ids
    ordinary_tokens = [token_id for token_id in ordinary_tokens if token_id not in special_ids]
    if not ordinary_tokens:
        raise ValueError("Pinned tokenizer produced no ordinary IDs for the parity phrase")
    ordinary = [CLS_TOKEN_ID]
    ordinary.extend(
        ordinary_tokens[(length * 17 + index * 29) % len(ordinary_tokens)]
        for index in range(length - 2)
    )
    ordinary.append(SEP_TOKEN_ID)
    rng = np.random.default_rng(SEED + length)
    random_ids = [CLS_TOKEN_ID]
    if length > 2:
        random_ids.extend(
            int(value) for value in rng.choice(valid_vocab_ids, size=length - 2, replace=True).tolist()
        )
    random_ids.append(SEP_TOKEN_ID)
    validate_input_ids(ordinary, vocab_size)
    validate_input_ids(random_ids, vocab_size)
    return (
        torch.tensor([ordinary], dtype=torch.int64, device="cpu"),
        torch.tensor([random_ids], dtype=torch.int64, device="cpu"),
    )


def _validate_probabilities(outputs: Any, sequence_length: int, np: Any, torch: Any, label: str):
    if not isinstance(outputs, (tuple, list)) or len(outputs) != len(HEADS):
        raise ValueError(f"{label} must return exactly {len(HEADS)} probability heads")
    expected_shapes = (
        (1, sequence_length, 2),
        (1, sequence_length, 4),
        (1, 2),
    )
    arrays = []
    for index, name in enumerate(HEADS):
        value = outputs[index]
        if torch.is_tensor(value):
            if value.dtype != torch.float32:
                raise ValueError(f"{label} {name} must be float32, got {value.dtype}")
            array = value.detach().cpu().numpy().copy()
        else:
            array = np.asarray(value)
        if array.dtype != np.dtype(np.float32):
            raise ValueError(f"{label} {name} must be float32, got {array.dtype}")
        if array.shape != expected_shapes[index]:
            raise ValueError(f"{label} {name} shape must be {expected_shapes[index]}, got {array.shape}")
        if not bool(np.isfinite(array).all()):
            raise ValueError(f"{label} {name} contains nonfinite values")
        if bool(((array < 0.0) | (array > 1.0)).any()):
            raise ValueError(f"{label} {name} contains values outside [0,1]")
        row_sums = array.astype(np.float64, copy=False).sum(axis=-1)
        if float(np.max(np.abs(row_sums - 1.0), initial=0.0)) > PROBABILITY_SUM_TOLERANCE:
            raise ValueError(f"{label} {name} row sums exceed {PROBABILITY_SUM_TOLERANCE}")
        arrays.append(array)
    return tuple(arrays)


def _head_max_abs(left: Any, right: Any, np: Any) -> dict[str, float]:
    if len(left) != len(HEADS) or len(right) != len(HEADS):
        raise ValueError("Numeric comparison requires exactly three complete heads on each side")
    maxima: dict[str, float] = {}
    for index, name in enumerate(HEADS):
        first = np.asarray(left[index])
        second = np.asarray(right[index])
        if first.shape != second.shape:
            raise ValueError(f"{name} comparison shape mismatch: {first.shape} != {second.shape}")
        if first.size != second.size:
            raise ValueError(f"{name} comparison element count mismatch: {first.size} != {second.size}")
        difference = np.abs(first.astype(np.float64) - second.astype(np.float64))
        if not bool(np.isfinite(difference).all()):
            raise ValueError(f"{name} comparison produced nonfinite absolute errors")
        maxima[name] = float(np.max(difference, initial=0.0))
    return maxima


def _update_maxima(target: dict[str, float], values: dict[str, float]) -> None:
    for head in HEADS:
        target[head] = max(target[head], values[head])


def _special_token_ids(tokenizer_json: dict[str, Any], tokenizer: Any,
                       vocab: dict[str, int], vocab_size: int) -> set[int]:
    added = tokenizer_json.get("added_tokens")
    if not isinstance(added, list):
        raise ValueError("Tokenizer JSON must contain an added_tokens list")
    special_ids: set[int] = set()
    for index, item in enumerate(added):
        if not isinstance(item, dict):
            raise ValueError(f"Tokenizer added_tokens[{index}] must be an object")
        if item.get("special") is True:
            token_id = item.get("id")
            content = item.get("content")
            if isinstance(token_id, bool) or not isinstance(token_id, int):
                raise ValueError(f"Special tokenizer added_tokens[{index}] has an invalid ID")
            if not isinstance(content, str) or not content:
                raise ValueError(f"Special tokenizer added_tokens[{index}] has invalid content")
            if not 0 <= token_id < vocab_size or token_id not in set(vocab.values()):
                raise ValueError(f"Special tokenizer ID {token_id} is outside the real model vocabulary")
            if tokenizer.token_to_id(content) != token_id:
                raise ValueError(f"Tokenizer special token {content!r} does not map to its declared ID")
            special_ids.add(token_id)
    if CLS_TOKEN_ID not in special_ids or SEP_TOKEN_ID not in special_ids:
        raise ValueError("Tokenizer JSON special added_tokens must include CLS=6 and SEP=4")
    return special_ids


def _load_local_tokenizer(path: Path, vocab_size: int):
    from tokenizers import Tokenizer
    import numpy as np

    try:
        with path.open("r", encoding="utf-8") as stream:
            tokenizer_json = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Could not read tokenizer JSON: {error}") from error
    if not isinstance(tokenizer_json, dict):
        raise ValueError("Tokenizer JSON must be an object")
    tokenizer = Tokenizer.from_file(str(path))
    vocab = tokenizer.get_vocab(with_added_tokens=True)
    if not vocab:
        raise ValueError("Tokenizer has no vocabulary")
    vocab_ids: set[int] = set()
    for token, token_id in vocab.items():
        if isinstance(token_id, bool) or not isinstance(token_id, int) or not 0 <= token_id < vocab_size:
            raise ValueError(f"Tokenizer vocabulary entry {token!r} has invalid ID {token_id!r}")
        vocab_ids.add(token_id)
    special_ids = _special_token_ids(tokenizer_json, tokenizer, vocab, vocab_size)
    comma_id = tokenizer.token_to_id("、")
    if comma_id != COMMA_TOKEN_ID:
        raise ValueError(f"Tokenizer comma token ID must be {COMMA_TOKEN_ID}, got {comma_id}")
    valid_vocab_ids = np.asarray(sorted(vocab_ids - special_ids), dtype=np.int64)
    if valid_vocab_ids.size == 0:
        raise ValueError("Tokenizer has no valid non-special IDs for random parity inputs")
    return tokenizer, special_ids, valid_vocab_ids, len(vocab_ids)


def _mask_checks(model: Any, torch: Any, transformers: Any) -> list[dict[str, Any]]:
    records = []
    config = model.backbone.config
    window = int(config.sliding_window)
    for length in (2, 64, 65, 66, 128, 192):
        wrapper_mask = _wrapper_sliding_mask(length, window, "cpu", torch)
        expected_rows = [
            [0.0 if abs(query - key) <= window else -1e4 for key in range(length)]
            for query in range(length)
        ]
        expected = torch.tensor(expected_rows, dtype=torch.float32)[None, None]
        if wrapper_mask.dtype != torch.float32 or not torch.equal(wrapper_mask, expected):
            raise ValueError(f"Wrapper additive mask differs from independent support at length {length}")

        embeddings = torch.zeros((1, length, int(config.hidden_size)), dtype=torch.float32)
        installed = transformers.masking_utils.create_bidirectional_sliding_window_mask(
            config=config, inputs_embeds=embeddings, attention_mask=None
        )
        if installed is None:
            installed_support = torch.ones((length, length), dtype=torch.bool)
            installed_description = "None (all-allowed support)"
            installed_is_none = True
        else:
            if tuple(installed.shape) != (1, 1, length, length):
                raise ValueError(
                    f"Transformers sliding mask shape at length {length} is {tuple(installed.shape)}"
                )
            installed_cpu = installed.detach().cpu()
            installed_support = (
                installed_cpu[0, 0] if installed_cpu.dtype == torch.bool
                else installed_cpu[0, 0] >= 0
            )
            installed_description = f"{installed_cpu.dtype}, shape={list(installed_cpu.shape)}"
            installed_is_none = False
        expected_support = expected[0, 0] == 0
        if not torch.equal(installed_support, expected_support):
            mismatch_count = int((installed_support != expected_support).sum().item())
            raise ValueError(
                f"Transformers sliding-window support differs at length {length}: {mismatch_count} pairs"
            )
        records.append({
            "length_tokens": length,
            "window_half_width": window,
            "full_attention": None,
            "wrapper_additive_values": "exact float32 0/-1e4",
            "wrapper_vs_independent_nested_support_equal": True,
            "transformers_mask": installed_description,
            "transformers_mask_is_none": installed_is_none,
            "none_interpreted_as": "all-allowed support" if installed_is_none else None,
            "allowed_pairs": int(expected_support.sum().item()),
            "support_equal": True,
        })
    return records


def _attention_sensitivity(reference_model: Any, tokenizer: Any, vocab_size: int,
                           valid_vocab_ids: Any, special_ids: set[int], torch: Any,
                           np: Any) -> dict[str, Any]:
    by_length: dict[str, dict[str, float]] = {}
    witness = None
    for length in (100, 192):
        _, random_ids = _ordinary_and_random_ids(
            tokenizer, vocab_size, length, valid_vocab_ids, special_ids, torch, np
        )
        with torch.inference_mode():
            masked = _eager_reference_outputs(reference_model, random_ids, torch, np)
            unmasked = _eager_unmasked_reference_outputs(reference_model, random_ids, torch, np)
        for label, outputs in (("masked", masked), ("unmasked", unmasked)):
            _validate_probabilities(outputs, length, np, torch, f"sensitivity {label}")
        differences = _head_max_abs(masked, unmasked, np)
        by_length[str(length)] = differences
        for head in HEADS:
            if differences[head] > TOLERANCE and witness is None:
                witness = {"length_tokens": length, "head": head, "max_abs_diff": differences[head]}
    if witness is None:
        raise ValueError("Masked-vs-unmasked negative control failed to exceed 1e-3 at lengths 100 or 192")
    return {"by_length_and_head": by_length, "witness": witness, "passed": True,
            "random_seed": SEED}


def _onnx_value_contract(model: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    import onnx

    dtype_names = {
        onnx.TensorProto.INT64: "int64",
        onnx.TensorProto.FLOAT: "float32",
    }

    def describe(values: Any) -> list[dict[str, Any]]:
        result = []
        for value in values:
            tensor_type = value.type.tensor_type
            if not tensor_type.HasField("shape"):
                raise ValueError(f"ONNX value {value.name} has no tensor shape")
            shape = []
            for dimension in tensor_type.shape.dim:
                if dimension.HasField("dim_value"):
                    shape.append(int(dimension.dim_value))
                elif dimension.HasField("dim_param") and dimension.dim_param:
                    shape.append(dimension.dim_param)
                else:
                    raise ValueError(f"ONNX value {value.name} has an empty/unknown dimension")
            dtype = dtype_names.get(tensor_type.elem_type)
            if dtype is None:
                raise ValueError(f"ONNX value {value.name} has unsupported tensor dtype {tensor_type.elem_type}")
            result.append({"name": value.name, "dtype": dtype, "shape": shape})
        return result

    return describe(model.graph.input), describe(model.graph.output)


def _walk_protobuf_messages(message: Any):
    yield message
    for descriptor, value in message.ListFields():
        if descriptor.message_type is None:
            continue
        if descriptor.is_repeated:
            for item in value:
                yield from _walk_protobuf_messages(item)
        else:
            yield from _walk_protobuf_messages(value)


def _strip_exporter_metadata(model: Any) -> None:
    for message in list(_walk_protobuf_messages(model)):
        fields = {field.name for field, _ in message.ListFields()}
        if "doc_string" in fields:
            message.ClearField("doc_string")
        if "metadata_props" in fields:
            message.ClearField("metadata_props")


def _validate_onnx_graph(model: Any, output_path: Path) -> dict[str, Any]:
    import onnx

    onnx.checker.check_model(model, full_check=True)
    inputs, outputs = _onnx_value_contract(model)
    validate_contract(inputs, outputs)

    if len(model.opset_import) != 1:
        raise ValueError("ONNX graph must import exactly one standard operator set")
    opset = model.opset_import[0]
    if opset.domain not in ("", "ai.onnx") or int(opset.version) != 18:
        raise ValueError(f"ONNX graph must use only standard ai.onnx opset 18, got {opset.domain!r}:{opset.version}")
    if len(model.functions):
        raise ValueError("ONNX graph must not define local functions")
    for node in model.graph.node:
        if node.domain not in ("", "ai.onnx"):
            raise ValueError(f"ONNX node {node.name or node.op_type} uses custom domain {node.domain!r}")
        try:
            onnx.defs.get_schema(node.op_type, 18, domain="")
        except onnx.defs.SchemaError as error:
            raise ValueError(f"ONNX node {node.op_type!r} is not a standard opset-18 operator") from error

    external_tensors = []
    forbidden_float_tensors = []
    forbidden_elem_types = {
        onnx.TensorProto.FLOAT16,
        onnx.TensorProto.DOUBLE,
        onnx.TensorProto.BFLOAT16,
    }
    for message in _walk_protobuf_messages(model):
        if isinstance(message, onnx.TensorProto):
            if message.data_location == onnx.TensorProto.EXTERNAL or len(message.external_data):
                external_tensors.append(message.name or "unnamed tensor")
            if message.data_type in forbidden_elem_types:
                forbidden_float_tensors.append(message.name or "unnamed tensor")
        elif isinstance(message, onnx.TypeProto) and message.HasField("tensor_type"):
            if message.tensor_type.elem_type in forbidden_elem_types:
                forbidden_float_tensors.append("value_info tensor type")
    if external_tensors:
        raise ValueError(f"ONNX graph contains external tensor data: {external_tensors}")
    if forbidden_float_tensors:
        raise ValueError(f"ONNX graph contains fp16/bf16/fp64 tensors: {forbidden_float_tensors}")
    if not output_path.is_file() or output_path.stat().st_size <= 0:
        raise ValueError("Serialized ClauseTagger.onnx is missing or empty")
    return {"opset": 18, "inputs": inputs, "outputs": outputs,
            "standard_operator_count": len(model.graph.node),
            "external_tensor_count": 0, "forbidden_float_tensor_count": 0}


def _embed_identity_and_validate(output_path: Path) -> dict[str, Any]:
    import onnx

    model = onnx.load(str(output_path), load_external_data=True)
    _strip_exporter_metadata(model)
    for key, value in IDENTITY.items():
        entry = model.metadata_props.add()
        entry.key = key
        entry.value = str(value)
    onnx.save_model(model, str(output_path), save_as_external_data=False)
    reloaded = onnx.load(str(output_path), load_external_data=True)
    metadata = {item.key: item.value for item in reloaded.metadata_props}
    expected_metadata = {key: str(value) for key, value in IDENTITY.items()}
    if metadata != expected_metadata:
        raise ValueError(f"Reloaded ONNX metadata differs from the six required identity fields: {metadata}")
    onnx.checker.check_model(reloaded, full_check=True)
    graph_record = _validate_onnx_graph(reloaded, output_path)
    graph_record["embedded_metadata"] = metadata
    return graph_record


def _package_versions() -> dict[str, str]:
    versions: dict[str, str] = {}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name")
        if name:
            normalized = "".join(character.lower() if character.isalnum() else "-" for character in name).strip("-")
            versions[normalized] = distribution.version
    for package, required in LOCKED_DIRECT_VERSIONS.items():
        actual = versions.get(package)
        if actual != required:
            raise ValueError(f"Locked package {package} must be {required}, got {actual!r}")
    return dict(sorted(versions.items()))


def _runtime_record(torch: Any, np: Any, transformers: Any) -> dict[str, Any]:
    return {
        "python": sys.version.split()[0],
        "operating_system": platform.system(),
        "architecture": platform.machine(),
        "macos_version": platform.mac_ver()[0] if platform.system() == "Darwin" else None,
        "packages": _package_versions(),
        "attention_compute_dtype": "float32",
        "device": "CPU",
    }


def _write_json(path: Path, value: Any) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def _run_export(args: argparse.Namespace) -> dict[str, Any]:
    # Heavy dependencies are deliberately imported only after CLI parsing and path validation.
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch
    import transformers
    from transformers import AutoConfig

    runtime = _runtime_record(torch, np, transformers)
    if sys.version_info[:2] != (3, 12):
        raise ValueError(f"Exporter requires locked Python 3.12, got {sys.version.split()[0]}")

    base_dir = args.base_dir.resolve(strict=True)
    checkpoint = args.checkpoint.resolve(strict=True)
    tokenizer_path = args.tokenizer.resolve(strict=True)
    fixture_path = args.fixture.resolve(strict=True)
    base_raw_config = _read_config_json(base_dir / "config.json", "Base config.json")
    checkpoint_raw_config = _read_config_json(checkpoint.parent / "config.json", "Checkpoint config.json")
    fixture = _read_fixture(fixture_path)
    input_records = _source_input_records(args)

    base_config = AutoConfig.from_pretrained(
        str(base_dir), local_files_only=True, trust_remote_code=False
    )
    checkpoint_config = AutoConfig.from_pretrained(
        str(checkpoint.parent), local_files_only=True, trust_remote_code=False
    )
    base_config._attn_implementation = "eager"
    checkpoint_config._attn_implementation = "eager"
    if int(base_config.sliding_window) != 64:
        raise ValueError(f"Base config sliding_window must resolve to 64, got {base_config.sliding_window!r}")
    if int(checkpoint_config.sliding_window) != 64:
        raise ValueError(f"Checkpoint config sliding_window must resolve to 64, got {checkpoint_config.sliding_window!r}")
    if int(base_config.vocab_size) != 102400 or int(checkpoint_config.vocab_size) != 102400:
        raise ValueError("Base and checkpoint config vocab_size must both be 102400")
    if int(base_config.cls_token_id) != CLS_TOKEN_ID or int(base_config.sep_token_id) != SEP_TOKEN_ID:
        raise ValueError("Base config CLS/SEP IDs must be 6/4")
    if int(checkpoint_config.cls_token_id) != CLS_TOKEN_ID or int(checkpoint_config.sep_token_id) != SEP_TOKEN_ID:
        raise ValueError("Checkpoint config CLS/SEP IDs must be 6/4")
    base_normalized = _normalized_config_dict(base_config)
    checkpoint_normalized = _normalized_config_dict(checkpoint_config)
    if base_normalized != checkpoint_normalized:
        differing = sorted(
            key for key in set(base_normalized) | set(checkpoint_normalized)
            if base_normalized.get(key) != checkpoint_normalized.get(key)
        )
        raise ValueError(f"Base and checkpoint model configs differ in fields: {differing}")
    if base_raw_config["cls_token_id"] != fixture["cls_token_id"] or base_raw_config["sep_token_id"] != fixture["sep_token_id"]:
        raise ValueError("Base config CLS/SEP IDs differ from the fixture")
    if checkpoint_raw_config["cls_token_id"] != fixture["cls_token_id"] or checkpoint_raw_config["sep_token_id"] != fixture["sep_token_id"]:
        raise ValueError("Checkpoint config CLS/SEP IDs differ from the fixture")

    tokenizer, special_ids, valid_vocab_ids, real_vocab_count = _load_local_tokenizer(
        tokenizer_path, int(base_config.vocab_size)
    )
    fixture_expected_outputs = []
    for index, case in enumerate(fixture["fixtures"]):
        validate_input_ids(case["input_ids"], int(base_config.vocab_size))
        stored_values = []
        for head, expected_shape in (
            ("boundary_probs", (len(case["input_ids"]), 2)),
            ("span_probs", (len(case["input_ids"]), 4)),
            ("priority_probs", (2,)),
        ):
            try:
                raw_values = np.asarray(case[head])
            except (TypeError, ValueError) as error:
                raise ValueError(f"Fixture case {index} {head} is not a rectangular numeric array") from error
            if raw_values.dtype.kind not in "iuf":
                raise ValueError(f"Fixture case {index} {head} must contain only JSON numbers")
            values = raw_values.astype(np.float32, copy=True)
            if values.shape != expected_shape:
                raise ValueError(f"Fixture case {index} {head} shape must be {expected_shape}, got {values.shape}")
            stored_values.append(values[None, ...])
        expected_outputs = _validate_probabilities(
            tuple(stored_values), len(case["input_ids"]), np, torch, f"Stored fixture {index}"
        )
        fixture_expected_outputs.append(expected_outputs)

    torch.manual_seed(SEED)
    torch.set_num_threads(1)
    state = torch.load(str(checkpoint), map_location="cpu", weights_only=True)
    if not isinstance(state, dict):
        raise ValueError("Checkpoint must be a complete state_dict mapping")
    export_model = create_model(base_dir)
    export_model.load_state_dict(state, strict=True)
    export_model.to(device="cpu", dtype=torch.float32).eval()
    reference_model = create_model(base_dir)
    reference_model.load_state_dict(state, strict=True)
    reference_model.to(device="cpu", dtype=torch.float32).eval()
    _assert_independent_parameters(export_model, reference_model)
    _validate_model_tensors(export_model, torch, "Export model")
    _validate_model_tensors(reference_model, torch, "Reference model")
    revision = _state_revision(export_model)
    reference_revision = _state_revision(reference_model)
    if revision != MODEL_REVISION or reference_revision != MODEL_REVISION:
        raise ValueError(
            f"Checkpoint state revision mismatch: export={revision}, reference={reference_revision}, expected={MODEL_REVISION}"
        )
    if revision != reference_revision:
        raise ValueError("Export and reference model state revisions differ")

    checks: list[str] = [
        "explicit input paths and output nonexistence validated",
        "base and checkpoint configs resolve to the same supported eager model configuration",
        "pinned tokenizer and 13-case fixture identities validated",
        "checkpoint strict-loaded into two independent CPU fp32 models",
        "both state revisions match the pinned model revision",
        "all floating model tensors are finite fp32",
    ]
    model_config = export_model.backbone.config
    attention_configuration = {
        "implementation": model_config._attn_implementation,
        "full_attention": None,
        "sliding_attention": "additive float32 inclusive abs(i-j) <= config.sliding_window, disallowed=-1e4",
        "sliding_window": int(model_config.sliding_window),
        "local_attention": int(model_config.local_attention),
    }
    mask_records = _mask_checks(export_model, torch, transformers)
    checks.append("wrapper and Transformers sliding-mask support agree at 2/64/65/66/128/192")
    sensitivity = _attention_sensitivity(
        reference_model, tokenizer, int(model_config.vocab_size), valid_vocab_ids,
        special_ids, torch, np
    )
    checks.append("masked-vs-unmasked negative control exceeds 1e-3 at a long input")

    # No output directory is created until every input identity/config/state preflight passes.
    output_dir = args.output_dir.resolve(strict=False)
    output_dir.mkdir(exist_ok=False)
    onnx_path = output_dir / "ClauseTagger.onnx"
    example_ids, _ = _ordinary_and_random_ids(
        tokenizer, int(model_config.vocab_size), 16, valid_vocab_ids,
        special_ids, torch, np
    )
    sequence_dim = torch.export.Dim("seq", min=MIN_LEN, max=MAX_LEN)
    with torch.inference_mode():
        torch.onnx.export(
            export_model,
            (example_ids,),
            str(onnx_path),
            dynamo=True,
            opset_version=18,
            external_data=False,
            input_names=["input_ids"],
            output_names=list(HEADS),
            dynamic_shapes=({1: sequence_dim},),
        )
    graph_record = _embed_identity_and_validate(onnx_path)
    checks.extend([
        "dynamo ONNX opset-18 graph passes full checker",
        "exact ordered dynamic tensor contract validated",
        "graph contains only standard operators and embedded tensors",
        "graph contains no fp16, bf16, or fp64 tensors",
        "exact six identity metadata values reload from ONNX",
    ])

    ort.disable_telemetry_events()
    session_options = ort.SessionOptions()
    session_options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    session_options.intra_op_num_threads = 1
    session_options.inter_op_num_threads = 1
    session_options.enable_cpu_mem_arena = False
    session = ort.InferenceSession(
        str(onnx_path), sess_options=session_options, providers=["CPUExecutionProvider"]
    )
    session.disable_fallback()
    if session.get_providers() != ["CPUExecutionProvider"]:
        raise ValueError(f"ORT must use CPUExecutionProvider only, got {session.get_providers()}")
    if [value.name for value in session.get_outputs()] != list(HEADS):
        raise ValueError("ORT output order/names differ from the required three heads")
    ort_metadata = session.get_modelmeta().custom_metadata_map
    if ort_metadata != {key: str(value) for key, value in IDENTITY.items()}:
        raise ValueError("ORT-reloaded model metadata differs from the required identity")
    checks.append("ORT 1.31.0 CPU-only session is sequential, single-threaded, no arena, and fallback-disabled")

    aggregate = {head: 0.0 for head in HEADS}
    comparison_maxima = {
        name: {head: 0.0 for head in HEADS}
        for name in ("wrapper_vs_reference", "ort_vs_reference", "ort_vs_wrapper")
    }
    parity_by_length: dict[str, Any] = {}
    violations: list[str] = []

    def run_ort(input_ids: Any, length: int):
        if input_ids.dtype != torch.int64:
            raise ValueError("Parity input must be int64")
        feed = input_ids.detach().cpu().numpy().astype(np.int64, copy=True)
        values = session.run(list(HEADS), {"input_ids": feed})
        return _validate_probabilities(values, length, np, torch, "ORT")

    for length in range(MIN_LEN, MAX_LEN + 1):
        case_records: dict[str, Any] = {}
        length_max = {head: 0.0 for head in HEADS}
        ordinary_ids, random_ids = _ordinary_and_random_ids(
            tokenizer, int(model_config.vocab_size), length,
            valid_vocab_ids, special_ids, torch, np
        )
        for case_name, input_ids in (("ordinary", ordinary_ids), ("random_vocab", random_ids)):
            validate_input_ids(input_ids[0].tolist(), int(model_config.vocab_size))
            with torch.inference_mode():
                wrapper_outputs = _validate_probabilities(
                    export_model(input_ids), length, np, torch, "Wrapper"
                )
                reference_outputs = _validate_probabilities(
                    _eager_reference_outputs(reference_model, input_ids, torch, np),
                    length, np, torch, "Independent reference"
                )
            ort_outputs = run_ort(input_ids, length)
            pairs = {
                "wrapper_vs_reference": (wrapper_outputs, reference_outputs),
                "ort_vs_reference": (ort_outputs, reference_outputs),
                "ort_vs_wrapper": (ort_outputs, wrapper_outputs),
            }
            case_record: dict[str, Any] = {}
            for comparison, (left, right) in pairs.items():
                maxima = _head_max_abs(left, right, np)
                case_record[comparison] = maxima
                _update_maxima(comparison_maxima[comparison], maxima)
                _update_maxima(length_max, maxima)
                _update_maxima(aggregate, maxima)
                for head, maximum in maxima.items():
                    if maximum > TOLERANCE:
                        violations.append(
                            f"{comparison} {head}, length={length}, case={case_name}: "
                            f"max_abs={maximum:.9g} exceeds {TOLERANCE}"
                        )
            case_records[case_name] = case_record
        parity_by_length[str(length)] = case_records
        print(json.dumps({"length_tokens": length, "max_abs_by_head": length_max}, sort_keys=True), flush=True)

    fixture_records = []
    for index, case in enumerate(fixture["fixtures"]):
        ids = case["input_ids"]
        length = len(ids)
        input_ids = torch.tensor([ids], dtype=torch.int64, device="cpu")
        with torch.inference_mode():
            wrapper_outputs = _validate_probabilities(export_model(input_ids), length, np, torch, "Fixture wrapper")
            reference_outputs = _validate_probabilities(
                _eager_reference_outputs(reference_model, input_ids, torch, np),
                length, np, torch, "Fixture independent reference"
            )
        ort_outputs = run_ort(input_ids, length)
        stored_outputs = fixture_expected_outputs[index]
        comparisons = {
            "reference_vs_stored": (reference_outputs, stored_outputs),
            "wrapper_vs_stored": (wrapper_outputs, stored_outputs),
            "ort_vs_stored": (ort_outputs, stored_outputs),
            "wrapper_vs_reference": (wrapper_outputs, reference_outputs),
            "ort_vs_reference": (ort_outputs, reference_outputs),
            "ort_vs_wrapper": (ort_outputs, wrapper_outputs),
        }
        errors = {}
        for comparison, (left, right) in comparisons.items():
            maxima = _head_max_abs(left, right, np)
            errors[comparison] = maxima
            _update_maxima(aggregate, maxima)
            for head, maximum in maxima.items():
                if maximum > TOLERANCE:
                    violations.append(
                        f"fixture={index} {comparison} {head}: max_abs={maximum:.9g} exceeds {TOLERANCE}"
                    )
        fixture_records.append({"fixture_index": index, "input_length": length, "max_abs_by_comparison_and_head": errors})

    for record in fixture_records:
        for comparison, maxima in record["max_abs_by_comparison_and_head"].items():
            for head in HEADS:
                comparison_name = f"fixture_{comparison}"
                comparison_maxima.setdefault(comparison_name, {item: 0.0 for item in HEADS})
                comparison_maxima[comparison_name][head] = max(
                    comparison_maxima[comparison_name][head], maxima[head]
                )

    mask_sensitivity_record = sensitivity
    if violations:
        print(json.dumps({
            "acceptance_failed": True,
            "violations": violations,
            "max_by_head": aggregate,
            "comparison_max_by_head": comparison_maxima,
        }, sort_keys=True), file=sys.stderr, flush=True)
        raise ValueError(f"Numerical acceptance failed with {len(violations)} violations")
    checks.append("wrapper, independent reference, ORT, and all stored fixtures pass strict probability parity")

    tokenizer_copy = output_dir / "tokenizer.json"
    shutil.copyfile(tokenizer_path, tokenizer_copy)
    if sha256_file(tokenizer_copy) != TOKENIZER_SHA256 or tokenizer_copy.read_bytes() != tokenizer_path.read_bytes():
        raise ValueError("Copied tokenizer.json is not byte-identical to the pinned input")
    model_record = _input_file_record(onnx_path, "ClauseTagger.onnx")
    (output_dir / "LICENSE.txt").write_text(LICENSE_TEXT, encoding="utf-8", newline="\n")
    output_entries = list(output_dir.iterdir())
    output_files = {path.name for path in output_entries}
    if output_files != {"ClauseTagger.onnx", "tokenizer.json", "LICENSE.txt"} or any(
        not path.is_file() or path.is_symlink() for path in output_entries
    ):
        raise ValueError(f"Unexpected entries in output directory before report: {sorted(output_files)}")

    report = {
        "schema_version": 1,
        "identity": dict(IDENTITY),
        "training_metadata": {
            "training_status": IDENTITY["training_status"],
            "unit_policy": IDENTITY["unit_policy"],
            "encoding_revision": IDENTITY["encoding_revision"],
            "state_revision": revision,
        },
        "inputs": input_records,
        "converter_source": {
            "logical_source": CONVERTER_LOGICAL_SOURCE,
            "sha256": CONVERTER_SOURCE_SHA256,
        },
        "runtime": runtime,
        "export": {
            "format": "ONNX",
            "opset": 18,
            "dynamo": True,
            "external_data": False,
            "dynamic_sequence": {"dimension": "seq", "minimum": MIN_LEN, "maximum": MAX_LEN},
            "contract": contract_document(),
            "attention_configuration": attention_configuration,
        },
        "tokenizer_parity_inputs": {
            "ordinary_phrase": ORDINARY_PHRASE,
            "ordinary_input_rule": "CLS then phrase IDs indexed by (length*17 + i*29) % phrase_token_count then SEP",
            "random_input_rule": "real tokenizer vocabulary IDs excluding added_tokens special=true IDs; replacement sampling",
            "random_seed": SEED,
            "random_seed_per_length": "20250614 + length",
            "cls_token_id": CLS_TOKEN_ID,
            "sep_token_id": SEP_TOKEN_ID,
            "comma_token_id": COMMA_TOKEN_ID,
            "real_tokenizer_vocab_id_count": real_vocab_count,
            "special_token_id_count": len(special_ids),
        },
        "reference_provenance": {
            "model": "separately constructed CPU fp32 instance strict-loaded from the same complete checkpoint state",
            "mask": "independently built nested i,j inclusive support; full_attention=None",
            "outputs": "detached cloned CPU NumPy snapshots from backbone and all three heads",
            "wrapper": "ported MultiTagger.forward; no reference-mask helper shared",
        },
        "mask_checks": mask_records,
        "attention_sensitivity": mask_sensitivity_record,
        "parity": {
            "lengths": {"minimum": MIN_LEN, "maximum": MAX_LEN, "count": MAX_LEN - MIN_LEN + 1},
            "cases_per_length": ["ordinary", "random_vocab"],
            "tolerance_max_abs": TOLERANCE,
            "probability_sum_tolerance": PROBABILITY_SUM_TOLERANCE,
            "by_length_case_and_comparison": parity_by_length,
            "fixtures": fixture_records,
            "comparison_max_by_head": comparison_maxima,
            "max_by_head": aggregate,
        },
        "graph_validation": graph_record,
        "passed_checks": checks,
        "artifacts": {
            "ClauseTagger.onnx": model_record,
            "tokenizer.json": _input_file_record(tokenizer_copy, "tokenizer.json"),
            "LICENSE.txt": _input_file_record(output_dir / "LICENSE.txt", "LICENSE.txt"),
        },
    }
    report_path = output_dir / "export.json"
    _write_json(report_path, report)
    output_entries = list(output_dir.iterdir())
    output_files = {path.name for path in output_entries}
    if output_files != {"ClauseTagger.onnx", "tokenizer.json", "export.json", "LICENSE.txt"} or any(
        not path.is_file() or path.is_symlink() for path in output_entries
    ):
        raise ValueError(f"Successful output must contain exactly four regular files, got {sorted(output_files)}")
    return {
        "artifact": {"file": "ClauseTagger.onnx", "sha256": model_record["sha256"], "size_bytes": model_record["size_bytes"]},
        "max_by_head": aggregate,
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        validate_paths(args)
        summary = _run_export(args)
    except Exception as error:
        print(f"export failed ({type(error).__name__}): {error}", file=sys.stderr, flush=True)
        return 1
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

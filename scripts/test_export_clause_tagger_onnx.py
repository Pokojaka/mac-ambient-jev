from __future__ import annotations

import builtins
import errno
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from copy import deepcopy
from io import StringIO
from pathlib import Path
from unittest.mock import patch

import export_clause_tagger_onnx as exporter


HEAVY_MODULES = {"torch", "numpy", "onnx", "onnxruntime", "transformers", "tokenizers"}


def fixture_document() -> dict[str, object]:
    document: dict[str, object] = dict(exporter.IDENTITY)
    document.update(
        cls_token_id=exporter.CLS_TOKEN_ID,
        sep_token_id=exporter.SEP_TOKEN_ID,
        comma_token_id=exporter.COMMA_TOKEN_ID,
        fixtures=[
            {
                "input_ids": [exporter.CLS_TOKEN_ID, exporter.SEP_TOKEN_ID],
                "boundary_probs": [],
                "span_probs": [],
                "priority_probs": [],
            }
            for _ in range(13)
        ],
    )
    return document


def make_paths(root: Path):
    base_dir = root / "base"
    base_dir.mkdir()
    for filename in ("config.json", "model.safetensors", "tokenizer.json"):
        (base_dir / filename).write_bytes(b"base input")

    checkpoint_dir = root / "checkpoint"
    checkpoint_dir.mkdir()
    (checkpoint_dir / "config.json").write_bytes(b"checkpoint config")
    checkpoint = checkpoint_dir / "model.bin"
    checkpoint.write_bytes(b"checkpoint")

    tokenizer_dir = root / "tokenizer"
    tokenizer_dir.mkdir()
    tokenizer = tokenizer_dir / "tokenizer.json"
    tokenizer.write_bytes(b"tokenizer")

    fixture_dir = root / "fixture"
    fixture_dir.mkdir()
    fixture = fixture_dir / "fixtures.json"
    fixture.write_text("{}", encoding="utf-8")

    output_parent = root / "output-parent"
    output_parent.mkdir()
    args = exporter.parse_args(
        [
            "--base-dir", str(base_dir),
            "--checkpoint", str(checkpoint),
            "--tokenizer", str(tokenizer),
            "--fixture", str(fixture),
            "--output-dir", str(output_parent / "export"),
        ]
    )
    return args


class ExporterArgumentTests(unittest.TestCase):
    def test_each_required_flag_is_missing_error(self) -> None:
        required = ["--base-dir", "--checkpoint", "--tokenizer", "--fixture", "--output-dir"]
        values = ["/base", "/checkpoint", "/tokenizer", "/fixture", "/output"]
        for omitted in range(len(required)):
            argv = [part for index, pair in enumerate(zip(required, values)) if index != omitted for part in pair]
            with (
                self.subTest(missing=required[omitted]),
                self.assertRaises(SystemExit) as error,
                redirect_stderr(StringIO()),
            ):
                exporter.parse_args(argv)
            self.assertEqual(error.exception.code, 2)

    def test_empty_and_whitespace_paths_are_rejected_for_each_flag(self) -> None:
        flags = ["--base-dir", "--checkpoint", "--tokenizer", "--fixture", "--output-dir"]
        good = ["/base", "/checkpoint", "/tokenizer", "/fixture", "/output"]
        for index, flag in enumerate(flags):
            for invalid in ("", " \t "):
                argv = [part for pair in zip(flags, good) for part in pair]
                argv[2 * index + 1] = invalid
                with (
                    self.subTest(flag=flag, value=invalid),
                    self.assertRaises(SystemExit),
                    redirect_stderr(StringIO()),
                ):
                    exporter.parse_args(argv)

    def test_unknown_flag_is_rejected(self) -> None:
        with redirect_stderr(StringIO()), self.assertRaises(SystemExit) as error:
            exporter.parse_args(
                [
                    "--base-dir", "/base", "--checkpoint", "/checkpoint",
                    "--tokenizer", "/tokenizer", "--fixture", "/fixture",
                    "--output-dir", "/output", "--unknown",
                ]
            )
        self.assertEqual(error.exception.code, 2)

    def test_python_s_import_and_help_use_only_standard_library(self) -> None:
        script = Path(exporter.__file__).resolve()
        result = subprocess.run(
            [sys.executable, "-S", str(script), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--base-dir", result.stdout)
        self.assertEqual(result.stderr, "")


class ExporterPathValidationTests(unittest.TestCase):
    def test_good_paths_do_not_create_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            args = make_paths(Path(temporary_directory))
            exporter.validate_paths(args)
            self.assertFalse(args.output_dir.exists())

    def test_each_required_regular_input_rejects_missing_wrong_kind_and_unreadable(self) -> None:
        file_getters = {
            "base config": lambda args: args.base_dir / "config.json",
            "base model": lambda args: args.base_dir / "model.safetensors",
            "base tokenizer": lambda args: args.base_dir / "tokenizer.json",
            "checkpoint": lambda args: args.checkpoint,
            "checkpoint sibling config": lambda args: args.checkpoint.parent / "config.json",
            "tokenizer": lambda args: args.tokenizer,
            "fixture": lambda args: args.fixture,
        }
        for label, get_path in file_getters.items():
            for failure in ("missing", "wrong kind", "unreadable"):
                with self.subTest(input=label, failure=failure), tempfile.TemporaryDirectory() as temporary_directory:
                    args = make_paths(Path(temporary_directory))
                    target = get_path(args).resolve()
                    if failure == "missing":
                        target.unlink()
                    elif failure == "wrong kind":
                        target.unlink()
                        target.mkdir()
                    else:
                        real_access = exporter.os.access

                        def access(path, mode, *, effective_ids=False, follow_symlinks=True):
                            if Path(path).resolve() == target:
                                return False
                            return real_access(
                                path, mode, effective_ids=effective_ids,
                                follow_symlinks=follow_symlinks,
                            )

                        with patch.object(exporter.os, "access", side_effect=access):
                            with self.assertRaises(ValueError):
                                exporter.validate_paths(args)
                        continue
                    with self.assertRaises((FileNotFoundError, ValueError)):
                        exporter.validate_paths(args)

    def test_base_directory_must_exist_and_be_a_directory(self) -> None:
        for failure in ("missing", "wrong kind"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                args = make_paths(root)
                if failure == "missing":
                    args.base_dir.rename(root / "renamed-base")
                else:
                    import shutil
                    shutil.rmtree(args.base_dir)
                    args.base_dir.write_bytes(b"not a directory")
                with self.assertRaises(FileNotFoundError):
                    exporter.validate_paths(args)

    def test_existing_output_file_and_directory_are_rejected(self) -> None:
        for kind in ("file", "directory"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary_directory:
                args = make_paths(Path(temporary_directory))
                if kind == "file":
                    args.output_dir.write_bytes(b"keep")
                else:
                    args.output_dir.mkdir()
                with self.assertRaises(FileExistsError):
                    exporter.validate_paths(args)

    def test_broken_output_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            args = make_paths(Path(temporary_directory))
            try:
                args.output_dir.symlink_to(args.output_dir.parent / "missing-target")
            except NotImplementedError as error:
                self.skipTest(f"OS does not support symlink creation: {error}")
            except OSError as error:
                unsupported = {
                    errno.EACCES, errno.EPERM, errno.ENOSYS,
                    getattr(errno, "ENOTSUP", errno.EINVAL),
                }
                if error.errno in unsupported or getattr(error, "winerror", None) == 1314:
                    self.skipTest(f"OS does not permit symlink creation: {error}")
                raise
            with self.assertRaises(FileExistsError):
                exporter.validate_paths(args)

    def test_missing_output_parent_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            args = make_paths(Path(temporary_directory))
            args.output_dir = Path(temporary_directory) / "missing-parent" / "export"
            with self.assertRaises(FileNotFoundError):
                exporter.validate_paths(args)

    def test_output_inside_each_input_directory_is_rejected(self) -> None:
        for label in ("base", "checkpoint", "tokenizer", "fixture"):
            with self.subTest(input_directory=label), tempfile.TemporaryDirectory() as temporary_directory:
                args = make_paths(Path(temporary_directory))
                input_dir = {
                    "base": args.base_dir,
                    "checkpoint": args.checkpoint.parent,
                    "tokenizer": args.tokenizer.parent,
                    "fixture": args.fixture.parent,
                }[label]
                args.output_dir = input_dir / "export"
                with self.assertRaises(ValueError):
                    exporter.validate_paths(args)

    def test_main_path_failure_returns_before_heavy_import_or_export(self) -> None:
        attempts: list[str] = []
        real_import = builtins.__import__

        def guarded_import(name, *args, **kwargs):
            if name.partition(".")[0] in HEAVY_MODULES:
                attempts.append(name)
                raise AssertionError(f"unexpected heavy import: {name}")
            return real_import(name, *args, **kwargs)

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            argv = [
                "--base-dir", str(root / "missing-base"),
                "--checkpoint", str(root / "checkpoint"),
                "--tokenizer", str(root / "tokenizer"),
                "--fixture", str(root / "fixture"),
                "--output-dir", str(root / "out"),
            ]
            stderr = StringIO()
            with (
                patch("builtins.__import__", side_effect=guarded_import),
                patch.object(exporter, "_run_export", side_effect=AssertionError("export ran")) as run_export,
                redirect_stderr(stderr),
            ):
                self.assertEqual(exporter.main(argv), 1)
            run_export.assert_not_called()
            self.assertEqual(attempts, [])
            self.assertIn("Base model directory", stderr.getvalue())


class ContractValidationTests(unittest.TestCase):
    def test_complete_contract_is_accepted(self) -> None:
        document = exporter.contract_document()
        exporter.validate_contract(document["inputs"], document["outputs"])

    def test_reordered_extra_missing_names_and_heads_are_rejected(self) -> None:
        baseline = exporter.contract_document()
        cases = []
        reversed_outputs = deepcopy(baseline["outputs"])
        reversed_outputs.reverse()
        cases.append((deepcopy(baseline["inputs"]), reversed_outputs))
        extra_output = deepcopy(baseline["outputs"])
        extra_output.append(deepcopy(extra_output[0]))
        cases.append((deepcopy(baseline["inputs"]), extra_output))
        missing_output = deepcopy(baseline["outputs"][:-1])
        cases.append((deepcopy(baseline["inputs"]), missing_output))
        wrong_input_name = deepcopy(baseline["inputs"])
        wrong_input_name[0]["name"] = "tokens"
        cases.append((wrong_input_name, deepcopy(baseline["outputs"])))
        wrong_head_name = deepcopy(baseline["outputs"])
        wrong_head_name[1]["name"] = "other_probs"
        cases.append((deepcopy(baseline["inputs"]), wrong_head_name))
        for inputs, outputs in cases:
            with self.subTest(inputs=inputs, outputs=outputs), self.assertRaises(ValueError):
                exporter.validate_contract(inputs, outputs)

    def test_dtypes_shapes_dimensions_and_extra_keys_are_rejected(self) -> None:
        baseline = exporter.contract_document()
        mutations = []

        def mutation(label, side, index, key, value):
            inputs, outputs = deepcopy(baseline["inputs"]), deepcopy(baseline["outputs"])
            collection = inputs if side == "inputs" else outputs
            collection[index][key] = value
            mutations.append((label, inputs, outputs))

        mutation("int32 input", "inputs", 0, "dtype", "int32")
        mutation("float16 output", "outputs", 0, "dtype", "float16")
        mutation("wrong batch", "inputs", 0, "shape", [2, "seq"])
        mutation("wrong channel", "outputs", 0, "shape", [1, "seq", 3])
        mutation("wrong rank", "outputs", 2, "shape", [1, 2, 1])
        mutation("fixed sequence", "inputs", 0, "shape", [1, 128])
        mutation("mismatched symbolic axis", "outputs", 1, "shape", [1, "length", 4])
        mutation("unknown dimension", "inputs", 0, "shape", [1, None])
        mutation("boolean dimension", "inputs", 0, "shape", [True, "seq"])
        extra_key_inputs = deepcopy(baseline["inputs"])
        extra_key_inputs[0]["optional"] = False
        mutations.append(("extra key", extra_key_inputs, deepcopy(baseline["outputs"])))
        for label, inputs, outputs in mutations:
            with self.subTest(case=label), self.assertRaises(ValueError):
                exporter.validate_contract(inputs, outputs)

    def test_contract_document_is_a_defensive_copy(self) -> None:
        document = exporter.contract_document()
        document["inputs"][0]["shape"][0] = 99
        document["outputs"][0]["name"] = "mutated"
        fresh = exporter.contract_document()
        self.assertEqual(fresh["inputs"][0]["shape"], [1, "seq"])
        self.assertEqual(fresh["outputs"][0]["name"], "boundary_probs")


class InputIdValidationTests(unittest.TestCase):
    def test_minimum_and_maximum_lengths_are_accepted(self) -> None:
        exporter.validate_input_ids([exporter.CLS_TOKEN_ID, exporter.SEP_TOKEN_ID], 1000)
        exporter.validate_input_ids(
            [exporter.CLS_TOKEN_ID] + [7] * (192 - 2) + [exporter.SEP_TOKEN_ID], 1000
        )

    def test_length_bounds_token_bounds_and_special_endpoints_are_rejected(self) -> None:
        cases = [
            ([], 1000),
            ([6] + [7] * 191 + [4], 1000),
            ([6, -1, 4], 1000),
            ([6, 1000, 4], 1000),
            ([5, 7, 4], 1000),
            ([6, 7, 3], 1000),
        ]
        for ids, vocab_size in cases:
            with self.subTest(ids=ids[:3], length=len(ids)), self.assertRaises(ValueError):
                exporter.validate_input_ids(ids, vocab_size)

    def test_boolean_and_float_ids_are_rejected(self) -> None:
        for ids in ([6, True, 4], [6, 1.0, 4]):
            with self.subTest(ids=ids), self.assertRaises(ValueError):
                exporter.validate_input_ids(ids, 1000)

    def test_invalid_vocabulary_sizes_are_rejected(self) -> None:
        for vocab_size in (0, -1, 2.5, True):
            with self.subTest(vocab_size=vocab_size), self.assertRaises(ValueError):
                exporter.validate_input_ids([6, 4], vocab_size)


class FixtureValidationTests(unittest.TestCase):
    def test_repository_fixture_digest_and_document_are_pinned_and_valid(self) -> None:
        fixture_path = (
            Path(exporter.__file__).resolve().parent.parent
            / "app/MacAmbientJev/Tests/MacAmbientJevClauseTaggerFixtures/Resources/ClauseTaggerFixtures.json"
        )
        self.assertEqual(
            exporter.FIXTURE_SHA256,
            "41650293a866faba413cabaf568807243dc4684f4fca1f9660a0d26ec0860726",
        )
        self.assertEqual(exporter.sha256_file(fixture_path), exporter.FIXTURE_SHA256)
        document = json.loads(fixture_path.read_text(encoding="utf-8"))
        exporter.validate_fixture_document(document)

    def test_thirteen_case_document_with_all_identity_and_heads_is_accepted(self) -> None:
        document = fixture_document()
        self.assertEqual(len(exporter.IDENTITY), 6)
        exporter.validate_fixture_document(document)

    def test_missing_extra_fields_and_changed_case_count_are_rejected(self) -> None:
        valid = fixture_document()
        cases = []
        missing = deepcopy(valid)
        del missing["model_id"]
        cases.append(("missing identity field", missing))
        extra = deepcopy(valid)
        extra["unexpected"] = True
        cases.append(("extra document field", extra))
        short = deepcopy(valid)
        short["fixtures"].pop()
        cases.append(("12 cases", short))
        long = deepcopy(valid)
        long["fixtures"].append(deepcopy(long["fixtures"][0]))
        cases.append(("14 cases", long))
        for label, document in cases:
            with self.subTest(case=label), self.assertRaises(ValueError):
                exporter.validate_fixture_document(document)

    def test_each_identity_field_and_token_id_metadata_must_match(self) -> None:
        valid = fixture_document()
        mutations = []
        for key, value in exporter.IDENTITY.items():
            changed = deepcopy(valid)
            changed[key] = str(value) + "-changed"
            mutations.append((key, changed))
        for key in ("cls_token_id", "sep_token_id", "comma_token_id"):
            changed = deepcopy(valid)
            changed[key] += 1
            mutations.append((key, changed))
        for key, document in mutations:
            with self.subTest(field=key), self.assertRaises(ValueError):
                exporter.validate_fixture_document(document)

    def test_missing_head_and_invalid_case_ids_are_rejected(self) -> None:
        valid = fixture_document()
        missing_head = deepcopy(valid)
        del missing_head["fixtures"][0]["span_probs"]
        bad_start = deepcopy(valid)
        bad_start["fixtures"][0]["input_ids"][0] = 5
        bad_end = deepcopy(valid)
        bad_end["fixtures"][0]["input_ids"][-1] = 5
        bool_id = deepcopy(valid)
        bool_id["fixtures"][0]["input_ids"][1] = True
        float_id = deepcopy(valid)
        float_id["fixtures"][0]["input_ids"][1] = 4.0
        for label, document in (
            ("missing head", missing_head), ("wrong CLS", bad_start),
            ("wrong SEP", bad_end), ("boolean ID", bool_id), ("float ID", float_id),
        ):
            with self.subTest(case=label), self.assertRaises(ValueError):
                exporter.validate_fixture_document(document)


class HashingTests(unittest.TestCase):
    def test_sha256_file_streams_and_matches_known_content_digest(self) -> None:
        payload = bytes(range(256)) * 8193
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "payload.bin"
            known_path = Path(temporary_directory) / "known.txt"
            known_path.write_bytes(b"abc")
            self.assertEqual(
                exporter.sha256_file(known_path),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            )
            path.write_bytes(payload)
            real_open = Path.open
            read_sizes: list[int] = []

            class TrackingReader:
                def __init__(self, stream):
                    self.stream = stream

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.stream.__exit__(*args)

                def read(self, size=-1):
                    read_sizes.append(size)
                    return self.stream.read(size)

            def tracked_open(target, *args, **kwargs):
                stream = real_open(target, *args, **kwargs)
                return TrackingReader(stream) if target == path else stream

            with patch.object(Path, "open", tracked_open):
                actual = exporter.sha256_file(path)
            self.assertEqual(actual, hashlib.sha256(payload).hexdigest())
            self.assertGreaterEqual(len(read_sizes), 3)
            self.assertTrue(all(size == 1024 * 1024 for size in read_sizes))

    def test_state_revision_sorts_names_and_frames_name_and_tensor_lengths(self) -> None:
        class FakeBytes:
            def __init__(self, value: bytes):
                self.value = value

            def tobytes(self, order):
                if order != "C":
                    raise AssertionError(f"unexpected order: {order}")
                return self.value

        class FakeTensor:
            def __init__(self, value: bytes):
                self.value = value

            def detach(self):
                return self

            def cpu(self):
                return self

            def contiguous(self):
                return self

            def numpy(self):
                return FakeBytes(self.value)

        class FakeModel:
            def state_dict(self):
                return {"z": FakeTensor(b"\x00\xff"), "a": FakeTensor(b"tensor")}

        framed = bytearray()
        for name, tensor_bytes in (("a", b"tensor"), ("z", b"\x00\xff")):
            name_bytes = name.encode("utf-8")
            framed.extend(len(name_bytes).to_bytes(8, "big"))
            framed.extend(name_bytes)
            framed.extend(len(tensor_bytes).to_bytes(8, "big"))
            framed.extend(tensor_bytes)
        expected = hashlib.sha256(framed).hexdigest()
        self.assertEqual(exporter._state_revision(FakeModel()), expected)


class LicenseTextTests(unittest.TestCase):
    def test_license_text_matches_third_party_notices_mit_block(self) -> None:
        notices = (Path(__file__).resolve().parent.parent / "THIRD-PARTY-NOTICES.md").read_text(encoding="utf-8")
        mit = exporter.LICENSE_TEXT.split("\n\n", 1)[1]
        self.assertIn(mit.rstrip("\n"), notices)
        self.assertIn("6a0406481a741f0f74f23c03a8b958acfd276b7c", exporter.LICENSE_TEXT.split("\n", 1)[0])


if __name__ == "__main__":
    unittest.main()

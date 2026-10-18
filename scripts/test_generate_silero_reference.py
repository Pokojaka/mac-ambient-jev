from __future__ import annotations

import importlib.metadata
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import MagicMock, patch

import fetch_silero_vad
import generate_silero_reference as reference_generator


class FakeAudio:
    def __len__(self) -> int:
        return 100 * reference_generator.FRAME_SAMPLES

    def __getitem__(self, frame_slice: slice) -> MagicMock:
        return MagicMock()


def fake_result(probability: float) -> MagicMock:
    result = MagicMock()
    result.item.return_value = probability
    return result


def fake_numpy() -> ModuleType:
    numpy = ModuleType("numpy")
    numpy.__version__ = "test-numpy"
    numpy.float32 = "float32"
    numpy.float64 = "float64"
    numpy.mean = lambda values, dtype: 1.0
    numpy.square = lambda values: 1.0
    numpy.sqrt = lambda value: 1.0
    return numpy


def fake_torch() -> ModuleType:
    torch = ModuleType("torch")
    torch.__version__ = "test-torch"
    torch.float32 = "float32"
    torch.set_num_threads = MagicMock()
    torch.from_numpy = MagicMock(side_effect=lambda frame: frame)
    torch.zeros = MagicMock(return_value=MagicMock())
    return torch


class GenerateSileroReferenceTests(unittest.TestCase):
    def run_main(
        self,
        voiced_above_threshold_count: int,
        silence_probabilities: list[float],
        existing_json: str | None,
    ) -> tuple[int, str, str, bool, str | None]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository_root = Path(temporary_directory)
            scripts_directory = repository_root / "scripts"
            scripts_directory.mkdir()
            model_path = repository_root / "model.onnx"
            model_path.write_bytes(b"model")
            resources_directory = (
                repository_root
                / "app/MacAmbientJev/Tests/MacAmbientJevONNXTests/Resources"
            )
            resources_directory.mkdir(parents=True)
            audio_path = resources_directory / "silero_speech.wav"
            audio_path.write_bytes(b"fixture")
            output_path = resources_directory / "silero_reference.json"
            if existing_json is not None:
                output_path.write_text(existing_json, encoding="utf-8")

            voiced_probabilities = [
                0.9 if index < voiced_above_threshold_count else 0.0
                for index in range(100)
            ]
            wrapper = MagicMock()
            wrapper.side_effect = [
                fake_result(probability)
                for probability in voiced_probabilities + silence_probabilities
            ]
            upstream_module = SimpleNamespace(
                OnnxWrapper=MagicMock(return_value=wrapper)
            )
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                patch.object(
                    reference_generator,
                    "__file__",
                    str(scripts_directory / "generate_silero_reference.py"),
                ),
                patch.dict(
                    sys.modules,
                    {
                        "numpy": fake_numpy(),
                        "onnxruntime": ModuleType("onnxruntime"),
                        "torch": fake_torch(),
                    },
                ),
                patch.object(reference_generator, "sha256_file", return_value=fetch_silero_vad.SHA256),
                patch.object(
                    reference_generator,
                    "read_audio",
                    return_value=(FakeAudio(), "audio-sha256"),
                ),
                patch.object(
                    reference_generator,
                    "load_upstream_wrapper",
                    return_value=(upstream_module, "wrapper-sha256"),
                ),
                patch.object(reference_generator, "REFERENCE_INDICES", (0, 1)),
                patch.object(importlib.metadata, "version", return_value="fixed-packaging-version"),
                patch.object(
                    sys,
                    "argv",
                    ["generate_silero_reference.py", "--model", str(model_path)],
                ),
                redirect_stdout(stdout),
                redirect_stderr(stderr),
            ):
                sys.modules["onnxruntime"].__version__ = "1.31.0"
                return_code = reference_generator.main()

            output_exists = output_path.exists()
            output_content = (
                output_path.read_text(encoding="utf-8") if output_exists else None
            )
            return (
                return_code,
                stdout.getvalue(),
                stderr.getvalue(),
                output_exists,
                output_content,
            )

    def test_voiced_fraction_below_70_percent_fails_without_overwriting_json(self) -> None:
        sentinel = '{"sentinel": true}\n'
        return_code, stdout, stderr, output_exists, output_content = self.run_main(
            69, [0.0] * 64, sentinel
        )

        self.assertEqual(return_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("70%", stderr)
        self.assertEqual(output_exists, True)
        self.assertEqual(output_content, sentinel)

    def test_silence_probability_at_0_1_fails_without_creating_json(self) -> None:
        silence_probabilities = [0.0] * 63 + [0.1]
        return_code, stdout, stderr, output_exists, output_content = self.run_main(
            100, silence_probabilities, None
        )

        self.assertEqual(return_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("0.1", stderr)
        self.assertEqual(output_exists, False)
        self.assertIsNone(output_content)

    def test_70_percent_and_silence_below_0_1_write_reference_json(self) -> None:
        return_code, stdout, stderr, output_exists, output_content = self.run_main(
            70, [0.099] * 64, None
        )

        self.assertEqual(return_code, 0)
        self.assertEqual(stderr, "")
        self.assertIn("packaging: fixed-packaging-version", stdout)
        self.assertNotIn("懸念", stdout + stderr)
        self.assertEqual(output_exists, True)
        reference_data = json.loads(output_content)
        self.assertEqual(reference_data["frameCount"], 100)
        self.assertEqual(reference_data["references"], [
            {"frameIndex": 0, "probability": 0.9},
            {"frameIndex": 1, "probability": 0.9},
        ])


if __name__ == "__main__":
    unittest.main()

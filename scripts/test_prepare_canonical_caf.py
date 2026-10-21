from __future__ import annotations

import importlib.util
import struct
import tempfile
import unittest
import wave
from pathlib import Path

SCRIPT = Path(__file__).with_name("prepare_canonical_caf.py")
SPEC = importlib.util.spec_from_file_location("prepare_canonical_caf", SCRIPT)
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


def write_wav(path: Path, samples: list[int], rate: int = 16000, channels: int = 1) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(struct.pack(f"<{len(samples)}h", *samples))


class PrepareCanonicalCafTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_layout_and_samples(self) -> None:
        write_wav(self.root / "a.wav", [0, 16384, -32768, 32767])
        caf, frames = prepare.canonical_caf_bytes(self.root / "a.wav")
        self.assertEqual(frames, 4)
        self.assertEqual(caf[:8], b"caff\x00\x01\x00\x00")
        self.assertEqual(caf[8:12], b"desc")
        self.assertEqual(struct.unpack(">q", caf[12:20])[0], 32)
        rate, fmt, flags, bytes_per_packet, frames_per_packet, channels, bits = struct.unpack(">dIIIIII", caf[20:52])
        self.assertEqual((rate, fmt, flags, bytes_per_packet, frames_per_packet, channels, bits), (16000.0, 0x6C70636D, 3, 4, 1, 1, 32))
        self.assertEqual(caf[52:56], b"data")
        self.assertEqual(struct.unpack(">q", caf[56:64])[0], 4 + 16)
        self.assertEqual(struct.unpack("<4f", caf[68:]), (0.0, 0.5, -1.0, 32767 / 32768))

    def test_rejects_other_formats(self) -> None:
        write_wav(self.root / "rate.wav", [1, 2], rate=48000)
        write_wav(self.root / "stereo.wav", [1, 2], channels=2)
        write_wav(self.root / "empty.wav", [])
        for name in ("rate.wav", "stereo.wav", "empty.wav"):
            with self.assertRaises(ValueError):
                prepare.canonical_caf_bytes(self.root / name)

    def test_output_is_never_replaced(self) -> None:
        write_wav(self.root / "a.wav", [1, 2])
        output = self.root / "a.caf"
        self.assertEqual(prepare.main(["--wav", str(self.root / "a.wav"), "--output", str(output)]), 0)
        before = output.read_bytes()
        self.assertEqual(prepare.main(["--wav", str(self.root / "a.wav"), "--output", str(output)]), 1)
        self.assertEqual(output.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

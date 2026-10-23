"""Independent stdlib fixtures for the native RecordingFLAC acceptance decoder."""

from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from engine_acceptance_flac import validate_flac


_FIXED_COEFFICIENTS = (
    (1,),
    (1, -1),
    (1, -2, 1),
    (1, -3, 3, -1),
    (1, -4, 6, -4, 1),
)
_FRAME_START = 42


def _crc8(data: bytes) -> int:
    crc = 0
    for byte in data:
        for shift in range(7, -1, -1):
            incoming = (byte >> shift) & 1
            top = (crc >> 7) & 1
            crc = (crc << 1) & 0xFF
            if top ^ incoming:
                crc ^= 0x07
    return crc


def _crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        for shift in range(7, -1, -1):
            incoming = (byte >> shift) & 1
            top = (crc >> 15) & 1
            crc = (crc << 1) & 0xFFFF
            if top ^ incoming:
                crc ^= 0x8005
    return crc


class _BitWriter:
    def __init__(self) -> None:
        self.bits: list[int] = []

    def write(self, value: int, width: int) -> None:
        if width < 0 or value < 0 or (width == 0 and value != 0):
            raise ValueError("invalid test fixture bit field")
        if width and value >= (1 << width):
            raise ValueError("test fixture value does not fit bit field")
        self.bits.extend((value >> shift) & 1 for shift in range(width - 1, -1, -1))

    def write_signed(self, value: int, width: int) -> None:
        self.write(value & ((1 << width) - 1), width)

    def write_unary(self, quotient: int) -> None:
        self.write(0, quotient)
        self.write(1, 1)

    def finish(self) -> bytes:
        while len(self.bits) % 8:
            self.bits.append(0)
        output = bytearray()
        for offset in range(0, len(self.bits), 8):
            byte = 0
            for bit in self.bits[offset : offset + 8]:
                byte = (byte << 1) | bit
            output.append(byte)
        return bytes(output)


def _coded_number(number: int) -> bytes:
    if number <= 0x7F:
        return bytes((number,))
    if number <= 0x7FF:
        length, prefix = 2, 0xC0
    elif number <= 0xFFFF:
        length, prefix = 3, 0xE0
    elif number <= 0x1FFFFF:
        length, prefix = 4, 0xF0
    elif number <= 0x3FFFFFF:
        length, prefix = 5, 0xF8
    elif number <= 0x7FFFFFFF:
        length, prefix = 6, 0xFC
    else:
        raise ValueError("test frame number is too large")
    encoded = bytearray((prefix | (number >> (6 * (length - 1))),))
    for index in range(length - 2, -1, -1):
        encoded.append(0x80 | ((number >> (index * 6)) & 0x3F))
    return bytes(encoded)


def _frame_header(block_size: int, number: int, rate_code: int = 5) -> bytes:
    if block_size <= 256:
        block_code = 6
        extra = bytes((block_size - 1,))
    elif block_size < 4096:
        block_code = 7
        extra = (block_size - 1).to_bytes(2, "big")
    elif block_size == 4096:
        block_code = 12
        extra = b""
    else:
        raise ValueError("test frame block size is outside the profile")
    header = bytearray((0xFF, 0xF8, (block_code << 4) | rate_code, 0x08))
    header.extend(_coded_number(number))
    header.extend(extra)
    header.append(_crc8(header))
    return bytes(header)


def _rice(residual: int, parameter: int) -> tuple[int, int]:
    folded = residual * 2 if residual >= 0 else (-residual * 2) - 1
    return folded >> parameter, folded & ((1 << parameter) - 1)


def _make_frame(
    samples: list[int],
    number: int,
    encoding: str,
    *,
    order: int = 0,
    partition_order: int = 0,
    parameters: list[int] | None = None,
    escape_width: int = 0,
    rate_code: int = 5,
) -> bytes:
    if not samples:
        raise ValueError("empty test frame")
    writer = _BitWriter()
    if encoding == "constant":
        if any(sample != samples[0] for sample in samples):
            raise ValueError("constant fixture is not constant")
        writer.write(0, 8)
        writer.write_signed(samples[0], 16)
    elif encoding == "verbatim":
        writer.write(0x02, 8)
        for sample in samples:
            writer.write_signed(sample, 16)
    elif encoding == "fixed":
        if order > 4 or order > len(samples):
            raise ValueError("invalid fixed fixture order")
        residuals: list[int] = []
        for index in range(order, len(samples)):
            prediction = sum(
                -coefficient * samples[index - offset]
                for offset, coefficient in enumerate(_FIXED_COEFFICIENTS[order][1:], start=1)
            )
            residuals.append(samples[index] - prediction)

        writer.write(0x10 + order * 2, 8)
        for sample in samples[:order]:
            writer.write_signed(sample, 16)
        writer.write(0, 2)  # Rice coding method 0 (4-bit parameter).
        writer.write(partition_order, 4)
        partition_count = 1 << partition_order
        if len(samples) % partition_count:
            raise ValueError("test block is not evenly partitioned")
        samples_per_partition = len(samples) // partition_count
        if parameters is None:
            parameters = [2] * partition_count
        if len(parameters) != partition_count:
            raise ValueError("test fixture needs one Rice parameter per partition")
        residual_position = 0
        for partition, parameter in enumerate(parameters):
            writer.write(parameter, 4)
            residual_count = samples_per_partition - (order if partition == 0 else 0)
            partition_residuals = residuals[residual_position : residual_position + residual_count]
            residual_position += residual_count
            if parameter == 15:
                writer.write(escape_width, 5)
                for residual in partition_residuals:
                    writer.write_signed(residual, escape_width)
            else:
                for residual in partition_residuals:
                    quotient, remainder = _rice(residual, parameter)
                    writer.write_unary(quotient)
                    writer.write(remainder, parameter)
        if residual_position != len(residuals):
            raise ValueError("test fixture residual partition count mismatch")
    else:
        raise ValueError(f"unknown test fixture encoding {encoding}")

    frame_body = writer.finish()
    without_crc = _frame_header(len(samples), number, rate_code) + frame_body
    return without_crc + _crc16(without_crc).to_bytes(2, "big")


def _make_file(frames: list[bytes], sample_blocks: list[list[int]]) -> bytes:
    samples = [sample for block in sample_blocks for sample in block]
    pcm = b"".join(sample.to_bytes(2, "little", signed=True) for sample in samples)
    digest = hashlib.md5(pcm, usedforsecurity=False).digest()
    frame_sizes = [len(frame) for frame in frames]
    format_word = (16_000 << 44) | (15 << 36) | len(samples)
    streaminfo = bytearray()
    streaminfo.extend((4096).to_bytes(2, "big"))
    streaminfo.extend((4096).to_bytes(2, "big"))
    streaminfo.extend(min(frame_sizes).to_bytes(3, "big"))
    streaminfo.extend(max(frame_sizes).to_bytes(3, "big"))
    streaminfo.extend(format_word.to_bytes(8, "big"))
    streaminfo.extend(digest)
    metadata = b"\x80\x00\x00\x22" + bytes(streaminfo)
    return b"fLaC" + metadata + b"".join(frames)


def _fix_frame_checksums(data: bytearray, frame_start: int = _FRAME_START) -> None:
    block_code = data[frame_start + 2] >> 4
    number_length = 1
    first_number_byte = data[frame_start + 4]
    if first_number_byte >= 0x80:
        number_length = 2
        if first_number_byte >= 0xE0:
            number_length = 3
        if first_number_byte >= 0xF0:
            number_length = 4
        if first_number_byte >= 0xF8:
            number_length = 5
        if first_number_byte >= 0xFC:
            number_length = 6
    extra_length = 1 if block_code == 6 else 2 if block_code == 7 else 0
    crc_position = frame_start + 4 + number_length + extra_length
    data[crc_position] = _crc8(bytes(data[frame_start:crc_position]))
    data[-2:] = _crc16(bytes(data[frame_start:-2])).to_bytes(2, "big")


class EngineAcceptanceFLACTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def _validate(self, content: bytes) -> dict[str, int | str | list[int]]:
        path = self.directory / "fixture.flac"
        path.write_bytes(content)
        return validate_flac(path)

    def _rejects(self, content: bytes, diagnostic: str) -> None:
        path = self.directory / "invalid.flac"
        path.write_bytes(content)
        with self.assertRaisesRegex(ValueError, diagnostic):
            validate_flac(path)

    def test_crc_reference_vectors(self) -> None:
        vector = b"123456789"
        self.assertEqual(_crc8(vector), 0xF4)
        self.assertEqual(_crc16(vector), 0xFEE8)

    def test_constant_and_verbatim_fixtures(self) -> None:
        cases = (
            ([123, 123, 123, 123, 123], "constant"),
            ([-32768, -1, 0, 1, 32767], "verbatim"),
        )
        for samples, encoding in cases:
            with self.subTest(encoding=encoding):
                frame = _make_frame(samples, 0, encoding)
                result = self._validate(_make_file([frame], [samples]))
                self.assertEqual(result["samples"], samples)
                self.assertEqual(result["sample_count"], len(samples))
                self.assertEqual(result["frame_count"], 1)
                self.assertEqual(result["sample_rate"], 16_000)
                self.assertEqual(result["channels"], 1)
                self.assertEqual(result["bits_per_sample"], 16)
                expected_md5 = hashlib.md5(
                    b"".join(s.to_bytes(2, "little", signed=True) for s in samples),
                    usedforsecurity=False,
                ).hexdigest()
                self.assertEqual(result["md5"], expected_md5)

    def test_fixed_predictor_orders_zero_through_four(self) -> None:
        samples = [-200, -155, -95, -20, 70, 175, 300, 440]
        for order in range(5):
            with self.subTest(order=order):
                frame = _make_frame(
                    samples,
                    0,
                    "fixed",
                    order=order,
                    partition_order=1,
                    parameters=[8, 8],
                )
                result = self._validate(_make_file([frame], [samples]))
                self.assertEqual(result["samples"], samples)
                self.assertEqual(result["sample_count"], 8)
                self.assertEqual(result["frame_count"], 1)

    def test_partitioned_escape_rice_and_multiple_frames(self) -> None:
        escape_samples = [10, 11, 9, 12, 10, 14, 13, 13]
        escape_frame = _make_frame(
            escape_samples,
            0,
            "fixed",
            order=1,
            partition_order=1,
            parameters=[15, 15],
            escape_width=4,
        )
        first_samples = [7] * 4096
        last_samples = [-8, 12, 31, -44, 100]
        first_frame = _make_frame(first_samples, 0, "constant")
        last_frame = _make_frame(last_samples, 1, "verbatim")
        combined = _make_file([first_frame, last_frame], [first_samples, last_samples])

        escape_result = self._validate(_make_file([escape_frame], [escape_samples]))
        self.assertEqual(escape_result["samples"], escape_samples)
        result = self._validate(combined)
        self.assertEqual(result["samples"], first_samples + last_samples)
        self.assertEqual(result["sample_count"], 4101)
        self.assertEqual(result["frame_count"], 2)

    def test_corrupt_header_and_frame_crc(self) -> None:
        samples = [1, -2, 3, -4]
        original = _make_file([_make_frame(samples, 0, "verbatim")], [samples])

        header_corrupt = bytearray(original)
        header_corrupt[_FRAME_START + 6] ^= 0x01
        self._rejects(bytes(header_corrupt), "frame-header CRC-8 mismatch")

        footer_corrupt = bytearray(original)
        footer_corrupt[-1] ^= 0x01
        self._rejects(bytes(footer_corrupt), "frame 0 CRC-16 mismatch")

    def test_streaminfo_md5_sample_count_and_metadata_sizes(self) -> None:
        samples = [9, 8, 7, 6, 5]
        original = _make_file([_make_frame(samples, 0, "verbatim")], [samples])

        md5_corrupt = bytearray(original)
        md5_corrupt[8 + 33] ^= 0x01
        self._rejects(bytes(md5_corrupt), "STREAMINFO PCM MD5 mismatch")

        count_corrupt = bytearray(original)
        format_word = int.from_bytes(count_corrupt[18:26], "big")
        count_corrupt[18:26] = (format_word + 1).to_bytes(8, "big")
        self._rejects(bytes(count_corrupt), "block size .* does not match expected")

        size_corrupt = bytearray(original)
        size_corrupt[7] = 33
        self._rejects(bytes(size_corrupt), "STREAMINFO metadata size is 33; expected 34")

    def test_truncation_trailing_bytes_and_frame_size_extrema(self) -> None:
        samples = [20, 21, 22]
        original = _make_file([_make_frame(samples, 0, "verbatim")], [samples])
        self._rejects(original[:-1], "truncated frame CRC-16")
        self._rejects(original + b"\x00", "trailing bytes after final FLAC frame: 1")

        extrema_corrupt = bytearray(original)
        stored_minimum = int.from_bytes(extrema_corrupt[12:15], "big")
        extrema_corrupt[12:15] = (stored_minimum + 1).to_bytes(3, "big")
        self._rejects(bytes(extrema_corrupt), "minimum frame size .* does not match actual")

    def test_unsupported_frame_format_and_subframe(self) -> None:
        samples = [1, 2, 3, 4]
        original = _make_file([_make_frame(samples, 0, "verbatim")], [samples])

        bad_rate = bytearray(original)
        bad_rate[_FRAME_START + 2] &= 0xF0
        _fix_frame_checksums(bad_rate)
        self._rejects(bytes(bad_rate), "unsupported frame sample-rate code 0")

        unsupported_subframe = bytearray(original)
        unsupported_subframe[_FRAME_START + 7] = 0x40
        _fix_frame_checksums(unsupported_subframe)
        self._rejects(bytes(unsupported_subframe), "unsupported subframe type 32")


if __name__ == "__main__":
    unittest.main()

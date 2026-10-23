"""Strict decoder for the small native RecordingFLAC acceptance profile.

This intentionally implements only the format emitted by RecordingFLAC.swift:
16 kHz mono signed 16-bit PCM, fixed 4096-sample frames (except the last),
and constant, verbatim, or fixed-predictor subframes using 4-bit Rice coding.
"""

from __future__ import annotations

import hashlib
from pathlib import Path


_FRAME_SAMPLES = 4096
_PCM_MIN = -(1 << 15)
_PCM_MAX = (1 << 15) - 1
_RESIDUAL_FOLDED_MAX = (1 << 32) - 1
_FIXED_COEFFICIENTS = (
    (1,),
    (1, -1),
    (1, -2, 1),
    (1, -3, 3, -1),
    (1, -4, 6, -4, 1),
)


def _crc8(data: bytes) -> int:
    """CRC-8/FLAC: polynomial 0x07, initial value zero."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ (0x07 if crc & 0x80 else 0)) & 0xFF
    return crc


def _crc16(data: bytes) -> int:
    """CRC-16/FLAC: polynomial 0x8005, initial value zero."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x8005 if crc & 0x8000 else 0)) & 0xFFFF
    return crc


def _signed(value: int, bit_count: int) -> int:
    sign_bit = 1 << (bit_count - 1)
    return value - (1 << bit_count) if value & sign_bit else value


class _BitReader:
    """MSB-first bit reader over the complete file, with explicit bounds checks."""

    def __init__(self, data: bytes, bit_position: int) -> None:
        self.data = data
        self.bit_position = bit_position

    def read(self, bit_count: int, field: str) -> int:
        if bit_count < 0:
            raise ValueError(f"invalid negative width while reading {field}")
        if self.bit_position + bit_count > len(self.data) * 8:
            raise ValueError(f"truncated {field}")
        value = 0
        remaining = bit_count
        while remaining:
            byte_index, bit_offset = divmod(self.bit_position, 8)
            take = min(remaining, 8 - bit_offset)
            shift = 8 - bit_offset - take
            mask = (1 << take) - 1
            value = (value << take) | ((self.data[byte_index] >> shift) & mask)
            self.bit_position += take
            remaining -= take
        return value

    def read_signed(self, bit_count: int, field: str) -> int:
        if bit_count == 0:
            return 0
        return _signed(self.read(bit_count, field), bit_count)

    def read_unary(self, maximum: int, field: str) -> int:
        quotient = 0
        while True:
            if self.read(1, field):
                return quotient
            quotient += 1
            if quotient > maximum:
                raise ValueError(f"{field} exceeds the signed 32-bit residual range")

    def align_zero(self, field: str) -> None:
        padding = (-self.bit_position) % 8
        if padding and self.read(padding, field) != 0:
            raise ValueError(f"nonzero {field} padding bits")


def _read_byte(data: bytes, position: int, field: str) -> tuple[int, int]:
    if position >= len(data):
        raise ValueError(f"truncated {field}")
    return data[position], position + 1


def _read_coded_number(data: bytes, position: int) -> tuple[int, int]:
    """Read the canonical UTF-8-style integer used by fixed frame headers."""
    first, position = _read_byte(data, position, "frame number")
    if first < 0x80:
        return first, position

    if 0xC2 <= first <= 0xDF:
        length, value = 2, first & 0x1F
    elif 0xE0 <= first <= 0xEF:
        length, value = 3, first & 0x0F
    elif 0xF0 <= first <= 0xF7:
        length, value = 4, first & 0x07
    elif 0xF8 <= first <= 0xFB:
        length, value = 5, first & 0x03
    elif 0xFC <= first <= 0xFD:
        length, value = 6, first & 0x01
    else:
        raise ValueError("invalid UTF-8-style frame number lead byte")

    for _ in range(length - 1):
        continuation, position = _read_byte(data, position, "frame number continuation")
        if continuation & 0xC0 != 0x80:
            raise ValueError("invalid UTF-8-style frame number continuation")
        value = (value << 6) | (continuation & 0x3F)

    minimum = (0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000)[length]
    if value < minimum:
        raise ValueError("non-canonical UTF-8-style frame number")
    return value, position


def _parse_frame_header(data: bytes, start: int) -> tuple[int, int, int]:
    if start + 4 > len(data):
        raise ValueError("truncated frame header")
    if data[start] != 0xFF or data[start + 1] != 0xF8:
        if data[start] == 0xFF and data[start + 1] == 0xF9:
            raise ValueError("variable-blocking frame found; fixed blocking is required")
        raise ValueError("invalid frame sync or reserved header bits")

    block_rate = data[start + 2]
    channel_depth = data[start + 3]
    block_code = block_rate >> 4
    rate_code = block_rate & 0x0F
    channel_assignment = channel_depth >> 4
    depth_code = (channel_depth >> 1) & 0x07
    if channel_depth & 1:
        raise ValueError("nonzero reserved frame-header bit")
    if channel_assignment != 0:
        raise ValueError(f"unsupported channel assignment {channel_assignment}; mono independent coding required")
    if depth_code != 4:
        raise ValueError(f"unsupported frame bit-depth code {depth_code}; RecordingFLAC emits code 4")
    if rate_code != 5:
        raise ValueError(f"unsupported frame sample-rate code {rate_code}; RecordingFLAC emits code 5")

    position = start + 4
    frame_number, position = _read_coded_number(data, position)
    if block_code == 6:
        encoded_size, position = _read_byte(data, position, "uncommon block size")
        block_size = encoded_size + 1
    elif block_code == 7:
        if position + 2 > len(data):
            raise ValueError("truncated uncommon block size")
        block_size = int.from_bytes(data[position : position + 2], "big") + 1
        position += 2
    elif block_code == 12:
        block_size = _FRAME_SAMPLES
    else:
        raise ValueError(f"unsupported block-size code {block_code}")

    if (position >= len(data)):
        raise ValueError("truncated frame-header CRC-8")
    actual_crc = _crc8(data[start:position])
    if data[position] != actual_crc:
        raise ValueError("frame-header CRC-8 mismatch")
    position += 1

    if block_size > _FRAME_SAMPLES:
        raise ValueError(f"frame block size {block_size} exceeds RecordingFLAC's 4096-sample block")
    if block_size <= 256 and block_code != 6:
        raise ValueError("non-canonical block-size encoding for block of 256 samples or fewer")
    if 257 <= block_size < _FRAME_SAMPLES and block_code != 7:
        raise ValueError("non-canonical uncommon block-size encoding")
    if block_size == _FRAME_SAMPLES and block_code != 12:
        raise ValueError("non-canonical 4096-sample block-size encoding")
    return frame_number, block_size, position


def _decode_residuals(reader: _BitReader, sample_count: int, order: int) -> list[int]:
    method = reader.read(2, "residual coding method")
    if method != 0:
        if method == 1:
            raise ValueError("unsupported 5-bit Rice residual coding method")
        raise ValueError(f"reserved residual coding method {method}")

    partition_order = reader.read(4, "Rice partition order")
    partition_count = 1 << partition_order
    if sample_count % partition_count:
        raise ValueError("Rice partition count does not divide the frame block size")
    samples_per_partition = sample_count // partition_count
    if samples_per_partition < order:
        raise ValueError("Rice partition is smaller than the fixed-predictor warm-up order")

    residuals: list[int] = []
    for partition in range(partition_count):
        parameter = reader.read(4, "4-bit Rice parameter")
        count = samples_per_partition - (order if partition == 0 else 0)
        if parameter == 15:
            raw_width = reader.read(5, "Rice escape raw width")
            if raw_width == 0:
                residuals.extend([0] * count)
            else:
                for _ in range(count):
                    residuals.append(reader.read_signed(raw_width, "escaped residual"))
            continue

        max_quotient = _RESIDUAL_FOLDED_MAX >> parameter
        for _ in range(count):
            quotient = reader.read_unary(max_quotient, "Rice unary quotient")
            remainder = reader.read(parameter, "Rice remainder")
            folded = (quotient << parameter) | remainder
            if folded > _RESIDUAL_FOLDED_MAX:
                raise ValueError("Rice residual exceeds the signed 32-bit residual range")
            if folded & 1:
                residual = -((folded >> 1) + 1)
            else:
                residual = folded >> 1
            if not -(1 << 31) <= residual < (1 << 31):
                raise ValueError("Rice residual exceeds the signed 32-bit residual range")
            residuals.append(residual)

    expected = sample_count - order
    if len(residuals) != expected:
        raise ValueError("decoded residual count does not match fixed-predictor block")
    return residuals


def _decode_subframe(reader: _BitReader, block_size: int) -> list[int]:
    header = reader.read(8, "subframe header")
    if header & 0x80:
        raise ValueError("invalid subframe zero bit")
    if header & 1:
        raise ValueError("wasted bits are unsupported; RecordingFLAC writes none")
    subframe_type = (header >> 1) & 0x3F

    if subframe_type == 0:
        sample = reader.read_signed(16, "constant subframe sample")
        samples = [sample] * block_size
    elif subframe_type == 1:
        samples = [reader.read_signed(16, "verbatim sample") for _ in range(block_size)]
    elif 8 <= subframe_type <= 12:
        order = subframe_type - 8
        if order >= block_size:
            raise ValueError("fixed-predictor warm-up order must be smaller than block size")
        samples = [reader.read_signed(16, "fixed-predictor warm-up sample") for _ in range(order)]
        residuals = _decode_residuals(reader, block_size, order)
        for residual in residuals:
            index = len(samples)
            prediction = sum(
                -coefficient * samples[index - offset]
                for offset, coefficient in enumerate(_FIXED_COEFFICIENTS[order][1:], start=1)
            )
            samples.append(prediction + residual)
    else:
        raise ValueError(f"unsupported subframe type {subframe_type}")

    for index, sample in enumerate(samples):
        if not _PCM_MIN <= sample <= _PCM_MAX:
            raise ValueError(f"decoded PCM sample {index} is outside signed 16-bit range")
    return samples


def validate_flac(path: Path) -> dict[str, int | str | list[int]]:
    """Decode and validate one complete native RecordingFLAC acceptance file.

    Returns sample-rate/channel/precision information, decoded counts, the
    verified lowercase PCM MD5 digest, and all decoded signed samples.
    Malformed or unsupported files raise ValueError with a diagnostic.
    """
    try:
        data = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read FLAC file {path}: {error}") from error

    if len(data) < 4 or data[:4] != b"fLaC":
        raise ValueError("missing FLAC signature")

    position = 4
    metadata_index = 0
    saw_streaminfo = False
    streaminfo: bytes | None = None
    is_last = False
    while not is_last:
        if position + 4 > len(data):
            raise ValueError("truncated metadata block header")
        block_header = data[position]
        is_last = bool(block_header & 0x80)
        block_type = block_header & 0x7F
        block_length = int.from_bytes(data[position + 1 : position + 4], "big")
        position += 4
        if block_type == 127:
            raise ValueError("reserved metadata block type 127")
        if metadata_index == 0 and block_type != 0:
            raise ValueError("first metadata block is not STREAMINFO")
        if block_type == 0:
            if saw_streaminfo:
                raise ValueError("duplicate STREAMINFO metadata block")
            if block_length != 34:
                raise ValueError(f"STREAMINFO metadata size is {block_length}; expected 34")
            saw_streaminfo = True
        if position + block_length > len(data):
            raise ValueError(f"truncated metadata block payload of {block_length} bytes")
        payload = data[position : position + block_length]
        if block_type == 0:
            streaminfo = payload
        position += block_length
        metadata_index += 1

    if not saw_streaminfo or streaminfo is None:
        raise ValueError("missing mandatory STREAMINFO metadata block")

    minimum_block_size = int.from_bytes(streaminfo[0:2], "big")
    maximum_block_size = int.from_bytes(streaminfo[2:4], "big")
    minimum_frame_size = int.from_bytes(streaminfo[4:7], "big")
    maximum_frame_size = int.from_bytes(streaminfo[7:10], "big")
    format_word = int.from_bytes(streaminfo[10:18], "big")
    sample_rate = (format_word >> 44) & 0xFFFFF
    channels = ((format_word >> 41) & 0x07) + 1
    bits_per_sample = ((format_word >> 36) & 0x1F) + 1
    sample_count = format_word & ((1 << 36) - 1)
    stored_md5 = streaminfo[18:34]

    if (minimum_block_size, maximum_block_size) != (_FRAME_SAMPLES, _FRAME_SAMPLES):
        raise ValueError("STREAMINFO block-size extrema are not canonical 4096 samples")
    if sample_rate != 16_000:
        raise ValueError(f"STREAMINFO sample rate is {sample_rate}; expected 16000 Hz")
    if channels != 1:
        raise ValueError(f"STREAMINFO channel count is {channels}; expected mono")
    if bits_per_sample != 16:
        raise ValueError(f"STREAMINFO bit depth is {bits_per_sample}; expected 16 bits")
    if sample_count == 0:
        raise ValueError("STREAMINFO total sample count must be positive")
    if not any(stored_md5):
        raise ValueError("STREAMINFO PCM MD5 is mandatory and must be nonzero")

    expected_frame_count = (sample_count + _FRAME_SAMPLES - 1) // _FRAME_SAMPLES
    if expected_frame_count > len(data) - position:
        raise ValueError("STREAMINFO sample count requires more frames than the file contains")

    decoded_samples: list[int] = []
    frame_sizes: list[int] = []
    frame_start = position
    for frame_number in range(expected_frame_count):
        expected_block_size = min(_FRAME_SAMPLES, sample_count - len(decoded_samples))
        actual_number, block_size, body_position = _parse_frame_header(data, frame_start)
        if actual_number != frame_number:
            raise ValueError(
                f"frame number {actual_number} is not the expected monotonic number {frame_number}"
            )
        if block_size != expected_block_size:
            raise ValueError(
                f"frame {frame_number} block size {block_size} does not match expected {expected_block_size}"
            )

        reader = _BitReader(data, body_position * 8)
        samples = _decode_subframe(reader, block_size)
        reader.align_zero("frame byte-alignment")
        footer_position = reader.bit_position // 8
        stored_crc = reader.read(16, "frame CRC-16")
        frame_end = reader.bit_position // 8
        actual_crc = _crc16(data[frame_start:footer_position])
        if stored_crc != actual_crc:
            raise ValueError(f"frame {frame_number} CRC-16 mismatch")

        decoded_samples.extend(samples)
        frame_sizes.append(frame_end - frame_start)
        frame_start = frame_end

    if len(decoded_samples) != sample_count:
        raise ValueError(
            f"decoded sample count {len(decoded_samples)} does not match STREAMINFO count {sample_count}"
        )
    if frame_start != len(data):
        raise ValueError(f"trailing bytes after final FLAC frame: {len(data) - frame_start}")
    if not frame_sizes:
        raise ValueError("FLAC stream contains no audio frames")
    actual_minimum_frame_size = min(frame_sizes)
    actual_maximum_frame_size = max(frame_sizes)
    if minimum_frame_size != actual_minimum_frame_size:
        raise ValueError(
            f"STREAMINFO minimum frame size {minimum_frame_size} does not match actual {actual_minimum_frame_size}"
        )
    if maximum_frame_size != actual_maximum_frame_size:
        raise ValueError(
            f"STREAMINFO maximum frame size {maximum_frame_size} does not match actual {actual_maximum_frame_size}"
        )

    pcm = bytearray()
    for sample in decoded_samples:
        pcm.extend(sample.to_bytes(2, byteorder="little", signed=True))
    actual_md5 = hashlib.md5(pcm, usedforsecurity=False).digest()
    if actual_md5 != stored_md5:
        raise ValueError(
            f"STREAMINFO PCM MD5 mismatch: stored {stored_md5.hex()}, decoded {actual_md5.hex()}"
        )

    return {
        "sample_rate": sample_rate,
        "channels": channels,
        "bits_per_sample": bits_per_sample,
        "sample_count": sample_count,
        "frame_count": len(frame_sizes),
        "md5": actual_md5.hex(),
        "samples": decoded_samples,
    }

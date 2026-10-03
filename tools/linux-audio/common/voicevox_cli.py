from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import tempfile
from dataclasses import dataclass
from typing import Any

from common.files import write_json_atomic


@dataclass(frozen=True)
class VoiceStyle:
    speaker_uuid: str
    speaker_name: str
    style_id: int
    style_name: str

    def metadata(self) -> dict[str, Any]:
        return {
            "speaker_uuid": self.speaker_uuid,
            "speaker_name": self.speaker_name,
            "style_id": self.style_id,
            "style_name": self.style_name,
        }


def _get(base_url: str, path: str) -> bytes:
    return subprocess.run(
        [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            f"{base_url.rstrip('/')}{path}",
        ],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout


def engine_version(base_url: str) -> str:
    version = json.loads(_get(base_url, "/version"))
    if not isinstance(version, str) or not version:
        raise ValueError(f"unexpected VOICEVOX /version: {version!r}")
    return version


def voice_styles(base_url: str) -> list[VoiceStyle]:
    """One style per VOICEVOX character, in /speakers order."""
    speakers = json.loads(_get(base_url, "/speakers"))
    return [
        VoiceStyle(
            speaker_uuid=speaker["speaker_uuid"],
            speaker_name=speaker["name"],
            style_id=speaker["styles"][0]["id"],
            style_name=speaker["styles"][0]["name"],
        )
        for speaker in speakers
    ]


def synthesize(
    *,
    base_url: str,
    text: str,
    style_id: int,
    output: pathlib.Path,
) -> dict[str, Any]:
    """Synthesizes text and returns the audio_query the engine used."""
    base = base_url.rstrip("/")
    query = subprocess.run(
        [
            "curl",
            "--fail",
            "--silent",
            "--show-error",
            "-X",
            "POST",
            "--get",
            "--data-urlencode",
            f"text={text}",
            "--data-urlencode",
            f"speaker={style_id}",
            f"{base}/audio_query",
        ],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    audio_query = json.loads(query)

    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(
        dir=output.parent,
        prefix=output.name + ".",
        suffix=".tmp",
    )
    temporary = pathlib.Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as wav:
            subprocess.run(
                [
                    "curl",
                    "--fail",
                    "--silent",
                    "--show-error",
                    "-X",
                    "POST",
                    "-H",
                    "Content-Type: application/json",
                    "--data-binary",
                    "@-",
                    f"{base}/synthesis?speaker={style_id}",
                ],
                input=query,
                stdout=wav,
                check=True,
            )
        temporary.replace(output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        output.unlink(missing_ok=True)
        raise
    return audio_query


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--style-id", type=int, required=True)
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        required=True,
    )
    parser.add_argument(
        "--query-output",
        type=pathlib.Path,
        required=True,
    )
    args = parser.parse_args()

    audio_query = synthesize(
        base_url=args.base_url,
        text=args.text,
        style_id=args.style_id,
        output=args.output,
    )
    write_json_atomic(args.query_output, audio_query)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

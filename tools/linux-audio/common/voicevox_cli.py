from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import tempfile


def synthesize(
    *,
    base_url: str,
    text: str,
    speaker: int,
    output: pathlib.Path,
) -> None:
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
            f"speaker={speaker}",
            f"{base}/audio_query",
        ],
        check=True,
        stdout=subprocess.PIPE,
    ).stdout

    json.loads(query)
    output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )
    with tempfile.NamedTemporaryFile(
        dir=output.parent,
        prefix=output.name + ".",
        suffix=".tmp",
        delete=False,
    ) as handle:
        temporary = pathlib.Path(handle.name)

    try:
        with temporary.open("wb") as wav:
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
                    f"{base}/synthesis?speaker={speaker}",
                ],
                input=query,
                stdout=wav,
                check=True,
            )
        temporary.replace(output)
    except Exception:
        temporary.unlink(missing_ok=True)
        output.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--speaker", type=int, required=True)
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        required=True,
    )
    args = parser.parse_args()

    synthesize(
        base_url=args.base_url,
        text=args.text,
        speaker=args.speaker,
        output=args.output,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

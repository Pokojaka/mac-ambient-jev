from __future__ import annotations

import argparse
import pathlib

from common.audio import normalize_to_wav
from common.corpus import load_manifest, prepare_resource
from common.csj import (
    csj_reference_text,
    csj_speaker_reference,
    parse_csj_transcript,
)
from common.files import write_json_atomic


ROLES = {"audio", "csj-transcript"}


def prepare_fixture(
    manifest_path: pathlib.Path,
    *,
    cache_root: pathlib.Path,
    output_root: pathlib.Path,
) -> dict:
    manifest = load_manifest(manifest_path)

    resources_by_role: dict[str, dict] = {}
    for resource in manifest["resources"]:
        role = resource.get("role")
        if role not in ROLES:
            raise ValueError(
                f"resource role must be one of {sorted(ROLES)}, "
                f"got {role!r}"
            )
        if role in resources_by_role:
            raise ValueError(f"duplicate role: {role}")
        resources_by_role[role] = resource
    missing = ROLES - set(resources_by_role)
    if missing:
        raise ValueError(f"missing resource roles: {sorted(missing)}")

    roles = {
        role: prepare_resource(
            resource,
            cache_root=cache_root / manifest["id"],
        )
        for role, resource in resources_by_role.items()
    }

    fixture_dir = output_root / manifest["id"]
    fixture_dir.mkdir(parents=True, exist_ok=True)

    utterances = parse_csj_transcript(
        roles["csj-transcript"].read_text(encoding="utf-8")
    )
    normalize_to_wav(roles["audio"], fixture_dir / "audio.wav")
    (fixture_dir / "reference-verbatim.txt").write_text(
        csj_reference_text(utterances, keep_fillers=True) + "\n",
        encoding="utf-8",
    )
    (fixture_dir / "reference-content.txt").write_text(
        csj_reference_text(utterances, keep_fillers=False) + "\n",
        encoding="utf-8",
    )
    write_json_atomic(
        fixture_dir / "speaker-reference.json",
        csj_speaker_reference(utterances),
    )

    result = {
        "schema_version": 1,
        "id": manifest["id"],
        "files": {
            "audio": "audio.wav",
            "reference_verbatim": "reference-verbatim.txt",
            "reference_content": "reference-content.txt",
            "speaker_reference": "speaker-reference.json",
        },
    }
    write_json_atomic(fixture_dir / "fixture.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument(
        "--cache-root",
        type=pathlib.Path,
        required=True,
    )
    parser.add_argument(
        "--output-root",
        type=pathlib.Path,
        required=True,
    )
    args = parser.parse_args()
    prepare_fixture(
        args.manifest,
        cache_root=args.cache_root,
        output_root=args.output_root,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

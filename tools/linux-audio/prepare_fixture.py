from __future__ import annotations

import argparse
import json
import pathlib

from common.audio import normalize_to_wav
from common.corpus import load_manifest, prepare_resource
from common.csj import (
    csj_reference_text,
    parse_csj_transcript,
)


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
        if not isinstance(role, str) or not role:
            raise ValueError("resource role is required")
        if role in resources_by_role:
            raise ValueError(f"duplicate role: {role}")
        resources_by_role[role] = resource

    roles: dict[str, pathlib.Path] = {}
    for role, resource in resources_by_role.items():
        roles[role] = prepare_resource(
            resource,
            cache_root=cache_root / manifest["id"],
        )

    fixture_dir = output_root / manifest["id"]
    fixture_dir.mkdir(parents=True, exist_ok=True)
    result = {
        "schema_version": 1,
        "id": manifest["id"],
        "files": {},
    }

    if "audio" in roles:
        normalized = normalize_to_wav(
            roles["audio"],
            fixture_dir / "audio.wav",
        )
        result["files"]["audio"] = normalized.name

    if "csj-transcript" in roles:
        utterances = parse_csj_transcript(
            roles["csj-transcript"].read_text(
                encoding="utf-8"
            )
        )
        verbatim = csj_reference_text(
            utterances,
            keep_fillers=True,
        )
        content = csj_reference_text(
            utterances,
            keep_fillers=False,
        )
        (fixture_dir / "reference-verbatim.txt").write_text(
            verbatim + "\n",
            encoding="utf-8",
        )
        (fixture_dir / "reference-content.txt").write_text(
            content + "\n",
            encoding="utf-8",
        )
        spans = [
            {
                "start_ms": item.start_ms,
                "end_ms": item.end_ms,
                "speaker_label": item.speaker,
            }
            for item in utterances
        ]
        (fixture_dir / "speaker-reference.json").write_text(
            json.dumps(
                spans,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )
        result["files"].update({
            "reference_verbatim":
                "reference-verbatim.txt",
            "reference_content":
                "reference-content.txt",
            "speaker_reference":
                "speaker-reference.json",
        })

    (fixture_dir / "fixture.json").write_text(
        json.dumps(
            result,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )
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

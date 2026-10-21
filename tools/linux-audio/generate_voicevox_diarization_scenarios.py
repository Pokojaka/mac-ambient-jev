from __future__ import annotations

import argparse
import json
import pathlib
from collections.abc import Sequence

from common.voicevox_cli import (
    engine_version,
    synthesize,
    voice_styles,
)
from voicevox_suite import SynthesizeFn, generate_scenario


def generate_scenarios(
    manifest: dict,
    *,
    scenario_ids: Sequence[str],
    voices: list,
    version: str,
    output_root: pathlib.Path,
    synthesize_fn: SynthesizeFn,
) -> list[dict]:
    if not scenario_ids:
        raise ValueError("at least one scenario is required")
    return [
        generate_scenario(
            manifest,
            scenario_id=scenario_id,
            voices=voices,
            engine_version=version,
            output_root=output_root,
            synthesize=synthesize_fn,
        )
        for scenario_id in scenario_ids
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--output-root", type=pathlib.Path, required=True)
    parser.add_argument(
        "--scenario",
        action="append",
        required=True,
        dest="scenarios",
    )
    args = parser.parse_args()

    def synthesize_with_engine(text, style_id, output):
        return synthesize(
            base_url=args.base_url,
            text=text,
            style_id=style_id,
            output=output,
        )

    generate_scenarios(
        json.loads(args.manifest.read_text(encoding="utf-8")),
        scenario_ids=args.scenarios,
        voices=voice_styles(args.base_url),
        version=engine_version(args.base_url),
        output_root=args.output_root,
        synthesize_fn=synthesize_with_engine,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

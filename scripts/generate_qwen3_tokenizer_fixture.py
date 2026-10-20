from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from tokenizers import Tokenizer

import fetch_qwen3_asr_tokenizer


OUTPUT = (
    Path(__file__).resolve().parent.parent
    / "app/MacAmbientJev/Tests/MacAmbientJevPortableRuntimeTests/Resources/qwen3_tokenizer_golden.json"
)
ASR_TEXT = 151704
STOP_IDS = (151643, 151645)
TEXTS = {
    "japanese": "今日はいい天気ですね。",
    "japanese_with_kanji_and_kana": "音声認識の精度を確認します。",
    "character_split_across_tokens": "彼は鬱蒼とした薔薇の園で躊躇した。",
    "mixed_ascii": "Hello, world! Mac Ambient Jev 1.7B は 2026年に公開された。",
    "punctuation": "「はい、そうです」と彼は言った…（笑）",
    "newlines_and_spaces": "一行目\n  二行目\t三行目",
    "emoji": "OK 👍 🎉",
}
SPECIAL_AND_ADDED = {
    "special_tokens_are_skipped": [151644, 872, 198, 151670, 151676],
    "non_special_added_token_is_kept": [151667, 151668, 151704],
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decode(tokenizer: Tokenizer, ids: list[int]) -> str:
    return tokenizer.decode(ids, skip_special_tokens=True)


def partial_character_cases(tokenizer: Tokenizer) -> list[dict]:
    cases = []
    for name, text in TEXTS.items():
        ids = tokenizer.encode(text).ids
        for index, token_id in enumerate(ids):
            if "�" in decode(tokenizer, [token_id]):
                cases.append({"name": f"{name}_partial_token_{index}", "ids": [token_id]})
    if not cases:
        raise RuntimeError("no token holds a partial UTF-8 character")
    return cases[:3]


def transcript_text(tokenizer: Tokenizer, ids: list[int]) -> str:
    start = len(ids) - ids[::-1].index(ASR_TEXT) if ASR_TEXT in ids else 0
    kept = [token_id for token_id in ids[start:] if token_id not in STOP_IDS]
    return decode(tokenizer, kept).strip()


def build(tokenizer: Tokenizer, tokenizer_sha256: str) -> dict:
    decode_cases = []
    for name, text in TEXTS.items():
        ids = tokenizer.encode(text).ids
        decode_cases.append({"name": name, "ids": ids, "text": decode(tokenizer, ids)})
        if decode_cases[-1]["text"] != text:
            raise RuntimeError(f"{name} does not round-trip")
    split_ids = tokenizer.encode(TEXTS["character_split_across_tokens"]).ids
    if not any("\ufffd" in decode(tokenizer, [token_id]) for token_id in split_ids):
        raise RuntimeError("the multi-byte case has no character split across tokens")
    for name, ids in SPECIAL_AND_ADDED.items():
        decode_cases.append({"name": name, "ids": ids, "text": decode(tokenizer, ids)})

    japanese = tokenizer.encode(TEXTS["japanese"]).ids
    mixed = tokenizer.encode(TEXTS["mixed_ascii"]).ids
    padded = tokenizer.encode("\n  音声認識です。 \n").ids
    prompt_tail = [11528, 11937, ASR_TEXT]
    transcript_inputs = {
        "stops_are_dropped_end_of_turn": japanese + [151645],
        "stops_are_dropped_end_of_text": japanese + [151643],
        "text_after_the_asr_text_marker": prompt_tail + japanese + [151645],
        "text_after_the_last_asr_text_marker": prompt_tail + japanese + [ASR_TEXT] + mixed + [151645],
        "whitespace_and_newlines_are_trimmed": [ASR_TEXT] + padded + [151645],
        "marker_only_gives_empty_text": [ASR_TEXT, 151645],
        "stop_only_gives_empty_text": [151645],
        "no_marker_keeps_all_text": mixed,
    }
    transcript_cases = [
        {"name": name, "ids": ids, "text": transcript_text(tokenizer, ids)}
        for name, ids in transcript_inputs.items()
    ]
    return {
        "tokenizer_sha256": tokenizer_sha256,
        "tokenizers_package": __import__("tokenizers").__version__,
        "decode_cases": decode_cases,
        "invalid_utf8_cases": partial_character_cases(tokenizer),
        "transcript_cases": transcript_cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokenizer", type=Path, required=True)
    arguments = parser.parse_args()
    digest = sha256(arguments.tokenizer)
    if digest != fetch_qwen3_asr_tokenizer.SHA256:
        raise SystemExit(f"tokenizer.json SHA-256 が固定値と一致しません: {digest}")
    tokenizer = Tokenizer.from_file(str(arguments.tokenizer))
    fixture = build(tokenizer, digest)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(OUTPUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

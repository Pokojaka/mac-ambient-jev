import hashlib
import json
import wave

from prepare_fixture import prepare_fixture


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_wav(path):
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(8_000)
        wav.writeframes(b"\x00\x00\x00\x00" * 800)


def test_prepare_csj_fixture_end_to_end(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    audio = source / "audio.wav"
    make_wav(audio)
    transcript = source / "transcript.txt"
    transcript.write_text(
        "0001 00000.000-00001.000 L:\n"
        "質問です & シツモンデス\n"
        "(F あの) & (F アノ)\n"
        "0002 00000.500-00001.500 R:\n"
        "(F うん) & (F <VN>)\n"
        "回答です & カイトーデス\n",
        encoding="utf-8",
    )

    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps({
            "schema_version": 1,
            "id": "csj-local",
            "resources": [
                {
                    "name": "audio",
                    "role": "audio",
                    "url": audio.as_uri(),
                    "filename": "audio.wav",
                    "sha256": sha256(audio),
                },
                {
                    "name": "transcript",
                    "role": "csj-transcript",
                    "url": transcript.as_uri(),
                    "filename": "transcript.txt",
                    "sha256": sha256(transcript),
                },
            ],
        }),
        encoding="utf-8",
    )

    prepare_fixture(
        manifest,
        cache_root=tmp_path / "cache",
        output_root=tmp_path / "out",
    )
    fixture = tmp_path / "out" / "csj-local"

    with wave.open(str(fixture / "audio.wav"), "rb") as wav:
        assert wav.getframerate() == 16_000
        assert wav.getnchannels() == 1

    assert (
        fixture / "reference-verbatim.txt"
    ).read_text(encoding="utf-8") == (
        "質問ですあのうん回答です\n"
    )
    assert (
        fixture / "reference-content.txt"
    ).read_text(encoding="utf-8") == (
        "質問です回答です\n"
    )

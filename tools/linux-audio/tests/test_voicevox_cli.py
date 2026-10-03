import subprocess

from common import voicevox_cli


class Result:
    def __init__(self, stdout=b""):
        self.stdout = stdout


def test_synthesis_posts_query_json_and_returns_it(monkeypatch, tmp_path):
    calls = []

    def fake_run(args, **kwargs):
        calls.append((args, kwargs))
        if args[-1].endswith("/audio_query"):
            return Result(b'{"accent_phrases":[],"speedScale":1.0}')
        kwargs["stdout"].write(b"RIFF")
        return Result()

    monkeypatch.setattr(subprocess, "run", fake_run)
    output = tmp_path / "out.wav"

    audio_query = voicevox_cli.synthesize(
        base_url="engine",
        text="テスト",
        style_id=3,
        output=output,
    )

    args, kwargs = calls[1]
    assert "--get" not in args
    assert args[-1].endswith("/synthesis?speaker=3")
    assert kwargs["input"] == b'{"accent_phrases":[],"speedScale":1.0}'
    assert audio_query == {"accent_phrases": [], "speedScale": 1.0}
    assert output.read_bytes() == b"RIFF"
    assert [path.name for path in tmp_path.iterdir()] == ["out.wav"]


def test_voice_styles_take_one_style_per_character(monkeypatch):
    speakers = (
        b'[{"name":"A","speaker_uuid":"uuid-a","styles":'
        b'[{"name":"normal","id":2},{"name":"sweet","id":0}]},'
        b'{"name":"B","speaker_uuid":"uuid-b","styles":'
        b'[{"name":"normal","id":3}]}]'
    )
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda args, **kwargs: Result(speakers),
    )

    assert voicevox_cli.voice_styles("engine") == [
        voicevox_cli.VoiceStyle("uuid-a", "A", 2, "normal"),
        voicevox_cli.VoiceStyle("uuid-b", "B", 3, "normal"),
    ]

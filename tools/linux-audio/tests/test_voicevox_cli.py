import subprocess

from common import voicevox_cli


class Result:
    def __init__(self, stdout=b""):
        self.stdout = stdout


def test_synthesis_keeps_json_in_post_body(
    monkeypatch,
    tmp_path,
):
    calls = []

    def fake_run(args, **kwargs):
        calls.append((args, kwargs))
        if args[-1].endswith("/audio_query"):
            return Result(b'{"accent_phrases":[]}')
        kwargs["stdout"].write(b"RIFF")
        return Result()

    monkeypatch.setattr(subprocess, "run", fake_run)
    output = tmp_path / "out.wav"

    voicevox_cli.synthesize(
        base_url="engine",
        text="テスト",
        speaker=3,
        output=output,
    )

    args, kwargs = calls[1]
    assert "--get" not in args
    assert args[-1].endswith("/synthesis?speaker=3")
    assert kwargs["input"] == b'{"accent_phrases":[]}'

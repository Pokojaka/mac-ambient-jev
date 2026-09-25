#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile


binary = pathlib.Path(sys.argv[1]).resolve()
session_id = "31AC3491-986E-4F0A-8697-E9181B0910D4"

with tempfile.TemporaryDirectory(prefix="mac-ambient-jev-cli-") as temporary:
    root = pathlib.Path(temporary)
    sessions = root / "sessions"
    sessions.mkdir()
    output = root / "segments.json"
    metrics = root / "metrics.json"
    thermal = root / "thermal.jsonl"
    memory = root / "memory.jsonl"
    invalid = [
        ["--resume-session", session_id, "--sessions-root", str(sessions), "audio.wav", str(output)],
        ["--inspect-session", session_id, "--sessions-root", str(sessions), "audio.wav"],
        ["--inspect-session", session_id, "--sessions-root", str(sessions), "--low-heat"],
        ["--resume-session", session_id, "--resume-session", session_id, "--sessions-root", str(sessions), str(output)],
        ["--resume-session", session_id, "--sessions-root", str(sessions), "--keep-session", str(output)],
        ["--resume-session", "--sessions-root", str(sessions), str(output)],
        ["--unexpected", "audio.wav", str(output)],
        ["--low-heat", "--low-heat", "audio.wav", str(output)],
        ["--run-id", "incomplete", "--metrics-output", str(metrics), "audio.wav", str(output)],
        ["--run-id", "inspect", "--metrics-output", str(metrics),
         "--thermal-output", str(thermal), "--memory-output", str(memory),
         "--inspect-session", session_id, "--sessions-root", str(sessions)],
    ]
    for arguments in invalid:
        result = subprocess.run([str(binary), *arguments], capture_output=True)
        assert result.returncode != 0, arguments
        assert not output.exists(), arguments
        assert not metrics.exists() and not thermal.exists() and not memory.exists(), arguments
        assert list(sessions.iterdir()) == [], arguments

print(f"CLI rejected {len(invalid)} invalid input forms without writing files")

#!/usr/bin/env python3
"""Exercise shell scripts' actual artifact Python without processing or capture."""
import ast
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent
IDENTITY = "31AC3491-986E-4F0A-8697-E9181B0910D4"
NAME = "2024-02-29_23-59-59_録音_31ac3491"


def embedded(script):
    source = (SCRIPTS / script).read_text()
    return ast.parse(source.split("<<'PY'\n")[-1].split("\nPY")[0])


def assignment(node, name):
    return isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == name for target in node.targets
    )


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="session-artifacts-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.sessions = self.root / "sessions"
        self.sessions.mkdir()
        self.log = self.root / "stdout.log"
        self.log.write_text("")

    def session(self, name=NAME, **changes):
        folder = self.sessions / name
        folder.mkdir()
        (folder / "audio").mkdir()
        manifest = dict(session_id=IDENTITY, created_at="2020-01-01T00:00:00Z",
                        source_kind="recording", capture_source="systemAudio")
        manifest.update(changes)
        (folder / "session.json").write_text(json.dumps(manifest, ensure_ascii=False))
        return folder

    def measurement(self, resume=IDENTITY):
        tree = embedded("measure_v1_run.sh")
        start = next(i for i, node in enumerate(tree.body) if assignment(node, "events"))
        end = next(i for i, node in enumerate(tree.body) if assignment(node, "duration"))
        nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                 and node.name in ("fail", "session_directory")]
        nodes += tree.body[start:end]
        code = "import datetime,json,pathlib,re,sys,unicodedata,uuid\n"
        code += f"folder=pathlib.Path({str(self.root)!r}); exit_code='7'; root={str(self.sessions)!r}; resume={resume!r}; audio=''\n"
        code += ast.unparse(ast.Module(body=nodes, type_ignores=[]))
        code += "\nprint(json.dumps({'directory':str(directory) if directory else None,'events':str(events) if events else None,'audio':audio}))\n"
        return subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)

    def capture(self, folder, identity=IDENTITY):
        summary = self.root / "summary.json"
        summary.write_text(json.dumps(dict(errors=[], permission="authorized", session_id=identity, path=str(folder))))
        tree = embedded("verify_system_audio.sh")
        end = next(i for i, node in enumerate(tree.body) if assignment(node, "rate"))
        code = ast.unparse(ast.Module(body=tree.body[:end], type_ignores=[]))
        code += "\nprint(session.name)\n"
        return subprocess.run([sys.executable, "-I", "-c", code, str(summary), "unused.wav", "3", str(self.sessions)],
                              capture_output=True, text=True)

    def test_full_identity_and_resolved_original(self):
        folder = self.session()
        self.session("2024-03-01_00-00-00_録音_31ac3491", session_id="31AC3491-0000-4000-8000-000000000000")
        (folder / "audio" / "original").write_bytes(b"audio")
        result = self.measurement(IDENTITY.lower())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), dict(directory=str(folder), events=str(folder / "events.jsonl"),
                                                        audio=str(folder / "audio" / "original")))
        (folder / "audio" / "original.wav").write_bytes(b"second")
        result = self.measurement()
        self.assertEqual(result.returncode, 1)

    def test_missing_duplicate_and_malformed_matches(self):
        self.assertEqual(self.measurement().returncode, 1)
        folder = self.session()
        duplicate = self.session("malformed")
        result = self.measurement()
        self.assertEqual(result.returncode, 1)
        (duplicate / "session.json").unlink()
        for name in ["bad", "2024-02-30_23-59-59_録音_31ac3491",
                     "2024-02-29_23-59-59_録音_deadbeef", "2024-02-29_23-59-59_wrong_31ac3491"]:
            changed = folder.with_name(name)
            folder.rename(changed)
            result = self.measurement()
            self.assertEqual(result.returncode, 1, result.stdout)
            changed.rename(folder)

    def test_import_grapheme_truncation_and_sanitization(self):
        # 225 ASCII bytes plus a composed character: omit that whole character.
        filename = "." + "a" * 222 + "/:" + "e\u0301" + ".wav"
        stem = "-" + "a" * 222 + "--"
        folder = self.session(f"2024-02-29_23-59-59_{stem}_31ac3491", source_kind="imported", original_filename=filename)
        self.assertEqual(self.measurement().returncode, 0)
        changed = folder.with_name(f"2024-02-29_23-59-59_{stem}e_31ac3491")
        folder.rename(changed)
        self.assertEqual(self.measurement().returncode, 1)

    def test_import_without_session_id_keeps_missing_artifacts(self):
        result = self.measurement(resume="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), dict(directory=None, events=None, audio=""))
        folder = self.session()
        self.log.write_text(f"session_id: {IDENTITY.lower()}\n")
        imported = self.measurement(resume="")
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertEqual(pathlib.Path(json.loads(imported.stdout)["directory"]).resolve(), folder.resolve())
        self.log.write_text("session_id: not-a-uuid\n")
        self.assertEqual(self.measurement(resume="").returncode, 1)

    def test_capture_summary_folder_identity_source_and_grammar(self):
        folder = self.session()
        result = self.capture(folder, IDENTITY.lower())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), NAME)
        self.assertNotEqual(self.capture(folder, "31AC3491-0000-4000-8000-000000000000").returncode, 0)
        for name in ["bad", "2024-02-30_23-59-59_録音_31ac3491", "2024-02-29_23-59-59_録音_deadbeef", "2024-02-29_23-59-59_wrong_31ac3491"]:
            changed = folder.with_name(name)
            folder.rename(changed)
            self.assertNotEqual(self.capture(changed).returncode, 0)
            changed.rename(folder)
        manifest_path = folder / "session.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["capture_source"] = "microphone"
        manifest_path.write_text(json.dumps(manifest))
        self.assertNotEqual(self.capture(folder).returncode, 0)
        outside = self.root / NAME
        folder.rename(outside)
        self.assertNotEqual(self.capture(outside).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""参照 checker の consumer-visible な失敗・除外境界を temp repo で検証する。"""
import pathlib
import tempfile
import unittest

from check_doc_references import check


class DocReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.put("README.md", "")
        self.put("app/MacAmbientJev/Package.swift", '''
.executable(name: "MacAmbientJevProcessRecording", targets: ["MacAmbientJevProcessRecording"])
.target(name: "MacAmbientJevCore")
''')
        self.put("app/MacAmbientJev/Sources/MacAmbientJevProcessRecording/main.swift", '''
struct RecordingOptions {}
enum RecordingMode { case ImportedRecording }
let option = removeFlag("--keep-session")
let value = removeOption("--sessions-root")
''')
        self.put("app/MacAmbientJev/Sources/MacAmbientJevTranscribeFile/TranscribeFileCommand.swift", '''
let documentedFlags = [
    "--silero-model",
    "--asr-model-directory",
    "--asr-model-size",
    "--threads",
    "--output",
    "--artifact-output",
    "--help",
]
''')
        self.put("app/MacAmbientJev/Sources/MacAmbientJevTranscribeFile/main.swift",
                 'let mainOnlyFlag = "--main-only"\n')
        self.put("scripts/build_app.sh", 'case "$1" in --print-info-plist) ;; esac\n'
                 'swift build --product MacAmbientJev\n')
        self.put("tools/linux-audio/run_suite.py", '''
import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--full", action="store_true")
parser.add_argument("--device")
other_command = ["swift", "--product"]
''')
        self.put("scripts/verify_linux_audio.sh", 'python3 tools/linux-audio/run_suite.py "$@"\n')

    def put(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def messages(self):
        return [str(problem) for problem in check(self.root)]

    def test_missing_path_and_basename_are_reported_with_locations(self):
        self.put("README.md", "`app/MacAmbientJev/Package.swfit`\n`build_ap.sh`\n")
        self.assertEqual(self.messages(), [
            "README.md:1: missing path: app/MacAmbientJev/Package.swfit",
            "README.md:2: missing path: build_ap.sh",
        ])

    def test_links_resolve_document_relative_and_root_paths(self):
        self.put("docs/guide.md", "[root](README.md#usage)\n[near](near.md)\n[bad](gone.md#usage)\n[ref]: absent.py\n")
        self.put("docs/near.md", "")
        self.assertEqual(self.messages(), [
            "docs/guide.md:3: missing path: gone.md",
            "docs/guide.md:4: missing path: absent.py",
        ])

    def test_fenced_script_commands_cannot_name_missing_scripts(self):
        self.put("README.md", "```bash\nbash scripts/build_ap.sh\n```\n")
        self.assertEqual(self.messages(), ["README.md:2: missing script: scripts/build_ap.sh"])

    def test_target_flags_are_checked_after_swiftpm_options(self):
        self.put("README.md", """```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \\
  --keep-session --sessions-root /tmp/sessions \\
  --keep-sesion <audio-file>
```
""")
        self.assertEqual(self.messages(), [
            "README.md:4: unknown flag for MacAmbientJevProcessRecording: --keep-sesion",
        ])

    def test_transcribe_file_flags_use_command_source_for_swift_run_and_executable(self):
        self.put("README.md", """```bash
swift run --package-path app/MacAmbientJev MacAmbientJevTranscribeFile --silero-model silero.onnx --asr-model-directory models --asr-model-size 0.6b --threads 4 --output transcript.json --artifact-output artifact.json
swift run --package-path app/MacAmbientJev MacAmbientJevTranscribeFile --artifact-ouput artifact.json
MacAmbientJevTranscribeFile --silero-model silero.onnx --asr-model-directory models --asr-model-size 0.6b --threads 4 --output transcript.json --artifact-output artifact.json
MacAmbientJevTranscribeFile --main-only
```
""")
        self.assertEqual(self.messages(), [
            "README.md:3: unknown flag for MacAmbientJevTranscribeFile: --artifact-ouput",
            "README.md:5: unknown flag for MacAmbientJevTranscribeFile: --main-only",
        ])

    def test_python_flags_use_argument_declarations_not_invoked_commands(self):
        self.put("README.md", """```bash
python3 tools/linux-audio/run_suite.py --full --device cpu --product invalid
bash scripts/verify_linux_audio.sh --full --devcie cpu
```
""")
        self.assertEqual(self.messages(), [
            "README.md:2: unknown flag for tools/linux-audio/run_suite.py: --product",
            "README.md:3: unknown flag for scripts/verify_linux_audio.sh: --devcie",
        ])

    def test_shell_flags_and_separate_commands(self):
        self.put("README.md", """```bash
bash scripts/build_app.sh --print-info-plist && swift build --product Example
bash scripts/build_app.sh --print-plist
bash scripts/build_app.sh --product MacAmbientJev
```
""")
        self.assertEqual(self.messages(), [
            "README.md:3: unknown flag for scripts/build_app.sh: --print-plist",
            "README.md:4: unknown flag for scripts/build_app.sh: --product",
        ])

    def test_deleted_swift_type_fails_but_declarations_and_products_pass(self):
        self.put("README.md", "`RecordingOptions` `ImportedRecording` `UserDefaults`\n"
                 "`MacAmbientJevProcessRecording` `MacAmbientJevCore` `Package.swift`\n"
                 "`DeletedRecorder` `RecordingOptions.parse`\n")
        self.put("tools/type.swift", "protocol ToolAdapter {}\ntypealias AudioSamples = [Float]\n")
        self.put("docs/types.md", "`ToolAdapter` `AudioSamples`\n")
        self.assertEqual(self.messages(), [
            "README.md:3: unknown Swift identifier: DeletedRecorder",
        ])

    def test_commented_declaration_does_not_resurrect_deleted_type(self):
        self.put("tools/old.swift", "// struct DeletedRecorder {}\n")
        self.put("README.md", "`DeletedRecorder`\n")
        self.assertEqual(self.messages(), [
            "README.md:1: unknown Swift identifier: DeletedRecorder",
        ])

    def test_external_anchors_placeholders_and_runtime_basenames(self):
        self.put("README.md", """[web](https://example.com/scripts/absent.sh)
[anchor](#usage) `https://example.com/gone.py`
`/tmp/missing.json` `~/Library/audio.wav` `$ROOT/audio.wav`
`docs/<name>.md` `<audio-file>` `<output.json>` `session.json` `audio.wav`
`README.md` `build_app.sh`
`docs/session.json`
""")
        self.assertEqual(self.messages(), ["README.md:6: missing path: docs/session.json"])

    def test_generated_build_paths_are_not_required_in_inline_code(self):
        self.put("README.md", "`.build/onnxruntime/1.31.0/`\n[model](.build/model.onnx)\n")
        self.assertEqual(self.messages(), ["README.md:2: missing path: .build/model.onnx"])

    def test_scope_includes_agents_and_nested_docs_but_excludes_records(self):
        self.put("AGENTS.md", "`missing.py`\n")
        self.put("docs/nested/guide.md", "`gone.sh`\n")
        self.put("docs/records/history.md", "`stale.py`\n")
        self.put("docs/nested/records/guide.md", "`nested_missing.py`\n")
        self.put("outside.md", "`unscanned.py`\n")
        self.assertEqual(self.messages(), [
            "AGENTS.md:1: missing path: missing.py",
            "docs/nested/guide.md:1: missing path: gone.sh",
            "docs/nested/records/guide.md:1: missing path: nested_missing.py",
        ])


if __name__ == "__main__":
    unittest.main()

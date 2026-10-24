from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPTS_DIRECTORY = Path(__file__).resolve().parent
BUILD_SCRIPT = SCRIPTS_DIRECTORY / "build_app.sh"
INFO_PLIST_SCRIPT = SCRIPTS_DIRECTORY / "app_info_plist.sh"


class BuildAppTests(unittest.TestCase):
    def test_fetch_failure_stops_before_swift_and_bundle_publication(self) -> None:
        root, environment = self.make_fake_repository()
        environment["FETCH_STATUS"] = "1"

        result = self.run_build(root, environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stub fetch failure", result.stderr)
        self.assertFalse((root / "swift.log").exists())
        self.assertFalse((root / ".build/MacAmbientJev.app").exists())

    def test_success_copies_fetched_model_and_license(self) -> None:
        root, environment = self.make_fake_repository()

        result = self.run_build(root, environment)

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertTrue((root / ".build/MacAmbientJev.app/Contents/Resources/clause-tagger/LICENSE.md").is_file())
        self.assertEqual(
            (root / ".build/MacAmbientJev.app/Contents/Resources/clause-tagger/LICENSE.md").read_text(),
            "license text\n",
        )
        self.assertTrue(
            (root / ".build/MacAmbientJev.app/Contents/Resources/clause-tagger/ClauseTagger.mlpackage/Manifest.json").is_file()
        )
        self.assertTrue(
            (root / ".build/MacAmbientJev.app/Contents/Resources/clause-tagger/tokenizer.json").is_file()
        )
        self.assertIn("-B", (root / "python.log").read_text())
        self.assertTrue((root / "swift.log").is_file())

    def test_invalid_fetch_results_stop_before_swift_and_publication(self) -> None:
        cases = (
            "relative",
            "missing_directory",
            "missing_package",
            "missing_tokenizer",
            "missing_license",
        )
        for scenario in cases:
            with self.subTest(scenario=scenario):
                root, environment = self.make_fake_repository()
                source = Path(environment["TAGGER_DIRECTORY"])
                missing_artifact = {
                    "missing_package": "ClauseTagger.mlpackage",
                    "missing_tokenizer": "tokenizer.json",
                    "missing_license": "LICENSE.md",
                }.get(scenario)
                if scenario == "relative":
                    environment["TAGGER_DIRECTORY"] = "relative/tagger"
                elif scenario == "missing_directory":
                    environment["TAGGER_DIRECTORY"] = str(root / "not-created")
                elif missing_artifact == "ClauseTagger.mlpackage":
                    shutil.rmtree(source / missing_artifact)
                elif missing_artifact:
                    (source / missing_artifact).unlink()

                result = self.run_build(root, environment)

                self.assertNotEqual(result.returncode, 0)
                if missing_artifact:
                    self.assertIn(missing_artifact, result.stderr)
                else:
                    self.assertIn("absolute existing directory", result.stderr)
                self.assertFalse((root / "swift.log").exists())
                self.assertFalse((root / ".build/MacAmbientJev.app").exists())

    def test_python_version_is_checked_before_fetching(self) -> None:
        root, environment = self.make_fake_repository()
        environment["PYTHON_VERSION_OK"] = "0"

        result = self.run_build(root, environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Python 3.12 or newer", result.stderr)
        python_calls = (root / "python.log").read_text().splitlines()
        self.assertEqual(len(python_calls), 1)
        self.assertFalse((root / "swift.log").exists())
        self.assertFalse((root / ".build/MacAmbientJev.app").exists())

    def make_fake_repository(self) -> tuple[Path, dict[str, str]]:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name) / "repo"
        scripts = root / "scripts"
        package = root / "app/MacAmbientJev"
        stub_bin = root / "stub-bin"
        fake_bin = root / "fake-bin"
        tagger_directory = root / "fetched/clause-tagger"
        scripts.mkdir(parents=True)
        (package / "Assets").mkdir(parents=True)
        (package / "Entitlements").mkdir(parents=True)
        stub_bin.mkdir()
        (fake_bin / "mlx-swift_Cmlx.bundle/Contents/Resources").mkdir(parents=True)
        tagger_directory.mkdir(parents=True)
        shutil.copy2(BUILD_SCRIPT, scripts / "build_app.sh")
        shutil.copy2(INFO_PLIST_SCRIPT, scripts / "app_info_plist.sh")
        (package / "Assets/AppIcon.png").write_bytes(b"fake icon")
        (fake_bin / "MacAmbientJev").write_bytes(b"fake executable")
        (fake_bin / "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib").write_bytes(b"shader")
        (tagger_directory / "ClauseTagger.mlpackage").mkdir()
        (tagger_directory / "ClauseTagger.mlpackage/Manifest.json").write_text("{}\n", encoding="utf-8")
        (tagger_directory / "tokenizer.json").write_text("{}\n", encoding="utf-8")
        (tagger_directory / "LICENSE.md").write_text("license text\n", encoding="utf-8")

        stubs = {
            "python3": '''#!/bin/bash
printf '%s\\n' "$*" >> "$PYTHON_LOG"
if [[ "${1:-}" == "-c" ]]; then
  [[ "$PYTHON_VERSION_OK" == "1" ]]
  exit $?
fi
if [[ "${1:-}" == "-B" && "$2" == "$EXPECTED_FETCHER" && "$3" == "--format" && "$4" == "coreml" ]]; then
  if [[ "$FETCH_STATUS" != "0" ]]; then
    echo "stub fetch failure" >&2
    exit "$FETCH_STATUS"
  fi
  printf '%s\\n' "$TAGGER_DIRECTORY"
  exit 0
fi
echo "unexpected python3 arguments: $*" >&2
exit 2
''',
            "swift": '''#!/bin/bash
printf '%s\\n' "$*" >> "$SWIFT_LOG"
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf '%s\\n' "$FAKE_BIN"
fi
''',
            "sips": '''#!/bin/bash
: > "${!#}"
''',
            "iconutil": '''#!/bin/bash
: > "${!#}"
''',
            "security": '''#!/bin/bash
exit 0
''',
            "codesign": '''#!/bin/bash
exit 0
''',
        }
        for name, contents in stubs.items():
            stub = stub_bin / name
            stub.write_text(contents, encoding="utf-8")
            stub.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{stub_bin}{os.pathsep}{environment['PATH']}",
                "PYTHON_LOG": str(root / "python.log"),
                "PYTHON_VERSION_OK": "1",
                "EXPECTED_FETCHER": str(scripts / "fetch_clause_tagger.py"),
                "FETCH_STATUS": "0",
                "TAGGER_DIRECTORY": str(tagger_directory),
                "SWIFT_LOG": str(root / "swift.log"),
                "FAKE_BIN": str(fake_bin),
            }
        )
        return root, environment

    def run_build(self, root: Path, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(root / "scripts/build_app.sh")],
            cwd=root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()

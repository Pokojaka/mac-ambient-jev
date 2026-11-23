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

    def test_onnxruntime_fetch_failure_stops_before_swift_and_publication(self) -> None:
        root, environment = self.make_fake_repository()
        environment["ORT_FETCH_STATUS"] = "1"

        result = self.run_build(root, environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stub ONNX Runtime fetch failure", result.stderr)
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
        self.assertEqual(
            (root / ".build/MacAmbientJev.app/Contents/Resources/MacAmbientJev_MacAmbientJevRuntime.bundle/Contents/Resources/Resources/fluid_vad_model.json").read_bytes(),
            b"fake model",
        )
        python_calls = (root / "python.log").read_text().splitlines()
        self.assertLess(
            python_calls.index(f"-B {environment['EXPECTED_ORT_FETCHER']}"),
            python_calls.index(f"-B {environment['EXPECTED_FETCHER']} --format coreml"),
        )
        self.assertTrue((root / "swift.log").is_file())
        sdk_lib_dir = root / ".build/onnxruntime/1.31.0/osx-arm64/lib"
        sdk_dylib = sdk_lib_dir / "libonnxruntime.1.dylib"
        bundled_dylib = root / ".build/MacAmbientJev.app/Contents/Frameworks/libonnxruntime.1.dylib"
        self.assertEqual(bundled_dylib.read_bytes(), b"fake ONNX Runtime dylibsigned")
        self.assertEqual(sdk_dylib.read_bytes(), b"fake ONNX Runtime dylib")
        self.assertEqual(
            (root / ".build/MacAmbientJev.app/Contents/Resources/onnxruntime/LICENSE").read_bytes(),
            b"fake ONNX Runtime license\n",
        )
        self.assertEqual(
            (root / ".build/MacAmbientJev.app/Contents/Resources/onnxruntime/ThirdPartyNotices.txt").read_bytes(),
            b"fake third-party notices\n",
        )
        self.assertEqual(
            (root / "install_name_tool.log").read_text(),
            f"call\n<-delete_rpath>\n<{sdk_lib_dir}>\n<{root / '.build/MacAmbientJev.app/Contents/MacOS/MacAmbientJev'}>\n---\n",
        )
        identity = "MacAmbientJev Local Signing"
        app = root / ".build/MacAmbientJev.app"
        self.assertEqual(
            (root / "codesign.log").read_text(),
            "\n".join(
                (
                    "<--force>",
                    "<--sign>",
                    f"<{identity}>",
                    f"<{bundled_dylib}>",
                    "---",
                    "<--force>",
                    "<--sign>",
                    f"<{identity}>",
                    "<--entitlements>",
                    f"<{root / 'app/MacAmbientJev/Entitlements/MacAmbientJev.entitlements'}>",
                    f"<{app}>",
                    "---",
                    "",
                )
            ),
        )

    def test_runtime_linkage_failures_stop_before_signing(self) -> None:
        cases = (
            ("install_name_tool_failure", "install_name_tool: SDK rpath not found"),
            ("missing_ort_dependency", "App is missing dependency @rpath/libonnxruntime.1.dylib"),
            ("wrong_ort_dependency", "App is missing dependency @rpath/libonnxruntime.1.dylib"),
            ("missing_framework_rpath", "App is missing rpath @executable_path/../Frameworks"),
            ("wrong_framework_rpath", "App is missing rpath @executable_path/../Frameworks"),
            ("repository_local_rpath", "App contains repository-local runtime path:"),
        )
        for scenario, diagnostic in cases:
            with self.subTest(scenario=scenario):
                root, environment = self.make_fake_repository()
                environment["OTOOL_SCENARIO"] = scenario
                if scenario == "install_name_tool_failure":
                    environment["INSTALL_NAME_STATUS"] = "1"

                result = self.run_build(root, environment)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertFalse((root / "codesign.log").exists())

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
        root = Path(temporary_directory.name) / "repo with spaces"
        scripts = root / "scripts"
        package = root / "app/MacAmbientJev"
        stub_bin = root / "stub-bin"
        fake_bin = root / "fake-bin"
        tagger_directory = root / "fetched/clause-tagger"
        sdk_lib_directory = root / ".build/onnxruntime/1.31.0/osx-arm64/lib"
        scripts.mkdir(parents=True)
        (package / "Assets").mkdir(parents=True)
        (package / "Entitlements").mkdir(parents=True)
        sdk_lib_directory.mkdir(parents=True)
        stub_bin.mkdir()
        (fake_bin / "MacAmbientJev_MacAmbientJevRuntime.bundle/Contents/Resources/Resources").mkdir(parents=True)
        tagger_directory.mkdir(parents=True)
        shutil.copy2(BUILD_SCRIPT, scripts / "build_app.sh")
        shutil.copy2(INFO_PLIST_SCRIPT, scripts / "app_info_plist.sh")
        (package / "Assets/AppIcon.png").write_bytes(b"fake icon")
        (sdk_lib_directory / "libonnxruntime.1.dylib").write_bytes(b"fake ONNX Runtime dylib")
        sdk_root = sdk_lib_directory.parent
        (sdk_root / "LICENSE").write_bytes(b"fake ONNX Runtime license\n")
        (sdk_root / "ThirdPartyNotices.txt").write_bytes(b"fake third-party notices\n")
        (fake_bin / "MacAmbientJev").write_bytes(b"fake executable")
        (fake_bin / "MacAmbientJev_MacAmbientJevRuntime.bundle/Contents/Resources/Resources/fluid_vad_model.json").write_bytes(b"fake model")
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
if [[ "${1:-}" == "-B" && "$2" == "$EXPECTED_ORT_FETCHER" ]]; then
  if [[ "$ORT_FETCH_STATUS" != "0" ]]; then
    echo "stub ONNX Runtime fetch failure" >&2
    exit "$ORT_FETCH_STATUS"
  fi
  exit 0
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
            "install_name_tool": '''#!/bin/bash
printf 'call\\n' >> "$INSTALL_NAME_LOG"
printf '<%s>\\n' "$@" >> "$INSTALL_NAME_LOG"
printf '%s\\n' '---' >> "$INSTALL_NAME_LOG"
if [[ "$INSTALL_NAME_STATUS" != "0" ]]; then
  echo "install_name_tool: SDK rpath not found" >&2
  exit "$INSTALL_NAME_STATUS"
fi
''',
            "otool": '''#!/bin/bash
case "$1" in
  -L)
    printf '%s\\n' "/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)"
    case "$OTOOL_SCENARIO" in
      missing_ort_dependency) ;;
      wrong_ort_dependency) printf '%s\\n' "@rpath/libonnxruntime.wrong.dylib (compatibility version 1.0.0, current version 1.0.0)" ;;
      success|missing_framework_rpath|wrong_framework_rpath|repository_local_rpath) printf '%s\\n' "@rpath/libonnxruntime.1.dylib (compatibility version 1.0.0, current version 1.0.0)" ;;
      *) echo "unexpected otool scenario: $OTOOL_SCENARIO" >&2; exit 2 ;;
    esac
    ;;
  -l)
    printf '%s\\n' \
      'Load command 0' \
      '          cmd LC_RPATH' \
      '      cmdsize 40' \
      '         path /usr/lib/swift (offset 12)' \
      'Load command 1' \
      '          cmd LC_RPATH' \
      '      cmdsize 40' \
      '         path @loader_path (offset 12)' \
      'Load command 2' \
      '          cmd LC_RPATH' \
      '      cmdsize 96' \
      '         path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx (offset 12)'
    case "$OTOOL_SCENARIO" in
      missing_framework_rpath) ;;
      wrong_framework_rpath) printf '%s\\n' 'Load command 3' '          cmd LC_RPATH' '      cmdsize 56' '         path @executable_path/../WrongFrameworks (offset 12)' ;;
      success|repository_local_rpath) printf '%s\\n' 'Load command 3' '          cmd LC_RPATH' '      cmdsize 56' '         path @executable_path/../Frameworks (offset 12)' ;;
      *) echo "unexpected otool scenario: $OTOOL_SCENARIO" >&2; exit 2 ;;
    esac
    if [[ "$OTOOL_SCENARIO" == "repository_local_rpath" ]]; then
      printf 'Load command 4\\n          cmd LC_RPATH\\n      cmdsize 80\\n         path %s (offset 12)\\n' "$REPOSITORY_LOCAL_RPATH"
    fi
    ;;
  *)
    echo "unexpected otool arguments: $*" >&2
    exit 2
    ;;
esac
''',
            "codesign": '''#!/bin/bash
printf '<%s>\\n' "$@" >> "$CODESIGN_LOG"
printf '%s\\n' '---' >> "$CODESIGN_LOG"
if [[ "$4" == "$EXPECTED_BUNDLED_DYLIB" ]]; then
  printf 'signed' >> "$EXPECTED_BUNDLED_DYLIB"
fi
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
                "EXPECTED_ORT_FETCHER": str(scripts / "fetch_onnxruntime.py"),
                "ORT_FETCH_STATUS": "0",
                "EXPECTED_FETCHER": str(scripts / "fetch_clause_tagger.py"),
                "FETCH_STATUS": "0",
                "TAGGER_DIRECTORY": str(tagger_directory),
                "SWIFT_LOG": str(root / "swift.log"),
                "FAKE_BIN": str(fake_bin),
                "INSTALL_NAME_LOG": str(root / "install_name_tool.log"),
                "INSTALL_NAME_STATUS": "0",
                "OTOOL_SCENARIO": "success",
                "REPOSITORY_LOCAL_RPATH": str(root / ".build/repository-local-runtime"),
                "EXPECTED_BUNDLED_DYLIB": str(root / ".build/MacAmbientJev.app/Contents/Frameworks/libonnxruntime.1.dylib"),
                "CODESIGN_LOG": str(root / "codesign.log"),
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

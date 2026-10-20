# Third-Party Notices

This project depends on or studies the following upstream projects.

## FluidAudio

Repository: `FluidInference/FluidAudio`

Used for local voice activity detection and speaker diarization. Preserve the upstream license and notices for the exact pinned version.

## speech-swift

Repository: `soniqo/speech-swift`

Used for the local Qwen3-ASR implementation. The upstream repository identifies its license as Apache-2.0. Preserve its license and notices for the pinned revision.

## meeting-transcriber

Repository: `pasrom/meeting-transcriber`

Used as a reference for macOS microphone capture, permissions, session flow, and audio plumbing. If source code is copied or adapted, record the source file and preserve the applicable upstream copyright and license notice here.

## miniaudio

リポジトリ: `mackron/miniaudio`

固定リリース: [0.11.23](https://github.com/mackron/miniaudio/releases/tag/0.11.23)

ソース: https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/miniaudio.h

SHA-256: `7e4f3f13c8fe66df2080ac3dd12a89193e3c2463cb7f067c798abd7331cd8ee6`

C ラッパーから WAV / FLAC / MP3 のデコードとサンプルレート変換に使用します。upstream の Unlicense / MIT No Attribution の選択肢から、本プロジェクトでは MIT No Attribution (MIT-0) を選択します。

```text
Copyright 2025 David Reid

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ONNX Runtime

リポジトリ: [`microsoft/onnxruntime`](https://github.com/microsoft/onnxruntime)

固定リリース: [1.31.0](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)

ソース: [LICENSE](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/LICENSE)

Windows / Linux で ONNX Runtime C API の CPU Execution Provider を使用します。取得したアーカイブに含まれる `LICENSE` と `ThirdPartyNotices.txt` は、展開した runtime root に保持します。アーカイブの SHA-256 は [Windows / Linux の ONNX Runtime 取得手順](docs/windows.md#onnx-runtime)を参照してください。

```text
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

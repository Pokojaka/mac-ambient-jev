# Third-Party Notices

This project depends on or studies the following upstream projects.

## FluidAudio

Repository: `FluidInference/FluidAudio`

Used for local voice activity detection and speaker diarization. Preserve the upstream license and notices for the exact pinned version.

`app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime` と `MacAmbientJevPipeline` の `VADStreamingStateMachine` は、FluidAudio 0.15.8 の `Sources/FluidAudio/VAD/VadManager+Streaming.swift`（`streamingStateMachine`、Apache-2.0）の発話開始・終了判定をポートしたものです。アプリが使う経路（開始閾値 0.50、終了閾値 = 開始閾値 − 0.15、最短無音 0.75 秒、speech padding 0）だけを残し、FluidAudio の型と Core ML には依存しません。`VADChunkScoring` の chunk 集約（8 frame の noisy-OR と部分 chunk の最後の sample 反復）は、FluidAudio の Core ML model `silero-vad-unified-256ms-v6.2.1` と `VadManager.swift` の `processChunk` の動作に合わせています。

`app/MacAmbientJev/Sources/MacAmbientJevDiarization` は、FluidAudio 0.15.8 の offline 話者分離（`Sources/FluidAudio/Diarizer/Offline/`、Apache-2.0）の reconstruction、Hungarian assignment、centroid、VBx、PLDA、mask 選択の計算をポートしたものです。Core ML と FluidAudio の型には依存しません。

FluidAudio 0.15.8 は Apache License, Version 2.0 です（<https://www.apache.org/licenses/LICENSE-2.0>）。ライセンス全文は <https://github.com/FluidInference/FluidAudio/blob/v0.15.8/LICENSE> にあります。上流の LICENSE は著作権者名を記載していません。

## fastcluster

FluidAudio 0.15.8 は `Sources/FastClusterWrapper/fastcluster_internal.hpp` に fastcluster を同梱しています。`app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1AHC.swift` は、その `binary_min_heap` と `generic_linkage_vector_alternative` を Swift にポートしたもので、ソース先頭に、FluidAudio 0.15.8 の `ThirdPartyLicenses/fastcluster-LICENSE.md` と同じ次の BSD 2-Clause License 表記を保持しています。

```text
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## speech-swift

Repository: `soniqo/speech-swift`

Used for the local Qwen3-ASR implementation. The upstream repository identifies its license as Apache-2.0. Preserve its license and notices for the pinned revision.

## Qwen3-ASR tokenizer

`scripts/fetch_qwen3_asr_tokenizer.py` は Hugging Face の [`andrewleech/qwen3-asr-1.7b-onnx`](https://huggingface.co/andrewleech/qwen3-asr-1.7b-onnx/tree/df916193ac67e59347769891a21e10d81d12acdd)（commit `df916193ac67e59347769891a21e10d81d12acdd`）から `tokenizer.json`（SHA-256 `bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92`）を取得します。このファイルは Qwen (Alibaba Cloud) の Qwen3-ASR の tokenizer で、Apache License, Version 2.0 です（<https://www.apache.org/licenses/LICENSE-2.0>）。リポジトリには含めず、実行時に取得します。PortableRuntime の `Qwen3ASRTokenDecoder` は、そこから `model.vocab` と `added_tokens` を読んで token id を text に戻します。

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

## Silero VAD

Windows / Linux のフレーム推論は、固定版 [`snakers4/silero-vad`](https://github.com/snakers4/silero-vad/tree/5cd7945676eb32225748052e2e6a0580e4686a08) v6.2.3（commit `5cd7945676eb32225748052e2e6a0580e4686a08`）の `OnnxWrapper` にある per-frame probability と recurrent state / context の契約を mirror します。使用する ONNX model は `src/silero_vad/data/silero_vad_16k_op15.onnx` で、SHA-256 は `7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49` です。1 frame は16 kHz mono の512 samples で、前 frame の末尾64 samples を context として連結します。初期 context と recurrent state はゼロで、推論の sample rate は16000です。成功した推論の state と context を次 frame に引き継ぎます。実装が参照する固定版 upstream の [utils_vad.py `OnnxWrapper`](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/src/silero_vad/utils_vad.py#L103-L144) と [LICENSE](https://github.com/snakers4/silero-vad/blob/5cd7945676eb32225748052e2e6a0580e4686a08/LICENSE) を参照してください。

```text
MIT License

Copyright (c) 2020-present Silero Team

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

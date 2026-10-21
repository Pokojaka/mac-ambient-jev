# P3.3 AHC 合成 benchmark 計測記録（2026-10-21）

## 環境と対象

- Mac16,12、Apple M4、物理 RAM 17,179,869,184 bytes（16 GiB）、macOS 27.0.1 (26A434)。
- Apple Swift 6.4（swiftlang 6.4.0.34.1）、clang 2100.3.34.1、target `arm64-apple-macosx27.0.0`。test runner の target は `arm64e-apple-macos14.0`、Testing Library は 2084。
- AHC の参照元は FluidAudio 0.15.8、revision `87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc`。pinned [FastClusterWrapper.cpp](https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FastClusterWrapper/FastClusterWrapper.cpp) が呼ぶ [fastcluster_internal.hpp](https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FastClusterWrapper/fastcluster_internal.hpp) の `generic_linkage_vector_alternative` を Swift port で実装し、root-first cut は pinned [AHCClustering.swift](https://github.com/FluidInference/FluidAudio/blob/87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc/Sources/FluidAudio/Diarizer/Offline/Clustering/AHCClustering.swift) に対応させています。対象は [Community1AHC.swift](../../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1AHC.swift) と [Community1AHCBenchmark.swift](../../app/MacAmbientJev/Tests/MacAmbientJevDiarizationTests/Community1AHCBenchmark.swift) です。
- これは portable Swift AHC の合成入力 benchmark で、FluidAudio の実 C++ 実装を直接計測していません。実音声、end-to-end diarization、モデル推論、モデル読み込み、推論 latency の計測でもありません。

AHC は全 `N-1` merge の tree を保持し、全 pair 距離行列・全 pair sort は作りません。初期距離探索は `O(N²D)` で、stale nearest-neighbor 再探索により最悪では `O(N³D)` となり得ます。作業領域は `O(ND)+O(N)` であり、これは時間量の保証ではありません。resource meter、work budget、小さい入力への fallback、近似経路はありません。root-first cut は centroid inversion を含め、root から辿った subtree の height を判定します。

benchmark test は `MAC_AMBIENT_JEV_RUN_AHC_BENCHMARK=1` のときだけ有効で、Release 構成と、default のない正の `MAC_AMBIENT_JEV_AHC_BENCHMARK_N`（160 の倍数）が必須です。通常の `swift test` では無効です。10分の `timeLimit` は test 実行をキャンセルする上限であり、アルゴリズムの resource budget、入力 sampling cap、または merge の早期停止ではありません。この実行は58.88秒で自然に終了したため、時間上限による cutoff や小さい代替ケースは使っていません。

## 入力と検証

`N=16,000`、`D=256`。SplitMix64 seed `0xA8C0160002560008` で8個の密な乱数 unit center を生成し、各 row に対応 center と各座標一様 jitter `0.025` 倍を加えてから L2 正規化します。各20 rows の turn を8群で巡回します。input generation と AHC の両方を test code 内で L2 正規化します。期待 label は全 row について `(row / 20) % 8` として benchmark code が作り、全 label の完全一致を assertion します。

検証は `merges == 15,999`、root merge の `size == 16,000`、cluster 数8、全 row の期待 labels 一致です。実行時 assertion はすべて成功しました。36 AHC fixture の label parity（centroid inversion を含む）は、この benchmark とは別に debug と optimized runner の7つの AHC tests で検証済みです。

## 再現手順

リポジトリルートから実行します。先行した `-Xswiftc -enable-testing` なしの Release `swift build` は、`@testable` を使う test target の compatible-module dependency error になりました。Release の `swift build` は testing を既定で有効にしないため、この flag を明示した次の build は成功しました（41.88秒）。失敗ログ全文はここには転記しません。

```bash
uptime
swift build --package-path app/MacAmbientJev --jobs 4 -c release --target MacAmbientJevDiarizationTests -Xswiftc -enable-testing
```

benchmark bundle は一つだけを起動し、他の build・test・model job と並行させず実行しました。計測直前の `uptime` は 21:08、up 23:41、1 user、load averages 2.71, 2.94, 3.06 でした。以下の command は build time・package resolution・FluidAudio / MLX の build・model load を含みません。helper は diarization test bundle のみをロードし、bundle 内に他の portable algorithm test code があっても `--filter Community1AHCBenchmark` により実際に実行する test は1件です。test が import するのは `Testing` ですが、process には Foundation、Swift Testing、XCTest support の runtime も含まれます。Swift Testing の helper runner protocol と Darwin の library path 指定は[公式 command-line debugging 文書](https://raw.githubusercontent.com/swiftlang/swift-testing/main/Documentation/CommandlineDebugging.md)を参照してください。

```bash
uptime
/usr/bin/time -l /usr/bin/env MAC_AMBIENT_JEV_RUN_AHC_BENCHMARK=1 MAC_AMBIENT_JEV_AHC_BENCHMARK_N=16000 DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks DYLD_LIBRARY_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path app/MacAmbientJev/.build/out/Products/Release/MacAmbientJevDiarizationTests.xctest/Contents/MacOS/MacAmbientJevDiarizationTests --testing-library swift-testing --filter Community1AHCBenchmark
```

`DYLD_FRAMEWORK_PATH` と `DYLD_LIBRARY_PATH` は `/usr/bin/time` の後の `/usr/bin/env` で設定します。macOS の `/usr/bin/time` は `DYLD_` 環境変数を子 process の exec 前に取り除くため、この位置で helper に渡します。Swift Testing の conditional test gate は[有効化と無効化の公式文書](https://docs.swift.org/latest/documentation/testing/enablinganddisabling/)を参照してください。

## 生出力

```text
AHC_BENCHMARK {"N":16000,"D":256,"speakers":8,"input_generation_seconds":0.015638542,"ahc_seconds":58.857762959,"merges":15999,"cluster_count":8}
✔ Test clusteredEmbeddings() passed after 58.880 seconds.
✔ Suite Community1AHCBenchmark passed after 58.880 seconds.
✔ Test run with 1 test in 1 suite passed after 58.880 seconds.
       58.93 real        58.85 user         0.05 sys
           149897216  maximum resident set size
                   0  average shared memory size
                   0  average unshared data size
                   0  average unshared stack size
               16981  page reclaims
                  22  page faults
                   0  swaps
                   0  block input operations
                   0  block output operations
                   7  messages sent
                   0  messages received
                   0  signals received
                   0  voluntary context switches
                5271  involuntary context switches
       1916616735644  instructions retired
        238266164422  cycles elapsed
           120865584  peak memory footprint
```

## 解釈と限界

AHC 自体の `ContinuousClock` 計測は58.857762959秒、入力生成は0.015638542秒でした。外側の `/usr/bin/time -l` による全 test process の最大 resident set size は149,897,216 bytes（約142.953125 MiB）です。`peak memory footprint` 120,865,584 bytes は別の指標で、RSS と同じ値として扱いません。

RSS は AHC だけの割当量ではありません。既知の主な payload は入力 `16,000×256×8 = 32,768,000` bytes と、AHC 内の flat coordinate buffer `(2×16,000−1)×256×8 = 65,533,952` bytes で、これらに加えて tree、heap、その他の配列、Swift allocator、test harness、ロード済み frameworks/runtime を含む process 全体の値です。この測定から AHC 単体の追加 working set や各配列の実測量を差し引いて推定しません。

実測値はこの機器・build・合成ケースでの一回の経過時間と process RSS です。性能閾値、実時間の上限、実データの規模への外挿、実音声の品質・推論 latency の根拠にはしません。

## fastcluster の帰属とライセンス

対象の Swift 実装は、FluidAudio が利用する fastcluster の heap/list/vector algorithm を Swift に翻訳したものです。fastcluster の著作権表示と BSD 2-Clause license を以下に記載します。

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

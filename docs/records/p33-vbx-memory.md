# P3.3 VBx メモリ確認（2026-10-21）

## 環境・方法

Mac16,12、macOS 27.0.1 (26A434)、Apple Swift 6.4.0.34.1 / clang 2100.3.34.1、arm64。合成 smoke ケース `N=16000, K=50, Drho=8, E=256` を、`-Onone` で既存の [Community1Profile.swift](../../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Profile.swift)、[Community1VBx.swift](../../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1VBx.swift)、[Community1Centroids.swift](../../app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Centroids.swift) と一緒に単体実行ファイルへコンパイルした。追加依存は `Foundation` と `Darwin` のみ。入力は全行で共有するゼロ rho 行、`row % 50` の初期ラベル、全要素 1 の phi、全行で共有する 256 要素（各 1/16）の embedding 行。アルゴリズム前に統計を取得し、VBx refine と posterior を再計算しながら行ごとに集計する centroid compute を順に実行した。全入力と結果を `withExtendedLifetime` で測定後まで保持した。probe は2 iteration、active 50、50×256 centroid（全座標 1/16）を検証する。

一時 probe のソースを `$PROBE/Probe.swift` として保存した状態で、リポジトリルートから実行したコンパイル／計測コマンド：

```sh
ROOT=$(git rev-parse --show-toplevel)
PROBE=/tmp/p33-vbx-memory.G7sgaw
swiftc -Onone "$PROBE/Probe.swift" "$ROOT/app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Profile.swift" "$ROOT/app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1VBx.swift" "$ROOT/app/MacAmbientJev/Sources/MacAmbientJevDiarization/Community1Centroids.swift" -o "$PROBE/vbx-memory-probe"
/usr/bin/time -l "$PROBE/vbx-memory-probe"
```

probe ソース全文：

```swift
import Foundation
import Darwin

enum ProbeError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message):
            return "VBx memory probe failed: \(message)"
        }
    }
}

@main
struct VBxMemoryProbe {
    static func main() throws {
        let n = 16_000, k = 50, dRho = 8, e = 256
        let zeroRhoRow = [Double](repeating: 0, count: dRho)
        let rhoFeatures = [[Double]](repeating: zeroRhoRow, count: n)
        let initialClusters = (0..<n).map { $0 % k }
        let phi = [Double](repeating: 1, count: dRho)
        let embeddingRow = [Double](repeating: 1.0 / 16.0, count: e)
        let trainingEmbeddings = [[Double]](repeating: embeddingRow, count: n)

        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        let vbx = try Community1VBx.refine(
            rhoFeatures: rhoFeatures, initialClusters: initialClusters, phi: phi
        )
        guard vbx.iterationCount == 2 else { throw ProbeError.failed("expected 2 VBx iterations, got \(vbx.iterationCount)") }
        let centroids = try Community1Centroids.compute(
            trainingEmbeddings: trainingEmbeddings, rhoFeatures: rhoFeatures, vbx: vbx
        )
        let active = vbx.pi.filter { $0 > Community1Profile.activePriorThreshold }.count
        guard vbx.pi.count == k, active == k, centroids.sourceClusterIndices.count == k,
              centroids.centroids.count == k,
              centroids.centroids.allSatisfy({ $0.count == e && $0.allSatisfy { abs($0 - 1.0 / 16.0) < 1e-12 } }) else {
            throw ProbeError.failed("expected K=50 active speakers and 50 centroids of 256 coordinates at 1/16")
        }

        var after = malloc_statistics_t()
        withExtendedLifetime((rhoFeatures, initialClusters, phi, trainingEmbeddings, vbx, centroids)) {
            malloc_zone_statistics(nil, &after)
            print("case N=\(n) K=\(k) Drho=\(dRho) E=\(e); iterations=\(vbx.iterationCount); active=\(active); centroids=\(centroids.centroids.count)x\(e) at 1/16")
            print("before size_in_use=\(before.size_in_use) max_size_in_use=\(before.max_size_in_use) size_allocated=\(before.size_allocated)")
            print("after  size_in_use=\(after.size_in_use) max_size_in_use=\(after.max_size_in_use) size_allocated=\(after.size_allocated)")
            if after.max_size_in_use >= before.size_in_use {
                print("delta_after_max_size_in_use_minus_before_size_in_use=\(after.max_size_in_use - before.size_in_use)")
            } else {
                print("delta_after_max_size_in_use_minus_before_size_in_use=unavailable (negative)")
            }
            print("hypothetical_dense_gamma_payload_NxKx8=\(n * k * MemoryLayout<Double>.stride) bytes")
        }
    }
}
```

## 結果と解釈

probe は期待値検証を通過。`malloc_zone_statistics(nil, &stats)` の実測値（bytes）：

| 統計 | algorithm 前 | algorithm 後 |
|---|---:|---:|
| `size_in_use` | 473,472 | 609,744 |
| `max_size_in_use` | 0 | 0 |
| `size_allocated` | 20,971,520 | 33,554,432 |

指定差分 `after.max_size_in_use - before.size_in_use` は負になるため算出不能。`size_allocated` の増分は 12,582,912 bytes。対照用の仮想 dense gamma payload `N×K×8` は 6,400,000 bytes（6.10 MiB）。この allocator 観測値は dense payload との合否比較には使えず、allocator 側のメモリ根拠は不確定として扱う。特に `size_allocated` は予約済み領域であり high-water 値と同じではない。

Apple の [libmalloc `malloc.h`](https://raw.githubusercontent.com/apple-oss-distributions/libmalloc/main/include/malloc/malloc.h) では、zone を `nil` にした `malloc_zone_statistics` は全 zone を合算し、`size_in_use` は現在値、`max_size_in_use` は high water mark of touched memory と説明されている。したがってこれは正確な live-allocation heap や全 transient bytes の計測ではなく、プロセス全体のピークメモリを保証する値でもない。今回 `max_size_in_use` が両回 0 のため、要求した差分自体が成立しない。別の allocator 指標への置き換え・再試行はせず、allocator 統計からメモリ削減を主張しない。

独立実行ファイルに対する `/usr/bin/time -l` は real 28.77 s、maximum resident set size 7,094,272 bytes（約 6.76 MiB、probe プロセス全体）。これは VBx 単体の割当量ではない。

決定的な追加根拠はソース形状の確認：VBx は `gValues` 等の行配列と `K×Drho` パラメータを使い、E-step の `K` 個の score/probability を1行ずつ再利用する。`N×K` posterior/gamma 配列は確保しない（VBx scratch は `O(N + K·Drho)`）。centroid overload は posterior responsibility を各行で再計算して即時集計し、scratch は `O(K·E + K + Drho)`。この限定したソース確認が、密な `N×K` 中間行列を避けていることの根拠であり、allocator 数値は裏付けを与えない。

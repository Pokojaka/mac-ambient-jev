# miniaudio

このディレクトリには miniaudio のヘッダーを同梱し、`CMiniaudio.c` が実装とラッパーを提供します。Swift Package は `CMiniaudio` ターゲットを Windows と Linux で追加し、macOS では追加しません。

- リリース: [0.11.23](https://github.com/mackron/miniaudio/releases/tag/0.11.23)
- ソース: https://raw.githubusercontent.com/mackron/miniaudio/0.11.23/miniaudio.h
- SHA-256 (`shasum -a 256`): `7e4f3f13c8fe66df2080ac3dd12a89193e3c2463cb7f067c798abd7331cd8ee6`
- ライセンス: upstream の選択肢から MIT No Attribution (MIT-0) を選択します。ライセンス全文はリポジトリルートの `THIRD-PARTY-NOTICES.md` とヘッダー末尾に記載されています。

## 現在の使用方法

`CMiniaudio.c` は WAV / FLAC / MP3 のデコードと、モノラル float32 PCM のサンプルレート変換を実装します。音声キャプチャ／録音の実装はありません。ビルド時には次の定義を実際に設定しています。

```c
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_RESOURCE_MANAGER
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ATOMIC_MODERN_GCC
```

Windows (`_WIN32`) ではさらに `MA_ENABLE_WASAPI` を定義します。これはコンパイル設定であり、ここに音声キャプチャ機能が実装されていることを意味しません。`MA_ATOMIC_MODERN_GCC` は全ビルドで明示し、Clang の `__atomic` 組み込みを使う現在のコンパイラー設定です。同梱の miniaudio 0.11.23 ヘッダーは変更していません。参照: [miniaudio 0.11.23 manual](https://miniaud.io/docs/manual/index.html)。

Windows の Swift リサンプラーは、入力が 16,000 Hz なら変換せずに入力をそのまま返します。それ以外のレートでは miniaudio 0.11.23 の公開 `ma_linear_resampler` API と order 8 の Butterworth 低域フィルターを使い、モノラル float32 を 16,000 Hz に変換します。`MA_MAX_FILTER_ORDER` はこの vendored header で 8 です。公開 `ma_linear_resampler_config.lpfNyquistFactor` を `0.95` に設定し、Nyquist 周波数より 5% 手前をカットオフにすることで、通過帯域と阻止帯域の間に遷移マージンを設けます。ソースレートを `r` とすると、フィルターレートは `max(r, 16000)`、カットオフは `min(r, 16000) / 2 × 0.95` です。たとえば 48,000 Hz 入力から 16,000 Hz への変換では、カットオフは 7,600 Hz です。

vendored `ma_lpf_reinit` は、even order 8 の biquad sections `j = 0..3` に `Q_j = 1 / (2 cos((2j+1)π/16))` を設定します。各 section の DC 遅延は `1 / (2 Q_j tan(π × cutoff / filterRate))` です。実際の Q 値は `0.50979557910415918`, `0.60134488693504529`, `0.89997622313641557`, `2.5629154477415055` です。そのため `C = Σ[j=0..3] 1/Q_j = 2Σ[j=0..3] cos((2j+1)π/16) = Σ[k=0..7] sin((2k+1)π/16) = 5.1258308954830127`、`D = C / (2 tan(π × cutoff / filterRate))` となります。出力レートでの DC 群遅延は、ダウンサンプリング (`r > 16000`) では `(1 + D) × 16000 / r` フレーム、アップサンプリング (`r < 16000`) では `16000 / r + D` フレームです。

C ラッパーはこの DC 群遅延を最も近い整数の出力フレーム数に丸めて返します。これは miniaudio 自身のレイテンシーフレーム数ではありません。Windows の Swift 側はストリーム開始時にこの数を出力から取り除き、終端ではゼロ入力を与えてフィルターを進めます。累積ソースフレーム数から得られる丸め済みの 16 kHz 境界までだけを出力し、それより後のフィルターテールは破棄します。

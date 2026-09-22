# Mac Ambient Jev

macOS 上で講義や会話を録音・読み込みし、ローカル音声処理を中心に文字起こしを生成する Swift ネイティブアプリです。

V1 では、録音、VAD、Qwen3-ASR、話者分離、場面判定、近接度判定をローカルで処理します。外部 API を利用するのは Jev の意味分類だけです。汎用 LLM は V1 に含みません。

## 必要環境

- macOS 15 以降
- Apple Silicon
- Swift 6 系
- 初回モデル取得時のインターネット接続

音声認識モデルは初回利用時に取得され、その後はアプリのモデル保存領域から再利用します。

## ビルドと起動

```bash
bash scripts/build_app.sh
open .build/MacAmbientJev.app
```

または、

```bash
bash scripts/run_app.sh
```

## V1 検証

```bash
bash scripts/verify_v1.sh
```

通常の検証では実ASRモデルを必要とする smoke test は実行しません。

Apple Silicon 実機でモデルを含めて検証するときは、

```bash
RUN_MODEL_TESTS=1 bash scripts/verify_v1.sh
```

を使用します。

## Jev APIキー

アプリの「設定」→「Jev」から API キーを入力します。

APIキーは macOS Keychain に保存します。UserDefaults、JSON、イベントログには保存しません。

Jev を無効化しても、録音・VAD・ASR・話者分離などのローカル処理は継続します。

## 録音とファイル読み込み

メイン画面のツールバーから、

- 「録音を開始」
- 「音声ファイルを読み込む」

を選択できます。

録音中に ASR が遅延しても、原音声保存と音声認識処理は別状態として扱います。

## データ保存場所

標準実行では、

```text
~/Library/Application Support/mac-ambient-jev/
```

以下にセッション・モデル・設定用データを配置します。

原音声は派生結果より上位の保存対象として扱います。文字起こしや話者分離は再処理可能な派生データです。

## テスト用録音

実講義や個人録音は GitHub に commit せず、

```text
test-data/recordings/local/
```

以下へ置きます。

例:

```text
test-data/recordings/local/lecture-ja-001/
├── audio.m4a
├── manifest.json
└── segments.json
```

音声ファイルだけを処理する場合:

```bash
swift tools/process-recording.swift \
  test-data/recordings/local/lecture-ja-001/audio.m4a
```

同じディレクトリに `segments.json` が生成されます。

評価:

```bash
swift tools/evaluate-session.swift \
  test-data/recordings/local/lecture-ja-001/manifest.json \
  test-data/recordings/local/lecture-ja-001/segments.json
```

評価方法の詳細は `docs/evaluation.md`、長時間・障害時の受け入れ試験は `docs/v1-acceptance.md` を参照してください。

## V1 の境界

V1 では次を行いません。

- 汎用 LLM の組み込み
- Python worker / Python ASR server
- 常駐 HTTP API
- 常駐 MCP server
- 音声や話者 embedding の Jev 送信

外部エージェント連携は V2 の境界として設計します。

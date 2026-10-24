# Mac Ambient Jev

macOS で講義や会話を録音し、音声ファイルも読み込める文字起こしアプリ。録音中は暫定の本文を表示し、停止後に発話区間・話者・本文を確定する。ローカル必須処理は発話区間検出・話者分離・音声認識の3段階。音声認識は Qwen3-ASR、VAD と話者分離は FluidAudio を使い、音声処理はローカルで実行する。

判定の単位は BTSJ 発話文です。境界判定は ASR 原文と次区間の先頭最大60文字、優先度判定は最大40件の発話文を入力にし、app bundle に同梱した Core ML モデルがネットワーク接続なしでこの Mac 上で判定します。

初期表示は ASR 原文です。境界判定が未保存・保留・失敗ならその区間は原文のまま表示し、保存済み判定では F 範囲だけを除き、D/O は残します。優先度が未判定・保留・失敗なら発話文は残し、LOW 判定の保存後に該当 slice を画面と txt/音声書き出しから除きます。ASR 原文とイベントは変更せず、JSON の `display_text` は原文と分けて保持します。詳しくは[発話文判定](docs/decision-engine.md)を参照してください。

## 発話文判定モデル

発話文判定モデル（ClauseTagger.mlpackage と tokenizer.json）は、公開 Hugging Face リポジトリ [Pokojaka/modernbert-ja-30m-utterance-tagger](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/tree/5c0213592cf8d59fc0b665183ab7536ddde05d1f) の commit `5c0213592cf8d59fc0b665183ab7536ddde05d1f` から取得します。Core ML と ONNX の全ファイルの byte count と SHA-256 は、単一の共有 [resource manifest](app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json) に固定されています。`scripts/build_app.sh` は `python3 scripts/fetch_clause_tagger.py --format coreml` を実行し、ClauseTagger.mlpackage、tokenizer.json、LICENSE.md を app bundle の Contents/Resources/clause-tagger に同梱します。

取得物は `.build/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger` にキャッシュし、毎回のビルドで全ファイルの構成・byte count・SHA-256 を検証します。取得失敗や不一致はビルドを停止し、再試行やフォールバックはしません。公開リポジトリからのダウンロードに認証トークンは不要です。アプリは bundle 内のモデルだけを読みます。Qwen3-ASR などの音声処理モデルは別のモデルで、初回利用時に取得してローカルにロードします。

仕様とモデルの更新手順は [発話文判定](docs/decision-engine.md)、実モデル parity テストは [検証と計測](docs/testing.md) を参照してください。

## 配布版を使う

ビルドせずに使う場合は、[Releases](https://github.com/Pokojaka/mac-ambient-jev/releases) からビルド済みの app を入手する。macOS 15 以降、Apple Silicon の Mac が必要。

1. 最新リリースの `MacAmbientJev-<version>.zip` をダウンロードして展開する。
2. 展開した MacAmbientJev.app を「アプリケーション」フォルダへ移す。
3. app は Apple の公証を受けていない自己署名なので、初回はそのまま開くと macOS にブロックされる。一度ダブルクリックしてブロックの表示を閉じ、「システム設定」→「プライバシーとセキュリティ」の下部に出る「このまま開く」を押して開く。ターミナルを使う場合は次のコマンドで隔離属性を外してから開いてもよい。

   ```bash
   xattr -dr com.apple.quarantine /Applications/MacAmbientJev.app
   ```

4. 録音を始めるとマイクの許可を、システム音声モードではシステム音声録音の許可を求められるので許可する。
5. Qwen3-ASR と話者分離のモデルは初回利用時にダウンロードするため、最初の一回はインターネット接続が必要。発話文判定モデルは app に同梱されている。

## ビルドと起動

macOS 15 以降、Apple Silicon、Swift 6 系が必要。依存パッケージと初回のモデル取得にはインターネット接続が必要。

発話文判定モデルの取得には Python 3.12 以上が必要です。`scripts/build_app.sh` は `python3 scripts/fetch_clause_tagger.py --format coreml` を呼び出します。公開 Hugging Face リポジトリからのダウンロードに認証トークンは不要です。

app bundle は「MacAmbientJev Local Signing」という名前の自己署名証明書で署名する。署名が毎回同じなので、マイクとシステム音声の許可が再ビルド後も引き継がれる。証明書がないと `scripts/build_app.sh` はエラーで止まる。証明書は最初に一度だけ作る。

1. 「キーチェーンアクセス」を開き、メニューの「キーチェーンアクセス」→「証明書アシスタント」→「証明書を作成…」を選ぶ。
2. 名前を `MacAmbientJev Local Signing`、固有名のタイプを「自己署名ルート」、証明書のタイプを「コード署名」にして作成する。

リポジトリのルートで実行する。

```bash
bash scripts/build_app.sh
open .build/MacAmbientJev.app
```

ビルドと起動をまとめて行う場合:

```bash
bash scripts/run_app.sh
```

アプリアイコンの元画像は `app/MacAmbientJev/Assets/AppIcon.png`（1024 × 1024 px）。`scripts/build_app.sh` が標準解像度と Retina 用の各サイズから AppIcon.icns を生成し、app bundle に組み込む。元画像が欠けている場合はビルドを停止する。

保存先フォルダーと自動書き出しは設定画面で指定する。

## ライセンス

アプリのコードはルートの [LICENSE](LICENSE) に記載の MIT License です。同梱する学習済み ClauseTagger は別ライセンスの CC BY-NC-ND 4.0 で、名大会話コーパスで学習されています。モデルとライセンスの詳細は [Hugging Face の固定 revision](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/tree/5c0213592cf8d59fc0b665183ab7536ddde05d1f) と [同梱 LICENSE.md](https://huggingface.co/Pokojaka/modernbert-ja-30m-utterance-tagger/resolve/5c0213592cf8d59fc0b665183ab7536ddde05d1f/LICENSE.md) を参照してください。MIT License はアプリのコードに適用され、学習済みモデルには適用されません。リポジトリに含まれる第三者のコードとデータのライセンスは [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) を参照してください。

## 検証

```bash
python3 scripts/check_doc_references.py
bash scripts/verify_v1.sh
```

通常の検証では実 ASR モデルを使うテストを実行しない。モデルテストの環境変数、ファイル入力 CLI、Linux 評価の手順は [検証と計測](docs/testing.md)を参照。

## ドキュメント

- [一覧](docs/README.md): 現行仕様の入口。
- [製品ルール](docs/decisions.md): 表示、保存、処理、評価の規則。
- [構成](docs/architecture.md)・[保存形式](docs/storage.md): モジュールとデータ契約。
- [ライブ](docs/live.md)・[確定処理](docs/final.md): 認識と復旧。
- [音声入力](docs/capture.md)・[発話文判定](docs/decision-engine.md)・[書き出し](docs/export.md): 利用時の動作。
- [Linux 評価](docs/linux.md)・[検証と計測](docs/testing.md): 開発用の実行手順。
- [開発ルール](AGENTS.md): 変更時の文書更新と検証。

個人録音や実講義は Git に含めない。[ローカル評価データ](test-data/recordings/README.md)を参照。

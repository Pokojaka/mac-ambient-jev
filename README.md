# Mac Ambient Jev

macOS で講義や会話を録音し、音声ファイルも読み込める文字起こしアプリ。録音中は暫定の本文を表示し、停止後に発話区間・話者・本文を確定する。ローカル必須処理は発話区間検出・話者分離・音声認識の3段階。音声認識は Qwen3-ASR、VAD と話者分離は FluidAudio を使い、音声処理はローカルで実行する。

境界・優先度判定の単位は BTSJ 発話文です。設定で Jev（API）または学習済みローカル Core ML モデルを選べます。Jev は境界判定にフィラーを含む ASR 原文と次区間の先頭最大60文字、優先度判定にフィラー除去後の閉じた発話文だけを最大40件ずつ送ります。音声・話者は送りません。ローカルモデルは Core ML で推論し、発話文判定にネットワークを使いません。低優先度の発話文は淡色にし、未解決・保留のない全 LOW 行だけを折り畳みます。画面とテキスト書き出しはフィラー除去済みの非空白本文をすべて含め、LOW の全文も残します。ASR 原文・イベントは変更せず、CLI JSON は原文と表示本文を別々に保持します。GUI の書き出しは文字起こし txt と音声のみ。

## 発話文判定エンジン

設定の「発話文の判定」で `Jev（API）` と `ローカルモデル` を選択します。Jev が初期選択で、Jev の利用には API キーが必要です。ローカルモデルは API キーなしで使え、判定データをネットワークへ送りません。

ローカル発話文モデルは手動配置が必要です。sandbox 内の `~/Library/Containers/app.mac-ambient-jev/Data/Library/Application Support/mac-ambient-jev/models/clause-tagger/` に ClauseTagger.mlpackage と tokenizer.json を置きます。自動ダウンロードやパス変更はありません。いずれかが欠ける、またはモデルや tokenizer が不正な場合はエラーとして判定を保留し、Jev へフォールバックしません。Qwen3-ASR の外部音声認識モデルは別のモデルで、従来どおり取得してローカルにロードします。これは発話文 tagger の手動配置とは別です。

仕様と配置は [発話文判定](docs/decision-engine.md)・[保存場所](docs/storage.md)、実モデル parity テストは [検証と計測](docs/testing.md) を参照してください。

## ビルドと起動

macOS 15 以降、Apple Silicon、Swift 6 系が必要。依存パッケージと初回のモデル取得にはインターネット接続が必要。

app bundle は「MacAmbientJev Local Signing」という名前の自己署名証明書で署名する。署名が毎回同じなので、Keychain の API キーへのアクセスを一度「常に許可」すれば、再ビルド後も確認を求めない。証明書がないと `scripts/build_app.sh` はエラーで止まる。証明書は最初に一度だけ作る。

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

Jev の API キーは設定画面で入力し、Keychain に保存する。保存先フォルダーと自動書き出しも設定画面で指定する。

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

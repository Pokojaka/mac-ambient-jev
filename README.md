# Mac Ambient Jev

macOS で講義や会話を録音し、音声ファイルも読み込める文字起こしアプリ。録音中は暫定の本文を表示し、停止後に発話区間・話者・本文・場面・音響範囲を確定する。音声認識は Qwen3-ASR、VAD と話者分離は FluidAudio を使い、音声処理はローカルで実行する。

Jev は発話の優先度分類にだけ使う。低優先度の発話は原文を保持して折り畳む。Jev を無効にしてもローカル処理を使える。場面判定は音響のみ。確定した文字起こしと音声を書き出せる。

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
- [音声入力](docs/capture.md)・[Jev](docs/jev.md)・[書き出し](docs/export.md): 利用時の動作。
- [Linux 評価](docs/linux.md)・[検証と計測](docs/testing.md): 開発用の実行手順。
- [開発ルール](AGENTS.md): 変更時の文書更新と検証。

個人録音や実講義は Git に含めない。[ローカル評価データ](test-data/recordings/README.md)を参照。

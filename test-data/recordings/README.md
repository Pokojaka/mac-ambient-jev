# ローカル評価用録音データ

実講義、会話、個人録音はこのディレクトリ内の local に置く。local 配下はルートの `.gitignore` で除外される。原音声、参照文、処理結果、計測結果を Git に含めない。

配置例:

```text
test-data/recordings/local/lecture-ja-001/
  audio.wav
  reference.txt
  segments.json
```

## segments.json の生成

リポジトリのルートから SwiftPM の CLI を実行する。`AUDIO` には音声ファイル、`SESSIONS_ROOT` にはアプリの保存・cache領域と重ならない隔離した保存ルートを指定する。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" "$AUDIO"
```

出力先を省略すると音声と同じディレクトリに `segments.json` を生成する。明示する場合は音声ファイルの次に出力パスを指定する。入力音声と同じファイルへの出力は拒否する。

通常、処理用に作ったアプリ側セッションは処理終了時に削除する。復旧や保存形式を調べる場合は保持する。

```bash
swift run --package-path app/MacAmbientJev MacAmbientJevProcessRecording \
  --sessions-root "$SESSIONS_ROOT" --keep-session "$AUDIO" "$SEGMENTS"
```

発話文判定は CLI では無効。音声処理はアプリと同じ確定パイプラインを使う。`segments.json` には空本文の区間を含めず、イベントログには保持する。

## 参照文による評価

`MacAmbientJevEvaluateSession` は音声と参照文を指定する manifest と生成済みの `segments.json` を受け取り、ASR CER を出力する。manifest の形式、モデルテストの設定、計測方法は [検証と計測](../../docs/testing.md)、Linux corpus は [Linux 評価](../../docs/linux.md)を参照。

# 改善後アプリでの動画全編 CER（2026-10-16）

## 結果

改善後の GUI アプリで[対象動画](https://www.youtube.com/watch?v=T-jKleBEeM4)を先頭から末尾まで1倍速で再生し、システム音声を録音した。ブラウザーの動画要素で `currentTime = duration = 2532.761`、`ended = true` を確認してから録音を停止した。全編42分12.761秒を対象とする。

| 評価 | CER | 置換 | 削除 | 挿入 | 編集数 / 参照文字数 | 認識文字数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 漢字を含む正規化 | 14.1594% | 1015 | 1287 | 516 | 2818 / 19902 | 19131 |
| ひらがな読み | 9.8004% | 546 | 1346 | 435 | 2327 / 23744 | 22833 |

確定 ASR の195区間すべてが認識成功、失敗0件だった。`processing_metadata.json` の finalization state は `complete`。active ASR run と active segmentation run を選び、全 `segment.created` に対応する `asr.completed` が一つずつあり、source frame 範囲が一致することを検証した。ライブ認識や上書き前の run は採点に混ぜていない。

## 録音と実処理

- セッション: `2026-10-16_02-11-15_録音_cc08e1b1`、capture source は `systemAudio`。
- 16 kHz、mono、float32、40,814,545 frames、2550.9090625秒。開始・停止時の余白を含む。checkpoint に列挙された全5102音声 chunk のサイズと合計 frame 数を検証した。
- checkpoint 順に連結した PCM の SHA-256: `3d2d7224d2dfb751a07d7b1c55f45bd8f74d0d71bdd18b1a13158d86d06706ef`。評価用にコピーした時点の audio storage state は `recordingPCM`。採点したのは、この音声を GUI が確定処理した ASR 原文である。
- 認識末尾の source end は frame 40,656,896（録音開始から2541.056秒）。末尾の原文は「コメント欄などで補足をしていきますので適宜ご参照ください。」で、動画の最終字幕に対応する。
- 確定 ASR run は `asr_final_9dce039a-df24-4f23-bfa3-dffa4b066f5c`。イベント上の開始は2026-10-16 02:55:16 JST、完了は03:07:40 JST（12分24秒）。全確定処理の完了後、GUI で「文字起こしと話者分離が完了しました（195区間）」を確認した。

録音の欠落警告は3回。保存された `missingCallback` は次のとおりで、合計806 frames（50.375 ms）。欠落部分を評価対象から除外していない。

| 開始 frame | 欠落 frames | 欠落時間 |
| ---: | ---: | ---: |
| 418304 | 233 | 14.5625 ms |
| 11342911 | 279 | 17.4375 ms |
| 11344555 | 294 | 18.3750 ms |

## 実装とモデル

確定 ASR は話者交代で細分化せず、VAD の音声区間を保持する。language は `Japanese`、過去の認識文の context は渡さない。VAD の最大長は14秒。字幕や正解の専門語を認識モデルへ渡していない。F・LOW 除去後の表示文ではなく、保存イベントの ASR 原文を source frame 順に連結して採点した。

実イベントの provenance は `qwen3-asr-swift`、`aufklarer/Qwen3-ASR-1.7B-MLX-8bit`、`speech-swift@c4c2fabbe825a9290c19e2f45d54ca3eae96b003`、`language=Japanese`。今回の GUI 用重みファイルの SHA-256 は独立に取得していない。

基準コミットは `330c623913e9662ed0b3e18511992951395fe2f7`。使用したアプリ実行ファイルの SHA-256 は `4b403fca8df826db50eae1871c52fd0e2dbb530f0f9c2b4c746ebf42413a390e` で、録音前後に一致した。実装差分を保存した `implementation.patch` の SHA-256 は `384480d8ba7266007a2a1ca846d1e44364e795858af022fc1545b3488f4d44d9`。

## 字幕と採点方法

ブラウザーから日本語字幕を取得した。字幕 metadata は `authored or unspecified`。全506行（最初2秒、最後2527秒）を使い、話者略号 `水/`、`堀/` を除去した。参照文は raw 22,727文字、SHA-256 は `270c45072c74d34f51f359f6971d14fcbe7bc0614d4ce9ecd1155ce58e6c0e5f`。

CER は本リポジトリの `CharacterErrorRate` による全編の編集距離 `(置換 + 削除 + 挿入) / 参照文字数`。区間別 CER の単純平均ではない。`JapaneseTextNormalizer` version 1（NFKC、空白・句読点除去）を使った。

読みは[先行の短時間比較](youtube-lecture-asr-2026-10-16.md)と同じ `cf-ja-reading-v2`。macOS 27.0.1（26A434）の `CFStringTokenizer`、locale `ja` で読みを取得し、ひらがなへ変換する。数字列は日本語 NumberFormatter spellOut、`%` は「パーセント」へそろえ、英字は大小文字を含め保持する。読み取得後に同じ normalizer を適用する。日本語の読みを取得できなければエラーとし、別方式へ置き換えない。固定10例の検証後に採点した。

字幕には発声の「ラージ A」「スモール a」を A/a/AA などへ編集した箇所がある。この CER は**編集済み字幕との文字差**であり、独立聴取した逐語正解への誤り率ではない。読み CER では「聾者／老者」「潜性／先生」「入植者／入職者」など同音異義語の意味の誤りが見えなくなるため、漢字を含む値と併記する。

先行の冒頭5分38秒では改善後の漢字 CER は19.8187%、読みは12.6476%だった。今回は対象範囲と録音が異なるので、今回との差を改善幅として扱わない。改善前の全編を同一録音で再処理した比較は、この測定では行っていない。

## 保存物と検証

音声セッションのコピー、字幕、参照文、認識原文、全195区間の JSON、採点 Swift ソースと実行ファイル、ログ、結果を、非追跡の `test-data/recordings/local/youtube-T-jKleBEeM4-full-20261016/` に保存した。

- `final-rows.json`: active run から抽出した全区間。SHA-256 `abc33e50acd24e33df33de202d67e9a554cd15b121e0ab8ace6f72933ff133e4`。
- `final-hypothesis.txt`: 採点した ASR 原文。SHA-256 `a4fd82b9fab8008dbe31195ddbdc0b5d0597e2b9752a0e3decf2ef84a8d18291`。
- `final-cer.json`: 両基準の編集数・分母・CER。SHA-256 `419de551865c0e81ca585b4c42e0d5ed8e4b9e8bb2482950da66dccd9d461ad9`。
- `capture-provenance.json`、`run-input.json`: 音声 hash、欠落、実行ファイル、参照字幕、再生完了の観測情報。

active run の網羅性検査、PCM chunk 長と総 frame 数の照合、読み変換の固定例、採点コマンドが成功した。製品コードのビルド・単体テスト・検証は先行比較の記録を参照。この全編測定中に製品コードを変更していない。

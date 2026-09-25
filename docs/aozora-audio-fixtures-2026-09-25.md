# 朗読音声の評価素材（2026-09-25）

この表はローカル評価に用いる取得元、元形式、長さ、SHA-256 を記録する。音声は `/private/tmp` に置き、アプリと配布 zip には含めない。長さは `ffprobe` の値であり、配信ページに記載された丸め値と一致しない場合がある。

| 音声 | 取得元 | 元形式 | 秒 | SHA-256 |
| --- | --- | --- | ---: | --- |
| ごん狐 1 | [LibriVox](https://archive.org/download/gongitsune_um_librivox/gongitsune_01_niimi_64kb.mp3) | MP3, 22050 Hz, 1 ch | 315.899 | `f2dd16a2e9400d54819f0967ccd77a7948b1437dcf739d702f792a3e933fc141` |
| ごん狐 2 | [LibriVox](https://archive.org/download/gongitsune_um_librivox/gongitsune_02_niimi_64kb.mp3) | MP3, 22050 Hz, 1 ch | 177.580 | `b7cbbea06363ca695b8b683cbf727f4d7cd539f93c10cc28fb34ed3bda7ed8e3` |
| ごん狐 3 | [LibriVox](https://archive.org/download/gongitsune_um_librivox/gongitsune_03_niimi_64kb.mp3) | MP3, 22050 Hz, 1 ch | 156.552 | `90d5d802e2d2373e9f8400b6967facc30e971fa89bbce6ac422c24a784c5587d` |
| ごん狐 4 | [LibriVox](https://archive.org/download/gongitsune_um_librivox/gongitsune_04_niimi_64kb.mp3) | MP3, 22050 Hz, 1 ch | 120.842 | `c0d26884e92ffcd58dd5f0c7b2b962b92b80236723eb0441300c87a585240847` |
| ごん狐 5 | [LibriVox](https://archive.org/download/gongitsune_um_librivox/gongitsune_05_niimi_64kb.mp3) | MP3, 22050 Hz, 1 ch | 81.737 | `dd73097db911af6064e1ae4cb9f746809c457a0967843ced6a226b125cd95443` |
| ごん狐 6 | [LibriVox](https://archive.org/download/gongitsune_um_librivox/gongitsune_06_niimi_64kb.mp3) | MP3, 22050 Hz, 1 ch | 93.858 | `c631ad41975b96c8e189e7a0b20f97f525715830cb21f208b86765fdebf98188` |
| よだかの星 | [青空朗読](https://aozoraroudoku.jp/voice/mp3/rd001.mp3) | MP3, 44100 Hz, 1 ch | 1187.082 | `9482340386bf38e38d617358034e8f6609fda33a441d8808d10cd038299631ea` |
| 庭 | [LibriVox](https://archive.org/download/multilingual_shorts_005_1212/msw005_06_niwa_dazai_um.mp3) | MP3, 44100 Hz, 1 ch | 613.930 | `c87b8e6e90037db90267bce9f7991bb04db16fb68e9c65197a3f3f0b975eb6e6` |
| 薬指の曲り | [LibriVox](https://archive.org/download/multilingual_shorts_005_1212/msw005_11_kusuriyubino_tanaka_am_64kb.mp3) | MP3, 22050 Hz, 1 ch | 513.386 | `c78e714b8f1fa0cb9efc7e04402e6e266860f298ef3a2ca6fd95248d630d427a` |

ごん狐の全章は各章の原形式を保持して順につないだ 22050 Hz、1 ch、Float32 PCM の評価用 WAV (`/private/tmp/mac-ambient-jev-gongitsune-full.wav`) にした。946.469 秒、SHA-256 は `880136749d821832995901577ca8b54f4ffcff6a372f7c00a9a072577a34c62b`。配信ページの「15分42秒」に対し、実ファイル合計は約15分46秒である。

`AudioFileTimelineBuilder` でこの全章 WAV を取り込んだ際、処理チェックポイントは `sampleRate=22050`、`channelCount=1`、`committedFrames=20869632` だった。これは音源の約946.469秒と一致し、16 kHz への一律変換をしていない。

二人話者の境界評価用 WAV (`/private/tmp/mac-ambient-jev-two-readers-abab.wav`) は「庭」を A、「薬指の曲り」を B とし、各音声の 20–140 秒、140–260 秒を A→B→A→B に並べた。B だけ連結に必要な 44100 Hz へ変換し、1 ch、Float32 PCM、480 秒、SHA-256 は `a31927a8d9e6ef5c01aa6c9df68ea622c4b9bfe3ea5620b5204f23fec23c39dd`。既知の交替境界は 120、240、360 秒。これは別々の朗読を組み合わせた評価音声であり、自然な会話の話者交替を示すものではない。

この連結では交替箇所に無音を**追加していない**が、元音声の切り出し端には無音に近い部分が残っている。20 ms RMS・-40 dBFS を基準にした波形確認では、120秒の直後に約0.42秒、240秒の約0.12～1.12秒に約1.00秒の低音量区間があり、360秒の接続点には同条件で長い低音量区間がない。VAD の設定上の最短無音は0.75秒であるため、120秒と360秒の境界が一つの VAD 区間に入ることは説明できる。一方、240秒の低音量区間は0.75秒を超えるため、ここが分割されなかった理由は VAD の音声確率・区間処理をさらに調べる必要がある。これを単に「無音なしなので想定どおり」とは扱わない。14秒の最大区間長による区切りも話者境界には合わせない。

対照試験では、元の120秒接続点の前後20秒を抜き出し、その間にデジタル無音1.5秒を入れた41.5秒の評価用音声を作った (`/private/tmp/mac-ambient-jev-ab-boundary-with-silence.wav`、44,100 Hz・1 ch、SHA-256 `b9f490344a696770630bf1749de965f2659d472c22f7638e0b87bf234d632645`)。同じファイル経路で処理した結果、VAD 区間は20.223秒で閉じ、次は21.660秒から始まった。この明示的な無音では話者境界を分離できた。元の240秒付近での未分離が波形上の低音量とモデルの無音判定の差に由来する可能性は残る。

## 実測結果

- 『ごん狐』全章: ファイル経路で96区間を完了。空白本文0件、認識失敗の定型文0件。英字を含む3区間は LibriVox の案内文に対応した。話者判定は単一94区間、話者不明2区間。
- A→B→A→B: ファイル経路で43区間を完了。各ブロックの主話者 ID は `S1→S2→S1→S2`。80%基準では単一41区間、複数話者2区間。無音なしの切替点を含む区間で二人の span を確認した。
- 『よだかの星』冒頭30秒: ファイル経路と原速ライブ経路はどちらも44,100 Hz・1 ch、1,323,000フレームで、6区間の時刻・本文・話者 span が一致。非空更新の欠落0件。ライブ遅延は P50 2.928秒、P95 3.986秒。
- 同じ30秒を録音なしで既定マイクの `activeFormat` に合わせると、処理形式は96,000 Hz・1 ch、2,880,000フレーム。ファイル経路との本文・話者 ID は一致し、区間時刻の最大差は1 ms。ライブ遅延は P50 3.420秒、P95 4.817秒。

3秒以内の P95 目標はこの短い音声では未達。これらはモデル初期化後の発話終了から非空更新までを測り、マイク機器からの取得と実画面の描画は含めない。『よだかの星』全体の話者交替時刻は音声を確認していないため、二人話者の正解区間としては未採点。参照文を実際の朗読に合わせて確定していないため、変更前後の文字誤り率比較も未測定。

[青空朗読の掲載ページ](https://aozoraroudoku.jp/voice/rdp/rd001.html)は二人の読み手を記載し、音声の無断転載・公衆送信を禁止している。「よだかの星」を二人話者の正解区間に採用するには、実際の交替箇所を音声で確認し、時刻を記録する。

# Linux 音声検証基盤と 7+OTHER 話者分離 設計仕様

日付: 2026-09-26  
対象: `Pokojaka/mac-ambient-jev`  
作業ブランチ: `work/linux-asr-evaluation`  
関連Issue: #1 #2 #3 #4 #5 #6

## 1. 目的

macOS版 `.app` を本番実装として維持したまま、macOS固有でない処理をLinuxでも実装・検証できる構成へ分離する。

Linux側では次を実行可能にする。

- Portable Swift Coreのunit test
- Qwen3-ASRによる日本語ASR評価
- 日本語参照文とのCER評価
- VOICEVOX等を使った再現可能な合成音声試験
- 実音声による朗読・自然会話・ニュース評価
- NVIDIA Nemotron 3 Diarizationによる話者分離評価
- 8人以上が登場する場合の `Speaker 1〜7 + OTHER` 評価
- GitHub Actionsを使わないローカル回帰試験

Linux環境をユーザー向けアプリとして配布することは目的にしない。

## 2. 設計原則

### 2.1 MacとLinuxは推論実装を共有しない

macOS本番:

- SwiftUI
- AVFoundation
- Security / Keychain
- FluidAudio
- speech-swift
- MLX
- Qwen3-ASR MLX backend

Linux検証:

- Python CLI
- PyTorch / CUDA
- Qwen3-ASR公式Linux backend
- Nemotron 3 Diarization
- ffmpeg等のCLI音声処理

両者で共有するのは推論器ではなく、データモデルと評価意味論である。

### 2.2 モデル間はartifactで接続する

PythonとSwiftをFFIや常駐serverで密結合しない。

各runnerはversion付きJSON artifactを出力し、Portable Coreの評価器が読む。

これによりASR、diarization、評価器を独立に再実行できる。

### 2.3 音声本体を原則commitしない

外部corpusと生成音声はローカルcacheへ保存する。

Gitには次だけを保存する。

- source URL
- license metadata
- SHA-256
- parser version
- crop/span情報
- generation script
- seed
- speaker/style設定
- expected reference

## 3. パッケージ境界

### 3.1 MacAmbientJevCore

Linux/macOS共通のPortable Coreとする。

含める:

- transcript / segment domain types
- event / materialization pure logic
- processing metadata
- session recoveryのportable部分
- corpus manifest
- Japanese text normalization
- CER evaluator
- diarization evaluation schema
- DER / collapsed DER evaluator
- speaker identity schema

Apple frameworkを直接importしない。

### 3.2 MacAmbientJevAppleSupport

Apple APIに依存するadapterを移す。

例:

- KeychainStore
- AudioFileTimelineBuilder
- AVFoundation file conversion
- Apple filesystem/security adapter

### 3.3 MacAmbientJevRuntime

既存Mac runtimeを維持する。

- FluidAudio
- Qwen3-ASR MLX
- live VAD
- live/offline diarization
- NativeSessionProcessor

### 3.4 Linux runners

```text
tools/linux-audio/
├── common/
│   ├── artifact.py
│   ├── corpus.py
│   └── audio.py
├── asr/
│   ├── pyproject.toml
│   └── qwen3_asr.py
└── diarization/
    ├── pyproject.toml
    ├── nemotron3.py
    └── speaker_overflow.py
```

ASRとdiarizationのPython環境は分離する。
NeMoの重い依存をASR smoke testに強制しない。

## 4. 共通speaker identity

アプリと評価器が扱うspeaker identityは次の3種類とする。

```swift
public enum SpeakerIdentity: Codable, Sendable, Equatable {
    case tracked(Int)   // 1...7
    case other
    case unknown
}
```

### 4.1 tracked

- indexは1〜7のみ
- 初回登場順に割り当てる
- 一度割り当てたindexはセッション中維持する

### 4.2 OTHER

Speaker 1〜7のどれにも属さない、8人目以降の人物の集合。

OTHER内部では人物を区別しない。

8人目、9人目、10人目が別人でも、公開schema上はすべてOTHERである。

### 4.3 UNKNOWN

証拠不足で安全に判定できない状態。

例:

- 発話が短すぎる
- overlapが強すぎる
- embedding品質が不足する
- tracked speakerとOTHERの判定差が小さい
- model出力が競合する

UNKNOWNをOTHERとして確定してはいけない。

## 5. Nemotron 3と7+OTHER

### 5.1 Nemotronの利用方法

Nemotron 3は8 speaker streamを持つ。

Linux評価では8streamをそのまま使用するが、公開speaker schemaを8人の固定人物として扱わない。

最初の7人だけをtracked speakerとして確定対象にする。

### 5.2 第8streamをOTHERと直結しない

単純な

```text
Nemotron stream 8 = OTHER
```

という対応は禁止する。

8人を超えた場合に、9人目以降が必ずstream 8へ集約される保証がないためである。

そのためNemotron後段に `SpeakerOverflowResolver` を置く。

## 6. SpeakerOverflowResolver

### 6.1 責務

Nemotronのactivity streamとspeaker embeddingを使って、各発話を次のいずれかへ変換する。

- Speaker 1〜7
- OTHER
- UNKNOWN

### 6.2 初期登録

新規speakerが登場し、tracked slotに空きがある場合:

1. 十分な長さのclean speech spanを取得する
2. speaker embeddingを作る
3. 既存tracked speakerとの重複がないことを確認する
4. 次の番号を初回登場順で割り当てる

例:

```text
first new speaker  -> Speaker 1
second             -> Speaker 2
...
seventh            -> Speaker 7
```

### 6.3 7人登録後

tracked slotが埋まった後は、新規人物へ新しい番号を発行しない。

各発話について:

1. Speaker 1〜7のreference embeddingと照合
2. 十分に一致するtracked speakerがあればそのID
3. どのtracked speakerにも一致せず、判定品質が十分ならOTHER
4. 品質不足または境界的ならUNKNOWN

### 6.4 OTHERのembedding

OTHER自体には単一reference embeddingを作らない。

OTHERは複数人物の集合であり、平均embeddingを作ると新規人物検出の意味が崩れるためである。

必要なら評価・デバッグ専用に内部temporary clusterを持てるが、公開speaker identityへ昇格させない。

### 6.5 speaker embedding backend

Overflow Resolverはembedding実装に依存しないprotocol/adapter境界を持つ。

Linuxで使用する具体的モデルは実装Issueでbenchmarkして選ぶ。

要件:

- 日本語話者でもspeaker verificationに使える
- CUDAでbatch処理できる
- reference embeddingをcacheできる
- model revisionをartifactへ記録できる

## 7. Diarization artifact

例:

```json
{
  "schema_version": 1,
  "engine": {
    "name": "nemotron-3-diarization",
    "revision": "...",
    "profile": "offline-30.4s"
  },
  "speaker_policy": {
    "tracked_limit": 7,
    "overflow": "other"
  },
  "spans": [
    {
      "start_ms": 1000,
      "end_ms": 3800,
      "speaker": {"kind": "tracked", "index": 1},
      "confidence": 0.94
    },
    {
      "start_ms": 4000,
      "end_ms": 5200,
      "speaker": {"kind": "other"},
      "confidence": 0.89
    }
  ]
}
```

UNKNOWNも同じschemaに保持する。

overlap時は異なるspeaker spanが同時間帯に存在してよい。

## 8. ASR artifact

Qwen3-ASR Linux runnerは次を出力する。

```json
{
  "schema_version": 1,
  "engine": {
    "name": "qwen3-asr",
    "revision": "...",
    "backend": "pytorch-cuda"
  },
  "segments": [
    {
      "start_ms": 1000,
      "end_ms": 3800,
      "text": "公開鍵暗号について説明します"
    }
  ],
  "runtime": {
    "audio_seconds": 60.0,
    "inference_seconds": 8.2,
    "rtf": 0.137
  }
}
```

ASRとdiarizationは独立に生成する。

speaker付きtranscriptが必要な場合は後段のmergerで時間区間を統合する。

## 9. 日本語ASR評価

主指標はCERとする。

保存する値:

- raw_cer
- normalized_cer
- substitutions
- deletions
- insertions
- reference_characters
- hypothesis_characters

正規化:

- Unicode NFKC
- 全角/半角の統一
- 改行/空白整理
- 評価用の句読点除外

行わない:

- 漢字からかなへの変換
- LLMによる意味補正
- 同義語変換
- 数字の意味的同一視

自然会話では必要に応じて:

- cer_verbatim
- cer_content

を分離する。

## 10. ASR corpus

### 10.1 VOICEVOX / VOICEVOX Nemo

固定scriptから毎回生成できる決定論的corpus。

内容:

- 一般文
- 講義調
- 会話調
- 数字
- 英字
- URL
- 情報理工系専門語
- 固有名詞
- 長文
- フィラー

生成WAVはcommitしない。

### 10.2 LibriVox + 青空文庫

日本語長文朗読。

冒頭/末尾のLibriVox案内文を除外するため、manifestでaudio/reference spanを固定する。

### 10.3 CSJ公開サンプル

日本語自然会話。

インタビュー・課題指向対話を使い:

- フィラー
- 相槌
- 言い直し
- overlap
- 話者交替

を評価する。

### 10.4 ニュース

再現可能に取得でき、音声と正解原稿の対応が明確な公開サンプルのみ使用する。

RWCP News Speech Corpus等を候補とし、取得条件が満たせないデータは標準suiteへ入れない。

## 11. 7+OTHER diarization corpus

### 11.1 VOICEVOX多話者

必須構成:

- 2 speakers
- 4 speakers
- 7 speakers
- 8 speakers
- 10 speakers

stress:

- 12 speakers
- overlap 0%
- overlap 10%
- overlap 30%
- 短い相槌
- 音量差
- reverb
- background noise

10話者referenceは:

```text
arrival 1 -> Speaker 1
arrival 2 -> Speaker 2
...
arrival 7 -> Speaker 7
arrival 8 -> OTHER
arrival 9 -> OTHER
arrival 10 -> OTHER
```

へcollapseする。

### 11.2 日本語実話者controlled mix

TTS固有の声質に評価が偏らないよう、利用可能な日本語実話者corpusから単一話者clipを取得し、既知timelineで混合する。

候補:

- JVS
- J-SpAW
- Koniwa

採用前にライセンスと自動取得可能性をfixture単位で記録する。

### 11.3 CSJ

日本語2話者の実自然会話として使用する。

7+OTHER overflow性能ではなく:

- real speech DER
- overlap
- boundary
- speaker stability

の評価に使う。

### 11.4 AMI

英語のためoptional sanity checkのみ。

日本語アプリの合否判定には使用しない。

## 12. Diarization評価

### 12.1 Standard metrics

- DER
- False Alarm
- Miss
- Speaker Confusion
- overlap recall
- speaker-switch boundary error
- RTF
- peak VRAM

### 12.2 7+OTHER metrics

通常DERとは別にreferenceとhypothesisを7+OTHER schemaへcollapseして評価する。

- collapsed_der
- tracked_speaker_confusion
- other_precision
- other_recall
- other_to_tracked_leakage
- tracked_to_other_leakage
- unknown_rate
- overflow_detection_recall

### 12.3 leakage

最重要のfailure modeの一つを:

```text
8人目以降の人物が Speaker 1〜7 に誤って混ざる
```

と定義する。

これを `other_to_tracked_leakage` として明示的に集計する。

第8Nemotron streamだけをOTHER扱いして、この誤りを隠してはいけない。

## 13. Mac FluidAudioとの比較

Mac側FluidAudioも共通speaker artifactへexportできるようにする。

ただしMac本番ロジックを7+OTHERへ強制変更することはこの設計の必須条件ではない。

評価時には:

```text
same audio
  ├─ macOS FluidAudio
  └─ Linux Nemotron + Overflow Resolver
          ↓
same evaluator
```

とする。

比較は日本語fixtureを主とする。

## 14. baseline

Mac/Linuxのbackendごとにbaselineを分離する。

```text
baselines/
├── macos/
│   ├── mlx-qwen.json
│   └── fluidaudio-diarization.json
└── linux/
    ├── qwen3-asr.json
    └── nemotron3-7plus-other.json
```

baselineに必須:

- model ID
- model revision
- backend version
- evaluator version
- normalizer version
- corpus hash
- device
- runtime config

初回実測前に恣意的なCER/DER合格閾値を決めない。

## 15. テスト階層

```text
L0 Portable Core
   networkなし
   GPUなし

L1 Evaluators
   CER / DER / collapse / parsers

L2 Synthetic smoke
   VOICEVOX + Qwen
   VOICEVOX multi-speaker + Nemotron

L3 Real-small
   LibriVox
   CSJ
   news sample
   Japanese real-speaker controlled mix

L4 Full regression
   standard corpus全件

L5 Stress
   30–90分
   10/12 speaker
   overlap/noise/reverb
```

GitHub Actionsは前提にしない。

## 16. 実行入口

```bash
./scripts/verify_portable.sh
./scripts/verify_linux_audio.sh --smoke
./scripts/verify_linux_audio.sh --full
```

`--smoke` はNemotron依存が未導入の場合、diarization項目をPASS扱いしてはいけない。

結果は明示的に:

- PASS
- FAIL
- SKIPPED_MISSING_DEPENDENCY

等へ分ける。

full suiteではSKIPを全体PASSへ読み替えない。

## 17. Issue分割

### #1 Portable Core
Apple依存をCoreから分離しLinux compile/testを成立させる。

### #2 ASR evaluator
日本語正規化、CER、reference schemaを実装する。

### #3 Linux Qwen3-ASR
Linux実推論runnerを追加する。

### #4 Corpus
VOICEVOX、朗読、自然会話、ニュースの取得/生成を実装する。

### #5 Nemotron 3
7+OTHER + UNKNOWNを含むdiarization backendと評価を実装する。

### #6 Regression suite
各backendとcorpusを統合しbaselineを管理する。

## 18. 実装順序

依存関係:

```text
#1 Portable Core
      |
      v
#2 Evaluators
      |
   +--+----------------+
   |                   |
   v                   v
#3 Linux ASR       #5 Nemotron
   |                   |
   +---------+---------+
             |
             v
          #4 Corpus
             |
             v
       #6 Regression
```

corpus取得器の一部は並行して作れるが、正式baseline作成はevaluator完成後に行う。

## 19. 失敗時の扱い

### モデルロード失敗

- artifactを成功として生成しない
- error metadataを別ログへ出す
- 他subsystemのテストは継続可能

### corpus取得失敗

- hash不一致をFAIL
- source消失を明示
- 古いcacheを無条件に信用しない

### Overflow Resolver不確実

- UNKNOWN
- OTHERへ楽観的に押し込まない

### 8人超

- tracked speaker IDを8以上へ増やさない
- 8人目以降はreference上OTHER
- hypothesisがtrackedへ混入した場合はleakage errorとして残す

## 20. 非目標

- Linux GUI
- Linux版ユーザーアプリ
- NemotronのMac移植
- Python daemonのMac同梱
- speaker本人認証
- OTHER内部人物の恒久追跡
- 8streamを10streamへ改造すること
- 英語AMIを日本語性能の代表値にすること

## 21. 完了条件

全体設計の完了条件は次。

1. Portable CoreがLinuxでcompile/test可能
2. Mac `.app` の既存build経路が維持される
3. Linux Qwen3-ASRで日本語実音声を文字起こし可能
4. 共通CER evaluatorで参照文照合可能
5. VOICEVOX、朗読、自然会話、ニュースの複数カテゴリを評価可能
6. Nemotronのspeaker activityを共通schemaへ変換可能
7. Speaker 1〜7を初回登場順で維持可能
8. 8人目以降をOTHERとしてreference/evaluation上collapse可能
9. 10話者日本語fixtureでCollapsed DERとleakageを測定可能
10. 不確実発話をUNKNOWNとして保持可能
11. Linux回帰試験がGitHub Actionsなしで再現可能
12. Nemotron/NeMo未導入でもASR系検証が独立して実行可能

# Clean Transcription Core — 設計仕様

日付: 2026-09-22  
リポジトリ: `Pokojaka/mac-ambient-jev`  
状態: 設計レビュー反映済み、書面レビュー待ち

## 1. 目的

macOS 上で、ライブのマイク音声または既存録音から、**構造化され、再処理可能で、AI が利用しやすい文字起こしデータ**を生成する。

v1 は講義ノート生成器ではなく、日常生活向け音声アシスタントでもない。役割は、後段の Hermes、Pi、独自エージェント、LLM、検索処理などが利用できる、信頼できる中間表現を作ることである。

ユーザーは講義中、聞き逃した直前の発言を確認するためにライブ文字起こしを読むことがある。講義終了後の主な利用者は人間ではなく後段の AI である。

本設計では次を基本原則とする。

1. 原音声が最上位の正本である。
2. 文字起こしや分類は、音声から再生成可能な派生データである。
3. 不確実な情報は捨てない。
4. 録音経路は、ASR・Jev・ダイアライゼーション・scene 判定から独立させる。
5. v1 は Swift ネイティブの単一アプリとして実装する。

## 2. v1 の成功条件

v1 は次を満たした時点で成功とする。

1. 60〜90 分の録音を継続し、アプリ異常終了時にも損失区間を限定できる。
2. 既存録音を読み込み、ライブ録音と同一の派生処理経路で処理できる。
3. VAD で発話候補区間を作り、Apple Silicon 上の Qwen3-ASR 1.7B でローカル文字起こしできる。
4. ASR が完了した発話を、Jev や汎用 LLM を待たずにライブ表示できる。
5. ASR の結果を破棄せず、意味上の優先度と音響上の範囲を独立した軸として保持できる。
6. Jev などの意味分類器は、明白な低情報発話だけを保守的に降格する。
7. `LECTURE` / `DISCUSSION` を、一発ごとの判定ではなく履歴を持つ状態機械で推定する。
8. discussion 中は、近傍グループらしい発話と周辺会話らしい発話を区別し、可能な範囲で匿名ダイアライゼーションを行う。
9. ASR、Jev、ダイアライゼーション、scene 判定が失敗しても録音を継続する。
10. VAD、ASR、scene、speaker、scope、意味分類を後から独立して再処理できる。
11. 自動評価を主としつつ、小規模な人手確認用データを校正基準として品質を追跡できる。
12. ユーザー向け UI、状態表示、エラー表示、設定名は日本語を既定とする。

## 3. v1 の範囲外

v1 では次を行わない。

- 講義ノート生成
- 要約、説明、重要点抽出
- クイズ、暗記カード生成
- Web 調査
- 長期履歴を横断した Q&A
- 常時起動の日常生活アシスタント
- 永続的な本人話者認証
- VOICEVOX 等による応答読み上げ
- HTTP 常駐 API
- MCP 常駐サーバー
- Python ASR バックエンド

これらは、必要性が確認された段階で別設計として追加する。

### 3.1 講義後処理は外部ワークフロー

講義後のノート作成や説明生成は、この macOS アプリの責任ではない。

```text
macOS Clean Transcription Core
        |
        +--> 完了した session data
                  |
                  | ユーザーまたは外部ワークフローが開始
                  v
           Hermes / Pi / 独自エージェント
                  |
                  +--> ノート
                  +--> 説明
                  +--> クイズ
                  +--> Web 調査
                  +--> その他成果物
```

v1 は外部エージェントを起動、監視、選択しない。

### 3.2 将来の日常生活アシスタント

将来の日常生活モードでは、低遅延の対話が必要になるため、選択されたライブ transcript event を外部 runtime に渡し、その応答を macOS 側で提示できるようにする。

外部 runtime は Hermes、Pi、独自実装のいずれでもよく、文字起こし core は特定 harness に依存しない。

### 3.3 V2 の外部エージェント連携

V2 の既定は zero-daemon とする。

```text
Canonical Session Store
        |
        +--> 直接の read-only file/schema access
        |
        +--> 小さな CLI / library adapter
        |
        +--> 必要時のみ起動する stdio MCP adapter
```

macOS アプリを起動し続けなくても、講義後の session data を外部エージェントが読めることを要件とする。

HTTP / Streamable HTTP は、同時複数クライアントや live event 配信など、実需が生じた場合のみ追加する。

既定では listen socket を持たない。

## 4. upstream 利用方針

`pasrom/meeting-transcriber` の macOS 基盤を、必要な範囲で再利用する。

再利用候補:

- macOS マイク入力
- マイク権限
- 音声デバイス選択
- session 開始 / 終了
- SwiftUI app shell
- file import
- FluidAudio / VAD
- diarization / speaker embedding
- audio queue 周辺
- 既存テストやアプリ基盤

ただし、upstream との将来同期を最優先の設計制約にはしない。

本プロジェクトの canonical data model、Qwen3-ASR、再処理モデル、ライブ表示要件が upstream と衝突する場合は、本プロジェクト側の責務分離を優先する。

不要な upstream 機能を残すこと自体を目的にしない。同期しやすさより、core の境界が理解しやすくテスト可能であることを優先する。

## 5. 上位アーキテクチャ

canonical な対象は `TranscriptSegment` ではなく、**原音声上の時間座標と、それに対して追加される派生イベント群**である。

```text
                    AudioSource
                        |
                        v
                  Capture Engine
                  |            |
                  |            +----> live audio bus
                  v
             Durable Audio Writer
                        |
                  source timeline
                        |
          +-------------+------------------+
          |                                |
          v                                v
     VAD Segmenter                  Diarization Engine
          |                                |
   segmentation events               speaker timeline
          |
          v
       ASR Actor
          |
       ASR events
          |
    +-----+-----------+----------------+
    |                 |                |
    v                 v                v
Semantic          Scene Analyzer   Proximity Evidence
Classifier              |                |
    |                    |                |
    +--------------------+----------------+
                         |
                     Event Store
                         |
                    Materializer
                  +------+------+
                  |             |
                  v             v
              SwiftUI       外部エージェント
```

録音・永続化は最優先経路であり、ASR や enrichment の遅延に依存しない。

## 6. 時間座標と正本

### 6.1 正本

正本は source audio とする。

すべての派生処理は、最終的に source audio 上の範囲へ戻れる必要がある。

### 6.2 時間座標

内部では、可能な限りミリ秒だけでなく sample index を持つ。

概念上:

```text
source_start_sample
source_end_sample
sample_rate
```

を永続的な基準座標とする。

表示や外部 API では必要に応じて `start_ms` / `end_ms` を派生する。

### 6.3 segment は派生物

segment は永久固定の実体ではない。

VAD 設定を変えれば境界が変化し得るため、segment は特定の `segmentation_run_id` に属する。

```text
source audio
   |
   +--> segmentation_run_A
   |       +--> seg_A1
   |       +--> seg_A2
   |
   +--> segmentation_run_B
           +--> seg_B1
           +--> seg_B2
```

この構造により、再 VAD 後も旧結果と新結果を混同しない。

## 7. AudioSource

### 7.1 ライブ録音

ユーザーが明示的に session を開始・終了する。

開始時:

1. session を作成する。
2. Durable Audio Writer を先に開始する。
3. live audio bus へ音声を供給する。
4. VAD を開始する。
5. ASR model の読み込みを非同期に開始する。

録音コールバックは ASR、ネットワーク、JSON 書き込み、SwiftUI 更新を待ってはならない。

### 7.2 既存録音

既存ファイルも通常の session として扱う。

`source.type = imported_file`

元ファイルは変更しない。

既定では session 管理下へ不変コピーを作成し、後日元ファイルが移動・削除されても再処理できるようにする。

ライブと import で別の ASR 実装や別の transcript schema を持たない。

## 8. Durable Audio Writer

### 8.1 責務

Durable Audio Writer は、最優先で source audio を永続化する。

次を満たす。

- 音声入力スレッドを長時間ブロックしない。
- downstream の処理速度に依存しない。
- 異常終了時の損失範囲を限定する。
- session manifest から最後に永続化済みの位置を判定できる。
- 後から VAD / ASR を再実行できる。

### 8.2 保存方式

単一連続ファイルか短い durable chunk 群かは実装検証で選ぶ。

ただし方式にかかわらず、v1 の受け入れ条件として以下を要求する。

- process kill 後に既存の長時間録音全体が破損しない。
- 最後の未確定区間を除き復旧可能である。
- session manifest が保存済み範囲を追跡できる。
- audio persistence の失敗を UI 上で即座に日本語で通知できる。

## 9. VAD と segmentation

VAD の責務は、安全な発話候補境界を作ることだけである。

意味の有無は判断しない。

挙動:

- speech 開始前の短い pre-roll を保持する。
- speech 中の短い pause を許容する。
- 継続 silence で segment を閉じる。
- 短い発話だけを理由に破棄しない。
- 長すぎる発話は適切な pause 付近で分割する。
- overlap の可能性を隠さない。
- exact timing は calibration parameter とする。

出力には最低限以下を含める。

```text
segmentation_run_id
segment_id
source_start_sample
source_end_sample
vad_version
vad_config_hash
```

## 10. ASR アーキテクチャ

### 10.1 Swift ネイティブ一本化

v1 は最初から Swift ネイティブで実装する。

```text
ASREngine
  └── NativeQwen3ASREngine
          Swift + MLX Swift
          Qwen3-ASR 1.7B
```

`ASREngine` protocol は将来置換可能性のために置くが、v1 で複数 backend を実装しない。

Python worker、IPC protocol、埋め込み Python、ASR server は作らない。

### 10.2 Qwen3-ASR

既存の Swift + MLX Swift 実装を優先して利用する。

手動 port から始めない。

ASR は macOS アプリと同じ process 内で動かす。

### 10.3 依存バージョン

外部 Swift package は shipping 時に branch head へ追従しない。

可能なら release tag、なければ特定 commit SHA へ固定する。

依存更新は明示的に行い、ASR regression test を通す。

### 10.4 ライブ動作

Qwen3-ASR は utterance 単位で処理する。

1. VAD segment が確定する。
2. ASR queue に segment reference を入れる。
3. ASR Actor が原音声の該当区間を読む。
4. ASR 完了 event を書く。
5. UI は ASR 完了直後に表示する。
6. scene、speaker、scope、意味分類は後から更新される。

### 10.5 ASR lifecycle

UI 起動時には model を読み込まない。

```text
app 起動
   |
録音開始
   |
Qwen3-ASR を非同期 load
   |
録音は継続
   |
segment reference が queue に蓄積
   |
ASR READY
   |
queue を順次処理
```

状態例:

- `STOPPED`
- `LOADING_MODEL`
- `READY`
- `TRANSCRIBING`
- `FAILED`

segment 単位:

- `PENDING`
- `OK`
- `EMPTY`
- `FAILED`
- `TIMEOUT`
- `ENGINE_UNAVAILABLE`

ASR failure は capture を停止させない。

### 10.6 memory policy

- app 起動だけでは model を load しない。
- ASR が必要なときだけ load する。
- active session 中は 1 instance を保持する。
- session 終了後は必要に応じて unload できる。
- v1 で複数 model instance を持たない。

測定対象:

- model load time
- resident memory
- unloaded idle memory
- 60〜90 分連続動作
- progressive memory growth
- thermal behavior

## 11. キュー、逆圧、並行実行

### 11.1 原則

PCM を無制限に RAM queue へ蓄積しない。

downstream が遅れても、source audio が durable なら後から読み直せる。

### 11.2 ASR queue

queue に置くのは原則として音声本体ではなく参照情報とする。

```text
segment_id
segmentation_run_id
source_start_sample
source_end_sample
```

### 11.3 bounded queue

capture 以外の in-memory queue は bounded とする。

queue が上限へ近づいた場合:

- source audio 保存は継続する。
- 未処理 job を durable state として残す。
- UI へ「文字起こし処理が遅れています」など日本語で通知する。
- capture を止めない。

### 11.4 Swift concurrency の境界

最低限、次の責務を分離する。

- `AudioCaptureEngine`
- `SessionWriter`
- `SegmentationEngine`
- `ASREngine` actor
- `DiarizationEngine`
- `EnrichmentCoordinator`
- `TranscriptMaterializer`

1 つの巨大 manager に集約しない。

## 12. canonical event store

### 12.1 基本形式

canonical store は append-only event log とする。

主ファイル:

`transcript.jsonl`

ただし「1 行 = 完成した segment」ではなく、「1 行 = 1 event」と定義する。

### 12.2 event envelope

概念例:

```json
{
  "event_id": "evt_...",
  "event_type": "asr.completed",
  "schema_version": 1,
  "session_id": "session_20260922_01",
  "processing_run_id": "run_...",
  "segmentation_run_id": "seg_run_...",
  "segment_id": "seg_000042",
  "source_start_sample": 3185600,
  "source_end_sample": 3231520,
  "created_at": "2026-09-22T03:20:00+09:00",
  "payload": {
    "text": "あれ、画面出ないな。ちょっと待ってください",
    "engine": "qwen3-asr",
    "model": "1.7b"
  }
}
```

event type の例:

- `segment.created`
- `asr.pending`
- `asr.completed`
- `asr.failed`
- `speaker.span`
- `scene.changed`
- `scope.assigned`
- `content_priority.assigned`
- `processing.invalidated`

### 12.3 MaterializedTranscriptSegment

人間 UI や外部エージェントは、原則として event log を直接解釈しない。

`TranscriptMaterializer` が最新状態を組み立てる。

概念例:

```json
{
  "segment_id": "seg_000042",
  "start_ms": 199100,
  "end_ms": 201970,
  "text": "あれ、画面出ないな。ちょっと待ってください",
  "scene": "lecture",
  "speakers": [
    {
      "id": "speaker_2",
      "start_ms": 199100,
      "end_ms": 200500,
      "confidence": 0.81
    },
    {
      "id": "speaker_3",
      "start_ms": 200500,
      "end_ms": 201970,
      "confidence": 0.74
    }
  ],
  "scope": "near",
  "content_priority": "low_priority"
}
```

speaker は segment に 1 個だけとは限らない。

### 12.4 derived views

必要なら次の view を生成する。

- `views/primary.jsonl`
- `views/low_priority.jsonl`
- `views/background.jsonl`

これらは cache / derived artifact であり正本ではない。

## 13. 意味分類

### 13.1 抽象化

アーキテクチャを Jev 固有にしない。

```text
ContentPriorityClassifier
        |
        v
DecisionProvider
        |
        +--> JevDecisionProvider
```

scene の semantic transition detector も同じ `DecisionProvider` を利用できる。

これにより、将来別 API やローカル分類器へ交換できる。

### 13.2 ContentPriority

意味上の優先度:

- `PRIMARY`
- `LOW_PRIORITY`

`LOW_PRIORITY` 候補:

- 単独 filler
- 内容のない相槌
- 機材・画面操作の明白な手間取り
- 待機中の無内容発話
- 明白な独り言ノイズ

混合発話は保持する。

例:

「えー、RSA では公開鍵を使います」

は `PRIMARY`。

### 13.3 分類入力

原則として current utterance のみを使う。

全講義を毎回送らない。

曖昧なら `PRIMARY` のままにする。

### 13.4 cache

最低限以下を fingerprint に含める。

- normalized text
- question/schema version
- provider/model version
- policy version

### 13.5 failure

Jev 等の provider が失敗した場合は `PRIMARY` 相当として扱う。

分類失敗で transcript を隠さない。

## 14. scene 判定

scene state:

- `LECTURE`
- `DISCUSSION`
- `UNKNOWN`

候補状態を持つ。

```text
LECTURE
   |
   v
DISCUSSION_CANDIDATE
   |
   v
DISCUSSION
   |
   v
LECTURE_CANDIDATE
   |
   v
LECTURE
```

### 14.1 acoustic evidence

rolling window で次を観測できる。

- active speaker count
- turn rate
- overlap ratio
- dominant speaker ratio
- voiced duration
- proximity evidence

ここで使う `proximity evidence` は、生の音響特徴であり `BACKGROUND` 判定そのものではない。

### 14.2 semantic transition

別の狭い semantic classifier で次を推定する。

- `discussion_start`
- `discussion_end`
- `none`

例:

- 「では隣の人と話し合ってください」
- 「5分間グループで考えてください」
- 「はい、そこまでです」
- 「それでは解説します」

### 14.3 LECTURE → DISCUSSION

強い経路:

1. semantic start cue
2. `DISCUSSION_CANDIDATE`
3. multi-speaker activity / turn-taking の増加確認
4. `DISCUSSION`

弱い経路:

semantic cue がなくても、十分長い acoustic evidence が続けば candidate に入れる。

短い質疑だけで `DISCUSSION` にしない。

### 14.4 DISCUSSION → LECTURE

終了判定は開始判定より厳しくする。

1. semantic end cue
2. `LECTURE_CANDIDATE`
3. multi-speaker activity の低下確認
4. dominant speaker の復帰確認
5. `LECTURE`

### 14.5 retroactive timestamp

scene 確定時刻と実際の転換時刻は一致しない。

確定後に recent window 内の最も妥当な時点へ遡って `scene.changed` event を書けるようにする。

## 15. proximity evidence と acoustic scope

循環依存を避けるため、生の proximity evidence と、意味上の scope assignment を分離する。

### 15.1 proximity evidence

proximity evidence は scene に関係なく計算してよい。

これは、

- 音量
- direct/reverberant 傾向
- speaker embedding の安定性
- microphone relative evidence
- その他利用可能な音響特徴

から得る内部証拠であり、それ自体は `BACKGROUND` を意味しない。

### 15.2 scope assignment

scope:

- `NEAR`
- `BACKGROUND`
- `UNKNOWN`

`BACKGROUND` として除外候補にする policy は `DISCUSSION` 中だけ有効にする。

`LECTURE` 中は、遠く聞こえる話者でも講師の可能性があるため、距離を理由に `BACKGROUND` にしない。

不確実なら `NEAR` または `UNKNOWN` として保持する。

## 16. diarization

diarization は VAD segment と同じ境界で動く必要はない。

speaker timeline は独立した time span として保持する。

例:

```text
VAD:
12.0 ---------------------------- 18.0

speaker:
12.0 ------ A ------ 14.7
                      14.7 ------ B ------ 18.0
```

anonymous session-local ID を使う。

- `SPEAKER_1`
- `SPEAKER_2`

overlap や不確実性がある場合は、無理に 1 speaker に決めない。

長期的な人物名付け、本人識別は v1 の範囲外。

## 17. ライブ文字起こし UI

ライブ中は transcript を主要 UI とする。

### 17.1 遅延原則

ASR 完了直後に表示する。

待たないもの:

- Jev
- scene 判定
- diarization
- scope assignment
- 汎用 LLM
- 講義ノート生成

### 17.2 表示

表示上の日本語例:

- `PRIMARY` → 通常表示
- `LOW_PRIORITY` → 薄く表示
- `BACKGROUND` → discussion 中は既定で非表示
- 処理待ち → 通常表示のまま
- ASR 遅延 → 「文字起こし処理が遅れています」
- ASR 読み込み中 → 「音声認識モデルを読み込んでいます」
- 録音保存失敗 → 「録音データを保存できません。空き容量を確認してください」

ユーザーが上へスクロールした場合は自動追従を止める。

「最新へ戻る」を用意する。

timestamp と anonymous speaker ID は利用可能なら表示する。

v1 では録音再生 UI は必須ではない。

### 17.3 言語方針

ユーザー向けテキストは日本語を既定とする。

内部 identifier、schema key、event type、enum 値は英語でよい。

例:

```text
内部: ENGINE_UNAVAILABLE
表示: 音声認識エンジンを利用できません
```

developer log は英語でもよいが、ユーザーへそのまま露出しない。

## 18. アプリ実行モデル

v1 は通常の macOS `.app` とする。

```text
Mac idle
  -> 常駐 runtime なし

講義前
  -> mac-ambient-jev.app 起動

講義中
  -> 録音 + ローカル処理

講義後
  -> session 停止
  -> pending 処理を必要に応じて完了
  -> app 終了可能
```

Docker、常駐 HTTP service、system daemon、別 Terminal process は不要。

### 18.1 app process

Swift / SwiftUI アプリが次を所有する。

- microphone capture
- durable audio persistence
- VAD
- Qwen3-ASR lifecycle
- transcript UI
- session persistence
- scene analyzer
- diarization
- proximity / scope
- semantic decision provider client

Qwen3-ASR は同一 process 内で MLX Swift により実行する。

## 19. ローカルデータ配置

概念上:

```text
~/Library/Application Support/mac-ambient-jev/
  ├── sessions/
  ├── models/
  └── config/
```

再生成可能 cache は `~/Library/Caches/` を利用できる。

session:

```text
sessions/
└── <session-id>/
    ├── session.json
    ├── processing_metadata.json
    ├── audio/
    │   ├── source.<ext>
    │   └── または durable chunks
    ├── transcript.jsonl
    ├── views/
    └── logs/
```

API key 等の secret は JSON 設定ファイルに平文保存せず、macOS Keychain を使う。

## 20. model download

ASR weight は app bundle に含めない。

未取得時:

1. 日本語で model download が必要であることを表示する。
2. managed model directory へ download する。
3. 一時領域へ download 後、整合性確認してから本配置へ移す。
4. 必須ファイル確認後に engine を `READY` とする。

中断 download が既存 session を壊してはならない。

## 21. session lifecycle

session state は少なくとも次を区別する。

- recording
- capture_stopped
- processing_pending
- complete
- complete_with_pending_work
- failed_capture

segment / task は独立状態を持つ。

停止時は新規 capture を止めるが、pending ASR / enrichment は続行可能とする。

## 22. crash recovery と冪等性

再起動時:

1. 未完了 session を検出する。
2. source audio の durable range を確認する。
3. processing event を materialize する。
4. 未完了 task のみ再開する。
5. 完了済み event を重複生成しない。

「local worker を再起動する」という表現は使わない。v1 は Python worker を持たない。

再開単位は processing engine / task とする。

冪等性 key は単純な `session_id + segment_id` だけに依存しない。

必要に応じて以下を含める。

- session_id
- segmentation_run_id
- segment_id
- processing_run_id
- stage
- version

## 23. processing version と再処理

記録するもの:

- source audio format/version
- VAD version/config hash
- segmentation_run_id
- ASR engine/model/version
- diarization version
- scene analyzer version
- decision schema/provider version
- policy version
- materializer schema version

例:

- threshold 変更 → 既存 provider score を再利用
- scene algorithm 変更 → audio / ASR を再利用
- semantic schema 変更 → ASR を再利用
- ASR model 変更 → source audio を再利用
- VAD 設定変更 → 新しい segmentation_run を生成

旧結果を破壊的に上書きしない。

## 24. エラー処理優先順位

優先順位:

1. source audio を保存する。
2. source timeline と durable range を保存する。
3. segmentation を保存する。
4. ASR text を保存する。
5. speaker / scene / scope を追加する。
6. content priority を追加する。

段階 N の失敗で、N-1 以前の成果を失わない。

disk space は capture を直接脅かすため、早期監視する。

残容量が危険な場合は日本語で明示する。

## 25. 評価戦略

主評価は自動化するが、完全自動だけにはしない。

### 25.1 自動評価

```text
recorded session
      |
      v
Clean Transcription Core
      |
      +-------------------+
      |                   |
   default view       fuller context
      |                   |
      +---------+---------+
                |
           AI evaluator
                |
        retention report
```

比較対象:

- non-background + PRIMARY
- LOW_PRIORITY を含む view
- BACKGROUND を含む fuller context

確認するもの:

- 情報落ち
- false LOW_PRIORITY
- false BACKGROUND
- scene transition 異常
- VAD 異常
- technical term loss

### 25.2 小規模 gold set

全講義の人手 transcript は不要。

代わりに、実際の講義録音から小規模な固定評価集合を作る。

目安:

- 15〜30 分程度
- scene transition を含む
- discussion を含む
- technical term を含む
- filler / low-priority 候補を含む

人手確認する対象:

- 重要専門用語
- 明白な ASR 誤り
- scene 境界
- false LOW_PRIORITY
- false BACKGROUND
- speaker 取り違えの代表例

この gold set は calibration anchor と regression test に使う。

### 25.3 性能指標

最低限:

- ASR real-time factor
- ASR queue depth
- oldest pending age
- model load time
- memory usage
- long-session memory growth
- thermal stability
- capture dropout
- crash recovery loss window
- scene oscillation count
- false LOW_PRIORITY rate
- false BACKGROUND rate
- technical-term retention

## 26. performance model

ASR が継続入力より速いことを期待するが、設計はそれに依存しすぎない。

ASR が一時的に追いつかなくても、

```text
source audio -> 保存継続
ASR queue   -> 遅延可
UI          -> 遅延状態を表示
```

とする。

M4 16GB 実機で Qwen3-ASR 1.7B が不足する場合のみ、量子化変更、小型モデル、スケジューリング変更を検討する。

v1 では先回りして複数 ASR backend を作らない。

## 27. privacy

raw audio はローカルに保持する。

Qwen3-ASR はローカルで動く。

外部 decision provider を使う場合、送信するのは原則として transcript text と必要最小限の文脈だけである。

ユーザーには、意味分類を有効にした場合に文字起こしテキストが外部 provider へ送信されることを明示する。

raw audio を外部へ送信しない。

API key は Keychain 管理とする。

V2 の外部 agent API でも、raw audio は既定で公開しない。

## 28. 外部連携の安定境界

v1 が安定させるべき契約:

- session schema
- source timeline
- event envelope
- processing version
- segmentation run identity
- materialized transcript view

V2 の CLI / stdio MCP はこの contract を読むだけにする。

外部 agent に canonical event store の自由書き換え権限を与えない。

## 29. 将来拡張

後から追加できるもの:

- daily-life capture
- persistent SELF verification
- live transcript event routing
- external daily-agent response
- VOICEVOX / TTS
- historical retrieval
- post-session research
- optional HTTP transport

これらの追加で、capture、durable audio、event store、ASR の再設計を要求しないことを目標とする。

## 30. 設計原則

1. **音声が正本。**
2. **時間軸が共通座標。**
3. **segment は派生物であり、VAD 再実行で変わり得る。**
4. **canonical store は append-only event log。**
5. **UI や外部 agent は materialized view を使う。**
6. **録音経路は enrichment から独立。**
7. **RAM queue に音声を無制限蓄積しない。**
8. **不確実なら保持する。**
9. **意味上の優先度と音響上の範囲を混同しない。**
10. **proximity evidence と BACKGROUND policy を分離する。**
11. **ライブ表示は ASR 完了を待つだけで、Jev 等を待たない。**
12. **v1 は Swift ネイティブの単一 runtime。**
13. **Python backend は具体的必要性が出るまで作らない。**
14. **外部 decision provider は交換可能な境界の内側へ閉じ込める。**
15. **ユーザー向けテキストは日本語を既定とする。**
16. **評価は自動中心だが、小規模 gold set を校正基準にする。**
17. **YAGNI: 講義後の成果物生成と日常アシスタントは別フェーズ。**

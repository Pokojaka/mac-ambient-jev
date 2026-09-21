# Clean Transcription Core 設計仕様

日付：2026-09-22  
リポジトリ：`Pokojaka/mac-ambient-jev`  
状態：再レビュー反映済み、書面レビュー待ち

## 1. 目的

このアプリは、macOS 上でライブのマイク音声または既存録音から、構造化された文字起こしデータを生成する。

講義中は、聞き逃した直前の発言を確認するためにライブ文字起こしを表示する。
講義終了後は、人間が読む完成原稿ではなく、Hermes、Pi、独自エージェントなどが利用する中間データを残す。

ここでいう**正本**は原音声である。
文字起こし、話者情報、場面判定、意味分類は、原音声から再生成できる派生データとして扱う。

v1 は講義ノート生成器ではなく、日常生活向け音声アシスタントでもない。
汎用 LLM も v1 のアプリには組み込まない。

## 2. v1 の成功条件

v1 は次の条件を満たす。

1. 60〜90 分の録音を継続し、アプリが異常終了しても失われる音声区間を限定できる。
2. 既存録音を読み込み、ライブ録音と同じ派生処理経路で処理できる。
3. VAD で発話候補区間を作り、Apple Silicon 上の Qwen3-ASR 1.7B でローカル文字起こしできる。
4. ASR が完了した発話を、Jev の完了を待たずにライブ表示できる。
5. ASR の結果を破棄せず、意味上の優先度と音響上の範囲を独立した情報として保持できる。
6. Jev は明白な低情報発話だけを保守的に降格する。
7. `LECTURE` と `DISCUSSION` を、各発話だけで決めず、履歴を持つ状態機械で推定する。
8. discussion 中は、近傍グループらしい発話と周辺会話らしい発話を区別し、可能な範囲で匿名ダイアライゼーションを行う。
9. ASR、Jev、ダイアライゼーション、場面判定のいずれかが失敗しても録音を継続する。
10. VAD、ASR、場面判定、話者情報、音響範囲、意味分類を後から独立して再処理できる。
11. 自動評価を主としつつ、小規模な人手確認用データを校正基準として品質を追跡できる。
12. ユーザー向けの画面文言、状態表示、エラー表示、設定名は日本語を既定とする。
13. Jev を除く v1 の音声処理はローカルで完結する。

## 3. v1 の範囲外

v1 では次の機能を実装しない。

- 講義ノート生成
- 要約、説明、重要点抽出
- クイズ、暗記カード生成
- Web 調査
- 長期履歴を横断した Q&A
- 汎用 LLM の組み込み
- 常時起動の日常生活アシスタント
- 永続的な本人話者認証
- VOICEVOX などによる応答読み上げ
- HTTP 常駐 API
- MCP 常駐サーバー
- Python ASR バックエンド
- Jev 以外のクラウド推論サービス

必要性が確認された機能は、v1 の実装に混ぜず、別の設計として追加する。

### 3.1 講義後処理

講義後のノート作成や説明生成は、この macOS アプリの責任に含めない。

```text
macOS Clean Transcription Core
        |
        +--> 完了したセッションデータ
                  |
                  | ユーザーまたは外部ワークフローが開始
                  v
           Hermes / Pi / 独自エージェント
                  |
                  +--> ノート
                  +--> 説明
                  +--> クイズ
                  +--> Web 調査
                  +--> その他の成果物
```

v1 は外部エージェントを起動せず、監視せず、どの実行環境を使うかも選ばない。

### 3.2 日常生活アシスタント

日常生活向けの常時対話機能は v1 に含めない。

将来追加する場合も、文字起こし基盤は Hermes、Pi、独自実装のいずれかに固定しない。

### 3.3 V2 の外部エージェント連携

V2 でも、常駐デーモンを既定にはしない。

```text
Canonical Session Store
        |
        +--> 直接の読み取り専用ファイルアクセス
        |
        +--> 小さな CLI またはライブラリアダプター
        |
        +--> 必要時だけ起動する stdio MCP アダプター
```

講義後のセッションデータは、macOS アプリを起動し続けなくても外部エージェントから読めるようにする。

HTTP または Streamable HTTP は、同時に複数のクライアントから読む必要や、ライブイベント配信の必要が生じた場合だけ追加する。
既定では待ち受けソケットを持たない。

## 4. 上流プロジェクトの利用方針

`pasrom/meeting-transcriber` が持つ macOS 向けの基盤は、責務が合う範囲で再利用する。

再利用候補は次のとおりである。

- macOS のマイク入力
- マイク権限
- 音声デバイス選択
- セッションの開始と終了
- SwiftUI のアプリ基盤
- 音声ファイルの読み込み
- FluidAudio と VAD
- ダイアライゼーションと話者埋め込み
- 音声キュー周辺
- 既存のテスト基盤

上流との同期しやすさを最優先の設計制約にはしない。

本プロジェクトの正本データ、Qwen3-ASR、再処理方式、ライブ表示要件が上流の構造と衝突する場合は、本プロジェクト側の責務分離を優先する。

## 5. 上位アーキテクチャ

処理全体の共通座標は、**正規化済み処理タイムライン**上の frame index とする。

元の録音ファイルは保存対象として不変のまま保持する。
VAD、ASR、ダイアライゼーション、場面判定、近接度判定は、同じ処理タイムラインを参照する。

```text
                Immutable Audio Asset
                         |
                         v
             Canonical Processing Timeline
                         |
          +--------------+------------------+
          |              |                  |
          v              v                  v
     VAD Segmenter  Diarization Engine  Acoustic Evidence
          |              |                  |
          v              |                  |
       ASR Actor         |                  |
          |              |                  |
          +---------> Local Scene State <---+
          |
          v
   Jev Decision Provider
          |
          v
       Event Store
          |
       Active Runs
          |
      Materializer
       /       \
      v         v
 Japanese UI  外部エージェント
```

録音と音声保存は、ASR、Jev、場面判定、話者分離から独立させる。
後段が遅れても、録音処理が待たされる構造にはしない。

## 6. 原音声と処理タイムライン

### 6.1 原音声

ライブ録音では、マイクから得た原音声を保存する。

既存録音を読み込む場合は、元ファイルを変更せず、不変コピーをセッション管理下に置く。

原音声は最上位の保存対象であり、後段の処理失敗によって失ってはならない。

### 6.2 正規化済み処理タイムライン

派生処理が共有する共通座標として、デコード済み PCM から得た**正規化済み処理タイムライン**を定義する。

タイムラインには少なくとも次を固定する。

- sample rate
- channel layout
- sample format
- frame index の起点
- 原音声からの変換 version

時間座標には `frame_index` を使う。

```text
source_start_frame
source_end_frame
sample_rate
```

表示用の `start_ms` と `end_ms` は、この情報から求める。

ASR 内部で追加の 16 kHz 変換などを行っても、その内部 sample index を canonical な座標にはしない。

### 6.3 発話区間

**発話区間**は、VAD が特定の設定で切り出した派生物である。

VAD の設定を変えると境界も変わるため、各発話区間を `segmentation_run_id` に所属させる。

```text
processing timeline
   |
   +--> segmentation_run_A
   |       +--> seg_A1
   |       +--> seg_A2
   |
   +--> segmentation_run_B
           +--> seg_B1
           +--> seg_B2
```

VAD を再実行しても、旧結果と新結果を同じ発話区間として扱わない。

## 7. 音声入力

### 7.1 ライブ録音

ユーザーが明示的にセッションを開始し、終了する。

開始時は次の順で処理する。

1. セッションを作成する。
2. `DurableAudioWriter` を開始する。
3. ライブ音声を音声バスへ供給する。
4. VAD を開始する。
5. ASR モデルの読み込みを非同期に開始する。

録音コールバックから ASR、ネットワーク通信、JSON 書き込み、SwiftUI 更新を待たない。

### 7.2 既存録音

既存ファイルも通常のセッションとして扱う。

`source.type = imported_file`

元ファイルは変更しない。
既定ではセッション管理下へ不変コピーを作る。

ライブ録音と既存録音で、別の ASR 実装や別の文字起こし形式を持たない。

## 8. 原音声の永続化

### 8.1 責務

**Durable Audio Writer** は、入力された原音声を最優先で永続化する構成要素である。

次の条件を満たす。

- 音声入力スレッドを長時間ブロックしない。
- 後段の処理速度に依存しない。
- 異常終了時の損失範囲を限定する。
- セッション管理情報から、最後に永続化された位置を判定できる。
- 保存済み音声から処理タイムラインを再生成できる。

### 8.2 保存方式

単一の連続ファイルを使うか、短い区間ごとのファイルを使うかは実装検証で決める。

どちらを選んでも、v1 は次の条件を満たす。

- プロセスを強制終了しても、それ以前の長時間録音全体が破損しない。
- 最後の未確定区間を除いて復旧できる。
- セッション管理情報から保存済み範囲を確認できる。
- 音声保存に失敗した場合は、ユーザーへ日本語で直ちに通知できる。

## 9. VAD と発話区間

VAD は、音響上の発話候補境界だけを決める。
発話に意味があるかどうかは判断しない。

挙動は次のとおりとする。

- 発話開始前の短い pre-roll を保持する。
- 発話中の短い pause を許容する。
- 一定時間の silence が続いたら発話区間を閉じる。
- 短い発話であることだけを理由に破棄しない。
- 長すぎる発話は、適切な pause があればその付近で分割する。
- 話者が重なっている可能性を隠さない。
- 閾値や時間長は校正可能な設定値として扱う。

出力には最低限、次を含める。

```text
segmentation_run_id
segment_id
source_start_frame
source_end_frame
vad_version
vad_config_hash
```

## 10. ASR

### 10.1 Swift ネイティブ実装

v1 の ASR は Swift ネイティブで実装する。

```text
ASREngine
  └── NativeQwen3ASREngine
          Swift + MLX Swift
          Qwen3-ASR 1.7B
```

`ASREngine` protocol は、将来 ASR 実装を置き換えられるように境界を作るために置く。
v1 で複数のバックエンドを実装するための抽象化ではない。

Python worker、IPC protocol、埋め込み Python、ASR server は v1 では作らない。

### 10.2 Qwen3-ASR

既存の Swift と MLX Swift による実装を優先して利用する。
Python 実装からの手動移植から始めない。

ASR は macOS アプリと同じプロセス内で動かす。

### 10.3 依存バージョン

外部 Swift package を、配布版で branch head に追従させない。

release tag があればそれを使い、なければ特定の commit SHA へ固定する。
依存を更新したときは ASR の回帰試験を実行する。

### 10.4 ライブ処理

Qwen3-ASR は発話区間単位で処理する。

1. VAD が発話区間を確定する。
2. ASR キューに音声範囲への参照を入れる。
3. ASR Actor が処理タイムラインの該当範囲を読む。
4. ASR 完了イベントを書き込む。
5. UI は ASR 完了直後に文字列を表示する。
6. 場面、話者、音響範囲、意味分類は後から付与する。

### 10.5 モデルの状態

UI 起動時にはモデルを読み込まない。

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

エンジンは少なくとも次の内部状態を持つ。

- `STOPPED`
- `LOADING_MODEL`
- `READY`
- `TRANSCRIBING`
- `FAILED`

発話区間ごとの処理状態は少なくとも次を区別する。

- `PENDING`
- `OK`
- `EMPTY`
- `FAILED`
- `TIMEOUT`
- `ENGINE_UNAVAILABLE`

ASR が失敗しても録音処理は止めない。

## 11. キューと並行実行

### 11.1 逆圧

後段の処理が遅れたときに、PCM を無制限に RAM へ積み続けない。

原音声と処理タイムラインを再構成できるため、ASR キューには原則として音声本体ではなく次の参照情報を置く。

```text
segment_id
segmentation_run_id
source_start_frame
source_end_frame
```

### 11.2 キューの上限

録音以外のメモリ上キューには上限を設ける。

キューが上限へ近づいても原音声の保存は継続する。
未処理作業はイベントログと active run 情報から再構成できるようにする。

ユーザーには「文字起こし処理が遅れています」などの日本語表示を出す。

### 11.3 Swift concurrency の境界

少なくとも次の責務を分離する。

- `AudioCaptureEngine`
- `SessionWriter`
- `SegmentationEngine`
- `ASREngine` actor
- `DiarizationEngine`
- `SceneAnalyzer`
- `JevDecisionProvider`
- `EnrichmentCoordinator`
- `TranscriptMaterializer`

一つの巨大な manager に集約しない。
各構成要素は、自分が扱う状態と入出力を限定する。

## 12. 正本イベントログ

### 12.1 基本形式

派生処理の正本は、**追記専用イベントログ**として保存する。

主ファイルは `events.jsonl` とする。

このファイルでは「1 行が完成した一発話」を意味せず、「1 行が一つのイベント」を意味する。

### 12.2 イベントの共通形式

概念例を示す。

```json
{
  "event_seq": 1842,
  "event_id": "evt_...",
  "event_type": "asr.completed",
  "schema_version": 1,
  "session_id": "session_20260922_01",
  "processing_run_id": "asr_run_07",
  "segmentation_run_id": "seg_run_03",
  "segment_id": "seg_000042",
  "source_start_frame": 3185600,
  "source_end_frame": 3231520,
  "created_at": "2026-09-22T03:20:00+09:00",
  "payload": {
    "text": "あれ、画面出ないな。ちょっと待ってください",
    "engine": "qwen3-asr",
    "model": "1.7b"
  }
}
```

`event_seq` はセッション内で単調増加させる。
Materializer は `created_at` ではなく `event_seq` を順序の基準にする。

### 12.3 書き込み規則

`SessionWriter` をイベントログの唯一の writer とする。

イベントは 1 行単位で追加する。
起動時に末尾へ不完全な JSON 行があれば、その行だけを無視または切り詰める。

途中の正常なイベントまで破棄しない。

### 12.4 イベント種別

少なくとも次を想定する。

- `segment.created`
- `asr.pending`
- `asr.completed`
- `asr.failed`
- `speaker.span`
- `scene.changed`
- `scope.span`
- `content_priority.assigned`
- `processing.run.completed`
- `processing.run.selected`
- `processing.invalidated`

### 12.5 表示用の文字起こし

人間向け UI や外部エージェントは、原則としてイベントログを直接解釈しない。

`TranscriptMaterializer` が active run のイベントだけを適用し、最新状態の `MaterializedTranscriptSegment` を組み立てる。

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
    }
  ],
  "scope_spans": [
    {
      "start_ms": 199100,
      "end_ms": 200200,
      "scope": "near",
      "confidence": 0.83
    },
    {
      "start_ms": 200200,
      "end_ms": 201970,
      "scope": "unknown",
      "confidence": 0.52
    }
  ],
  "content_priority": "low_priority"
}
```

一つの発話区間に複数の話者区間と複数の音響範囲区間が重なることを許す。

## 13. 再処理結果の選択

再処理によって複数の結果が残るため、どの run を現在値として使うかを明示する。

`session.json` または `processing_metadata.json` に、少なくとも次の active run を保持する。

```text
active_runs:
  segmentation: seg_run_03
  asr: asr_run_07
  diarization: diar_run_04
  scene: scene_run_02
  scope: scope_run_05
  content_priority: priority_run_06
```

新しい run は、生成途中では active にしない。

処理が必要条件を満たして完了した後にだけ active pointer を切り替える。
途中で失敗した run が、既存の正常な結果を部分的に上書きすることを防ぐ。

## 14. Jev による意味分類

### 14.1 既定 provider

v1 の意味分類には Jev API を既定で使う。

汎用 LLM は v1 の分類経路に入れない。

```text
ContentPriorityClassifier
        |
        v
DecisionProvider
        |
        +--> JevDecisionProvider
```

`DecisionProvider` の境界は、将来 provider を置き換えられるように残す。

### 14.2 Jev の役割

Jev は次の狭い意味判断に使う。

- 内容の優先度判定
- discussion 開始や終了の意味上の手掛かり

Jev は録音、VAD、ASR、話者分離、近接度判定そのものには使わない。

### 14.3 内容の優先度

内容の優先度は次の二値とする。

- `PRIMARY`
- `LOW_PRIORITY`

`LOW_PRIORITY` の候補は、単独の filler、内容のない相槌、機材や画面操作の明白な手間取り、待機中の無内容発話、明白な独り言ノイズである。

意味のある内容を含む発話は降格しない。
たとえば「えー、RSA では公開鍵を使います」は `PRIMARY` とする。

### 14.4 入力

内容の優先度判定では、原則として現在の発話だけを送る。

場面転換判定では、必要な場合に限り、現在の発話、直前の少数発話、現在の場面状態を送る。

講義全体を毎回送らない。

### 14.5 キャッシュ

Jev の判定結果は再利用する。

fingerprint には最低限次を含める。

- normalized text
- 判定 schema version
- provider version
- policy version
- 必要な場合は限定的な context hash

### 14.6 通信失敗

Jev が利用できない場合でも録音、ASR、話者分離、場面判定は継続する。

内容の優先度が未判定なら、表示と外部利用では暫定的に `PRIMARY` として扱う。

未判定作業は残し、Jev が利用可能になった後に再実行できる。

### 14.7 利用上限

Jev は低単価の入力判定に使う前提とする。

アプリには、少なくとも送信回数、推定 token 数、利用停止スイッチを確認できる診断情報を持たせる。

利用開始時点では保有する API クレジットを利用する。
クレジット残高そのものを設計上の恒久条件にはしない。

## 15. 場面判定

場面は `LECTURE`、`DISCUSSION`、`UNKNOWN` の三状態を基本とする。

一つの発話だけで状態を切り替えず、候補状態を経由する。

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

### 15.1 ローカル音響証拠

一定時間の観測窓から、次の値をローカルで計算する。

- active speaker count
- turn rate
- overlap ratio
- dominant speaker ratio
- voiced duration
- proximity evidence

`proximity evidence` は近接度を示す生の音響証拠であり、`BACKGROUND` 判定そのものではない。

### 15.2 Jev の意味手掛かり

Jev で `discussion_start`、`discussion_end`、`none` を判定できる。

開始手掛かりの例には、「では隣の人と話し合ってください」「5分間グループで考えてください」がある。

終了手掛かりの例には、「はい、そこまでです」「それでは解説します」がある。

### 15.3 講義から discussion への遷移

Jev が開始手掛かりを検出した場合は、`DISCUSSION_CANDIDATE` へ移り、複数話者の活動や発話交替の増加をローカル音響で確認してから `DISCUSSION` へ移る。

Jev が利用できなくても、十分長い複数話者活動が続けばローカル音響だけで `DISCUSSION_CANDIDATE` へ移れる。

短い質疑だけでは `DISCUSSION` にしない。

### 15.4 discussion から講義への遷移

Jev が終了手掛かりを検出した場合は、`LECTURE_CANDIDATE` へ移る。

Jev が利用できない場合でも、複数話者活動の低下、dominant speaker の復帰、一定時間の継続を確認できれば `LECTURE_CANDIDATE` へ移れる。

開始より長い確認時間を要求してから `LECTURE` へ戻す。

Jev は状態遷移を速める証拠として使い、状態機械の必須依存にはしない。

### 15.5 転換時刻

状態を確定した時刻と、実際に場面が変わった時刻は一致しないことがある。

状態を確定した後、直近の観測窓から最も根拠の強い時点を選び、そこへ遡る `scene.changed` イベントを書けるようにする。

## 16. 近接度と音響範囲

近接度の生データと、`NEAR` または `BACKGROUND` として扱う方針を分離する。

### 16.1 近接度の証拠

**近接度の証拠**は、話者が Mac の近くにいる可能性を示すローカル内部情報である。

候補となる特徴には、音量、直接音と残響の比、話者埋め込みの安定性、マイクに対する相対的な音響特徴などがある。

どの特徴を採用するかは、録音データを使った検証で決める。

### 16.2 音響範囲

音響範囲は次の三値とする。

- `NEAR`
- `BACKGROUND`
- `UNKNOWN`

音響範囲は segment 単位ではなく、原音声上の span として保存する。

`BACKGROUND` として既定表示から除外する方針は、`DISCUSSION` 中だけ有効にする。

一つの発話区間に `NEAR` または `UNKNOWN` の span が含まれる場合は、その発話全体を背景として捨てない。

`LECTURE` 中は、距離だけを理由に `BACKGROUND` へ分類しない。

## 17. ダイアライゼーション

ダイアライゼーションは VAD の発話区間と同じ境界で動く必要はない。

話者情報は、正規化済み処理タイムライン上の独立した時間区間として保持する。

### 17.1 ライブ結果

講義中は streaming diarization を使い、暫定的な speaker timeline を生成できる。

ライブ UI では、この暫定結果を表示してよい。

### 17.2 録音後の再処理

録音停止後は、保存済み音声に対して offline diarization を実行できる。

offline run が完了した場合は、その run を active diarization として選択できる。

これにより、ライブ表示の低遅延と、講義後データの精度を分離する。

### 17.3 話者 ID

話者にはセッション内だけで有効な匿名 ID を割り当てる。

- `SPEAKER_1`
- `SPEAKER_2`

話者の重なりや不確実性がある場合は、無理に一人へ決めない。

長期的な人物名付けと本人識別は v1 の範囲外とする。

### 17.4 ASR 文字列との対応

ダイアライゼーションは時間軸上の話者推定である。

一つの ASR 発話区間に複数話者が含まれる場合、単語単位で誰が話したかまでは v1 で保証しない。

必要性が確認されるまでは forced alignment を必須機能にしない。

## 18. ライブ文字起こし

### 18.1 表示時刻

ライブ表示は ASR 完了直後に行う。

Jev、場面判定、ダイアライゼーション、音響範囲判定の完了は待たない。

後から得られた情報は、既に表示した発話の見た目や補足情報へ反映する。

### 18.2 表示規則

表示例は次のとおりである。

- `PRIMARY`：通常表示
- `LOW_PRIORITY`：薄く表示
- `BACKGROUND`：discussion 中は既定で非表示
- Jev 未判定：通常表示
- ASR 遅延：「文字起こし処理が遅れています」
- ASR 読み込み中：「音声認識モデルを読み込んでいます」
- Jev 未接続：「意味分類を後で再試行します」
- 録音保存失敗：「録音データを保存できません。空き容量を確認してください」

ユーザーが過去の発話を読むために上へスクロールした場合は、自動追従を止める。

その状態から最新発話へ戻るために「最新へ戻る」を用意する。

時刻と匿名話者 ID は、利用可能になった時点で表示できる。

v1 では録音再生 UI を必須にしない。

### 18.3 表示言語

ユーザー向けテキストは日本語を既定とする。

内部の識別子、schema key、event type、enum 値は英語でよい。

表示層で日本語へ変換し、内部値をそのままユーザーへ見せない。

```text
内部: ENGINE_UNAVAILABLE
表示: 音声認識エンジンを利用できません
```

開発者向けログは英語でもよい。

## 19. アプリの実行モデル

v1 は通常の macOS `.app` とする。

```text
Mac idle
  -> 常駐 runtime なし

講義前
  -> mac-ambient-jev.app 起動

講義中
  -> 録音 + ローカル処理
  -> Jev の意味判定だけ外部 API

講義後
  -> セッション停止
  -> 未完了処理を必要に応じて完了
  -> アプリ終了可能
```

Docker、常駐 HTTP service、system daemon、別の Terminal process は必要としない。

Swift と SwiftUI で構成するアプリ本体が、マイク入力、原音声保存、VAD、Qwen3-ASR、ライブ表示、セッション管理、場面判定、ダイアライゼーション、近接度判定、Jev 通信を管理する。

Qwen3-ASR は同じプロセス内で MLX Swift により実行する。

## 20. ローカルデータ

概念上、次の配置を使う。

```text
~/Library/Application Support/mac-ambient-jev/
  ├── sessions/
  ├── models/
  └── config/
```

再生成できるキャッシュは `~/Library/Caches/` を利用できる。

各セッションは概念上、次の構造を持つ。

```text
sessions/
└── <session-id>/
    ├── session.json
    ├── processing_metadata.json
    ├── audio/
    │   ├── original.<ext>
    │   └── または durable chunks
    ├── events.jsonl
    ├── views/
    └── logs/
```

API key などの秘密情報は JSON 設定ファイルへ平文保存せず、macOS Keychain に保存する。

## 21. セッション状態

セッション全体を一つの enum だけで表さない。

少なくとも capture と processing を分ける。

```text
capture_state:
  idle
  recording
  stopped
  failed

processing_state:
  idle
  running
  backlogged
  complete
  partial_failure
```

これにより「録音中だが ASR は遅延中」のような状態を自然に表せる。

UI でも録音状態と処理遅延を別々に表示できる。

## 22. 異常終了からの復旧

再起動時は次の順で復旧する。

1. 未完了セッションを検出する。
2. 原音声の永続化済み範囲を確認する。
3. `events.jsonl` の末尾を検査する。
4. 末尾に不完全な JSON 行があれば、その行だけを無視または切り詰める。
5. active run 情報を読み込む。
6. 保存済みイベントを materialize する。
7. 未完了の処理作業だけを再開する。
8. 完了済みイベントを重複生成しない。

v1 は Python worker を持たないため、復旧時に外部 worker を再起動する処理は前提にしない。

## 23. 再処理とバージョン

再処理に必要な次の情報を保存する。

- 原音声形式と version
- processing timeline version
- VAD version と config hash
- `segmentation_run_id`
- ASR engine、model、version
- diarization version
- scene analyzer version
- Jev schema と provider version
- policy version
- materializer schema version

VAD の設定を変えた場合は、新しい `segmentation_run_id` を作る。

ASR モデルだけを変えた場合は原音声を再利用する。

意味分類の方針だけを変えた場合は既存の ASR 結果を再利用する。

旧結果を破壊的に上書きしない。

## 24. エラー処理

処理成果を守る優先順位は次のとおりである。

1. 原音声
2. 正規化済み処理タイムラインを再生成するための情報
3. 発話区間
4. ASR の文字列
5. 話者、場面、音響範囲
6. Jev による内容の優先度

後段の失敗によって、それ以前に保存できた成果を失わない。

ディスク容量不足は原音声保存そのものを脅かすため、早い段階から監視する。

Jev の通信失敗やクレジット不足は録音停止理由にしない。

## 25. 評価

### 25.1 自動評価

通常の利用時に渡す文字起こしと、低優先度発話や背景発話まで含めた文字起こしを比較する。

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
           evaluator
                |
        retention report
```

評価器はアプリ本体の v1 機能ではない。
外部ワークフローとして実行してよい。

比較から、情報落ち、誤った `LOW_PRIORITY`、誤った `BACKGROUND`、場面転換の異常、VAD の異常、専門用語の欠落を調べる。

### 25.2 小規模な人手確認用データ

全講義の正解文字起こしを人手で作ることは v1 の要件にしない。

代わりに、実際の講義録音から 15〜30 分程度の固定評価集合を作る。

場面転換、discussion、専門用語、低優先度候補を含む区間を選ぶ。

人手で確認する対象は、重要な専門用語、明白な ASR 誤り、場面境界、誤った `LOW_PRIORITY`、誤った `BACKGROUND`、代表的な話者取り違えである。

この固定評価集合を、校正と回帰試験の基準にする。

### 25.3 性能指標

最低限、次を測定する。

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
- false `LOW_PRIORITY` rate
- false `BACKGROUND` rate
- technical-term retention

## 26. 性能モデル

ASR は継続入力より速く処理できることを目標とする。

ただし、一時的に ASR が追いつかなくても録音を継続できる構造にする。

```text
source audio -> 保存継続
ASR queue   -> 遅延可
UI          -> 遅延状態を表示
```

M4 16GB 実機で Qwen3-ASR 1.7B の処理速度またはメモリ量が不足する場合に限り、量子化変更、小型モデル、スケジューリング変更を検討する。

v1 では、問題が確認される前から複数の ASR バックエンドを作らない。

## 27. ネットワーク境界とプライバシー

v1 の通常処理で外部 API を使うのは Jev だけとする。

ローカルで実行するものは次のとおりである。

- 録音
- 音声保存
- VAD
- ASR
- ダイアライゼーション
- 場面判定の音響部分
- 近接度判定
- 音響範囲判定
- イベント保存
- 再処理
- Materializer

Jev へ送信するのは、文字起こしテキストと判定に必要な最小限の文脈だけとする。

原音声を Jev へ送信しない。

Jev の API key は macOS Keychain で管理する。

Jev 以外のクラウド推論サービスは v1 の依存にしない。

モデル取得などの配布用通信は、この推論境界とは別に扱う。

## 28. 外部連携の契約

v1 で安定させる対象は次のとおりである。

- session schema
- canonical processing timeline
- event envelope
- `event_seq`
- processing version
- active run selection
- segmentation run identity
- materialized transcript view

V2 の CLI と stdio MCP は、この契約を読み取る側として実装する。

外部エージェントに正本イベントログの自由な書き換え権限は与えない。

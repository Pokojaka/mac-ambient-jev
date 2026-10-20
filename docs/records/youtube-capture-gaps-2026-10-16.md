# 動画録音の音声欠落調査（2026-10-16）

## 観測と結論

[全編 CER 測定](youtube-full-cer-2026-10-16.md)の `missingCallback` 3件、合計806 frames（50.375 ms）は、Core Audio の I/O 処理時間超過と一致した。警告だけの誤表示ではなく、保存 PCM に欠落補填の無音が入っている。PTS の丸めや SRC によって欠落が作られたという証拠は得られていない。

macOS unified log の `coreaudiod` は3件とも `HostApplicationDisplayID: app.mac-ambient-jev`、`cause: ClientHALIODurationExceededBudget` を記録した。512 frames / 48 kHz の I/O 周期は約10.667 msで、記録された client I/O 時間はすべてこれを超える。

| gap 開始 canonical frame | 開始秒 | 補填 frames | Core Audio のログ時刻（JST） | client I/O 時間 |
| ---: | ---: | ---: | --- | ---: |
| 418304 | 26.1440000 | 233 | 02:11:42.537 | 14.180625 ms |
| 11342911 | 708.9319375 | 279 | 02:23:06.302 | 11.423625 ms |
| 11344555 | 709.0346875 | 294 | 02:23:06.304 | 18.130583 ms |

時刻の近さだけでなく、ログの device-frame 座標が保存 gap と一致する。初期 `anchor_sample_time` は131。以下は48 kHzから16 kHzへの累積境界の変換である。

- 1件目: `1254912 / 3 = 418304`。
- 2件目: `round((32773120 + 1255743 - 131) / 3) = 11342911`。
- 3件目: `(4096 + 34029700 - 131) / 3 = 11344555`。

`io_frame_counter` と、再開後の `anchor_sample_time` を使うと3件すべて一致する。先行の短時間録音も、00:44:40.473 JST の同じ予算超過（20.411833 ms）と一致した。その `io_frame_counter` は5147136で、`5147136 / 3 = 1715712` が短時間録音の gap 開始 frame になる。短時間録音の補填は684 frames（42.75 ms）。

## PCM と保存経路の検証

全編の checkpoint 順に5102 chunk を読み、各 byte 長、総40,814,545 frames、SHA-256 `3d2d7224d2dfb751a07d7b1c55f45bd8f74d0d71bdd18b1a13158d86d06706ef` を照合した。gap 内には次の exact zero run があり、前後には音声サンプルがある。境界の数 frame に現れる小さい非ゼロ値は、無音も同じ stateful SRC を通すことと整合する。

| gap 開始 frame | exact zero の範囲（終端を含まない） | zero frames |
| ---: | --- | ---: |
| 418304 | `[418309, 418533)` | 224 |
| 11342911 | `[11342916, 11343185)` | 269 |
| 11344555 | `[11344560, 11344844)` | 284 |

保存経路は `SystemAudioTap` → `CaptureFrameTimestampMapper` → `TimestampedMonoSink` → `AudioBlockRing` → `AudioCaptureDrain` → `CanonicalAudioResampler`。gap は device-frame の PTS 不連続を drain が無音で埋め、その後に SRC を通す。保存された理由に `overflow`、`invalidBuffer`、`stopTail` はない。リングの保存待ちによる overflow や SRC の block ごとの丸めとは区別できる。

## 修正

`AudioDeviceCreateIOProcIDWithBlock` に通常の serial dispatch queue を渡すと、Core Audio は I/O ごとにその queue へ同期 dispatch する。SDK の `AudioHardware.h` は、queue が `NULL` なら IOBlock を直接呼び出すと規定している。

システム音声の IOBlock は queue を渡さず Core Audio の IO スレッドから直接呼び出すようにした。形式変更の property listener は専用 queue で受け、既存の atomic flag で入力を無効化する。タイムスタンプ mapper、scratch、ring producer は引き続き1本の IO producer が所有する。停止時は device stop と IOProc destroy の後に録音資源を解放する。

これにより通常の dispatch queue の実行待ちが realtime deadline に入る経路を除去する。履歴ログは client I/O の予算超過を証明するが、その超過時間の全量が dispatch 待ちだったとは断定できない。欠落の検出・警告・無音補填は維持している。

回帰テストでは format listener queue を塞ぎ、Core Audio の同期 dispatch 契約を模した登録境界から実際の tap callback を呼ぶ。修正前は1秒待っても sink の end frame が0で、listener を解放するまで音声が届かなかった。修正後は listener を塞いだまま2 frames の PCM を取得できる。テストの待機中はメインアクターを占有しない。

修正後に次を実行し、capture target の57テスト、繰り返す短い PTS 欠落のテスト、3入力レートでの連続 SRC と欠落・重複・overflow・末尾のテストがすべて成功した。

```bash
swift test --package-path app/MacAmbientJev --filter 'MacAmbientJevCaptureTests|continuousCanonicalIngress|fractionalGapsOverlapOverflowAndStopTail|repeatedSmallPTSLossesPreserveAccumulatedMissingFrames'
```

## 証拠の保存と限界

非追跡の `test-data/recordings/local/youtube-T-jKleBEeM4-full-20261016/capture-investigation/` に、3時間帯の Core Audio ログ JSON、`inspect_pcm_gaps.py`、`pcm-gap-analysis.json` を保存した。元の録音セッションは変更していない。

別プロセスの timestamp-only probe は、sandbox 内で tap 作成が `!obj`、sandbox 外では `AudioDeviceStart` が OSStatus 268451843 で失敗し、callback を採取できなかった。この実行を正常な実録音テストとして扱っていない。新しい bundle のシステム音声権限は追加していない。

この調査に用いた全編 PCM は修正前の録音であり、修正後42分間の欠落ゼロを示す測定ではない。単体テストは実機の権限や長時間の I/O 負荷まで保証しない。

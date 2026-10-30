# Windows CPU prepack 計測記録（2026-10-29、未完了）

この測定記録と [転写単位の CSV](windows-cpu-prepack-2026-10-29.csv) は、Windows 11 ARM64 VMware Fusion VM 上の短い固定音声による CPU 比較である。**6つの model-size/mode セルすべては完了していない。** 0.6b の3 mode と1.7b の `current` / `external-mapped` は各3 fresh processで測定したが、1.7b `saved-prepacked` は保存容量不足で生成・reload できず、数値は未測定である。したがって、この記録は P6-7 の計測完了、製品採用承認、または独立した1.7b EP 検証を意味しない。

## 結果概要と範囲

成功した15 measurement process（0.6b 9件、1.7b 6件）は、各々 first transcription 1回と warm transcription 50回を実行した。合計765転写、うち warm 750回である。全処理は fresh process で、PID は各表に記載した。全サイズ・完了 mode・trial で出力 text の UTF-8 bytes と token IDs は current と一致した。CLI は各 process 内でも warm 50回すべてが first transcription の bytes / token IDs と一致しなければ失敗する。ただし expected Japanese transcript を CLI の合否条件にしたわけではなく、観測した parity はこの fixture と環境での計測 parity である。

観測結果はすべて `今日は音声認識の動作を確認します。`、generated token IDs は `[133165, 78685, 70074, 110790, 15767, 117748, 29412, 114277, 77334, 1773, 151645]` だった。これは独立した approved 1.7b execution-provider (EP) verification ではない。

| サイズ | current | external-mapped | saved-prepacked |
| --- | --- | --- | --- |
| 0.6b | 完了（3 trials） | 完了（3 trials） | 完了（3 trials） |
| 1.7b | 完了（3 trials） | 完了（3 trials） | **BLOCKED / 未測定**（save が失敗、reload/measure なし） |

production の通常の ASR 挙動と定数は変更していない一方、測定専用の CLI / factory plumbing を追加した。本記録は測定専用の変更と結果を記録するもので、production 採用を意味しない。結論は **KEEP CURRENT**。将来の明示的な「省メモリ」option は未実装の案であり、この記録で実装・承認したものではない。

> Fix-loop round 1: controller-reviewed corrections to scope, invocation details, and completed checks are incorporated. Raw timings, memory, parity, calibration, and the disk-capacity blocker are unchanged.

## 環境、入力、設定

- Windows 11 ARM64、VMware Fusion VM 上の Apple silicon（M-series Mac host）、4 logical processors、visible memory `6,973,825,024` bytes、OS build `26200`、Windows PowerShell `5.1.26100.9711`。VM は noisy で、ambient noise は計測していない。bare-metal 結果ではない。
- Swift `6.2` (`swift-6.2-RELEASE`)、assertions 有効、`aarch64-unknown-windows-msvc`、Release `-O`。ONNX Runtime `1.31.0` CPU provider。x64 hardware はなく、**全 x64 数値は pending / unrun**。
- intra-op threads `3`（4 logical CPU の VM で1を残す設定）、inter-op `1`、CPU memory arena off、graph optimization `enable_all`。greedy Japanese decode、`max_new_tokens=448`、`no_repeat_ngram_size=nil`。入力は3.3066875秒で、最大15秒未満の短い clip。
- 固定 production fixture [`qwen3_asr_voicevox_short.wav`](../../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/Resources/qwen3_asr_voicevox_short.wav)：VOICEVOX:ずんだもん、52,907 samples、105,858 bytes、16 kHz mono PCM16、3.3066875秒、SHA-256 `2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9`。適用条件・credit は [fixture license](../../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/Resources/qwen3_asr_voicevox.LICENSE.txt) を参照。
- source model manifest の各ファイルと fixture は、各 measurement timer の前に SHA-256 検証済み。saved mode では derived files も timer 前に identity と全 SHA-256 を検証する。この読み込みで OS file cache が温まる。`cold_process_load_seconds` は fresh process の `engine.prepare()` のみであり、cold-storage read、model acquisition、hashing を含まない。
- 3つの engine session は測定中 process に保持された。memory snapshot の **PrivateUsage** は snapshot 時点の現在 private commit、**PeakPagefileUsage** は transient load peak も含む process lifetime の真の peak private commit、**WorkingSetSize** は現在 resident memory、**PeakWorkingSetSize** は lifetime peak working set である。両 peak は pre-timer validation を含む lifetime high-water mark。VMMap / ETW を採っていないため zero-copy は立証されない。

## mode と保存手順

- `current` は元の `ONNXQwen3ASREngine` initializer で、明示的 session config entry はない。
- `external-mapped` は `session.use_device_allocator_for_initializers=0` と `session.disable_prepacking=0` を明示した control であり、どちらも ORT 1.31.0 の既定値。eligible CPU external data は ORT が通常どおり自動 map する。これは新しい optimization ではない。`.onnx` を使ったこの計測に `.ort` 専用 mmap key は適用していないし、別の key を仮定しない。
- 0.6b `saved-prepacked` は `session.save_external_prepacked_constant_initializers=1`、`session.optimized_model_filepath=<staging>/<original graph name>`、`session.optimized_model_external_initializers_file_name=<role>.data`、`session.optimized_model_external_initializers_min_size_in_bytes=1024` を使う**別 save process**で生成した。reload は external-mapped entries を使うが save option は渡さず、保存済み identity / hashes を timer 前に検証する。manifest identity は pinned source hashes、ORT、architecture/ISA、settings を含む。staging からの atomic publication、破損時の明示 error と明示的再生成は、この計測用 derived cache の規則であり production cache 動作を示すものではない。

### pinned model source files

各行の hashes は source manifest から得た値で、各測定前に検証した。0.6b commit `4fc24a1402e74db89c4d2ef256875e71680128c4`、1.7b commit `df916193ac67e59347769891a21e10d81d12acdd`。

| model | file | bytes | SHA-256 |
| --- | --- | ---: | --- |
| 0.6b | `decoder_init.int4.onnx` | 355,390 | `6d54633bbb9e6b1ecf372f218d04adb3bf6f2bfc442ce55c988526d532896faa` |
| 0.6b | `decoder_step.int4.onnx` | 354,888 | `7eaa4f31d5eb6ae2937ff45222c32f692f2d5ac29b46cbae9046da332a9f317d` |
| 0.6b | `decoder_weights.int4.data` | 962,460,672 | `d68cd1c0695a7ba42651d06b1bc1158e2e58af5f9adbb6dba874fbbb8a4f22cf` |
| 0.6b | `embed_tokens.bin` | 311,164,928 | `e80150119fa5f7e56e85aed64c3a02d5c78eb7a37cfdcb973d0987316f15bee2` |
| 0.6b | `encoder.onnx` | 745,762,694 | `3c027f880f677615de85e1f6934906e1d5d77624b724096d33accef99c753eed` |
| 0.6b | `tokenizer.json` | 11,429,377 | `bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92` |
| 1.7b | `decoder_init.int4.onnx` | 356,165 | `c638585ada629b3cf65ce9cb068b7b980fccc9454a7f05e2333b8813730c1999` |
| 1.7b | `decoder_step.int4.onnx` | 355,662 | `fa138c025c26f6559e12be51cfbba5204a0b6993a1f3bb1177f80a0a65873bb5` |
| 1.7b | `decoder_weights.int4.data` | 2,226,321,408 | `3f8d8fb695bcffc20ce8d8e823471e011404420785adf7678aac31057ef67333` |
| 1.7b | `embed_tokens.bin` | 622,329,856 | `1489075dbd08fcd6b87bc69c5feca278014d29fa5693bd4aa61e47c1a3a160d4` |
| 1.7b | `encoder.onnx` | 1,270,241,779 | `c19ff8d702707693877a509ba1867472b0ad964593b93751091891a143edffec` |
| 1.7b | `tokenizer.json` | 11,429,377 | `bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92` |

### 0.6b saved-prepack manifest の生成結果

Generation は42.8790521秒。下記 file sizes の合計は3,526,025,208 bytes（約3.29 GiB）であり、**file data の容量であって process memory/residency ではない**。各生成物の SHA-256 は manifest の値。

| generated file | bytes | SHA-256 |
| --- | ---: | --- |
| `decoder_init.data` | 1,336,935,936 | `17c11fb844a25313296a22be313050f7ecec37d9785b1099cfba50b154a58375` |
| `decoder_init.int4.onnx` | 335,448 | `591a6621f48825604bedd9463d5c4b79ba4c27a8afbcce61661d0d0ab1f7a1ee` |
| `decoder_step.data` | 714,606,080 | `d8a5184a2c0851e2bbda1214116a70f881f8ef4b9e6fa607d4b27aff79f33c68` |
| `decoder_step.int4.onnx` | 345,729 | `63618e2ea85a6e42f6dbb47c3423f731b53718d49ea45a9924d6ffd6307094b5` |
| `encoder.data` | 1,473,593,344 | `880c14e81952cfbb631ed9bb9bcfa045c8a610e41ced378414c183e295c55399` |
| `encoder.onnx` | 208,671 | `d56410f57c016299c7d4b4b4996da18c70d3457f4ccadc2e012475be0b806c0e` |

## 全15 measurement process の performance

`warm mean RTF` は first を除外した warm 50回の arithmetic mean。`warm p95` は warm latency 秒の nearest-rank p95（50件中の48番目）で、first transcription を含まない。すべての individual first / warm elapsed 秒と RTF は [CSV](windows-cpu-prepack-2026-10-29.csv) に記録した。CSV の `phase=first` は `call_index=1`、`phase=warm` は `call_index=1..50`（phase ごとの index）。

| サイズ | mode | trial / PID | load (秒) | first RTF | warm 平均 RTF | warm p95 (秒) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 0.6b | current | 1 / 68 | 14.7330881 | 0.639015540 | 0.509228743 | 2.0524162 |
| 0.6b | current | 2 / 6672 | 13.6526595 | 0.510885592 | 0.461123873 | 1.8076899 |
| 0.6b | current | 3 / 7888 | 14.8226628 | 0.479502856 | 0.464468982 | 1.8219579 |
| 0.6b | external-mapped | 1 / 6992 | 17.5320611 | 0.471599357 | 0.487378340 | 1.8210938 |
| 0.6b | external-mapped | 2 / 4540 | 15.0756380 | 0.637287557 | 0.529328253 | 2.2634373 |
| 0.6b | external-mapped | 3 / 8024 | 19.3166507 | 0.478082280 | 0.473510356 | 1.8319650 |
| 0.6b | saved-prepacked | 1 / 6892 | 9.4277570 | 0.649394084 | 0.538613577 | 2.0179808 |
| 0.6b | saved-prepacked | 2 / 4144 | 9.8213154 | 0.671364167 | 0.605924257 | 2.4569432 |
| 0.6b | saved-prepacked | 3 / 2600 | 9.7464013 | 0.690267677 | 0.478356488 | 2.2217173 |
| 1.7b | current | 1 / 7556 | 32.2522359 | 1.091443869 | 0.618980369 | 2.3622364 |
| 1.7b | current | 2 / 748 | 29.7639324 | 1.061544370 | 0.651677094 | 2.5383432 |
| 1.7b | current | 3 / 2840 | 28.7596296 | 1.013630741 | 0.663219044 | 2.5951771 |
| 1.7b | external-mapped | 1 / 7420 | 26.2363714 | 1.188167706 | 0.702037876 | 3.7389206 |
| 1.7b | external-mapped | 2 / 3952 | 26.2653008 | 1.030127643 | 0.636846890 | 2.2990307 |
| 1.7b | external-mapped | 3 / 5472 | 26.2178357 | 0.984469533 | 0.658118933 | 2.5808930 |

## memory snapshots: after prepare

bytes で記録。Peak 値は process lifetime の peak、その他は snapshot 時点の値。

| サイズ | mode | trial / PID | Peak WS (B) | WS (B) | PrivateUsage (B) | PeakPagefileUsage (B) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 0.6b | current | 1 / 68 | 1,727,352,832 | 1,668,829,184 | 1,564,839,936 | 1,601,990,656 |
| 0.6b | current | 2 / 6672 | 1,727,696,896 | 1,669,181,440 | 1,565,220,864 | 1,602,375,680 |
| 0.6b | current | 3 / 7888 | 1,727,475,712 | 1,668,927,488 | 1,564,925,952 | 1,602,080,768 |
| 0.6b | external-mapped | 1 / 6992 | 1,727,815,680 | 1,669,316,608 | 1,565,315,072 | 1,602,375,680 |
| 0.6b | external-mapped | 2 / 4540 | 1,727,356,928 | 1,668,845,568 | 1,564,835,840 | 1,602,039,808 |
| 0.6b | external-mapped | 3 / 8024 | 1,727,606,784 | 1,669,234,688 | 1,565,270,016 | 1,602,334,720 |
| 0.6b | saved-prepacked | 1 / 6892 | 326,361,088 | 169,979,904 | 65,826,816 | 146,763,776 |
| 0.6b | saved-prepacked | 2 / 4144 | 326,324,224 | 170,070,016 | 66,240,512 | 147,001,344 |
| 0.6b | saved-prepacked | 3 / 2600 | 326,328,320 | 170,328,064 | 66,088,960 | 146,804,736 |
| 1.7b | current | 1 / 7556 | 3,897,061,376 | 3,760,726,016 | 3,504,930,816 | 3,542,061,056 |
| 1.7b | current | 2 / 748 | 3,897,126,912 | 3,760,824,320 | 3,504,971,776 | 3,542,077,440 |
| 1.7b | current | 3 / 2840 | 3,896,958,976 | 3,760,648,192 | 3,504,812,032 | 3,541,946,368 |
| 1.7b | external-mapped | 1 / 7420 | 3,897,458,688 | 3,761,065,984 | 3,505,233,920 | 3,542,376,448 |
| 1.7b | external-mapped | 2 / 3952 | 3,897,044,992 | 3,760,873,472 | 3,505,020,928 | 3,542,028,288 |
| 1.7b | external-mapped | 3 / 5472 | 3,897,081,856 | 3,760,668,672 | 3,504,758,784 | 3,541,946,368 |

## memory snapshots: after all warm calls

| サイズ | mode | trial / PID | Peak WS (B) | WS (B) | PrivateUsage (B) | PeakPagefileUsage (B) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 0.6b | current | 1 / 68 | 1,785,655,296 | 1,720,217,600 | 1,615,216,640 | 1,680,785,408 |
| 0.6b | current | 2 / 6672 | 1,773,944,832 | 1,720,594,432 | 1,615,675,392 | 1,669,079,040 |
| 0.6b | current | 3 / 7888 | 1,774,280,704 | 1,718,927,360 | 1,613,873,152 | 1,669,341,184 |
| 0.6b | external-mapped | 1 / 6992 | 1,774,514,176 | 1,720,172,544 | 1,615,159,296 | 1,669,603,328 |
| 0.6b | external-mapped | 2 / 4540 | 1,773,637,632 | 1,719,386,112 | 1,614,368,768 | 1,668,722,688 |
| 0.6b | external-mapped | 3 / 8024 | 1,774,145,536 | 1,717,600,256 | 1,612,701,696 | 1,669,885,952 |
| 0.6b | saved-prepacked | 1 / 6892 | 1,738,838,016 | 1,679,699,968 | 79,233,024 | 146,763,776 |
| 0.6b | saved-prepacked | 2 / 4144 | 1,738,653,696 | 1,679,601,664 | 79,491,072 | 147,001,344 |
| 0.6b | saved-prepacked | 3 / 2600 | 1,752,219,648 | 1,679,044,608 | 78,491,648 | 152,109,056 |
| 1.7b | current | 1 / 7556 | 3,897,061,376 | 3,812,016,128 | 3,554,656,256 | 3,609,849,856 |
| 1.7b | current | 2 / 748 | 3,897,126,912 | 3,811,799,040 | 3,554,398,208 | 3,609,997,312 |
| 1.7b | current | 3 / 2840 | 3,896,958,976 | 3,808,956,416 | 3,551,596,544 | 3,609,526,272 |
| 1.7b | external-mapped | 1 / 7420 | 3,897,458,688 | 3,811,483,648 | 3,554,050,048 | 3,609,845,760 |
| 1.7b | external-mapped | 2 / 3952 | 3,897,044,992 | 3,812,012,032 | 3,554,668,544 | 3,610,025,984 |
| 1.7b | external-mapped | 3 / 5472 | 3,897,081,856 | 3,811,561,472 | 3,554,099,200 | 3,621,920,768 |

## page faults

`load Δ = after_prepare − before_load`、`inference Δ = after_all_warm_calls − after_prepare`、`合計 Δ = after_all_warm_calls − before_load`。件数は raw process counter。

| サイズ | mode | trial / PID | load前 | load Δ | inference Δ | 合計 Δ |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 0.6b | current | 1 / 68 | 877,757 | 811,135 | 2,388,159 | 3,199,294 |
| 0.6b | current | 2 / 6672 | 877,329 | 808,804 | 2,386,972 | 3,195,776 |
| 0.6b | current | 3 / 7888 | 877,616 | 808,715 | 2,382,628 | 3,191,343 |
| 0.6b | external-mapped | 1 / 6992 | 877,014 | 810,861 | 2,386,681 | 3,197,542 |
| 0.6b | external-mapped | 2 / 4540 | 877,269 | 809,414 | 2,373,673 | 3,183,087 |
| 0.6b | external-mapped | 3 / 8024 | 877,290 | 811,704 | 2,387,610 | 3,199,314 |
| 0.6b | saved-prepacked | 1 / 6892 | 2,211,216 | 545,322 | 4,541,618 | 5,086,940 |
| 0.6b | saved-prepacked | 2 / 4144 | 2,194,023 | 545,307 | 4,525,482 | 5,070,789 |
| 0.6b | saved-prepacked | 3 / 2600 | 2,195,825 | 545,500 | 4,564,569 | 5,110,069 |
| 1.7b | current | 1 / 7556 | 1,777,851 | 1,773,316 | 2,478,722 | 4,252,038 |
| 1.7b | current | 2 / 748 | 1,777,819 | 1,773,328 | 2,449,867 | 4,223,195 |
| 1.7b | current | 3 / 2840 | 1,777,600 | 1,773,097 | 2,503,991 | 4,277,088 |
| 1.7b | external-mapped | 1 / 7420 | 1,778,435 | 1,773,097 | 2,529,829 | 4,302,926 |
| 1.7b | external-mapped | 2 / 3952 | 1,779,296 | 1,772,148 | 2,414,782 | 4,186,930 |
| 1.7b | external-mapped | 3 / 5472 | 1,779,154 | 1,771,024 | 2,482,031 | 4,253,055 |

## 1.7b saved-prepacked の blocker

Full PowerShell runner は1.7b save error で停止した。以後の1.7b `current` / `external-mapped` 3 trials 各自は runner の fallback / replacement ではなく、CLI の必須 `--action measure --calls 50 --threads 3` を指定して明示的に手動実行した独立測定である。保存済み 1.7b model の read / reload は発生していない。saved-prepacked の load time、memory、RTF、p95、text/token parity はすべて**未測定**であり、0 や他 mode からの推定値ではない。

1.7b save は2回を個別に明示実行し、どちらも exit code 1。自動 retry はない。ORT の diagnostic は `graph.cc:5466 ... Failed to write pre-packed blobs to external file`（`decoder_step` 作成中）だった。1秒間隔の disk sampling で `minimum_free_c_bytes=0`、`maximum_staging_bytes=7,355,890,608` を観測した時点の partial files は以下。これは観測された partial staging であって、完成時の総必要容量の推定ではない。

| partial staging file | bytes |
| --- | ---: |
| `decoder_init.data` | 3,304,506,880 |
| `decoder_init.int4.onnx` | 336,244 |
| `decoder_step.data` | 1,528,807,424 |
| `decoder_step.int4.onnx` | 0 |
| `encoder.data` | 2,521,964,544 |
| `encoder.onnx` | 275,516 |
| **観測最大 staging 合計** | **7,355,890,608** |

実行前 C: free bytes は `7,133,634,560`（約7 GB）で、sampling 中には0まで減った。完成に必要な save size は不明で、観測された partial staging は開始時の空き容量を超えた。これはディスク容量 blocker であり ORT text/token parity failure ではない。圧縮・optimization・source files の変更や無関係 file の削除で続行していない。測定作成物は cleanup 済みで、raw cleanup は `prepack_small_exists=false`、`prepack_large_exists=false`、`staging_count=0`、最終 free C: `7,334,293,504` bytes を記録する。

## 結果の判断と限界

- 採用判断は **KEEP CURRENT**。production behavior、threshold/constants、x64 / GPU ratio を変更・承認しない。
- 0.6b warm mean RTF は current `0.4782738659156634`、external-mapped `0.4967389832473335`、saved-prepacked `0.5409647741634692`。saved の平均は current より約13.11%遅く、暫定10% tolerance を超える。対応 trial の最悪回帰は31.401624%。
- saved-prepacked の真の peak commit (`PeakPagefileUsage`) は current 比で90.888–91.268%減少した一方、warm current working set は saved より大きく離れておらず、warm WS だけから同等の省メモリを主張できない。メモリ改善単独では速度回帰を受け入れる根拠にならない。
- 1.7b saved-prepacked は blocked なので採用可否の比較材料がない。これがこの時点での全体測定 blocker。
- 暫定 `0.70 RTF`、`x1.20` margin、`10%` tolerance は変更しない。短 clip・3 trials の ARM64 VM 比較からの calibration は evidence のみ：current large/small warm mean ratio は `0.6446255025106948 / 0.4782738659156634 = 1.347816697608071`、paired ratios `[1.2155251986696856, 1.4132365125032558, 1.4279081500269064]`。illustrative に `ceil(max(ratio)*10)/10 = 1.5`、さらに `x1.20 = 1.8` と置くと、small mean ×1.8 = `0.860892958648194` で0.70を上回る。
- external-mapped control の large/small warm mean ratio は `0.6656678999754286 / 0.4967389832473335 = 1.3400758193443074`、paired ratios `[1.440437167734697, 1.2031228007810617, 1.3898723113262563]`。同じ illustrative rounding は1.8となる。どちらの比率も release constant / production scale ではない。
- 校正は3.3067秒の固定短 clip と noisy ARM64 VM に限られる。14秒までの代表的 live segments、x64、bare-metal、backend/vendor coverage、1.7b saved pair がない。従って x64 数値、一般化した throughput、採用比率は推定しない。

## 再現情報

作業は Mac 側で次の lock convention を使い、Windows 11 ARM64 VM に委譲した。

```sh
lockf -t900 /private/tmp/winvm-p4.lock winvm run /Users/pokojaka/Documents/ChatGPT/mac-ambient-jev/.claude/worktrees/windows-p6 -- '<PowerShell>'
```

記録対象 Windows Release build command は次のとおり（初回291.60秒、最終19.24秒）。

```powershell
cmd /c "swift build --package-path app/MacAmbientJev -c release --product MacAmbientJevTranscribeFile > C:\Users\codextest\p6-7-build-final.log 2>&1"
```

実際に使用した Release bin path は、既存の Release directory を指定した次の `$binDir` の解決済み path である。この job では `swift --show-bin-path` を実行していない。ORT DLL は次から release bin へ copy する。

```powershell
$binDir=Join-Path (Get-Location) 'app/MacAmbientJev/.build/aarch64-unknown-windows-msvc/release'
Copy-Item -LiteralPath '.build/onnxruntime/1.31.0/onnxruntime-win-arm64-1.31.0/lib/onnxruntime.dll' -Destination (Join-Path $binDir 'onnxruntime.dll') -Force
```

0.6b / 1.7b の model paths はそれぞれ `C:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4`、`C:\Models\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd`。source fixture は `app/MacAmbientJev/Sources/MacAmbientJevEngineHost/Resources/qwen3_asr_voicevox_short.wav`。runner [`scripts/measure-windows-cpu-prepack.ps1`](../../scripts/measure-windows-cpu-prepack.ps1) の必須 parameters は `-Executable`, `-SmallModelDirectory`, `-LargeModelDirectory`, `-Fixture`, `-ResultsDirectory`。結果先は新規 `C:\Users\codextest\p6-7-results-20261029`。runner は各 model で save を先に行い、その後 mode order を trial ごとに rotate する。0.6b の実行順は trial 1 `current, external-mapped, saved-prepacked`、trial 2 `external-mapped, saved-prepacked, current`、trial 3 `saved-prepacked, current, external-mapped`。0.6b の9件は成功したが、1.7b save error で full runner は停止したため、runner 全体が成功したとは扱わない。実行時の引数形は次のとおり。

```powershell
& .\scripts\measure-windows-cpu-prepack.ps1 `
  -Executable (Join-Path $binDir 'MacAmbientJevTranscribeFile.exe') `
  -SmallModelDirectory 'C:\Models\qwen3-asr-0.6b-int4-4fc24a1402e74db89c4d2ef256875e71680128c4' `
  -LargeModelDirectory 'C:\Models\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd' `
  -Fixture (Join-Path (Get-Location) 'app/MacAmbientJev/Sources/MacAmbientJevEngineHost/Resources/qwen3_asr_voicevox_short.wav') `
  -ResultsDirectory 'C:\Users\codextest\p6-7-results-20261029'
```

runner 停止後に行った1.7b current / external-mapped の手動測定では、各 invocation に `measure-prepack --fixture <fixture> --asr-model-directory <1.7b pinned path> --asr-model-size 1.7b --threads 3 --prepack <mode> --action measure --calls 50 --output <unique JSON>` を渡し、native `cmd` から unique `.log` へ `2>&1` redirect した。実行順は `trial 1: current, external-mapped`、`trial 2: external-mapped, current`、`trial 3: current, external-mapped`。各 JSON / log は `C:\Users\codextest\p6-7-results-20261029` に個別名で保存（例: `1.7b-current-1.json` と `.log`）。いずれも fresh process であり、saved-prepacked を代用した実行ではない。実際の既知 path に spaces はなく、代表的な invocation（trial 1 current）の native `cmd` command pattern は次のとおり。

```powershell
$exe = Join-Path $binDir 'MacAmbientJevTranscribeFile.exe'
$fixture = (Resolve-Path 'app/MacAmbientJev/Sources/MacAmbientJevEngineHost/Resources/qwen3_asr_voicevox_short.wav').Path
$model = 'C:\Models\qwen3-asr-1.7b-int4-df916193ac67e59347769891a21e10d81d12acdd'
$json = 'C:\Users\codextest\p6-7-results-20261029\1.7b-current-1.json'
$log = 'C:\Users\codextest\p6-7-results-20261029\1.7b-current-1.log'
$nativeCommand = "$exe measure-prepack --fixture $fixture --asr-model-directory $model --asr-model-size 1.7b --threads 3 --prepack current --action measure --calls 50 --output $json > $log 2>&1"
cmd /c $nativeCommand
```

UTC run start は `2026-10-29T23:02:36.5966336Z`、collection は `2026-10-30T00:00:31.4924377Z`（JST では10月30日）。

## 完了した検証

この job で完了した検証結果と、完了していない Windows full-suite 確認を記録する。

- Windows Debug Swift build pass、42.63秒。全 test targets の compile は52.57秒で完了。
- 既存 Windows tests を `ONNXSessionTests|ONNXValueTests|TranscribeFileTests` で filter した run は34 tests / 3 suites PASS、0.208秒。filtered invocation 全体も0.208秒で、filtered-run budget は適用されていない。
- Windows full Swift-test suite は未実行。preflight で prepared Silero resource が不足しており、download は行っていない。
- Mac `swift test` は1,372 reported tests / 14 bundle summaries pass。
- .NET tests は479件、exit code 0。
- Portable checker、`python3 scripts/check_doc_references.py`、`git diff --check` は pass。

## 参照

- ONNX Runtime 1.31.0 [session option config keys](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/include/onnxruntime/core/session/onnxruntime_session_options_config_keys.h)、[CPU initializer mapping path](https://raw.githubusercontent.com/microsoft/onnxruntime/v1.31.0/onnxruntime/core/framework/session_state_utils.cc)、[v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0)。
- Windows [`PROCESS_MEMORY_COUNTERS_EX`](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex) と [`GetProcessMemoryInfo`](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)。
- Swift Foundation 6.2 [`Data+Writing.swift`](https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.2-RELEASE/Sources/FoundationEssentials/Data/Data+Writing.swift)（`withoutOverwriting` direct write と atomic move を使う staging publication 実装の根拠）。
- fixture の適用条件と credit: [VOICEVOX:ずんだもん license](../../app/MacAmbientJev/Sources/MacAmbientJevEngineHost/Resources/qwen3_asr_voicevox.LICENSE.txt)。

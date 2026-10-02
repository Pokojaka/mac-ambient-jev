# Linux 音声検証

この文書は、macOS版 `.app` と分離したLinux検証環境の実行方法をまとめる。

## 境界

macOS版は本番アプリであり、SwiftUI、AVFoundation、FluidAudio、MLX版Qwen3-ASRを使う。

Linux側は検証専用で、Portable Core、Qwen3-ASR公式Python実装、Nemotron 3 Diarization、corpus取得・評価を扱う。Python、CUDA、NeMoはMacアプリの依存に追加しない。

## Portable Core

```bash
./scripts/verify_portable.sh
```

このコマンドは次を確認する。

- `MacAmbientJevCore` にAVFoundation、Security、SwiftUI等のApple framework importがない
- Linux上でSwiftPM manifestを評価できる
- `MacAmbientJevCoreTests` を実行できる

## Linux音声smoke test

```bash
./scripts/verify_linux_audio.sh --smoke
```

smokeではPortable CoreとPython unit testを実行し、Qwen3-ASR依存の有無を確認する。

依存がない場合はPASSではなく `SKIPPED_MISSING_DEPENDENCY` とし、exit code 2で終了する。

## Full test

```bash
./scripts/verify_linux_audio.sh --full
```

fullではNemotron/NeMo依存も確認する。

NemotronはLinux + NVIDIA GPU向けのoptional backendであり、未導入でもASR unit testは独立して実行できる。

## Qwen3-ASR

Linuxでは公式 `qwen-asr` packageのTransformers backendを利用する。

モデル:

```text
Qwen/Qwen3-ASR-1.7B
```

実行runner:

```text
tools/linux-audio/asr/qwen3_asr.py
```

Mac版のspeech-swift/MLX backendと出力完全一致は要求しない。共通化するのはartifact schemaとCER evaluatorである。

## Nemotron 3 Diarization

Linux runner:

```text
tools/linux-audio/diarization/nemotron3.py
```

評価上のspeaker schema:

```text
Speaker 1 ... Speaker 7
OTHER
UNKNOWN
```

最初の7人は初回登場順に固定する。8人目以降はOTHERへcollapseする。判定材料が不足する場合はUNKNOWNとし、OTHERへ楽観的に押し込まない。

Nemotronの第8streamをそのままOTHERとは扱わない。9人目以降がSpeaker 1〜7へ混入する可能性を、`other_to_tracked_leakage` として別に測定する。

## corpus

VOICEVOX用の固定日本語scriptは次にある。

```text
tools/corpora/voicevox-ja-core-v1.json
```

外部corpusは音声本体をcommitせず、テスト時にローカルcacheへ取得する。取得物はSHA-256を固定してからstandard suiteへ昇格する。

候補は以下。

- CSJ公開インタビュー/課題指向対話
- LibriVox + 青空文庫の著作権切れ作品
- RWCP News Speech Corpusの公開試聴sample

取得元が変化した場合、hash mismatchを無視して成功扱いにしてはいけない。

## baseline

baselineはbackendごとに分離する。

```text
baselines/
  macos/
    mlx-qwen.json
    fluidaudio-diarization.json
  linux/
    qwen3-asr.json
    nemotron3-7plus-other.json
```

baselineには最低限次を保存する。

- model
- revision
- backend
- device
- evaluator version
- corpus SHA-256
- metrics

これらの再現条件が異なるbaseline同士は比較しない。

## 現時点での検証制約

ChatGPT側のLinux実行環境にはNVIDIA GPU/NeMoがないため、Nemotron本体推論はここでは実行できない。

またPrivate GitHub checkoutをLinuxコンテナへ直接materializeできないため、Portable Coreの実リポジトリ全体ビルドは別環境で最終確認が必要である。

純粋ロジックについてはLinux上の分離ハーネスでSwift/Python testを実行する。未実行項目をPASSとして記録しない。

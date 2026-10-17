# Windows 音声 codec fixture

このディレクトリには圧縮済み fixture だけを置きます。WAV は保存せず、テスト中に生成します。レートやチャンネル数を変えた WAV テスト用データもテスト中に生成し、コミットする fixture セットを 100,000 バイト未満に保ちます。

## 入力信号

すべて 48,000 Hz、ステレオ、PCM 16-bit little-endian、正確に 12,288 source frames（0.256 秒）です。形式ごとの波形は次のとおりです。

- FLAC / MP3: 全 source frames に両チャンネル同位相の 375 Hz 正弦波
- M4A / AAC: `0..<3072` は無音、`3072..<3584` は 700 Hz から 3,700 Hz への線形 chirp、`3584..<6144` は無音、`6144..<12288` は 375 Hz 正弦波
- 音のある区間では左チャンネルのゲインが 0.5、右が 0.25。解析値を mono に平均したゲインは `(0.5 + 0.25) / 2 = 0.375`
- PCM への量子化は `round(value * 32768)` 相当で、ちょうど中間の値はゼロから遠ざかる方向へ丸めます

fixture の再生成には、PATH 上にある **FFmpeg 8.0** が必要です。Windows テストはコミット済みの圧縮 fixture とテスト中に生成する WAV を使うため、FFmpeg を必要としません。8.0 以外のバージョンや別 encoder への fallback はありません。codec / AAC encoder の一次資料は [FFmpeg 8.0 Changelog](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/Changelog) と [FFmpeg AAC codec documentation](https://ffmpeg.org/ffmpeg-codecs.html#aac) です。エンコードには metadata を除去する `-map_metadata -1` と bitexact / single-thread flags (`-fflags +bitexact -flags:a +bitexact -threads 1`) を使います。`-fflags +bitexact` は MP4/M4A にも適用されます。MP3 は gapless 再生に必要な Xing 情報を残します。

## 個別の再生成コマンド

リポジトリのルートから、それぞれ別々に実行します。出力先が既にある場合は上書きしません。再生成する場合は、まず対象ファイルを検証し、手動で削除してください。

```sh
python3 -B scripts/generate_windows_audio_fixtures.py --format flac --output app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/Resources/windows_audio_fixture.flac
```

```sh
python3 -B scripts/generate_windows_audio_fixtures.py --format mp3 --output app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/Resources/windows_audio_fixture.mp3
```

```sh
python3 -B scripts/generate_windows_audio_fixtures.py --format m4a --output app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/Resources/windows_audio_fixture.m4a
```

```sh
python3 -B scripts/generate_windows_audio_fixtures.py --format aac --output app/MacAmbientJev/Tests/MacAmbientJevWindowsSupportTests/Resources/windows_audio_fixture.aac
```

FLAC は compression level 5 / `s16`、MP3 は `libmp3lame` 192 kbit/s、M4A は native AAC 192 kbit/s / AAC-LC、AAC は同じ native AAC encoder を ADTS container で出力します。現行の圧縮 fixture 合計は 34,804 bytes（100,000 bytes 未満）です。生成スクリプトは出力を一つずつ作成し、出力サイズが正であることと、同じ出力ディレクトリ内の圧縮 fixture 合計が 100,000 バイト未満であることを確認します。

## デコード時の期待値

MP3 と AAC は lossy codec のため、デコードした PCM は量子化済み source と完全一致しません。375 Hz 正弦波の周期は `48000 / 375 = 128` source frames です。AAC encoder の priming は 1,024 frames（整数周期 8 周期）です。

FLAC と Xing 情報による gapless decode を使う MP3 は、native decode が正確に 12,288 frames、16 kHz canonical timeline が正確に 4,096 frames です。M4A と ADTS AAC は native decode が正確に 13,312 frames（1,024 frames の AAC packet 13 個）、canonical timeline が正確に 4,437 frames です。FFmpeg 8.0 native AAC の untrimmed ADTS 参照も 13,312 decoded frames です。AAC priming は取り除かず、native frame extent から canonical boundary を算出して一致を確認します。

M4A / AAC の source 信号は frame 3,072 から始まります。mono sample の `abs(sample) > 0.05` を最初に満たす native decode frame は 4,098 ±4、canonical frame は 1,366 ±2 が期待値です。ADTS 参照の native decode では最初の crossing は frame 4,098 です。初期 crossing の lossy decoder による小さな差だけを許す狭い許容幅であり、1,024-frame priming の追加・除去（canonical で約341 framesの移動）を許しません。

AAC / M4A の 16 kHz canonical samples では `2560..<4096` を正弦波の内部区間として検証します。canonical frame `f` の期待値は、source frame `Double(f) * 3 - 1024` における 48 kHz / 375 Hz sine、mono gain 0.375 です。FLAC / MP3 は canonical frames `768..<3328` を検証します。すべての形式で lossy decode の振幅誤差 tolerance は 0.06 です。

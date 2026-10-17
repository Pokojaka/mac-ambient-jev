# Windows の共通コア

Windows では Swift 6.2 で共通コア、評価 CLI 3 本、Core の単体テストをビルドできます。
録音、音声ファイルのデコード、VAD・ASR・話者分離・発話文判定の実推論、GUI、
インストーラーは Windows の実行対象に含まれません。macOS のアプリは従来どおり
Apple Silicon と macOS 15 以降で動作します。

## ビルドと検証

Swift 6.2 の Windows toolchain、対応する Visual Studio の C++ Build Tools と Windows SDK、
Python 3 を用意し、リポジトリルートから実行します。

```powershell
python -B scripts/test_portable_core.py
python -B scripts/check_portable_core.py
python scripts/test_doc_references.py
python scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
```

`swift build` は共通コアと MacAmbientJevEvaluateSession、MacAmbientJevEvaluateASR、
MacAmbientJevEvaluateDiarization をビルドします。macOS 専用の framework や推論モデルは取得しません。
評価 CLI の参照文・artifact の形式は [testing.md](testing.md) と [linux.md](linux.md) を参照してください。
参照文のファイル指定は相対パスと Windows の絶対パスを扱います。

[portable-core.yml](../.github/workflows/portable-core.yml) は main への push、pull request、手動実行で
Linux と Windows のビルド・Core テストを実行します。Windows のテストには symlink の作成権限が必要です。
macOS の app bundle と録音・GUI の検証は [ci.yml](../.github/workflows/ci.yml) と Mac で行います。

## 保存先と境界

既定の保存先は SHGetKnownFolderPath で取得する LocalAppData 配下です。
取得に失敗した場合はエラーにし、環境変数や macOS のパスで補いません。
セッションは LocalAppData/mac-ambient-jev/sessions、モデルは同じアプリ root の models、
キャッシュは LocalAppData/Caches/mac-ambient-jev に置きます。
LocalAppData はシステムの既知フォルダーであり、これらは生成される保存先です。

SessionFileAccess は Windows 専用の CWindowsSession を使います。
明示された root を CreateFileW の FILE_FLAG_OPEN_REPARSE_POINT 付きで開き、
子要素は固定した親 handle を基点に NtCreateFile で開きます。
reparse point（symlink、junction を含む）、通常ファイルでない末尾、境界外パスは拒否します。
親が途中で改名されても、検査後に絶対パスから開き直すことはありません。

一時ファイルは同じ親 handle 配下に排他的に作り、FlushFileBuffers 後、
NtSetInformationFile の FileRenameInformation で開いた一時ファイル自身を原子的に公開します。
公開先も固定したディレクトリ handle で指定し、公開後にディレクトリを同期します。
MoveFileExW のパスを再解決する方式は使いません。同期・原子置換をファイルシステムが拒否した場合は
エラーを返し、通常のコピーや未同期の保存へ切り替えません。
ファイルとディレクトリの同期には書き込み権限が必要です。

イベントログの追記と durable read は LockFileEx で全範囲を排他ロックし、
handle を閉じるまで保持します。復旧の途中で破損した末尾を読むことを防ぎ、
複数 writer が同じイベント番号を発行しません。

セッション名と PCM chunk 名には Windows と POSIX に共通の名前規則を適用します。
詳細は [storage.md](storage.md) を参照してください。

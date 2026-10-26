# 開発ルール

- 挙動、保存形式、CLI フラグ、ファイル配置を変更するコミットでは、対応する docs 内の文書を同じコミットで更新する。現行仕様を本文へ直接反映し、日付付きの追記はしない。
- 製品ルールは [docs/decisions.md](docs/decisions.md) に置く。
- 日付付きの測定記録は [docs/records/](docs/records/) に置く。
- 提案と未実装の作業は GitHub issues に置き、docs には書かない。
- 話者ラベルは Speaker 1–7、OTHER、UNKNOWN を使う。

## 絶対ルール

- 後方互換、互換性、エイリアスが明示的に必要とされていない限り、後方互換のための実装は絶対に行わない。明示的に求められない限りは必ず、実装をよりシンプルでクリーンにするための後方互換を残さない破壊的変更を行う。破壊的変更を行う際は、歴史的経緯を思わせるような痕跡すら完全に抹消する。初めからそうであったかのようにコードベースを変更する。
- 明示的な要求がない限り、互換レイヤ・silent fallback・場当たり的な代替経路を追加しないこと。
- fallback は原則的に禁止。failing fast を心がけること。安全に継続できない場合は、明確なエラーを raise すること。`os.getenv()`などにデフォルト引数を入れてフォールバックするのも厳禁。

## 検証

リポジトリのルートから実行する。

```bash
python3 -B scripts/check_portable_core.py
python3 scripts/check_doc_references.py
swift build --package-path app/MacAmbientJev
swift test --package-path app/MacAmbientJev
bash scripts/verify_v1.sh
```

Linux 評価ツールのテストは作業ディレクトリを tools 内の linux-audio にして実行する。

```bash
uv run --python 3.12 --with pytest python -m pytest -q tests
```

モデルテスト、CLI、計測の詳細は [docs/testing.md](docs/testing.md) を参照。マイク・システム音声の権限や GUI の操作確認は、ビルドと単体テストだけでは検証できない。

Windows / Linux では共通コアと評価 CLI の build・test を行い、macOS 専用の `verify_v1.sh` は Mac の CI で実行する。Windows の環境と保存規則は [docs/windows.md](docs/windows.md) を参照。Core の OS 固有 import と禁止 framework は `python3 -B scripts/check_portable_core.py` で検査する。

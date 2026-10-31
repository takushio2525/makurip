# Makurip — エージェント向けガイド

Mac 用のクリップボード履歴アプリ（メニューバー常駐）。コピーされたものを型を問わず保存し、⌃⌘V で呼び出して元のアプリへ貼り戻す。

> このリポジトリの AI 向け規約はここに集約してある。詳細仕様は `.agent/` を参照。
> ユーザー向けの説明は README.md にある。**要件の正本は `.agent/requirements.md`**。

## 概要

- 目的: Windows のクリップボード履歴に相当するものを Mac で。種類・コピー方法・コピー元で絞り込めることが売り
- 対象: 作者本人（開発・AI チャットでコピーを多用する人）
- 状況: フェーズ4（設定スキーマ・設定画面・CLI・全キー割り当て #4）まで。次は秘密の検出（#5）（`.agent/roadmap.md`）

## 技術スタック

| 領域 | 採用 | 補足 |
|---|---|---|
| 言語 | Swift 6（言語モード 6） | Xcode 26.2 / macOS 14 以降 |
| UI | AppKit（NSStatusItem・NSPanel）+ SwiftUI | メニューバー常駐（`LSUIElement`）、Dock に出さない |
| 永続化 | macOS 同梱の SQLite（C API 直叩き） | `Sources/MakuripCore/Store/SQLite.swift` の薄いラッパー |
| ショートカット | Carbon `RegisterEventHotKey` | 権限不要・任意のキーを登録できる（フェーズ4のキー割り当てに対応） |
| ビルド | SwiftPM + `scripts/build-app.sh` | .app の組み立てと署名をスクリプトで行う |
| テスト | Swift Testing（`swift test`） | |
| Lint / Format | `swift format`（ツールチェーン同梱） | 設定は `.swift-format` |
| コードの色付け | 自前の簡易な字句解析（`Sources/MakuripCore/Syntax/`） | Highlightr・tree-sitter と比べて採らなかった（`.agent/architecture.md` の「技術選定（フェーズ3）」）。⌘Y のコードは NSTextView で描く |
| 定型文 | データフォルダの `snippets.json` + ファイルの監視（`Sources/MakuripCore/Snippets/`） | 履歴の DB とは別（上限・消去で消えない）。検証は `SnippetCollection.normalize` の 1 か所。履歴の SQLite に表を足す案と比べた（`.agent/architecture.md` の「技術選定（フェーズ7）」） |
| 設定 | データフォルダの `settings.json` + ファイルの監視（`Sources/MakuripCore/Settings/`） | スキーマ・検証は Core の 1 か所。画面・CLI（`--settings`）が同じ関数を通す。UserDefaults・分散通知と比べた（`.agent/architecture.md` の「技術選定（フェーズ4）」） |
| キーの記録 | 自前（窓の `NSEvent` ローカル監視 → `SettingsModel.record`） | KeyboardShortcuts（sindresorhus）は記録欄の見た目が試作の「新しいキーを押す…」と違い、依存も増えるので採らなかった |

**外部ライブラリは 0**。入れる場合は採用理由と比べた代替を PR とこの表に書く。
技術選定で比べた代替（XcodeGen・GRDB・SwiftData・KeyboardShortcuts など）は `.agent/architecture.md` の「技術選定」節。

## ディレクトリ規約

```
makurip/
├── Package.swift
├── Sources/
│   ├── MakuripCore/   ← UI に依存しない本体（モデル・判定・取り込み・書き戻し・ストア・検索・絞り込み・キーマップ・位置・候補窓の流れ・コードの言語と色付けの区間・プロンプト・設定のスキーマ・ファイル・CLI・定型文）。AppKit は NSPasteboard だけ使う
│   ├── MakuripUI/     ← 一覧（案 B のパネル・⌘Y のプレビュー・定型文の一覧）と候補窓と設定画面と定型文の窓。Core にだけ依存する
│   ├── Makurip/       ← 実行ファイル（AppDelegate・メニューバー・ホットキー・監視・貼り付け・候補窓の横取り・設定の反映・起動引数・--settings の入口）。Info.plist もここ
│   └── MakuripDevTool/← 検証用 CLI（テストデータを書く・型の一覧を出す・一般ペーストボードの退避と復元）。.app に入れない
├── Tests/MakuripCoreTests/ ← 単体テスト。一般ペーストボードは使わず NSPasteboard(name:) を使う
├── Tests/MakuripUITests/   ← パネルのキー操作（ビューモデル）・表示の文言・オフスクリーン描画（環境変数を付けたときだけ）
├── scripts/           ← build-app.sh（組み立て・署名）/ install.sh / e2e/（隔離 E2E。settings.sh は設定）
├── docs/              ← ai-settings.md（AI エージェントに設定を頼むときの手順と、頼みと項目の対応表）
├── Resources/         ← build-app.sh が actool でコンパイルするアイコン（AppIcon.icon・Assets.xcassets の MenuBarIcon）。design/icon/ から生成
├── design/icon/       ← アイコンの原稿（SVG・icon.json）と、Resources/ の再生成・検証スクリプト（README.md に手順）
├── design/ui-compare/ ← 試作（案 B・候補窓・設定シート）と SwiftUI を並べた比較画像と、作り直すスクリプト（README.md に結果）
├── Config/            ← signing.local.env.example（雛形だけコミット。実ファイルは git 管理外）
└── .agent/            ← AI 向け詳細仕様と作業メモ
```

- `MakuripCore` に UI のコード（SwiftUI・NSWindow）を置かない。判定ロジックは純粋関数にしてここに置く
- `MakuripUI` から `Makurip`（実行ファイル側）を参照しない。本体とのやりとりは `HistoryPresenting` / `HistoryActions` / `CandidatePresenting` / `SettingsPresenting`（+ `SettingsController`）/ `SnippetEditorPresenting`（+ `SnippetController`）だけ
- 設定項目を足すときは `SettingsSchema` の 1 か所に足す（ID・型・既定値・範囲・説明・頼みの例）。画面・CLI・ファイルはそこから引く

## コマンド

| 用途 | コマンド |
|---|---|
| build（デバッグ） | `make build` |
| test | `make test` |
| lint | `make lint`（`swift format lint --strict`） |
| format | `make format` |
| .app を組み立てて署名 | `make app`（→ `.app-build/Makurip.app`） |
| 決まった場所へ入れる | `make install`（→ `~/Applications/Makurip.app`） |
| 隔離 E2E（取り込み・永続化） | `make e2e`（一般ペーストボードに触らない） |
| 隔離 E2E（設定） | `MAKURIP_APP=.app-build/Makurip.app make e2e-settings`（窓を出さない。ホットキーは使われていない組み合わせだけ） |
| 隔離 E2E（定型文） | `MAKURIP_APP=.app-build/Makurip.app make e2e-snippets`（登録・置き換え・名前付きペーストボードへの書き戻し・履歴の消去で消えないこと。窓を出さず、キーも送らない） |
| 設定の CLI | `Makurip [--data-dir DIR] --settings list\|get\|set\|add\|remove\|reset\|schema [--json]`（`docs/ai-settings.md`） |
| 試作と並べた比較画像 | `make ui-compare`（画面ロック中でも動く。出力は `.ui-compare/`） |
| 隔離 E2E（一覧・貼り付け） | `scripts/e2e/paste.sh`（画面ロック解除と Makurip のアクセシビリティ許可が要る。満たさなければ何も触らず終了コード 3/4） |
| メタデータだけ書き出す | `~/Applications/Makurip.app/Contents/MacOS/Makurip --dump-metadata [--data-dir DIR]` |

完了報告の前に `make check`（lint・ビルド・テスト）を通すこと。署名の設定は `Config/signing.local.env`（雛形を写して作る）。

## 安全規則（最重要・全フェーズ共通）

- 実際のコピー内容・実履歴の中身を、ペイン・ログ・コミット・Issue に出さない。見てよいのはメタデータ（型名・バイト数・種類・時刻）と自作のテストデータだけ
- 開発・検証は `--data-dir` で隔離したフォルダを使い、終わったら消す。既定のデータフォルダ（`~/Library/Application Support/com.takushio2525.makurip/`）を検証に使わない。設定の CLI の検証も `--data-dir` を付ける（設定ファイルはデータフォルダにある）
- UserDefaults を使うテストは `UserDefaults(suiteName:)` で分ける。`register(defaults:)` はプロセス全体で共有されるので使わない
- 隔離したインスタンスでホットキーの付け替えを試すときは、起動する前に CLI で使われていない組み合わせ（⌃⌥⇧⌘F11 など）にしておく（ほかのアプリのキーを奪わない）。ログイン時の起動は隔離中は登録しない作りにしてある
- `--debug-control`（E2E 用の遠隔操作）は `--data-dir` を指定したときしか効かない作りにしてある。この制約を外さない
- 自動テストで前面のアプリにキーを送らない（`CGEvent.post(tap:)` 禁止）。送るときは `postToPid` で宛先を固定する
- 候補窓のキーの横取り（CGEventTap）を残さない。閉じる経路を足すときは `CandidateInterceptLifetimeTests` に足す（`.agent/conventions.md` の「候補窓」）
- 一般ペーストボードを E2E で使うときは `MakuripDevTool pb-stash` で退避し、終わったら `pb-unstash` で戻す
- 検証で起動した開発用インスタンスは必ず終了する（記録係を 2 つ常駐させない）
- UI に絵文字を使わない

## AI 向け詳細仕様

必要なときだけ Read する（常時展開しない）。

- 要件の正本・決定事項: `.agent/requirements.md`
- アーキテクチャ・データモデル・技術選定: `.agent/architecture.md`
- 命名・ログ・エラー・判定の限界: `.agent/conventions.md`
- 起動引数・公開型・DB スキーマ・キーマップ: `.agent/api.md`
- 案 B の見た目と試作との差: `design/ui-compare/README.md`

### 作業履歴メモ（毎ターン参照・更新）

- タスクリスト: @.agent/roadmap.md
- 現在の作業状況（毎ターン上書き）: @.agent/activeContext.md
- 完了タスクの時系列（毎ターン追記）: @.agent/progress.md

セッション開始時に必ず読み、応答終了前に `activeContext` は最新状態で**上書き**、
作業が一段落していれば `progress` の末尾に**1〜3 行で追記**する。

## コミット規約

グローバル CLAUDE.md（`~/.claude/CLAUDE.md`）の「Git コミット」節に従う。
Issue → `feat/<番号>-説明` ブランチ → PR（`Closes #番号`）→ squash merge（`--delete-branch`）。

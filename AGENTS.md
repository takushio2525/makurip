# Makurip — エージェント向けガイド

Mac 用のクリップボード履歴アプリ（メニューバー常駐）。コピーされたものを型を問わず保存し、⌃⌘V で呼び出して元のアプリへ貼り戻す。

> このリポジトリの AI 向け規約はここに集約してある。詳細仕様は `.agent/` を参照。
> ユーザー向けの説明は README.md にある。**要件の正本は `.agent/requirements.md`**。

## 概要

- 目的: Windows のクリップボード履歴に相当するものを Mac で。種類・コピー方法・コピー元で絞り込めることが売り
- 対象: 作者本人（開発・AI チャットでコピーを多用する人）
- 状況: フェーズ2（本番 UI・絞り込み・日本語検索）まで。次は候補窓（#8）・プレビューの色付け（#3）・設定（#4）（`.agent/roadmap.md`）

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

**外部ライブラリは 0**。入れる場合は採用理由と比べた代替を PR とこの表に書く。
技術選定で比べた代替（XcodeGen・GRDB・SwiftData・KeyboardShortcuts など）は `.agent/architecture.md` の「技術選定」節。

## ディレクトリ規約

```
makurip/
├── Package.swift
├── Sources/
│   ├── MakuripCore/   ← UI に依存しない本体（モデル・判定・取り込み・書き戻し・ストア・検索・絞り込み・キーマップ・位置）。AppKit は NSPasteboard だけ使う
│   ├── MakuripUI/     ← 一覧（案 B のパネル・⌘Y のプレビュー）。Core にだけ依存する
│   ├── Makurip/       ← 実行ファイル（AppDelegate・メニューバー・ホットキー・監視・貼り付け・起動引数）。Info.plist もここ
│   └── MakuripDevTool/← 検証用 CLI（テストデータを書く・型の一覧を出す・一般ペーストボードの退避と復元）。.app に入れない
├── Tests/MakuripCoreTests/ ← 単体テスト。一般ペーストボードは使わず NSPasteboard(name:) を使う
├── Tests/MakuripUITests/   ← パネルのキー操作（ビューモデル）・表示の文言・オフスクリーン描画（環境変数を付けたときだけ）
├── scripts/           ← build-app.sh（組み立て・署名）/ install.sh / e2e/（隔離 E2E）
├── Resources/         ← build-app.sh が actool でコンパイルするアイコン（AppIcon.icon・Assets.xcassets の MenuBarIcon）。design/icon/ から生成
├── design/icon/       ← アイコンの原稿（SVG・icon.json）と、Resources/ の再生成・検証スクリプト（README.md に手順）
├── design/ui-compare/ ← 試作（案 B）と SwiftUI のパネルを並べた比較画像と、作り直すスクリプト（README.md に結果）
├── Config/            ← signing.local.env.example（雛形だけコミット。実ファイルは git 管理外）
└── .agent/            ← AI 向け詳細仕様と作業メモ
```

- `MakuripCore` に UI のコード（SwiftUI・NSWindow）を置かない。判定ロジックは純粋関数にしてここに置く
- `MakuripUI` から `Makurip`（実行ファイル側）を参照しない。本体とのやりとりは `HistoryPresenting` / `HistoryActions` だけ

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
| 試作と並べた比較画像 | `make ui-compare`（画面ロック中でも動く。出力は `.ui-compare/`） |
| 隔離 E2E（一覧・貼り付け） | `scripts/e2e/paste.sh`（画面ロック解除と Makurip のアクセシビリティ許可が要る。満たさなければ何も触らず終了コード 3/4） |
| メタデータだけ書き出す | `~/Applications/Makurip.app/Contents/MacOS/Makurip --dump-metadata [--data-dir DIR]` |

完了報告の前に `make check`（lint・ビルド・テスト）を通すこと。署名の設定は `Config/signing.local.env`（雛形を写して作る）。

## 安全規則（最重要・全フェーズ共通）

- 実際のコピー内容・実履歴の中身を、ペイン・ログ・コミット・Issue に出さない。見てよいのはメタデータ（型名・バイト数・種類・時刻）と自作のテストデータだけ
- 開発・検証は `--data-dir` で隔離したフォルダを使い、終わったら消す。既定のデータフォルダ（`~/Library/Application Support/com.takushio2525.makurip/`）を検証に使わない
- `--debug-control`（E2E 用の遠隔操作）は `--data-dir` を指定したときしか効かない作りにしてある。この制約を外さない
- 自動テストで前面のアプリにキーを送らない（`CGEvent.post(tap:)` 禁止）。送るときは `postToPid` で宛先を固定する
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

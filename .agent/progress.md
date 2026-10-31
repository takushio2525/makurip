# Progress Log

> 作業完了時に**末尾へ追記**する時系列ログ。新しいものほど下。1 エントリ 3 行以内。

## 2026-10-31（プロジェクト開始）

- リポジトリ雛形（AGENTS.md / .agent / README / .gitignore / .gitattributes）と要件の正本・ロードマップを作成
- フェーズ1 実装: 全型の取り込み・除外・上限・重複・SQLite 永続化・⌃⌘V の仮一覧・pid 宛ての貼り付け・署名と導入。単体 49 件・隔離 E2E 51 項目が緑
- 書き込み途中で読んで項目が欠ける競合を発見して修正（型の並びが落ち着くまで待つ）。GitHub への作成は権限で拒否され未実施、Issue は `.agent/issue-drafts/` に下書き
- 次: GitHub の許可 → push・起票・PR、Makurip のアクセシビリティ許可 → `scripts/e2e/paste.sh`
- master がリポジトリを作って push。Issue #1〜#9 を起票（#8 候補窓、#9 フェーズ1 の実機確認）、下書きを削除。候補窓の追加決定（カーソルの横・確定時に貼るアプリ）を要件に反映
- アイコン B の組み込み（#11）: `design/icon/` に原稿と再生成・検証スクリプト、`Resources/` に AppIcon.icon と MenuBarIcon、build-app.sh で actool → Assets.car。署名の DR は入れ直しても不変。実機のメニューバー・Dock の目視は画面ロック中で未検証（#9 に追記）

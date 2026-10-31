# .agent/ — AI 向け詳細仕様の置き場

AI（Claude Code 等）が実装中に参照する詳細仕様と作業メモ。人間向けの説明は `../README.md`。

## ファイル

### 静的な仕様

- `requirements.md` — **要件の正本**（ユーザー発言の原文・決定事項と理由）。Issue と食い違ったらこちらが正
- `architecture.md` — 全体構成・モジュールの責務・データモデル・データフロー・技術選定
- `conventions.md` — 命名・ログ・エラー・判定の限界
- `api.md` — 起動引数・公開型・DB スキーマ

### 動的な作業文脈

- `roadmap.md` — フェーズ別のタスクリスト（AGENTS.md から @import）
- `activeContext.md` — 現在の対象・次の一手（毎ターン上書き）
- `progress.md` — 完了タスクの時系列（毎ターン追記）

# Active Context

> AI が**毎ターン上書き更新**する現在状態のスナップショット。過去ログは `progress.md`。

## 現在の対象

- 何を / どこを: フェーズ1（#1）土台。実装・単体テスト・取り込みの隔離 E2E まで完了（ブランチ `feat/1-foundation`、ローカルのみ）
- ステータス: ユーザーの操作待ち（下の 2 つ）
- 最終更新: 2026-10-31

## 現フェーズで Read すべき設計書

- フェーズ1 の残り: `scripts/e2e/paste.sh`（貼り付けの E2E）・`.agent/issue-drafts/README.md`（起票の手順）
- フェーズ2 に入る人: `.agent/requirements.md` → `.agent/architecture.md`（UI の差し替え方）→ `.agent/api.md`（`HistoryPresenting`）

## 直近の観点・指摘

- 実際のクリップボードの中身をログ・ペイン・コミットに出さない（メタデータと自作データだけで検証）
- 開発・検証は `--data-dir` で隔離し、終わったら消す。キーは pid 宛てだけ
- フェーズ1 の範囲と受け入れ条件は変えない（候補窓・設定スキーマ・デザイン案 B は後のフェーズへ記録済み）

## 未解決・次の一手

- [ ] **GitHub**: リポジトリ作成・push・Issue 起票・PR が、このセッションの権限判定で拒否された（外部へのアップロード扱い）。ユーザーが許可したら: `gh repo create takushio2525/makurip --private --source . --remote origin` → main と `feat/1-foundation` を push → `.agent/issue-drafts/` の 8 本を起票（手順は同フォルダの README）→ PR（Closes #1）→ squash merge → 下書きフォルダを消す
- [ ] **アクセシビリティ**: `~/Applications/Makurip.app` を許可してもらい、画面ロックを解除した状態で `scripts/e2e/paste.sh` を実行（受け入れ条件 5・6・7。スクショは `SHOTS=` で残す）
- [ ] 物理キーでの確認（⌃⌘V で一覧が開く・⌘C がキー操作として記録される）はユーザーの手で

## 関連ファイル / リンク

- 実装: `Sources/MakuripCore/`・`Sources/Makurip/`・`Sources/MakuripUI/`・検証用 CLI `Sources/MakuripDevTool/`
- E2E: `scripts/e2e/capture.sh`（`make e2e`、51 項目）・`scripts/e2e/paste.sh`

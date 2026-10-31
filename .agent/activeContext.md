# Active Context

> AI が**毎ターン上書き更新**する現在状態のスナップショット。過去ログは `progress.md`。

## 現在の対象

- 何を / どこを: フェーズ1〜5・7 と候補窓（#8）まで main に入った。AI の口（#6）が作業中。そのあと全体の結合レビュー
- ステータス: 実機でしか確かめられない点はすべて #9 に集約（画面ロック中・アクセシビリティ未許可）。e2e-secrets の揺れは #21
- 最終更新: 2026-10-31

## 現フェーズで Read すべき設計書

- 設定を触る人: `.agent/api.md`（「設定」）→ `.agent/architecture.md`（「設定（フェーズ4）」「技術選定（フェーズ4）」）→ `docs/ai-settings.md`
- #5 に入る人: `.agent/requirements.md`（R8）→ `ClipFlag.secretLikely`・`ClipStore.setFlags`。マスクの見た目は試作 `screenshots/a-secret-reveal.png`・`candidate-secret.png`
- 見た目を触る人: `design/ui-compare/README.md`（試作との差と作り直し方。`make ui-compare`）
- #9（実機確認）: `scripts/e2e/paste.sh` と Issue #9 の手順

## 直近の観点・指摘

- 実際のクリップボードの中身をログ・ペイン・コミットに出さない（メタデータと自作データだけで検証）
- 設定項目を足すときは `SettingsSchema` の 1 か所（画面・CLI・ファイルが同じ検証を通す）。秘密の判定（#5）の閾値などを設定にするならここへ。プライバシーを守る振る舞いは設定にしない
- 設定の CLI の検証は必ず `--data-dir`（付けないと本物の設定が変わる）。隔離インスタンスでホットキーを試すときは、起動前に使われていない組み合わせにする（`scripts/e2e/settings.sh`）
- 試作が正本。勝手に「より良く」しない。変えたところは `design/ui-compare/README.md` の「意図して変えたところ」に書く

## 未解決・次の一手

- [ ] #6 AI の口（MCP / CLI。既定オフ・オンは設定画面からだけ・中身を返さない）
- [ ] #21 e2e-secrets のランダム文字列の揺れ
- [ ] 全体の結合レビュー（#2〜#8 の PR をまたいだつながり）
- [ ] #9: 許可と解除のあとに実機チェックリスト（paste.sh・候補窓・プレビュー・設定・秘密・定型文・アイコン）

## 関連ファイル / リンク

- Issue: #1〜#7 がフェーズ1〜7、#8 が候補窓、#9 が実機確認
- 設定: `Sources/MakuripCore/Settings/`・`Sources/MakuripUI/Settings*.swift`・`docs/ai-settings.md`
- E2E: `make e2e`（取り込み）・`make e2e-settings`（設定）・`scripts/e2e/paste.sh`。見比べ: `make ui-compare`

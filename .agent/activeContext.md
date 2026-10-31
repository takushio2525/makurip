# Active Context

> AI が**毎ターン上書き更新**する現在状態のスナップショット。過去ログは `progress.md`。

## 現在の対象

- 何を / どこを: フェーズ2（#2）本番 UI（案 B のパネル）・絞り込み・日本語検索・キーマップ・パネル位置の部品を実装済み
- ステータス: 実機でしか確かめられない点（位置・フォーカス・日本語入力の変換中・素材）は #9 に「未検証」として追記。次は候補窓（#8）
- 最終更新: 2026-10-31

## 現フェーズで Read すべき設計書

- 候補窓（#8）に入る人: `.agent/requirements.md`（候補窓の決定）→ `.agent/api.md`（「パネルの位置」「キーマップ」）→ `.agent/architecture.md`（一覧の部品・技術選定 フェーズ2）
- 見た目を触る人: `design/ui-compare/README.md`（試作との差と作り直し方。`make ui-compare`）
- #9（実機確認）: `scripts/e2e/paste.sh` と Issue #9 の手順

## 直近の観点・指摘

- 実際のクリップボードの中身をログ・ペイン・コミットに出さない（メタデータと自作データだけで検証）。見た目の検証は架空の履歴（`Tests/MakuripUITests/SampleHistory.swift`）
- 試作が正本。勝手に「より良く」しない。変えたところは `design/ui-compare/README.md` の「意図して変えたところ」に書く
- キーは全部 `KeyAction` から引く（ID は試作の Mk.ACTIONS と同じ）。足すときは `KeymapTests` の重なり検出が守る
- UI のテストは @MainActor。メインで重い処理をするとペーストボード監視のテストが落ちる（`.agent/conventions.md` のテスト節）

## 未解決・次の一手

- [ ] #9: 許可と解除のあとに `scripts/e2e/paste.sh` と物理キーでの確認。案 B の実機確認（位置・フォーカス・変換中・素材）も
- [ ] 候補窓（#8）: `PanelPlacement.frame(side: .beside(rowOffset:))` と `InsertionPointLocator` を使う
- [ ] フェーズ3（#3）: コードの色付け・言語名・「$ 」を外して貼る（プレビューとカードはいま等幅で出すだけ）

## 関連ファイル / リンク

- Issue: #1〜#7 がフェーズ1〜7、#8 が候補窓、#9 がフェーズ1 の実機確認（案 B の未検証点も）
- UI: `Sources/MakuripUI/`（`PanelController`・`HistoryPanelModel`・`PanelView`・`CardView`・`PeekView`・`ClipContentLoader`）
- E2E: `scripts/e2e/capture.sh`（`make e2e`、51 項目）・`scripts/e2e/paste.sh`。見比べ: `make ui-compare`

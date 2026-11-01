# Active Context

> AI が**毎ターン上書き更新**する現在状態のスナップショット。過去ログは `progress.md`。

## 現在の対象

- 何を / どこを: 計画した全機能と #35（メニューバーのアイコンがノッチの裏に隠れる不具合）の修正まで main（0a8267b）に入った。本番の ~/Applications/Makurip.app も 0a8267b で、ユーザーが 11/1 から使い始めている
- ステータス: 開いている Issue は #9（実機確認）・#35（内蔵画面での目視待ち）・#37（テストの UserDefaults の後始末）。アクセシビリティの許可が効いているかはまだ確かめていない
- 最終更新: 2026-11-01

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

- [ ] #35: 蓋を開けた内蔵画面で、入力メニューのすぐ左にアイコンが見え、押すとメニューが開くことをユーザーに見てもらったら閉じる
- [ ] #9: 画面ロックの解除とアクセシビリティの許可（ユーザータスク u-89）のあと、実機チェックリストの全 75 項目を OK / NG / 手動に分ける。paste.sh は本番の Makurip が動いていると止まるので、一時的に終了してもらう
- [ ] #37: テストが残す makurip-test-* の後始末
- 隔離インスタンスもメニューバーの位置と窓の枠を本番の UserDefaults ドメインに書く（#35 の worker が手で消した）。直すなら #37 と一緒に
- 結合レビューの報告書は git 外: ~/dev/makurip-design/review/integration-2026-10-31.md

## 関連ファイル / リンク

- Issue: #1〜#7 がフェーズ1〜7、#8 が候補窓、#9 が実機確認
- 設定: `Sources/MakuripCore/Settings/`・`Sources/MakuripUI/Settings*.swift`・`docs/ai-settings.md`
- E2E: `make e2e`（取り込み）・`make e2e-settings`（設定）・`scripts/e2e/paste.sh`。見比べ: `make ui-compare`

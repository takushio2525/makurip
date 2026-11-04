# Active Context

> AI が**毎ターン上書き更新**する現在状態のスナップショット。過去ログは `progress.md`。

## 現在の対象

- 何を / どこを: #38（カードのクリックで貼る・右クリックの操作メニュー）が main（7f92fd1）に入り、本番の ~/Applications/Makurip.app も 7f92fd1 に入れ替えた（署名の DR は不変）。リポジトリは public（MIT）
- 進行中: #43（アプリ内アップデート）と #41（Developer ID の署名・公証つきの Release・v0.1.0）を 1 人の worker が worktree `feat/43-update` で担当。Developer ID なしでできる部分を先に作り、PR まで出す
- 待ち: ユーザータスク u-92（Developer ID の証明書と notarytool のプロファイル `makurip-notary`）。これが済めば公証 → v0.1.0 の Release → 本番を Developer ID 版に入れ替える（アクセシビリティを 1 回取り直す）
- 最終更新: 2026-11-04

## 現フェーズで Read すべき設計書

- 更新と配布（#43・#41）: Issue #43・#41 の本文 → `.agent/architecture.md`（技術選定）→ `.agent/api.md`（起動引数）
- カードのクリックと右クリック: `.agent/requirements.md`（R11）→ `Sources/MakuripCore/Menu/CardMenuModel.swift`・`Sources/MakuripUI/CardMenu.swift`
- 見た目を触る人: `design/ui-compare/README.md`（試作との差と作り直し方。`make ui-compare`）
- #9（実機確認）: `scripts/e2e/paste.sh` と Issue #9 の手順

## 直近の観点・指摘

- 実際のクリップボードの中身をログ・ペイン・コミットに出さない（メタデータと自作データだけで検証）
- リポジトリは public。Team ID・証明書の名前・Apple ID・メール・実名・ホームパスをコミット・PR・Release のノートに書かない
- `make e2e-click` は NSMenu を開くので、使っている人のクリックを 1 回吸う。ユーザーが操作している間は回さない
- v0.1.0 は #9 を待たずに出す（11/4 ユーザー「ガンガン進めちゃって」）
- 試作が正本。勝手に「より良く」しない。変えたところは `design/ui-compare/README.md` の「意図して変えたところ」に書く

## 未解決・次の一手

- [ ] u-92 が済んだら、#43/#41 の worker に段 B（Developer ID の 2 版で更新の E2E → merge → v0.1.0 → 本番の入れ替え）を頼む
- [ ] 本番でカードのクリック・右クリックをユーザーに試してもらう（本物のアプリへの貼り付けとトラックパッドは #9）
- [ ] #35: 内蔵画面で、入力メニューの左にアイコンが見えてメニューが開くことをユーザーに見てもらったら閉じる
- [ ] #9: アクセシビリティの許可（Developer ID 版に入れ替えたときにまとめる）のあと、実機チェックリストを OK / NG / 手動に分ける
- [ ] #37: テストが残す makurip-test-* の後始末（隔離インスタンスが本番の UserDefaults ドメインに書く件も）

## 関連ファイル / リンク

- Issue: #1〜#7 がフェーズ1〜7、#8 が候補窓、#9 が実機確認、#38 がクリックと右クリック、#41 が配布、#43 が更新
- E2E: `make e2e`・`make e2e-settings`・`make e2e-secrets`・`make e2e-snippets`・`make e2e-ai`・`make e2e-click`・`scripts/e2e/paste.sh`
- 検証のスクショ（git 外）: ~/dev/makurip-design/verify/2026-11-04/

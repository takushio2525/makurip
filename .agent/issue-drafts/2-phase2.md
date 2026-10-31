[フェーズ2] 本番 UI・絞り込み・日本語検索

## 目的
ユーザーが選んだデザイン案（`~/dev/makurip-design/` で別の worker が試作中）どおりに、一覧を作り直す。「UIとかはカナリこだわって すごく使いやすくして欲しい」（ユーザー原文）。

詳細は `.agent/requirements.md` を正とする。

## デザイン（2026-10-31 ユーザーが決定）
- UI は**案 B**: カーソル横に出す小さめのパネル（Windows の Win+V 型）。上のタブで種類を切り替えるカード一覧、⌘Y で大きいプレビュー。試作は `~/dev/makurip-design/ui/b.html`
- アイコンは**案 B「パラパラ」**（付箋の束を扇形にめくる）。原稿と書き出しは `~/dev/makurip-design/icon/`。組み込みはフェーズ1 のマージ後に別の担当者が行う
- カーソル横に出す位置決め（AX の `AXSelectedTextRange` → `AXBoundsForRange`、取れないアプリはマウス位置）は、候補窓（#8）と共通の部品にできる

## 範囲
- `Sources/MakuripUI/` を丸ごと差し替える（`HistoryPresenting` / `HistoryActions` を実装し、`HistoryUIFactory.make(actions:)` を用意すれば本体は変えなくてよい）
- 絞り込み: どうコピーしたか（キー操作 / コピーボタン等）・種類（テキスト / リッチテキスト / 画像 / ファイル / URL / 色 / コード / コマンド / その他）・コピー元のアプリ。データはフェーズ1 で記録済み
- 日本語に強い検索: ひらがなとカタカナ、全角と半角を区別しない。「kopi」のようなローマ字で「コピー」を引ける
- アイコンの差し替え（「メモをめくる」イメージ）
- E2E（`scripts/e2e/paste.sh`）が使う `debugState` の `rowCount` / `query` と `-MakuripPanelScreen` を新しい UI でも保つか、スクリプトを直す

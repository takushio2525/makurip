[フェーズ2] 本番 UI・絞り込み・日本語検索

## 目的
ユーザーが選んだデザイン案（`~/dev/makurip-design/` で別の worker が試作中）どおりに、一覧を作り直す。「UIとかはカナリこだわって すごく使いやすくして欲しい」（ユーザー原文）。

詳細は `.agent/requirements.md` を正とする。

## 範囲
- `Sources/MakuripUI/` を丸ごと差し替える（`HistoryPresenting` / `HistoryActions` を実装し、`HistoryUIFactory.make(actions:)` を用意すれば本体は変えなくてよい）
- 絞り込み: どうコピーしたか（キー操作 / コピーボタン等）・種類（テキスト / リッチテキスト / 画像 / ファイル / URL / 色 / コード / コマンド / その他）・コピー元のアプリ。データはフェーズ1 で記録済み
- 日本語に強い検索: ひらがなとカタカナ、全角と半角を区別しない。「kopi」のようなローマ字で「コピー」を引ける
- アイコンの差し替え（「メモをめくる」イメージ）
- E2E（`scripts/e2e/paste.sh`）が使う `debugState` の `rowCount` / `query` と `-MakuripPanelScreen` を新しい UI でも保つか、スクリプトを直す

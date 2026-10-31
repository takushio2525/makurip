[フェーズ3] 開発向けのプレビュー

## 目的
差別化 2・4（`.agent/requirements.md`）。画像やコードを大きくプレビューでき、開発・AI チャット向けに使いやすくする。

詳細は `.agent/requirements.md` を正とする。

## 範囲
- 画像・コードの大きなプレビュー、コードの色付け
- コマンドの先頭の「$ 」を外して貼る
- 取れる場合はコピー元のページを出す（`ClipItem.sourceURL`。Chromium 系と WebKit のみ取れる）
- データは `ClipStore.snapshot(id:)`（全型）と `representationInfos(id:)`（型の一覧）で取れる

# Issue の下書き（起票したら消す）

GitHub への起票（リポジトリ作成を含む）がこのセッションの権限で通らなかったので、本文をここに置いてある。
起票の順番が Issue 番号になる（1〜7 がフェーズ1〜7、8 が候補窓）。1 行目がタイトル、2 行目以降が本文。

```bash
for f in .agent/issue-drafts/[0-9]*.md; do
  gh issue create --repo takushio2525/makurip --title "$(head -n 1 "$f")" --body "$(tail -n +3 "$f")" --label enhancement
done
```

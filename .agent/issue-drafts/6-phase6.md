[フェーズ6] AI 用の口（CLI / MCP）

## 目的
差別化 6。「AIから，履歴に追加とか，そういう系はできて欲しいかな」「AIから中の文は見れずに，形式だけ調査して」（ユーザー原文）。

詳細は `.agent/requirements.md` を正とする。

## 範囲
- AI から履歴への追加はできる（`CapturedClip` を組み立てて `ClipStore.save`、`ClipFlag.addedByAI` の印）
- AI には中身を見せず、形式の情報だけを渡す（`MetadataDump` 相当: 種類・型名・バイト数・時刻）
- 秘密の判定はアプリの中で形式から行う（フェーズ5）

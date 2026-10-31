[フェーズ4] 設定画面と全操作のキー割り当て

## 目的
差別化 3。「キーとかも好きに色々設定できるように」（ユーザー原文）。

詳細は `.agent/requirements.md` を正とする。

## 範囲
- 設定画面（件数・容量の上限、除外するアプリなど。既定値は `Limits.default`）
- すべての操作のキーを割り当て直せる。既定の ⌃⌘V は Clipy の「履歴を開く」と同じなので変えられるようにする
- グローバルショートカットは `HotKey`（仮想キーコード + 修飾キー、Codable）と `HotKeyCenter`（Carbon `RegisterEventHotKey`。任意の組み合わせを登録できる）で用意済み。キーを記録する UI を足す（KeyboardShortcuts ライブラリは記録 UI 付きの候補。入れるなら理由と代替を PR と AGENTS.md に書く）

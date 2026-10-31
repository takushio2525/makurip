# 規約（命名・ログ・エラー・テスト・判定の限界）

## 命名

| 対象 | 規則 | 例 |
|---|---|---|
| ファイル | 中心の型の名前（PascalCase） | `ClipStore.swift` |
| 型 | PascalCase | `PasteboardSnapshot` |
| 関数・変数 | camelCase | `acknowledgeOwnWrite` |
| DB の表・列 | snake_case | `last_used_at` |
| 起動引数 | `--kebab-case` | `--data-dir` |
| 分散通知（検証用） | `com.takushio2525.makurip.debug.<命令>` | `...debug.toggleHistory` |

UI に出す文言は日本語。絵文字は使わない。

## ログ（最重要: 中身を書かない）

- `os.Logger`（サブシステム = バンドル ID、カテゴリ `app` / `capture` / `paste`）
- 書いてよいのは **メタデータだけ**: 種類・コピー方法・型の数・バイト数・スキップの理由・結果
- **平文・データ・プレビュー・コピー元ページの URL は書かない**。`privacy: .public` を付けるのはメタデータの値だけ
- 見るとき: `log stream --predicate 'subsystem == "com.takushio2525.makurip"' --info`

## エラー

- ストア・SQLite は `throws`（`SQLiteDatabase.Failure`）。呼ぶ側（アプリ）はログに残して続ける。起動時に開けなければ終了する
- 取り込みの失敗は `PasteboardMonitor.Event.failed` で返す（落とさない）

## テスト

- 単体テストは Swift Testing（`@Test` / `#expect`）。`swift test` で全部回る
- **一般ペーストボードを使わない**。`NSPasteboard(name:)` に一意な名前を付け、終わったら `releaseGlobally()`
- ストアのテストは一時フォルダ（`TemporaryDirectory`）。既定のデータフォルダに触らない
- テストデータは自作（`Tests/MakuripCoreTests/Fixtures.swift`・`MakuripDevTool pb-write`）
- E2E（`scripts/e2e/`）は `--data-dir` で隔離し、終わったら消す。起動したインスタンスは必ず終了させる

## 判定の限界（正直に書く）

### 種類（`KindClassifier` / `TextHeuristics`）

経験則なので、次は見分けられない・間違えうる。

- **短い断片**: 「`x = 1`」のような 1 行は、手がかりが 2 つ以上ないとコードにならない。逆に「`a == b`」を含む文章はコードになりうる
- **コードを含む Markdown**: 途中に ``` がある文書はテキスト扱い（AI チャットの回答をまるごとコピーした場合など）。全体が ``` で囲まれていればコード
- **コマンド**: 先頭の語が既知の CLI の一覧（`TextHeuristics.knownCommands`）にあるか、行頭が `$ ` `% ` `❯ ` のときだけ。一覧にない自作のツールは「テキスト」になる。プロンプトの `# `（root）は Markdown の見出しと区別できないので見ない
- **リッチテキスト**: RTF・HTML の型が載っているかで決める。VS Code やターミナルは色付きの RTF/HTML も載せるが、中身がコード・コマンドならそちらを優先する。整形のない文章でも RTF を載せるアプリ（Pages 等）はリッチテキストになる
- **画像と文章が両方あるとき**: Office は文章にプレビュー画像（PNG/PDF）を添えるので、文章があればリッチテキスト。平文が URL かパスだけなら画像（ブラウザの「画像をコピー」）
- **PDF だけ**: 画像として扱う（種類に PDF がないため）
- **色**: 色の型（`com.apple.cocoa.pasteboard.color`）か、`#RRGGBB` / `rgb()` / `hsl()` の 1 語だけ。色名（`red`）は色にしない
- **ファイル**: `file://` の URL があれば何があってもファイル（Finder はアイコン画像と名前の平文も載せるため）

### コピー方法（`CopyMethodClassifier`）

- **キー操作の判定にはアクセシビリティの許可が要る**。許可がないあいだは全部「不明」（「それ以外」と混ぜない）
- ⌘C を押したが何もコピーされず、1 秒以内にボタンでコピーすると「キー操作」になる
- ⌘C から 1 秒より遅れてペーストボードに書くアプリは「それ以外」になる
- ⌘C を他のキーに割り当てているアプリ、メニューの「コピー」をマウスで選んだ場合は「それ以外」（正しい）
- 自動操作（他のプロセスが `postToPid` で送った ⌘C）はグローバル監視に見えないので「それ以外」
- セキュア入力中（パスワード欄など）はキーが見えない（その場合、コピー自体もふつう ConcealedType が付く）
- ⌃ を伴う ⌃⌘C などは別の操作とみなす

### 取り込み（`PasteboardMonitor`）

- ペーストボードには変化の通知がないので 0.25 秒おきに見る。**それより速く上書きされたコピーは最後の 1 回だけ**になる（上書きされた中身は読みようがない）。書き込みが落ち着くまで 0.08 秒待つので、0.3 秒より短い間隔の連続コピーはまとまる
- コピー元のアプリは「変化を見つけた時点で前面にいたアプリ」（⌘C のときは押した瞬間）。コピーしてすぐ別のアプリへ切り替えると、切り替え先になることがある。バックグラウンドのアプリが書いた場合も前面のアプリになる
- 遅延で渡すデータ（promise）は読んだ時点で書き手に作らせる。書き手が終了していると読めない型は落ちる
- 同じ内容の判定は「全項目・全型のデータが同じ」（コピーのたびに変わる付随情報の型は除く。`PasteboardMarkers.volatileTypePrefixes`）。同じ文字列でもコピー元のアプリが違って型の組が違えば別の履歴になる
- コピー元ページの URL は Chromium 系（`org.chromium.source-url`）と WebKit の webarchive だけ。Firefox・コピーボタン（`navigator.clipboard.writeText`）は取れない

### 貼り付け（`Paster`）

- ⌘V は仮想キーコード 9 + 文字 "v" で送る。⌘V を別のキーに割り当てているアプリでは貼れない
- 元のアプリが終了していたら ⌘V は送らない（ペーストボードには載っている）

# 起動引数・公開型・DB スキーマ

## 起動引数（`Sources/Makurip/LaunchOptions.swift`）

`open -n ~/Applications/Makurip.app --args ...` か、実行ファイルを直接起動して渡す。
**アクセシビリティの許可は `open` で起動したときに Makurip 自身に付く**（ターミナルから実行ファイルを直接起動すると、許可の判定はターミナル側になる）。

| 引数 | 意味 |
|---|---|
| `--data-dir PATH` | データフォルダを指定する（検証用に隔離）。環境変数 `MAKURIP_DATA_DIR` でも同じ。既定は `~/Library/Application Support/com.takushio2525.makurip/` |
| `--pasteboard-name NAME` | 一般ペーストボードの代わりに名前付きペーストボードを監視・書き戻しする（E2E 用） |
| `--dump-metadata` | 保存済み項目のメタデータだけを JSON で標準出力に書いて終わる。中身（平文・データ）は出さない。UI もロックも使わないので、動いているインスタンスがあっても読める |
| `--debug-control` | E2E 用の遠隔操作を受け付ける。**`--data-dir` を指定したときだけ有効**（既定のデータフォルダでは無視してログに残す） |
| `-MakuripPanelScreen NAME` | 一覧と候補窓を出す画面を名前で固定する（UserDefaults の引数ドメイン。E2E が仮想ディスプレイに出すため）。指定すると文字カーソルの位置は使わず、その画面の下寄りの中央に出す |
| `--settings <命令> ...` | 設定の CLI（下の「設定」）。後ろの引数は `--data-dir` を除いてすべて CLI に渡す。UI もロックも使わないので、動いているインスタンスがあっても使える |
| `--mcp` | AI の口の MCP サーバー（標準入出力の JSON-RPC。下の「AI の口」）。UI もロックも使わない。標準入力が閉じたら終わる。`--pasteboard-name` を付けるとクリップボードに置く先もそれになる |
| `--ai <命令> ...` | AI の口の CLI（MCP と同じ道具。下の「AI の口」）。後ろの引数は `--data-dir`・`--pasteboard-name` を除いてすべて CLI に渡す |
| `--update <命令> ...` | アップデートの CLI（`status` / `check` / `apply`。下の「アップデート」）。後ろの引数は `--data-dir`・`--update-feed`・`--update-allow-unnotarized` を除いてすべて CLI に渡す。AI の口からは呼べない |
| `--update-feed URL` | 版を問い合わせる先（Release の一覧の JSON。`file://`・`http(s)://`・パス）を差し替える。**`--data-dir` を指定したときだけ有効**（アプリはログに残して無視、CLI の `check`・`apply` は止める）。E2E 用 |
| `--update-allow-unnotarized` | 公証のない版も入れる。**`--data-dir` と `--update-feed` がそろったときだけ有効**（署名・チーム・要件の確かめは外れない）。Developer ID がない間の E2E 用 |

~~`-hotkeyMode paste|candidate|list` ほか（候補窓の設定を UserDefaults の引数ドメインで起動のときだけ上書き）~~ は #4 でなくした。
隔離したインスタンスの設定は、起動する前に `Makurip --data-dir DIR --settings set ...` で書く。

同じデータフォルダを 2 つのインスタンスが使おうとすると、後から起動した方が終了する（`instance.lock` の flock）。

### 検証用の遠隔操作（`--debug-control`）

分散通知 `com.takushio2525.makurip.debug.<命令>`、object = データフォルダの絶対パス（標準化したもの）。
送るのは `MakuripDevTool notify --data-dir DIR <命令> [--pid PID] [--index N] [--mode M] [--action 操作ID]`。

| 命令 | 動き |
|---|---|
| `toggleHistory` | 一覧を開く / 閉じる（メニューの「履歴の一覧を開く」と同じ） |
| `pressOpenKey` | ⌃⌘V を押したのと同じ（動きは `hotkeyMode`。既定は候補窓。許可がなければ一覧を開く） |
| `pressOpenListKey` | ⌃⌥⌘V を押したのと同じ |
| `simulateCopyShortcut` | ⌘C を見たときと同じ信号を入れる |
| `setPasteTarget` | 貼り付けの宛先を pid で固定する（固定した pid のアプリが無ければどこにも貼らない。ユーザーの前面のアプリへは落とさない） |
| `pause` / `resume` | 記録の一時停止 / 再開 |
| `checkForUpdates` | アップデートを確かめる（メニューの「アップデートを確認…」と同じ。結果の窓は出さず、状態の `update` に書く。#43） |
| `installUpdate` | 見つけた新しい版に入れ替えて起動し直す（メニューの「アップデートして再起動」と同じ。失敗の窓は出さない） |
| `skipUpdate` | 見つけた新しい版を知らせないようにする（メニューの「この版は知らせない」と同じ） |
| `pasteSnippet` | 定型文を貼る（一覧の ↩ と同じ処理）。`userInfo["index"]` は 1 からの番号、`["mode"]` は `normal` / `plainText` / `copyOnly`（既定 `normal`）。番号の外は何もしない |
| `clearHistory` | 履歴を消去する（メニューの「履歴を消去…」の確かめの後と同じ。ピン留めと定型文は残る） |
| `enableAIAccess` / `disableAIAccess` | AI の口をオン / オフにする（設定画面の切り替えと同じ。`--debug-control` は隔離したときだけ効くので、本物の履歴の口は開けられない） |
| `copyMCPRegisterCommand` | 設定画面の「登録コマンドをコピー」と同じ（監視しているペーストボードに書く。新しい履歴にならないことを `make e2e-ai` が確かめる） |
| `openSnippetList` | 一覧を定型文の表示で開く（メニューの「定型文の一覧を開く」と同じ） |
| `clickCard` / `clickCardReleaseOutside` | 一覧のカードを左クリックする / 押したままカードの外へ出て離す（#38）。`userInfo["index"]` は上から 1 始まり。窓の中で作った出来事をパネルへ送る（本物のマウスとほかのアプリには触れない）。作られていないカード（見えていない）は何もしない |
| `rightClickCard` | 一覧のカードを右クリックしてメニューを出し（`index` は同上）、`userInfo["hold"]` 秒後（既定 1。0.5〜5）に `userInfo["action"]`（キーマップの操作 ID。`paste`・`copyOnly` など）の項目を選ぶ。`action` が無ければ何も選ばずに閉じる。**メニューを開いている間は分散通知が届かない**（メニューの追跡中は主スレッドが通知を受けない）ので、選ぶのも、選ぶ前（`hold` の 6 割の時点）に状態を書くのも、メニューの中でも回るタイマーで行う |
| `scrollCards` | 一覧のカードの上で下へスクロールする（`index` のカードの真ん中で当たるビューへ、ホイールの出来事を渡す。カードに重ねた NSView が一覧のスクロールへ流すかを見る） |
| `panelKeyFocusOff` / `panelKeyFocusOn` | 一覧がキーの焦点を取らない / 取る（既定は取る）。取らないと、出しても使っている人の打鍵を横取りせず、外の操作（ほかの窓のクリック）でも閉じない。E2E を人が Mac を使っている間に回すため |
| `writeStatus` | 状態を `<データフォルダ>/debug-status.json` に書く（設定ファイルから読み直したときも自動で書く） |
| `quit` | 終了する |

`debug-status.json` の鍵: `pid`・`accessibilityTrusted`・`keyMonitorActive`・`hotKeys`・`pasteboard`・`paused`・`itemCount`・`historyVisible`・`historyUI`（`query`・`rowCount`・`loadedCount`・`selectedIndex`・`selectedKind`・`selectedSecret`・`revealing`・`windowNumber`・`kindFilter`・`methodFilter`・`appFilter`・`pinnedOnly`・`previewOpen`・`pickerOpen`・`anchor`・`menuOpen`・`menuOpenCount`・`menuItems`（開いているカードのメニューの「操作 ID=文言(キー)」を `|` でつないだもの。区切りは `-`）・`menuLastRow`（直近にメニューを出したカードの番号。1 始まり）・`firstVisibleRow`（見えているいちばん上のカードの番号）・`listScrollY`（カードの一覧のスクロールの位置。pt）・`lastScrollHit`（検証用のスクロールが当たったビューの型の名前）・`panelKey`（一覧がいまキーの焦点を持っているか）・`takesKeyFocus`）・`candidate`（`active`・`tapActive`・`method`・`index`・`count`・`order`・`tentative`・`note`・`lastEnd`・`revealed`・`selectedSecret`・`candidateAnchor`・`candidateFirstRow`）・`pasteTargetOverride`・`lastPasteOutcome`（`pasted` / `noPermission` / `noTarget` / `copied`）・
`lastHotKeyRoute`（直近に押した呼び出しキーの振り分け）・`openKeyRoute`（いま呼び出しキーを押したらどうなるか。押さずに `HotKeyRouter.route` で計算した値: `startCandidate` / `pasteLatest` / `openList` / `closeList` / `expandCandidate`）・
`storeLimits`（`maxItems`・`maxTotalBytes`。ストアに当たっている上限）・`candidateHotKeyMode`（候補窓の流れが持っている呼び出しキーの動き）・
`secrets`（`count` 秘密の件数・`knownFormat` 自動消去の対象の件数・`autoDeleted` 起動してから自動で消した件数・`retentionSeconds`・`nextSweepAt` 次に消す時刻。中身は出さない）・
`settings`（`hotkeyMode`・`candOrder`・`maxItems`・`maxTotalMB`・`keys.open`・`keys.openList`・`excludedApps` の値（JSON の文字列）と `reloadCount`・`issueCount`・`watching`）・`settingsVisible`・
`snippets`（`count`・`reloadCount`・`issueCount`・`watching`・`editorVisible`・`dateFormat`・`lastPasteLength`（直近に書き戻した文字の長さ。UTF-16）・`lastCursorOffsetFromEnd`。中身は出さない。秘密の形の値を含んだときはどちらも `"hidden"`）・
`ai`（`enabled` AI の口がオンか・`externalHistoryChanges` MCP・CLI が履歴を変えたと知らされた回数・`activityCount` AI の操作の記録の件数・`lastTool`・`lastOutcome`。#6）・
`statusItem`（`autosaveName`・`visibility`（`visible` / `behindNotch` / `unknown`）・`seededPosition` 今回の起動で保存位置の種をまいたか。#35）・
`update`（`currentVersion`・`phase`（`idle` / `checking` / `installing:<段>` / `failed`）・`availability`（`upToDate` / `available` / `skipped`）・`latestVersion`・`skippedVersion`・`lastCheckedAt`・`lastError`・`autoCheck`・`timerActive`・`feedOverridden`・`notarizationRequired`・`installable`。版と結果だけで、署名の中身は出さない。#43）・`writtenAt`。
`historyUI` には `showsSnippets`・`snippetCount` もある。

`anchor` はパネルを出した手がかりの種類（`caret` 文字カーソル / `field` 入力欄の枠 / `mouse` マウス / `screen` 画面の指定）。座標は出さない。

## メタデータの書き出し（`--dump-metadata`）

```json
{
  "itemCount": 2,
  "schemaVersion": 2,
  "items": [{
    "id": "UUID", "kind": "image", "copyMethod": "keyboard",
    "sourceBundleID": "com.apple.Preview", "sourceName": "プレビュー", "sourceURLHost": null,
    "createdAt": "ISO8601", "lastUsedAt": "ISO8601", "copyCount": 1, "pinned": false, "flags": [],
    "totalBytes": 32264,
    "pasteboardItems": [[{"type": "public.png", "bytes": 1234, "storage": "inline"}]]
  }, {
    "id": "UUID", "kind": "text", "copyMethod": "button",
    "sourceBundleID": "com.google.Chrome", "sourceName": "Google Chrome", "sourceURLHost": "console.example.com",
    "createdAt": "ISO8601", "lastUsedAt": "ISO8601", "copyCount": 1, "pinned": false,
    "flags": ["secretKnownFormat", "secretLikely"], "size": "hidden",
    "pasteboardItems": [[{"type": "public.utf8-plain-text", "storage": "inline"}, {"type": "org.chromium.source-url", "storage": "inline"}]]
  }]
}
```

新しい順（`lastUsedAt` の降順）。`sourceURLHost` はホスト名だけ（クエリに秘密が入りうるため）。
`flags` に `secretLikely`（秘密っぽい）・`secretKnownFormat`（確度が高い。自動消去の対象）が入る（#5）。`schemaVersion` は DB の版（いまは 2）。

AI の口の門の外（シェルを使えるエージェントなら、口がオフでも実行できる）なので、中身を推せる値は出さない（#23）。
内容のハッシュはどの項目にも出さない（短い秘密は、推した値のハッシュと照らして当てられる。1 回の書き出しの中では、同じ内容の項目はもともと 1 つ）。
秘密の項目（`secretLikely`）は `totalBytes` と型ごとの `bytes` を出さず `size: "hidden"`（AI の口の `list_history` と同じ）。

## UI との約束（`Sources/MakuripCore/Support/HistoryPresenting.swift`）

```swift
@MainActor public protocol HistoryPresenting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func show(selecting itemID: UUID?)            // 候補窓から広げたとき。既定の実装は show()
    func showSnippets()                           // 定型文の表示で開く（メニューの「定型文の一覧を開く」）。既定の実装は show()
    func hide()
    func historyDidChange()
    var debugState: [String: String] { get }   // 既定は空
    func keymapDidChange(_ keymap: Keymap)        // 設定でキーが変わった（既定は何もしない）
    func snippetsDidChange()                      // 定型文が変わった（開いていれば読み直す。既定は何もしない）
    func debugPerform(_ request: HistoryDebugRequest) // 検証用（.click(row:releaseInside:) / .rightClick(row:choose:hold:) / .scroll(row:) / .takesKeyFocus。既定は何もしない）
}

@MainActor public protocol HistoryActions: AnyObject {
    func historyItems(limit: Int) -> [ClipItem]
    func paste(itemID: UUID)                      // UI は先に自分を閉じてから呼ぶ
    func paste(itemID: UUID, mode: PasteMode)     // .normal / .plainText（文字の型だけ。プロンプトは外さない）/ .copyOnly（⌘V を送らない）。中身は PastePipeline.prepare
    func historyDidClose()                        // 貼らずに閉じたとき（元のアプリへフォーカスを返す）
    func setPinned(_ pinned: Bool, itemID: UUID)
    func delete(itemID: UUID)
    func representationInfos(itemID: UUID) -> [RepresentationInfo]          // サムネイル・プレビューで読む型を選ぶ
    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data?  // 型 1 つのデータ（UI の中だけで使う）
    func openSettings()                           // 一覧の ⌘,（UI は先に閉じる）
    func snippets() -> [Snippet]                  // 定型文（一覧の順）
    func pasteSnippet(id: UUID, mode: PasteMode)  // 差し込みを置き換えて貼る（UI は先に閉じる）。履歴には足さない
    func openSnippetEditor(_ request: SnippetEditRequest)  // 定型文の窓（.open / .edit(id) / .new(body:) / .fromHistory(itemID)）
    func snippetDateFormat() -> SnippetDateFormat // {{日付}} の書き方（⌘Y の説明に使う）
}
// paste(itemID:) と historyItems・historyDidClose 以外は既定の実装（何もしない・空）がある

@MainActor public protocol SnippetEditorPresenting: AnyObject {
    var isVisible: Bool { get }
    func show(_ request: SnippetEditRequest)      // メニューの「定型文を編集…」・一覧の ⇧⌘S
    func close()
}
public struct SnippetEditorEnvironment { dateFormat: () -> SnippetDateFormat }

@MainActor public protocol SettingsPresenting: AnyObject {
    var isVisible: Bool { get }
    func show()                                   // メニューの「設定…」・一覧の ⌘,
    func close()
    func environmentDidChange()                   // ホットキーの登録の成否などが変わった
}
public struct SettingsEnvironment {               // 設定画面が本体に聞くこと
    appName: (String) -> String?                  // バンドル ID → 表示名
    hotKeyRegistered: (KeyAction) -> Bool?        // どこからでも効くキーを登録できたか
    launchAtLoginNote: () -> String?              // ログイン項目の注記
    recordingDidChange: (Bool) -> Void            // キーの記録中は本体がホットキーを外す
}

// MakuripUI 側の入口（差し替えた UI も同じ名前で用意する）
public enum HistoryUIFactory { @MainActor static func make(actions: HistoryActions, keymap: Keymap) -> HistoryPresenting }
public enum CandidateUIFactory { @MainActor static func make(actions: HistoryActions, keymap: Keymap) -> CandidatePresenting }
public enum SettingsUIFactory { @MainActor static func make(controller: SettingsController, environment: SettingsEnvironment) -> SettingsPresenting }
public enum SnippetEditorUIFactory { @MainActor static func make(controller: SnippetController, environment: SnippetEditorEnvironment) -> SnippetEditorPresenting }
```

`CandidatePresenting` にも `keymapDidChange(_:)`（既定は何もしない）がある。`CandidateCoordinator.keymap` を変えると窓にも伝わる。

## キーマップ（`Sources/MakuripCore/Keymap/Keymap.swift`）

全操作は `KeyAction`（ID・既定のキー・説明文・まとまり・範囲）から定義する。ID は試作（`core.js` の `Mk.ACTIONS`）と同じ。
設定スキーマは操作ごとに `keys.<ID>` の項目を作り、設定画面・CLI・MCP（#6）がこの ID と説明文をそのまま使う。重なりは `Keymap.conflicts()` で見つける（全体のキーとパネルのキーは同じ範囲として見る）。
キーは物理キーの位置（仮想キーコード）で持つ（`KeyCombo`。`.digits` は 1〜9 の範囲、`.hold` は修飾キー 1 つを押している間。
`.hold` はキーを押しても操作として引かず、`Keymap.isHeld(_:modifiers:)` で修飾キーの状態から見る。文字では `⌥`・`alt` と書く）。

| ID | 操作 | 既定のキー | 範囲 |
|---|---|---|---|
| `open` | 履歴を呼び出す（どこからでも）。動きは `hotkeyMode` | ⌃⌘V | 全体 |
| `openList` | 一覧を開く（どこからでも） | ⌃⌥⌘V | 全体 |
| `close` | 検索を消す／閉じる | esc | パネル |
| `prev` / `next` | 前の項目 / 次の項目 | ↑・⌃P / ↓・⌃N | パネル |
| `paste` / `pastePlain` / `copyOnly` | 貼り付け / プレーンテキストで / コピーだけ | ↩ / ⇧↩ / ⌘↩ | パネル |
| `quick` | 番号の項目をすぐ貼り付け | ⌘1–9 | パネル |
| `kindNext` / `kindPrev` | 種類：次へ / 前へ | ⇥ / ⇧⇥ | パネル |
| `method` | コピー方法を切り替え（すべて → キー操作 → ボタンなど） | ⌘K | パネル |
| `app` | コピー元アプリを選ぶ | ⌘E | パネル |
| `pinned` / `pin` | ピン留めだけ表示 / ピン留めする・外す | ⇧⌘P / ⌘P | パネル |
| `snippets` | 定型文を表示（もう一度で履歴に戻る） | ⌘S | パネル |
| `look` | 大きくプレビュー | ⌘Y | パネル |
| `reveal` | 隠した内容を表示（押している間）。一覧・プレビュー・候補窓で効く | ⌥（押している間） | パネル |
| `source` | コピー元のページを開く | ⌘O | パネル |
| `delete` | 履歴から削除 | ⌘⌫ | パネル |
| `settings` | 設定を開く | ⌘, | パネル |
| `editSnippet` | 定型文を編集（定型文の一覧）／選んだ履歴から登録（履歴の一覧）。試作に無い | ⇧⌘S | パネル |
| `candUp` / `candDown` | 上の候補へ / 下の候補へ（ターミナル式では ↑ が古いほう） | ↑ / ↓ | 候補窓 |
| `candCommit` | 確定（改行や送信はしない） | ⇥・↩ | 候補窓 |
| `candCancel` | 取り消し（貼る前に戻す） | esc | 候補窓 |
| `candExpand` | 一覧に広げる | ⌃⌘V | 候補窓 |

候補窓の範囲のキーは候補窓が出ている間だけ効くので、候補窓のキーどうしだけで重なりを見る（⌃⌘V が `open` と `candExpand` の両方にあるのはこのため）。
候補窓の間に全体のキー（⌃⌘V・⌃⌥⌘V）が来たら、タップは素通しして Carbon のホットキーに任せ、`HotKeyRouter` が「広げる」に振り分ける。
一覧のカードの右クリックのメニュー（#38）の項目は、`paste`・`pastePlain`・`copyOnly`・`pin`・`editSnippet`・`look`・`source`・`delete` の操作そのもので、
選ぶとそのキーを押したのと同じ処理を通す（`HistoryPanelModel.performMenuAction`）。並びと出し分けは `CardMenuModel`（`Sources/MakuripCore/Menu/`。
文字の有無・ページの有無・ピン留めの状態・秘密）、右に添えるキーはいまのキーマップの先頭の割り当てを `KeyCombo.menuKeyEquivalent` で NSMenu の表記にしたもの
（↩・⌫・矢印・F キーも出せる。数字の範囲と修飾キーだけのキーは書けないので添えない）。カードのクリックで貼るのは `paste`（↩）と同じ処理。
隠した内容の表示（⌥）は #5 で足した。定型文の一覧では `kindNext`・`kindPrev`・`method`・`app`・`pin`・`delete` は効かない（試作と同じ）。キーとして使える組み合わせの決まりは `KeyRules`（下の「設定」）。

## 候補窓（`Sources/MakuripCore/Candidate/`・#8）

| 型 | 役割 |
|---|---|
| `CandidateCoordinator` | 流れ全体（始める・↑↓・確定・取り消し・広げる・閉じる経路すべて）。`start()`・`pasteLatest()`・`perform(_:)`・`frontmostAppDidChange(pid:)`・`environmentDidChange()`・`shutdown()` |
| `CandidateSession` / `CandidateLayout` | 並び（ターミナル式・予測変換式）と選択 / 寸法・見えている 8 行・選んだ行までの距離（純粋関数） |
| `ReplacePlanner` | 差し替え方式の決め方・貼った範囲の測り方・⌘Z で戻ったかの判定（純粋関数） |
| `ComposingState` | 変換中の判定（AX の未確定の範囲 → 入力ソース。判定できなければ `.unknown`） |
| `HotKeyRouter` | ⌃⌘V・⌃⌥⌘V の振り分け（`HotKeyMode` と、候補窓・一覧が出ているか） |
| `CandidateSettings` / `DeferredPasteApps` | 設定（`AppSettings.candidate` から作る）/ 確定まで貼らないアプリの既定の一覧 |
| `FocusedText` | 入力欄の選択範囲・文字数・未確定の範囲を AX で読み、選択範囲を書く（入力欄の文字は読まない） |
| `KeyTapInput` | タップに届いた CGEvent を値にする（Makurip が送った印 `SyntheticEventMarker` の付いたキーは素通し） |

差し込み（テストでは偽物）: `CandidateHost`（前面のアプリ・AX・ペーストボードの控えと戻し・pid 宛てのキー・ストア）・
`CandidatePresenting`（窓。`present`・`dismiss`・`bump`・`contains(screenPoint:)`・クリックの知らせ）・
`KeyEventTapping`（横取り。本番は `Sources/Makurip/KeyEventTap.swift`）・`CandidateScheduling`（無操作の時計）。

### 候補窓の設定

設定ファイルの項目（下の「設定」）。ID は試作の `Mk.PREFS` と同じで、UserDefaults の時代（#8）のキーとも同じ名前。
`hotkeyMode`（`paste` / `candidate` / `list`）・`candOrder`（`terminal` / `ime`）・`candPasteTiming`（バンドル ID → `immediate` / `onCommit`。既定の一覧より優先）・
`candReplaceMethod`（バンドル ID → `selectRange` / `undo` / `deferred`。自動の判定より優先）・`candIdleTimeout`（2〜120 秒）。
`defaults write` で書いた値は、既定のデータフォルダで最初に起動したとき（か CLI を使ったとき）に設定ファイルへ引き継ぎ、UserDefaults からは消す。

## 設定（`Sources/MakuripCore/Settings/`・#4）

| 型 | 役割 |
|---|---|
| `SettingsSchema` | 項目の一覧（`SettingItem`: ID・まとまり・名前・説明・型・頼みの例・詳細か・画面に出すか・既定の一覧）と、値の読み書き・**検証の 1 か所**（`validate`・`applying(_:to:in:keyConflicts:)`） |
| `KeyRules` | キーとして使える組み合わせ（範囲ごと）。使えなければ理由の文 |
| `KeyComboText` | キーの文字表現（`⌃⌘V`・`ctrl+cmd+v`・`⌘1–9` を読み、画面の表記で書く） |
| `AppSettings` | 値の型付きの形。`limits`（`Limits`）・`candidate`（`CandidateSettings`）・`keymap`・`globalHotKey(_:)` を作る。既定値は `Limits.default`・`CandidateSettings.default`・`KeyAction.defaultCombos` から |
| `SettingsFile` | `<データフォルダ>/settings.json` の読み書き（純粋関数の `decode`・`encode` と、置き換えで書く `save`） |
| `SettingsMigration` | UserDefaults の永続ドメインから引き継ぐ（設定ファイルがないときに 1 回だけ。既定のデータフォルダのときだけ） |
| `SettingsController` | 動いているアプリの設定。ファイルの監視（フォルダとファイルの DispatchSource）で読み直し、変わったら `observe` の相手に知らせる。画面からの `set`・`reset`・`resetAll` もここ |
| `SettingsApplier` / `SettingsApplying` | 変わった部分だけを反映先（`AppController`）へ渡す（上限・記録しないアプリ・どこからでも効くキー・キーマップ・候補窓の設定・ログイン時の起動） |
| `SettingsCLI` | `--settings` の本体（純粋。`run(_:) -> Output`） |

### 設定ファイル

```json
{
  "formatVersion" : 1,
  "settings" : {
    "hotkeyMode" : "paste",
    "keys.open" : [ "⌥V" ]
  }
}
```

- 既定と違う値だけを書く。キーは名前の順。置き換えで書く（読む側が書きかけを見ない）
- 知らない項目は読み飛ばし、書き戻すときに残す。値が検証に通らない項目は既定に戻し、理由（`issues`）を画面と `list` に出す
- JSON として読めないときはすべて既定で動き、次に書くときに `settings.broken.json` へ退避する
- 重なったキーもそのまま読む（拒否するのは CLI と画面で入れるとき）

### 項目

| ID | 型 | 既定 | 範囲・値 |
|---|---|---|---|
| `hotkeyMode` | 選択肢 | `candidate` | `paste` / `candidate` / `list` |
| `candOrder` | 選択肢 | `terminal` | `terminal` / `ime` |
| `launchAtLogin` | オン・オフ | false | 変えたときだけ `SMAppService.mainApp` に登録・解除（隔離中はしない） |
| `maxItems` | 整数 | 1000 | 10〜20000 件 |
| `maxTotalMB` | 整数 | 1024 | 100〜20480 MB（「2GB」とも書ける） |
| `secretAutoDeleteMinutes` | 整数 | 10 | 1〜1440 分（「1時間」とも書ける）。確度の高い秘密を、最後に使ってからこの時間で消す。「消さない」はない（ピン留めで残す） |
| `excludedApps` | バンドル ID の並び | なし | 前面にあるときのコピーはデータを読まずに捨てる（`SkipReason.excludedApp`） |
| `candPasteTiming` | バンドル ID → 選択肢 | なし | `immediate` / `onCommit`（既定の一覧は `builtIn`） |
| `candIdleTimeout` | 数（詳細） | 10 | 2〜120 秒 |
| `candReplaceMethod` | バンドル ID → 選択肢（詳細・画面に出さない） | なし | `selectRange` / `undo` / `deferred` |
| `snippetDateFormat` | 選択肢 | `slash` | `slash`（2026/10/31）/ `hyphen`（2026-10-31）/ `japanese`（2026年10月31日）。定型文の `{{日付}}` |
| `autoUpdateCheck` | オン・オフ | true | 起動したときと 1 日 1 回、GitHub の Release を確かめる（#43。知らせるだけで入れ替えない）。変えたらその場で時計を掛ける・止める（`SettingsApplying.applyAutoUpdateCheck`） |
| `keys.<操作 ID>` | キーの並び | `KeyAction.defaultCombos` | `KeyRules` に通るもの。どこからでも効くキーは 1 つだけ。空の並びで未設定。`keys.reveal` は修飾キー 1 つだけ |

### CLI（`Makurip [--data-dir DIR] --settings ...`）

`schema` / `list` / `get <ID>` / `set <ID> <値>...` / `add <ID> <値>` / `remove <ID> <値>` / `reset <ID>... | --all` / `path` / `help`。
`--json` で機械向け、`--take-over` で重なった操作から外して付け替える。終了コード: 0 成功・1 使い方の誤り・2 検証に通らない・3 書けない。
`schema --json` の形: `guide`（AI 向けの案内）・`command`・`settingsFile`・`keyFormat`・`items[]`（`id`・`section`・`group`・`label`・`description`・`type`・
`default`・`current`・`choices[]`・`min`/`max`/`step`/`unit`・`keyScope`・`builtIn[]`・`examples[]`（`request`・`value`・`command`・`note`）・`advanced`・`shownInSettingsWindow`）。
AI 向けの手順と頼みの対応表は `docs/ai-settings.md`。

## 検索と絞り込み（`Sources/MakuripCore/Search/`）

| 型 | 役割 |
|---|---|
| `SearchText.normalize(_:)` | NFKC → 小文字 → カタカナをひらがな → NFC（照合用） |
| `SearchText.romajiToKana(_:)` / `parse(_:)` | ローマ字の読み / 検索欄の文字列を語（AND）と候補（元の綴り・読み）に分ける |
| `SearchQuery` | `matches(normalized:)`（UTF-8 のバイト列で探す）・`highlightRanges(in:)`（元の文字列での一致範囲） |
| `HistoryFilter` | 種類（nil はすべて）・`CopyMethodFilter`・アプリ（バンドル ID か名前）・ピン留め・検索語。`apply`・`kindCounts`・`appOptions` |

## コードの言語・色付け・プロンプト（`Sources/MakuripCore/Syntax/`・`Paste/`・フェーズ3）

どれも純粋関数。位置は UTF-16 で数える（`NSRange` にそのまま使える）。

| 型 | 役割 |
|---|---|
| `CodeLanguage` | 18 の言語（`displayName` は画面に出す名前。シェルだけ「シェル」）。`init?(fenceTag:)` で ```swift などの別名から引く |
| `CodeLanguageDetector.detect(_:)` | 言語（決まらなければ nil）。コードブロックの言語名 → shebang → JSON・XML・HTML・YAML の形 → 言語ごとの手がかりの点数 |
| `SyntaxHighlighter.tokens(in:language:)` | 色を付ける区間 `[SyntaxToken]`（`location`・`length`・`kind`）。重ならず、順に並ぶ。`kind` は `keyword` / `string` / `comment` / `number` / `type` / `function` / `attribute` / `flag`（試作の `.s-*`）。言語が nil なら文字列・数・コメントだけ |
| `ShellPrompt.analyze(_:)` | `Analysis`: 外すプロンプトの範囲（`promptRanges`）・コマンドの行（`commandLineRanges`）・外した文字列（`stripped`） |
| `ShellPrompt.explicitPromptLength(_:)` | 1 行の頭のはっきりしたプロンプトの長さ（`$ `・PS1 など。root の `# ` と続き行の `> ` は文脈で決めるので見ない）。種類の判定でも使う |
| `PastePipeline.prepare(_:kind:mode:)` | 貼るときにペーストボードへ書く中身。`.plainText` は文字の型だけ、`.normal`・`.copyOnly` はコマンドなら文字の型だけプロンプトを外す（UTF-16 は BOM と並びを保つ） |
| `PastePipeline.candidatePaste(_:kind:)` | 候補窓から貼る中身と、入力欄に増える文字の長さ（`PastedContent`。外した後の文字で数える） |

UI 側（`Sources/MakuripUI/`）: `ClipContentLoader.language(for:)`（一覧の平文から 1 回だけ判定してキャッシュ）・`codeCardLines`・`commandCard`・`commandPreview`・
`cachedCodeTokens` / `codeTokens`（長いものは裏で作る）・`CodeStyler`（AttributedString / NSAttributedString にする）・`CodeTextView`（⌘Y のコード）・
`DisplayText.sourcePage(_:)`（コピー元のページの「ホスト・パス」。http・https でホストがあるときだけ・クエリは出さない）。

## 定型文（`Sources/MakuripCore/Snippets/`・#7）

| 型 | 役割 |
|---|---|
| `Snippet` / `SnippetDraft` | 1 件（id・名前・略語・本文・作った時刻・変えた時刻）/ 登録・編集で入れる値 |
| `SnippetCollection` | 並び（= 一覧の順・⌘1〜9 の順）と `add`・`update`・`remove`・`move(id:to:)`・`move(id:by:)`。**検証は `normalize` の 1 か所**（本文が空・空白だけ・10 万文字超・名前 100 文字超・略語に空白・32 文字超は不可。名前が空なら本文の 1 行目）。上限 5000 件 |
| `SnippetTemplate` | 差し込み（`SnippetPlaceholder`: `{{日付}}`・`{{クリップボード}}`・`{{言語}}`・`{{カーソル}}`）の読み取り（`segments`・`placeholderRanges`・`placeholders`）と置き換え（`expand(_:context:) -> Expansion`: 文字と、カーソルから末尾までの長さ） |
| `SnippetDateFormat` | `{{日付}}` の書き方（西暦で固定。和暦の環境でも 2026） |
| `SnippetClipboard` | `{{クリップボード}}` に使う履歴（新しい順で、文字として差し込める種類・`secretLikely` でないもの）と `{{言語}}`（コードは判定・コマンドはシェル・ほかは空） |
| `SnippetPaste` | 書き戻す中身（文字の型 UTF-8 だけ）・`{{カーソル}}` へ動かす先（`cursorTarget`。貼る前後の入力欄を AX で読めて、カーソルがちょうど貼った文字の後ろにあるときだけ） |
| `SnippetFile` | `<データフォルダ>/snippets.json` の読み書き（純粋関数の `decode`・`encode` と、置き換えで書く `save`。読めない項目・ファイルは `snippets.broken.json` に退避してから書き直す） |
| `SnippetController` | 動いているアプリの定型文。ファイルの監視で読み直し、変わったら `observe` の相手に知らせる。窓からの `add`・`update`・`remove`・`move` もここ（AI の口 #6 も使える） |

### 定型文のファイル

```json
{
  "formatVersion" : 1,
  "snippets" : [
    { "abbr" : ";date", "body" : "{{日付}}", "createdAt" : "2026-10-31T06:30:00Z",
      "id" : "…", "name" : "今日の日付", "updatedAt" : "2026-10-31T06:30:00Z" }
  ]
}
```

- `body` だけが必須（`name` が空なら本文の 1 行目、`id`・日時がなければ読んだときに作る。`id` が重なれば作り直す）
- 履歴（`history.sqlite`）とは別のファイル。履歴の上限・消去・削除では消えない
- 差し込みの記法: `{{名前}}`（中の前後の空白は無視）。知らない名前・閉じていない・中に改行・名前が 24 文字を超えるものは書いたままの文字

UI 側（`Sources/MakuripUI/`）: `SnippetCardView`・`SnippetPeekContent`（パネルの定型文）・`SnippetBodyText`（本文を TextKit で組む。行の高さを CSS と同じに固定し、差し込みは札の画像）・
`SnippetEditorModel` / `SnippetEditorView` / `SnippetEditorWindowController`（定型文の窓）。

## パネルの位置（`Sources/MakuripCore/Placement/`）

| 型 | 役割 |
|---|---|
| `InsertionPointLocator.locate(pid:)` | 前面のアプリの文字カーソル（`AXSelectedTextRange` → `AXBoundsForRange`）、取れなければ入力欄の枠（`AXPosition` + `AXSize`）。AX の座標のまま返す。許可がない・取れないときは nil |
| `PanelPlacement.frame(size:anchor:screens:side:mouse:)` | 手がかり（`PanelAnchor`: 文字カーソル → 入力欄の枠 → マウス → なし）から窓の枠を決める。`.below` はカーソルの下（入らなければ上。案 B）、`.beside(rowOffset:)` はカーソルの右（候補窓 #8） |
| `PanelPlacement.peekFrame(panel:width:screens:)` | ⌘Y のプレビューの枠（右に入らなければ左） |
| `PanelPlacement.appKitRect(fromAX:primaryScreenHeight:)` | AX の座標（左上原点）を AppKit の座標（左下原点）へ |

## メニューバーの項目とメニュー（`Placement/StatusItemPlacement.swift`・`Menu/StatusMenuModel.swift`・#35）

macOS は新しい状態の項目をいちばん左に置くので、ノッチのある内蔵画面でメニューバーが混んでいると、ノッチの裏や左に押し出されて描かれない。
そこで項目を作る前に、保存位置（UserDefaults の `NSStatusItem Preferred Position <保存名>`）が**まだ無いときだけ** `StatusItemPlacement.seedPosition`（1000）を書く。
値が大きいほど左で、システムの項目は 100〜400 台。1000 は「保存位置のない他社アプリの項目の右・システムの項目の左」に入る（macOS 26 の実測）。
利用者が ⌘ を押しながらドラッグして動かすと macOS が同じ鍵を書き換えるので、以後はそちらを使う（種は 2 度まかない）。

| 型・値 | 役割 |
|---|---|
| `StatusItemPlacement.autosaveName(isolated:)` | 保存名。本番は `MakuripStatusItem`、隔離したインスタンスは `MakuripStatusItemIsolated`。UserDefaults はバンドル ID ごとで `--data-dir` では分かれないので、名前を分けて本番の位置に触れない（隔離の検証を流すと、この鍵が 1 つだけ本番のドメインに残る） |
| `StatusItemPlacement.positionToSeed(saved:)` | 保存位置が無ければ種の値、あれば nil |
| `StatusItemPlacement.visibility(itemFrame:screenFrame:rightOfNotchWidth:)` | 項目の窓がノッチの右の領域（`auxiliaryTopRightArea` の幅を画面の右端から取る）に収まっているか。`visible` / `behindNotch` / `unknown`（ノッチのない画面）。遮蔽状態は画面ロック中に当てにならないので使わない。起動の 1 秒後にログ（「メニューバーの項目 visibility=…」）と `debug-status.json` の `statusItem` に出す |
| `StatusMenuModel.entries(_:)` | メニューの並び。新しい版があれば先頭に知らせ（「新しい版 vX.Y.Z があります（今は vA.B.C）」・アップデートして再起動・この版は知らせない。#43）／履歴の一覧を開く（`keys.openList`）・定型文の一覧を開く（`keys.snippets`。一覧を定型文の表示で開く）・定型文を編集…（`keys.editSnippet`）・設定…（`keys.settings`）・アップデートを確認…（確かめている間は押せない）／記録を一時停止（再開）・履歴を消去…／アクセシビリティを許可…（許可がないときだけ）・状態の行／終了（⌘Q）。右のキーはいまのキーマップから引き、1 文字で書けないキーはヒントにだけ出す |

アイコンが隠れていても画面へ行けるように、動いている Makurip をもう一度開く（Spotlight・Finder・`open`）と設定を開く（`applicationShouldHandleReopen`）。

## ストア（`ClipStore`）

| メソッド | 役割 |
|---|---|
| `save(_:) -> SaveResult` | 保存。同じハッシュがあれば `.movedToTop`（回数 +1）、なければ `.inserted`。最後に上限を当てる |
| `touch(id:at:)` | Makurip から貼ったとき先頭へ移す（回数・コピー元・方法は変えない） |
| `items(limit:)` / `item(id:)` / `count()` | メタデータを新しい順に読む |
| `snapshot(id:)` | 全項目・全型のデータ（貼り直し用） |
| `representationInfos(id:)` | 型の一覧（中身なし） |
| `data(id:itemIndex:type:)` | 型 1 つのデータ（一覧のサムネイル・プレビュー用。全型を読む `snapshot` より軽い） |
| `setPinned(_:id:)` / `setFlags(_:id:)` / `delete(id:)` / `clearUnpinned()` | 編集 |
| `limits` / `setLimits(_:)` | いまの上限 / 上限を変える（下げたら超えた古い履歴をその場で消す。設定から） |
| `enforceLimits()` / `removeOrphanBlobs()` | 上限の当て直し・保存途中で落ちた残りの掃除（起動時に呼ぶ） |

## 秘密（`Sources/MakuripCore/Secret/`・#5）

どれも純粋関数（`SecretRescan` だけストアを読み書きする）。判定の一覧と限界は `.agent/conventions.md` の「秘密の判定」。

| 型 | 役割 |
|---|---|
| `SecretDetector.findings(in:)` | 文字列の中の秘密（`SecretFinding`: `kind`・UTF-16 の `location`/`length`・見せてよい接頭辞と末尾の長さ）。重ならない・位置の順。`version` は判定の版 |
| `SecretKind` | 当たった形式（`anthropicKey`・`githubToken`・`privateKey`・`authorizationHeader`・`passwordAssignment`・`randomToken` など）。`confidence`（`.high` / `.medium`）と画面の理由（`reason`。「API キーの形式」） |
| `SecretScanner.assess(_:)` | スナップショット（全項目の平文・ファイルと URL の文字列・平文がなければ RTF/HTML）の判定。`SecretAssessment`（確度・形式・付ける印 `flags`） |
| `SecretMask.masked(_:)` / `apply(_:to:)` | 伏せ字にした文字列（`sk-test-••••••••••••••••0000`） |
| `PreviewText.make(…, maskSecrets:)` | 一覧用の平文。秘密なら全文を伏せてから先頭を切る |
| `SecretExpiry` | 自動消去の決まり（`isEligible`・`deadline`・`expired`・`nextDeadline`。既定 `defaultMinutes` = 10） |
| `SecretRescan.runIfNeeded(store:)` | 判定の版が上がったとき、既存の履歴に 1 回だけ当て直す（`meta` の `secretScanVersion`） |

`ClipItem.isSecretLikely`・`PastePipeline.prepare(…, secret:)`（ConcealedType の印を足す）・`CandidateViewState.revealed`・
`KeyTapEvent.flagsChanged`（候補窓の間の修飾キー。食べずに素通し）。ストアは `items(flagged:)`・`addFlags(_:maskedPreview:id:)`・
`snapshot(id:types:)`・`delete(ids:)`・`scrubDeletedData()`（WAL の切り詰め）・`metaValue` / `setMetaValue` を足した。

## AI の口（`Sources/MakuripCore/AI/`・#6）

利用者・AI 向けの案内（登録・頼みと道具の対応・限界）は `docs/ai-mcp.md`。

| 型 | 役割 |
|---|---|
| `AIAccess` | オン・オフ（DB の `meta` の `aiAccess` = `on` / `off`、`aiAccessChangedAt`）。DB がなければオフ。`setEnabled(true, …)` を呼ぶのは設定画面の配線（と隔離時の遠隔操作）だけ。`looksLikeGateID` は設定の CLI・道具で「設定画面からだけ」と答える ID |
| `AIGateway` | 履歴の操作（`add`・`list`・`deleteSecrets`・`delete`・`status`・`disable`）。毎回 DB のオン・オフを読む。上限は設定ファイルの値。書いたら `historyDidChange` |
| `AIHistoryFilter` / `AISecretFilter` | 一覧と削除の条件（ids・種類・秘密・AI が足したか・ピン留め・最後に使ってからの分数・コピー元アプリ） |
| `AITools` | 道具の一覧（`tools`。MCP の tools/list）・引数の検証（`Arguments`。知らない引数は誤り）・実行・記録。設定の道具は `SettingsCLI` を `--json` で通す。定型文の道具は `AISnippetTools.swift` |
| `MCPServer` / `MCPLineReader` | JSON-RPC 2.0（1 行 1 件）。`handle(_:)` は 1 行 → 1 行（通知は nil）。読み取りは `read(2)` で届いた分だけ（入力を開いたまま待つ相手と互いに待たないため）。1 件 128 MB まで |
| `AICLI` | `--ai` の CLI。フラグを道具の引数（JSON）に組み直して `AITools` を呼ぶ |
| `AIActivityLog` / `AIActivityEntry` | 操作の記録（データフォルダの `ai-activity.jsonl`。1 行 1 件・`flock`・500 件を超えたら古いものから捨てる・0600）。メタデータだけ |
| `HistoryChangeSignal` | 分散通知 `com.takushio2525.makurip.historyDidChange`（履歴が変わった）と `…aiActivity`（記録が増えた）。object はデータフォルダの標準化したパス |
| `AppPresence` | 同じデータフォルダで Makurip が動いているか（`instance.lock` を共有のロックで試す） |
| `AIClientName` | MCP の相手の名前（短く切って制御文字を除く）。一覧のコピー元アプリは「AI（名前）」 |

道具（MCP の名前。CLI の命令）: `status`（`status`）・`add_to_history`（`add`）・`list_history`（`list`）・`delete_secrets`（`delete-secrets`）・
`delete_history`（`delete`）・`add_snippet`（`snippet-add`）・`list_snippets`（`snippets`）・`delete_snippets`（`snippet-delete`）・
`settings_schema`・`settings_list`・`settings_get`・`settings_set`・`settings_reset`（CLI は `--settings`）。CLI だけ: `log`・`disable`（`enable` は拒否）。
履歴と定型文の道具と、設定を変える `settings_set`・`settings_reset`（`destructiveHint: true`）は AI の口がオンのときだけ（オフは `aiAccessDisabled`。#26）。
設定を読む `settings_schema`・`settings_list`・`settings_get` と `status` はいつでも。
`add_to_history` の結果の `result` は、人のコピーには合流しないので、AI が前に足した同じ内容があったときだけ `movedToTop`（ほかは `inserted`。#24）。

MCP の応答: 成功は `result.content[0].text`（`structuredContent` の 1 行の JSON）・`structuredContent`・`isError: false`。
道具の失敗は `isError: true`・`structuredContent`（`error`: `aiAccessDisabled` / `invalidArguments` / `settingsRejected` / `unavailable`・`message`）。
JSON-RPC の誤り: -32700（JSON でない）・-32600（形の誤り・大きすぎる）・-32601（知らない method）・-32602（知らない道具・params の形の誤り）。
`initialize` は相手の版が `MCPServer.supportedProtocolVersions`（2025-11-25・2025-06-18・2025-03-26・2024-11-05）にあればそれで、なければいちばん新しい版で答える。

`list_history` の 1 件の鍵: `id`・`kind`・`kindLabel`・`createdAt`・`lastUsedAt`・`copyCount`・`copyMethod`・`pinned`・`addedByAI`・`truncated`・`pasteboardItems`・
`types`・`sourceApp`（`bundleID`・`name`）・`sourcePageHost`・`language`・`languageLabel`・秘密なら `secret`（`level` high/medium・`formats[]`（`id`・`label`）・`autoDelete`）と
`size: "hidden"`、秘密でなければ `totalBytes`・（1 MB 以下の平文なら）`characters`・`lines`。中身・平文・URL・ファイル名・ハッシュの鍵はない（`AIListTests` が守る）。
`list_snippets` の 1 件も同じく、秘密っぽければ `characters`・`lines` を入れず `size: "hidden"`（`AISnippetSizeTests`）。

AI がクリップボードにも置くときは `PasteboardMarkers.savedByMakuripAI`（`com.takushio2525.makurip.saved-by-ai`）の型を足し、
監視は `SkipReason.savedByAI` で取り込まない（保存は済んでいる）。秘密っぽいものは ConcealedType も足す。
本体: `AppController.observeAIGateway`（知らせを受けて一覧の読み直し・秘密の自動消去の掛け直し）・`setAIAccess`・`mcpRegisterCommand`。
設定画面: `SettingsEnvironment.aiAccess`（`AIAccessEnvironment`）→ `SettingsModel.aiAccessRowID` の行（`SettingsAIAccessRow`）。

## アップデート（`Sources/MakuripCore/Update/`・#43）

確かめと入れ替えの本体（`Updater`）は Core に置き、アプリ（`Sources/Makurip/UpdateController.swift`）と `--update` の CLI が同じものを使う。
守ることと限界は `.agent/conventions.md` の「アップデート」、配布物の決まりは「版と配布」。

| 型 | 役割 |
|---|---|
| `AppVersion` | 版（`X.Y.Z`・`vX.Y.Z`。数 3 つだけ）。比べられる。`tag` は `vX.Y.Z` |
| `ReleaseFeed` | GitHub の `GET /repos/{owner}/{repo}/releases`（か `/releases/latest` の 1 件）の読み取り。draft・prerelease・tag の形が違うもの・添付（`Makurip-X.Y.Z.zip` と `.sha256`）がそろわないもの・アップロードの途中のものを除き、新しい版の順に `UpdateRelease` を返す |
| `UpdateRelease` / `ReleaseAsset` | 入れられる Release（版・tag・ページ・zip・sha256 のファイル）/ 添付 1 つ（名前・URL・大きさ・GitHub の digest の sha256） |
| `UpdateAvailability` | `upToDate` / `available(release)` / `skipped(release)`（「この版は知らせない」） |
| `UpdateChecksum` | sha256 のファイルの 1 行（`<64 桁の 16 進>  Makurip-X.Y.Z.zip`）の読み取りと、ファイルの sha256 |
| `UpdateSource` | 配信元。本番は GitHub（`production`）。差し替えは `resolve(override:isolated:)` で隔離したときだけ。`allowsDownload(from:)` は本番ならこのリポジトリの Release のダウンロードの場所だけ |
| `UpdatePolicy` | 確かめの方針。本番はいつも公証まで（`production`）。公証だけを外せるのは隔離・差し替え・`--update-allow-unnotarized` がそろったとき |
| `CodeSignature` / `CodeIdentity` | .app の署名の読み取り（Security.framework。バンドル ID・版・チーム ID・designated requirement・署名の可否・公証）と、要件を満たすかの確かめ |
| `UpdateVerification.check` | 入れ替えてよいかの判断（純粋関数。署名 → バンドル ID → チーム → 要件 → 公証 → 版） |
| `UpdateTransport` / `URLSessionUpdateTransport` | 問い合わせとダウンロード（GET だけ・ephemeral。`file://` は差し替えた配信元のときだけ届く） |
| `Updater` | `fetchLatest`・`check(running:)`（結果を `update-state.json` に書く）・`install(_:replacing:running:progress:)`（落とす → sha256 → 展開 → 署名 → 置き換え。段は `Updater.Step`） |
| `UpdateStateFile` / `UpdateState` | `<データフォルダ>/update-state.json`（`lastCheckedAt`・`latest`・`skippedVersion`・`lastError`）。設定ではない |
| `UpdateStatus` / `UpdateEnvironment` | メニューと設定画面に出す状態と文言 / 設定画面の「アップデート」の行が本体に頼むこと（確認・入れ替え・知らせない） |
| `UpdateCLI` | `--update` の本体 |
| `UpdateInstalledSignal` | 分散通知 `com.takushio2525.makurip.updateInstalled`（object = データフォルダ）。`--update apply` が入れ替えたら送り、動いている Makurip がディスクの版を見て起動し直す |

アプリ側: `UpdateController`（自動の確認の時計・手での確認・入れ替え・`open -n -g` で起動し直す sh・知らせの受け取り・結果の窓）、
`LaunchOptions.relaunchArguments`（起動し直すときに渡す引数）、`BlockingTask`（CLI で async を待つ）。

### CLI（`Makurip [--data-dir DIR] [--update-feed URL] --update status|check|apply [--json]`）

| 命令 | 動き | `--json` の鍵 |
|---|---|---|
| `status` | 今の版・置き場所（置き換えられるか）・自動の確認・配信元・最後に確かめた結果（問い合わせない） | `currentVersion`・`appPath`・`installable`・`installBlockedReason`・`autoCheck`・`feed`（`github` / `overridden`）・`notarizationRequired`・`lastCheckedAt`・`latestVersion`・`available`・`skippedVersion`・`lastError` |
| `check` | Release に新しい版があるかを確かめる（入れ替えない） | `result`（`upToDate` / `available` / `skipped`）・`currentVersion`・`latestVersion`・`available` |
| `apply` | 新しい版があれば入れ替える（「この版は知らせない」でも入れる）。同じデータフォルダで Makurip が動いていれば `UpdateInstalledSignal` で起動し直してもらう | `result`（`installed` / `upToDate` / `failed`）・`version`・`previousVersion`・`relaunching`、失敗は `error`（`UpdateFailure.code`）・`message` |

終了コード: 0 成功（新しい版がないときも）・1 使い方の誤り（`--data-dir` なしの `--update-feed` での `check`・`apply` を含む）・2 確かめに通らないので入れ替えなかった・3 通信やファイルの失敗。
進み具合（「ダウンロード…」など）は標準エラーに 1 行ずつ。

## DB スキーマ（版 2・`PRAGMA user_version = 2`）

```sql
CREATE TABLE clip (
  id TEXT PRIMARY KEY,                 -- UUID
  content_hash TEXT NOT NULL UNIQUE,   -- SHA-256（同じ内容の判定）
  kind TEXT NOT NULL,                  -- ClipKind.rawValue
  copy_method TEXT NOT NULL,           -- CopyMethod.rawValue
  source_bundle_id TEXT, source_name TEXT,
  source_url TEXT,                     -- コピー元ページ（取れたときだけ）
  created_at REAL NOT NULL,            -- 1970 年からの秒
  last_used_at REAL NOT NULL,          -- 並びのキー
  copy_count INTEGER NOT NULL DEFAULT 1,
  pinned INTEGER NOT NULL DEFAULT 0,
  flags TEXT NOT NULL DEFAULT '[]',    -- ClipFlag.rawValue の JSON 配列
  preview_text TEXT,                   -- 一覧・絞り込み用の平文（先頭 1000 文字）
  total_bytes INTEGER NOT NULL,
  item_count INTEGER NOT NULL
);
CREATE INDEX clip_last_used ON clip(last_used_at DESC);
-- preview_text は、秘密（flags に secretLikely）なら伏せ字にしたもの（#5）

CREATE TABLE representation (
  clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
  item_index INTEGER NOT NULL,         -- NSPasteboardItem の順
  position INTEGER NOT NULL,           -- その項目の中の型の順
  type TEXT NOT NULL,
  byte_count INTEGER NOT NULL,
  inline_data BLOB,                    -- 64 KB 以下はここ
  blob_file TEXT,                      -- それより大きいものは blobs/ からの相対パス
  PRIMARY KEY (clip_id, item_index, position)
);

-- 版 2（#5）: 小さな覚え書き。key = 'secretScanVersion'（既存の履歴に当て直した判定の版）
-- #6 で key = 'aiAccess'（'on' / 'off'。AI の口）・'aiAccessChangedAt'（切り替えた時刻）を足した（表は変えていないので版は 2 のまま）
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

MCP・`--ai` の CLI のプロセスと動いているアプリは、同じ DB を別の接続で読み書きする（WAL・`busy_timeout` 2 秒・複数の文をまとめて書く操作は `BEGIN IMMEDIATE`）。

`PRAGMA secure_delete = ON`（消した行をファイルの上でも 0 で上書きする）。秘密を消したあとは `wal_checkpoint(TRUNCATE)` で WAL を空にする。

データフォルダ: `history.sqlite`（+ `-wal` / `-shm`）・`blobs/<履歴ID>/<項目>-<順>.bin`・`instance.lock`・`settings.json`（+ 壊れていたときの `settings.broken.json`）・`snippets.json`・`ai-activity.jsonl`（AI の操作の記録）・`update-state.json`（最後に確かめた時刻・見つけた最新の Release・「この版は知らせない」の版。#43）・（検証時のみ）`debug-status.json`。

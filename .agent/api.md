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

~~`-hotkeyMode paste|candidate|list` ほか（候補窓の設定を UserDefaults の引数ドメインで起動のときだけ上書き）~~ は #4 でなくした。
隔離したインスタンスの設定は、起動する前に `Makurip --data-dir DIR --settings set ...` で書く。

同じデータフォルダを 2 つのインスタンスが使おうとすると、後から起動した方が終了する（`instance.lock` の flock）。

### 検証用の遠隔操作（`--debug-control`）

分散通知 `com.takushio2525.makurip.debug.<命令>`、object = データフォルダの絶対パス（標準化したもの）。
送るのは `MakuripDevTool notify --data-dir DIR <命令> [--pid PID]`。

| 命令 | 動き |
|---|---|
| `toggleHistory` | 一覧を開く / 閉じる（メニューの「履歴の一覧を開く」と同じ） |
| `pressOpenKey` | ⌃⌘V を押したのと同じ（動きは `hotkeyMode`。既定は候補窓。許可がなければ一覧を開く） |
| `pressOpenListKey` | ⌃⌥⌘V を押したのと同じ |
| `simulateCopyShortcut` | ⌘C を見たときと同じ信号を入れる |
| `setPasteTarget` | 貼り付けの宛先を pid で固定する |
| `pause` / `resume` | 記録の一時停止 / 再開 |
| `writeStatus` | 状態を `<データフォルダ>/debug-status.json` に書く（設定ファイルから読み直したときも自動で書く） |
| `quit` | 終了する |

`debug-status.json` の鍵: `pid`・`accessibilityTrusted`・`keyMonitorActive`・`hotKeys`・`pasteboard`・`paused`・`itemCount`・`historyVisible`・`historyUI`（`query`・`rowCount`・`loadedCount`・`selectedIndex`・`selectedKind`・`selectedSecret`・`revealing`・`windowNumber`・`kindFilter`・`methodFilter`・`appFilter`・`pinnedOnly`・`previewOpen`・`pickerOpen`・`anchor`）・`candidate`（`active`・`tapActive`・`method`・`index`・`count`・`order`・`tentative`・`note`・`lastEnd`・`revealed`・`selectedSecret`・`candidateAnchor`・`candidateFirstRow`）・`pasteTargetOverride`・`lastPasteOutcome`（`pasted` / `noPermission` / `noTarget` / `copied`）・
`lastHotKeyRoute`（直近に押した呼び出しキーの振り分け）・`openKeyRoute`（いま呼び出しキーを押したらどうなるか。押さずに `HotKeyRouter.route` で計算した値: `startCandidate` / `pasteLatest` / `openList` / `closeList` / `expandCandidate`）・
`storeLimits`（`maxItems`・`maxTotalBytes`。ストアに当たっている上限）・`candidateHotKeyMode`（候補窓の流れが持っている呼び出しキーの動き）・
`secrets`（`count` 秘密の件数・`knownFormat` 自動消去の対象の件数・`autoDeleted` 起動してから自動で消した件数・`retentionSeconds`・`nextSweepAt` 次に消す時刻。中身は出さない）・
`settings`（`hotkeyMode`・`candOrder`・`maxItems`・`maxTotalMB`・`keys.open`・`keys.openList`・`excludedApps` の値（JSON の文字列）と `reloadCount`・`issueCount`・`watching`）・`settingsVisible`・`writtenAt`。

`anchor` はパネルを出した手がかりの種類（`caret` 文字カーソル / `field` 入力欄の枠 / `mouse` マウス / `screen` 画面の指定）。座標は出さない。

## メタデータの書き出し（`--dump-metadata`）

```json
{
  "itemCount": 1,
  "schemaVersion": 1,
  "items": [{
    "id": "UUID", "kind": "image", "copyMethod": "keyboard",
    "sourceBundleID": "com.apple.Preview", "sourceName": "プレビュー", "sourceURLHost": null,
    "createdAt": "ISO8601", "lastUsedAt": "ISO8601", "copyCount": 1, "pinned": false, "flags": [],
    "totalBytes": 32264, "contentHashPrefix": "12 桁",
    "pasteboardItems": [[{"type": "public.png", "bytes": 1234, "storage": "inline"}]]
  }]
}
```

新しい順（`lastUsedAt` の降順）。`sourceURLHost` はホスト名だけ（クエリに秘密が入りうるため）。
`flags` に `secretLikely`（秘密っぽい）・`secretKnownFormat`（確度が高い。自動消去の対象）が入る（#5）。`schemaVersion` は 2。

## UI との約束（`Sources/MakuripCore/Support/HistoryPresenting.swift`）

```swift
@MainActor public protocol HistoryPresenting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func show(selecting itemID: UUID?)            // 候補窓から広げたとき。既定の実装は show()
    func hide()
    func historyDidChange()
    var debugState: [String: String] { get }   // 既定は空
    func keymapDidChange(_ keymap: Keymap)        // 設定でキーが変わった（既定は何もしない）
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
}
// paste(itemID:) と historyItems・historyDidClose 以外は既定の実装（何もしない・空）がある

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
| `look` | 大きくプレビュー | ⌘Y | パネル |
| `reveal` | 隠した内容を表示（押している間）。一覧・プレビュー・候補窓で効く | ⌥（押している間） | パネル |
| `source` | コピー元のページを開く | ⌘O | パネル |
| `delete` | 履歴から削除 | ⌘⌫ | パネル |
| `settings` | 設定を開く | ⌘, | パネル |
| `candUp` / `candDown` | 上の候補へ / 下の候補へ（ターミナル式では ↑ が古いほう） | ↑ / ↓ | 候補窓 |
| `candCommit` | 確定（改行や送信はしない） | ⇥・↩ | 候補窓 |
| `candCancel` | 取り消し（貼る前に戻す） | esc | 候補窓 |
| `candExpand` | 一覧に広げる | ⌃⌘V | 候補窓 |

候補窓の範囲のキーは候補窓が出ている間だけ効くので、候補窓のキーどうしだけで重なりを見る（⌃⌘V が `open` と `candExpand` の両方にあるのはこのため）。
候補窓の間に全体のキー（⌃⌘V・⌃⌥⌘V）が来たら、タップは素通しして Carbon のホットキーに任せ、`HotKeyRouter` が「広げる」に振り分ける。
定型文（⌘S）は #7 で足す。隠した内容の表示（⌥）は #5 で足した。キーとして使える組み合わせの決まりは `KeyRules`（下の「設定」）。

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

## パネルの位置（`Sources/MakuripCore/Placement/`）

| 型 | 役割 |
|---|---|
| `InsertionPointLocator.locate(pid:)` | 前面のアプリの文字カーソル（`AXSelectedTextRange` → `AXBoundsForRange`）、取れなければ入力欄の枠（`AXPosition` + `AXSize`）。AX の座標のまま返す。許可がない・取れないときは nil |
| `PanelPlacement.frame(size:anchor:screens:side:mouse:)` | 手がかり（`PanelAnchor`: 文字カーソル → 入力欄の枠 → マウス → なし）から窓の枠を決める。`.below` はカーソルの下（入らなければ上。案 B）、`.beside(rowOffset:)` はカーソルの右（候補窓 #8） |
| `PanelPlacement.peekFrame(panel:width:screens:)` | ⌘Y のプレビューの枠（右に入らなければ左） |
| `PanelPlacement.appKitRect(fromAX:primaryScreenHeight:)` | AX の座標（左上原点）を AppKit の座標（左下原点）へ |

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
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

`PRAGMA secure_delete = ON`（消した行をファイルの上でも 0 で上書きする）。秘密を消したあとは `wal_checkpoint(TRUNCATE)` で WAL を空にする。

データフォルダ: `history.sqlite`（+ `-wal` / `-shm`）・`blobs/<履歴ID>/<項目>-<順>.bin`・`instance.lock`・`settings.json`（+ 壊れていたときの `settings.broken.json`）・（検証時のみ）`debug-status.json`。

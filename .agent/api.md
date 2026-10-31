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
| `-MakuripPanelScreen NAME` | 一覧を出す画面を名前で固定する（UserDefaults の引数ドメイン。E2E が仮想ディスプレイに出すため）。指定すると文字カーソルの位置は使わず、その画面の下寄りの中央に出す |

同じデータフォルダを 2 つのインスタンスが使おうとすると、後から起動した方が終了する（`instance.lock` の flock）。

### 検証用の遠隔操作（`--debug-control`）

分散通知 `com.takushio2525.makurip.debug.<命令>`、object = データフォルダの絶対パス（標準化したもの）。
送るのは `MakuripDevTool notify --data-dir DIR <命令> [--pid PID]`。

| 命令 | 動き |
|---|---|
| `toggleHistory` | ⌃⌘V と同じ（一覧を開く / 閉じる） |
| `simulateCopyShortcut` | ⌘C を見たときと同じ信号を入れる |
| `setPasteTarget` | 貼り付けの宛先を pid で固定する |
| `pause` / `resume` | 記録の一時停止 / 再開 |
| `writeStatus` | 状態を `<データフォルダ>/debug-status.json` に書く |
| `quit` | 終了する |

`debug-status.json` の鍵: `pid`・`accessibilityTrusted`・`keyMonitorActive`・`hotKeys`・`pasteboard`・`paused`・`itemCount`・`historyVisible`・`historyUI`（`query`・`rowCount`・`loadedCount`・`selectedIndex`・`selectedKind`・`windowNumber`・`kindFilter`・`methodFilter`・`appFilter`・`pinnedOnly`・`previewOpen`・`pickerOpen`・`anchor`）・`pasteTargetOverride`・`lastPasteOutcome`（`pasted` / `noPermission` / `noTarget` / `copied`）・`writtenAt`。

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

## UI との約束（`Sources/MakuripCore/Support/HistoryPresenting.swift`）

```swift
@MainActor public protocol HistoryPresenting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func historyDidChange()
    var debugState: [String: String] { get }   // 既定は空
}

@MainActor public protocol HistoryActions: AnyObject {
    func historyItems(limit: Int) -> [ClipItem]
    func paste(itemID: UUID)                      // UI は先に自分を閉じてから呼ぶ
    func paste(itemID: UUID, mode: PasteMode)     // .normal / .plainText（文字の型だけ）/ .copyOnly（⌘V を送らない）
    func historyDidClose()                        // 貼らずに閉じたとき（元のアプリへフォーカスを返す）
    func setPinned(_ pinned: Bool, itemID: UUID)
    func delete(itemID: UUID)
    func representationInfos(itemID: UUID) -> [RepresentationInfo]          // サムネイル・プレビューで読む型を選ぶ
    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data?  // 型 1 つのデータ（UI の中だけで使う）
}
// paste(itemID:) と historyItems・historyDidClose 以外は既定の実装（何もしない・空）がある

// MakuripUI 側の入口（差し替えた UI も同じ名前で用意する）
public enum HistoryUIFactory { @MainActor static func make(actions: HistoryActions) -> HistoryPresenting }
```

## キーマップ（`Sources/MakuripCore/Keymap/Keymap.swift`）

全操作は `KeyAction`（ID・既定のキー・説明文・まとまり・範囲）から定義する。ID は試作（`core.js` の `Mk.ACTIONS`）と同じ。
フェーズ4の設定スキーマ・CLI・MCP（#6）はこの ID と説明文をそのまま使う。重なりは `Keymap.conflicts()` で見つける（全体のキーとパネルのキーは同じ範囲として見る）。
キーは物理キーの位置（仮想キーコード）で持つ（`KeyCombo`。`.digits` は 1〜9 の範囲）。

| ID | 操作 | 既定のキー | 範囲 |
|---|---|---|---|
| `open` | 履歴を呼び出す（どこからでも） | ⌃⌘V | 全体 |
| `close` | 検索を消す／閉じる | esc | パネル |
| `prev` / `next` | 前の項目 / 次の項目 | ↑・⌃P / ↓・⌃N | パネル |
| `paste` / `pastePlain` / `copyOnly` | 貼り付け / プレーンテキストで / コピーだけ | ↩ / ⇧↩ / ⌘↩ | パネル |
| `quick` | 番号の項目をすぐ貼り付け | ⌘1–9 | パネル |
| `kindNext` / `kindPrev` | 種類：次へ / 前へ | ⇥ / ⇧⇥ | パネル |
| `method` | コピー方法を切り替え（すべて → キー操作 → ボタンなど） | ⌘K | パネル |
| `app` | コピー元アプリを選ぶ | ⌘E | パネル |
| `pinned` / `pin` | ピン留めだけ表示 / ピン留めする・外す | ⇧⌘P / ⌘P | パネル |
| `look` | 大きくプレビュー | ⌘Y | パネル |
| `source` | コピー元のページを開く | ⌘O | パネル |
| `delete` | 履歴から削除 | ⌘⌫ | パネル |

定型文（⌘S）・隠した内容の表示（⌥）・設定（⌘,）・候補窓のキーは、それぞれ #7・#5・#4・#8 で足す。

## 検索と絞り込み（`Sources/MakuripCore/Search/`）

| 型 | 役割 |
|---|---|
| `SearchText.normalize(_:)` | NFKC → 小文字 → カタカナをひらがな → NFC（照合用） |
| `SearchText.romajiToKana(_:)` / `parse(_:)` | ローマ字の読み / 検索欄の文字列を語（AND）と候補（元の綴り・読み）に分ける |
| `SearchQuery` | `matches(normalized:)`（UTF-8 のバイト列で探す）・`highlightRanges(in:)`（元の文字列での一致範囲） |
| `HistoryFilter` | 種類（nil はすべて）・`CopyMethodFilter`・アプリ（バンドル ID か名前）・ピン留め・検索語。`apply`・`kindCounts`・`appOptions` |

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
| `enforceLimits()` / `removeOrphanBlobs()` | 上限の当て直し・保存途中で落ちた残りの掃除（起動時に呼ぶ） |

## DB スキーマ（版 1・`PRAGMA user_version = 1`）

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
```

データフォルダ: `history.sqlite`（+ `-wal` / `-shm`）・`blobs/<履歴ID>/<項目>-<順>.bin`・`instance.lock`・（検証時のみ）`debug-status.json`。

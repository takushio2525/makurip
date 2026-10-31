# アーキテクチャ

## モジュール構成（SwiftPM のターゲット）

```
Makurip（実行ファイル）── MakuripUI（一覧: 案 B のパネル）
     │                         │
     └──────────┬──────────────┘
                ▼
          MakuripCore（UI に依存しない本体）
```

| ターゲット | 責務 | 依存先 |
|---|---|---|
| `MakuripCore` | モデル・判定（純粋関数）・ペーストボードの読み書き・監視・SQLite のストア・メタデータの書き出し・UI との約束（`HistoryPresenting` / `HistoryActions`）・日本語検索（`Search/`）・キーマップ（`Keymap/`）・パネルの位置（`Placement/`）・候補窓の流れと判断（`Candidate/`） | Foundation・AppKit（NSPasteboard だけ）・ApplicationServices（AX）・CoreGraphics（CGEvent の読み取り）・CryptoKit・libsqlite3 |
| `MakuripUI` | 一覧（案 B のパネル。nonactivating な NSPanel + SwiftUI）・⌘Y のプレビュー（子ウインドウ）・候補窓（キーの焦点を取らない NSPanel）・中身の遅延読み込み。入口は `HistoryUIFactory.make(actions:)`・`CandidateUIFactory.make(actions:keymap:)` | MakuripCore |
| `Makurip` | AppDelegate（`AppController`）・メニューバー・ホットキー（Carbon）・⌘C の監視・貼り付け（⌘V 送信）・候補窓の横取り（`KeyEventTap`）と本体側の実装（`CandidateBridge`）・起動引数・検証用の遠隔操作 | MakuripCore・MakuripUI・Carbon |
| `MakuripDevTool` | 検証用 CLI（テストデータ・型の一覧・一般ペーストボードの退避と復元・pid 宛てのキー） | MakuripCore |

依存の向き: `Makurip` → `MakuripUI` → `MakuripCore`。逆向き（Core が UI・アプリを知る、UI がアプリを知る）は禁止。

## データフロー

### 取り込み

1. `PasteboardMonitor` が 0.25 秒おきに `changeCount` を見る（⌘C を見たら 0.05〜0.8 秒後にも追加で見る）
2. 変化があれば型の並びを控え、0.08 秒待って並びが落ち着いたのを確かめる（書き込みの途中で読むと項目が欠けるため）
3. `PasteboardReader.read` — 型名だけで除外の印（ConcealedType 等）を判定し、印があればデータを読まずに捨てる。なければ全項目・全型のデータを読む（型 1 つの上限を超えたものはここで落とす）
4. `CapturePipeline.process`（純粋関数）— 空・除外・サイズ上限 → 種類（`KindClassifier`）・コピー方法（`CopyMethodClassifier`）・コピー元ページ（`SourceURLExtractor`）・一覧用の平文（`PreviewText`）・同一判定のハッシュ（`ContentHasher`）
5. `ClipStore.save` — 同じハッシュがあれば先頭へ移す（回数 +1・コピー元とコピー方法を新しい方に）。なければ挿入（64 KB を超える型は `blobs/` のファイルへ）。最後に件数・容量の上限を当てて古い順に消す

### 呼び出しと貼り付け

1. ⌃⌘V（`HotKeyCenter`。キーは `Keymap` の `openHistory` から引く）→ `AppController.toggleHistory` — 前面のアプリを `previousApp` に控えて一覧を開く
2. `PanelController.show` — 窓を出す**前に**前面のアプリの文字カーソルを AX で取り（`InsertionPointLocator`）、`PanelPlacement` で位置を決める。
   パネルは nonactivating なので Makurip は前面にならず、元のアプリが前面のままキーだけを受け取る
3. キーはパネルの窓のローカル監視 → `HistoryPanelModel.handle`（キーマップで操作を引く。日本語入力の変換中は横取りしない）
4. Enter（⇧Enter・⌘Enter・⌘1〜9）→ UI が自分を閉じてから `HistoryActions.paste(itemID:mode:)`
5. `ClipStore.snapshot` で全項目・全型を読み（プレーンテキストのときは文字の型だけ）、`PasteboardWriter.write` でペーストボードへ戻す
6. 書いたあとの changeCount を `monitor.acknowledgeOwnWrite` に渡す（新しい履歴にしない）。`store.touch` で先頭へ移す
7. `Paster` が `previousApp` を前面に戻し、その pid 宛てに ⌘V を送る（アクセシビリティの許可が要る）。「コピーだけ」は送らずにフォーカスだけ返す

### 候補窓（フェーズ2.5・#8）

1. ⌃⌘V（`HotKeyCenter` → `AppController.hotKeyPressed(.open)`）。`HotKeyRouter` が `hotkeyMode`（既定 `candidate`）と、
   候補窓・一覧が出ているかで振り分ける。⌃⌥⌘V はいつも一覧。候補窓が出ていればどちらのキーでも一覧へ広げる
2. `CandidateCoordinator.start` — 許可がない・前面のアプリがない・タップを作れないときは一覧を開く（横取りしない）。
   前面のアプリ（`CandidateTarget`）・変換中か（`ComposingState`）・貼り方（`PasteTiming`）・入力欄の状態（`FocusedText.probe`）から
   差し替え方式（`ReplacePlanner.initialMethod`）を決め、**タップを始めてから**窓を出す
3. 窓（`CandidatePanelController`）は出す前に文字カーソルを AX で取り、カーソルの右に、選んだ行をカーソルの行にそろえて出す。
   位置の手がかりはそのセッションの間は固定し、選択が変わるたびに `PanelPlacement.frame(... .beside(rowOffset:))` で置き直す
4. 仮に貼る（`.selectRange` / `.undo` のとき）: 貼る前のペーストボードを丸ごとメモリに控え、最新を書いて pid 宛てに ⌘V。
   AX で文字カーソルが進んだことを確かめ、貼った範囲を測る
5. ↑↓（タップ → `handle` → `perform`）: 選択だけをすぐ変え、文書への反映は 1 つずつ順に行う（`drain`。連打しても最後の選択に追いつく）。
   差し替えは、貼った範囲を AX で選び直してその上に ⌘V（文字だけの中身で長さが合うとき）→ だめなら ⌘Z で 1 段戻して ⌘V。
   ⌘Z で戻ったことを AX で確かめられなければ ⌘⇧Z で打ち消し、貼ってあるもので閉じる（そのアプリは次から確定まで貼らない）
6. 確定（⇥・↩・ダブルクリック）: 貼ってある項目を先頭へ移す（`store.touch`）。確定まで貼らない方式では、ここで初めて ⌘V。
   取り消し（esc）: 貼ったものを消し（範囲を選んで ⌫、または ⌘Z）、控えたペーストボードを戻す。広げる: 取り消してから一覧を選んだ状態で開く
7. 閉じる経路はすべて `end` を通り、**その場で**タップを止め、時計を止め、窓を閉じる。文書の後始末はそのあとタップなしで行う

部品: `CandidateCoordinator`（流れ）・`CandidateSession` / `CandidateLayout`（並び・寸法）・`ReplacePlanner`（方式）・
`CandidateView` / `CandidatePanelController`（窓）・`KeyEventTap`（CGEventTap）・`CandidateBridge`（AX・ペーストボード・キー・ストア）。

### 一覧（フェーズ2・`Sources/MakuripUI/`）

| 部品 | 役割 |
|---|---|
| `PanelController` | 窓（nonactivating な `KeyablePanel`）・キーのローカル監視・位置・⌘Y の子ウインドウ（`PeekPanel`）。メインメニューがないので検索欄の ⌘A/C/V/X/Z もここで送る |
| `HistoryPanelModel` | 状態（絞り込み・選択・プレビュー・⌘E）と全操作。`handle(_:isComposing:)` がキーマップから操作を引く。単体テストはここを駆動する |
| `HistoryPanelView` / `CardView` / `PeekView` | 試作（`~/dev/makurip-design/ui/shared/panel-b.*`・`base.css`）の寸法と色を写した SwiftUI。文字の行の高さは `CSSText` で CSS の line-height を再現 |
| `ClipContentLoader` | サムネイル・全文・ファイル・色・リッチテキストを、見えたカードと選んだ 1 件だけ読む。画像の縮小はメインスレッドの外 |

- 履歴は開くたびに全件のメタデータを読む（5000 件で 23 ms）。検索用の正規化（`HistoryFilter.haystack`）は開いた後に裏で作り、内容のハッシュが同じあいだ使い回す
- 試作との見比べは `design/ui-compare/`（`make ui-compare`）

## データモデル

型の定義は `Sources/MakuripCore/Model/`。DB スキーマは `.agent/api.md`。

| 型 | 中身 |
|---|---|
| `PasteboardSnapshot` | 1 回のコピーの全項目（`PasteboardItemSnapshot`）× 全型（`PasteboardRepresentation` = 型名 + データ） |
| `CapturedClip` | 保存前の 1 件（スナップショット + メタデータ） |
| `ClipItem` | 保存済みの 1 件のメタデータ（データ本体は含まない） |
| `ClipKind` | テキスト / リッチテキスト / 画像 / ファイル / URL / 色 / コード / コマンド / その他 |
| `CopyMethod` | キー操作（⌘C/⌘X）/ それ以外 / 不明 |
| `ClipFlag` | 開いた集合の印。`truncated`（上限で型を落とした）・`secretLikely`（フェーズ5）・`addedByAI`（フェーズ6） |
| `SourceApp` | コピーした瞬間に前面にいたアプリ（バンドル ID・名前） |
| `Limits` | 上限の既定値（件数 1000・合計 1 GB・型 1 つ 50 MB・1 件 100 MB・DB に入れる上限 64 KB） |
| `HotKey` | 仮想キーコード + 修飾キー（Codable。フェーズ4の設定で保存する） |

後のフェーズでの載せ方:
- ~~フェーズ2（絞り込み）: `kind`・`copyMethod`・`source` は列として持っている。日本語検索の正規化は `preview_text` を元に別の列か索引を足す（スキーマ版を上げる）~~
- フェーズ2（済）: 絞り込みと日本語検索はメモリの中で行う（DB の列は足していない。スキーマ版 1 のまま）。全件を読んでも 5000 件で 23 ms、温まった後の検索が 15 ms で足りるため。1 万件を大きく超える上限にするなら、正規化した列と FTS を足す
- フェーズ2.5（候補窓・済）: 位置は `PanelPlacement.frame(... side: .beside(rowOffset:))`、手がかりは `InsertionPointLocator`。DB は変えていない（仮に貼っている間は `touch` せず、確定したときだけ先頭へ移す。回している間の並びは始めた時点のものを固定して持つ）
- フェーズ3（プレビュー）: `ClipStore.snapshot(id:)` で全データ、`representationInfos(id:)` で型の一覧が取れる
- フェーズ4（設定）: `Limits` と `HotKey` を UserDefaults か設定ファイルに保存し、`ClipStore(directory:limits:)` と `HotKeyCenter.register` に渡す
- フェーズ5（秘密）: 判定結果を `ClipStore.setFlags(_:id:)` で `secretLikely` にする。判定は形式だけで行い、中身を外へ出さない
- フェーズ6（AI の口）: 追加は `CapturedClip` を組み立てて `ClipStore.save`（`addedByAI` の印）。AI へは `MetadataDump` 相当の形式情報だけを返す

## 技術選定（フェーズ1・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| プロジェクトの作り方 | SwiftPM + `scripts/build-app.sh` | XcodeGen（brew で追加ツールが要り、生成物の .xcodeproj を扱う）、生の .xcodeproj（pbxproj の差分が読めず衝突しやすい）、Tuist（重い）。SwiftPM は追加ツールなしで差分が読め、`swift build` / `swift test` で完結する。.app の組み立てと署名は 40 行ほどのスクリプトで見える形にした。Xcode で開くときは `Package.swift` を開けば SwiftUI のプレビューも使える |
| 永続化 | macOS 同梱の SQLite を C API で直接 | GRDB（外部ライブラリ）、SwiftData（macOS 14+・挙動の癖とマイグレーションの扱いにくさ）、Core Data（.xcdatamodeld が要る）、JSON ファイル（件数が増えると全体の書き直しが重い）。SQLite は依存ゼロで、WAL で読みと書きを並べられ、`sqlite3` コマンドで中を確かめられる。ラッパーは `Store/SQLite.swift` の 150 行ほど |
| グローバルショートカット | Carbon `RegisterEventHotKey` | KeyboardShortcuts（sindresorhus。中身は同じ Carbon で、記録 UI 付き。フェーズ4で記録 UI が欲しくなったら候補）、CGEventTap（入力監視の許可が要る）、NSEvent のグローバル監視（キーを横取りできず前面のアプリにも届く）。Carbon は権限不要・任意の組み合わせを登録でき・横取りもできる |
| ⌘C の検出 | `NSEvent.addGlobalMonitorForEvents(.keyDown)` | CGEventTap（listen-only でも入力監視の許可が別に要る）。グローバル監視はアクセシビリティの許可で動き、貼り付けにも同じ許可が要るので、ユーザーに頼む許可が 1 つで済む |
| ⌘V の送り先 | `CGEvent.postToPid(元のアプリの pid)` | `CGEvent.post(tap: .cghidEventTap)`（その時点で前面にある別の窓に入りうる）。pid 宛てなら意図したアプリにしか届かない |

## 技術選定（フェーズ2・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| パネルの窓 | nonactivating な NSPanel（`canBecomeKey`） | 通常の NSPanel + `NSApp.activate`（フェーズ1。Makurip が前面になり、日本語入力の状態や元の窓のフォーカスが動く）、NSPopover（カーソルの位置に出せない）。nonactivating なら元のアプリを前面のまま検索欄に打てる（Spotlight と同じ形） |
| キーの受け方 | 窓のローカル監視（`NSEvent.addLocalMonitorForEvents`）→ ビューモデル | SwiftUI の `onKeyPress`（⌘ 付き・Tab の扱いが TextField と取り合う。テストからも駆動しにくい）。監視で受けてモデルに渡せば、キーの処理を単体テストで確かめられる |
| 日本語検索 | メモリの中で正規化（NFKC・カタカナ→ひらがな・NFC）+ UTF-8 のバイト列で探す | SQLite の FTS（日本語の分かち書きが要る・スキーマ版が上がる）、`String.range(of:options:)`（打鍵ごとに数千件 × 1000 文字で遅い）。正規化した文字列をキャッシュすれば 5000 件で 15 ms |
| アイコン | SF Symbols | 試作の線画を SVG で持つ（アセットが増える・ダークの色を別に持つ）。リッチテキストの `textformat` だけ英語の字形に固定（日本語の環境で「あぁ」になる） |
| 見た目の検証 | `NSHostingView` を枠なしの窓に載せて `cacheDisplay`（画面ロック中でも描ける） | `ImageRenderer`（TextField・ScrollView など AppKit 由来の部品を描けない）、実機のスクショ（画面ロック中は真っ黒） |

## 技術選定（フェーズ2.5・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| 候補窓の間のキーの横取り | 能動の CGEventTap（`.cgSessionEventTap`・`.headInsertEventTap`）を候補窓の間だけ作る | Carbon のホットキーを ↑↓ 等に一時登録（Tab・Enter・esc を修飾なしで登録すると、その間に押した「ほかのキー」を見られず、予測変換のように確定して素通しができない）、`NSEvent` のグローバル監視（見るだけで食べられない）、窓にキーの焦点を取る（前面のアプリの入力欄から焦点が外れ、仮に貼った文字の後に打てない）。タップは許可（アクセシビリティ）が要るが、貼り付けにも同じ許可が要る |
| 差し替え | 範囲を AX で選び直して ⌘V → ⌘Z → 確定まで貼らない | ⌘Z だけ（画像・リッチテキストには強いが、⌘Z が貼り付け以外も戻すアプリがある）、⇧← を文字数ぶん送って選ぶ（改行・絵文字・自動整形で数がずれる）、`kAXSelectedTextAttribute` を書いて文字を入れる（文字以外を貼れない・取り消しの履歴に乗らないアプリがある）。どの方式も、AX で結果を確かめられるときだけ使い、確かめられない入力欄では仮に貼らない |
| 変換中の判定 | AX の `AXTextInputMarkedRange`（WebKit は `AXTextInputMarkedTextMarkerRange`）→ 入力ソース（TIS）| 入力ソースだけ（日本語入力のかなモードのまま英数を打つ人では、いつも「変換中」になって候補窓が使えない）、日本語入力の候補窓が画面にあるか（未確定の文字はあっても候補窓が出ていないことが多い） |
| 候補窓の窓 | キーの焦点を取らない nonactivating な NSPanel（`.popUpMenu`） | 一覧（案 B）の窓を使い回す（あちらは検索欄に打つので焦点を取る。焦点の扱いが逆なので分けた） |

## 変更時の波及

- DB スキーマを変える: `ClipStore.migrate()` に版を足し、`.agent/api.md` の「DB スキーマ」と `MetadataDump` を同時に直す
- 種類の判定を変える: `KindClassifierTests` に入力例を足し、`.agent/conventions.md` の「判定の限界」を見直す
- UI を差し替える: `Sources/MakuripUI/` を置き換え、`HistoryUIFactory.make(actions:)` を同じ名前で用意する。E2E（`scripts/e2e/paste.sh`）は `debugState` の `rowCount` / `query` と `-MakuripPanelScreen` を使っているので、新しい UI でも同じ鍵を返すか、スクリプトを直す（案 B のパネルは同じ鍵を返す）
- キーを足す・変える: `KeyAction`（ID・既定のキー・説明文）に足す。`KeymapTests` の「既定のキーに重なりがない」が守る。画面のヒントはキーマップから引くので直さなくてよい。候補窓のキー（範囲 `.candidate`）は候補窓のキーどうしだけで重なりを見る
- 候補窓の閉じ方・横取りを変える: 閉じる経路を足したら `CandidateInterceptLifetimeTests.Path` に足す（全経路でタップ・窓・時計が残らないことを確かめる）。差し替えを変えたら `CandidateCoordinatorTests`（偽の入力欄で文書が元に戻るか）
- 確定まで貼らないアプリを足す: `DeferredPasteApps`（バンドル ID は .app の Info.plist で確かめる）と `CandidateSettingsTests`
- 検索を変える: `SearchTextTests` に例を足し、`.agent/conventions.md` の「検索」の限界を見直す。試作（`core.js`）と振る舞いを変えるときは理由を書く
- 見た目を変える: `make ui-compare` で試作と並べて確かめ、`design/ui-compare/README.md` の「意図して変えたところ」を直す
- 表示名・バンドル ID・版を変える: `Sources/Makurip/Info.plist` の 1 か所だけ

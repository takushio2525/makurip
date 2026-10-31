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
| `MakuripCore` | モデル・判定（純粋関数）・ペーストボードの読み書き・監視・SQLite のストア・メタデータの書き出し・UI との約束（`HistoryPresenting` / `HistoryActions`）・日本語検索（`Search/`）・キーマップ（`Keymap/`）・パネルの位置（`Placement/`）・コードの言語と色付けの区間・プロンプト（`Syntax/`）・貼るときの中身（`Paste/`）・候補窓の流れと判断（`Candidate/`）・設定のスキーマ・検証・ファイル・監視・反映・CLI（`Settings/`） | Foundation・AppKit（NSPasteboard だけ）・ApplicationServices（AX）・CoreGraphics（CGEvent の読み取り）・CryptoKit・libsqlite3 |
| `MakuripUI` | 一覧（案 B のパネル。nonactivating な NSPanel + SwiftUI）・⌘Y のプレビュー（子ウインドウ）・候補窓（キーの焦点を取らない NSPanel）・設定画面（ふつうの窓 + SwiftUI。キーの記録）・中身の遅延読み込み。入口は `HistoryUIFactory.make(actions:keymap:)`・`CandidateUIFactory.make(actions:keymap:)`・`SettingsUIFactory.make(controller:environment:)` | MakuripCore |
| `Makurip` | AppDelegate（`AppController`）・メニューバー・ホットキー（Carbon）・⌘C の監視・貼り付け（⌘V 送信）・候補窓の横取り（`KeyEventTap`）と本体側の実装（`CandidateBridge`）・設定の反映（`SettingsApplying`）・ログイン時の起動（ServiceManagement）・起動引数・`--settings` の入口・検証用の遠隔操作 | MakuripCore・MakuripUI・Carbon・ServiceManagement |
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

1. 一覧を開くキー（`HotKeyCenter`。キーは設定の `keys.openList`、既定 ⌃⌥⌘V）・メニュー → `AppController.openList` — 前面のアプリを `previousApp` に控えて一覧を開く
2. `PanelController.show` — 窓を出す**前に**前面のアプリの文字カーソルを AX で取り（`InsertionPointLocator`）、`PanelPlacement` で位置を決める。
   パネルは nonactivating なので Makurip は前面にならず、元のアプリが前面のままキーだけを受け取る
3. キーはパネルの窓のローカル監視 → `HistoryPanelModel.handle`（キーマップで操作を引く。日本語入力の変換中は横取りしない）
4. Enter（⇧Enter・⌘Enter・⌘1〜9）→ UI が自分を閉じてから `HistoryActions.paste(itemID:mode:)`
5. `ClipStore.snapshot` で全項目・全型を読み、`PastePipeline.prepare`（純粋関数）で書き戻す中身を決めて `PasteboardWriter.write` でペーストボードへ戻す。
   プレーンテキストのときは文字の型だけ（プロンプトは外さない）。コマンドは文字の型（UTF-8・UTF-16）だけ行頭のプロンプトを外し（`ShellPrompt`）、RTF・HTML などほかの型と並びは元のまま。保存した履歴は変えない
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
   書く中身は一覧と同じく `PastePipeline.candidatePaste`（コマンドはプロンプトを外す。差し替えで選び直す長さも外した後の文字で数える）。
   AX で文字カーソルが進んだことを確かめ、貼った範囲を測る
5. ↑↓（タップ → `handle` → `perform`）: 選択だけをすぐ変え、文書への反映は 1 つずつ順に行う（`drain`。連打しても最後の選択に追いつく）。
   差し替えは、貼った範囲を AX で選び直してその上に ⌘V（文字だけの中身で長さが合うとき）→ だめなら ⌘Z で 1 段戻して ⌘V。
   ⌘Z で戻ったことを AX で確かめられなければ ⌘⇧Z で打ち消し、貼ってあるもので閉じる（そのアプリは次から確定まで貼らない）
6. 確定（⇥・↩・ダブルクリック）: 貼ってある項目を先頭へ移す（`store.touch`）。確定まで貼らない方式では、ここで初めて ⌘V。
   取り消し（esc）: 貼ったものを消し（範囲を選んで ⌫、または ⌘Z）、控えたペーストボードを戻す。広げる: 取り消してから一覧を選んだ状態で開く
7. 閉じる経路はすべて `end` を通り、**その場で**タップを止め、時計を止め、窓を閉じる。文書の後始末はそのあとタップなしで行う

部品: `CandidateCoordinator`（流れ）・`CandidateSession` / `CandidateLayout`（並び・寸法）・`ReplacePlanner`（方式）・
`CandidateView` / `CandidatePanelController`（窓）・`KeyEventTap`（CGEventTap）・`CandidateBridge`（AX・ペーストボード・キー・ストア）。

### 設定（フェーズ4・#4）

1. 起動: 既定のデータフォルダなら `SettingsMigration` が UserDefaults の候補窓の設定を引き継ぐ（設定ファイルがないときに 1 回）。
   `SettingsController` が `settings.json` を読み、`ClipStore`・`PasteboardMonitor`・一覧・候補窓をその値で作り、`SettingsApplier.apply(previous: nil)` で
   ホットキーの登録・上限・記録しないアプリ・キーマップ・候補窓の設定を当てる
2. 変える: 設定画面（`SettingsModel` → `SettingsController.set`）も CLI（別のプロセスの `SettingsCLI` → `SettingsFile.save`）も、
   `SettingsSchema.applying` で検証してからファイルに書く（置き換えで書く）
3. 読み直す: `SettingsController` がデータフォルダ（置き換えで名前が変わる）と設定ファイル（その場での書き換え）を DispatchSource で見張り、
   変化から 0.05 秒待って読み直す。中身が同じなら何もしない（自分で書いた分も 1 回読むが知らせない）
4. 反映: 変わった部分だけ `SettingsApplier` が `AppController`（`SettingsApplying`）へ渡す。上限は `ClipStore.setLimits`（下げたらその場で古い順に消す）と
   `PasteboardMonitor.limits`、記録しないアプリは `PasteboardMonitor.excludedApps`（前面のアプリで判定し、データを読まずに捨てる）、
   どこからでも効くキーは Carbon の登録を外して付け直す、キーマップは一覧・候補窓（とそのヒント）・メニューの表示、候補窓の設定は `CandidateCoordinator.settings`。
   ログイン時の起動は変えたときだけ `SMAppService.mainApp` に登録・解除（隔離中はしない）
5. キーの記録: 設定画面が記録を始めると、本体はどこからでも効くキーを外す（⌃⌘V などを記録できるように）。終わったら付け直す

部品: `SettingsSchema`・`KeyRules`・`KeyComboText`・`AppSettings`・`SettingsFile`・`SettingsMigration`・`SettingsController`・`SettingsApplier`・`SettingsCLI`（Core）、
`SettingsModel`・`SettingsView`・`SettingsWindowController`（UI）。

### 一覧（フェーズ2・`Sources/MakuripUI/`）

| 部品 | 役割 |
|---|---|
| `PanelController` | 窓（nonactivating な `KeyablePanel`）・キーのローカル監視・位置・⌘Y の子ウインドウ（`PeekPanel`）。メインメニューがないので検索欄の ⌘A/C/V/X/Z もここで送る |
| `HistoryPanelModel` | 状態（絞り込み・選択・プレビュー・⌘E）と全操作。`handle(_:isComposing:)` がキーマップから操作を引く。単体テストはここを駆動する |
| `HistoryPanelView` / `CardView` / `PeekView` | 試作（`~/dev/makurip-design/ui/shared/panel-b.*`・`base.css`）の寸法と色を写した SwiftUI。文字の行の高さは `CSSText` で CSS の line-height を再現 |
| `ClipContentLoader` | サムネイル・全文・ファイル・色・リッチテキストを、見えたカードと選んだ 1 件だけ読む。画像の縮小はメインスレッドの外。コードの言語・色付きのカード・プレビューの色付けの区間もここでキャッシュする |
| `CodeStyler` / `CodeTextView` | コードとコマンドの色付け（フェーズ3）。カードと ⌘Y のコマンドは SwiftUI の Text（AttributedString）、⌘Y のコードは NSTextView（行番号は `LineNumberRuler`） |

### コードの色付け（フェーズ3・#3）

1. 言語: `ClipContentLoader.language(for:)` が一覧の平文（先頭 1000 文字）を `CodeLanguageDetector.detect` に渡し、項目ごとに 1 回だけ決める。
   カード・⌘Y のプレビュー・候補窓の行（「Swift 17行」）が同じ言語を使う。コマンドはいつもシェル
2. 区間: `SyntaxHighlighter.tokens`（純粋関数・自前の字句解析）が UTF-16 の区間と種類（キーワード・文字列・コメント・数・型・関数・属性・フラグ）を返す
3. カード（コード 5 行・コマンド 3 行）: `CodeStyler` が NSMutableAttributedString に SwiftUI の属性の鍵で色を付け、一度に AttributedString へ変える。配色ごとにキャッシュ
4. ⌘Y のコード: 区間を配色によらずキャッシュし、`CodeTextView`（NSTextView）に NSColor で塗って渡す。8000 文字（UTF-16）までその場で、
   それより長いものは区間を裏のスレッドで作り、できるまでは色なしで出す。プレビューは先頭 2 万文字まで（`previewCharacterLimit`）
5. コマンド: `ShellPrompt.analyze` で外すプロンプトの範囲を薄くし、プロンプトのある文字列ではコマンドの行（プロンプトの行と続きの行）だけを色付けする（出力の行は色なし）

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
| `Limits` | 上限の既定値（件数 1000・合計 1 GB・型 1 つ 50 MB・1 件 100 MB・DB に入れる上限 64 KB）。件数と容量は設定で変わる |
| `HotKey` | 仮想キーコード + 修飾キー（Carbon に登録する形。設定ではキーマップの `KeyCombo` を文字で持つ） |
| `AppSettings` | 設定の値（呼び出しキーの動き・候補窓の並び・上限・アプリごとの扱い・キーマップ）。ファイルは `settings.json` |

後のフェーズでの載せ方:
- ~~フェーズ2（絞り込み）: `kind`・`copyMethod`・`source` は列として持っている。日本語検索の正規化は `preview_text` を元に別の列か索引を足す（スキーマ版を上げる）~~
- フェーズ2（済）: 絞り込みと日本語検索はメモリの中で行う（DB の列は足していない。スキーマ版 1 のまま）。全件を読んでも 5000 件で 23 ms、温まった後の検索が 15 ms で足りるため。1 万件を大きく超える上限にするなら、正規化した列と FTS を足す
- フェーズ2.5（候補窓・済）: 位置は `PanelPlacement.frame(... side: .beside(rowOffset:))`、手がかりは `InsertionPointLocator`。DB は変えていない（仮に貼っている間は `touch` せず、確定したときだけ先頭へ移す。回している間の並びは始めた時点のものを固定して持つ）
- フェーズ3（プレビュー・済）: DB は変えていない。言語は表示のときに一覧の平文から判定してメモリにキャッシュする（列を足すと判定を直すたびに作り直しが要るため）。コピー元のページは取り込み時の `sourceURL` をそのまま使う
- フェーズ4（設定・済）: データフォルダの `settings.json`（DB は変えていない）。`ClipStore.limits` を変えられるようにし（`setLimits`）、ホットキーは設定が変わるたびに付け直す
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

## 技術選定（フェーズ3・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| コードの色付け | 自前の簡易な字句解析（`SyntaxHighlighter`。C 系は設定付きの 1 つ、シェル・HTML/XML・CSS・JSON・YAML は個別）| Highlightr（highlight.js を JavaScriptCore で動かす。外部ライブラリが 1 つ増え、起動に JS の実行環境が要り、1 回の色付けが数十 ms かかる。配色は CSS の書き換えになる）、tree-sitter（SwiftTreeSitter + 言語ごとの文法パッケージ。正確だが依存と C のソースが言語の数だけ増え、ビルドと保守が重い）。クリップボードの断片は不完全なコードも多く、構文木より字句で十分。依存 0 のまま、試作の 9 色にそのまま対応でき、1 回なめるだけで 500 行 5 ms（デバッグビルド） |
| 言語の判定 | 形で決まるもの（コードブロックの言語名・shebang・JSON・タグ・YAML）→ 言語ごとの手がかり（正規表現と重み）の点数 | 拡張子（クリップボードにはない）、機械学習の分類器（モデルが要る・説明しにくい）。点数なら紛らわしい例をテストで固定して調整できる |
| ⌘Y のコードの描画 | NSTextView（TextKit）+ NSRulerView の行番号 | SwiftUI の Text（色の区間が多いと組むのが極端に遅い。色付きの 600 行で 2.5 秒、1000 行で 17 秒。区間が少ないカードとコマンドはこちら）、1 行ずつの Text を LazyVStack に並べる（速いが、行をまたいで選べず、横に送ると行番号も一緒に動く）。NSTextView なら 3000 行でもパネルとプレビューの描画が約 120 ms で一定 |
| プロンプトを外す場所 | 貼るときに書き戻す中身だけ（`PastePipeline`）。保存した履歴と RTF・HTML は変えない | 取り込みのときに外して保存する（元に戻せない・⇧↩ で元のまま貼れない）、全型を書き換える（RTF の制御語や HTML のタグを壊しうる） |

## 技術選定（フェーズ4・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| 設定の保存先 | データフォルダの JSON ファイル（`settings.json`） | UserDefaults（CLI が別のプロセスから同じドメインを書くと、動いているアプリの cfprefsd のキャッシュと食い違いうる・`--data-dir` で隔離できない・値の検証を通さずに `defaults write` で書ける）、SQLite の表（人と AI が中を読みにくい）。JSON ならアプリと CLI が同じコードで読み書きでき、隔離したインスタンスの設定が本物と混ざらない |
| 動いているアプリへの反映 | ファイルの監視（データフォルダと設定ファイルの DispatchSource） | 分散通知（CLI から送るのは簡単だが、手や AI がファイルを直接書き換えたときに気づけない）、定期的に読む（遅い・無駄）、FSEvents（ファイル単位の変化を取るのに C のコールバックとストリームの管理が要る）。DispatchSource 2 つで、置き換え（CLI）・その場での書き換え（エディタ）の両方を拾える |
| キーの記録 | 自前（窓の `NSEvent` ローカル監視 → `SettingsModel.record`） | KeyboardShortcuts（sindresorhus。記録欄が NSSearchField 風の部品で、試作の「行を選んで Enter → 新しいキーを押す…」と見た目と操作が違う。重なりの扱いも試作と違う。依存が 1 つ増える）。一覧のキーと同じ監視の仕組みで書け、単体テストでモデルを駆動できる |
| 設定画面の形 | 試作どおりの 1 つの一覧（動き → 履歴 → アプリごと → 詳細 → キーのまとまり） | 標準の `Settings` シーン + タブ（SwiftUI の App ライフサイクルが要る・試作と違う）。試作に無い項目（上限・アプリ）は同じ行の形（切り替え・数・札）で足した |
| 検証の場所 | Core の `SettingsSchema.applying` の 1 か所（画面・CLI・ファイルの読み込みが通る） | 画面と CLI で別々に確かめる（ずれる）。重なりの扱いだけ呼ぶ側が選ぶ（CLI は拒否・画面は試作どおり付け替え・ファイルはそのまま） |

## 変更時の波及

- DB スキーマを変える: `ClipStore.migrate()` に版を足し、`.agent/api.md` の「DB スキーマ」と `MetadataDump` を同時に直す
- 種類の判定を変える: `KindClassifierTests` に入力例を足し、`.agent/conventions.md` の「判定の限界」を見直す
- 言語の判定・色付けを変える: `CodeLanguageDetectorTests`（各言語の代表例と紛らわしい組）・`SyntaxHighlighterTests`（区間が重ならない・サロゲートペアを割らない）に足し、`make ui-compare` で試作と並べる。言語を足すときは `CodeLanguage`（名前・コードブロックの別名）と `SyntaxHighlighter` の設定の両方
- プロンプトの外し方を変える: `ShellPromptTests`（外さない例を必ず添える）と `PastePipelineTests`（名前付きペーストボードで書いて読み直す）。候補窓の流れは `CandidateCoordinatorTests`
- UI を差し替える: `Sources/MakuripUI/` を置き換え、`HistoryUIFactory.make(actions:)` を同じ名前で用意する。E2E（`scripts/e2e/paste.sh`）は `debugState` の `rowCount` / `query` と `-MakuripPanelScreen` を使っているので、新しい UI でも同じ鍵を返すか、スクリプトを直す（案 B のパネルは同じ鍵を返す）
- キーを足す・変える: `KeyAction`（ID・既定のキー・説明文）に足す。`KeymapTests` の「既定のキーに重なりがない」と `SettingsSchemaTests` の「既定のキーはキーの決まりに通る」が守る。
  設定の項目（`keys.<ID>`）・設定画面の行・CLI はキーマップから作るので直さなくてよい。候補窓のキー（範囲 `.candidate`）は候補窓のキーどうしだけで重なりを見る
- 設定項目を足す: `SettingsSchema.behaviorItems` に足し（ID・まとまり・説明・型・頼みの例）、`SettingsSchema.value` と `assign`、`AppSettings` に値を足す。
  反映が要るなら `SettingsApplying` に口を足す。`SettingsSchemaTests`（全項目の説明・既定・例が検証に通る）が守る。`docs/ai-settings.md` の一覧と `.agent/api.md` の「設定」も直す
- 候補窓の閉じ方・横取りを変える: 閉じる経路を足したら `CandidateInterceptLifetimeTests.Path` に足す（全経路でタップ・窓・時計が残らないことを確かめる）。差し替えを変えたら `CandidateCoordinatorTests`（偽の入力欄で文書が元に戻るか）
- 確定まで貼らないアプリを足す: `DeferredPasteApps`（バンドル ID は .app の Info.plist で確かめる）と `CandidateSettingsTests`
- 検索を変える: `SearchTextTests` に例を足し、`.agent/conventions.md` の「検索」の限界を見直す。試作（`core.js`）と振る舞いを変えるときは理由を書く
- 見た目を変える: `make ui-compare` で試作と並べて確かめ、`design/ui-compare/README.md` の「意図して変えたところ」を直す
- 表示名・バンドル ID・版を変える: `Sources/Makurip/Info.plist` の 1 か所だけ

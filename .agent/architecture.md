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
| `MakuripCore` | モデル・判定（純粋関数）・ペーストボードの読み書き・監視・SQLite のストア・メタデータの書き出し・UI との約束（`HistoryPresenting` / `HistoryActions`）・日本語検索（`Search/`）・キーマップ（`Keymap/`）・パネルとメニューバーの項目の位置（`Placement/`）・メニューバーのメニューの並び（`Menu/`）・コードの言語と色付けの区間・プロンプト（`Syntax/`）・貼るときの中身（`Paste/`）・候補窓の流れと判断（`Candidate/`）・設定のスキーマ・検証・ファイル・監視・反映・CLI（`Settings/`）・秘密の判定・伏せ字・自動消去の決まり・当て直し（`Secret/`）・定型文の検証・置き換え・ファイル・監視（`Snippets/`）・AI の口（オン・オフ・道具・MCP の JSON-RPC・`--ai` の CLI・操作の記録。`AI/`） | Foundation・AppKit（NSPasteboard だけ）・ApplicationServices（AX）・CoreGraphics（CGEvent の読み取り）・CryptoKit・libsqlite3 |
| `MakuripUI` | 一覧（案 B のパネル。nonactivating な NSPanel + SwiftUI）・⌘Y のプレビュー（子ウインドウ）・候補窓（キーの焦点を取らない NSPanel）・設定画面（ふつうの窓 + SwiftUI。キーの記録）・定型文の窓（ふつうの窓）・中身の遅延読み込み。入口は `HistoryUIFactory.make(actions:keymap:)`・`CandidateUIFactory.make(actions:keymap:)`・`SettingsUIFactory.make(controller:environment:)`・`SnippetEditorUIFactory.make(controller:environment:)` | MakuripCore |
| `Makurip` | AppDelegate（`AppController`）・メニューバー（`StatusMenuController`。置き場所の種まきと、`StatusMenuModel` の並びを NSMenu に写す。もう一度開かれたら設定を開く）・ホットキー（Carbon）・⌘C の監視・貼り付け（⌘V 送信）・候補窓の横取り（`KeyEventTap`）と本体側の実装（`CandidateBridge`）・設定の反映（`SettingsApplying`）・定型文の貼り付け（置き換え → 書き戻し → ⌘V → `{{カーソル}}` へ）・ログイン時の起動（ServiceManagement）・起動引数・`--settings`・`--mcp`・`--ai` の入口・AI の口の知らせの受け取り・検証用の遠隔操作 | MakuripCore・MakuripUI・Carbon・ServiceManagement |
| `MakuripDevTool` | 検証用 CLI（テストデータ・型の一覧・一般ペーストボードの退避と復元・pid 宛てのキー） | MakuripCore |

依存の向き: `Makurip` → `MakuripUI` → `MakuripCore`。逆向き（Core が UI・アプリを知る、UI がアプリを知る）は禁止。

## データフロー

### 取り込み

1. `PasteboardMonitor` が 0.25 秒おきに `changeCount` を見る（⌘C を見たら 0.05〜0.8 秒後にも追加で見る）
2. 変化があれば型の並びを控え、0.08 秒待って並びが落ち着いたのを確かめる（書き込みの途中で読むと項目が欠けるため）
3. `PasteboardReader.read` — 型名だけで除外の印（ConcealedType 等）を判定し、印があればデータを読まずに捨てる。なければ全項目・全型のデータを読む（型 1 つの上限を超えたものはここで落とす）
4. `CapturePipeline.process`（純粋関数）— 空・除外・サイズ上限 → 種類（`KindClassifier`）・コピー方法（`CopyMethodClassifier`）・コピー元ページ（`SourceURLExtractor`）・秘密（`SecretScanner`。印を付ける）・一覧用の平文（`PreviewText`。秘密なら伏せ字）・同一判定のハッシュ（`ContentHasher`）
5. `ClipStore.save` — 同じハッシュがあれば先頭へ移す（回数 +1・コピー元とコピー方法を新しい方に）。なければ挿入（64 KB を超える型は `blobs/` のファイルへ）。最後に件数・容量の上限を当てて古い順に消す

### 呼び出しと貼り付け

1. 一覧を開くキー（`HotKeyCenter`。キーは設定の `keys.openList`、既定 ⌃⌥⌘V）・メニュー → `AppController.openList`（メニューの「定型文の一覧を開く」は `openSnippetList` → `HistoryPresenting.showSnippets`）— 前面のアプリを `previousApp` に控えて一覧を開く
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

### 秘密（フェーズ5・#5）

1. 取り込み: `SecretScanner.assess` が全項目の平文（平文がなければ RTF・HTML の中身）・ファイルと URL の文字列を `SecretDetector` に通す。
   見つかれば `secretLikely`（確度「高」なら `secretKnownFormat` も）を付け、`PreviewText` が**全文を伏せ字にしてから**先頭 1000 文字に切って `preview_text` に入れる。
   なので一覧・検索・候補窓・メニューなど `previewText` を使うところは、何もしなくても伏せ字になる（本当の中身は `representation` にだけある）
2. 起動: `SecretRescan` が、判定の版（`SecretDetector.version`）が `meta` の版より新しければ、裏のスレッドで既存の履歴に 1 回だけ当て直す（文字の型だけ読む）
3. 表示: 一覧・⌘Y・候補窓は、秘密なら伏せ字の箱（`SecretCardBody`・`SecretPreviewBody`・行の鍵）で出す。表示のキー（`keys.reveal`。既定 ⌥）を押している間だけ、
   `ClipContentLoader.secret` が `representation` から本当の中身を読んで出す。閉じたら隠した状態へ戻し、読んだ中身を捨てる。
   一覧はパネルの窓のローカル監視（`flagsChanged`）、候補窓は横取りのタップ（`KeyTapEvent.flagsChanged`。食べずに素通し）で修飾キーを見る
4. 候補窓: `CandidateCoordinator` は秘密を仮に貼らない（選んだら仮に貼ってあるものを戻す）。確定したときに `.pasteSelected` で初めて貼る。ほかのキー・クリック・無操作で閉じたら貼らずに戻す
5. 貼る: `PastePipeline.prepare(…, secret: true)` が ConcealedType の印を足して書く（ほかのクリップボード履歴アプリに残さない）
6. 自動消去: `AppController.scheduleSecretSweep` が `items(flagged: .secretKnownFormat)` から時間の来たもの（`SecretExpiry`）を消し、次に消す時刻に 1 回きりのタイマーを掛け直す。
   起動・秘密の取り込み・設定の変更（`SettingsApplying.applySecretRetention`）・タイマーのたびに呼ぶ。消したら `scrubDeletedData` で WAL を空にする

### 定型文（フェーズ7・#7）

1. 保存: データフォルダの `snippets.json`（`SnippetFile`）。履歴の DB とは別なので、上限・消去・削除・DB の作り直しでは消えない。
   動いているアプリは `SnippetController` が設定と同じ仕組み（フォルダとファイルの DispatchSource）で見張り、変わったら一覧（`HistoryPresenting.snippetsDidChange`）と窓に知らせる
2. 呼び出し: 一覧で ⌘S（`KeyAction.snippets`）→ `HistoryPanelModel.showsSnippets`。試作どおり種類のタブ・コピー方法・アプリの絞り込みは薄くして効かなくし、
   検索（名前・略語・本文と「定型文」）・↑↓・↩・⇧↩・⌘↩・⌘1〜9・⌘Y はそのまま。⇧⌘P は履歴のピン留めだけの表示へ移る
3. 貼る: UI が閉じてから `HistoryActions.pasteSnippet(id:mode:)` → `AppController` が `SnippetTemplate.expand` で置き換える。
   `{{クリップボード}}`・`{{言語}}` があるときだけ、新しい 200 件のメタデータから `SnippetClipboard.candidates` を選び、先頭から 20 件まで平文を読む（読めたら止める）。
   `SnippetPaste.snapshot`（文字の型だけ）を `PasteboardWriter.write` → `monitor.acknowledgeOwnWrite`（新しい履歴にしない）→ `Paster` で元のアプリへ ⌘V。履歴の `touch` はしない
4. `{{カーソル}}`: 貼る前の入力欄を `FocusedText.probe` で読み、⌘V の後 0.6 秒まで、カーソルがちょうど貼った文字の後ろに来たかを見て（`SnippetPaste.cursorTarget`）、
   来たらその位置から末尾までの長さだけ戻す（`FocusedText.select`）。読めない・長さが合わない（改行の変換・自動の字下げ）ときは動かさない
5. 登録・編集: 定型文の窓（`SnippetEditorWindowController`。設定の窓と同じ作りのふつうの窓）。入口は一覧の ⇧⌘S（定型文の一覧では選んだものを編集、
   履歴の一覧では選んだ項目の平文を本文にした新しい下書き。本体が `store.snapshot` から読む）・メニューの「定型文を編集…」。
   値の検証と保存は `SnippetController` → `SnippetCollection.normalize` の 1 か所（AI の口 #6 も同じ関数を通す）

部品: `Snippet`・`SnippetCollection`・`SnippetTemplate`・`SnippetDateFormat`・`SnippetClipboard`・`SnippetPaste`・`SnippetFile`・`SnippetController`（Core）、
`SnippetViews`（カード・⌘Y・本文の TextKit の組み）・`SnippetEditorModel`・`SnippetEditorView`・`SnippetEditorWindowController`（UI）。

### AI の口（フェーズ6・#6）

```
Claude Code ──stdio（1 行 1 件の JSON-RPC）──> Makurip --mcp ─┐
シェル・スクリプト ──────────────────────> Makurip --ai ──┤ AITools（検証・実行・記録）
                                                              ├─ AIGateway ──> history.sqlite（WAL。アプリと同じ DB）
                                                              ├─ AISnippetTools ──> snippets.json
                                                              └─ SettingsCLI（#4）──> settings.json
                    分散通知 historyDidChange / aiActivity ──> 動いている Makurip（一覧の読み直し・秘密の自動消去・設定画面の記録）
```

1. 入口: 同じ実行ファイルの `--mcp`（`MCPServer.run`。標準入力が閉じるまで）と `--ai`（`AICLI.run`）。どちらも UI・ロック（`instance.lock`）を使わず、
   `AITools` を同じように作る（`main.swift` の `makeAITools`）。CLI のフラグは道具の引数（JSON）に組み直して同じ検証を通す
2. 門: 履歴と定型文の道具は、呼ぶたびに DB の `meta` の `aiAccess` を読む（`AIAccess`）。オフ・DB がない → `aiAccessDisabled`（DB を作らない）。
   オンにするのは設定画面（`AppController.setAIAccess` ← `SettingsAIAccessRow`）だけ。CLI の `disable` はオフにだけできる
3. 追加: 道具の引数 → スナップショット（文字は UTF-8 の平文・画像はその形式のまま・ファイルは file-url と名前の平文）→ `CapturePipeline.process`（種類・秘密・伏せ字。
   コピー元は「AI（相手の名前）」・方法は「それ以外」）→ `addedByAI` を足して `ClipStore.save`（上限は設定ファイルの値）。
   クリップボードにも置くときは `PastePipeline.prepare` の中身に取り込み済みの印（と秘密なら ConcealedType）を足して書く
4. 一覧: `ClipStore.items` → `AIHistoryFilter` → `AIGateway.describe`（形式の情報だけ。言語と秘密の形式はこのプロセスの中で中身を読んで名前だけを返す）
5. 削除: 条件に合う ID を `ClipStore.delete(ids:)` → `scrubDeletedData`（WAL を空に）。件数だけを返す
6. 知らせ: 書いたら `HistoryChangeSignal.post`（object = データフォルダ）。動いている `AppController.externalHistoryDidChange` が一覧を読み直し（`historyDidChange`）、
   `scheduleSecretSweep` で自動消去の時計を掛け直す。記録を足したら `postActivity`（設定画面の記録を描き直す）。定型文はファイルの監視で届く
7. 記録: `AITools.record` が `ai-activity.jsonl` に 1 行（道具・結果・件数と種類の文）。読むだけの設定の道具と `status` は残さない。オフで断ったものは残す

### 一覧（フェーズ2・`Sources/MakuripUI/`）

| 部品 | 役割 |
|---|---|
| `PanelController` | 窓（nonactivating な `KeyablePanel`）・キーのローカル監視・位置・⌘Y の子ウインドウ（`PeekPanel`）。メインメニューがないので検索欄の ⌘A/C/V/X/Z もここで送る |
| `HistoryPanelModel` | 状態（絞り込み・選択・プレビュー・⌘E）と全操作。`handle(_:isComposing:)` がキーマップから操作を引く。単体テストはここを駆動する |
| `HistoryPanelView` / `CardView` / `PeekView` | 試作（`~/dev/makurip-design/ui/shared/panel-b.*`・`base.css`）の寸法と色を写した SwiftUI。文字の行の高さは `CSSText` で CSS の line-height を再現 |
| `ClipContentLoader` | サムネイル・全文・ファイル・色・リッチテキストを、見えたカードと選んだ 1 件だけ読む。画像の縮小はメインスレッドの外。コードの言語・色付きのカード・プレビューの色付けの区間もここでキャッシュする |
| `CodeStyler` / `CodeTextView` | コードとコマンドの色付け（フェーズ3）。カードと ⌘Y のコマンドは SwiftUI の Text（AttributedString）、⌘Y のコードは NSTextView（行番号は `LineNumberRuler`） |
| `CardMouseArea` / `CardMouseView` / `CardMenus`（`CardMenu.swift`・#38） | カードの上に重ねた透明な NSView が、左クリック（押したカードの上で離したら `releaseRow` が貼る）と右クリック・⌃ クリック（`CardMenuModel` の並びを NSMenu に写す）を受ける。SwiftUI のタップでは離した位置と右クリックしたカードが取れないため。スクロールは受けずに外へ流す |

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
| `ClipFlag` | 開いた集合の印。`truncated`（上限で型を落とした）・`secretLikely`（秘密っぽい。フェーズ5）・`secretKnownFormat`（確度が高い秘密。自動消去の対象。フェーズ5）・`addedByAI`（フェーズ6） |
| `SourceApp` | コピーした瞬間に前面にいたアプリ（バンドル ID・名前） |
| `Limits` | 上限の既定値（件数 1000・合計 1 GB・型 1 つ 50 MB・1 件 100 MB・DB に入れる上限 64 KB）。件数と容量は設定で変わる |
| `HotKey` | 仮想キーコード + 修飾キー（Carbon に登録する形。設定ではキーマップの `KeyCombo` を文字で持つ） |
| `AppSettings` | 設定の値（呼び出しキーの動き・候補窓の並び・上限・アプリごとの扱い・定型文の日付の書き方・キーマップ）。ファイルは `settings.json` |
| `Snippet` | 定型文 1 件（id・名前・略語・本文・時刻）。並びは `SnippetCollection`、ファイルは `snippets.json`（履歴の DB とは別） |

後のフェーズでの載せ方:
- ~~フェーズ2（絞り込み）: `kind`・`copyMethod`・`source` は列として持っている。日本語検索の正規化は `preview_text` を元に別の列か索引を足す（スキーマ版を上げる）~~
- フェーズ2（済）: 絞り込みと日本語検索はメモリの中で行う（DB の列は足していない。スキーマ版 1 のまま）。全件を読んでも 5000 件で 23 ms、温まった後の検索が 15 ms で足りるため。1 万件を大きく超える上限にするなら、正規化した列と FTS を足す
- フェーズ2.5（候補窓・済）: 位置は `PanelPlacement.frame(... side: .beside(rowOffset:))`、手がかりは `InsertionPointLocator`。DB は変えていない（仮に貼っている間は `touch` せず、確定したときだけ先頭へ移す。回している間の並びは始めた時点のものを固定して持つ）
- フェーズ3（プレビュー・済）: DB は変えていない。言語は表示のときに一覧の平文から判定してメモリにキャッシュする（列を足すと判定を直すたびに作り直しが要るため）。コピー元のページは取り込み時の `sourceURL` をそのまま使う
- フェーズ4（設定・済）: データフォルダの `settings.json`（DB は変えていない）。`ClipStore.limits` を変えられるようにし（`setLimits`）、ホットキーは設定が変わるたびに付け直す
- ~~フェーズ5（秘密）: 判定結果を `ClipStore.setFlags(_:id:)` で `secretLikely` にする。判定は形式だけで行い、中身を外へ出さない~~
- フェーズ5（秘密・済）: 判定は取り込みの中（`CapturePipeline`）で行い、`CapturedClip.flags` に `secretLikely`・`secretKnownFormat` を入れて保存する。
  `preview_text` は伏せ字で持つ。既存の履歴は `SecretRescan` が `ClipStore.addFlags(_:maskedPreview:id:)` で 1 回だけ当て直す。DB は版 2（`meta` 表）
- ~~フェーズ6（AI の口）: 追加は `CapturedClip` を組み立てて `ClipStore.save`（`addedByAI` の印）。AI へは `MetadataDump` 相当の形式情報だけを返す。
  定型文の追加・編集を扱うなら `SnippetController`（動いているアプリ）か `SnippetFile` + `SnippetCollection`（別のプロセス）を使う（検証は同じ `normalize`）~~
- フェーズ6（AI の口・済）: DB の表は変えていない（版 2 のまま。`meta` に `aiAccess`・`aiAccessChangedAt` の鍵を足しただけ）。追加は `CapturePipeline` → `addedByAI` → `ClipStore.save`。
  AI へ返すのは形式の情報だけ（内容のハッシュ・URL・秘密の項目の大きさは返さない。門の外の `MetadataDump` も #23 で同じ基準にそろえた）。
  AI の追加は人のコピーと別のハッシュの空間（`ContentHasher.aiAdded`。#24）。定型文は別のプロセスから `SnippetFile` + `SnippetCollection`。
  操作の記録は DB でなくデータフォルダの `ai-activity.jsonl`
- フェーズ7（定型文・済）: DB は変えていない（#5 の版 2 のまま）。履歴とは別のファイル `snippets.json` に持つ

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

## 技術選定（フェーズ5・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| 秘密の判定 | 自前（既知の接頭辞の正規表現・文脈（名前・ヘッダー）・ランダムさの点数）。確度を「高」「中」に分ける | gitleaks・trufflehog の規則を取り込む（数百の規則とエントロピーの閾値。Go の実行ファイルか規則の TOML を持ち込むことになり、依存が増え、クリップボードの短い断片には誤判定が多い）、エントロピーだけ（UUID・ハッシュ・Base64 の画像を拾う）、機械学習の分類器（モデルが要る・説明しにくい）。自前なら陽性・陰性の例をテストで固定して調整でき、外部ライブラリ 0 のまま |
| 伏せ字の持ち方 | 取り込みのときに `preview_text` を伏せ字にして保存する | 表示のときに毎回伏せる（伏せ忘れた画面・検索・後のフェーズの口から中身が漏れうる）。保存の時点で伏せておけば、`previewText` を使うどこからも中身が出ない。本当の中身は `representation` にあり、⌥ のときだけ読む |
| 自動で消すもの | 確度「高」だけ。ピン留めは消さない | 判定したものをすべて消す（ID やファイル名をランダムな文字列と誤判定すると、勝手に消えて困る）、消さずにマスクだけ（AI の口（#6）やディスクに長く残る） |
| 時間の数え方 | 最後に使ってから（既定 10 分）。時刻で掛ける 1 回きりのタイマー | 取り込んでから（使っている途中で消える）、一定間隔の見回り（消える時刻がぶれる・無駄に起きる） |
| 当て直しの印 | DB の `meta` 表（版 2）に判定の版 | 毎回起動時に全件を判定（2 万件では起動が遅くなる）、設定ファイルに書く（設定は人と AI が書き換える場所で、内部の状態を置かない） |
| 候補窓の ⌥ | 横取りのタップに `flagsChanged` を足し、食べずに素通し | 窓の側で `NSEvent` のグローバル監視（タップと別の経路で修飾キーを見ることになり、閉じたときの後始末が 2 か所になる） |

## 技術選定（フェーズ6・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| MCP の実装 | 自前の JSON-RPC 2.0（stdio・1 行 1 件。`MCPServer` 約 250 行）。扱うのは initialize・ping・tools/list・tools/call だけ | 公式の Swift SDK（modelcontextprotocol/swift-sdk。外部ライブラリが 0 → 1 になり、swift-log などの依存も入る。版の追従が要る。使うのは道具だけで、resources・prompts・HTTP の搬送・相手への要求は要らない）、TypeScript・Python の SDK で別のサーバーを作る（Node か Python が要り、DB・判定・伏せ字のコードを二重に持つことになる）。道具だけの stdio なら仕様は小さく、単体テストで往復を固定できる |
| 入口 | 同じ実行ファイルの `--mcp` と `--ai`（.app の中の Makurip） | .app に別の実行ファイルを入れる（署名・組み立てが増え、判定と DB のコードを 2 つのターゲットに持つ）、動いているアプリに XPC・ソケットでつなぐ（アプリが動いていないと使えない・口が 1 つ増える・権限の扱いが増える）。#4 の `--settings` と同じ形で、アプリが動いていなくても使え、隔離（`--data-dir`）もそのまま効く |
| オン・オフの置き場所 | 履歴の DB の `meta` 表（`aiAccess`）。設定のスキーマ・設定ファイルには載せない | 設定の項目にする（AI が `--settings set`・MCP の `settings_set`・`settings.json` の書き換えで自分で口を開けられる。#4 の所見 6 と同じ理由で不可）、UserDefaults（`defaults write` で簡単に書ける・`--data-dir` で隔離できない）、キーチェーン（オフの状態から AI が `security` で項目を作れば同じこと。重い）。DB の値は「ふつうの口」からは書けない。直接 `sqlite3` で書くことは防げない（限界として書いた） |
| 動いているアプリへの知らせ | 分散通知（object = データフォルダ）+ 一覧は開くたびに読み直す | DB のファイルを見張る（WAL の書き込みは頻繁で、アプリ自身の書き込みと見分けにくい）、定期的に `PRAGMA data_version` を読む（遅い・無駄に起きる）、XPC（上と同じ理由）。知らせは「読み直す」だけなので、誰が送っても害がない。届かなくても、一覧は開くたびに読み、秘密は次の見回りで消える |
| 同じ DB を 2 つのプロセスで使う | SQLite の WAL・`busy_timeout` 2 秒・複数の文をまとめて書く操作は `BEGIN IMMEDIATE`（#1 からのまま） | DB をアプリだけが触り、MCP はアプリに頼む（アプリが動いていないと足せない）。WAL なら読みは書きを待たず、書きどうしは SQLite のロックで順に並ぶ |
| AI へ返す形式の情報 | 種類・時刻・アプリ・型名・大きさ・言語・秘密の印と形式名。ハッシュ・URL（ホスト名を除く）・ファイル名・秘密の項目の大きさは返さない | `MetadataDump` をそのまま返す（当時はハッシュの先頭で短い秘密を当てられ、秘密の長さが分かった。門の外にあったので #23 でダンプも同じ基準にした）、何も返さず件数だけ（「さっきの API キー」を選んで消すのに、どれが秘密かが分からない） |
| AI の追加と人のコピーの合流（#24） | 別のハッシュの空間（`ContentHasher.aiAdded`）。AI が足したもの同士だけ合流する | 合流しても応答は常に `inserted`（件数・一覧の回数と並びで、あったかが分かる）、AI の追加は毎回別の項目（AI が同じものを足すたびに並ぶ）、秘密の項目にだけ合流しない（判定が見逃した短いパスワードは当てられる） |
| 設定を変える道具（#26） | `settings_set`・`settings_reset` を門の内側に置き `destructiveHint: true`。読む道具は門の外。人の CLI（`--settings`）は門の外 | 門の外のまま説明だけ足す（MCP だけのクライアントが、オフのまま上限を下げて履歴を消せる）、履歴を減らす向きの変更だけ門に入れる（項目ごとの向きの判定が要り、漏れやすい。既定に戻すのも上限を下げうる）、CLI にも門（ユーザー自身が CLI で設定できなくなる。シェルからは `sqlite3` でも開けられるので守りにならない） |
| 操作の記録 | データフォルダの `ai-activity.jsonl`（`flock` で足す・500 件） | DB に表を足す（スキーマの版が上がる。#7 と版が重なりうる）、os.Logger だけ（設定画面で見せられない） |

## 技術選定（フェーズ7・比べた代替）

| 何を | 採用 | 比べた代替と、採らなかった理由 |
|---|---|---|
| 定型文の保存先 | データフォルダの JSON ファイル（`snippets.json`）+ ファイルの監視 | 履歴の SQLite に表を足す（履歴の上限・消去・作り直しと同じ場所に置くと、消してはいけないものが近くなる・スキーマ版が上がる・人と AI が中を読みにくい）、UserDefaults（`--data-dir` で隔離できない・別のプロセスから書くとキャッシュと食い違う。設定と同じ理由）。数百件でも数十 KB で、全体を置き換えで書いて足りる。設定と同じ作りなので、AI の口（#6）が別のプロセスから書いても動いているアプリがすぐ読み直す |
| 登録・編集の入口 | 専用の窓（設定の窓と同じ作り）+ 一覧の ⇧⌘S・メニュー | 一覧のパネルの中で編集する（パネルは前面を奪わず、↩ が貼り付け・フォーカスが外れたら閉じる作りなので、複数行の本文と日本語入力の変換を落ち着いて打てない）、設定の窓の行にする（試作の設定シートはキーで 1 行ずつ選ぶ 1 つの一覧で、複数行の入力欄が合わない）。試作に編集の画面はないので、見た目は設定シートにそろえた |
| 本文の描画（カード・⌘Y） | TextKit（`NSLayoutManager`。段落の最小・最大の行の高さを CSS の line-height に固定、差し込みは `NSTextAttachment` の札） | SwiftUI の `Text` に `Text(Image)` で札を入れる（基準線より下に出る分と `baselineOffset` の分だけ行が高くなり、札のある行が試作より約 5pt 高い。CSS の inline-block は行の高さを変えない）。行数の切り方も CSS の line-clamp と同じにした（先頭の 3 行で切って末尾に「…」。空の行も 1 行） |
| `{{クリップボード}}` の元 | 履歴のいちばん新しい文字（秘密っぽい項目は飛ばす。試作と同じ） | いまのペーストボードを読む（記録しなかったコピー＝パスワード管理アプリ・記録しないアプリ・一時停止中のものを定型文に混ぜて貼ってしまう） |
| `{{カーソル}}` | 貼った後に AX で文字カーソルを戻す（確かめられるときだけ） | ← を文字数ぶん送る（改行・絵文字・自動整形で数がずれる。前面のアプリにキーを送る）、消すだけ（試作の見本の動き。名前の意味がなくなる） |

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
- 秘密の判定を変える: `SecretDetectorTests` に陽性と陰性の例を足し（本物の形式どおりの値は直書きせず、`FakeSecret` で実行時に作る）、
  `SecretDetector.version` を上げる（既存の履歴に 1 回だけ当て直す）。`.agent/conventions.md` の「秘密の判定」の一覧と限界を直す。
  隔離 E2E は `scripts/e2e/secrets.sh`（`make e2e-secrets`）
- 秘密の表示・候補窓の扱いを変える: `SecretDisplayTests`・`CandidateSecretTests`、見た目は `make ui-compare` の `secret-*`・`candidate-secret-*`
- 検索を変える: `SearchTextTests` に例を足し、`.agent/conventions.md` の「検索」の限界を見直す。試作（`core.js`）と振る舞いを変えるときは理由を書く
- 見た目を変える: `make ui-compare` で試作と並べて確かめ、`design/ui-compare/README.md` の「意図して変えたところ」を直す
- 定型文の差し込みを足す: `SnippetPlaceholder`（名前・説明）と `SnippetTemplate.expand`・`AppController.snippetContext`。`SnippetTemplateTests` に壊れた記法の例を足し、`.agent/api.md` の「定型文」と定型文の窓の説明を直す
- 定型文の検証を変える: `SnippetCollection.normalize` の 1 か所（窓・ファイルの読み込み・AI の口が同じ関数を通す）。`SnippetCollectionTests`・`SnippetFileTests`
- AI の口に道具を足す: `AITools.Name`・道具の一覧（説明は AI が読んで使い分けられるように）・`perform`・引数の検証（`Arguments.only` で知らない引数を誤りに）。
  履歴を触るなら `needsAccess: true`。CLI の命令は `AICLI.commands`。返す JSON に中身・URL・ファイル名・ハッシュを入れない（`AIListTests`・`MCPServerTests` の漏れの検査に通す）。
  **AI の口をオンにする道具・命令は足さない**（`AIAccessTests`）。`docs/ai-mcp.md` の一覧と対応表、`.agent/api.md` の「AI の口」を直す。隔離 E2E は `make e2e-ai`
- 一覧で返す形式の情報を変える: `AIGateway.describe`。足す情報が中身を推せないか（長さ・ハッシュ・名前）を考え、`docs/ai-mcp.md` の「守っていること」を直す
- 表示名・バンドル ID・版を変える: `Sources/Makurip/Info.plist` の 1 か所だけ

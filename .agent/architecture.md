# アーキテクチャ

## モジュール構成（SwiftPM のターゲット）

```
Makurip（実行ファイル）── MakuripUI（仮の一覧。フェーズ2で丸ごと差し替え）
     │                         │
     └──────────┬──────────────┘
                ▼
          MakuripCore（UI に依存しない本体）
```

| ターゲット | 責務 | 依存先 |
|---|---|---|
| `MakuripCore` | モデル・判定（純粋関数）・ペーストボードの読み書き・監視・SQLite のストア・メタデータの書き出し・UI との約束（`HistoryPresenting` / `HistoryActions`） | Foundation・AppKit（NSPasteboard だけ）・CryptoKit・libsqlite3 |
| `MakuripUI` | 仮の一覧（NSPanel + SwiftUI）。入口は `HistoryUIFactory.make(actions:)` | MakuripCore |
| `Makurip` | AppDelegate（`AppController`）・メニューバー・ホットキー（Carbon）・⌘C の監視・貼り付け（⌘V 送信）・起動引数・検証用の遠隔操作 | MakuripCore・MakuripUI・Carbon |
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

1. ⌃⌘V（`HotKeyCenter`）→ `AppController.toggleHistory` — 前面のアプリを `previousApp` に控えて一覧を開く
2. 一覧で Enter → UI が自分を閉じてから `HistoryActions.paste(itemID:)`
3. `ClipStore.snapshot` で全項目・全型を読み、`PasteboardWriter.write` でペーストボードへ戻す
4. 書いたあとの changeCount を `monitor.acknowledgeOwnWrite` に渡す（新しい履歴にしない）。`store.touch` で先頭へ移す
5. `Paster` が `previousApp` を前面に戻し、その pid 宛てに ⌘V を送る（アクセシビリティの許可が要る）

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
- フェーズ2（絞り込み）: `kind`・`copyMethod`・`source` は列として持っている。日本語検索の正規化は `preview_text` を元に別の列か索引を足す（スキーマ版を上げる）
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

## 変更時の波及

- DB スキーマを変える: `ClipStore.migrate()` に版を足し、`.agent/api.md` の「DB スキーマ」と `MetadataDump` を同時に直す
- 種類の判定を変える: `KindClassifierTests` に入力例を足し、`.agent/conventions.md` の「判定の限界」を見直す
- UI を差し替える（フェーズ2）: `Sources/MakuripUI/` を置き換え、`HistoryUIFactory.make(actions:)` を同じ名前で用意する。E2E（`scripts/e2e/paste.sh`）は `debugState` の `rowCount` / `query` と `-MakuripPanelScreen` を使っているので、新しい UI でも同じ鍵を返すか、スクリプトを直す
- 表示名・バンドル ID・版を変える: `Sources/Makurip/Info.plist` の 1 か所だけ

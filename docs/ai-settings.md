# AI エージェントに Makurip の設定を頼む

Claude Code などの AI エージェントに「候補窓は出さないで」「呼び出しを ⌥V にして」と頼むと、
エージェントが Makurip の CLI で設定を読み、当てはまる項目を見つけて書き換える。そのための説明。

- 設定項目の一覧（スキーマ）は 1 つだけで、設定画面（⌘,）と CLI が同じものを使う。MCP（#6）も同じものを使う予定
- 設定に秘密は入っていない。AI が読むのも書くのもよい。**履歴の中身はこの CLI では見られない**
- 動いている Makurip は設定ファイルの変化を見て、すぐに反映する（再起動は要らない）

## エージェントの手順

```sh
MAKURIP=~/Applications/Makurip.app/Contents/MacOS/Makurip

# 1. 一覧を読む（先頭に案内。項目ごとに ID・型・既定値・いまの値・取りうる値・説明・頼みの例と実行できるコマンド）
$MAKURIP --settings schema --json

# 2. 頼みに当たる項目を label・description・examples から選び、変える
$MAKURIP --settings set hotkeyMode paste

# 3. 確かめる（* は既定から変えた項目。キーの重なり・読めなかった項目も出る）
$MAKURIP --settings list
```

| 命令 | 使いどころ |
|---|---|
| `schema [--json]` | 項目の一覧。AI はまずこれを読む |
| `list [--json]` | いまの値・既定から変えた項目・キーの重なり・設定ファイルの読めなかった項目 |
| `get <ID> [--json]` | 1 つの値 |
| `set <ID> <値>...` | 変える。キーは複数を空白で区切る（`set keys.prev ↑ ⌃P`）。`none` で空にする。`[...]`・`{...}` は JSON として読む |
| `add <ID> <値>` / `remove <ID> <値>` | 並び（`excludedApps`）・アプリごとの項目（`candPasteTiming` は `バンドル ID=値`）・キーに 1 つ足す / 外す |
| `reset <ID>...` / `reset --all` | 既定に戻す |
| `--take-over` | キーが他の操作と重なったら、その操作から外して付け替える（付けないと拒否する） |

- 検証に通らない値は、理由を付けて拒否する（終了コード 2・理由は標準エラー）。理由を読んで値を直すか、ユーザーに確かめる
- 使い方の誤りは終了コード 1、設定ファイルに書けないときは 3
- アプリは名前でなく**バンドル ID** で書く。名前から調べるには `osascript -e 'id of app "Slack"'`。
  入っていないアプリでも入れられる（「この Mac に見つからない」と注意を出す）
- キーの書き方: `⌃⌘V`・`⌥V`・`⇧↩`・`esc`・`⌘1–9`。修飾キーは記号か `ctrl+`・`opt+`・`shift+`・`cmd+`（`ctrl+cmd+v`）。
  特殊キーは `↩ ⇥ esc space ⌫ ↑ ↓ ← → F1〜F20`
- 設定ファイル（`<データフォルダ>/settings.json`）は直接書き換えない（検証を通すため）。場所は `--settings path`
- 検証用に隔離したインスタンスの設定は `--data-dir <フォルダ>` を付ける（`Makurip --data-dir DIR --settings ...`）

### キーの決まり（拒否される組み合わせ）

| 範囲 | 決まり |
|---|---|
| どこからでも効くキー（`keys.open`・`keys.openList`） | ⌃・⌥・⌘ のどれかが要る（⇧ だけは不可）。⌘ だけ（⌘C など）は不可。macOS の操作（⌃space・⌘⇧4 など）は不可。1 つだけ。F1〜F20 は修飾キーなしでよい |
| 一覧・候補窓のキー | 文字を打つキー（英字・数字・記号・space）は ⌘・⌃・⌥ と一緒に。一覧では検索欄の ⌘A・⌘C・⌘V・⌘X・⌘Z は不可 |
| 番号の操作（`keys.quick`） | 「修飾キー + 1〜9」（`⌘1–9`）だけ |
| 重なり | 同じ範囲（どこからでも効くキーと一覧のキーは同じ範囲として見る。候補窓は候補窓どうし）で同じキーは拒否。`--take-over` で付け替え |

## 頼みと項目の対応表

`schema` の `examples` に載せてあるもの。下の 5 つ（太字）は #4 の受け入れ条件で、2026-10-31 に隔離したフォルダで実際に CLI に通した（結果は下）。

| 頼み | 項目 | 値 | コマンド |
|---|---|---|---|
| **候補窓は出さないで** | `hotkeyMode`（呼び出しキーの動き） | `paste`（すぐ貼るだけ） | `set hotkeyMode paste` |
| **呼び出しを ⌥V にして** | `keys.open`（履歴を呼び出す） | `⌥V` | `set keys.open ⌥V` |
| **履歴は 200 件まで** | `maxItems`（保存する件数の上限） | `200` | `set maxItems 200` |
| **Slack では確定するまで貼らないで** | `candPasteTiming`（確定まで貼らないアプリ） | `com.tinyspeck.slackmacgap` → `onCommit` | `add candPasteTiming com.tinyspeck.slackmacgap=onCommit` |
| **候補窓の並びを予測変換みたいに** | `candOrder`（候補窓の並び） | `ime`（予測変換式） | `set candOrder ime` |
| 貼り付けのときに UI を出さないで | `hotkeyMode` | `paste` | `set hotkeyMode paste` |
| ⌃⌘V で一覧を開くようにして | `hotkeyMode` | `list` | `set hotkeyMode list` |
| 履歴の容量は 2GB まで | `maxTotalMB` | `2048`（`2GB` とも書ける） | `set maxTotalMB 2GB` |
| Safari でコピーしたものは残さないで | `excludedApps` | `com.apple.Safari` | `add excludedApps com.apple.Safari` |
| ターミナルでもすぐ貼って | `candPasteTiming` | `com.apple.Terminal` → `immediate` | `add candPasteTiming com.apple.Terminal=immediate` |
| Mac を起動したら自動で立ち上げて | `launchAtLogin` | `true` | `set launchAtLogin true` |
| 候補窓は Enter だけで確定 | `keys.candCommit` | `↩` | `set keys.candCommit ↩` |
| 履歴の削除は ⌥⌫ にして | `keys.delete` | `⌥⌫` | `set keys.delete ⌥⌫` |
| 定型文の日付をハイフン区切りにして | `snippetDateFormat`（日付の書き方） | `hyphen`（2026-10-31） | `set snippetDateFormat hyphen` |
| 日付は「2026年10月31日」のように | `snippetDateFormat` | `japanese` | `set snippetDateFormat japanese` |
| 定型文を開くキーを ⌘J にして | `keys.snippets`（定型文を表示） | `⌘J` | `set keys.snippets ⌘J` |

補足:

- 「Slack では確定するまで貼らないで」は、何もしなくても既定でそうなっている（ターミナルとチャットは確定まで貼らない。
  `schema --json` の `candPasteTiming.builtIn` が既定の一覧）。明示しておくと、既定の一覧が変わってもそのまま保たれる
- 「呼び出しを ⌥V にして」は呼び出しキーだけを変える。候補窓の「一覧に広げる」（`keys.candExpand`、既定 ⌃⌘V）は別の項目なので、
  揃えたいときは `set keys.candExpand ⌥V` も行う
- ⌥V は、どのアプリでも ⌥V で打つ文字（「√」など）の代わりに Makurip を呼ぶようになる。ユーザーが頼んだのでそのまま入れる

### CLI に通した結果（2026-10-31・隔離したフォルダ・アプリは動かしていない）

```
$ Makurip --settings set hotkeyMode paste
hotkeyMode（呼び出しキー（⌃⌘V）の動き）を「paste（すぐ貼るだけ）」にしました。動いている Makurip は、設定ファイルの変化を見てすぐに反映します。
$ Makurip --settings set keys.open ⌥V
keys.open（履歴を呼び出す（どこからでも））を「⌥V」にしました。…
$ Makurip --settings set maxItems 200
maxItems（保存する件数の上限）を「200 件」にしました。…
$ Makurip --settings add candPasteTiming com.tinyspeck.slackmacgap=onCommit
candPasteTiming（確定まで貼らないアプリ）を「com.tinyspeck.slackmacgap=onCommit」にしました。…
$ Makurip --settings set candOrder ime
candOrder（候補窓の並び）を「ime（予測変換式）」にしました。…
$ Makurip --settings list --json | jq -c '{changed, conflicts, issues}'
{"changed":["hotkeyMode","candOrder","maxItems","candPasteTiming","keys.open"],"conflicts":[],"issues":[]}
$ Makurip --settings list | grep '^\*'
* hotkeyMode = paste　呼び出しキー（⌥V）の動き
* candOrder = ime　候補窓の並び
* maxItems = 200　保存する件数の上限
* candPasteTiming = com.tinyspeck.slackmacgap=onCommit　確定まで貼らないアプリ
* keys.open = ⌥V　履歴を呼び出す（どこからでも）
```

どれも終了コード 0。動いているインスタンスにすぐ効くことは `scripts/e2e/settings.sh`（`make e2e-settings`）で確かめている
（⌃⌘V の動き・呼び出しキー・件数の上限。状態の書き出しと `--dump-metadata` で見る）。

### 拒否の例

```
$ Makurip --settings set keys.open V
変えられない（keys.open）: V: 修飾キーなし（⇧ だけも）では、どのアプリで打っても横取りしてしまう。⌃・⌥・⌘ と組み合わせる（例: ⌃⌘V・⌥V）
$ Makurip --settings set keys.method ⌘E
変えられない（keys.method）: ⌘E は「コピー元アプリを選ぶ」（keys.app）と重なる。そちらを先に変えるか、--take-over を付けて付け替える
$ Makurip --settings set maxItems 5
変えられない（maxItems）: 値は 10〜20000 の整数（単位は 件。いま: 5）
$ Makurip --settings add candPasteTiming Slack=onCommit
変えられない（candPasteTiming）: 「Slack」はバンドル ID の形ではない。バンドル ID（例: com.tinyspeck.slackmacgap）で書く。アプリ名から調べるには osascript -e 'id of app "アプリ名"'
```

## 項目の一覧

`--settings schema` が正本（ここは要約）。キーの項目（`keys.<操作 ID>`）は全操作ぶんあり、ID と既定は `.agent/api.md` の「キーマップ」。

| ID | 名前 | 型 | 既定 |
|---|---|---|---|
| `hotkeyMode` | 呼び出しキーの動き | `paste` / `candidate` / `list` | `candidate` |
| `candOrder` | 候補窓の並び | `terminal` / `ime` | `terminal` |
| `launchAtLogin` | ログイン時に起動 | true / false | false |
| `maxItems` | 保存する件数の上限 | 整数 10〜20000（件） | 1000 |
| `maxTotalMB` | 容量の上限 | 整数 100〜20480（MB） | 1024 |
| `excludedApps` | 記録しないアプリ | バンドル ID の並び | なし |
| `candPasteTiming` | 確定まで貼らないアプリ | バンドル ID → `immediate` / `onCommit` | なし（ターミナル・チャットは既定で `onCommit`） |
| `candIdleTimeout` | 候補窓を自動で閉じるまで（詳細） | 数 2〜120（秒） | 10 |
| `candReplaceMethod` | 差し替え方式の決め打ち（詳細・画面には出さない） | バンドル ID → `selectRange` / `undo` / `deferred` | なし |
| `snippetDateFormat` | 日付の書き方（定型文の `{{日付}}`） | `slash`（2026/10/31）/ `hyphen`（2026-10-31）/ `japanese`（2026年10月31日） | `slash` |
| `keys.<操作 ID>` | 各操作のキー（26 個。定型文の `keys.snippets`・`keys.editSnippet` を含む） | キーの並び | 試作どおり |

設定にしないもの: パスワード等の印（ConcealedType）が付いたコピーを保存しない動き（プライバシーを守る振る舞いは、
AI や他のアプリが設定ファイルを書き換えても弱められないようにしてある）・監視の間隔などの内部の定数。

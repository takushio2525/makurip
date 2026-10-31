# AI エージェントから Makurip を使う（MCP・`--ai` の CLI）

Claude Code などの AI エージェントから、MCP（と同じ機能の CLI）で次のことができる。

- 履歴への追加（「このコマンドを履歴に入れておいて」）と定型文の登録
- 形式の情報だけの一覧（種類・時刻・コピー元アプリ・大きさ・言語・秘密の印。**中身は見せない**）
- 秘密っぽいもの（API キー・トークン・秘密鍵・パスワードなど）を消す（「さっきの API キーを履歴から消して」）
- 条件（種類・期間・AI が追加したもの）での削除
- 設定の読み書き（「候補窓は出さないで」。#4 の設定の CLI と同じ検証。手順と対応表は `docs/ai-settings.md`）

履歴には秘密も入りうるので、**履歴と定型文の道具と、設定を変える道具は、設定画面で「AI の口」をオンにしたときだけ**使える。既定はオフで、
AI・CLI・MCP からはオンにできない（AI が自分で口を開けないようにするため）。使い終わったらオフにする。
設定を読む道具（`settings_schema`・`settings_list`・`settings_get`）は、オフでも使える（設定に秘密は入っていない）。
設定を変える道具（`settings_set`・`settings_reset`）がオンのときだけなのは、件数の上限を下げると履歴が消え、記録しないアプリを外すと記録が増えるため（#26）。

## 1. 使えるようにする（ユーザーが 1 回だけ）

1. Claude Code に登録する（ターミナルで実行。`--scope user` でどのフォルダの Claude Code からも使える）

   ```sh
   claude mcp add --scope user makurip -- ~/Applications/Makurip.app/Contents/MacOS/Makurip --mcp
   ```

   Makurip の設定画面の「AI の口」に、この Mac のパスを入れた同じコマンドと「コピー」ボタンがある。
   登録できたかは `claude mcp list`、外すときは `claude mcp remove --scope user makurip`。
2. Makurip の設定画面（メニューバーの Makurip → 設定…）の「AI の口」をオンにする（切り替えを押すか、行を選んで ↩）
3. Claude Code に頼む。終わったら設定画面でオフにする（⌫ でも初期値のオフに戻る。「すべて初期値に戻す」でもオフになる）

AI が行ったことは、設定画面の「AI の口」の下と `Makurip --ai log` で見られる（メタデータだけ。中身は残さない）。

## 2. 守っていること

| 返すもの（形式の情報） | 返さないもの |
|---|---|
| id（UUID）・作った時刻・最後に使った時刻・回数 | 中身（平文・画像・データ）・一覧用の平文（伏せ字のものも） |
| 種類（`text`・`code`・`command`・`url`・`image`・`file` など）・コードの言語名 | コピー元ページの URL のパスとクエリ（**ホスト名だけ**返す。トークンが入りうるため） |
| コピー元アプリ（バンドル ID・名前）・コピー方法・ピン留め・AI が追加したか | ファイルの名前とパス（名前に秘密が入りうるため） |
| 型名（UTI）の並び・項目数・大きさ（バイト・文字数・行数） | 内容のハッシュ（短い秘密は、推した値のハッシュと照らし合わせて当てられるため） |
| 秘密の印（確度「高」「中」）と形式の名前（`githubToken`・「API キーの形式」など）・自動で消えるか | **秘密の項目の大きさ・長さ**（伏せ字が元の長さを隠すのと同じ。秘密っぽい定型文も `size: "hidden"`） |
| 定型文の名前（名前を付けたものだけ。秘密っぽければ伏せ字）・略語・文字数（秘密っぽくなければ）・差し込み | 定型文の本文と、本文の 1 行目から作った名前 |
| 追加の結果（id・種類・秘密の確度） | 推した文字列が人の履歴にあるか（AI の追加は人のコピーに合流させず、いつも新しい項目になる） |

- 種類・言語・秘密の形式は、Makurip のプロセスの中で中身を読んで判定し、結果の名前だけを返す（中身は外に出さない）
- 追加・削除の結果も、id・種類・印・件数だけ（足した文字を返さない）。誤りの文にもパスや中身を入れない
- AI が足したものには `addedByAI` の印が付き、一覧の「コピー元アプリ」は「AI（相手の名前）」になる（その名前で絞り込める）
- AI が足したものは、人がコピーした同じ内容に合流しない（合流すると「先頭へ移した」の 1 語で、推した文字列が人の履歴にあるかが分かり、
  人の項目のコピー元も AI に書き換わるため。#24）。結果の `result` は、AI が前に足した同じ内容があったときだけ `movedToTop`、ほかは `inserted`
- メタデータの書き出し（`Makurip --dump-metadata`）は AI の口の門の外にあるが、同じ基準で内容のハッシュと秘密の項目の大きさを出さない（#23）
- AI が秘密っぽい形式を足したら、ふつうのコピーと同じく伏せ字で入り、確度「高」は時間が来ると自動で消える
- AI の口のオン・オフは設定ファイル（`settings.json`）と設定のスキーマに載せず、履歴の DB の `meta` 表に置く（設定の CLI・MCP の設定の道具・設定ファイルの書き換えではオンにできない）

## 3. 道具の一覧

| 道具 | 使いどころ | 主な引数 | 返すもの | オフのとき |
|---|---|---|---|---|
| `status` | オンか・Makurip が動いているか | なし | `aiAccess`・`appRunning`・（オンなら）件数 | 使える |
| `add_to_history` | 履歴に 1 件足す | `text` か `imagePath`（画像の絶対パス）か `filePaths`（絶対パスの並び）・`copyToClipboard`・`pin` | id・種類・秘密の確度・クリップボードに置いたか | 断る |
| `list_history` | 形式の情報の一覧（新しい順） | `limit`（既定 20・最大 200）・`kind`・`secret`（`any`/`high`/`medium`/`none`）・`addedByAI`・`pinned`・`withinMinutes`・`olderThanMinutes`・`sourceApp` | 全件数・合った件数・項目の形式の情報 | 断る |
| `delete_secrets` | 秘密っぽいものを消す | `confidence`（`high` 既定 / `any`）・`withinMinutes`・`includePinned`・`dryRun` | 消した件数（`dryRun` なら消すはずの件数） | 断る |
| `delete_history` | 条件に合うものを消す（条件は 1 つ以上） | `ids`・`kind`・`secret`・`addedByAI`・`withinMinutes`・`olderThanMinutes`・`sourceApp`・`includePinned`・`dryRun` | 消した件数 | 断る |
| `add_snippet` | 定型文を登録 | `body`・`name`・`abbreviation` | id・名前・文字数・差し込み | 断る |
| `list_snippets` | 定型文の名前と形式の一覧 | `limit` | 名前・略語・文字数・行数・差し込み・時刻 | 断る |
| `delete_snippets` | 定型文を消す | `ids` | 消した件数 | 断る |
| `settings_schema` | 設定項目の一覧（まず読む） | なし | `--settings schema --json` と同じ | 使える |
| `settings_list` / `settings_get` | いまの値 | `id` | 値 | 使える |
| `settings_set` | 設定を変える（上限を下げると履歴が消える。`destructiveHint: true`） | `id`・`value`・`operation`（`set`/`add`/`remove`）・`takeOver` | 入れた値（拒否なら理由） | 断る |
| `settings_reset` | 既定に戻す（上限が下がると履歴が消える。`destructiveHint: true`） | `ids` か `all` | 戻した ID | 断る |

- 期間（`withinMinutes`・`olderThanMinutes`）は「最後にコピー・使った時刻」で見る（一覧の並びと同じ）
- ピン留めは、`includePinned: true` を付けたときだけ消す
- 消したものは元に戻せない。消す範囲に迷ったら `dryRun: true` で数えて、ユーザーに確かめる
- 失敗（オフ・入力の誤り・設定の拒否）は `isError: true` の結果で返し、`structuredContent.error` に種類（`aiAccessDisabled`・`invalidArguments`・`settingsRejected`・`unavailable`）、本文に理由の文を入れる。理由を読んで直すか、ユーザーに伝える
- 知らない引数は誤りにする（綴りの誤りを黙って無視しない）

## 4. 頼みと道具の対応表

| 頼み | 道具 | 引数 |
|---|---|---|
| **さっきの API キーを履歴から消して** | `delete_secrets` | `{"withinMinutes": 30}`（確度「高」だけ。件数を先に見るなら `"dryRun": true`） |
| **このコマンドを履歴に入れておいて** | `add_to_history` | `{"text": "<コマンド>"}` |
| **候補窓は出さないで** | `settings_set` | `{"id": "hotkeyMode", "value": "paste"}` |
| このコマンドをクリップボードにも入れて | `add_to_history` | `{"text": "<コマンド>", "copyToClipboard": true}` |
| このスクショを履歴に入れて | `add_to_history` | `{"imagePath": "/Users/…/shot.png"}` |
| 履歴に秘密っぽいものが残っていないか見て | `list_history` | `{"secret": "any"}`（形式の名前と件数だけが分かる） |
| ランダムな文字列も含めて、秘密っぽいものを全部消して | `delete_secrets` | `{"confidence": "any"}`（ピン留めは残る） |
| AI が入れたものを全部消して | `delete_history` | `{"addedByAI": true}`（先に `"dryRun": true` で数える） |
| 1 時間以内にコピーした画像を消して | `delete_history` | `{"kind": "image", "withinMinutes": 60}` |
| 1 週間より前の履歴を消して | `delete_history` | `{"olderThanMinutes": 10080}`（ピン留めは残る） |
| いつもの挨拶文を定型文にして | `add_snippet` | `{"body": "<本文>", "name": "挨拶"}` |
| 呼び出しを ⌥V にして | `settings_set` | `{"id": "keys.open", "value": "⌥V"}` |
| Safari でコピーしたものは残さないで | `settings_set` | `{"id": "excludedApps", "operation": "add", "value": "com.apple.Safari"}` |
| 履歴の中身を見せて・API キーを教えて | （できない） | 中身を返す道具はない。ユーザーに Makurip の一覧で見てもらう（⌥ を押している間だけ伏せ字が外れる） |
| AI の口をオンにして | （できない） | ユーザーに設定画面の「AI の口」でオンにしてもらう |

設定の頼みと項目の対応は、`docs/ai-settings.md` の「頼みと項目の対応表」がそのまま使える（`--settings set <ID> <値>` を `settings_set` の `id` と `value` に読み替える）。

## 5. 同じ機能の CLI（`Makurip --ai`）

MCP を使わないエージェントやスクリプトから使う。引数は MCP と同じ検証を通り、`--json` で MCP の `structuredContent` と同じ JSON を出す。

```sh
MAKURIP=~/Applications/Makurip.app/Contents/MacOS/Makurip
$MAKURIP --ai status
$MAKURIP --ai add --text 'git log --oneline -20'        # 標準入力から: --stdin。画像: --image PATH。ファイル: --file PATH...
$MAKURIP --ai list --secret any --json
$MAKURIP --ai delete-secrets --within 30 --dry-run
$MAKURIP --ai delete --ai-added
$MAKURIP --ai snippet-add --body '{{日付}} 作業メモ' --name 日付メモ
$MAKURIP --ai log                                        # AI が行ったこと（メタデータだけ）
$MAKURIP --ai disable                                    # AI の口をオフにする（オンにする命令はない）
```

| 終了コード | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 使い方の誤り（知らない命令・フラグ） |
| 2 | 検証に通らない（理由は標準エラー。`enable` もここ） |
| 3 | DB・ファイルを読み書きできない |
| 4 | AI の口がオフ |

設定は `Makurip --settings`（`docs/ai-settings.md`）。検証用に隔離したインスタンスは `--data-dir <フォルダ>` を付ける（`Makurip --data-dir DIR --mcp`）。

## 6. 動いている Makurip との関係

- MCP・CLI のプロセスは、動いている Makurip と同じ DB（SQLite の WAL）を直接読み書きする。書いたら分散通知で知らせ、
  動いている Makurip は開いている一覧を読み直し、秘密の自動消去の時計を掛け直す（追加したものは一覧にすぐ出る）
- Makurip が動いていなくても足せる（次に起動したときに一覧に出る）。`status`・`add_to_history` の `appRunning` で分かる
- `copyToClipboard: true` でクリップボードに置いたものは、動いている Makurip が取り込み直さない（保存は済んでいるので、
  コピー元が前面のアプリに書き換わらないように印を付ける）。秘密っぽい形式なら ConcealedType の印も付ける（ほかのクリップボード履歴アプリに残さない）
- 履歴の上限は設定ファイルの値で当てる（アプリと同じ。足して上限を超えたら、古いものから消える）
- 定型文は `snippets.json` に書き、動いている Makurip がファイルの変化を見て読み直す

## 7. 限界

- **同じユーザーで動くプロセスは、DB を直接書き換えてオンにできる**（`sqlite3` で `meta` 表を書くなど）。この仕組みが防ぐのは、
  AI が CLI・MCP・設定ファイルの「ふつうの口」から自分で口を開けることまで。設定画面を画面操作（アクセシビリティ）で押すことも防げない
- 形式の情報からも分かることはある: コピー元アプリ・コピー元ページのホスト名・型名・時刻・（秘密でないものの）大きさ・秘密の形式の名前
- 名前を付けた定型文の名前は返す（本文から作った名前は返さない）。名前そのものに秘密を書くと、伏せ字の判定から外れる形のものは見える
- 秘密の判定の限界（見逃し・誤判定）は `.agent/conventions.md` の「秘密の判定」と同じ。見逃した秘密は、ふつうの項目として形式の情報（大きさを含む）が返る
- 同時に書いたとき: 同じ内容を Makurip の取り込みと AI がほぼ同時に入れると、片方が失敗しうる（失敗は誤りとして返る）。
  ふだんの使い方（人がコピーする・AI が足す）で重なることはまずない
- 「さっき」の分数は AI の解釈しだい。消す前に `dryRun` で件数を確かめるよう、道具の説明に書いてある

## 8. 隔離した検証の結果（2026-10-31）

`make e2e-ai`（`scripts/e2e/ai.sh`）で、隔離したインスタンスの履歴に一意な目印を、文字・URL のクエリ・コピー元ページの URL・ファイル名・RTF・偽の秘密・コードに入れ、
MCP の全道具（13 個）を stdio の JSON-RPC で呼んだ（initialize → tools/list → 各 tools/call）。すべての応答・操作の記録・状態の書き出しで、目印は 0 件。
偽の秘密の内容のハッシュ（推す側が手元で作れるもの）と長さも、MCP・`--ai`・`--dump-metadata`・操作の記録・状態の書き出しのどこにも 0 件（#23）。
あわせて、オフの拒否（設定を変える道具も。#26）・CLI と設定の道具からオンにできないこと・人のコピーと同じ文字を足しても合流しないこと（#24）・
オンからオフに切り替えた直後の拒否・壊れた要求（-32700・-32601・-32602・-32600）・
50 MB を超える追加と 128 MB を超える要求・アプリが動いていないときの追加・動いているアプリの一覧にすぐ出ることを確かめた（87 項目）。

往復の例（中身なし。足した文字は `<テスト用の文字>` に置き換え。id は乱数）:

```
--> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-client","version":"1"}}}
<-- {"id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"makurip","title":"Makurip（クリップボード履歴）","version":"0.1.0"},"capabilities":{"tools":{"listChanged":false}}}}
--> {"jsonrpc":"2.0","id":2,"method":"tools/list"}
<-- {"id":2,"result":{"tools":["status","add_to_history","list_history","delete_secrets","delete_history","add_snippet","list_snippets","delete_snippets","settings_schema","settings_list","settings_get","settings_set","settings_reset"]}}
--> {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"add_to_history","arguments":{"text":"<テスト用の文字>"}}}
<-- {"id":7,"isError":false,"structuredContent":{"addedByAI":true,"appRunning":true,"copiedToClipboard":false,"id":"…","kind":"command","kindLabel":"コマンド","message":"コマンドを履歴に追加しました。","pinned":false,"result":"inserted","secret":"none"}}
--> {"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"delete_secrets","arguments":{}}}
<-- {"id":18,"isError":false,"structuredContent":{"deleted":1,"message":"秘密っぽいもの（確度「高」）を 1 件消しました。"}}
--> {"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"settings_set","arguments":{"id":"candOrder","value":"ime"}}}
<-- {"id":16,"isError":false,"structuredContent":{"id":"candOrder","movedFrom":[],"value":"ime","warnings":[]}}
```

本物の Claude Code に登録して頼む流れ・設定画面の「AI の口」の見た目は、実機で確かめる（#9）。

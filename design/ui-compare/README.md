# 試作（案 B・候補窓）と SwiftUI の見比べ

フェーズ2（#2）で、HTML の試作（`~/dev/makurip-design/ui/b.html`。正本）と SwiftUI のパネルを同じ状態で描き、
横に並べて確かめた記録。フェーズ2.5（#8）で候補窓（`candidate.html`）も足した（後半の「候補窓」）。
フェーズ3（#3）でコードの色付け・コマンドのプロンプト・コピー元のページを足した（「コードの色付け」）。
フェーズ4（#4）で設定画面（試作の設定シート）を足した（「設定画面」）。
フェーズ5（#5）で秘密の伏せ字と ⌥ での表示を足した（「秘密」）。
フェーズ7（#7）で定型文の一覧（⌘S）と定型文の窓を足した（「定型文」）。
画面ロック中でも作れる（試作はヘッドレス Chrome、SwiftUI はオフスクリーン描画）。

## 作り直し方

```
make ui-compare            # = design/ui-compare/shoot.sh。出力は .ui-compare/compare/（git 管理外・2 倍）
```

- 試作は読むだけ。`b-states.html` が試作の部品を読み込み、状態（選択・絞り込み・検索・⌘Y・⌘E）を作る
- 見比べやすくするため、試作はぼかし（backdrop-filter）を切って単色の背景に置き、パネルを CSS の (40, 40) に固定する。
  SwiftUI 側も同じ色の背景に、同じ位置で描く（`Tests/MakuripUITests/SnapshotTests.swift`、`MAKURIP_SNAPSHOT_DIR` を付けたときだけ動く）
- データは試作と同じ架空の履歴（`Tests/MakuripUITests/SampleHistory.swift`）。秘密の 2 件は、秘密の状態（`secrets=1`）を撮るときだけ両方に入れる。
  アプリのアイコンは試作と同じ色の札（手元に入っているアプリのアイコンは使わない）
- `images/` は 1 倍に縮めた写し（左が試作・右が SwiftUI）。`edge-*.png` は試作に同じ状態がないエッジケース

## 見比べた結果（2026-10-31）

配置・余白・色・文字の大きさに大きなずれはない。カードの高さは試作の実測（Chrome の計算後の値）とそろえた
（コマンド 61pt・コード 5 行 142pt・画像 137pt・文章 3 行。CSS の line-height は `CSSText` で再現）。

| 状態 | 画像 |
|---|---|
| ライト（2 件目を選択） | `images/compare-light.png` |
| ダーク（↓ で 3 件目へ。選んだカードが見えるまで送る） | `images/compare-dark.png` |
| ⌘Y のプレビュー（コード・画像） | `images/compare-peek-light.png`・`images/compare-peek-dark.png` |
| 絞り込み中（コマンド × ボタンなど） | `images/compare-filtered.png`・`images/compare-filtered-dark.png` |
| ローマ字検索（depuroi → ﾃﾞﾌﾟﾛｲ） | `images/compare-search.png` |
| 0 件（検索で 0 件・履歴なし・ピン留めのみ） | `images/compare-empty-search.png`・`images/compare-empty-search-dark.png`・`images/compare-empty-history.png`・`images/compare-pinned.png` |
| ⌘E のアプリ選択（ひらがなで「めーる」） | `images/compare-picker.png` |

### 意図して変えたところ・範囲外のもの

- ~~**定型文のタブ・「⌘S 定型文を見る」がない**: 定型文は #7。押しても何も起きない入口は置かない~~（#7 で足した。`compare-empty-history.png` に「⌘S 定型文を見る」が出る）
- **カードのコピー方法が「⌘C」でなく「キー」**: 取り込みでは ⌘C と ⌘X を見分けていない（詳細は「キー操作（⌘C / ⌘X）」）
- **⌘E のアプリ選択をパネルの内側に収めた**: 試作はパネルの右へはみ出すが、窓の外に出すには別の窓とフォーカスの扱いが要るため
- **等幅の書体**: 試作の CSS は SF Mono を指定しているが、Chrome は名前で見つけられず Menlo で描いている。SwiftUI は指定どおり SF Mono（字幅が 2.6% 広い）
- **アイコン**: 試作の線画を SF Symbols に置き換えた（リッチテキストの `textformat` は日本語の環境で「あぁ」になるので英語の字形に固定）

### オフスクリーン描画では分からないこと（実機で確かめる。#9）

- 素材の見え方（実機は NSVisualEffectView のぼかし。比較画像は単色の背景に重ねたもの）と窓の影
- 文字カーソルの下に出る位置・フォーカスを奪わないこと・日本語入力の変換中の挙動

## 候補窓（#8・2026-10-31）

試作 `candidate.html`（`shared/candidate.*`）と SwiftUI の候補窓（`Sources/MakuripUI/CandidateView.swift`）を同じ状態で並べた。
試作は窓をカーソルの**下**に出すが、決定は**右横**なので、位置は比べず窓そのものの見た目だけを比べる。

- 試作側は `candidate-states.html` が試作の部品を読み込み、候補窓を CSS の (40, 40) に固定して撮る（`idx`・`order`・`count`）
- SwiftUI 側は `Tests/MakuripUITests/CandidateSnapshotTests.swift`（`make ui-compare` で一緒に動く）。
  見える 8 行の範囲は、最新から 1 つずつたどったのと同じ送り方で作る

| 状態 | 画像 |
|---|---|
| ライト（ターミナル式・4 件目の URL を選択） | `images/compare-candidate-light.png` |
| ダーク（3 件目の画像を選択） | `images/compare-candidate-dark.png` |
| 縦長の画像・長い 1 行のコマンド・長い文章（ダーク） | `images/compare-candidate-image.png`・`images/compare-candidate-long.png`・`images/compare-candidate-scrolled-dark.png` |
| 予測変換式（最新がいちばん上） | `images/compare-candidate-ime.png` |
| 履歴 0 件・1 件 | `images/compare-candidate-empty.png`・`images/compare-candidate-one.png` |
| 確定まで貼らないアプリ・変換中（試作に無い。注記つき） | `images/edge-candidate-deferred-dark.png`・`images/edge-candidate-composing.png` |

### 見比べた結果

並ぶ行・選んだ行の位置・行の高さ（30pt）・札（20pt）・薄い字の種類名・最下段のヒントと「n / 件数」・窓の高さ（8 行で 291.5pt）に
大きなずれはない。見比べで次の 2 つを直した。

- **見えている 8 行の送り方**: 試作は動かすたびに一覧を描き直し、いちばん上から `scrollIntoView` の nearest で送る。
  なので選んだ行が 8 行目より下なら、いつも見えている範囲のいちばん下に来る。最初はこちらを「前の位置からなるべく動かさない」に
  していたので、試作どおりに直した（`CandidateLayout.firstVisibleRow`）。ターミナル式では、↑ でたどっても窓は動かず一覧だけが流れ、
  選んだ行がカーソルの行にとどまる（決定の「選んでいる行をカーソルの行の高さにそろえる」とよく合う）
- **画像の札**: サムネイルが 20pt の札からはみ出していたのを、札の中で切り抜くように直した。札の記号は試作の線画に合わせて小さくした

### 意図して変えたところ・範囲外のもの

- **位置**: カーソルの右（入らなければ左）。選んでいる行の中心をカーソルの行の中心にそろえる。画面の端では押し戻す（そのときだけ行がずれる）
- **注記**: 確定まで貼らないとき（ターミナル・チャット・変換中・入力欄を読めない・差し替えが効かないアプリ）に、
  その理由を 1 行で出す。試作の秘密の注記（`.cd-note`）と同じ形で、色は秘密の赤でなく知らせの青
- ~~**言語名がない**（試作は「Python 7行」「Swift 17行」、こちらは「コード 7行」）~~: #3 で言語名を出すようにした（`compare-candidate-long.png` の「Python 7行」）
- **色の名前がない**（試作は「#0A84FF アクセント（青）」、こちらは HEX だけ）: 履歴に色の名前を持っていない
- **画像の名前**: 履歴に画像の名前がないので、コピー元のアプリから「スクリーンショットの画像」「Safari の画像」と呼ぶ
- **文字数**: 試作はコードポイントで数え、こちらは見た目の 1 文字（書記素）で数える。半角の「ﾃﾞ」は試作で 2 字、こちらで 1 字。
  一覧用の平文（先頭 1000 文字）で切れているときは「テキスト 1000+字」のように「+」を付ける
- ~~**秘密の行（伏せ字と鍵の印・⌥ で表示）**: フェーズ5（#5）。比較では両方から除いた~~: #5 で足した（下の「秘密」）
- **マウスを載せたときの行の色**: 窓がキーの焦点を取らないので、マウスの追跡は入れていない（クリックで選ぶ・ダブルクリックで確定はできる）

### オフスクリーン描画では分からないこと（実機で確かめる。#9）

- 本物のアプリでの位置（文字カーソルの横に出るか）・素材の見え方・窓の影・クリックの当たり方

## コードの色付け（#3・2026-10-31）

試作の `Mk.syntax`・`Mk.cmdHTML`（`core.js`）と配色（`base.css` の `--s-*`）を、Swift の字句解析（`SyntaxHighlighter`）と
`CodeStyler` で写した。試作側は `b-states.html` に `state=custom&kind=…&move=…&look=1`（種類で絞って n 件目を ⌘Y）を足して撮る。

| 状態 | 画像 |
|---|---|
| コードのカードだけ（4 言語） | `images/compare-code-cards-light.png`・`images/compare-code-cards-dark.png` |
| ⌘Y のコード: Swift（ライト）・TypeScript（ダーク）・Python（ライト・コピー元のページ付き）・シェル（ダーク） | `images/compare-peek-light.png`・`images/compare-peek-code-ts-dark.png`・`images/compare-peek-code-py-light.png`・`images/compare-peek-code-sh-dark.png` |
| ⌘Y のコマンド（プロンプトを薄く・外す注記・コピー元のページ） | `images/compare-peek-cmd-light.png`・`images/compare-peek-cmd-dark.png` |
| 候補窓の言語名（「Python 7行」） | `images/compare-candidate-long.png` |
| 言語不明・1 文字・全角と絵文字・とても長い 1 行・3000 行・PS1 と出力と続き行・コピー元のページ付きの文章・コードの中の検索（試作に無い） | `images/edge-code-cards.png`・`images/edge-code-cards-long-line.png`・`images/edge-peek-code-unknown.png`・`images/edge-peek-code-one-char.png`・`images/edge-peek-code-cjk.png`・`images/edge-peek-code-long-line.png`・`images/edge-peek-code-3000-lines.png`・`images/edge-peek-cmd-ps1.png`・`images/edge-peek-text-source.png`・`images/edge-search-in-code.png` |

### 見比べた結果

キーワード（太字）・型・文字列・コメント・数・関数・属性・シェルのフラグの色、行番号の位置・線、行の高さ（12.5px × 1.65）、
カードの 5 行の切り方に大きなずれはない。ライトとダークとも試作の値どおり。見比べで次を直した。

- **端末のコピーの出力の行**: 出力の行（`Build complete!` など）までコマンドとして色が付いていた。プロンプトのある文字列では、コマンドの行（プロンプトの行と続きの行）だけを色付けするようにした（`edge-peek-cmd-ps1.png`）
- **一覧の下の方のカードを選んだ状態**: 選んだカードが見える位置まで一覧が送られるよう、描いた後に選ぶようにした（比べ方の直し）
- **3000 行の見出し**: プレビュー用に切った後の行数（603 行）を出していたのを、全文の行数にした。切ったことの注記も出す
- **長い行のコードのカードがパネルの右へはみ出していた（#16）**: 折り返さない行の幅でカードが広がり、右の枠線と ⌘2 の札が切れていた
  （`compare-peek-code-ts-dark.png` の TypeScript のカード）。カードの幅をパネルが渡した幅（352pt）に固定し、行はカードの内側で切るようにした。
  `CardLayoutTests` が、長い 1 行・空白のない長い語を含む全種類のカードの幅を、選択中・非選択とライト・ダークで確かめる

### 意図して変えたところ・範囲外のもの

- **コピー元のページの書き方**: 試作は「題名　ドメイン」。題名は取り込んでいない（Chrome 系・Safari の型に題名が載らない）ので、「ホスト　パス」にした。クエリ（`?` の後ろ）はトークンが入りうるので出さない
- **プロンプトの注記の文言**: 試作の「（設定で変更できます）」は設定画面（#4）がまだないので出さず、外さずに貼るキー（⇧↩。キーマップから引く）を書いた
- **⌘Y のコードは NSTextView**: SwiftUI の Text は色の区間が多いと極端に遅い（色付きの 600 行で 2.5 秒）。行番号は横に送っても動かず、縦は本文と一緒に動く（試作の `.gutter` と同じ）。行をまたいで選べる
- **言語が決まらないコード**: 試作は TypeScript として色を付けるが、こちらは文字列・数・`//` のコメントだけ（違う言語の色を付けないため）
- **右端で切れる長い行**: 等幅の字幅の差（SF Mono と Menlo）で、試作より少し手前で切れる。横に送れば読める

### 色付けの速さ（`images/highlight-speed.txt`）

架空の Swift のコード（デバッグビルド・ほかの仕事でマシンが混んでいる状態。描画は 3 回の中央値）。プレビューは先頭 2 万文字まで。

| 行数 | 文字数 | 区間 | 言語の判定 | 字句解析 | 色付きの文字列 | パネルとプレビューを描き直す |
|---|---|---|---|---|---|---|
| 1（基準） | 18 | 0 | 2.9 ms | 0.6 ms | 3.3 ms | 113 ms |
| 100 | 3,319 | 340 | 2.3 ms | 1.4 ms | 0.4 ms | 123 ms |
| 500 | 16,599 | 1,700 | 2.3 ms | 4.9 ms | 1.3 ms | 122 ms |
| 1000 | 33,199 | 3,400 | 2.3 ms | 9.5 ms | 2.1 ms | 120 ms |
| 3000 | 99,599 | 10,200 | 2.2 ms | 30 ms | 5.2 ms | 119 ms |

描き直しは 1 行のコード（基準）とほぼ同じで、色付けの分は長さによらず 10 ms 前後。8000 文字（UTF-16）を超えるコードの区間は
裏のスレッドで作り、できるまでは色なしで出す。一覧を開く速さは、変更前（`origin/main`）と交互に 3 回ずつ測って差がなかった
（1000 件の最初の描画が 185〜191 ms と 188〜199 ms、5000 件が 92〜114 ms と 93〜101 ms。下の表より遅いのはマシンが混んでいたため）。

## 設定画面（#4・2026-10-31）

試作の設定シート（統合版 `candidate.html` の ⌘,。`shared/core.js` の `Mk.sheet`）と、SwiftUI の設定画面（`Sources/MakuripUI/SettingsView.swift`）を並べた。

- 試作側は `settings-states.html` が試作の部品を読み込み、`Mk.sheet.show()` でシートを開く（`state=keys` は「コピー方法を切り替え」まで ↓ で下りて Enter）。
  シートは画面の中央（幅 640・高さ 820）。記録中の札の明滅は止めて撮る
- SwiftUI 側は `Tests/MakuripUITests/SettingsSnapshotTests.swift`（`make ui-compare` で一緒に動く）。設定ファイルは一時フォルダ。
  試作に無い状態（キーの重なり・アプリの札・数の打ち込み・読めない値）は、設定ファイルに先に値を書いて描く

| 状態 | 画像 |
|---|---|
| 「動き」（いちばん上の行を選んだ状態） | `images/compare-settings-behavior-light.png`・`images/compare-settings-behavior-dark.png` |
| 「キー割り当て」（コピー方法を切り替えのキーを記録中） | `images/compare-settings-keys-light.png`・`images/compare-settings-keys-dark.png` |
| キーが重なった状態（設定ファイルで ⌘E を 2 つの操作に。試作に無い） | `images/edge-settings-conflict-light.png`・`images/edge-settings-conflict-dark.png` |
| 件数の上限・記録しないアプリ・確定まで貼らないアプリ（札）・数の打ち込み（試作に無い） | `images/edge-settings-history-light.png`・`images/edge-settings-history-dark.png` |
| 変えた直後の知らせ・設定ファイルに読めない値があったときの注記 | `images/edge-settings-message.png`・`images/edge-settings-file-issue.png` |
| 「AI の口」の段（#6。試作に無い）: オフで記録あり・オンにした直後（暗い配色） | `images/edge-settings-ai-light.png`・`images/edge-settings-ai-dark.png` |

### 見比べた結果

窓の幅（640）・題名のバー（44pt）・リードの文・まとまりの見出し・行の高さと余白・選んだ行の色・記録中の枠と「新しいキーを押す…」の札・
選択肢の切り替え（選んでいる面の白と影）・キーの札・下の段のヒントと「すべて初期値に戻す」に大きなずれはない。見比べで次を直した。

- **キーの説明**: 最初は全部のキーの説明の末尾に「一覧が開いている間だけ効く。」を足していたので、行が 2 行に伸びて試作より騒がしかった。
  説明は試作の文のままにし、効く範囲は CLI の型（`keyScope`）と、候補窓のまとまりの見出しの注記（試作どおり）で出す
- **AI 向けの言葉**: 「確定まで貼らないアプリ」の説明に「builtIn の一覧」と CLI の言葉が出ていたので、「Slack・Discord・LINE・メッセージなど」にした
- **打ち込み中の数**: 単位（秒など）が消えていたので、入力欄の横に出した

### 意図して変えたところ・試作に無いもの

- **試作に無い項目を同じ形で足した**: 件数・容量・秒は「− 値 ＋」（切り替えと同じ面。値を押すと打ち込める）、ログイン時に起動は「しない／する」の切り替え、
  記録しないアプリ・確定まで貼らないアプリは説明の下に札（× で外す）と右に「追加…」（動いているアプリの一覧・「その他…」でアプリを選ぶ）。
  並びは「動き → 履歴 → アプリごと → 詳細 → キーのまとまり」。差し替え方式の決め打ち（`candReplaceMethod`）は手直し用なので画面に出さない
- **リードの文と「呼び出しキーの動き」の説明**: 足した項目に合わせて「履歴の上限・アプリごとの扱い」を足した。呼び出しキーの動きの説明には
  「貼り付けのときに窓（候補窓・一覧）を出すかどうかも、これで決まる」を足した（AI が「UI を出さないで」をこの項目に結びつけられるように。説明は AI 向けの一覧と同じ文）。
  「いま：」の文は決定どおり「文字カーソルの**横**に候補窓を出す」（試作は下）
- **キーの重なりの表示**: 試作は記録したときに前の割り当てから外すだけ（ここも同じ）。設定ファイルや CLI で重なったときは、両方の行の札を橙にして
  「「…」と重なっています。どちらかを変えてください。」を出す。どこからでも効くキーを登録できなかったときも同じ色で注記を出す
- **設定ファイルの読めない値**: 一覧の先頭に橙の注記（項目と理由）を出す。その項目は初期値で動く
- **窓の枠**: 本物の窓（信号機のボタンは AppKit が描くので、オフスクリーン描画には写らない）。中身を窓の上まで広げ、44pt のバーは SwiftUI で描く
- **送り方**: 選んだ行が見えるところまで最小限に送る（`ScrollViewReader.scrollTo`）。試作の `scrollIntoView({block: 'nearest'})` と同じ考えだが、
  記録中の行の下に見える行の数は試作と少し違う
- **「AI の口」の段（#6）**: 試作に無い。「詳細」の後・キーのまとまりの前に 1 行（`SettingsAIAccessRow`）。ほかの行と同じ形（左に名前と説明・右に「オフ／オン」の切り替え。↩・←→ で切り替え・⌫ でオフ）に、
  Claude Code の登録コマンド（等幅の箱と「コピー」）と AI の操作の記録（新しい順に 6 件。断ったものは橙）を説明の下に足した。オンの間は橙の「いま：オン」を出す。
  設定のスキーマの項目ではない（AI・CLI から変えられないように）。本体が `SettingsEnvironment.aiAccess` を渡したときだけ出すので、
  試作と並べる `compare-settings-*` には写らず、`edge-settings-ai-*`（見本の記録と `/Users/sample/…` のパスで描く）で見る

### オフスクリーン描画では分からないこと（実機で確かめる。#9）

- 「AI の口」の段の見た目（長い登録コマンドの折り返し・記録の行の切れ方・「コピー」）
- 信号機のボタンの位置（44pt のバーの中で上下の中央に来るか）・窓の影・Makurip を前面にしたときのフォーカス
- キーの記録（全体のキー ⌃⌘V なども、記録の間はホットキーを外すので記録できるか）・「追加…」のメニューと「その他…」の選ぶ画面

## 定型文（#7・2026-10-31）

試作の定型文の一覧（`b.html` で ⌘S。`screenshots/b-snippets.png`）と SwiftUI を並べた。試作側は `b-states.html` に `state=snippets`（と `q=…` の検索語）を足して撮る。
データは試作と同じ 6 件（`SampleHistory.snippets`）。試作に定型文の**窓**（登録・編集）はないので、窓は見た目の元にした試作の設定シートと並べた。

| 状態 | 画像 |
|---|---|
| 定型文の一覧（2 件目を選択。`b-snippets.png` と同じ）・ダーク（4 件目まで送る） | `images/compare-snippets.png`・`images/compare-snippets-dark.png` |
| ⌘Y の定型文（差し込みの札と説明） | `images/compare-peek-snippet-light.png`・`images/compare-peek-snippet-dark.png` |
| 検索（rebyu- → レビュー） | `images/compare-snippets-search.png` |
| 履歴が空（「⌘S 定型文を見る」） | `images/compare-empty-history.png` |
| 定型文の窓（試作の設定シートと並べる）: 編集・新しい下書き（履歴から登録） | `images/compare-snippet-editor-light.png`・`images/compare-snippet-editor-dark.png`・`images/compare-snippet-editor-new-light.png`・`images/compare-snippet-editor-new-dark.png` |
| 一覧のエッジケース（試作に無い）: 0 件・長い名前と空白のない長い行・10 行・壊れた記法・同じ名前・差し込みだらけ・300 件 | `images/edge-snippets-empty.png`・`images/edge-snippets-empty-dark.png`・`images/edge-snippets-long.png`・`images/edge-snippets-long-dark.png`・`images/edge-snippets-many.png` |
| 窓のエッジケース: 保存できない（本文が空）・0 件・ファイルに読めない項目・長いもの・300 件 | `images/edge-snippet-editor-error.png`・`images/edge-snippet-editor-empty-dark.png`・`images/edge-snippet-editor-issues.png`・`images/edge-snippet-editor-long.png`・`images/edge-snippet-editor-many.png` |
| 設定画面の「定型文」のまとまり（日付の書き方） | `images/edge-settings-snippet.png` |

### 見比べた結果

タブ（種類は薄く・定型文のタブは青）・見出し（「定型文 6 件　⌘S 履歴に戻る」）・薄くした絞り込み・カードの名前と本文 3 行・差し込みの札（色・角丸・大きさ・行の中の位置）・
「定型文 · ;略語」・番号・カードの高さと位置に大きなずれはない（ライト・ダークとも）。見比べで次を直した。

- **札のある行が高かった**: 最初は札を SwiftUI の `Text(Image)` で文に入れたが、基準線より下に出る分だけ行が高くなり（約 24pt。試作は 18.85pt）、2 枚目から下のカードがずれた。
  本文を TextKit で組み、段落の行の高さを CSS の line-height に固定して、札を `NSTextAttachment` にした（`SnippetBodyText`）
- **3 行で切ったときの「…」**: TextKit の行数の上限に任せると、空の 3 行目を飛ばして 4 行目の文を出していた。CSS の line-clamp と同じく、
  先頭の 3 行で切って末尾に「…」を足すようにした（PR の説明テンプレートの 3 行目が「…」だけになる）

### 意図して変えたところ・試作に無いもの

- **⌘Y の説明に編集のキー**: 試作の「色の付いた部分は貼り付けるときに置き換わります（日付 → 今日の日付、クリップボード → 最新のテキスト）。」の下に
  「⇧⌘S で編集します。」を足した（試作に編集の画面がないので、入口のキーをここで示す）。日付は今日の日付を設定の書き方で出す
- **定型文が 0 件の一覧**: 試作は 6 件の見本で 0 件にならない。履歴の空の案内と同じ形で「定型文はまだありません」と「⇧⌘S 新しい定型文」を出す
- **定型文の窓**: 試作に無い。設定シートと同じ窓の色・44pt の題名のバー・リードの文・選んだ行の色・下の段のキーのヒントにそろえた。
  左に一覧（番号・名前・略語・本文の 1 行目、上下のボタンで並べ替え）、右に名前・略語・本文（差し込みに定型文の色）と、差し込みを入れる札
- **⌘Y の本文は選べない**: 試作は文字を選べるが、札を画像にしているので、選んでコピーすると札が文字にならない。貼るのは ↩ で行う
- **⌘⌫ で定型文を消さない**: 試作どおり（一覧では消せない）。消すのは定型文の窓で、確かめてから

### オフスクリーン描画では分からないこと（実機で確かめる。#9）

- 本物のアプリに貼ったときの置き換えと `{{カーソル}}` の位置・定型文の窓での日本語入力・削除の確かめ（シート）・窓を閉じたときの保存

## 開く速さ（`images/open-speed.txt`・`images/store-speed.txt`）

架空の履歴で測った値（M シリーズの Mac・デバッグビルド）。

| 件数 | ストアから読む | 絞り込み（開く） | 最初の描画 | 検索（温まった後） | 検索（開いてすぐ打った 1 回目） |
|---|---|---|---|---|---|
| 1000 | — | 1.6 ms | 107 ms | 3.3 ms | 48 ms |
| 5000 | 23 ms | 7.1 ms | 116 ms | 15 ms | 239 ms |

検索用の正規化は開いた後に裏で作る（`HistoryPanelModel.warmHaystacks`）。開いて 0.2 秒以内に打つと、
1 回目だけ足りない分をその場で作るので遅くなる。

## 秘密（#5・2026-10-31）

試作の秘密の 2 件（h05: ダッシュボードのコピーボタンで取った API キー、h18: ターミナルの `export API_TOKEN=…`）を残した 27 件で、
伏せ字・⌥ で表示・候補窓の注記を並べた。試作側は `b-states.html`・`candidate-states.html` に `secrets=1`（秘密を残す）と `reveal=1`
（⌥ を押している間と同じ）を足して撮る。Swift 側は `SampleHistory.secretEntries`（同じ形の偽物。値は実行時に擬似乱数でつなぐ）。

| 状態 | 画像 |
|---|---|
| 一覧で秘密のカードを選んだところ（ライト・ダーク） | `images/compare-secret-light.png`・`images/compare-secret-dark.png` |
| ⌘Y のプレビュー（伏せ字・理由・押している間だけ表示） | `images/compare-secret-peek-light.png`・`images/compare-secret-peek-dark.png` |
| ⌥ を押している間（カードとプレビューが表示に変わる） | `images/compare-secret-reveal-light.png`・`images/compare-secret-reveal-dark.png` |
| コマンドの秘密（`export API_TOKEN=…`） | `images/compare-secret-cmd-light.png` |
| 候補窓で秘密を選んだところ（鍵・「秘密」・2 行の注記） | `images/compare-candidate-secret-light.png`・`images/compare-candidate-secret-dark.png` |
| 候補窓で ⌥ を押している間 | `images/compare-candidate-secret-reveal-light.png`・`images/compare-candidate-secret-reveal-dark.png` |
| 「himitsu」で検索・確定まで貼らないアプリで秘密を選んだとき（注記は秘密を優先）・秘密のコマンド（試作に無い） | `images/edge-secret-search.png`・`images/edge-candidate-secret-deferred.png`・`images/edge-candidate-secret-cmd-dark.png` |

### 見比べた結果（自分で見た）

伏せ字の箱（赤みの地に鍵・等幅）・「⌥ を押している間だけ表示」・種類名を秘密の赤で出すこと・プレビューの「秘密」の札と
「API キーの形式 · 36 文字」・押している間だけ表示するボタン・表示中の青みの箱と目の印・候補窓の鍵と「秘密」と 2 行の注記に、
大きなずれはない。ライトとダークとも試作の色（`--k-secret` = #c4361f / #ff8a75）どおり。見比べで次を直した。

- **プレビューの注記の行の分け方**: 3 行に分けていたのを、試作と同じく「〜なので隠しています。⌥ を押している間だけ表示します。」を 1 行に、
  「貼り付けると元の文字列が入ります。」を次の行にした（理由が長くて入らないときだけ、⌥ の文を次の行に送る）
- **候補窓の行の印**: 表示中に目の印へ変えていたのを、試作どおり鍵のままにした（目に変わるのはプレビューとカードの箱だけ）

### 意図して変えたところ・範囲外のもの

- **接頭辞の分からない値の伏せ方**: 試作の `export API_TOKEN=tok-test-••••••••••••` は `tok-test-` を見せるが、こちらは
  `export API_TOKEN=••••••••••••••••XXXX`。`tok-` のような決まっていない接頭辞は値の一部かもしれないので見せず、十分に長いときだけ末尾 4 文字を見せる
  （GitHub などの管理画面と同じ）。既知の形式（`sk-test-`・`ghp_`・`AKIA` など）は試作どおり接頭辞を見せる
- **表示中の中身**: 試作は `sk-test-XXXX…0000`、こちらは同じ形の擬似乱数（`XXXX…` の並びはランダムでないので秘密と判定しない）
- **伏せ字の点**: SF Mono の「•」は、試作が描いている Menlo のものより少し大きく濃い（等幅の書体の違い。上の「等幅の書体」）
- **コピー元のページ**: 題名を取り込んでいないので「ホスト　パス」（上の「コードの色付け」と同じ）

### オフスクリーン描画では分からないこと（実機で確かめる。#9）

- 本物のキーボードで ⌥ を押し離ししたときに、パネルと候補窓がすぐ表示・非表示に変わるか（パネルはローカル監視、候補窓はタップの `flagsChanged`）
- ⌘Y のボタンを押している間だけ表示され、離すと（窓の外で離しても）隠れるか

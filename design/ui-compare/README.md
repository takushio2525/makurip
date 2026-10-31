# 試作（案 B・候補窓）と SwiftUI の見比べ

フェーズ2（#2）で、HTML の試作（`~/dev/makurip-design/ui/b.html`。正本）と SwiftUI のパネルを同じ状態で描き、
横に並べて確かめた記録。フェーズ2.5（#8）で候補窓（`candidate.html`）も足した（後半の「候補窓」）。
フェーズ3（#3）でコードの色付け・コマンドのプロンプト・コピー元のページを足した（「コードの色付け」）。
画面ロック中でも作れる（試作はヘッドレス Chrome、SwiftUI はオフスクリーン描画）。

## 作り直し方

```
make ui-compare            # = design/ui-compare/shoot.sh。出力は .ui-compare/compare/（git 管理外・2 倍）
```

- 試作は読むだけ。`b-states.html` が試作の部品を読み込み、状態（選択・絞り込み・検索・⌘Y・⌘E）を作る
- 見比べやすくするため、試作はぼかし（backdrop-filter）を切って単色の背景に置き、パネルを CSS の (40, 40) に固定する。
  SwiftUI 側も同じ色の背景に、同じ位置で描く（`Tests/MakuripUITests/SnapshotTests.swift`、`MAKURIP_SNAPSHOT_DIR` を付けたときだけ動く）
- データは試作と同じ架空の履歴（`Tests/MakuripUITests/SampleHistory.swift`）。秘密の 2 件は #5 の範囲なので両方から除く。
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

- **定型文のタブ・「⌘S 定型文を見る」・設定の歯車がない**: 定型文は #7、設定画面は #4。押しても何も起きない入口は置かない
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
- **秘密の行（伏せ字と鍵の印・⌥ で表示）**: フェーズ5（#5）。比較では両方から除いた
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
| 言語不明・1 文字・全角と絵文字・とても長い 1 行・3000 行・PS1 と出力と続き行・コピー元のページ付きの文章・コードの中の検索（試作に無い） | `images/edge-code-cards.png`・`images/edge-peek-code-unknown.png`・`images/edge-peek-code-one-char.png`・`images/edge-peek-code-cjk.png`・`images/edge-peek-code-long-line.png`・`images/edge-peek-code-3000-lines.png`・`images/edge-peek-cmd-ps1.png`・`images/edge-peek-text-source.png`・`images/edge-search-in-code.png` |

### 見比べた結果

キーワード（太字）・型・文字列・コメント・数・関数・属性・シェルのフラグの色、行番号の位置・線、行の高さ（12.5px × 1.65）、
カードの 5 行の切り方に大きなずれはない。ライトとダークとも試作の値どおり。見比べで次を直した。

- **端末のコピーの出力の行**: 出力の行（`Build complete!` など）までコマンドとして色が付いていた。プロンプトのある文字列では、コマンドの行（プロンプトの行と続きの行）だけを色付けするようにした（`edge-peek-cmd-ps1.png`）
- **一覧の下の方のカードを選んだ状態**: 選んだカードが見える位置まで一覧が送られるよう、描いた後に選ぶようにした（比べ方の直し）
- **3000 行の見出し**: プレビュー用に切った後の行数（603 行）を出していたのを、全文の行数にした。切ったことの注記も出す

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

## 開く速さ（`images/open-speed.txt`・`images/store-speed.txt`）

架空の履歴で測った値（M シリーズの Mac・デバッグビルド）。

| 件数 | ストアから読む | 絞り込み（開く） | 最初の描画 | 検索（温まった後） | 検索（開いてすぐ打った 1 回目） |
|---|---|---|---|---|---|
| 1000 | — | 1.6 ms | 107 ms | 3.3 ms | 48 ms |
| 5000 | 23 ms | 7.1 ms | 116 ms | 15 ms | 239 ms |

検索用の正規化は開いた後に裏で作る（`HistoryPanelModel.warmHaystacks`）。開いて 0.2 秒以内に打つと、
1 回目だけ足りない分をその場で作るので遅くなる。

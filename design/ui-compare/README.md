# 試作（案 B・候補窓）と SwiftUI の見比べ

フェーズ2（#2）で、HTML の試作（`~/dev/makurip-design/ui/b.html`。正本）と SwiftUI のパネルを同じ状態で描き、
横に並べて確かめた記録。フェーズ2.5（#8）で候補窓（`candidate.html`）も足した（後半の「候補窓」）。
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

- **コードの色付けがない**: フェーズ3（#3）。いまは等幅で出すだけ。コマンドの先頭の「$ 」を薄くするのは試作どおり
- **定型文のタブ・「⌘S 定型文を見る」・設定の歯車がない**: 定型文は #7、設定画面は #4。押しても何も起きない入口は置かない
- **カードのコピー方法が「⌘C」でなく「キー」**: 取り込みでは ⌘C と ⌘X を見分けていない（詳細は「キー操作（⌘C / ⌘X）」）
- **プレビューの見出しに言語名（Swift など）がない**: 言語の判定はフェーズ3
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
- **言語名がない**（試作は「Python 7行」「Swift 17行」、こちらは「コード 7行」）: 言語の判定はフェーズ3（#3）
- **色の名前がない**（試作は「#0A84FF アクセント（青）」、こちらは HEX だけ）: 履歴に色の名前を持っていない
- **画像の名前**: 履歴に画像の名前がないので、コピー元のアプリから「スクリーンショットの画像」「Safari の画像」と呼ぶ
- **文字数**: 試作はコードポイントで数え、こちらは見た目の 1 文字（書記素）で数える。半角の「ﾃﾞ」は試作で 2 字、こちらで 1 字。
  一覧用の平文（先頭 1000 文字）で切れているときは「テキスト 1000+字」のように「+」を付ける
- **秘密の行（伏せ字と鍵の印・⌥ で表示）**: フェーズ5（#5）。比較では両方から除いた
- **マウスを載せたときの行の色**: 窓がキーの焦点を取らないので、マウスの追跡は入れていない（クリックで選ぶ・ダブルクリックで確定はできる）

### オフスクリーン描画では分からないこと（実機で確かめる。#9）

- 本物のアプリでの位置（文字カーソルの横に出るか）・素材の見え方・窓の影・クリックの当たり方

## 開く速さ（`images/open-speed.txt`・`images/store-speed.txt`）

架空の履歴で測った値（M シリーズの Mac・デバッグビルド）。

| 件数 | ストアから読む | 絞り込み（開く） | 最初の描画 | 検索（温まった後） | 検索（開いてすぐ打った 1 回目） |
|---|---|---|---|---|---|
| 1000 | — | 1.6 ms | 107 ms | 3.3 ms | 48 ms |
| 5000 | 23 ms | 7.1 ms | 116 ms | 15 ms | 239 ms |

検索用の正規化は開いた後に裏で作る（`HistoryPanelModel.warmHaystacks`）。開いて 0.2 秒以内に打つと、
1 回目だけ足りない分をその場で作るので遅くなる。

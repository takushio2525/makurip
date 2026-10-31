# 試作（案 B）と SwiftUI のパネルの見比べ

フェーズ2（#2）で、HTML の試作（`~/dev/makurip-design/ui/b.html`。正本）と SwiftUI のパネルを同じ状態で描き、
横に並べて確かめた記録。画面ロック中でも作れる（試作はヘッドレス Chrome、SwiftUI はオフスクリーン描画）。

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

## 開く速さ（`images/open-speed.txt`・`images/store-speed.txt`）

架空の履歴で測った値（M シリーズの Mac・デバッグビルド）。

| 件数 | ストアから読む | 絞り込み（開く） | 最初の描画 | 検索（温まった後） | 検索（開いてすぐ打った 1 回目） |
|---|---|---|---|---|---|
| 1000 | — | 1.6 ms | 107 ms | 3.3 ms | 48 ms |
| 5000 | 23 ms | 7.1 ms | 116 ms | 15 ms | 239 ms |

検索用の正規化は開いた後に裏で作る（`HistoryPanelModel.warmHaystacks`）。開いて 0.2 秒以内に打つと、
1 回目だけ足りない分をその場で作るので遅くなる。

# アイコンの原稿（案 B「パラパラ」）

Makurip のアプリアイコン（Dock・Finder）とメニューバーのアイコンの原稿と、アプリのビルドが使う入力（リポジトリ直下の `Resources/`）を作り直すスクリプトです。デザインは 3 案を比べ、2026-10-31 にユーザーが案 B「パラパラ」に決めました。付箋の束を扇形にパラパラとめくっている絵で、名前の「まくる（めくる）」と、溜まった履歴を次々とめくって探す使い方を表しています。

## 中身

```
design/icon/
  b-parapara/
    icon.json          Icon Composer の記述。背景の 2 色（藍のグラデーション, srgb）の定義はここだけ
    layers/N_*.svg     前景レイヤー（1024 の正方形 = アイコンの外形いっぱい。番号順に奥→手前）
    menubar.svg        メニューバー用テンプレート画像（16pt。@2x とベクター用）
    menubar-16.svg     同じ配置を 16px（@1x）の画素にそろえた専用版
  scripts/
    sync-resources.sh  原稿から Resources/ を作り直す（原稿を直したらこれ）
    export.sh          形式ごとの書き出しと検証（.icon・アセットカタログ・.icns・システムでの見え方）
    lib.sh             共通関数
  tools/
    checkpng.swift     PNG を数値で点検する（寸法・半透明の画素数・黒以外の色）
    sysicon.swift      macOS（NSWorkspace）が実際に描くアプリアイコンを PNG にする
```

ビルドの流れは次のとおりです。

- `Resources/AppIcon.icon` と `Resources/Assets.xcassets`（MenuBarIcon）を、`scripts/build-app.sh` が actool でまとめてコンパイルし、`.app` の `Contents/Resources/Assets.car` を作る（旧 OS 用の `AppIcon.icns` も作られる）。
- `Info.plist` の `CFBundleIconName` / `CFBundleIconFile` が `AppIcon` を指す。
- メニューバーは `StatusMenuController` が `NSImage(named: "MenuBarIcon")` で読む。テンプレート指定は imageset に入っているので、ライト・ダークの色はシステムが付ける。`.app` に入れずに実行したときは Assets.car がないので、SF Symbol で代える。

## 直し方

```sh
zsh design/icon/scripts/sync-resources.sh                              # 原稿 → Resources/（actool に通るかも確かめる）
make app                                                               # .app を組み立てて署名
zsh design/icon/scripts/export.sh design/icon/b-parapara               # 書き出しと検証（.build/icon-export/b-parapara/ に。git 管理外）
```

形は `layers/*.svg` を、色は `icon.json` の `fill.linear-gradient` を直します。レイヤーを足したら、`icon.json` の `groups` にも書き足します（配列の先頭が一番手前）。メニューバーは `menubar.svg` と `menubar-16.svg` を同じ配置のまま両方直します。

必要なのは Xcode 26 以降（actool と、Icon Composer.app に同梱の ictool）と rsvg-convert（`brew install librsvg`）です。rsvg-convert は原稿を PNG にするときだけ使い、`make app` には要りません。

export.sh は書き出したあと、次の項目を確かめて `verify.txt` に残します。

- .icns の 10 枚の寸法。
- メニューバー画像が黒と透明度だけでできていること。
- actool でコンパイルできること。
- assetutil で見て、AppIcon が .icon 由来のレイヤー付きで、MenuBarIcon がテンプレート指定の @1x/@2x であること。
- 3 通りの渡し方で、システムが描いた見え方（`preview/system-*.png`）。

## メニューバー版

付箋 3 枚を左上へ 2pt ずつずらして重ねた形です。奥の 2 枚は 1pt の L 字、手前は塗りで、文字行を 2 本抜いています。アプリアイコンの回転した扇をそのまま縮めると、16px では細い切れ端の縁が灰色ににじみます（最初の版は 16px の 119 画素のうち 98 が半透明でした）。そこでメニューバー版だけ回転をやめ、辺をすべて水平・垂直に置きました。16px 専用版はアンチエイリアスを切っているので、半透明の画素は 0 です。

## macOS 26 のアイコンについて分かったこと

Apple の資料から分かったことは次の 3 つです。

- **形**: macOS のアイコンは正方形で作り、角丸はシステムがマスクで付ける。レイヤーはマスクせず正方形のまま渡す。レイアウトは 1024×1024px（HIG）。
- **形式**: レイヤー付きの Icon Composer 形式（.icon）が推奨。前景レイヤーに付く Liquid Glass（鏡面ハイライト・屈折・半透明）はシステムが付けるので、原稿に影やハイライトを入れない（HIG）。
- **Xcode との関係**: .icon を使うと AppIcon アセットカタログに置き換わり、旧 OS 用の画像は actool がビルド時に作る（Apple「Creating your app icon using Icon Composer」）。

macOS 26 は、角丸四角の外形に合わないアイコンを縮小し、灰色の台座に載せて表示します（9to5Mac、Rogue Amoeba）。

この Mac（macOS 26.4 / Xcode 26.2）で、NSWorkspace にダミーの .app のアイコンを描かせて確かめた結果は次のとおりです。.icns だけのアプリは、64px 以上では正常でも、32px 以下では灰色の台座に縮小されます。他社の .icns だけのアプリも同じでした。Assets.car と CFBundleIconName で渡すと、16px まで正常です。`build-app.sh` が actool を通すのはこのためです。

icon.json の書式には公式の仕様書が見つかりませんでした。キー名は Icon Composer のバイナリ内の文字列と照合し、ictool で描けることと actool でコンパイルできることで確かめています。

出典:

- Apple Human Interface Guidelines「App icons」 https://developer.apple.com/design/human-interface-guidelines/app-icons
- Apple Developer Documentation「Creating your app icon using Icon Composer」 https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- 9to5Mac の記事（2025-08-08。外形に合わないアイコンが灰色の箱に入る件） https://9to5mac.com/2025/08/08/macos-tahoe-fix-gray-box-icons/
- Rogue Amoeba のブログ記事（2026-06-26。macOS 26 の形の強制と macOS 27 ベータの動き） https://weblog.rogueamoeba.com/2026/06/26/free-the-icons/

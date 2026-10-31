# Makurip アイコン書き出しの共通関数（zsh 用）。
# export.sh（書き出しと検証）と sync-resources.sh（ビルド入力の再生成）から source する。
#
# 原稿の約束ごと（案のフォルダ = design/icon/<案>/。いまは b-parapara だけ）:
#   icon.json        Icon Composer の記述。背景色（fill.linear-gradient の 2 色, srgb）もここが唯一の定義
#   layers/N_*.svg   前景レイヤー。1024x1024 の正方形キャンバス全面 = アイコンの外形いっぱい。
#                    番号順に奥→手前。icon.json が参照しないもの（*-flat.svg）は平面版だけで使う
#   menubar.svg      メニューバー用テンプレート画像（16x16 の viewBox, 黒 + 透明度のみ）。@2x とベクター用
#   menubar-16.svg   （任意）16px（@1x）専用に画素へそろえた版。あれば 16px の書き出しはこちらを使う

ICTOOL="${ICTOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"

die() { print -u2 "エラー: $*"; exit 1 }

need_tools() {
  local t
  for t in rsvg-convert iconutil sips plutil xcrun; do
    command -v $t >/dev/null || die "$t が見つかりません"
  done
  [[ -x $ICTOOL ]] || die "ictool が見つかりません（$ICTOOL）。Xcode 26 以降が必要です"
}

# icon.json を JSON として読めるか確かめる
check_icon_json() {
  plutil -convert xml1 -o /dev/null "$1/icon.json" 2>/dev/null || die "$1/icon.json が JSON として読めません"
}

# "srgb:r,g,b,a" を #RRGGBB に変換する
srgb_to_hex() {
  [[ $1 == srgb:* ]] || die "背景色は srgb: 形式で書いてください（$1）"
  print -r -- "$1" | awk -F'[:,]' '{printf "#%02X%02X%02X\n", $2*255+0.5, $3*255+0.5, $4*255+0.5}'
}

# icon.json が参照する画像ファイル名を列挙する
icon_images() {
  plutil -convert xml1 -o - "$1/icon.json" | grep -oE '<string>[^<]+\.(svg|png)</string>' | sed -E 's#</?string>##g'
}

# 案のフォルダから .icon バンドル（icon.json + Assets/）を組み立てる
assemble_icon() {
  emulate -L zsh
  local c=$1 out=$2 f
  check_icon_json $c
  rm -rf $out && mkdir -p $out/Assets
  cp $c/icon.json $out/icon.json
  for f in $(icon_images $c); do
    [[ -f $c/layers/$f ]] || die "$c/layers/$f がありません（icon.json が参照）"
    cp $c/layers/$f $out/Assets/
  done
}

# 超楕円（|x|^n + |y|^n = 1）で角丸四角のパスを作る。macOS の連続曲率の角丸に近い形
squircle_path() {
  awk -v x0=$1 -v y0=$2 -v s=$3 -v n=${4:-5} 'BEGIN{
    pi = atan2(0, -1); a = s / 2; cx = x0 + a; cy = y0 + a; N = 360; printf "M"
    for (i = 0; i < N; i++) {
      t = 2 * pi * i / N; c = cos(t); si = sin(t)
      x = cx + a * (c < 0 ? -1 : 1) * (c < 0 ? -c : c) ^ (2 / n)
      y = cy + a * (si < 0 ? -1 : 1) * (si < 0 ? -si : si) ^ (2 / n)
      printf "%s%.1f,%.1f", (i ? " L" : ""), x, y
    }
    print " Z"
  }'
}

# 平面版（ビットマップ用）の SVG を合成する。
# Big Sur 以降のテンプレートに合わせ、1024 キャンバスの中央 824 に角丸四角を置き、下に影を付ける。
# macOS 26 はこの形を「外形に合う」と判定し、灰色の台座に入れずに新しい角丸でマスクし直す（README 参照）。
compose_flat() {
  emulate -L zsh
  local c=$1 out=$2 f
  check_icon_json $c
  local g0=$(srgb_to_hex "$(plutil -extract fill.linear-gradient.0 raw $c/icon.json)")
  local g1=$(srgb_to_hex "$(plutil -extract fill.linear-gradient.1 raw $c/icon.json)")
  local P=$(squircle_path 100 100 824)
  {
    print '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
    print '<!-- 自動生成（scripts/lib.sh の compose_flat）。直すときは layers/*.svg と icon.json を編集する -->'
    print "<defs>"
    print "<linearGradient id=\"flat-bg\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"$g0\"/><stop offset=\"1\" stop-color=\"$g1\"/></linearGradient>"
    print "<clipPath id=\"flat-shape\"><path d=\"$P\"/></clipPath>"
    print '<filter id="flat-drop" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000000" flood-opacity="0.3"/></filter>'
    print "</defs>"
    print "<path d=\"$P\" fill=\"$g1\" filter=\"url(#flat-drop)\"/>"
    print '<g clip-path="url(#flat-shape)">'
    print '<rect x="100" y="100" width="824" height="824" fill="url(#flat-bg)"/>'
    print '<g transform="translate(100 100) scale(0.8046875)">'
    for f in $c/layers/*.svg(n); do sed '1d;$d' $f; done
    print '</g>'
    print '</g>'
    print '</svg>'
  } > $out
}

# .icon を ictool（Icon Composer 同梱の CLI）で PNG に描画する。窓は出ない。
# rendition: Default / Dark / ClearLight / ClearDark / TintedLight / TintedDark
ic_render() {
  local icon=$1 out=$2 rendition=$3 px=$4
  "$ICTOOL" $icon --export-image --output-file $out --platform macOS --rendition $rendition \
    --width $px --height $px --scale 1 >/dev/null 2>&1 || die "ictool で描画できません（$icon $rendition）"
  [[ -s $out ]] || die "ictool の出力が空です（$out）"
}

# SVG を正方形 PNG に描画する
svg_png() { rsvg-convert -w $2 -h $2 $1 -o $3 || die "rsvg-convert 失敗（$1）" }

# ---- システムの描画で確かめるための関数（export.sh の検証と make-sheet.sh が使う） ----

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Swift ツールをコンパイルする（$1 = ソース, $2 = 出力先）
build_swift_tool() {
  xcrun swiftc -O -o $2 $1 2>/dev/null || die "Swift ツールをコンパイルできません（$1）"
}

# 試験用のダミー .app を作り、そのパスを出力する（$1 = 置き場, $2 = 名前）。
# Icon Services のキャッシュに古い絵が残らないよう、呼び出し側で名前を毎回変える
make_probe_app() {
  local a=$1/$2.app
  rm -rf $a && mkdir -p $a/Contents/MacOS $a/Contents/Resources
  print '#!/bin/sh' > $a/Contents/MacOS/$2 && chmod +x $a/Contents/MacOS/$2
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.makurip.iconcheck.$2" \
    -c "Add :CFBundleExecutable string $2" -c "Add :CFBundlePackageType string APPL" \
    -c "Add :CFBundleName string $2" $a/Contents/Info.plist >/dev/null
  print $a
}

# .icon を actool でコンパイルしてダミー .app に入れる（Xcode のビルドと同じ処理）
app_add_icon() {
  local app=$1 icon=$2 name=${2:t:r}
  xcrun actool $icon --compile $app/Contents/Resources --platform macosx --minimum-deployment-target 13.0 \
    --app-icon $name --output-partial-info-plist $app/../${app:t:r}-partial.plist --target-device mac \
    >/dev/null || die "actool で .icon をコンパイルできません（$icon）"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $name" -c "Add :CFBundleIconName string $name" \
    $app/Contents/Info.plist
}

# .icns をダミー .app に入れる（Xcode を通さずに .app を組む場合と同じ形）
app_add_icns() {
  cp $2 $1/Contents/Resources/AppIcon.icns
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" $1/Contents/Info.plist
}

# システムが描くアイコンを書き出す（$1 = sysicon の実行ファイル, $2 = app, $3 = 出力の接頭辞, 残り = px）。
# 描いたあとは LaunchServices の登録を消す
system_render() {
  local tool=$1 app=$2 prefix=$3; shift 3
  $LSREGISTER -f $app
  $tool $app $prefix "$@" >/dev/null || die "システムの描画に失敗しました（$app）"
  $LSREGISTER -u $app >/dev/null 2>&1 || true
}

# メニューバー用テンプレート画像を PNG にする（$1 = 案のフォルダ, $2 = px, $3 = 出力）。
# 16px で menubar-16.svg があればそれを使い、それ以外は menubar.svg を使う
menubar_png() {
  local src=$1/menubar.svg
  [[ $2 == 16 && -f $1/menubar-16.svg ]] && src=$1/menubar-16.svg
  svg_png $src $2 $3
}


# アセットカタログの直下の Contents.json を書く（$1 = .xcassets のフォルダ）
write_xcassets_root() {
  mkdir -p $1
  print '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}' > $1/Contents.json
}

# メニューバー用テンプレート画像の imageset（16pt の @1x / @2x + テンプレート指定）を書く
# （$1 = 案のフォルダ, $2 = MenuBarIcon.imageset のフォルダ）
write_menubar_imageset() {
  local c=$1 mb=$2
  rm -rf $mb && mkdir -p $mb
  menubar_png $c 16 $mb/MenuBarIcon.png
  menubar_png $c 32 $mb/MenuBarIcon@2x.png
  cat > $mb/Contents.json <<'JSON'
{
  "images" : [
    { "filename" : "MenuBarIcon.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "MenuBarIcon@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
}

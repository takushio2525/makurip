#!/bin/zsh
# tako:run zsh design/icon/scripts/export.sh design/icon/b-parapara
#
# 原稿（SVG・icon.json）から、アイコン一式を書き出して検証する。アプリのビルドが使うのは
# Resources/ のほうで、そちらは sync-resources.sh で作り直す。これは形式ごとの確認と、システムでの見え方の点検用。
#
# 使い方:
#   zsh design/icon/scripts/export.sh <案のフォルダ> [出力先] [--no-system-check]
#   例) zsh design/icon/scripts/export.sh design/icon/b-parapara   → .build/icon-export/b-parapara/ に書き出す（git 管理外）
#
# 書き出すもの（詳しくは design/icon/README.md）:
#   AppIcon.icon/                       Icon Composer 形式（macOS 26 以降の本命。旧 OS 用は Xcode がビルド時に自動生成）
#   Assets.xcassets/AppIcon.appiconset  旧来のアセットカタログ形式（.icon を使わない場合）
#   Assets.xcassets/MenuBarIcon.imageset メニューバー用テンプレート画像（16pt, @1x/@2x）
#   AppIcon.icns                        .icns だけを使う場合（macOS 26 では 32px 以下で灰色の台座に入るので非推奨）
#   compiled/                           Xcode を通さずに .app を組む場合に Resources へ入れる Assets.car など
#   MenuBarIconTemplate.png / @2x.png   NSImage(named:) で読む場合（名前末尾の Template でテンプレート扱いになる）
#   MenuBarIcon.svg                     メニューバー用のベクター原稿（@2x 相当）
#   MenuBarIcon-16.svg                  16px（@1x）専用に画素へそろえた原稿（案のフォルダにある場合だけ）
#   preview/                            macOS 26 の各外観（ictool）と平面版の 1024px、システムが描いた見え方
#   verify.txt                          検証ログ
#
# 必要なもの: Xcode 26 以降（actool / Icon Composer 同梱の ictool）, rsvg-convert（brew install librsvg）
set -euo pipefail

ROOT=${0:A:h:h}
source $ROOT/scripts/lib.sh

SYSTEM_CHECK=1
args=()
for a in "$@"; do
  case $a in
    --no-system-check) SYSTEM_CHECK=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' ${0:A} | sed '$d'; exit 0 ;;
    *) args+=$a ;;
  esac
done
(( ${#args} >= 1 )) || die "案のフォルダを指定してください（例: zsh design/icon/scripts/export.sh design/icon/b-parapara）"
C=${args[1]:A}
NAME=${C:t}
# 既定の出力先はリポジトリの .build/（git 管理外。make clean で消える）
OUT=${args[2]:-$ROOT/../../.build/icon-export/$NAME}
OUT=${OUT:A}

need_tools
[[ -f $C/icon.json && -d $C/layers && -f $C/menubar.svg ]] || die "$C に icon.json / layers/ / menubar.svg がそろっていません"

TMP=$(mktemp -d -t makurip-icon)
trap 'rm -rf $TMP' EXIT
rm -rf $OUT && mkdir -p $OUT/preview
LOG=$OUT/verify.txt
log() { print -r -- "$*" | tee -a $LOG }
: > $LOG
log "# 書き出し検証ログ: $NAME（$(date '+%Y-%m-%d %H:%M')）"

# ---- 1. Icon Composer 形式（.icon） ----
assemble_icon $C $OUT/AppIcon.icon

# ---- 2. 平面版 SVG → アセットカタログの AppIcon と .icns ----
compose_flat $C $TMP/flat.svg
cp $TMP/flat.svg $OUT/preview/AppIcon-flat.svg
XC=$OUT/Assets.xcassets
AI=$XC/AppIcon.appiconset
ISET=$TMP/AppIcon.iconset
mkdir -p $AI $ISET
write_xcassets_root $XC
entries=()
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$(( pt * scale ))
    suffix=""; [[ $scale == 2 ]] && suffix=@2x
    file=icon_${pt}x${pt}${suffix}.png
    svg_png $TMP/flat.svg $px $AI/$file
    cp $AI/$file $ISET/$file
    entries+="    { \"filename\" : \"$file\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${pt}x${pt}\" }"
  done
done
{
  print '{\n  "images" : ['
  print -r -- ${(pj:,\n:)entries}
  print '  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}'
} > $AI/Contents.json
iconutil -c icns $ISET -o $OUT/AppIcon.icns || die "iconutil で .icns を作れません"

# ---- 3. メニューバー用テンプレート画像 ----
MB=$XC/MenuBarIcon.imageset
write_menubar_imageset $C $MB
cp $MB/MenuBarIcon.png $OUT/MenuBarIconTemplate.png
cp $MB/MenuBarIcon@2x.png $OUT/MenuBarIconTemplate@2x.png
cp $C/menubar.svg $OUT/MenuBarIcon.svg
[[ -f $C/menubar-16.svg ]] && cp $C/menubar-16.svg $OUT/MenuBarIcon-16.svg

# ---- 4. プレビュー ----
for r in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  ic_render $OUT/AppIcon.icon $OUT/preview/macos26-$r.png $r 1024
done
svg_png $TMP/flat.svg 1024 $OUT/preview/flat-1024.png

# ---- 5. 検証 ----
log ""
log "## .icns の中身（iconutil で iconset に戻して確かめる）"
iconutil -c iconset $OUT/AppIcon.icns -o $TMP/roundtrip.iconset || die ".icns を iconset に戻せません"
n=$(ls $TMP/roundtrip.iconset | wc -l | tr -d ' ')
log "$(file $OUT/AppIcon.icns | sed "s#$OUT/##")"
for f in $TMP/roundtrip.iconset/*.png(n); do log "  ${f:t}: $(sips -g pixelWidth -g pixelHeight $f | awk '/pixel/{printf "%s ", $2}')"; done
(( n == 10 )) || die ".icns に入っている画像が $n 枚です（10 枚のはず）"
log "→ 10 枚（16〜512pt の @1x/@2x）がそろっている"

log ""
log "## アセットカタログの PNG（ファイル名どおりの寸法か）"
bad=0
for f in $AI/*.png(n); do
  pt=${${f:t}#icon_}; pt=${pt%%x*}
  scale=1; [[ ${f:t} == *@2x* ]] && scale=2
  want=$(( pt * scale ))
  got=$(sips -g pixelWidth $f | awk '/pixelWidth/{print $2}')
  [[ $got == $want ]] || { bad=1; log "  NG ${f:t}: ${got}px（期待 ${want}px）" }
done
(( bad == 0 )) || die "AppIcon.appiconset の寸法が合いません"
log "→ AppIcon.appiconset の 10 枚すべて寸法一致"

log ""
log "## PNG の点検（checkpng.swift）"
build_swift_tool $ROOT/tools/checkpng.swift $TMP/checkpng
$TMP/checkpng $MB/MenuBarIcon.png $MB/MenuBarIcon@2x.png $AI/icon_512x512@2x.png $AI/icon_16x16.png \
  | sed "s#$OUT/##" > $TMP/check.txt
cat $TMP/check.txt | tee -a $LOG
(( $(grep -c 'MenuBarIcon.*黒以外=0' $TMP/check.txt) == 2 )) || die "メニューバー画像に黒以外の色が混ざっています"
log "→ メニューバー画像は黒 + 透明度のみ（黒以外=0）。平面版の四隅α=0（角丸の外は透明）"

log ""
log "## actool でコンパイルできるか（Xcode のビルドと同じ処理）"
mkdir -p $TMP/car1 $TMP/car2 $TMP/car3
xcrun actool $XC --compile $TMP/car1 --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist $TMP/car1/partial.plist --target-device mac --warnings --errors \
  --output-format human-readable-text > $TMP/car1/out.txt 2>&1 || { cat $TMP/car1/out.txt; die "Assets.xcassets をコンパイルできません" }
log "Assets.xcassets → $(cd $TMP/car1 && ls | grep -v -E 'partial|out.txt' | tr '\n' ' ')"
grep -E 'warning|error' $TMP/car1/out.txt | sed 's/^/  /' | tee -a $LOG || true
xcrun actool $OUT/AppIcon.icon --compile $TMP/car2 --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist $TMP/car2/partial.plist --target-device mac --warnings --errors \
  --output-format human-readable-text > $TMP/car2/out.txt 2>&1 || { cat $TMP/car2/out.txt; die "AppIcon.icon をコンパイルできません" }
log "AppIcon.icon → $(cd $TMP/car2 && ls | grep -v -E 'partial|out.txt' | tr '\n' ' ')（.icns は旧 OS 用に actool が .icon から自動生成したもの）"
grep -E 'warning|error' $TMP/car2/out.txt | sed 's/^/  /' | tee -a $LOG || true
xcrun actool $OUT/AppIcon.icon $XC --compile $TMP/car3 --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist $TMP/car3/partial.plist --target-device mac --warnings --errors \
  --output-format human-readable-text > $TMP/car3/out.txt 2>&1 || { cat $TMP/car3/out.txt; die ".icon と Assets.xcassets を同時にコンパイルできません" }
log "AppIcon.icon + Assets.xcassets を同時に → $(cd $TMP/car3 && ls | grep -v -E 'partial|out.txt' | tr '\n' ' ')"
grep -E 'warning|error' $TMP/car3/out.txt | sed 's/^/  /' | tee -a $LOG || true
log "  Info.plist に入るキー: $(plutil -convert json -o - $TMP/car3/partial.plist)"

log ""
log "## assetutil でコンパイル結果の中身を確かめる（.icon + Assets.xcassets を同時にコンパイルした Assets.car）"
xcrun assetutil --info $TMP/car3/Assets.car > $TMP/car3/info.json 2>/dev/null || die "assetutil で Assets.car を読めません"
# assetutil の出力は平たい JSON オブジェクトの並びなので、"}" で区切って 1 件ずつ調べる
groups=$(awk 'BEGIN{RS="}"} /"AssetType" : "IconGroup"/ {n++} END{print n+0}' $TMP/car3/info.json)
mbt=$(awk 'BEGIN{RS="}"} /"Name" : "MenuBarIcon"/ && /"Template Mode" : "template"/ {n++} END{print n+0}' $TMP/car3/info.json)
mbpx=$(awk 'BEGIN{RS="}"} /"Name" : "MenuBarIcon"/ && /"Template Mode"/ {match($0, /"PixelWidth" : [0-9]+/); printf "%spx ", substr($0, RSTART+15, RLENGTH-15)}' $TMP/car3/info.json)
log "AppIcon のレイヤーグループ（IconGroup）: $groups 件 / $(grep -oE '"Name" : "AppIcon\\\\?/[^"]+"' $TMP/car3/info.json | sed -E 's#.*/([^"]+)"#\1#' | sort -u | tr '\n' ' ')"
log "MenuBarIcon（Template Mode = template）: $mbt 件（$mbpx）"
(( groups > 0 )) || die "Assets.car に .icon 由来のレイヤー付きアイコンが入っていません"
(( mbt == 2 )) || die "Assets.car の MenuBarIcon がテンプレート指定の @1x/@2x 2 件になっていません（$mbt 件）"
log "→ AppIcon は .icon 由来のレイヤー付き、MenuBarIcon はテンプレート指定の @1x/@2x"

# Xcode を通さずに .app を組む場合に、そのまま Contents/Resources へ入れられるコンパイル済みの一式
mkdir -p $OUT/compiled
cp $TMP/car3/Assets.car $TMP/car3/AppIcon.icns $OUT/compiled/
cp $TMP/car3/partial.plist $OUT/compiled/Info-partial.plist

if (( SYSTEM_CHECK )); then
  log ""
  log "## macOS が実際に描く見え方（NSWorkspace。灰色の台座に入れられていないか）"
  build_swift_tool $ROOT/tools/sysicon.swift $TMP/sysicon
  stamp=$(date +%s)$$
  a1=$(make_probe_app $TMP MakuripIconCheck-$NAME-icon-$stamp)
  app_add_icon $a1 $OUT/AppIcon.icon
  system_render $TMP/sysicon $a1 $OUT/preview/system-icon 256 64 32 16
  a2=$(make_probe_app $TMP MakuripIconCheck-$NAME-appiconset-$stamp)
  xcrun actool $XC --compile $a2/Contents/Resources --platform macosx --minimum-deployment-target 13.0 \
    --app-icon AppIcon --output-partial-info-plist $TMP/a2.plist --target-device mac >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" -c "Add :CFBundleIconName string AppIcon" \
    $a2/Contents/Info.plist
  system_render $TMP/sysicon $a2 $OUT/preview/system-appiconset 256 64 32 16
  a3=$(make_probe_app $TMP MakuripIconCheck-$NAME-icns-$stamp)
  app_add_icns $a3 $OUT/AppIcon.icns
  system_render $TMP/sysicon $a3 $OUT/preview/system-icns 256 64 32 16
  log "preview/system-icon-*.png       .icon を actool でコンパイル（Assets.car + CFBundleIconName）"
  log "preview/system-appiconset-*.png AppIcon.appiconset を actool でコンパイル（Assets.car + CFBundleIconName）"
  log "preview/system-icns-*.png       .icns だけ（CFBundleIconFile のみ）"
  log "→ 目で確かめる: 上の 2 つは全サイズで角丸四角の外形いっぱいに描かれること。"
  log "  .icns だけの場合、macOS 26.4 は 32px 以下で灰色の台座に縮小して描く（他社の .icns だけのアプリも同じ。design/icon/README.md 参照）"
fi

log ""
log "完了: $OUT"

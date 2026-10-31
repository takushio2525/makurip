#!/bin/zsh
# tako:run zsh design/icon/scripts/sync-resources.sh
#
# 原稿（design/icon/b-parapara/）から、アプリのビルドが使うアイコンの入力（Resources/）を作り直す。
# 原稿を直したら、これを流してから scripts/build-app.sh（make app）でビルドする。
#
#   Resources/AppIcon.icon/                         Dock・Finder 用（Icon Composer 形式）。build-app.sh が actool でコンパイルする
#   Resources/Assets.xcassets/MenuBarIcon.imageset  メニューバー用テンプレート画像（16pt の @1x / @2x。@1x は menubar-16.svg から）
#
# 使い方: zsh design/icon/scripts/sync-resources.sh [案のフォルダ]（省略時 design/icon/b-parapara）
# 必要なもの: rsvg-convert（brew install librsvg）, Xcode（actool でコンパイルできるかの確認に使う）
set -euo pipefail

ICON_ROOT=${0:A:h:h}
REPO=${ICON_ROOT:h:h}
source $ICON_ROOT/scripts/lib.sh

C=${1:-$ICON_ROOT/b-parapara}
C=${C:A}
[[ -f $C/icon.json && -d $C/layers && -f $C/menubar.svg ]] || die "$C に icon.json / layers/ / menubar.svg がそろっていません"
for t in rsvg-convert plutil xcrun; do command -v $t >/dev/null || die "$t が見つかりません"; done

RES=$REPO/Resources
assemble_icon $C $RES/AppIcon.icon
write_xcassets_root $RES/Assets.xcassets
write_menubar_imageset $C $RES/Assets.xcassets/MenuBarIcon.imageset

# build-app.sh と同じ形で actool に通し、コンパイルできることを確かめる
TMP=$(mktemp -d -t makurip-sync)
trap 'rm -rf $TMP' EXIT
xcrun actool $RES/AppIcon.icon $RES/Assets.xcassets --compile $TMP --platform macosx \
  --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist $TMP/partial.plist \
  --target-device mac --errors --warnings --output-format human-readable-text > $TMP/out.txt 2>&1 \
  || { cat $TMP/out.txt; die "actool でコンパイルできません" }
grep -q -E 'error|warning' $TMP/out.txt && { cat $TMP/out.txt; die "actool がエラーか警告を出しました" }
[[ -f $TMP/Assets.car ]] || die "Assets.car ができません"

print "作り直しました（${RES#$REPO/}/）:"
(cd $REPO && find Resources -type f | sort | sed 's/^/  /')

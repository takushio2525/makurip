#!/bin/bash
# tako:run design/ui-compare/shoot.sh
#
# 試作（~/dev/makurip-design/ui の案 B と候補窓）と SwiftUI のパネル・候補窓を同じ状態で描き、横に並べた比較画像を作る。
# 画面ロック中でも動く（試作はヘッドレス Chrome、SwiftUI はオフスクリーン描画）。窓は画面に出さない。
#
# 出力（git 管理外）: $OUT/compare/compare-<状態>.png（左が試作・右が SwiftUI。2 倍）・swift-*.png・open-speed.txt
#
#   design/ui-compare/shoot.sh                 # 既定の場所から試作を読む
#   MAKURIP_DESIGN_DIR=<試作の ui フォルダ> OUT=<出力先> design/ui-compare/shoot.sh
#
# 試作のファイルは読むだけ（書き換えない）。比べやすくするため、試作側はぼかしを切って単色の背景に置き、
# パネルを CSS の (40, 40) に固定する。データは試作と同じ架空の履歴（秘密の 2 件は #5 の範囲なので除く）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DESIGN="${MAKURIP_DESIGN_DIR:-$HOME/dev/makurip-design/ui}"
OUT="${OUT:-$ROOT/.ui-compare}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

[ -f "$DESIGN/shared/panel-b.js" ] || {
    echo "試作が見つからない: $DESIGN（MAKURIP_DESIGN_DIR で指定する）" >&2
    exit 1
}
[ -x "$CHROME" ] || {
    echo "Google Chrome が見つからない（CHROME で指定する）" >&2
    exit 1
}
command -v node > /dev/null || {
    echo "node が要る（試作の data.js から画像の SVG を取り出す）" >&2
    exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/work/svg" "$OUT/assets" "$OUT/proto" "$OUT/compare"

echo "== 試作の画像（SVG）を取り出して PNG にする"
DATA_JS="$DESIGN/shared/data.js" SVG_DIR="$OUT/work/svg" node -e '
global.window = {};
require(process.env.DATA_JS);
const fs = require("fs");
for (const it of window.MK_DATA.items) if (it.kind === "image") {
  fs.writeFileSync(`${process.env.SVG_DIR}/${it.id}.svg`, decodeURIComponent(it.src.split(",")[1]));
}'
xcrun swift "$HERE/rasterize.swift" "$OUT/work/svg" "$OUT/assets" h03 h09 h19 h25

echo "== 試作をヘッドレス Chrome で撮る"
sed "s#@DESIGN@#$DESIGN#g" "$HERE/b-states.html" > "$OUT/work/b-states.html"
shoot() { # 名前 テーマ 状態 [追加の引数]
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
        --user-data-dir="$OUT/work/chrome" --window-size=1440,900 --force-device-scale-factor=2 \
        --virtual-time-budget=2500 --allow-file-access-from-files \
        --screenshot="$OUT/proto/$1.png" "file://$OUT/work/b-states.html?clean=1&theme=$2&state=$3${4:-}" 2> /dev/null
}
shoot light light light
shoot dark dark dark
shoot peek-light light peek-light
shoot peek-dark dark peek-dark
shoot filtered light filtered
shoot filtered-dark dark filtered
shoot search light search
shoot empty-search light empty-search
shoot empty-search-dark dark empty-search
shoot empty-history light light "&empty=1"
shoot pinned light pinned
shoot picker light picker

echo "== 試作の候補窓をヘッドレス Chrome で撮る"
sed "s#@DESIGN@#$DESIGN#g" "$HERE/candidate-states.html" > "$OUT/work/candidate-states.html"
shoot_cand() { # 名前 テーマ [追加の引数]
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
        --user-data-dir="$OUT/work/chrome" --window-size=1440,900 --force-device-scale-factor=2 \
        --virtual-time-budget=2500 --allow-file-access-from-files \
        --screenshot="$OUT/proto/$1.png" "file://$OUT/work/candidate-states.html?clean=1&theme=$2${3:-}" 2> /dev/null
}
shoot_cand candidate-light light "&idx=3"
shoot_cand candidate-dark dark "&idx=2"
shoot_cand candidate-image light "&idx=7"
shoot_cand candidate-long light "&idx=12"
shoot_cand candidate-scrolled-dark dark "&idx=15"
shoot_cand candidate-ime light "&order=ime"
shoot_cand candidate-empty light "&count=0"
shoot_cand candidate-one light "&count=1"

echo "== SwiftUI のパネルをオフスクリーンで描き、試作と並べる"
(cd "$ROOT" && MAKURIP_SNAPSHOT_DIR="$OUT/compare" MAKURIP_SNAPSHOT_ASSETS="$OUT/assets" \
    MAKURIP_PROTO_SHOTS="$OUT/proto" swift test --filter "SnapshotTests|StoreSpeedTests|CandidateSnapshotTests" 2>&1 |
    grep -E "件:|件を読む|✔ Test run|✘" || true)
rm -rf "$OUT/work"
echo "比較画像: $OUT/compare/"

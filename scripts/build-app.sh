#!/bin/bash
# tako:run scripts/build-app.sh
#
# Makurip.app を組み立てて署名する。出力: .app-build/Makurip.app（最後の行にパスを出す）
#
#   CONFIGURATION=debug scripts/build-app.sh   # デバッグビルドで組み立てる（既定は release）
#
# 署名の証明書は Config/signing.local.env の MAKURIP_SIGN_IDENTITY（雛形は signing.local.env.example）。
# アイコンは Resources/（AppIcon.icon と Assets.xcassets）を actool でコンパイルして入れる（Xcode が要る）。
# Resources/ は design/icon/ の原稿から design/icon/scripts/sync-resources.sh で作る。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
PLIST="$ROOT/Sources/Makurip/Info.plist"
OUT="$ROOT/.app-build"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
NAME="$(plist_value CFBundleName)"
EXECUTABLE="$(plist_value CFBundleExecutable)"
ICON_NAME="$(plist_value CFBundleIconName)"
MIN_OS="$(plist_value LSMinimumSystemVersion)"
APP="$OUT/$NAME.app"

if [ -f "$ROOT/Config/signing.local.env" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/Config/signing.local.env"
fi
if [ -z "${MAKURIP_SIGN_IDENTITY:-}" ] || [[ "$MAKURIP_SIGN_IDENTITY" == "<"* ]]; then
    echo "署名の設定がない: Config/signing.local.env.example を Config/signing.local.env に写して MAKURIP_SIGN_IDENTITY を入れる" >&2
    exit 2
fi

cd "$ROOT"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE" >&2
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# アイコン: Dock・Finder 用の Icon Composer 形式（.icon）とメニューバー用のアセットカタログを actool でまとめて
# コンパイルし、Contents/Resources に Assets.car（と旧 OS 用の .icns）を作る（Xcode のビルドと同じ処理）。
# macOS 26 は .icns だけだと 32px 以下で灰色の台座に入れて描くので、Assets.car と CFBundleIconName で渡す。
ACTOOL_LOG="$(xcrun actool "$ROOT/Resources/$ICON_NAME.icon" "$ROOT/Resources/Assets.xcassets" \
    --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target "$MIN_OS" \
    --app-icon "$ICON_NAME" --output-partial-info-plist "$OUT/actool-partial.plist" --target-device mac \
    --errors --warnings --output-format human-readable-text 2>&1)" || {
    echo "$ACTOOL_LOG" >&2
    echo "actool でアイコンをコンパイルできない" >&2
    exit 1
}
if echo "$ACTOOL_LOG" | grep -q -E 'error|warning'; then
    echo "$ACTOOL_LOG" >&2
    echo "actool がエラーか警告を出した" >&2
    exit 1
fi
if [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
    echo "Assets.car ができていない" >&2
    exit 1
fi
rm -f "$OUT/actool-partial.plist"

# Hardened Runtime で署名する（アクセシビリティ・キー送信に追加の entitlement は要らない）
codesign --force --options runtime --timestamp=none --sign "$MAKURIP_SIGN_IDENTITY" "$APP" >&2
codesign --verify --strict "$APP" >&2
echo "$APP"

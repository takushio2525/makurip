#!/bin/bash
# tako:run scripts/build-app.sh
#
# Makurip.app を組み立てて署名する。出力: .app-build/Makurip.app（最後の行にパスを出す）
#
#   CONFIGURATION=debug scripts/build-app.sh   # デバッグビルドで組み立てる（既定は release）
#
# 署名の証明書は Config/signing.local.env の MAKURIP_SIGN_IDENTITY（雛形は signing.local.env.example）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
PLIST="$ROOT/Sources/Makurip/Info.plist"
OUT="$ROOT/.app-build"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
NAME="$(plist_value CFBundleName)"
EXECUTABLE="$(plist_value CFBundleExecutable)"
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

# Hardened Runtime で署名する（アクセシビリティ・キー送信に追加の entitlement は要らない）
codesign --force --options runtime --timestamp=none --sign "$MAKURIP_SIGN_IDENTITY" "$APP" >&2
codesign --verify --strict "$APP" >&2
echo "$APP"

#!/bin/bash
# tako:run scripts/install.sh
#
# 組み立てて署名した Makurip.app を決まった場所（既定 ~/Applications/Makurip.app）へ入れる。
# 場所と署名を固定するのは、アクセシビリティの許可を 1 回で済ませるため（許可は署名とパスに紐づく）。
#
# 入れ替える前に、その場所の Makurip が動いていれば止める（検証用インスタンスを含む）。
# 止めたくなければ先に自分で終了しておく。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/Config/signing.local.env" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/Config/signing.local.env"
fi
DEST_DIR="${MAKURIP_INSTALL_DIR:-$HOME/Applications}"

BUILT="$("$ROOT/scripts/build-app.sh" | tail -n 1)"
NAME="$(basename "$BUILT")"
DEST="$DEST_DIR/$NAME"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BUILT/Contents/Info.plist")"

RUNNING="$(pgrep -f "^$DEST/Contents/MacOS/$EXECUTABLE" || true)"
if [ -n "$RUNNING" ]; then
    echo "動いている $NAME を止める: pid=$(echo "$RUNNING" | tr '\n' ' ')" >&2
    # shellcheck disable=SC2086
    kill -TERM $RUNNING
    for _ in $(seq 1 50); do
        pgrep -f "^$DEST/Contents/MacOS/$EXECUTABLE" > /dev/null || break
        sleep 0.1
    done
fi

mkdir -p "$DEST_DIR"
rm -rf "${DEST:?}"
ditto "$BUILT" "$DEST"
codesign --verify --strict "$DEST"
echo "入れた: $DEST" >&2
codesign -dv "$DEST" 2>&1 | grep -E "^(Identifier|Format|Authority|TeamIdentifier|Runtime|Signature)" | sed -E 's/(TeamIdentifier=).*/\1<非表示>/; s/(Authority=Apple Development: ).*/\1<非表示>/' >&2
echo "$DEST"

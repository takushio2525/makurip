#!/bin/bash
# tako:run scripts/release.sh --skip-notarize
#
# Makurip を配布する（#41）。1 つのコマンドで、組み立て → Developer ID の署名 → 公証 → staple → zip → sha256 →
# quarantine を付けた Gatekeeper の確かめ → annotated tag → GitHub Release まで行う。
#
#   scripts/release.sh                  # 全部（tag vX.Y.Z と Release。添付は Makurip-X.Y.Z.zip と .sha256）
#   scripts/release.sh --no-publish     # 公証・staple した zip と sha256 を作って確かめるだけ（tag・Release は作らない）
#   scripts/release.sh --skip-notarize  # 署名して zip と sha256 を作るだけ（公証の手前まで。Developer ID がなくても流れを試せる）
#
# 版は Sources/Makurip/Info.plist の CFBundleShortVersionString（X.Y.Z）。上げるのは scripts/bump-version.sh X.Y.Z。
# 出力は .release/<版>/（MAKURIP_RELEASE_OUT で変えられる）。
#
# 前提（Config/signing.local.env。git 管理外）:
#   MAKURIP_RELEASE_IDENTITY  Developer ID Application の証明書（40 桁のハッシュか名前）
#   MAKURIP_NOTARY_PROFILE    notarytool の鍵束のプロファイル名（省略時 makurip-notary。
#                             作り方: xcrun notarytool store-credentials makurip-notary ...）
# 試験用（--no-publish・--skip-notarize のときだけ）: MAKURIP_VERSION_OVERRIDE=X.Y.Z で .app の版だけを変える。
#
# 公開のリポジトリなので、チーム ID・証明書の名前・Apple ID はこのスクリプトの出力にも出さない。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/Makurip/Info.plist"
MODE="publish"
case "${1:-}" in
    "") ;;
    --no-publish) MODE="no-publish" ;;
    --skip-notarize) MODE="skip-notarize" ;;
    -h | --help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "知らない引数: $1（--no-publish か --skip-notarize）" >&2
        exit 1
        ;;
esac

if [ -f "$ROOT/Config/signing.local.env" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/Config/signing.local.env"
fi
NOTARY_PROFILE="${MAKURIP_NOTARY_PROFILE:-makurip-notary}"

say() { echo "== $*" >&2; }
fail() {
    echo "止めた: $*" >&2
    exit 1
}

# --- 版 ---
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [ -n "${MAKURIP_VERSION_OVERRIDE:-}" ]; then
    [ "$MODE" = "publish" ] && fail "MAKURIP_VERSION_OVERRIDE は --no-publish か --skip-notarize のときだけ使える（公開する版は Info.plist で決める）"
    VERSION="$MAKURIP_VERSION_OVERRIDE"
fi
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "版 $VERSION が X.Y.Z の形ではない"
TAG="v$VERSION"
NAME="Makurip-$VERSION.zip"
OUT="${MAKURIP_RELEASE_OUT:-$ROOT/.release/$VERSION}"
say "版 ${VERSION}（${MODE}）→ $OUT"

# --- 証明書 ---
if [ "$MODE" = "skip-notarize" ]; then
    IDENTITY="${MAKURIP_RELEASE_IDENTITY:-${MAKURIP_SIGN_IDENTITY:-}}"
else
    IDENTITY="${MAKURIP_RELEASE_IDENTITY:-}"
    [ -n "$IDENTITY" ] && [[ "$IDENTITY" != "<"* ]] \
        || fail "Config/signing.local.env に MAKURIP_RELEASE_IDENTITY（Developer ID Application の証明書）がない"
    security find-identity -v -p codesigning | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application: ' \
        || fail "MAKURIP_RELEASE_IDENTITY が鍵束の Developer ID Application の証明書を指していない"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
        || fail "notarytool のプロファイル $NOTARY_PROFILE が使えない（xcrun notarytool store-credentials で作る）"
fi
[ -n "$IDENTITY" ] && [[ "$IDENTITY" != "<"* ]] || fail "署名の証明書の設定がない（Config/signing.local.env）"

# --- 公開の前の確かめ（tag と Release は main の push 済みの版からだけ作る）---
if [ "$MODE" = "publish" ]; then
    cd "$ROOT"
    [ -z "$(git status --porcelain)" ] || fail "作業ツリーに未コミットの変更がある"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "main ブランチで実行する"
    git fetch --quiet origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main が origin/main と同じではない（pull か push を先に）"
    git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && fail "tag $TAG はもうある"
    [ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || fail "origin に tag $TAG がもうある"
    gh auth status > /dev/null 2>&1 || fail "gh にログインしていない"
    gh release view "$TAG" > /dev/null 2>&1 && fail "Release $TAG はもうある"
fi

# --- 組み立てと署名 ---
rm -rf "${OUT:?}"
mkdir -p "$OUT"
say "組み立てて署名する（Hardened Runtime・Apple の時刻印）"
TIMESTAMP=1
[ "$MODE" = "skip-notarize" ] && TIMESTAMP="${MAKURIP_SIGN_TIMESTAMP:-0}"
BUILT="$(MAKURIP_BUILD_IDENTITY="$IDENTITY" MAKURIP_SIGN_TIMESTAMP="$TIMESTAMP" \
    MAKURIP_VERSION_OVERRIDE="${MAKURIP_VERSION_OVERRIDE:-}" "$ROOT/scripts/build-app.sh" | tail -n 1)"
APP="$OUT/Makurip.app"
ditto "$BUILT" "$APP"
codesign --verify --strict --deep "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
    || fail ".app の版が $VERSION ではない"
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
echo "$SIGN_INFO" | grep -q "flags=0x10000(runtime)" || fail "Hardened Runtime で署名されていない"
if [ "$MODE" != "skip-notarize" ]; then
    echo "$SIGN_INFO" | grep -q "^Authority=Developer ID Application: " || fail "Developer ID で署名されていない"
    echo "$SIGN_INFO" | grep -q "^Timestamp=" || fail "Apple の時刻印がない"
fi

# --- 公証と staple ---
if [ "$MODE" != "skip-notarize" ]; then
    say "公証に出して待つ（数分かかる）"
    UPLOAD="$OUT/notarize-upload.zip"
    ditto -c -k --keepParent "$APP" "$UPLOAD"
    RESULT="$OUT/notarize-result.json"
    xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RESULT" \
        || true
    STATUS="$(plutil -extract status raw -o - "$RESULT" 2> /dev/null || echo "不明")"
    SUBMISSION="$(plutil -extract id raw -o - "$RESULT" 2> /dev/null || echo "")"
    if [ "$STATUS" != "Accepted" ]; then
        if [ -n "$SUBMISSION" ]; then
            xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" "$OUT/notarize-log.json" > /dev/null 2>&1 \
                && plutil -extract issues json -o - "$OUT/notarize-log.json" >&2 || true
        fi
        fail "公証が通らなかった（status=${STATUS}）"
    fi
    rm -f "$UPLOAD"
    say "staple する"
    xcrun stapler staple "$APP" > /dev/null
    xcrun stapler validate "$APP" > /dev/null || fail "stapler validate が通らない"
    ASSESS="$(spctl -a -vv -t exec "$APP" 2>&1)"
    echo "$ASSESS" | grep -q "source=Notarized Developer ID" || fail "spctl が Notarized Developer ID と言わない"
    echo "  spctl: $(echo "$ASSESS" | grep -E "accepted|source=" | tr '\n' ' ')" >&2
fi

# --- zip と sha256（公証・staple した .app を ditto で固める）---
say "zip と sha256 を作る"
ditto -c -k --keepParent "$APP" "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "  $(cat "$OUT/$NAME.sha256" | cut -c1-16)…  ${NAME}（$(stat -f %z "$OUT/$NAME") バイト）" >&2

# --- quarantine を付けた zip を別の場所で展開して、Gatekeeper の判定を見る（ブラウザで落としたときと同じ）---
if [ "$MODE" != "skip-notarize" ]; then
    say "quarantine を付けた zip を別の場所で展開して確かめる"
    GK="$(mktemp -d "${TMPDIR:-/tmp}/makurip-gatekeeper.XXXXXX")"
    cp "$OUT/$NAME" "$GK/$NAME"
    xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$GK/$NAME"
    ditto -x -k "$GK/$NAME" "$GK/x"
    xattr -p com.apple.quarantine "$GK/x/Makurip.app" > /dev/null 2>&1 || fail "展開した .app に quarantine が付いていない"
    GK_ASSESS="$(spctl -a -vv -t exec "$GK/x/Makurip.app" 2>&1)"
    echo "$GK_ASSESS" | grep -q "source=Notarized Developer ID" || fail "quarantine 付きの .app を Gatekeeper が通さない"
    xcrun stapler validate "$GK/x/Makurip.app" > /dev/null || fail "展開した .app の staple が読めない"
    if command -v syspolicy_check > /dev/null; then
        syspolicy_check distribution "$GK/x/Makurip.app" > /dev/null 2>&1 || fail "syspolicy_check distribution が通らない"
    fi
    rm -rf "$GK"
    echo "  quarantine 付き: $(echo "$GK_ASSESS" | grep -E "accepted|source=" | tr '\n' ' ')" >&2
fi

# --- tag と Release ---
if [ "$MODE" = "publish" ]; then
    say "annotated tag $TAG を打って push する"
    cd "$ROOT"
    git tag -a "$TAG" -m "Makurip $VERSION"
    git push origin "$TAG"
    say "GitHub Release $TAG を作る"
    gh release create "$TAG" "$OUT/$NAME" "$OUT/$NAME.sha256" --verify-tag --generate-notes --title "Makurip $VERSION"
    # 公開された添付を落とし直して照らす（アプリのアップデートが読むのと同じもの）
    CHECK="$(mktemp -d "${TMPDIR:-/tmp}/makurip-release.XXXXXX")"
    gh release download "$TAG" -D "$CHECK" -p "$NAME" -p "$NAME.sha256"
    (cd "$CHECK" && shasum -a 256 -c "$NAME.sha256" > /dev/null) || fail "公開された zip の sha256 が合わない"
    rm -rf "$CHECK"
    echo "  $(gh release view "$TAG" --json url -q .url)" >&2
fi

say "できた"
echo "$OUT/$NAME"

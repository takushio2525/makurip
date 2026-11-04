#!/bin/bash
# tako:run scripts/bump-version.sh
#
# 版を上げる（#41）。Sources/Makurip/Info.plist の CFBundleShortVersionString を X.Y.Z にし、
# CFBundleVersion（ビルド番号。整数）を 1 つ上げる。コミット・tag・Release はしない（tag は scripts/release.sh が打つ）。
#
#   scripts/bump-version.sh 0.2.0
#
# 版の付け方（.agent/conventions.md の「版と配布」）: 機能を足したら Y、直しだけなら Z を上げる（1.0.0 までは X は 0）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/Makurip/Info.plist"
NEW="${1:-}"
[[ "$NEW" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo "使い方: scripts/bump-version.sh X.Y.Z" >&2
    exit 1
}
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
# 数として比べる（新しい版は今より大きいこと）
newer() {
    local IFS=.
    # shellcheck disable=SC2206
    local a=($1) b=($2)
    for i in 0 1 2; do
        [ "${a[$i]}" -gt "${b[$i]}" ] && return 0
        [ "${a[$i]}" -lt "${b[$i]}" ] && return 1
    done
    return 1
}
newer "$NEW" "$CURRENT" || {
    echo "$NEW は今の版 $CURRENT より新しくない" >&2
    exit 2
}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$PLIST"
echo "${CURRENT}（${BUILD}）→ ${NEW}（$((BUILD + 1))）"

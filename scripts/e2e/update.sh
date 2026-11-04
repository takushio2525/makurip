#!/bin/bash
# tako:run scripts/e2e/update.sh
#
# アップデートの隔離 E2E（#43 の受け入れ条件 3〜5 と境目）。古い版の .app を作業場所に置き、偽の配信元（file:// の Release の一覧）
# から新しい版へ入れ替えて起動し直すところまでと、入れ替えてはいけない場合（sha256 の不一致・壊れた sha256 の行・中身の改ざん・
# 別の署名・中の版の違い・通信の失敗・新しくない版・prerelease だけ）で今の版のまま理由を出すかを確かめる。
#
#   scripts/e2e/update.sh                            # 本番と同じ確かめ（Developer ID で署名して公証した 2 つの版。公証に数分ずつ）
#   UPDATE_E2E_UNNOTARIZED=1 scripts/e2e/update.sh   # 公証の確かめだけ外す（--update-allow-unnotarized。Developer ID がない間の試し）
#
# 安全の約束（lib.sh に加えて）:
# - 置き換えるのは .e2e/ の下に写した .app だけ。~/Applications の本番には触らない
# - 本物の GitHub に試験用の Release を出さない（配信元は file:// の一覧）
# - 起動したインスタンスは必ず終了する。窓は出さない（遠隔操作では結果の窓を出さない）
# - 署名の要件・チーム ID・証明書の名前は出さない（比べた結果だけを出す）
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

OLD="0.0.1"
NEW="0.0.2"
UNNOTARIZED="${UPDATE_E2E_UNNOTARIZED:-0}"

build_devtool
new_run_dir update
APP="$RUN/Applications/Makurip.app"
EXE="$APP/Contents/MacOS/Makurip"
FEED="$RUN/feed"
mkdir -p "$RUN/Applications" "$FEED"
trap 'finish_run' EXIT

EXTRA=()
[ "$UNNOTARIZED" = "1" ] && EXTRA=(--update-allow-unnotarized)

# --- 2 つの版を作る ---
# 本番と同じ確かめ: scripts/release.sh --no-publish（Developer ID の署名・公証・staple・zip・sha256）
# 公証を外す試し: いつもの組み立て（Config/signing.local.env の MAKURIP_SIGN_IDENTITY）で .app を作って固める
build_version() { # 版 出力先
    if [ "$UNNOTARIZED" = "1" ]; then
        mkdir -p "$2"
        local built
        built="$(MAKURIP_VERSION_OVERRIDE="$1" "$ROOT/scripts/build-app.sh" 2> /dev/null | tail -n 1)"
        ditto "$built" "$2/Makurip.app"
        ditto -c -k --keepParent "$2/Makurip.app" "$2/Makurip-$1.zip"
        (cd "$2" && shasum -a 256 "Makurip-$1.zip" > "Makurip-$1.zip.sha256")
    else
        MAKURIP_VERSION_OVERRIDE="$1" MAKURIP_RELEASE_OUT="$2" "$ROOT/scripts/release.sh" --no-publish > /dev/null
    fi
}

echo "== 2 つの版を作る（$OLD と $NEW。$([ "$UNNOTARIZED" = "1" ] && echo "公証の確かめを外す試し" || echo "Developer ID・公証済み")）"
build_version "$OLD" "$RUN/old"
build_version "$NEW" "$RUN/new"

dr_of() { codesign -d -r- "$1" 2> /dev/null | sed -n 's/^designated => //p'; }
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
exe_hash() { shasum -a 256 "$EXE" | cut -d' ' -f1; }

check "2 つの版の designated requirement が同じ" "yes" "$([ "$(dr_of "$RUN/old/Makurip.app")" = "$(dr_of "$RUN/new/Makurip.app")" ] && echo yes || echo no)"
if [ "$UNNOTARIZED" != "1" ]; then
    check "新しい版は公証済み（spctl）" "*source=Notarized Developer ID*" "$(spctl -a -vv -t exec "$RUN/new/Makurip.app" 2>&1 | tr '\n' ' ')"
fi

install_old() {
    rm -rf "$APP"
    ditto -x -k "$RUN/old/Makurip-$OLD.zip" "$RUN/Applications"
    OLD_HASH="$(exe_hash)"
}

# 偽の Release の一覧。引数は「版 zip sha256 [prerelease|draft]」の組（zip と sha256 は file の場所）
write_feed() { # 出力 組…
    local out="$1"
    shift
    local entries="[]"
    while [ "$#" -ge 3 ]; do
        local version="$1" zip="$2" sha="$3" flag="${4:-}"
        shift 3
        if [ "$flag" = "prerelease" ] || [ "$flag" = "draft" ]; then shift; fi
        local size=0
        [ -f "$zip" ] && size="$(stat -f %z "$zip")"
        entries="$(jq --arg v "$version" --arg zip "file://$zip" --arg sha "file://$sha" --argjson size "$size" \
            --arg flag "$flag" '. + [{
                tag_name: ("v" + $v), draft: ($flag == "draft"), prerelease: ($flag == "prerelease"),
                assets: [
                    {name: ("Makurip-" + $v + ".zip"), size: $size, state: "uploaded", browser_download_url: $zip},
                    {name: ("Makurip-" + $v + ".zip.sha256"), state: "uploaded", browser_download_url: $sha}
                ]}]' <<< "$entries")"
    done
    echo "$entries" > "$out"
}

# 新しい版の zip を作り直して置く（中身を書き換える関数を渡せる）。sha256 は作り直した zip に合わせる
repack() { # 名前 版 [書き換える関数]
    local dir="$FEED/$1"
    rm -rf "$dir"
    mkdir -p "$dir/x"
    ditto -x -k "$RUN/new/Makurip-$NEW.zip" "$dir/x"
    if [ -n "${3:-}" ]; then "$3" "$dir/x/Makurip.app"; fi
    ditto -c -k --keepParent "$dir/x/Makurip.app" "$dir/Makurip-$2.zip"
    (cd "$dir" && shasum -a 256 "Makurip-$2.zip" > "Makurip-$2.zip.sha256")
    rm -rf "$dir/x"
}

tamper() { printf 'x' >> "$1/Contents/Resources/Assets.car"; }
adhoc() { codesign --force --sign - "$1" 2> /dev/null; }

APPLY() { # 一覧 → 終了コードを $CODE、出力を $OUTPUT に
    set +e
    OUTPUT="$("$EXE" --data-dir "$DATA" --update-feed "file://$1" "${EXTRA[@]}" --update apply 2>&1)"
    CODE=$?
    set -e
}

expect_untouched() { # 名前
    check "$1: 今の版のまま" "$OLD" "$(version_of "$APP")"
    check "$1: 実行ファイルも同じ" "$OLD_HASH" "$(exe_hash)"
    check "$1: 置き場所に残りがない" "Makurip.app" "$(ls "$RUN/Applications" | tr '\n' ' ' | sed 's/ $//')"
}

install_old
check "古い版を置いた" "$OLD" "$(version_of "$APP")"

echo "== 1. 入れ替えてはいけない場合（CLI。今の版のまま理由を出す）"
write_feed "$FEED/same.json" "$OLD" "$RUN/old/Makurip-$OLD.zip" "$RUN/old/Makurip-$OLD.zip.sha256"
APPLY "$FEED/same.json"
check "同じ版しかない: 終了コード 0" "0" "$CODE"
check "同じ版しかない: 最新と言う" "*最新*" "$OUTPUT"
expect_untouched "同じ版しかない"

write_feed "$FEED/older.json" "0.0.0" "$RUN/old/Makurip-$OLD.zip" "$RUN/old/Makurip-$OLD.zip.sha256"
APPLY "$FEED/older.json"
check "古い版しかない: 最新と言う" "*最新*" "$OUTPUT"
expect_untouched "古い版しかない"

write_feed "$FEED/prerelease.json" "$NEW" "$RUN/new/Makurip-$NEW.zip" "$RUN/new/Makurip-$NEW.zip.sha256" prerelease \
    "0.0.3" "$RUN/new/Makurip-$NEW.zip" "$RUN/new/Makurip-$NEW.zip.sha256" draft
APPLY "$FEED/prerelease.json"
check "prerelease と draft だけ: 最新と言う" "*最新*" "$OUTPUT"
expect_untouched "prerelease と draft だけ"

APPLY "$RUN/no-such-feed.json"
check "通信できない（一覧がない）: 終了コード 3" "3" "$CODE"
check "通信できない: 理由を出す" "*確かめられませんでした*" "$OUTPUT"
expect_untouched "通信できない"
set +e
OUTPUT="$("$EXE" --data-dir "$DATA" --update-feed "http://127.0.0.1:9/feed.json" "${EXTRA[@]}" --update check 2>&1)"
CODE=$?
set -e
check "つながらない相手（127.0.0.1:9）: 終了コード 3" "3" "$CODE"

repack badsha "$NEW"
echo "$(printf '0%.0s' $(seq 1 64))  Makurip-$NEW.zip" > "$FEED/badsha/Makurip-$NEW.zip.sha256"
write_feed "$FEED/badsha.json" "$NEW" "$FEED/badsha/Makurip-$NEW.zip" "$FEED/badsha/Makurip-$NEW.zip.sha256"
APPLY "$FEED/badsha.json"
check "sha256 の不一致: 終了コード 2" "2" "$CODE"
check "sha256 の不一致: 理由" "*sha256 が一致しない*" "$OUTPUT"
expect_untouched "sha256 の不一致"

repack brokensha "$NEW"
echo "これは sha256 ではない" > "$FEED/brokensha/Makurip-$NEW.zip.sha256"
write_feed "$FEED/brokensha.json" "$NEW" "$FEED/brokensha/Makurip-$NEW.zip" "$FEED/brokensha/Makurip-$NEW.zip.sha256"
APPLY "$FEED/brokensha.json"
check "sha256 の行が壊れている: 終了コード 2" "2" "$CODE"
check "sha256 の行が壊れている: 理由" "*sha256 のファイルの形が違う*" "$OUTPUT"
expect_untouched "sha256 の行が壊れている"

repack tampered "$NEW" tamper
write_feed "$FEED/tampered.json" "$NEW" "$FEED/tampered/Makurip-$NEW.zip" "$FEED/tampered/Makurip-$NEW.zip.sha256"
APPLY "$FEED/tampered.json"
check "zip の中身の改ざん（sha256 は合わせ直した）: 終了コード 2" "2" "$CODE"
check "zip の中身の改ざん: 理由" "*書き換えられている*" "$OUTPUT"
expect_untouched "zip の中身の改ざん"

repack adhoc "$NEW" adhoc
write_feed "$FEED/adhoc.json" "$NEW" "$FEED/adhoc/Makurip-$NEW.zip" "$FEED/adhoc/Makurip-$NEW.zip.sha256"
APPLY "$FEED/adhoc.json"
check "別の署名（アドホック・チーム ID なし）: 終了コード 2" "2" "$CODE"
check "別の署名: 理由" "*チームが今の Makurip と違う*" "$OUTPUT"
expect_untouched "別の署名（アドホック）"

if [ "$UNNOTARIZED" != "1" ]; then
    # 同じチームの開発用の証明書（Apple Development）で署名した新しい版。要件が違い、公証もない
    DEV="$FEED/dev"
    mkdir -p "$DEV"
    DEV_BUILT="$(MAKURIP_VERSION_OVERRIDE="$NEW" "$ROOT/scripts/build-app.sh" 2> /dev/null | tail -n 1)"
    ditto -c -k --keepParent "$DEV_BUILT" "$DEV/Makurip-$NEW.zip"
    (cd "$DEV" && shasum -a 256 "Makurip-$NEW.zip" > "Makurip-$NEW.zip.sha256")
    write_feed "$FEED/dev.json" "$NEW" "$DEV/Makurip-$NEW.zip" "$DEV/Makurip-$NEW.zip.sha256"
    APPLY "$FEED/dev.json"
    check "開発用の署名の新しい版: 終了コード 2" "2" "$CODE"
    check "開発用の署名の新しい版: 理由（要件か公証）" "*入れ替えませんでした*" "$OUTPUT"
    expect_untouched "開発用の署名"
fi

# tag と中の .app の版が違う（0.0.3 として出した 0.0.2）
repack mislabeled "0.0.3"
write_feed "$FEED/mislabeled.json" "0.0.3" "$FEED/mislabeled/Makurip-0.0.3.zip" "$FEED/mislabeled/Makurip-0.0.3.zip.sha256"
APPLY "$FEED/mislabeled.json"
check "中の版が Release の版と違う: 終了コード 2" "2" "$CODE"
check "中の版が Release の版と違う: 理由" "*Release の版*" "$OUTPUT"
expect_untouched "中の版の違い"

echo "== 2. 隔離していないときは配信元を差し替えない（本物の家のフォルダの代わりに作業場所を家にして試す）"
FAKE_HOME="$RUN/home"
mkdir -p "$FAKE_HOME"
write_feed "$FEED/ok.json" "$NEW" "$RUN/new/Makurip-$NEW.zip" "$RUN/new/Makurip-$NEW.zip.sha256"
set +e
OUTPUT="$(CFFIXED_USER_HOME="$FAKE_HOME" "$EXE" --update-feed "file://$FEED/ok.json" "${EXTRA[@]}" --update apply 2>&1)"
CODE=$?
set -e
check "--data-dir なしの --update-feed: apply は止める（終了コード 1）" "1" "$CODE"
check "--data-dir なしの --update-feed: 理由" "*--data-dir と一緒のときだけ*" "$OUTPUT"
check "--data-dir なしの --update-feed: 何も書かない" "0" "$(find "$FAKE_HOME" -type f | wc -l | tr -d ' ')"
expect_untouched "--data-dir なし"

echo "== 3. アプリの中で失敗したら、今の版のまま動き続けて理由を出す（sha256 の不一致）"
launch_instance --update-feed "file://$FEED/badsha.json" "${EXTRA[@]}"
PID_BEFORE="$(status_value '.pid')"
notify checkForUpdates
sleep 1.5
check "確かめた: 新しい版がある" "available" "$(status_value '.update.availability')"
notify installUpdate
for _ in $(seq 1 40); do
    [ "$(status_value '.update.phase')" = "failed" ] && break
    sleep 0.5
done
check "入れ替えに失敗した" "failed" "$(status_value '.update.phase')"
check "失敗の理由（sha256）" "*sha256*" "$(status_value '.update.lastError')"
check "同じプロセスのまま動いている" "$PID_BEFORE" "$(status_value '.pid')"
expect_untouched "アプリの中での失敗"
quit_instance
rm -f "$DATA/update-state.json"

echo "== 4. 起動したときの自動の確認 →「この版は知らせない」→ 入れ替えて起動し直す（メニューの操作と同じ道）"
launch_instance --update-feed "file://$FEED/ok.json" "${EXTRA[@]}"
PID_BEFORE="$(status_value '.pid')"
check "自動の確認がオン・1 日 1 回の時計がある" "true true" "$(status_value '"\(.update.autoCheck) \(.update.timerActive)"')"
for _ in $(seq 1 30); do
    [ -n "$(status_value '.update.lastCheckedAt')" ] && break
    sleep 0.5
done
check "起動の少し後に自動で確かめた" "available" "$(status_value '.update.availability')"
check "見つけた版" "$NEW" "$(status_value '.update.latestVersion')"
notify skipUpdate
check "「この版は知らせない」" "skipped $NEW" "$(status_value '"\(.update.availability) \(.update.skippedVersion)"')"
notify checkForUpdates
sleep 1.5
check "もう一度確かめても知らせない" "skipped" "$(status_value '.update.availability')"
DR_BEFORE="$(dr_of "$APP")"
notify installUpdate
PID_AFTER=""
for _ in $(seq 1 120); do
    sleep 0.5
    [ -f "$DATA/debug-status.json" ] || continue
    PID_NOW="$(jq -r '.pid' "$DATA/debug-status.json" 2> /dev/null || echo "")"
    if [ -n "$PID_NOW" ] && [ "$PID_NOW" != "$PID_BEFORE" ] && kill -0 "$PID_NOW" 2> /dev/null; then
        PID_AFTER="$PID_NOW"
        break
    fi
done
check "起動し直した（別のプロセス）" "yes" "$([ -n "$PID_AFTER" ] && echo yes || echo no)"
check "古いプロセスは終わった" "yes" "$(kill -0 "$PID_BEFORE" 2> /dev/null && echo no || echo yes)"
check "動いている版" "$NEW" "$(status_value '.update.currentVersion')"
check "ディスクの版" "$NEW" "$(version_of "$APP")"
check "入れ替えの前後で designated requirement が同じ" "yes" "$([ "$(dr_of "$APP")" = "$DR_BEFORE" ] && echo yes || echo no)"
check "起動し直した後は最新" "upToDate" "$(status_value '.update.availability')"
check "置き場所に残りがない" "Makurip.app" "$(ls "$RUN/Applications" | tr '\n' ' ' | sed 's/ $//')"
check "入れ替えた .app の署名" "ok" "$(codesign --verify --strict --deep "$APP" 2> /dev/null && echo ok || echo ng)"
if [ "$UNNOTARIZED" != "1" ]; then
    check "入れ替えた .app も公証済み（spctl）" "*source=Notarized Developer ID*" "$(spctl -a -vv -t exec "$APP" 2>&1 | tr '\n' ' ')"
fi
quit_instance

echo "== 5. 自動の確認をオフ → CLI の apply で入れ替え、動いている Makurip が起動し直す"
install_old
rm -f "$DATA/update-state.json"
"$EXE" --data-dir "$DATA" --settings set autoUpdateCheck false > /dev/null
launch_instance --update-feed "file://$FEED/ok.json" "${EXTRA[@]}"
PID_BEFORE="$(status_value '.pid')"
sleep 7
check "オフなら起動しても確かめない・時計もない" "false false" "$(status_value '"\(.update.autoCheck) \(.update.timerActive)"')"
check "確かめた時刻がない" "" "$(status_value '.update.lastCheckedAt')"
set +e
OUTPUT="$("$EXE" --data-dir "$DATA" --update-feed "file://$FEED/ok.json" "${EXTRA[@]}" --update apply --json 2> /dev/null)"
CODE=$?
set -e
check "CLI の apply: 終了コード 0" "0" "$CODE"
check "CLI の apply: 入れ替えて起動し直しを頼んだ" "installed $NEW true" "$(jq -r '"\(.result) \(.version) \(.relaunching)"' <<< "$OUTPUT")"
PID_AFTER=""
for _ in $(seq 1 120); do
    sleep 0.5
    PID_NOW="$(jq -r '.pid' "$DATA/debug-status.json" 2> /dev/null || echo "")"
    if [ -n "$PID_NOW" ] && [ "$PID_NOW" != "$PID_BEFORE" ] && kill -0 "$PID_NOW" 2> /dev/null; then
        PID_AFTER="$PID_NOW"
        break
    fi
done
check "動いていた Makurip が起動し直した" "yes" "$([ -n "$PID_AFTER" ] && echo yes || echo no)"
check "起動し直した版" "$NEW" "$(status_value '.update.currentVersion')"
check "CLI の status" "*Makurip $NEW*" "$("$EXE" --data-dir "$DATA" --update status 2>&1)"
quit_instance

echo
echo "結果: OK $PASS / NG $FAIL"
[ "$FAIL" -eq 0 ]

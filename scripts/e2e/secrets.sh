#!/bin/bash
# tako:run scripts/e2e/secrets.sh
#
# 秘密の判定・マスク・自動消去の隔離 E2E（#5 の受け入れ条件 2 とエッジケース）。
# 隔離したインスタンスに偽物のキーを数種類コピーさせ、--dump-metadata で印（secretLikely・secretKnownFormat）が付くこと、
# 時間が来ると消えること（ピン留めとランダムな文字列は残ること）、既存の履歴に当て直すことを確かめる。
#
# 安全の約束（lib.sh に加えて）:
# - 偽物の値は MakuripDevTool が実行のたびに乱数で作る（実在しない）。中身は出力しない（出すのは種類・印・件数だけ）
# - 一般ペーストボードには触らない（private ペーストボードを監視させる）。窓は出さない
# - 起動する前に、呼び出しキーを使われていない組み合わせ（⌃⌥⇧⌘F11・F10）にしておく（ほかのアプリのキーを奪わない）
# - 1 分で消す設定にするので、全体で 2〜3 分かかる
#
#   MAKURIP_APP=.app-build/Makurip.app scripts/e2e/secrets.sh   # make app で作った .app で試す
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

build_devtool
new_run_dir secrets
PB="com.takushio2525.makurip.e2e.$(uuidgen)"
trap 'finish_run; "$DEVTOOL" pb-release "$PB" > /dev/null 2>&1 || true' EXIT
DB="$DATA/history.sqlite"

SET() {
    "$EXE" --data-dir "$DATA" --settings "$@"
}

write() {
    "$DEVTOOL" pb-write --pasteboard "$PB" --file-dir "$FILES" "$1" > /dev/null
    sleep "${2:-0.8}"
}

# 書いたら先頭がその種類・印になる（印は名前の順に「,」でつなぐ）
expect_flags() {
    local fixture="$1" kind="$2" flags="$3"
    write "$fixture"
    check "$fixture → 種類" "$kind" "$(top_field kind)"
    check "$fixture → 印" "$flags" "$(dump | jq -r '.items[0].flags | sort | join(",")')"
}

# 中身の文字を出さずに数だけ数える（隔離した DB を読むだけ）
sql_count() {
    sqlite3 "$DB" "$1"
}

HIGH="secretKnownFormat,secretLikely"

echo "== 起動前: 呼び出しキーを使われていない組み合わせに・秘密を 1 分で消す"
SET set keys.open ⌃⌥⇧⌘F11 > /dev/null
SET set keys.openList ⌃⌥⇧⌘F10 > /dev/null
SET set secretAutoDeleteMinutes 1 > /dev/null
check "CLI で時間を設定した" "1" "$(SET get secretAutoDeleteMinutes)"
check "0 は選べない（消さない設定はない）" "2" "$(SET set secretAutoDeleteMinutes 0 > /dev/null 2>&1; echo $?)"
check "「1時間」とも書ける" "60" "$(SET set secretAutoDeleteMinutes 1時間 > /dev/null; SET get secretAutoDeleteMinutes)"
SET set secretAutoDeleteMinutes 1 > /dev/null

echo "== 起動（隔離: data=.e2e/$(basename "$RUN")/data, private ペーストボード）"
launch_instance --pasteboard-name "$PB"
check "起動直後は 0 件" "0" "$(item_count)"
check "自動で消すまで 60 秒" "60" "$(status_value '.secrets.retentionSeconds')"
check "判定の版を覚えた（空の履歴に当て直し済み）" "1" "$(sql_count "SELECT value FROM meta WHERE key='secretScanVersion'")"

echo "== 既知の形式（確度「高」）"
expect_flags secret-github text "$HIGH"
expect_flags secret-openai text "$HIGH"
expect_flags secret-aws text "$HIGH"
expect_flags secret-env "*" "$HIGH"
expect_flags secret-pem "*" "$HIGH"
PIN_ID="$(top_field id)"
expect_flags secret-rtf richText "$HIGH"
expect_flags secret-file file "$HIGH"
expect_flags secret-image-url image "$HIGH"
START=$(date +%s)
expect_flags secret-long text "$HIGH"
echo "    $(top_summary)"
check "secret-long → 取り込みに時間がかからない（3 秒以内）" "yes" "$([ $(($(date +%s) - START)) -le 3 ] && echo yes || echo no)"

echo "== 確度「中」（ランダムな文字列）と、秘密でないもの"
expect_flags secret-random text "secretLikely"
expect_flags not-secret text ""
expect_flags text text ""
expect_flags url url ""

echo "== マスク（一覧用の平文は伏せ字。中身は出さずに数で確かめる）"
check "秘密で平文のあるものは、すべて伏せ字（•）を含む" "0" \
    "$(sql_count "SELECT COUNT(*) FROM clip WHERE instr(flags,'secretLikely')>0 AND preview_text IS NOT NULL AND instr(preview_text,'•')=0")"
check "秘密でないものは伏せ字にしない" "0" \
    "$(sql_count "SELECT COUNT(*) FROM clip WHERE instr(flags,'secretLikely')=0 AND instr(IFNULL(preview_text,''),'•')>0")"
check "--dump-metadata に値が出ない" "0" "$(dump | grep -cE 'ghp_|sk-test-|sk-proj-|PRIVATE KEY|AKIA|token=' || true)"
check "--dump-metadata に内容のハッシュがない（#23）" "0" "$(dump | jq '[.. | objects | keys[] | select(test("hash"; "i"))] | length')"
check "--dump-metadata は秘密の項目の大きさを伏せる（#23）" "0" \
    "$(dump | jq '[.items[] | select(.flags | index("secretLikely")) | select(.totalBytes != null or .size != "hidden" or ([.pasteboardItems[][].bytes] | any(. != null)))] | length')"
check "秘密でない項目は大きさを出す" "0" "$(dump | jq '[.items[] | select((.flags | index("secretLikely")) | not) | select(.totalBytes == null)] | length')"
check "状態の書き出しに値が出ない" "0" \
    "$(status_value '.' > /dev/null; grep -cE 'ghp_|sk-test-|sk-proj-|PRIVATE KEY|AKIA|token=' "$DATA/debug-status.json" || true)"

echo "== ピン留めした秘密（秘密鍵）は消さない"
sql_count "UPDATE clip SET pinned=1 WHERE id='$PIN_ID'" > /dev/null
check "秘密の件数（ランダム 1 件を含む）" "10" "$(status_value '.secrets.count')"
check "自動で消す対象の件数" "9" "$(status_value '.secrets.knownFormat')"
check "次に消す時刻を決めた" "20*" "$(status_value '.secrets.nextSweepAt')"
TOTAL_BEFORE="$(item_count)"

echo "== 1 分待つ（最後に使ってから 60 秒で消える）"
for _ in $(seq 1 30); do
    [ "$(status_value '.secrets.knownFormat')" = "1" ] && break
    sleep 5
done
check "確度「高」はピン留め以外すべて消えた" "1" "$(status_value '.secrets.knownFormat')"
check "自動で消した件数" "8" "$(status_value '.secrets.autoDeleted')"
check "ピン留めした秘密は残る" "$HIGH" "$(dump | jq -r --arg id "$PIN_ID" '.items[] | select(.id == $id) | .flags | sort | join(",")')"
check "ランダムな文字列（確度「中」）は消さない" "1" \
    "$(dump | jq '[.items[] | select((.flags | index("secretLikely")) and ((.flags | index("secretKnownFormat")) | not))] | length')"
check "秘密でないものは消さない" "$((TOTAL_BEFORE - 8))" "$(item_count)"
check "消したあと WAL を空にした" "0" "$(stat -f %z "$DB-wal" 2> /dev/null || echo 0)"

echo "== 既存の履歴への当て直し（判定を入れる前の版で保存した形に戻して、起動し直す）"
quit_instance
sql_count "UPDATE clip SET flags='[]', preview_text=NULL WHERE id='$PIN_ID'; DELETE FROM meta;" > /dev/null
check "印を外した" "" "$(dump | jq -r --arg id "$PIN_ID" '.items[] | select(.id == $id) | .flags | join(",")')"
launch_instance --pasteboard-name "$PB"
for _ in $(seq 1 20); do
    [ "$(sql_count "SELECT COUNT(*) FROM meta WHERE key='secretScanVersion'")" = "1" ] && break
    sleep 0.5
done
check "起動したら印を当て直した" "$HIGH" "$(dump | jq -r --arg id "$PIN_ID" '.items[] | select(.id == $id) | .flags | sort | join(",")')"
check "平文も伏せ字で入れ直した" "1" "$(sql_count "SELECT instr(preview_text,'•')>0 FROM clip WHERE id='$PIN_ID'")"
check "ピン留めはそのまま（消さない）" "1" "$(sql_count "SELECT pinned FROM clip WHERE id='$PIN_ID'")"

echo
echo "結果: OK $PASS / NG $FAIL"
[ "$FAIL" -eq 0 ]

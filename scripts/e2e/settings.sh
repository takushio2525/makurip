#!/bin/bash
# tako:run scripts/e2e/settings.sh
#
# 設定の隔離 E2E（#4 の受け入れ条件 2 とエッジケース）。隔離したインスタンスを動かしたまま CLI で設定を変え、
# アプリ側にすぐ効いたことを、中身を出さない方法（状態の書き出し・--dump-metadata）で確かめる。
#
# 安全の約束（lib.sh に加えて）:
# - 窓を出さない。⌃⌘V は押さず、押したら何をするかを状態の書き出し（openKeyRoute）で見る
# - 起動する前に、呼び出しキーを使われていない組み合わせ（⌃⌥⇧⌘F11・F10）にしておく（ほかのアプリのキーを奪わない）
# - 一般ペーストボードには触らない（private ペーストボードを監視させる）
#
#   MAKURIP_APP=.app-build/Makurip.app scripts/e2e/settings.sh   # make app で作った .app で試す
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

build_devtool
new_run_dir settings
PB="com.takushio2525.makurip.e2e.$(uuidgen)"
trap 'finish_run; "$DEVTOOL" pb-release "$PB" > /dev/null 2>&1 || true' EXIT

SET() {
    "$EXE" --data-dir "$DATA" --settings "$@"
}

# CLI で変えたあと、アプリが読み直すのを待ってから状態を読む
settled_status() {
    sleep 0.6
    status_value "$1"
}

echo "== 起動前: 呼び出しキーを使われていない組み合わせにする（CLI はアプリが動いていなくても使える）"
SET set keys.open ⌃⌥⇧⌘F11 > /dev/null
SET set keys.openList ⌃⌥⇧⌘F10 > /dev/null
check "設定ファイルができた" "yes" "$([ -f "$DATA/settings.json" ] && echo yes || echo no)"

echo "== 起動（隔離: data=.e2e/$(basename "$RUN")/data, private ペーストボード）"
launch_instance --pasteboard-name "$PB"
check "起動時に設定ファイルの呼び出しキーを登録した" "⌃⌥⇧⌘F10,⌃⌥⇧⌘F11" "$(status_value '.hotKeys|join(",")')"
check "設定ファイルを見張っている" "true" "$(status_value '.settings.watching')"
check "既定の動き: 押したら候補窓" "startCandidate" "$(status_value '.openKeyRoute')"

echo "== 1. ⌃⌘V の動き（hotkeyMode）"
SET set hotkeyMode paste
check "候補窓の設定（押したときに読む値）が paste に変わった" "paste" "$(settled_status '.candidateHotKeyMode')"
check "押したら「すぐ貼るだけ」になる" "pasteLatest" "$(status_value '.openKeyRoute')"
SET set hotkeyMode list > /dev/null
check "list にすると押したら一覧を開く" "openList" "$(settled_status '.openKeyRoute')"

echo "== 2. 呼び出しのキー（keys.open）"
SET set keys.open ⌃⌥⇧⌘F12
check "Carbon のホットキーを付け替えた（F11 は外れた）" "⌃⌥⇧⌘F10,⌃⌥⇧⌘F12" "$(settled_status '.hotKeys|join(",")')"

echo "== 3. 件数の上限（maxItems）"
for _ in $(seq 1 15); do
    "$DEVTOOL" pb-write --pasteboard "$PB" text > /dev/null
    sleep 0.4
done
sleep 0.5
check "15 件を取り込んだ" "15" "$(item_count)"
SET set maxItems 10
sleep 0.6
check "上限を下げたらその場で古い 5 件を消した（--dump-metadata）" "10" "$(item_count)"
check "ストアの上限が 10 になった" "10" "$(status_value '.storeLimits.maxItems')"
"$DEVTOOL" pb-write --pasteboard "$PB" text > /dev/null
sleep 0.8
check "新しく取り込んでも 10 件のまま" "10" "$(item_count)"
check "読み直した回数（CLI の 4 回）" "4" "$(status_value '.settings.reloadCount')"

echo "== エッジケース"
code=0
SET set keys.open V 2> "$RUN/err.txt" || code=$?
check "修飾キーなしの呼び出しキーは拒否（終了コード 2）" "2" "$code"
echo "    理由: $(cat "$RUN/err.txt")"
code=0
SET set keys.method ⌘E 2> "$RUN/err.txt" || code=$?
check "他の操作と重なるキーは拒否（終了コード 2）" "2" "$code"
echo "    理由: $(cat "$RUN/err.txt")"
SET set keys.openList none > /dev/null
check "空にしたキーは登録を外す" "⌃⌥⇧⌘F12" "$(settled_status '.hotKeys|join(",")')"
SET set maxItems 1 2> /dev/null || true
check "範囲外の件数は拒否してファイルを変えない" "10" "$(SET get maxItems)"
SET add excludedApps com.example.does-not-exist 2> "$RUN/err.txt"
check "存在しないアプリは注意を出して入れる" "*見つからない*" "$(cat "$RUN/err.txt")"
check "記録しないアプリがアプリに届いた" '*"com.example.does-not-exist"*' "$(settled_status '.settings.excludedApps')"

echo "== 動いている最中に設定ファイルの値を壊す（手で書き換えた）"
cp "$DATA/settings.json" "$RUN/settings-good.json"
jq '.settings.maxItems = -5' "$RUN/settings-good.json" > "$DATA/settings.json"
check "使えない値は既定に戻し（1 件の理由）、ほかの項目は使い続ける" "1" "$(settled_status '.settings.issueCount')"
check "件数の上限は既定の 1000 に戻った" "1000" "$(status_value '.storeLimits.maxItems')"
check "呼び出しキーはそのまま" "⌃⌥⇧⌘F12" "$(status_value '.hotKeys|join(",")')"
check "落ちていない" "yes" "$([ -n "$(instance_pids)" ] && echo yes || echo no)"

echo "== JSON として読めないファイルで起動する（最後に行う: 既定の ⌃⌘V を数秒だけ登録する）"
quit_instance
printf '{ "settings": { "maxItems": ' > "$DATA/settings.json"
launch_instance --pasteboard-name "$PB"
check "壊れたファイルでも起動する" "yes" "$([ -n "$(instance_pids)" ] && echo yes || echo no)"
check "読めない理由を 1 つ持つ" "1" "$(status_value '.settings.issueCount')"
check "すべて既定の値で動く" "1000/candidate" "$(status_value '"\(.storeLimits.maxItems)/\(.candidateHotKeyMode)"')"
quit_instance
SET list > "$RUN/list.txt" || true
check "list に読めない理由を出す" "*JSON として読めない*" "$(cat "$RUN/list.txt")"
SET set hotkeyMode paste > /dev/null
check "CLI で書くと壊れたファイルを退避してから書き直す" "yes" "$([ -f "$DATA/settings.broken.json" ] && echo yes || echo no)"
check "書き直したファイルは読める" "paste" "$(SET get hotkeyMode)"

echo
echo "結果: OK=$PASS NG=$FAIL"
[ "$FAIL" -eq 0 ]

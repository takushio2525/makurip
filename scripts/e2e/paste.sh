#!/bin/bash
# tako:run scripts/e2e/paste.sh
#
# 一覧・貼り付けの E2E（受け入れ条件 5・6・7）。
#
# 前提: 画面ロックが解除されている・~/Applications/Makurip.app にアクセシビリティの許可がある・
#       本番の Makurip が動いていない。満たさなければ何も触らずに「未検証」で終わる（終了コード 3 / 4）。
#
# 安全の約束:
# - 一般ペーストボードは触る前に名前付きペーストボードへ退避し（ディスクには書かない）、最後に戻して digest を比べる
# - キーは pid 宛て（postToPid）だけ。前面のアプリには送らない。送る前に毎回画面ロックを確かめる
# - 貼り付け先は専用に起動した TextEdit（open -n の別インスタンス）の書類。ユーザーの書類には届かない
# - 一覧と TextEdit の窓は仮想ディスプレイ（既定 tako-vd）に出す。スクショはその窓だけを撮る（screencapture -l）
#
#   SHOTS=dir scripts/e2e/paste.sh   # スクショの置き場（既定は .e2e/ の下で、終わったら消える）
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

VD_NAME="${MAKURIP_VD_NAME:-tako-vd}"
VD_SCRIPT="${TAKO_VD_SCRIPT:-$HOME/dev/tako/scripts/lib/virtual-display.sh}"

locked() { ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; }
guard_unlocked() {
    if locked; then
        echo "画面がロックされたので中止（キーを送らない）"
        exit 3
    fi
}

# ---- 前提の確認（ここまでは何も触らない）
if locked; then
    echo "未検証: 画面がロックされている（スクショは黒くなり、キーはロック画面に届いてしまう）"
    exit 3
fi
if pgrep -f "Makurip.app/Contents/MacOS/Makurip$" > /dev/null; then
    echo "中止: 本番の Makurip が動いている（テストデータが本物の履歴に入る）。終了してから実行する"
    exit 3
fi

build_devtool
new_run_dir paste
SHOTS="${SHOTS:-$RUN/shots}"
mkdir -p "$SHOTS"
STASH="com.takushio2525.makurip.e2e.stash.$(uuidgen)"
TOKEN="probe$(uuidgen | cut -c1-8 | tr 'A-Z' 'a-z')"
USER_FRONT_PID="$("$DEVTOOL" frontmost | sed -E 's/.*pid=//')"
STASHED=0
DIGEST_BEFORE=""
TE_PID=""

cleanup() {
    set +e
    quit_instance
    if [ -n "$TE_PID" ]; then kill -TERM "$TE_PID" 2> /dev/null; fi
    if [ "$STASHED" = 1 ]; then
        local after
        after="$("$DEVTOOL" pb-unstash --from "$STASH" | sed -E 's/.*digest=//')"
        check "一般ペーストボードを元に戻した（digest が退避前と同じ）" "$DIGEST_BEFORE" "$after"
    fi
    if [ -n "$USER_FRONT_PID" ] && [ "$USER_FRONT_PID" != "0" ]; then
        "$DEVTOOL" activate --pid "$USER_FRONT_PID" > /dev/null 2>&1
    fi
    finish_run
    echo
    echo "結果: OK=$PASS NG=$FAIL"
}
trap cleanup EXIT

# 仮想ディスプレイの左上（窓を置く場所）
VD_X=0
VD_Y=0
if [ -x "$VD_SCRIPT" ]; then
    "$VD_SCRIPT" ensure > /dev/null 2>&1 || true
    read -r VD_X VD_Y _ _ <<< "$("$VD_SCRIPT" bounds 2> /dev/null || echo "0 0 0 0")"
fi

move_window_to_vd() {
    osascript -e "tell application \"System Events\" to set position of window 1 of (first process whose unix id is $1) to {$((VD_X + $2)), $((VD_Y + $3))}" > /dev/null
}

shot() {
    local pid="$1" name="$2" wid
    wid="$("$DEVTOOL" window-id --pid "$pid")"
    screencapture -x -o -l "$wid" "$SHOTS/$name"
    echo "    スクショ: $SHOTS/$name（$("$DEVTOOL" image-stats "$SHOTS/$name")）"
}

# 一般ペーストボードへテストデータを書き、取り込まれるのを待つ
gw() {
    "$DEVTOOL" pb-write --pasteboard general --file-dir "$FILES" --token "$TOKEN" "$1" > /dev/null
    sleep 0.9
}

echo "== 一般ペーストボードを退避（名前付きペーストボードへ。中身は出さない）"
DIGEST_BEFORE="$("$DEVTOOL" pb-stash --to "$STASH" | sed -E 's/.*digest=//')"
STASHED=1

echo "== 隔離したインスタンスを起動（一般ペーストボードを監視）"
launch_instance -MakuripPanelScreen "$VD_NAME"
MK_PID="$(status_value .pid)"
if [ "$(status_value .accessibilityTrusted)" != "true" ]; then
    echo "未検証: Makurip にアクセシビリティの許可がない（システム設定 > プライバシーとセキュリティ > アクセシビリティ）"
    exit 4
fi
check "⌃⌘V のホットキーが登録されている" "*⌃⌘V*" "$(status_value '.hotKeys|join(",")')"
check "⌘C のキー監視が効いている" "true" "$(status_value .keyMonitorActive)"

echo "== 履歴を作る"
for fixture in text image code command paste-probe; do
    gw "$fixture"
    if [ "$fixture" = paste-probe ]; then PROBE_ID="$(top_field id)"; fi
done
check "5 件取り込んだ" "5" "$(item_count)"

echo "== コピー方法（受け入れ条件 5）"
notify simulateCopyShortcut
sleep 0.05
gw url
check "⌘C の信号の直後に書いた → キー操作" "keyboard" "$(top_field copyMethod)"
gw rtf
check "信号なしで書いた → それ以外" "other" "$(top_field copyMethod)"

echo "== 貼り付け先の TextEdit（専用インスタンス・仮想ディスプレイ）"
printf '{\\rtf1\\ansi\\deff0 }' > "$RUN/paste-target.rtf"
EXISTING_TE="$(pgrep -x TextEdit | tr '\n' ' ' || true)"
open -n -g -a TextEdit "$RUN/paste-target.rtf" --args -ApplePersistenceIgnoreState YES
for _ in $(seq 1 50); do
    for pid in $(pgrep -x TextEdit || true); do
        case " $EXISTING_TE " in *" $pid "*) ;; *) TE_PID="$pid" ;; esac
    done
    if [ -n "$TE_PID" ] && "$DEVTOOL" window-id --pid "$TE_PID" > /dev/null 2>&1; then break; fi
    sleep 0.2
done
[ -n "$TE_PID" ] || {
    echo "TextEdit の窓が出なかった"
    exit 1
}
move_window_to_vd "$TE_PID" 700 80
notify setPasteTarget --pid "$TE_PID"

echo "== ⌃⌘V と同じ処理で一覧を開く（受け入れ条件 6）"
guard_unlocked
notify toggleHistory
sleep 1
check "一覧が開いた" "true" "$(status_value .historyVisible)"
check "一覧は新しい順に全件" "7" "$(status_value '.historyUI.rowCount')"
shot "$MK_PID" 1-history-open.png

echo "== 文字を打つと絞り込まれる"
guard_unlocked
"$DEVTOOL" post-keys --pid "$MK_PID" --text "$TOKEN" > /dev/null
sleep 0.8
check "絞り込みの語が入った" "$TOKEN" "$(status_value '.historyUI.query')"
check "目印の 1 件だけに絞り込まれた" "1" "$(status_value '.historyUI.rowCount')"
shot "$MK_PID" 2-history-filtered.png

echo "== Enter で貼り付け（受け入れ条件 6・7）"
COUNT_BEFORE="$(item_count)"
guard_unlocked
"$DEVTOOL" post-keys --pid "$MK_PID" --key return > /dev/null
sleep 1.5
check "一覧が閉じた" "false" "$(status_value .historyVisible)"
check "⌘V を送った" "pasted" "$(status_value .lastPasteOutcome)"
STORED_TYPES="$(dump | jq -r --arg id "$PROBE_ID" '.items[] | select(.id == $id) | .pasteboardItems[][].type' | sort | tr '\n' ' ')"
BOARD_TYPES="$("$DEVTOOL" pb-types --pasteboard general | awk '/^  \[/{print $2}' | sort | tr '\n' ' ')"
echo "    保存した型:           $STORED_TYPES"
echo "    ペーストボードの型:   $BOARD_TYPES"
check "保存したすべての型がペーストボードに戻った" "$STORED_TYPES" "$BOARD_TYPES"
check "貼っても件数は増えない（重複しない）" "$COUNT_BEFORE" "$(item_count)"
check "貼った項目が先頭へ" "$PROBE_ID" "$(top_field id)"
check "貼っただけではコピー回数は増えない" "1" "$(top_field copyCount)"

echo "== 貼り付け先の書類を保存して確かめる"
guard_unlocked
"$DEVTOOL" post-keys --pid "$TE_PID" --key cmd-s > /dev/null
sleep 1.2
shot "$TE_PID" 3-textedit-pasted.png
check "TextEdit の書類に貼り付いた（目印がある）" "yes" \
    "$(textutil -convert txt -stdout "$RUN/paste-target.rtf" | grep -q "$TOKEN" && echo yes || echo no)"

echo "== 限界の確認: 他のプロセスが pid 宛てに送った ⌘C は、キー操作として見えない"
guard_unlocked
"$DEVTOOL" post-keys --pid "$TE_PID" --key cmd-a > /dev/null
"$DEVTOOL" post-keys --pid "$TE_PID" --key cmd-c > /dev/null
sleep 1.5
check "TextEdit がコピーした → 取り込んだ（種類）" "richText" "$(top_field kind)"
echo "    コピー方法: $(top_field copyMethod)（postToPid のキーはグローバル監視に届かないので other になる。物理キーは手で確かめる）"

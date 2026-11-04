#!/bin/bash
# tako:run scripts/e2e/click.sh
#
# 一覧のカードのクリックと右クリックのメニューの隔離 E2E（#38）。隔離したインスタンスの一覧を仮想ディスプレイ（既定 tako-vd）に出し、
# 窓の中で作ったマウスの出来事（遠隔操作 clickCard・rightClickCard など）でカードを押す。結果は名前付きペーストボードへの書き戻し
# （自作のテストデータ）と状態（debug-status.json）で確かめる。
#
# 前提: 画面ロックが解除されている・仮想ディスプレイ（tako-vd）がある。満たさなければ何も触らずに「未検証」で終わる（終了コード 3）。
# ロック中は、キーをどこへも送らないので害は無いが、ディスプレイが眠って描画が止まり（スクロール・見えていないカードへ送るのが進まない）、
# 一覧がキーの焦点も取れない（前面がロック画面）ので、結果が当てにならない。
# 本番の Makurip が動いていてもよい（一般ペーストボードに触らないので、本物の履歴には入らない）。
#
# 安全の約束（lib.sh に加えて）:
# - 一般ペーストボードには触らない（private ペーストボードを監視させ、書き戻し先もそこ）。出すのは型の名前と自作の文字だけ（秘密の偽物の文字は出さない）
# - 本物のマウスは使わない（出来事は Makurip が自分の窓の中で作って自分の窓へ送る）。ほかのアプリへキーを送らない
# - 貼り付けの宛先は無い pid に固定する（⌘V はどこにも送らない。ユーザーの前面のアプリへは落ちない）
# - 一覧は仮想ディスプレイに出す（-MakuripPanelScreen。名前の画面が無ければ起動しない）。仮想ディスプレイは作らない・消さない（bounds を読むだけ）
# - 「コピー元のページを開く」（ブラウザが開く）と「定型文に登録…」「編集…」（窓がメイン画面に出る）は、項目が出ることだけ確かめて選ばない
# - 一覧はキーの焦点を取らない開き方にする（遠隔操作 panelKeyFocusOff）。使っている人の打鍵を横取りせず、外のクリックでも閉じない。
#   本来の開き方（キーの焦点を取る）は最後の 1 か所だけ（メニューを開いても一覧が閉じないこと）。外の操作で崩れたら 3 回まで試し直す
# - メニューを開いている間は遠隔操作が届かないので、右クリックの命令に「何秒後に何を選ぶか」を一緒に渡す（開いている間の状態は Makurip が 1 回書く）
# - 起動する前に、呼び出しキーを使われていない組み合わせ（⌃⌥⇧⌘F11・F10）にしておく
#
#   MAKURIP_APP=$PWD/.app-build/Makurip.app scripts/e2e/click.sh
#   SHOTS=dir MAKURIP_APP=… scripts/e2e/click.sh   # 右クリックのメニューを撮る（Makurip の窓の範囲だけ。仮想ディスプレイの外は撮らない）
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

VD_NAME="${MAKURIP_VD_NAME:-tako-vd}"
VD_SCRIPT="${TAKO_VD_SCRIPT:-$HOME/dev/tako/scripts/lib/virtual-display.sh}"

locked() { ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; }

# ---- 前提の確認（ここまでは何も触らない）
if locked; then
    echo "未検証: 画面がロックされている（ディスプレイが眠り、描画とキーの焦点を試せない）"
    exit 3
fi
VD_BOUNDS=""
if [ -x "$VD_SCRIPT" ]; then VD_BOUNDS="$("$VD_SCRIPT" bounds 2> /dev/null || true)"; fi
SCREEN_FOUND="$(osascript -l JavaScript -e "ObjC.import('AppKit'); function run(argv) { const s = \$.NSScreen.screens; for (let i = 0; i < s.count; i++) { if (s.objectAtIndex(i).localizedName.js === argv[0]) return 'found'; } return ''; }" "$VD_NAME" 2> /dev/null || true)"
if [ -z "$VD_BOUNDS" ] || [ "$SCREEN_FOUND" != "found" ]; then
    echo "未検証: 仮想ディスプレイ（${VD_NAME}）が見つからない（メイン画面に一覧を出さない）"
    exit 3
fi
read -r VD_X VD_Y VD_W VD_H <<< "$VD_BOUNDS"

build_devtool
new_run_dir click
PB="com.takushio2525.makurip.e2e.$(uuidgen)"
trap 'finish_run; "$DEVTOOL" pb-release "$PB" > /dev/null 2>&1 || true; echo; echo "結果: OK=$PASS NG=$FAIL"' EXIT
USER_FRONT="$("$DEVTOOL" frontmost)"
SNIPPETS="$DATA/snippets.json"
NOT_A_PID=999999 # macOS の pid は 99999 まで

SET() {
    "$EXE" --data-dir "$DATA" --settings "$@"
}

pw() {
    "$DEVTOOL" pb-write --pasteboard "$PB" --file-dir "$FILES" "$1" > /dev/null
    sleep 0.8
}

ui() {
    status_value ".historyUI.$1"
}

# 一覧での行の番号（1 始まり）。jq の条件に合う最初の項目（ダンプの並びは一覧と同じ新しい順）
row_where() {
    dump | jq "[.items[] | ($1)] | index(true) + 1"
}

# 名前付きペーストボードの型の名前を「,」でつないで（中身は出さない）
pb_types() {
    "$DEVTOOL" pb-types --pasteboard "$PB" | sed -nE 's/^ +\[[0-9]+\] ([^ ]+) [0-9]+B$/\1/p' | paste -sd, -
}

pb_text() {
    "$DEVTOOL" pb-text --pasteboard "$PB"
}

open_list() {
    notify toggleHistory
    sleep 0.6
}

close_list() {
    if [ "$(status_value .historyVisible)" = "true" ]; then
        notify toggleHistory
        sleep 0.4
    fi
}

# 右クリックしてメニューを出し、hold 秒後に操作 action を選ぶ（空なら何も選ばずに閉じる）。
# メニューを開いている間の状態（Makurip が hold の 6 割の時点で書く）を MENU に入れ、shot の名前があれば開いている間に撮る
right_click() {
    local row="$1" action="${2:-}" hold="${3:-1}" shot_name="${4:-}"
    local args=(rightClickCard --index "$row" --hold "$hold")
    [ -n "$action" ] && args+=(--action "$action")
    notify "${args[@]}"
    sleep "$(awk -v h="$hold" 'BEGIN { print h * 0.6 + 0.25 }')"
    MENU="$(cat "$DATA/debug-status.json")"
    [ -n "$shot_name" ] && shot "$shot_name"
    sleep "$(awk -v h="$hold" 'BEGIN { print h * 0.4 + 0.6 }')"
}

# 開いている間の状態の値（.historyUI.menuItems など）
menu_value() {
    jq -r "$1" <<< "$MENU"
}

# Makurip の窓（一覧とメニュー）を囲む範囲だけを撮る。仮想ディスプレイの外にはみ出す分は切る
shot() {
    [ -n "${SHOTS:-}" ] || return 0
    mkdir -p "$SHOTS"
    local region
    region="$(osascript -l JavaScript -e "ObjC.import('CoreGraphics'); function run(argv) { const pid = +argv[0]; const vx = +argv[1], vy = +argv[2], vw = +argv[3], vh = +argv[4]; const list = ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(\$.kCGWindowListOptionOnScreenOnly, 0)); let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (let i = 0; i < list.count; i++) { const w = list.objectAtIndex(i); if (w.objectForKey('kCGWindowOwnerPID').js !== pid) continue; const b = w.objectForKey('kCGWindowBounds'); const x = b.objectForKey('X').js, y = b.objectForKey('Y').js, ww = b.objectForKey('Width').js, h = b.objectForKey('Height').js; if (x + ww <= vx || x >= vx + vw || y + h <= vy || y >= vy + vh || ww < 50) continue; x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x + ww); y1 = Math.max(y1, y + h); } if (x0 === Infinity) return ''; x0 = Math.max(vx, x0 - 16); y0 = Math.max(vy, y0 - 16); x1 = Math.min(vx + vw, x1 + 16); y1 = Math.min(vy + vh, y1 + 16); return [x0, y0, x1 - x0, y1 - y0].map(Math.round).join(','); }" "$MK_PID" "$VD_X" "$VD_Y" "$VD_W" "$VD_H")"
    if [ -z "$region" ]; then
        echo "    スクショ: Makurip の窓が仮想ディスプレイに見つからない（撮らない）"
        return 0
    fi
    screencapture -x -R "$region" "$SHOTS/$1"
    echo "    スクショ: $SHOTS/$1（範囲 ${region}・$("$DEVTOOL" image-stats "$SHOTS/$1")）"
}

echo "== 起動前: 呼び出しキーを使われていない組み合わせにする"
SET set keys.open ⌃⌥⇧⌘F11 > /dev/null
SET set keys.openList ⌃⌥⇧⌘F10 > /dev/null

echo "== 起動（隔離: data=.e2e/$(basename "$RUN")/data, private ペーストボード, 一覧は ${VD_NAME}）"
launch_instance --pasteboard-name "$PB" -MakuripPanelScreen "$VD_NAME"
MK_PID="$(status_value .pid)"
notify setPasteTarget --pid "$NOT_A_PID"
check "貼り付けの宛先を無い pid に固定（⌘V はどこにも送らない）" "$NOT_A_PID" "$(status_value .pasteTargetOverride)"
notify panelKeyFocusOff
check "一覧はキーの焦点を取らない開き方（打鍵を横取りしない）" "false" "$(status_value .historyUI.takesKeyFocus)"

echo "== 履歴を作る（古い順に 秘密・ファイル・画像・ページ付きの文・リッチテキスト・コマンド・テキスト）"
for fixture in secret-github file image leak-page rtf command text; do pw "$fixture"; done
check "7 件取り込んだ" "7" "$(item_count)"

echo "== 1. 左クリックで貼る（↩ と同じ貼り方）"
open_list
check "一覧が開いた" "true" "$(status_value .historyVisible)"
check "一覧を出しても前面のアプリは変わらない" "$USER_FRONT" "$("$DEVTOOL" frontmost)"
ROW="$(row_where '.kind == "command"')"
notify clickCard --index "$ROW"
sleep 0.6
check "クリックで一覧が閉じた" "false" "$(status_value .historyVisible)"
check "貼り付けまで進んだ（宛先が無いので ⌘V は送らない）" "no[TP]*" "$(status_value .lastPasteOutcome)"
check "書き戻したのはプロンプトを外した文字（↩ と同じ）" "git log --oneline -n *" "$(pb_text)"
check "書き戻しは新しい履歴にしない" "7" "$(item_count)"
check "クリックした項目が先頭へ（使った順）" "command" "$(dump | jq -r '.items[0].kind')"

echo "== 2. 押したままカードの外で離すと貼らない"
open_list
ROW="$(row_where '.kind == "richText"')"
notify clickCardReleaseOutside --index "$ROW"
sleep 0.6
check "一覧は開いたまま" "true" "$(status_value .historyVisible)"
check "押したカードは選んだまま" "$((ROW - 1))" "$(ui selectedIndex)"
check "書き戻していない（ペーストボードはコマンドのまま）" "git log --oneline -n *" "$(pb_text)"

echo "== 3. スクロールでは貼らない"
check "見えているいちばん上は 1 行目" "1" "$(ui firstVisibleRow)"
notify scrollCards --index 1
sleep 0.6
check "スクロールした（いちばん上のカードが下がった）" "[2-9]" "$(ui firstVisibleRow)"
check "一覧は開いたまま" "true" "$(status_value .historyVisible)"
check "書き戻していない" "git log --oneline -n *" "$(pb_text)"
close_list

echo "== 4. 右クリックのメニュー（リッチテキスト）→ 文字だけで貼り付け"
open_list
ROW="$(row_where '.kind == "richText"')"
right_click "$ROW" pastePlain 1.6 menu-richtext.png
check "メニューが開いた" "true" "$(menu_value .historyUI.menuOpen)"
check "右クリックしたカードのメニュー" "$ROW" "$(menu_value .historyUI.menuLastRow)"
check "右クリックしたカードを選んだ" "$((ROW - 1))" "$(menu_value .historyUI.selectedIndex)"
check "メニューを開いても一覧は閉じない" "true" "$(menu_value .historyVisible)"
check "メニューを開いても前面のアプリは変わらない" "$USER_FRONT" "$("$DEVTOOL" frontmost)"
check "並びと右のキー（キーマップから）" \
    "paste=貼り付け(↩)|pastePlain=文字だけで貼り付け(⇧↩)|copyOnly=クリップボードにコピー(⌘↩)|-|pin=ピン留め(⌘P)|editSnippet=定型文に登録…(⇧⌘S)|look=プレビュー(⌘Y)|-|delete=履歴から削除(⌘⌫)" \
    "$(menu_value .historyUI.menuItems)"
check "選んだらメニューが閉じた" "false" "$(ui menuOpen)"
check "一覧が閉じた" "false" "$(status_value .historyVisible)"
check "貼り付けまで進んだ" "no[TP]*" "$(status_value .lastPasteOutcome)"
check "文字だけで書き戻した（RTF なし）" "public.utf8-plain-text" "$(pb_types)"
check "書き戻しは新しい履歴にしない" "7" "$(item_count)"

echo "== 5. 画像のメニュー（文字の操作とページは出ない）→ クリップボードにコピー"
open_list
ROW="$(row_where '.kind == "image"')"
right_click "$ROW" copyOnly 1.6 menu-image.png
check "画像のメニュー" \
    "paste=貼り付け(↩)|copyOnly=クリップボードにコピー(⌘↩)|-|pin=ピン留め(⌘P)|look=プレビュー(⌘Y)|-|delete=履歴から削除(⌘⌫)" \
    "$(menu_value .historyUI.menuItems)"
check "コピーだけ（⌘V は送らない）" "copied" "$(status_value .lastPasteOutcome)"
check "画像の型ごと書き戻した" "*public.png*" "$(pb_types)"
check "書き戻しは新しい履歴にしない" "7" "$(item_count)"
check "前面のアプリは変わらない" "$USER_FRONT" "$("$DEVTOOL" frontmost)"

echo "== 6. ファイルのメニュー（文字の操作は出ない）→ 何も選ばずに閉じる"
open_list
ROW="$(row_where '.kind == "file"')"
right_click "$ROW"
check "ファイルのメニュー" \
    "paste=貼り付け(↩)|copyOnly=クリップボードにコピー(⌘↩)|-|pin=ピン留め(⌘P)|look=プレビュー(⌘Y)|-|delete=履歴から削除(⌘⌫)" \
    "$(menu_value .historyUI.menuItems)"
check "メニューが閉じた" "false" "$(ui menuOpen)"
check "何も選ばずに閉じても一覧は開いたまま" "true" "$(status_value .historyVisible)"
check "何も貼っていない（直近はコピーのまま）" "copied" "$(status_value .lastPasteOutcome)"

echo "== 7. ページのある項目だけ「コピー元のページを開く」が出る（選ばない: ブラウザが開くため）"
ROW="$(row_where '.sourceURLHost != null')"
right_click "$ROW" "" 1.6 menu-page.png
check "ページのある文のメニュー" \
    "paste=貼り付け(↩)|pastePlain=文字だけで貼り付け(⇧↩)|copyOnly=クリップボードにコピー(⌘↩)|-|pin=ピン留め(⌘P)|editSnippet=定型文に登録…(⇧⌘S)|look=プレビュー(⌘Y)|source=コピー元のページを開く(⌘O)|-|delete=履歴から削除(⌘⌫)" \
    "$(menu_value .historyUI.menuItems)"

echo "== 8. ピン留め → もう一度開くと「ピン留めを外す」"
PLAIN='.kind == "text" and .sourceURLHost == null and (.flags | index("secretLikely") | not)'
ROW="$(row_where "$PLAIN")"
right_click "$ROW" pin
check "メニューのピン留めで一覧は閉じない" "true" "$(status_value .historyVisible)"
check "ピン留めした" "true" "$(dump | jq -r "[.items[] | select($PLAIN)][0].pinned")"
ROW="$(row_where "$PLAIN")"
right_click "$ROW" "" 1.6 menu-pinned.png
check "ピン留め済みのメニューは「ピン留めを外す」" "*|pin=ピン留めを外す(⌘P)|*" "$(menu_value .historyUI.menuItems)"

echo "== 9. プレビュー → もう一度開くと「プレビューを閉じる」"
right_click "$ROW" look
check "プレビューが開いた" "true" "$(ui previewOpen)"
right_click "$ROW" look
check "プレビュー中のメニューは「プレビューを閉じる」" "*|look=プレビューを閉じる(⌘Y)|*" "$(menu_value .historyUI.menuItems)"
check "プレビューが閉じた" "false" "$(ui previewOpen)"

echo "== 10. 秘密のメニュー（定型文に登録は出ない）→ クリップボードにコピー（印を付ける・新しい履歴にしない）"
ROW="$(row_where '.flags | index("secretLikely")')"
right_click "$ROW" copyOnly 1.6 menu-secret.png
check "秘密のメニュー（定型文に登録なし）" \
    "paste=貼り付け(↩)|pastePlain=文字だけで貼り付け(⇧↩)|copyOnly=クリップボードにコピー(⌘↩)|-|pin=ピン留め(⌘P)|look=プレビュー(⌘Y)|-|delete=履歴から削除(⌘⌫)" \
    "$(menu_value .historyUI.menuItems)"
check "右クリックしたのは秘密の項目" "true" "$(menu_value .historyUI.selectedSecret)"
check "コピーだけ" "copied" "$(status_value .lastPasteOutcome)"
check "ConcealedType の印を付けて書き戻した" "*org.nspasteboard.ConcealedType*" "$(pb_types)"
check "書き戻しは新しい履歴にしない" "7" "$(item_count)"

echo "== 11. キーを付け替えると、メニューの右のキーも変わる"
SET set keys.copyOnly ⌥⌘C > /dev/null
sleep 0.8
open_list
right_click 1
check "クリップボードにコピーのキーが ⌥⌘C" "*|copyOnly=クリップボードにコピー(⌥⌘C)|*" "$(menu_value .historyUI.menuItems)"
SET reset keys.copyOnly > /dev/null
sleep 0.8

echo "== 12. メニューの「履歴から削除」"
ROW="$(row_where '.kind == "file"')"
right_click "$ROW" delete
check "1 件減った" "6" "$(item_count)"
check "ファイルが消えた" "0" "$(dump | jq '[.items[] | select(.kind == "file")] | length')"
close_list

echo "== 13. 定型文の一覧（⌘S）: クリックで貼る・右クリックのメニュー"
jq -n '{formatVersion: 1, snippets: [{name: "E2E あいさつ", body: "Makurip E2E の定型文 1"}, {name: "E2E 返信", body: "Makurip E2E の定型文 2"}]}' > "$DATA/.snippets.tmp"
mv "$DATA/.snippets.tmp" "$SNIPPETS"
sleep 0.8
check "定型文 2 件" "2" "$(status_value '.snippets.count')"
notify openSnippetList
sleep 0.6
check "定型文の一覧が開いた" "true" "$(ui showsSnippets)"
notify clickCardReleaseOutside --index 1
sleep 0.5
check "外で離したら貼らない（一覧は開いたまま）" "true" "$(status_value .historyVisible)"
notify clickCard --index 1
sleep 0.6
check "クリックで一覧が閉じた" "false" "$(status_value .historyVisible)"
check "1 件目の定型文を書き戻した" "Makurip E2E の定型文 1" "$(pb_text)"
check "貼り付けまで進んだ" "no[TP]*" "$(status_value .lastPasteOutcome)"
notify openSnippetList
sleep 0.6
right_click 2 copyOnly 1.6 menu-snippet.png
check "定型文のメニュー" \
    "paste=貼り付け(↩)|copyOnly=クリップボードにコピー(⌘↩)|-|editSnippet=編集…(⇧⌘S)|look=プレビュー(⌘Y)" \
    "$(menu_value .historyUI.menuItems)"
check "2 件目の定型文をコピーした" "Makurip E2E の定型文 2" "$(pb_text)"
check "コピーだけ" "copied" "$(status_value .lastPasteOutcome)"
check "定型文の書き戻しは履歴にしない" "6" "$(item_count)"

close_list

echo "== 14. 本来の開き方（キーの焦点を取る）でも、メニューを開いて閉じても一覧は閉じず、キーの焦点も持ったまま"
# 一覧がキーの焦点を持つ間は、使っている人の打鍵が一覧へ入り、外のクリックで一覧が閉じる。開いている時間を短くし、崩れたら試し直す
notify panelKeyFocusOn
KEPT=""
for attempt in 1 2 3; do
    open_list
    right_click 1 "" 0.8
    AFTER="$(status_value '[.historyVisible, .historyUI.panelKey] | map(tostring) | join(",")')"
    DURING="$(menu_value '[.historyUI.menuOpen, (.historyVisible | tostring), .historyUI.panelKey] | join(",")')"
    close_list
    if [ "$DURING" = "true,true,true" ] && [ "$AFTER" = "true,true" ]; then
        KEPT="$attempt"
        break
    fi
    echo "    $attempt 回目は崩れた（開いている間 メニュー,一覧,キー=$DURING / 閉じた後 一覧,キー=${AFTER}）。外の操作の可能性があるので試し直す"
    sleep 1
done
check "メニューを開いている間も一覧はキーの焦点を持ったまま・閉じた後も開いたまま（試した回）" "[123]" "$KEPT"
notify panelKeyFocusOff

echo "== 後片付けの前に"
close_list
check "最後まで前面のアプリは変わらない" "$USER_FRONT" "$("$DEVTOOL" frontmost)"

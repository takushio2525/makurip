#!/bin/bash
# tako:run scripts/e2e/ai.sh
#
# AI の口（MCP・--ai の CLI）の隔離 E2E（#6 の受け入れ条件 2・3 とエッジケース）。
# 隔離したインスタンスの履歴に、一意な目印を文字・URL のクエリ・コピー元ページの URL・ファイル名・RTF・偽の秘密・コードに入れ、
# MCP の全道具を標準入出力の JSON-RPC で呼んで（initialize → tools/list → 各 tools/call）、すべての応答に目印が 0 件であることを確かめる。
# 中身を推せる値（偽の秘密の内容のハッシュ・長さ）も、どの出口（MCP・--ai・--dump-metadata・記録・状態）にも出ないことを確かめる（#23）。
# あわせて、動いているアプリに追加がすぐ届くこと・オフの拒否（設定を変える道具も。#26）・人のコピーと同じ文字を AI が足しても
# 合流しないこと（#24）・オンからオフに切り替えた直後・壊れた要求・巨大な追加・アプリが動いていないときの追加を確かめる。
#
# 安全の約束（lib.sh に加えて）:
# - 目印と偽の秘密は実行のたびに乱数で作る（実在しない）。出力するのは件数・印・道具の結果の形だけ（中身は出さない）
# - 偽の秘密のハッシュと長さ（推す側が作れる値）は DevTool の pb-guess で実行用のフォルダに控え、照らした件数だけを出す
# - 一般ペーストボードには触らない（private ペーストボードを監視させ、MCP にも同じものを使わせる）
# - 起動する前に、呼び出しキーを使われていない組み合わせ（⌃⌥⇧⌘F11・F10）にしておく（ほかのアプリのキーを奪わない）
# - AI の口をオンにするのは検証用の遠隔操作（--data-dir のときだけ効く）。本物の履歴の口は開けない
# - 一覧の窓を一瞬だけ開いて、追加がすぐ一覧に出るかを状態の書き出しで見る（開けなければ知らせの回数で見る）
#
#   MAKURIP_APP=$PWD/.app-build/Makurip.app scripts/e2e/ai.sh   # make app で作った .app で試す
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

build_devtool
new_run_dir ai
PB="com.takushio2525.makurip.e2e.$(uuidgen)"
trap 'finish_run; "$DEVTOOL" pb-release "$PB" > /dev/null 2>&1 || true' EXIT
MARK="MKLEAK$(uuidgen | tr -d - | cut -c1-10)"
RESP="$RUN/responses"
mkdir -p "$RESP"

SET() { "$EXE" --data-dir "$DATA" --settings "$@"; }
AI() { "$EXE" --data-dir "$DATA" --pasteboard-name "$PB" --ai "$@"; }

# JSON-RPC の要求を 1 行で作る
req() {
    local params="${3:-null}"
    jq -nc --argjson id "$1" --arg m "$2" --argjson p "$params" \
        '{jsonrpc: "2.0", id: $id, method: $m} + (if $p == null then {} else {params: $p} end)'
}
call() {
    local args="${3:-}"
    [ -n "$args" ] || args='{}'
    req "$1" tools/call "$(jq -nc --arg n "$2" --argjson a "$args" '{name: $n, arguments: $a}')"
}
init_req() {
    req "$1" initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-client","version":"1"}}'
}
initialized() { echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'; }

# 要求のファイルを MCP に流し、応答を responses/<名前>.jsonl に残す（応答の行数を返す）
mcp() {
    local name="$1" input="$2"
    "$EXE" --data-dir "$DATA" --pasteboard-name "$PB" --mcp < "$input" > "$RESP/$name.jsonl"
    wc -l < "$RESP/$name.jsonl" | tr -d ' '
}
# 応答の中の id の結果
res() { jq -c --argjson id "$2" 'select(.id == $id)' "$RESP/$1.jsonl"; }
is_error() { res "$1" "$2" | jq -r '.result.isError'; }
err_code() { res "$1" "$2" | jq -r '.error.code'; }
structured() { res "$1" "$2" | jq -r ".result.structuredContent$3"; }

write() {
    "$DEVTOOL" pb-write --pasteboard "$PB" --file-dir "$FILES" --token "$MARK" "$1" > /dev/null
    sleep "${2:-0.8}"
}

fake_github() { echo "gh""p_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"; }

# 漏れの検査（#23）: 偽の秘密のハッシュの先頭（推した値のものと、ペーストボードそのままのもの）が出た行の数。
# 出口 = MCP と --ai の応答・--dump-metadata・AI の操作の記録・状態の書き出し（値そのものは出さず、数だけ返す）
leak_hash_count() {
    cat "$RESP"/* "$DATA/ai-activity.jsonl" "$DATA/debug-status.json" 2> /dev/null \
        | grep -c -e "${GUESS_HASH:0:10}" -e "${BOARD_HASH:0:10}" || true
}
# 漏れの検査（#23）: 偽の秘密の項目（id で見る）の中に、平文のバイト数か文字数と同じ数が出た回数
leak_length_count() {
    cat "$RESP"/*.jsonl "$RESP"/*.json \
        | jq -s --arg id "$SECRET_ID" --argjson b "$SECRET_BYTES" --argjson c "$SECRET_CHARS" \
            '[.. | objects | select(.id == $id) | .. | numbers | select(. == $b or . == $c)] | length'
}

echo "== 起動前: 一度も起動していないデータフォルダはオフで、DB を作らない"
SET set keys.open ⌃⌥⇧⌘F11 > /dev/null
SET set keys.openList ⌃⌥⇧⌘F10 > /dev/null
check "CLI の status はオフ" "off" "$(AI status --json | jq -r '.aiAccess')"
check "Makurip は動いていない" "false" "$(AI status --json | jq -r '.appRunning')"
{ init_req 1; call 2 add_to_history '{"text":"before launch"}'; } > "$RUN/pre.in"
mcp pre "$RUN/pre.in" > /dev/null
check "起動前の MCP の追加は断る" "true" "$(is_error pre 2)"
check "断った理由はオフ" "aiAccessDisabled" "$(structured pre 2 .error)"
check "DB を作らない" "no" "$([ -f "$DATA/history.sqlite" ] && echo yes || echo no)"

echo "== 起動（隔離: data=.e2e/$(basename "$RUN")/data, private ペーストボード）"
launch_instance --pasteboard-name "$PB"
check "既定はオフ" "false" "$(status_value '.ai.enabled')"

echo "== 目印入りの履歴（文字・URL・コピー元ページ・ファイル名・RTF・偽の秘密・コード）"
for fixture in leak-text leak-url leak-page leak-file leak-rtf leak-secret leak-code; do
    write "$fixture"
    if [ "$fixture" = leak-secret ]; then
        # 推す側（AI）が手元で作れる値（ハッシュ・長さ）を控える。画面には出さず、照らした件数だけを出す
        "$DEVTOOL" pb-guess --pasteboard "$PB" > "$RUN/guess-values.json"
    fi
done
check "7 件取り込んだ" "7" "$(item_count)"
check "偽の秘密に印が付いた" "1" "$(dump | jq '[.items[] | select(.flags | index("secretKnownFormat"))] | length')"
SECRET_ID="$(dump | jq -r '.items[] | select(.flags | index("secretKnownFormat")) | .id')"
GUESS_HASH="$(jq -r '.guessHash' "$RUN/guess-values.json")"
BOARD_HASH="$(jq -r '.boardHash' "$RUN/guess-values.json")"
SECRET_BYTES="$(jq -r '.bytes' "$RUN/guess-values.json")"
SECRET_CHARS="$(jq -r '.characters' "$RUN/guess-values.json")"
check "推す側の値を控えた（値は出さない）" "yes" \
    "$([ ${#GUESS_HASH} -eq 64 ] && [ ${#BOARD_HASH} -eq 64 ] && [ "$SECRET_BYTES" -gt 1 ] && echo yes || echo no)"
# 秘密があるうちに、門の外の出口（--dump-metadata）を控える（漏れの検査で照らす）
dump > "$RESP/dump-metadata.json"

echo "== オフのとき: 履歴の道具と設定を変える道具は断り、設定を読む道具は使える"
{
    init_req 1
    initialized
    call 2 list_history
    call 3 add_to_history '{"text":"x"}'
    call 4 delete_secrets
    call 5 settings_get '{"id":"hotkeyMode"}'
    call 6 settings_set '{"id":"maxItems","value":10}'
    call 7 settings_reset '{"all":true}'
} > "$RUN/off.in"
mcp off "$RUN/off.in" > /dev/null
check "list_history は断る" "aiAccessDisabled" "$(structured off 2 .error)"
check "add_to_history は断る" "aiAccessDisabled" "$(structured off 3 .error)"
check "delete_secrets は断る" "aiAccessDisabled" "$(structured off 4 .error)"
check "断る文は設定画面でオンにするよう伝える" "*設定画面*" "$(res off 2 | jq -r '.result.content[0].text')"
check "settings_get は使える" "false" "$(is_error off 5)"
check "settings_set（上限を下げる）は断る（#26）" "aiAccessDisabled" "$(structured off 6 .error)"
check "settings_reset は断る（#26）" "aiAccessDisabled" "$(structured off 7 .error)"
sleep 0.5
check "設定ファイルの上限は変わっていない" "1000" "$(SET get maxItems)"
check "tools/list の注釈: 設定を変える道具は destructiveHint" "true,true" \
    "$({ init_req 1; req 2 tools/list; } > "$RUN/tools.in"; mcp tools "$RUN/tools.in" > /dev/null; res tools 2 | jq -r '[.result.tools[] | select(.name == "settings_set" or .name == "settings_reset") | .annotations.destructiveHint] | join(",")')"
check "CLI もオフなら終了コード 4" "4" "$(AI list > /dev/null 2>&1; echo $?)"
check "CLI からはオンにできない（終了コード 2）" "2" "$(AI enable > /dev/null 2>&1; echo $?)"
check "設定の CLI からもオンにできない" "2" "$(SET set aiAccess true > /dev/null 2>&1; echo $?)"
check "MCP の設定の道具からもオンにできない（オフなので門で断る）" "aiAccessDisabled" \
    "$({ init_req 1; call 2 settings_set '{"id":"aiAccess","value":true}'; } > "$RUN/gate.in"; mcp gate "$RUN/gate.in" > /dev/null; structured gate 2 .error)"
check "まだオフのまま" "false" "$(status_value '.ai.enabled')"
check "オフで断ったことを記録した（起動前 1・MCP 6・CLI 1）" "8" \
    "$(AI log --json | jq '[.[] | select(.outcome == "refused")] | length')"
check "設定を変える道具で断ったことも記録した" "refused" "$(status_value '.ai.lastOutcome')"

echo "== 設定画面と同じ切り替えでオンにする（検証用の遠隔操作。隔離したときだけ効く）"
notify enableAIAccess
check "オンになった" "true" "$(status_value '.ai.enabled')"
check "オンでも、設定の道具から口の項目は変えられない" "settingsRejected" \
    "$({ init_req 1; call 2 settings_set '{"id":"aiAccess","value":false}'; } > "$RUN/gate-on.in"; mcp gate-on "$RUN/gate-on.in" > /dev/null; structured gate-on 2 .error)"
check "拒否したことを記録した" "rejected" "$(status_value '.ai.lastOutcome')"
# 秘密があるうちに、--ai の CLI の一覧（JSON と人が読む形）も控える（漏れの検査で照らす）
AI list --limit 200 --json > "$RESP/cli-list.json"
AI list --limit 200 > "$RESP/cli-list.txt"

echo "== 設定画面の「登録コマンドをコピー」は、ほかの書き戻しと同じく新しい履歴にしない（#29 L7）"
COUNT_BEFORE_COPY="$(status_value '.itemCount')"
notify copyMCPRegisterCommand
sleep 1.5
# コマンドには実行ファイルとデータフォルダのパスが入るので、先頭の形だけを見る（出さない）
check "ペーストボードに登録コマンドが入った" "yes" \
    "$([[ "$("$DEVTOOL" pb-text --pasteboard "$PB")" == "claude mcp add "* ]] && echo yes || echo no)"
check "履歴の件数は変わらない" "$COUNT_BEFORE_COPY" "$(status_value '.itemCount')"

echo "== 一覧を開いて、追加がすぐ出るか見る"
notify toggleHistory
sleep 0.5
PANEL="$(status_value '.historyVisible')"
LOADED_BEFORE="$(status_value '.historyUI.loadedCount // "0"')"
CHANGES_BEFORE="$(status_value '.ai.externalHistoryChanges')"
echo "    一覧の窓: ${PANEL}（読み込んだ件数 ${LOADED_BEFORE}）"

echo "== MCP の全道具を呼ぶ（initialize → tools/list → 各 tools/call）"
{
    init_req 1
    initialized
    req 2 tools/list
    call 3 status
    call 4 list_history '{"limit":200}'
    call 5 list_history '{"secret":"any"}'
    call 6 list_history '{"kind":"file"}'
    call 7 add_to_history "$(jq -nc --arg t "echo $MARK" '{text: $t}')"
    call 8 delete_secrets '{"dryRun":true}'
    call 9 delete_history '{"kind":"url","dryRun":true}'
    call 10 add_snippet "$(jq -nc --arg t "定型文 $MARK" '{body: $t}')"
    call 11 list_snippets
    call 12 delete_snippets "$(jq -nc --arg id "$(uuidgen)" '{ids: [$id]}')"
    call 13 settings_schema
    call 14 settings_list
    call 15 settings_get '{"id":"hotkeyMode"}'
    call 16 settings_set '{"id":"candOrder","value":"ime"}'
    call 17 settings_reset '{"ids":["candOrder"]}'
    call 18 delete_secrets
    call 19 delete_history '{"kind":"richText"}'
    call 20 list_history
} > "$RUN/main.in"
check "応答の数（通知を除く 20 件）" "20" "$(mcp main "$RUN/main.in")"
check "道具はどれも成功した（誤りで素通りしていない）" "0" \
    "$(jq -s '[.[] | select(.result.isError == true or .error != null)] | length' "$RESP/main.jsonl")"
check "tools/list の道具の数" "13" "$(res main 2 | jq '.result.tools | length')"
check "追加したものは AI の印付きのコマンド" "command" "$(structured main 7 .kind)"
check "秘密の削除（dryRun）は件数だけ" "1" "$(structured main 8 .wouldDelete)"
check "秘密を消した件数" "1" "$(structured main 18 .deleted)"
check "リッチテキストを消した件数" "1" "$(structured main 19 .deleted)"
check "設定の set が通った" "ime" "$(structured main 16 '.value')"
check "最後の一覧（7 件 + 追加 1 − 消した 2）" "6" "$(structured main 20 .total)"

echo "== 漏れの検査: すべての応答に目印が 0 件"
check "MCP の応答に目印がない" "0" "$(cat "$RESP"/*.jsonl | grep -c "$MARK" || true)"
check "AI の操作の記録に目印がない" "0" "$(grep -c "$MARK" "$DATA/ai-activity.jsonl" || true)"
check "状態の書き出しに目印がない" "0" "$(status_value '.' > /dev/null; grep -c "$MARK" "$DATA/debug-status.json" || true)"
check "一覧にコピー元ページのホスト名だけが出る" "docs.example.org" \
    "$(structured main 4 '.items[] | select(.sourcePageHost) | .sourcePageHost')"
check "一覧に URL・ファイル名・ハッシュの鍵がない" "0" \
    "$(res main 4 | jq '.result.structuredContent | [.. | objects | keys[] | select(. == "url" or . == "sourceURL" or . == "path" or . == "fileName" or . == "contentHash" or . == "previewText" or . == "text")] | length')"
check "--dump-metadata にも目印がない" "0" "$(grep -c "$MARK" "$RESP/dump-metadata.json" || true)"
check "どの出口にも、偽の秘密のハッシュ（推した値と照らせるもの）が出ない（#23）" "0" "$(leak_hash_count)"
check "どの出口にも、偽の秘密の項目の長さが出ない（#23）" "0" "$(leak_length_count)"
check "秘密の項目は一覧・ダンプとも大きさを伏せる（見つかった数/伏せていない数）" "[1-9]*/0" \
    "$(jq -rs --arg id "$SECRET_ID" '[.. | objects | select(.id == $id)] | "\(length)/\([.[] | select(.size != "hidden")] | length)"' "$RESP/main.jsonl" "$RESP/cli-list.json" "$RESP/dump-metadata.json")"

echo "== 動いているアプリに、すぐ届いた"
check "外から変わった知らせを受けた" "yes" \
    "$([ "$(status_value '.ai.externalHistoryChanges')" -gt "$CHANGES_BEFORE" ] && echo yes || echo no)"
check "アプリの件数" "6" "$(status_value '.itemCount')"
if [ "$PANEL" = "true" ]; then
    check "開いている一覧が読み直した（件数が 6 になった）" "6" "$(status_value '.historyUI.loadedCount')"
else
    echo "    （一覧の窓が開けなかったので、知らせを受けた回数とアプリの件数で確かめた）"
fi
notify toggleHistory
check "AI が足したものの、コピー元は「AI（相手の名前）」" "AI（e2e-client）" "$(dump | jq -r '.items[0].sourceName')"

echo "== MCP の往復の記録（中身なし。足した文字は <テスト用の文字> に置き換え）"
TRANSCRIPT="$RUN/transcript.txt"
{
    for id in 1 2 7 4 18 16; do
        echo "--> $(jq -c --argjson id "$id" 'select(.id == $id) | if .params.arguments.text then .params.arguments.text = "<テスト用の文字>" else . end' "$RUN/main.in")"
        case "$id" in
            1) echo "<-- $(res main 1 | jq -c '{id, result: {protocolVersion: .result.protocolVersion, serverInfo: .result.serverInfo, capabilities: .result.capabilities}}')" ;;
            2) echo "<-- $(res main 2 | jq -c '{id, result: {tools: [.result.tools[].name]}}')" ;;
            4) echo "<-- $(res main 4 | jq -c '{id, isError: .result.isError, total: .result.structuredContent.total, items0: .result.structuredContent.items[0]}')" ;;
            *) echo "<-- $(res main "$id" | jq -c '{id, isError: .result.isError, structuredContent: .result.structuredContent}')" ;;
        esac
    done
} > "$TRANSCRIPT"
cut -c1-400 "$TRANSCRIPT" | sed 's/^/    /'
check "記録にも目印がない" "0" "$(grep -c "$MARK" "$TRANSCRIPT" || true)"

echo "== クリップボードにも置く（動いているアプリは取り込み直さない）"
BEFORE="$(item_count)"
{ init_req 1; call 2 add_to_history '{"text":"make e2e-ai","copyToClipboard":true}'; } > "$RUN/clip.in"
mcp clip "$RUN/clip.in" > /dev/null
check "クリップボードに置いた" "true" "$(structured clip 2 .copiedToClipboard)"
sleep 1
check "1 件だけ増えた（監視は取り込み済みの印を見て飛ばす）" "$((BEFORE + 1))" "$(item_count)"
check "コピー元は AI のまま" "AI（e2e-client）" "$(dump | jq -r '.items[0].sourceName')"

echo "== 秘密を AI が足すと、伏せ字で入り、アプリが自動消去の時計を掛ける"
AI add --text "$(fake_github)" --json > "$RESP/cli-secret.json"
check "CLI の結果は秘密（高）" "high" "$(jq -r '.secret' "$RESP/cli-secret.json")"
sleep 0.6
check "アプリが次に消す時刻を決めた" "20*" "$(status_value '.secrets.nextSweepAt')"

echo "== 壊れた要求・知らない道具・巨大な追加"
{
    echo '{not json'
    req 2 resources/list
    call 3 read_history
    echo '[]'
    printf '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add_to_history","arguments":{"text":"'
    head -c 53000000 /dev/zero | tr '\0' a
    printf '"}}}\n'
    printf '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"add_to_history","arguments":{"text":"'
    head -c 140000000 /dev/zero | tr '\0' a
    printf '"}}}\n'
    req 7 ping
} > "$RUN/edge.in"
mcp edge "$RUN/edge.in" > /dev/null
check "壊れた JSON は -32700" "-32700" "$(sed -n 1p "$RESP/edge.jsonl" | jq -r '.error.code')"
check "知らない method は -32601" "-32601" "$(err_code edge 2)"
check "知らない道具は -32602" "-32602" "$(err_code edge 3)"
check "空の配列は -32600" "-32600" "$(sed -n 4p "$RESP/edge.jsonl" | jq -r '.error.code')"
check "50 MB を超える文字は断る" "*大きすぎ*" "$(res edge 5 | jq -r '.result.content[0].text')"
check "128 MB を超える要求は読まずに -32600" "-32600" "$(sed -n 6p "$RESP/edge.jsonl" | jq -r '.error.code')"
check "そのあとも応える" "{}" "$(res edge 7 | jq -c '.result')"
check "巨大な追加で件数は増えない" "$((BEFORE + 2))" "$(item_count)"

echo "== 人のコピーと同じ文字を AI が足しても合流しない（推した文字があるかが分からない・#24）"
write fixed-text
HUMAN_ID="$(top_field id)"
BEFORE="$(item_count)"
{
    init_req 1
    call 2 add_to_history '{"text":"Makurip E2E の固定テキスト"}'
    call 3 add_to_history '{"text":"Makurip E2E の固定テキスト（外れ）"}'
} > "$RUN/guess.in"
mcp guess "$RUN/guess.in" > /dev/null
check "当たりの推しも inserted" "inserted" "$(structured guess 2 .result)"
check "外れの推しも inserted" "inserted" "$(structured guess 3 .result)"
check "当たりの推しの id は人の項目と違う" "yes" "$([ "$(structured guess 2 .id)" != "$HUMAN_ID" ] && echo yes || echo no)"
check "どちらも 1 件ずつ増えた" "$((BEFORE + 2))" "$(item_count)"
check "人の項目に AI の印が付かない" "" "$(dump | jq -r --arg id "$HUMAN_ID" '.items[] | select(.id == $id) | .flags | join(",")')"
check "人の項目の回数は 1 のまま" "1" "$(dump | jq -r --arg id "$HUMAN_ID" '.items[] | select(.id == $id) | .copyCount')"
check "人の項目のコピー元は AI にならない" "no" \
    "$(dump | jq -r --arg id "$HUMAN_ID" '.items[] | select(.id == $id) | .sourceName // "" | startswith("AI")' | sed 's/false/no/;s/true/yes/')"

echo "== オンからオフに切り替えた直後（同じ MCP のプロセスのまま）"
mkfifo "$RUN/live.in"
"$EXE" --data-dir "$DATA" --pasteboard-name "$PB" --mcp < "$RUN/live.in" > "$RESP/live.jsonl" &
MCP_PID=$!
exec 3> "$RUN/live.in"
init_req 1 >&3
call 2 list_history '{"limit":1}' >&3
sleep 1
notify disableAIAccess
sleep 0.5
call 3 list_history '{"limit":1}' >&3
exec 3>&-
wait "$MCP_PID"
check "オンのときは使えた" "false" "$(is_error live 2)"
check "オフにした直後の呼び出しは断る" "aiAccessDisabled" "$(structured live 3 .error)"
check "アプリもオフ" "false" "$(status_value '.ai.enabled')"

echo "== アプリが動いていないときの追加（次に起動したときに一覧に出る）"
notify enableAIAccess
check "もう一度オン" "true" "$(status_value '.ai.enabled')"
COUNT="$(item_count)"
quit_instance
{ init_req 1; call 2 add_to_history '{"text":"npm run build"}'; } > "$RUN/offline.in"
mcp offline "$RUN/offline.in" > /dev/null
check "動いていなくても足せる" "false" "$(is_error offline 2)"
check "動いていないと答える" "false" "$(structured offline 2 .appRunning)"
check "DB には入った" "$((COUNT + 1))" "$(item_count)"
launch_instance --pasteboard-name "$PB"
check "起動したアプリの件数に入っている" "$((COUNT + 1))" "$(status_value '.itemCount')"
check "オンのまま（DB に覚えている）" "true" "$(status_value '.ai.enabled')"

echo "== CLI の disable でオフにできる"
check "disable は成功" "0" "$(AI disable > /dev/null; echo $?)"
check "アプリから見てもオフ" "false" "$(status_value '.ai.enabled')"
check "記録に操作が残っている" "yes" "$([ "$(AI log --json | jq 'length')" -gt 10 ] && echo yes || echo no)"
check "記録に目印がない（最後）" "0" "$(grep -c "$MARK" "$DATA/ai-activity.jsonl" || true)"
check "すべての応答に目印がない（最後）" "0" "$(cat "$RESP"/* | grep -c "$MARK" || true)"
check "すべての出口に偽の秘密のハッシュがない（最後）" "0" "$(leak_hash_count)"
check "すべての出口に偽の秘密の項目の長さがない（最後）" "0" "$(leak_length_count)"

echo
echo "結果: OK $PASS / NG $FAIL"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# E2E の共通部品（source して使う）。
#
# 安全の約束:
# - データフォルダは毎回 .e2e/ の下に新しく作り、終わったら消す（KEEP_E2E=1 で残す）
# - 起動したインスタンスは必ず終了させる（trap）。記録係を 2 つ常駐させない
# - 出力するのはメタデータ（種類・型の数・バイト数）だけ。中身は出さない

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${MAKURIP_APP:-$HOME/Applications/Makurip.app}"
EXE="$APP/Contents/MacOS/Makurip"
PASS=0
FAIL=0

build_devtool() {
    (cd "$ROOT" && swift build --product MakuripDevTool > /dev/null)
    DEVTOOL="$(cd "$ROOT" && swift build --show-bin-path)/MakuripDevTool"
}

new_run_dir() {
    RUN="$ROOT/.e2e/$1-$(date +%Y%m%d-%H%M%S)-$$"
    DATA="$RUN/data"
    FILES="$RUN/files"
    mkdir -p "$DATA" "$FILES"
}

instance_pids() {
    pgrep -f -- "$EXE --data-dir $DATA" || true
}

# 隔離したインスタンスを起動する（-g: 前面に出さない）。引数は追加の起動引数
launch_instance() {
    rm -f "$DATA/debug-status.json"
    open -n -g -a "$APP" --args --data-dir "$DATA" --debug-control "$@"
    for _ in $(seq 1 100); do
        if [ -f "$DATA/debug-status.json" ] && [ -n "$(instance_pids)" ]; then return 0; fi
        sleep 0.1
    done
    echo "起動しなかった" >&2
    return 1
}

notify() {
    "$DEVTOOL" notify --data-dir "$DATA" "$@" > /dev/null
}

quit_instance() {
    [ -n "$(instance_pids)" ] || return 0
    notify quit
    for _ in $(seq 1 50); do
        [ -z "$(instance_pids)" ] && return 0
        sleep 0.1
    done
    # 遠隔操作が届かなかったときだけ TERM で止める
    local pids
    pids="$(instance_pids)"
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -TERM $pids
    sleep 0.5
}

status_value() {
    notify writeStatus
    sleep 0.5
    jq -r "$1" "$DATA/debug-status.json"
}

dump() {
    "$EXE" --dump-metadata --data-dir "$DATA"
}

item_count() {
    dump | jq '.itemCount'
}

# 先頭（いちばん新しい）項目のメタデータを 1 行で
top_summary() {
    dump | jq -r '.items[0] | "kind=\(.kind) method=\(.copyMethod) items=\(.pasteboardItems|length) types=\([.pasteboardItems[][]]|length) flags=\(.flags|join(",")) bytes=\(.totalBytes) copyCount=\(.copyCount)"'
}

top_field() {
    dump | jq -r ".items[0].$1"
}

check() {
    local name="$1" expected="$2" actual="$3"
    # shellcheck disable=SC2053
    if [[ "$actual" == $expected ]]; then
        echo "OK  $name: $actual"
        PASS=$((PASS + 1))
    else
        echo "NG  $name: 期待 $expected / 実際 $actual"
        FAIL=$((FAIL + 1))
    fi
}

finish_run() {
    quit_instance
    if [ "${KEEP_E2E:-0}" != "1" ] && [ -n "${RUN:-}" ]; then
        rm -rf "${RUN:?}"
    fi
}

#!/bin/bash
# tako:run scripts/e2e/snippets.sh
#
# 定型文の隔離 E2E（#7 の受け入れ条件 3 とエッジケース）。隔離したインスタンスで定型文を登録し（snippets.json を書く。
# AI の口や手での書き換えと同じ経路で、動いているアプリはファイルの監視で読み直す）、一覧の Enter と同じ処理（遠隔操作 pasteSnippet）で
# 名前付きペーストボードへ書き戻した結果が、置き換え済みの文字になっているかを確かめる。
#
# 安全の約束（lib.sh に加えて）:
# - 一般ペーストボードには触らない（private ペーストボードを監視させ、書き戻し先もそこ）。読み出す文字は自作のテストデータだけ
# - 窓を出さない・キーを送らない（「コピーだけ」で書き戻す。⌘V を送る経路は、宛先のアプリがいないので送らない）
# - 起動する前に、呼び出しキーを使われていない組み合わせ（⌃⌥⇧⌘F11・F10）にしておく
#
#   MAKURIP_APP=.app-build/Makurip.app scripts/e2e/snippets.sh   # make app で作った .app で試す
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

build_devtool
new_run_dir snippets
PB="com.takushio2525.makurip.e2e.$(uuidgen)"
trap 'finish_run; "$DEVTOOL" pb-release "$PB" > /dev/null 2>&1 || true' EXIT
SNIPPETS="$DATA/snippets.json"

SET() {
    "$EXE" --data-dir "$DATA" --settings "$@"
}

# 定型文のファイルを書く（引数は {"name":…,"body":…} の JSON を並べたもの）。置き換えで書く（読み手が書きかけを見ない）
write_snippets() {
    local tmp="$DATA/.snippets.tmp"
    jq -n --argjson list "[$1]" '{formatVersion: 1, snippets: $list}' > "$tmp"
    mv "$tmp" "$SNIPPETS"
    sleep 0.6
}

# 番号の定型文を貼る（既定はコピーだけ）。書き戻した名前付きペーストボードの平文を返す
paste_snippet() {
    notify pasteSnippet --index "$1" --mode "${2:-copyOnly}"
    sleep 0.6
    "$DEVTOOL" pb-text --pasteboard "$PB"
}

echo "== 起動前: 呼び出しキーを使われていない組み合わせにする"
SET set keys.open ⌃⌥⇧⌘F11 > /dev/null
SET set keys.openList ⌃⌥⇧⌘F10 > /dev/null

echo "== 起動（隔離: data=.e2e/$(basename "$RUN")/data, private ペーストボード）"
launch_instance --pasteboard-name "$PB"
check "定型文のファイルを見張っている" "true" "$(status_value '.snippets.watching')"
check "定型文 0 件で起動" "0" "$(status_value '.snippets.count')"

echo "== 1. 定型文を登録する（動いているアプリがファイルの変化を読み直す）"
write_snippets '
  {"name": "日付", "abbr": ";date", "body": "今日は {{日付}} です"},
  {"name": "コードブロック", "abbr": ";code", "body": "```{{言語}}\n{{クリップボード}}\n```"},
  {"name": "カーソル", "body": "前{{カーソル}}後ろ"},
  {"name": "壊れた記法", "body": "{{日付 と {{名前}} と 日付}}"},
  {"name": "複数行", "body": "1 行目\n2 行目\n\n4 行目"},
  {"name": "同じ名前", "body": "A"},
  {"name": "同じ名前", "body": "B"}'
check "登録した 7 件を読み直した" "7" "$(status_value '.snippets.count')"
check "読み直した回数" "1" "$(status_value '.snippets.reloadCount')"

echo "== 2. 差し込みの置き換え（PasteboardWriter で名前付きペーストボードへ）"
"$DEVTOOL" pb-write --pasteboard "$PB" code > /dev/null
sleep 0.8
check "履歴にコードが 1 件" "1" "$(item_count)"
TODAY="$(date +%Y/%m/%d)"
check "{{日付}} → 今日の日付（年/月/日）" "今日は $TODAY です" "$(paste_snippet 1)"
check "貼ったのはコピーだけ" "copied" "$(status_value '.lastPasteOutcome')"
check "書き戻しは新しい履歴にしない" "1" "$(item_count)"
CODE="$(paste_snippet 2)"
check "{{言語}} → swift・{{クリップボード}} → 履歴のコード" '```swift
func makuripE2E_*\(\) -> Int {
    let value = 42
    return value
}
```' "$CODE"
check "{{カーソル}} は文字としては消す" "前後ろ" "$(paste_snippet 3)"
check "カーソルから末尾までの長さ（UTF-16）" "2" "$(status_value '.snippets.lastCursorOffsetFromEnd')"
check "壊れた記法・知らない名前は書いたまま" "{{日付 と {{名前}} と 日付}}" "$(paste_snippet 4)"
check "複数行（空の行も）そのまま" "$(printf '1 行目\n2 行目\n\n4 行目')" "$(paste_snippet 5)"
check "同じ名前でも別の定型文" "A,B" "$(paste_snippet 6),$(paste_snippet 7)"
check "プレーンテキストで貼っても同じ文字" "今日は $TODAY です" "$(paste_snippet 1 plainText)"
check "番号の外は何もしない（直前のまま）" "今日は $TODAY です" "$(paste_snippet 99)"
# ⌘V を送る経路: 宛先のアプリがいない（一覧を開いていない）ので送らずに終わる。書き戻しまでは同じ
NORMAL="$(paste_snippet 3 normal)"
check "Enter と同じ経路でも書き戻しは置き換え済み" "前後ろ" "$NORMAL"
# noTarget（許可あり・宛先なし）か noPermission（アクセシビリティの許可なし）。どちらも ⌘V は送っていない
check "宛先がいなければ ⌘V は送らない" "no*" "$(status_value '.lastPasteOutcome')"

echo "== 3. 日付の書き方（設定 snippetDateFormat）"
SET set snippetDateFormat hyphen > /dev/null
sleep 0.6
check "設定の CLI で変えるとすぐ効く（年-月-日）" "今日は $(date +%Y-%m-%d) です" "$(paste_snippet 1)"
SET set snippetDateFormat 2026年10月31日 > /dev/null
sleep 0.6
check "ラベルでも指定できる（年月日）" "今日は $(date +%Y)年$(date +%-m)月$(date +%-d)日 です" "$(paste_snippet 1)"
check "知らない書き方は拒否（終了コード 2）" "2" "$(SET set snippetDateFormat yyyy.MM.dd > /dev/null 2>&1; echo $?)"

echo "== 4. 履歴の消去・上限で定型文は消えない"
BEFORE="$(shasum "$SNIPPETS" | cut -d' ' -f1)"
notify clearHistory
sleep 0.6
check "履歴を消去した" "0" "$(item_count)"
check "定型文は 7 件のまま" "7" "$(status_value '.snippets.count')"
check "定型文のファイルは変わらない" "$BEFORE" "$(shasum "$SNIPPETS" | cut -d' ' -f1)"
check "履歴が空なら {{クリップボード}} と {{言語}} は空" '```

```' "$(paste_snippet 2)"
SET set maxItems 10 > /dev/null
for _ in $(seq 1 13); do
    "$DEVTOOL" pb-write --pasteboard "$PB" text > /dev/null
    sleep 0.4
done
sleep 0.5
check "件数の上限で履歴は 10 件" "10" "$(item_count)"
check "定型文は 7 件のまま" "7" "$(status_value '.snippets.count')"
check "定型文のファイルは変わらない" "$BEFORE" "$(shasum "$SNIPPETS" | cut -d' ' -f1)"
check "{{クリップボード}} は秘密でない最新の文字（テストデータの文）" "Makurip E2E のテキスト *" \
    "$(paste_snippet 2 | sed -n 2p)"

echo "== 5. 壊れたファイル・数百件・とても長い本文"
printf 'not json' > "$SNIPPETS.tmp" && mv "$SNIPPETS.tmp" "$SNIPPETS"
sleep 0.6
check "JSON として読めなければ 0 件で動く" "0" "$(status_value '.snippets.count')"
check "読めない理由を 1 つ持つ" "1" "$(status_value '.snippets.issueCount')"
check "アプリはファイルを書き換えない（退避は次に保存するとき）" "not json" "$(cat "$SNIPPETS")"
MANY="$(jq -nc '[range(0; 300) | {name: "定型文 \(. + 1)", body: "本文 \(. + 1) {{日付}}"}] | .[]' | paste -sd, -)"
write_snippets "$MANY"
check "300 件を読み直した" "300" "$(status_value '.snippets.count')"
check "300 番目を貼れる" "本文 300 $(date +%Y)年$(date +%-m)月$(date +%-d)日" "$(paste_snippet 300)"
LONG="$(jq -nc '{name: "長い", body: ([range(0; 5000) | "長い文の \(.) 行目"] | join("\n"))}')"
write_snippets "$LONG"
check "長い本文（5000 行）を貼れる" "5000" "$(paste_snippet 1 | wc -l | tr -d ' ' | awk '{print $1 + 1}')"
check "書き戻した長さ（UTF-16）" "$(jq -r '.snippets[0].body | length' "$SNIPPETS")" \
    "$(status_value '.snippets.lastPasteLength')"

echo
echo "結果: OK $PASS / NG $FAIL"
[ "$FAIL" -eq 0 ]

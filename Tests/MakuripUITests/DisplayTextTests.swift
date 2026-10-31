import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

@Suite("一覧の文言")
struct DisplayTextTests {
    let now = SampleHistory.now

    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    @Test("相対時刻（試作の Mk.rel と同じ）")
    func relative() {
        #expect(DisplayText.relative(ago(0.5), now: now) == "たった今")
        #expect(DisplayText.relative(ago(5), now: now) == "5分前")
        #expect(DisplayText.relative(ago(59), now: now) == "59分前")
        #expect(DisplayText.relative(ago(130), now: now) == "2時間前")
        #expect(DisplayText.relative(ago(1440 + 140), now: now) == "昨日")
        #expect(DisplayText.relative(ago(3 * 1440 + 200), now: now) == "3日前")
        #expect(DisplayText.relative(ago(9 * 1440), now: now) == "10月22日")
    }

    @Test("日時と日付の区切り")
    func absoluteAndGroup() {
        #expect(DisplayText.absolute(ago(5), now: now) == "今日 15:25")
        #expect(DisplayText.absolute(ago(1440 + 140), now: now) == "昨日 13:10")
        #expect(DisplayText.group(ago(5), now: now) == .today)
        #expect(DisplayText.group(ago(16 * 60), now: now) == .yesterday)  // 前日の 23:30
        #expect(DisplayText.group(ago(3 * 1440), now: now) == .older)
    }

    @Test("内容の要点")
    func info() {
        let text = makeItem(.text, "あいうえお")
        #expect(DisplayText.info(for: text, detail: nil) == "5 文字")
        let code = makeItem(.code, "a\nb\nc")
        #expect(DisplayText.info(for: code, detail: nil) == "3 行")
        let url = makeItem(.url, "https://developer.example.com/x")
        #expect(DisplayText.info(for: url, detail: nil) == "developer.example.com")
    }

    @Test("コードの言語名とコマンドの注記（試作の「Swift · 17 行」「貼るときに先頭の記号を外す」）")
    func codeAndCommandInfo() {
        var detail = ClipDetail()
        detail.fullText = "let a = 1\nlet b = 2"
        detail.language = .swift
        #expect(DisplayText.info(for: makeItem(.code, "x"), detail: detail) == "Swift · 2 行")
        detail.language = nil
        #expect(DisplayText.info(for: makeItem(.code, "x"), detail: detail) == "2 行")
        var command = ClipDetail()
        command.fullText = "$ ls\n$ pwd"
        command.promptCount = 2
        #expect(DisplayText.info(for: makeItem(.command, "x"), detail: command) == "2 行 · 貼るときに先頭の記号を外す")
        command.promptCount = 0
        #expect(DisplayText.info(for: makeItem(.command, "x"), detail: command) == "2 行")
    }

    @Test("途中で切った長い文字列は、全文の行数と文字数を出す")
    func truncatedCounts() {
        var detail = ClipDetail()
        detail.fullText = "a\nb"
        detail.textTruncated = true
        detail.totalLineCount = 3000
        detail.totalCharacterCount = 99_999
        detail.language = .swift
        #expect(DisplayText.info(for: makeItem(.code, "x"), detail: detail) == "Swift · 3000 行")
        #expect(DisplayText.info(for: makeItem(.text, "x"), detail: detail) == "99999 文字")
    }

    @Test("コード・コマンドの表示用の文字列（\\r\\n をそろえ、タブを空白に）と行数")
    func codeText() {
        #expect(DisplayText.codeText("a\r\nb\r\n\tc") == "a\nb\n    c")
        #expect(DisplayText.codeText("a\rb") == "a\nb")
        #expect(DisplayText.lineCount("a\r\nb\r\nc") == 3)
        #expect(DisplayText.lineCount("") == 1)
    }

    @Test("コピー元のページ（取れるものだけ。クエリは出さない）")
    func sourcePage() {
        let page = DisplayText.sourcePage("https://chat.example.ai/c/7f3a2b?token=abc#x")
        #expect(page?.host == "chat.example.ai")
        #expect(page?.path == "/c/7f3a2b")
        #expect(DisplayText.sourcePage("https://example.com/")?.path == "")
        #expect(DisplayText.sourcePage("https://example.com/%E6%97%A5%E6%9C%AC")?.path == "/日本")
        for broken in [nil, "", "not a url", "file:///tmp/a", "https://", "javascript:alert(1)"] {
            #expect(DisplayText.sourcePage(broken) == nil, "\(String(describing: broken))")
        }
    }

    @Test("コマンドの出力の行には色を付けず、プロンプトは薄くする")
    func commandStyling() {
        let text = "$ make check\nBuild complete!"
        let styled = CodeStyler.command(text, style: CodeStyler.Style(palette: .light, size: 13), query: .empty)
        var colored: [String] = []
        for run in styled.runs where run.foregroundColor != nil {
            colored.append(String(styled[run.range].characters))
        }
        #expect(colored == ["$ ", "make"])
    }

    @Test("カードのコードは先頭 5 行を 1 行ずつ、言語の色で（\\r\\n でも行に分かれる）")
    @MainActor
    func codeCardLines() {
        let item = makeItem(.code, "import Foundation\r\nlet a = 1\r\n3\r\n4\r\n5\r\n6\r\n7")
        let loader = ClipContentLoader(actions: nil)
        let lines = loader.codeCardLines(for: item, palette: .light, query: .empty)
        #expect(lines.count == 5)
        #expect(String(lines[1].characters) == "let a = 1")
        #expect(lines[1].runs.contains { $0.foregroundColor != nil })
        // 検索語があるときは一致した所に印を付ける
        let marked = loader.codeCardLines(for: item, palette: .light, query: SearchText.parse("foundation"))
        #expect(marked[0].runs.contains { $0.backgroundColor != nil })
    }

    @Test("色の読み取り（#RGB・#RRGGBB・rgb()・hsl()）")
    func colors() {
        #expect(ColorInfo.parse("#0A84FF")?.hex == "#0A84FF")
        #expect(ColorInfo.parse("#fff")?.hex == "#FFFFFF")
        #expect(ColorInfo.parse("rgb(255, 159, 10)")?.hex == "#FF9F0A")
        #expect(ColorInfo.parse("hsl(0, 100%, 50%)")?.hex == "#FF0000")
        #expect(ColorInfo.parse("red") == nil)
        #expect(ColorInfo.parse("#0A84FF")?.hsl == [210, 100, 52])  // 試作の rgbToHsl と同じ値
    }
}

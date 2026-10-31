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

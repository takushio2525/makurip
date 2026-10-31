import Foundation
import Testing

@testable import MakuripCore

@Suite("日本語に強い検索")
struct SearchTextTests {
    @Test("全角と半角・大文字と小文字・カタカナとひらがなを同一視する")
    func normalize() {
        // String の == は正準等価で比べるので、合成済みかどうかまでスカラーで確かめる（照合はバイト列で行う）
        #expect(Array(SearchText.normalize("ﾃﾞﾌﾟﾛｲ").unicodeScalars) == Array("でぷろい".unicodeScalars))
        #expect(Array(SearchText.normalize("ｶﾞｷﾞｸﾞ").unicodeScalars) == Array("がぎぐ".unicodeScalars))
        #expect(SearchText.normalize("デプロイ") == "でぷろい")
        #expect(SearchText.normalize("ＡＢＣ１２３") == "abc123")
        #expect(SearchText.normalize("Makurip") == "makurip")
        #expect(SearchText.normalize("コピー") == "こぴー")
        #expect(SearchText.normalize("ヴァ") == "ゔぁ")
        // 全角の空白は半角へ（語の区切りになる）
        #expect(SearchText.normalize("あ　い") == "あ い")
    }

    @Test("ローマ字をひらがなへ（試作の表と同じ）")
    func romaji() {
        #expect(SearchText.romajiToKana("kopi") == "こぴ")
        #expect(SearchText.romajiToKana("depuroi") == "でぷろい")
        #expect(SearchText.romajiToKana("kopi-") == "こぴー")
        #expect(SearchText.romajiToKana("shashin") == "しゃしん")
        #expect(SearchText.romajiToKana("kitte") == "きって")
        #expect(SearchText.romajiToKana("konnichiha") == "こんにちは")
        #expect(SearchText.romajiToKana("tsukue") == "つくえ")
        #expect(SearchText.romajiToKana("kyou") == "きょう")
        #expect(SearchText.romajiToKana("onna") == "おんな")
        #expect(SearchText.romajiToKana("kan'i") == "かんい")
        #expect(SearchText.romajiToKana("fairu") == "ふぁいる")
    }

    @Test("試作と同じ例: 「depuroi」で半角の「ﾃﾞﾌﾟﾛｲ」、「kopi」で「コピー」が見つかる")
    func prototypeExamples() {
        let deploy = SearchText.normalize("ﾃﾞﾌﾟﾛｲ手順：ビルド → 公証 → 配布ページ更新。")
        #expect(SearchText.parse("depuroi").matches(normalized: deploy))
        #expect(SearchText.parse("でぷろい").matches(normalized: deploy))
        #expect(SearchText.parse("デプロイ").matches(normalized: deploy))
        #expect(SearchText.parse("ﾃﾞﾌﾟﾛｲ").matches(normalized: deploy))
        let copy = SearchText.normalize("コピーした瞬間の内容")
        #expect(SearchText.parse("kopi").matches(normalized: copy))
        #expect(SearchText.parse("こぴー").matches(normalized: copy))
        #expect(SearchText.parse("KOPI").matches(normalized: copy))
        #expect(SearchText.parse("ｋｏｐｉ").matches(normalized: copy))
    }

    @Test("語の分け方と候補: 英字だけで 2 文字以上の語にだけ読みを足す")
    func parse() {
        #expect(SearchText.parse("").isEmpty)
        #expect(SearchText.parse("   ").isEmpty)
        #expect(SearchText.parse("kopi").terms == [["kopi", "こぴ"]])
        // 1 文字は読みを足さない（「a」で「あ」を含むものが全部出ないように）
        #expect(SearchText.parse("a").terms == [["a"]])
        // ローマ字にならない語（子音だけ）は元の綴りだけ
        #expect(SearchText.parse("git").terms == [["git"]])
        #expect(SearchText.parse("xcode").terms == [["xcode"]])
        // 数字を含む語は読みを足さない
        #expect(SearchText.parse("probe12ab").terms == [["probe12ab"]])
        // 全角の空白でも区切る。語はすべて含まれれば一致（AND）
        let query = SearchText.parse("ビルド　公証")
        #expect(query.terms.count == 2)
        let haystack = SearchText.normalize("ビルド → 公証")
        #expect(query.matches(normalized: haystack))
        #expect(!SearchText.parse("ビルド 署名").matches(normalized: haystack))
    }

    @Test("英語の語は綴りのまま一致する（読みの候補は足すだけ）")
    func latinWords() {
        let haystack = SearchText.normalize("$ git switch -c feature/history-panel")
        #expect(SearchText.parse("feature").matches(normalized: haystack))
        #expect(SearchText.parse("HISTORY panel").matches(normalized: haystack))
        #expect(!SearchText.parse("release").matches(normalized: haystack))
    }

    @Test("一致した場所は元の文字列の位置に戻す（表記が違っても）")
    func highlight() {
        let text = "ﾃﾞﾌﾟﾛｲ手順：ﾃﾞﾌﾟﾛｲ前に確認"
        let ranges = SearchText.parse("depuroi").highlightRanges(in: text)
        #expect(ranges.map { String(text[$0]) } == ["ﾃﾞﾌﾟﾛｲ", "ﾃﾞﾌﾟﾛｲ"])
        let copy = "テキストをコピーする"
        #expect(SearchText.parse("kopi").highlightRanges(in: copy).map { String(copy[$0]) } == ["コピ"])
        // 重なった一致はまとめる
        let merged = SearchText.parse("ab bc").highlightRanges(in: "xabcx")
        #expect(merged.map { String("xabcx"[$0]) } == ["abc"])
        #expect(SearchText.parse("").highlightRanges(in: "abc").isEmpty)
    }

    @Test("バイト列での部分一致（多バイト文字の途中では一致しない）")
    func byteContains() {
        #expect(SearchQuery.contains("こぴー", "ぴー"))
        #expect(SearchQuery.contains("abc", ""))
        #expect(!SearchQuery.contains("ab", "abc"))
        #expect(!SearchQuery.contains("", "a"))
    }
}

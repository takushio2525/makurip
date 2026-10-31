import Foundation

/// 日本語に強い検索の正規化と照合（純粋関数）。
///
/// 試作（`~/dev/makurip-design/ui/shared/core.js` の `normWithMap`・`romajiToKana`・`parseQuery`・`hl`）と同じ振る舞いにしてある。
/// - 全角と半角（NFKC）・大文字と小文字・カタカナとひらがなを同一視する（「ﾃﾞﾌﾟﾛｲ」→「でぷろい」）
/// - 英字だけの語（2 文字以上）はローマ字としても照合する（「kopi」→「こぴ」で「コピー」が見つかる）
/// - 空白で区切った語はすべて含まれていれば一致（AND）。1 つの語の中では、元の綴りかローマ字の読みのどちらかでよい
public enum SearchText {
    /// 照合用に正規化する。NFKC → 小文字 → カタカナ（ァ〜ヶ）をひらがなへ → NFC。
    ///
    /// 最後の NFC は、半角の「ﾃﾞ」が「て」＋結合用の濁点のまま残るのを「で」1 文字にまとめるため。
    /// 照合はバイト列で行うので、見た目が同じでも合成・分解の違いがあると一致しない
    public static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value), let hiragana = Unicode.Scalar(scalar.value - 0x60) {
                scalars.append(hiragana)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// ローマ字をひらがなへ（訓令式・ヘボン式の両方。変換できない文字はそのまま残す）
    public static func romajiToKana(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // 子音の重なりは促音（「kk」→「っk」）。n の重なりは下の撥音で扱う
            if c == n, c != "n", consonants.contains(c) {
                out += "っ"
                i += 1
                continue
            }
            if c == "n", n.map({ !vowelsAndY.contains($0) }) ?? true {
                out += "ん"
                let afterNext: Character? = i + 2 < chars.count ? chars[i + 2] : nil
                i += (n == "n" && !(afterNext.map { vowelsAndY.contains($0) } ?? false)) ? 2 : 1
                continue
            }
            // 「kan'i」の「'」は ん と母音の区切り（試作は残していたが、照合の邪魔になるので落とす）
            if c == "'" {
                i += 1
                continue
            }
            var hit = false
            for length in stride(from: 3, through: 1, by: -1) {
                let end = min(i + length, chars.count)
                if let kana = romaji[String(chars[i..<end])] {
                    out += kana
                    i = end
                    hit = true
                    break
                }
            }
            if !hit {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// 検索欄の文字列を語に分け、語ごとの候補（元の綴り・ローマ字の読み）を作る
    public static func parse(_ query: String) -> SearchQuery {
        let terms = normalize(query).split(whereSeparator: \.isWhitespace).map { token -> [String] in
            let term = String(token)
            var variants = [term]
            if term.count >= 2, term.allSatisfy({ asciiLettersAndRomajiMarks.contains($0) }) {
                let kana = romajiToKana(term)
                if kana != term, !kana.contains(where: { $0.isASCII && $0.isLetter }) {
                    variants.append(kana)
                }
            }
            return variants
        }
        return SearchQuery(terms: terms)
    }

    // MARK: 表

    private static let consonants = Set("bcdfghjklmpqrstvwxyz")
    private static let vowelsAndY = Set("aiueoy")
    private static let asciiLettersAndRomajiMarks = Set("abcdefghijklmnopqrstuvwxyz'-")

    /// ローマ字 → ひらがな（試作の ROMA と同じ表）
    static let romaji: [String: String] = {
        var table: [String: String] = ["a": "あ", "i": "い", "u": "う", "e": "え", "o": "お", "-": "ー"]
        let rows: [(String, String)] = [
            ("k", "かきくけこ"), ("g", "がぎぐげご"), ("s", "さしすせそ"), ("z", "ざじずぜぞ"), ("t", "たちつてと"),
            ("d", "だぢづでど"), ("n", "なにぬねの"), ("h", "はひふへほ"), ("b", "ばびぶべぼ"), ("p", "ぱぴぷぺぽ"),
            ("m", "まみむめも"), ("r", "らりるれろ"),
        ]
        for (consonant, kana) in rows {
            for (vowel, character) in zip("aiueo", kana) { table[consonant + String(vowel)] = String(character) }
        }
        let extra: [String: String] = [
            "ya": "や", "yu": "ゆ", "yo": "よ", "wa": "わ", "wo": "を", "wi": "うぃ", "we": "うぇ",
            "shi": "し", "chi": "ち", "tsu": "つ", "fu": "ふ", "ji": "じ", "si": "し", "ti": "ち", "tu": "つ", "hu": "ふ",
            "zi": "じ", "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "she": "しぇ", "je": "じぇ", "che": "ちぇ",
            "thi": "てぃ", "dhi": "でぃ", "dhu": "でゅ", "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
            "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ", "xtu": "っ", "ltu": "っ", "xya": "ゃ", "xyu": "ゅ",
            "xyo": "ょ",
        ]
        table.merge(extra) { _, new in new }
        let small: [(String, String)] = [("ya", "ゃ"), ("yu", "ゅ"), ("yo", "ょ")]
        for consonant in "kgnhbpmr" {
            for (y, kana) in small { table[String(consonant) + y] = table[String(consonant) + "i"]! + kana }
        }
        for (y, kana) in small {
            let vowel = String(y.dropFirst())
            table["sh" + vowel] = "し" + kana
            table["ch" + vowel] = "ち" + kana
            table["j" + vowel] = "じ" + kana
            table["sy" + vowel] = "し" + kana
            table["ty" + vowel] = "ち" + kana
            table["jy" + vowel] = "じ" + kana
            table["zy" + vowel] = "じ" + kana
        }
        return table
    }()
}

/// 解析済みの検索語。`terms` の各要素が 1 つの語の候補（どれか 1 つが含まれればその語は一致）
public struct SearchQuery: Hashable, Sendable {
    public var terms: [[String]]

    public init(terms: [[String]]) {
        self.terms = terms
    }

    public static let empty = SearchQuery(terms: [])

    public var isEmpty: Bool { terms.isEmpty }

    /// 正規化済みの文字列（`SearchText.normalize` の結果）にすべての語が含まれるか
    public func matches(normalized haystack: String) -> Bool {
        terms.allSatisfy { variants in variants.contains { SearchQuery.contains(haystack, $0) } }
    }

    /// 元の文字列の中で一致した範囲（表記が違っても元の文字の位置に戻す。重なりはまとめる）
    public func highlightRanges(in text: String) -> [Range<String.Index>] {
        guard !isEmpty, !text.isEmpty else { return [] }
        // 正規化後の 1 文字ごとに、元の文字列の範囲を持つ
        var normalized: [Character] = []
        var origin: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            for character in SearchText.normalize(String(text[index..<next])) {
                normalized.append(character)
                origin.append(index..<next)
            }
            index = next
        }
        var ranges: [Range<String.Index>] = []
        for variant in terms.joined() {
            let needle = Array(variant)
            guard !needle.isEmpty, needle.count <= normalized.count else { continue }
            var start = 0
            while start + needle.count <= normalized.count {
                if normalized[start] == needle[0], Array(normalized[start..<start + needle.count]) == needle {
                    ranges.append(origin[start].lowerBound..<origin[start + needle.count - 1].upperBound)
                    start += needle.count
                } else {
                    start += 1
                }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// UTF-8 のバイト列で探す（数千件 × 1000 文字を打鍵ごとに見るので速さを優先する。どちらも NFKC 済みなので
    /// バイトの一致で足りる。UTF-8 は文字の途中から一致することがない）
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { h in
            needle.withUTF8 { n in
                guard n.count <= h.count, let hBase = h.baseAddress, let nBase = n.baseAddress else { return false }
                return memmem(hBase, h.count, nBase, n.count) != nil
            }
        }
    }
}

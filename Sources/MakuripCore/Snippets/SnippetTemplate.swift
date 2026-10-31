import Foundation

/// 定型文の差し込み（試作 `makurip-design/ui/shared/data.js` の定型文と同じ 4 つ）
public enum SnippetPlaceholder: String, CaseIterable, Sendable {
    /// 貼る日の日付（書き方は設定の `snippetDateFormat`）
    case date = "日付"
    /// 履歴のいちばん新しい文字（秘密っぽいものは飛ばす。`SnippetClipboard`）
    case clipboard = "クリップボード"
    /// その文字のコードの言語名（```swift のように使う。決まらなければ空）
    case language = "言語"
    /// 貼ったあとの文字カーソルの位置（文字としては消す）
    case cursor = "カーソル"

    /// 本文に書く形（`{{日付}}`）
    public var token: String { "{{\(rawValue)}}" }

    /// 何に置き換わるかの説明（定型文の窓・⌘Y のプレビューに出す）
    public var summary: String {
        switch self {
        case .date: "貼る日の日付"
        case .clipboard: "履歴のいちばん新しい文字"
        case .language: "その文字のコードの言語名（swift など）"
        case .cursor: "貼ったあとの文字カーソルの位置"
        }
    }
}

/// 日付の書き方（設定 `snippetDateFormat`）。暦は設定によらず西暦（和暦の環境でも「2026」）
public enum SnippetDateFormat: String, CaseIterable, Sendable {
    /// 2026/10/31（試作と同じ。既定）
    case slash
    /// 2026-10-31
    case hyphen
    /// 2026年10月31日
    case japanese

    public static let `default` = SnippetDateFormat.slash

    public var label: String {
        switch self {
        case .slash: "2026/10/31"
        case .hyphen: "2026-10-31"
        case .japanese: "2026年10月31日"
        }
    }

    public func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
        switch self {
        case .slash: return "\(year)/\(two(month))/\(two(day))"
        case .hyphen: return "\(year)-\(two(month))-\(two(day))"
        case .japanese: return "\(year)年\(month)月\(day)日"
        }
    }
}

/// 定型文の本文の読み取りと置き換え（純粋関数）。
///
/// - 差し込みは `{{名前}}`。中の前後の空白は無視する（`{{ 日付 }}` も日付）
/// - 知らない名前（`{{名前}}`）・閉じていないもの（`{{日付`）・中に改行があるものは、書いたとおりの文字として残す
/// - `{{{日付}}` のように `{` が多いときは、余った `{` を文字として残し、最後の `{{日付}}` を差し込みにする
public enum SnippetTemplate {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case placeholder(SnippetPlaceholder)
    }

    /// 本文を文字と差し込みに分ける（画面で差し込みを札にして出すのにも使う）
    public static func segments(_ body: String) -> [Segment] {
        var result: [Segment] = []
        var cursor = body.startIndex
        for (range, kind) in placeholderRanges(in: body) {
            if cursor < range.lowerBound { result.append(.text(String(body[cursor..<range.lowerBound]))) }
            result.append(.placeholder(kind))
            cursor = range.upperBound
        }
        if cursor < body.endIndex { result.append(.text(String(body[cursor...]))) }
        return result
    }

    /// 差し込みの位置（書いたままの `{{ 日付 }}` の範囲）と種類。定型文の窓で差し込みに色を付けるのに使う
    public static func placeholderRanges(in body: String) -> [(range: Range<String.Index>, kind: SnippetPlaceholder)] {
        var result: [(range: Range<String.Index>, kind: SnippetPlaceholder)] = []
        var index = body.startIndex
        while let open = body.range(of: "{{", range: index..<body.endIndex) {
            if let found = placeholder(at: open.lowerBound, in: body) {
                result.append((open.lowerBound..<found.end, found.kind))
                index = found.end
            } else {
                index = body.index(after: open.lowerBound)
            }
        }
        return result
    }

    /// 名前として見る長さ（これより先に `}}` がなければ差し込みではない。閉じない `{{` が多い長文でも速く終わるように）
    static let maxNameLength = 24

    /// `start` から始まる `{{名前}}` が知っている差し込みなら、その種類と終わりの位置
    private static func placeholder(at start: String.Index, in body: String) -> (
        kind: SnippetPlaceholder, end: String.Index
    )? {
        let open = body.index(start, offsetBy: 2)
        var cursor = open
        var length = 0
        while cursor < body.endIndex, length <= maxNameLength {
            let character = body[cursor]
            if character.isNewline { return nil }
            if character == "}", body[cursor...].hasPrefix("}}") {
                let name = body[open..<cursor].trimmingCharacters(
                    in: .whitespaces.union(CharacterSet(charactersIn: "\u{3000}")))
                guard let kind = SnippetPlaceholder(rawValue: name) else { return nil }
                return (kind, body.index(cursor, offsetBy: 2))
            }
            cursor = body.index(after: cursor)
            length += 1
        }
        return nil
    }

    /// 本文に使われている差し込み（重なりなし・出てきた順）
    public static func placeholders(in body: String) -> [SnippetPlaceholder] {
        var seen: [SnippetPlaceholder] = []
        for case .placeholder(let kind) in segments(body) where !seen.contains(kind) { seen.append(kind) }
        return seen
    }

    /// 置き換えに使う値
    public struct Context: Sendable {
        public var now: Date
        public var timeZone: TimeZone
        public var dateFormat: SnippetDateFormat
        /// `{{クリップボード}}` に入れる文字（履歴が空なら nil → 空にする）
        public var clipboardText: String?
        /// `{{言語}}` に入れる言語（決まらなければ nil → 空にする）
        public var language: CodeLanguage?

        public init(
            now: Date, timeZone: TimeZone = .current, dateFormat: SnippetDateFormat = .default,
            clipboardText: String? = nil, language: CodeLanguage? = nil
        ) {
            self.now = now
            self.timeZone = timeZone
            self.dateFormat = dateFormat
            self.clipboardText = clipboardText
            self.language = language
        }
    }

    /// 置き換えた結果
    public struct Expansion: Equatable, Sendable {
        public var text: String
        /// `{{カーソル}}` の位置から末尾までの長さ（UTF-16）。貼ったあと、文字カーソルをこの分だけ戻す。なければ nil
        public var cursorOffsetFromEnd: Int?
    }

    public static func expand(_ body: String, context: Context) -> Expansion {
        var text = ""
        var cursorAt: Int?
        for segment in segments(body) {
            switch segment {
            case .text(let literal):
                text += literal
            case .placeholder(.date):
                text += context.dateFormat.format(context.now, timeZone: context.timeZone)
            case .placeholder(.clipboard):
                text += context.clipboardText ?? ""
            case .placeholder(.language):
                text += context.language?.rawValue ?? ""
            case .placeholder(.cursor):
                // 2 つ目からは消すだけ（文字カーソルは 1 か所にしか置けない）
                if cursorAt == nil { cursorAt = text.utf16.count }
            }
        }
        return Expansion(text: text, cursorOffsetFromEnd: cursorAt.map { text.utf16.count - $0 })
    }
}

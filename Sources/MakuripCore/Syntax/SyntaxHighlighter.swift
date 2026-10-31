import Foundation

/// 色付けの種類（試作 base.css の --s-kw・--s-str などと 1 対 1）
public enum SyntaxTokenKind: String, Sendable, CaseIterable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case attribute
    case flag
}

/// 色を付ける 1 区間（位置は UTF-16。`NSRange` にそのまま使える）
public struct SyntaxToken: Sendable, Equatable {
    public let location: Int
    public let length: Int
    public let kind: SyntaxTokenKind

    public init(location: Int, length: Int, kind: SyntaxTokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// コードの色付け（純粋関数・自前の簡易な字句解析）。試作（core.js の Mk.syntax）と同じ考え方で、
/// コメント・文字列・数・キーワード・型（大文字で始まる名前）・関数（`(` が続く名前か `.` の後ろ）・属性（`@` `#`）を見分ける。
///
/// 正確な構文解析はしない（正規表現のリテラル・文字列の中の式・JSX は見分けない）。1 回なめるだけなので長さに比例して速い。
/// 位置は UTF-16 で数え、区切りはいつも ASCII の文字の位置なので、サロゲートペアを割らない。
public enum SyntaxHighlighter {
    /// これより長い部分は色を付けない（プレビューは 2 万文字で切るので、ふつうは届かない）
    public static let maxLength = 200_000

    public static func tokens(in text: String, language: CodeLanguage?) -> [SyntaxToken] {
        var units = Array(text.utf16)
        if units.count > maxLength { units.removeSubrange(maxLength...) }
        var lexer = Lexer(u: units)
        lexer.lexDocument(language: language)
        return lexer.out
    }
}

// MARK: - 字句解析

private struct Lexer {
    let u: [UInt16]
    var out: [SyntaxToken] = []

    init(u: [UInt16]) {
        self.u = u
    }

    // MARK: 共通

    mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
        guard end > start else { return }
        out.append(SyntaxToken(location: start, length: end - start, kind: kind))
    }

    @inline(__always) func at(_ index: Int) -> UInt16 {
        index >= 0 && index < u.count ? u[index] : 0
    }

    func matches(_ pattern: [UInt16], at index: Int, end: Int) -> Bool {
        guard index + pattern.count <= end else { return false }
        for offset in 0..<pattern.count where u[index + offset] != pattern[offset] { return false }
        return true
    }

    /// 大文字小文字を区別せずに比べる（ASCII だけ）
    func matchesIgnoringCase(_ pattern: [UInt16], at index: Int, end: Int) -> Bool {
        guard index + pattern.count <= end else { return false }
        for offset in 0..<pattern.count where lower(u[index + offset]) != lower(pattern[offset]) { return false }
        return true
    }

    func find(_ pattern: [UInt16], from index: Int, end: Int) -> Int? {
        var cursor = index
        while cursor + pattern.count <= end {
            if matches(pattern, at: cursor, end: end) { return cursor }
            cursor += 1
        }
        return nil
    }

    func lineEnd(from index: Int, end: Int) -> Int {
        var cursor = index
        while cursor < end, u[cursor] != A.newline { cursor += 1 }
        return cursor
    }

    func word(_ start: Int, _ end: Int) -> String {
        String(decoding: u[start..<end], as: UTF16.self)
    }

    /// 次の空白でない文字（同じ行の中で、最大 4 文字先まで）
    func nextNonSpace(after index: Int, end: Int) -> UInt16 {
        var cursor = index
        while cursor < end, cursor < index + 4, u[cursor] == A.space || u[cursor] == A.tab { cursor += 1 }
        return cursor < end ? u[cursor] : 0
    }

    /// 文字列の終わり（閉じの引用符の次）。閉じなければ行末（複数行を許すものは end）
    func scanString(from start: Int, quote: [UInt16], multiline: Bool, escapes: Bool, end: Int) -> Int {
        var cursor = start + quote.count
        while cursor < end {
            let c = u[cursor]
            if escapes, c == A.backslash {
                cursor += 2
                continue
            }
            if c == A.newline, !multiline { return cursor }
            if matches(quote, at: cursor, end: end) { return cursor + quote.count }
            cursor += 1
        }
        return end
    }

    /// 数の終わり（0x・小数・指数・後ろに付く単位や型の印を含む）
    func scanNumber(from start: Int, end: Int) -> Int {
        var cursor = start
        if u[cursor] == A.zero, cursor + 1 < end, [A.x, A.upperX, A.b, A.o].contains(u[cursor + 1]) {
            cursor += 2
            while cursor < end, isIdent(u[cursor]) { cursor += 1 }
            return cursor
        }
        while cursor < end, isDigit(u[cursor]) || u[cursor] == A.underscore { cursor += 1 }
        if cursor + 1 < end, u[cursor] == A.dot, isDigit(u[cursor + 1]) {
            cursor += 1
            while cursor < end, isDigit(u[cursor]) || u[cursor] == A.underscore { cursor += 1 }
        }
        if cursor + 1 < end, u[cursor] == A.e || u[cursor] == A.upperE {
            let sign = u[cursor + 1] == A.plus || u[cursor + 1] == A.minus
            if isDigit(at(cursor + (sign ? 2 : 1))) {
                cursor += sign ? 2 : 1
                while cursor < end, isDigit(u[cursor]) { cursor += 1 }
            }
        }
        while cursor < end, isIdent(u[cursor]) { cursor += 1 }
        return cursor
    }

    // MARK: 文書全体（Markdown のコードブロックの囲みを外す）

    mutating func lexDocument(language: CodeLanguage?) {
        let end = u.count
        var start = 0
        var stop = end
        // ```lang … ``` の囲みの行はコメントの色にして、中だけを言語で色付けする
        if matches(A.fence, at: 0, end: end) {
            let firstLineEnd = lineEnd(from: 0, end: end)
            emit(0, firstLineEnd, .comment)
            start = min(end, firstLineEnd + 1)
            var trimmedEnd = end
            while trimmedEnd > start, isSpace(u[trimmedEnd - 1]) { trimmedEnd -= 1 }
            var closeStart = trimmedEnd
            while closeStart > start, u[closeStart - 1] != A.newline { closeStart -= 1 }
            if closeStart >= start, matches(A.fence, at: closeStart, end: trimmedEnd) {
                emit(closeStart, trimmedEnd, .comment)
                stop = closeStart
            }
        }
        guard start < stop else { return }
        lex(language: language, from: start, to: stop)
    }

    mutating func lex(language: CodeLanguage?, from start: Int, to end: Int) {
        switch language {
        case .shell: lexShell(from: start, to: end)
        case .html: lexMarkup(from: start, to: end, html: true)
        case .xml: lexMarkup(from: start, to: end, html: false)
        case .css: lexCSS(from: start, to: end)
        case .json: lexJSON(from: start, to: end)
        case .yaml: lexYAML(from: start, to: end)
        case let language?: lexCLike(Spec.of(language), from: start, to: end)
        case nil: lexCLike(Spec.generic, from: start, to: end)
        }
    }

    // MARK: C 系（Swift・JS/TS・Python・Go・Rust・C/C++・Java・Kotlin・Ruby・SQL・言語不明）

    mutating func lexCLike(_ spec: Spec, from start: Int, to end: Int) {
        var i = start
        var atLineStart = true
        while i < end {
            let c = u[i]
            if c == A.newline {
                atLineStart = true
                i += 1
                continue
            }
            if isSpace(c) {
                i += 1
                continue
            }
            let lineStart = atLineStart
            atLineStart = false

            // コメント
            if let (open, close) = spec.blockComment, matches(open, at: i, end: end) {
                let stop = find(close, from: i + open.count, end: end).map { $0 + close.count } ?? end
                emit(i, stop, .comment)
                i = stop
                continue
            }
            if spec.lineComments.contains(where: { matches($0, at: i, end: end) }),
                !(c == A.hash && (spec.preprocessor || spec.hashAttributes) && isIdentStart(at(i + 1)))
            {
                let stop = lineEnd(from: i, end: end)
                emit(i, stop, .comment)
                i = stop
                continue
            }

            // # で始まるもの（C のプリプロセッサ・Swift の #if・Rust の #[...]）
            if c == A.hash {
                if spec.preprocessor, lineStart {
                    var cursor = i + 1
                    while cursor < end, isSpace(u[cursor]) { cursor += 1 }
                    let nameStart = cursor
                    while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                    emit(i, cursor, .attribute)
                    let directive = word(nameStart, cursor)
                    if directive == "include" || directive == "import" {
                        while cursor < end, isSpace(u[cursor]) { cursor += 1 }
                        if cursor < end, u[cursor] == A.less {
                            let close = find([A.greater], from: cursor, end: lineEnd(from: cursor, end: end))
                            let stop = close.map { $0 + 1 } ?? lineEnd(from: cursor, end: end)
                            emit(cursor, stop, .string)
                            cursor = stop
                        }
                    }
                    i = cursor
                    continue
                }
                if spec.rustAttributes,
                    at(i + 1) == A.bracketOpen || (at(i + 1) == A.bang && at(i + 2) == A.bracketOpen)
                {
                    let stop =
                        find([A.bracketClose], from: i, end: lineEnd(from: i, end: end)).map { $0 + 1 }
                        ?? lineEnd(from: i, end: end)
                    emit(i, stop, .attribute)
                    i = stop
                    continue
                }
                if spec.hashAttributes, isIdentStart(at(i + 1)) {
                    var cursor = i + 1
                    while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                    emit(i, cursor, .attribute)
                    i = cursor
                    continue
                }
                if spec.hashAttributes, at(i + 1) == A.quote {
                    // Swift の生の文字列 #"…"#
                    let stop =
                        find([A.quote, A.hash], from: i + 2, end: end).map { $0 + 2 } ?? lineEnd(from: i, end: end)
                    emit(i, stop, .string)
                    i = stop
                    continue
                }
            }

            // @ で始まる属性・デコレータ・Ruby のインスタンス変数
            if spec.attributeSigils.contains(c), isIdentStart(at(i + 1)) || (c == A.at && at(i + 1) == A.at) {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) || u[cursor] == A.at { cursor += 1 }
                emit(i, cursor, .attribute)
                i = cursor
                continue
            }

            // 文字列（3 つ重ねの引用符を先に見る）
            if let triple = spec.tripleQuotes.first(where: { matches($0, at: i, end: end) }) {
                let stop = scanString(from: i, quote: triple, multiline: true, escapes: true, end: end)
                emit(i, stop, .string)
                i = stop
                continue
            }
            if spec.stringPrefixes.contains(c), let quoteStart = stringPrefixEnd(spec, from: i, end: end) {
                let quote = u[quoteStart]
                if let triple = spec.tripleQuotes.first(where: { matches($0, at: quoteStart, end: end) }) {
                    let stop = scanString(from: quoteStart, quote: triple, multiline: true, escapes: true, end: end)
                    emit(i, stop, .string)
                    i = stop
                } else {
                    let stop = scanString(
                        from: quoteStart, quote: [quote], multiline: false, escapes: true, end: end)
                    emit(i, stop, .string)
                    i = stop
                }
                continue
            }
            if spec.quotes.contains(c) {
                if c == A.apostrophe, spec.rustLifetimes, !isRustCharLiteral(at: i, end: end) {
                    // Rust のライフタイム 'a
                    var cursor = i + 1
                    while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                    emit(i, cursor, .type)
                    i = cursor
                    continue
                }
                let stop = scanString(
                    from: i, quote: [c], multiline: spec.multilineQuotes.contains(c), escapes: true, end: end)
                emit(i, stop, .string)
                i = stop
                continue
            }

            // Ruby のシンボル :name と $グローバル
            if spec.rubySymbols, c == A.colon, isIdentStart(at(i + 1)), at(i - 1) != A.colon, !isIdent(at(i - 1)) {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                emit(i, cursor, .attribute)
                i = cursor
                continue
            }

            // 数
            if isDigit(c) || (c == A.dot && isDigit(at(i + 1)) && !isIdent(at(i - 1)) && at(i - 1) != A.dot) {
                let stop = scanNumber(from: i, end: end)
                emit(i, stop, .number)
                i = stop
                continue
            }

            // 名前
            if isIdentStart(c) || (spec.dollarInIdentifiers && c == A.dollar) {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) || (spec.dollarInIdentifiers && u[cursor] == A.dollar) {
                    cursor += 1
                }
                classifyWord(spec, start: i, end: cursor, limit: end)
                i = cursor
                continue
            }
            i += 1
        }
    }

    /// Python の r"…"・b'…'・f"…" の引用符の位置
    func stringPrefixEnd(_ spec: Spec, from start: Int, end: Int) -> Int? {
        var cursor = start
        while cursor < end, cursor < start + 2, spec.stringPrefixes.contains(u[cursor]) { cursor += 1 }
        guard cursor < end, spec.quotes.contains(u[cursor]), !isIdent(at(start - 1)) else { return nil }
        return cursor
    }

    func isRustCharLiteral(at index: Int, end: Int) -> Bool {
        if at(index + 1) == A.backslash { return true }
        if at(index + 2) == A.apostrophe { return true }
        // 'あ' のように ASCII でない 1 文字（サロゲートペアを含む）
        if at(index + 1) > 0x7F { return at(index + 2) == A.apostrophe || at(index + 3) == A.apostrophe }
        return false
    }

    mutating func classifyWord(_ spec: Spec, start: Int, end: Int, limit: Int) {
        let name = word(start, end)
        let key = spec.caseInsensitive ? name.uppercased() : name
        if spec.keywords.contains(key) {
            emit(start, end, .keyword)
            return
        }
        if spec.macroBang, at(end) == A.bang, [A.parenOpen, A.bracketOpen, A.braceOpen].contains(at(end + 1)) {
            emit(start, end + 1, .function)
            return
        }
        if spec.types.contains(key) || (spec.capitalizedTypes && isUpper(u[start])) {
            emit(start, end, .type)
            return
        }
        if spec.functionWords.contains(name) || nextNonSpace(after: end, end: limit) == A.parenOpen
            || at(start - 1) == A.dot
        {
            emit(start, end, .function)
        }
    }

    // MARK: シェル

    static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "case", "esac", "function", "while", "until",
        "select", "return", "local", "export", "readonly", "declare", "unset", "break", "continue", "exit",
    ]
    /// この後ろの語もコマンドの位置
    static let shellCommandPrefixes: Set<String> = [
        "if", "then", "else", "elif", "do", "while", "until", "sudo", "time", "exec", "nohup", "env", "xargs",
    ]

    mutating func lexShell(from start: Int, to end: Int) {
        var i = start
        var commandPosition = true
        while i < end {
            let c = u[i]
            if c == A.newline {
                commandPosition = true
                i += 1
                continue
            }
            if isSpace(c) {
                i += 1
                continue
            }
            // 語の頭の # からはコメント（a#b は語の一部）
            if c == A.hash {
                let stop = lineEnd(from: i, end: end)
                emit(i, stop, .comment)
                i = stop
                continue
            }
            if c == A.quote {
                let stop = scanString(from: i, quote: [c], multiline: false, escapes: true, end: end)
                emit(i, stop, .string)
                i = stop
                commandPosition = false
                continue
            }
            if c == A.apostrophe {
                let stop = scanString(from: i, quote: [c], multiline: false, escapes: false, end: end)
                emit(i, stop, .string)
                i = stop
                commandPosition = false
                continue
            }
            if c == A.dollar {
                let next = at(i + 1)
                if next == A.braceOpen {
                    let stop = find([A.braceClose], from: i, end: lineEnd(from: i, end: end)).map { $0 + 1 } ?? i + 2
                    emit(i, stop, .attribute)
                    i = stop
                } else if isIdentStart(next) {
                    var cursor = i + 1
                    while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                    emit(i, cursor, .attribute)
                    i = cursor
                } else if isDigit(next) || A.shellSpecialVariables.contains(next) {
                    emit(i, i + 2, .attribute)
                    i += 2
                } else if next == A.parenOpen {
                    i += 2
                    commandPosition = true
                    continue
                } else {
                    i += 1
                }
                commandPosition = false
                continue
            }
            if c == A.pipe || c == A.semicolon || c == A.ampersand || c == A.parenOpen || c == A.backtick {
                commandPosition = true
                i += 1
                continue
            }
            if A.shellStops.contains(c) {
                i += 1
                continue
            }
            // 語
            var cursor = i
            while cursor < end, !isSpace(u[cursor]), u[cursor] != A.newline, !A.shellStops.contains(u[cursor]),
                u[cursor] != A.dollar, u[cursor] != A.quote, u[cursor] != A.apostrophe, u[cursor] != A.pipe,
                u[cursor] != A.semicolon, u[cursor] != A.ampersand, u[cursor] != A.parenOpen, u[cursor] != A.backtick
            {
                cursor += 1
            }
            let name = word(i, cursor)
            var keepCommandPosition = false
            if c == A.minus, !commandPosition, isLetter(at(i + 1)) || (at(i + 1) == A.minus && isLetter(at(i + 2))) {
                emit(i, cursor, .flag)
            } else if Self.shellKeywords.contains(name) {
                emit(i, cursor, .keyword)
                keepCommandPosition = Self.shellCommandPrefixes.contains(name)
            } else if name.utf16.allSatisfy(isDigit) {
                emit(i, cursor, .number)
            } else if commandPosition {
                if name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                    // FOO=bar cmd の代入。次の語もコマンドの位置
                    keepCommandPosition = true
                } else {
                    emit(i, cursor, .function)
                    keepCommandPosition = Self.shellCommandPrefixes.contains(name)
                }
            }
            commandPosition = keepCommandPosition
            i = cursor
        }
    }

    // MARK: HTML・XML

    mutating func lexMarkup(from start: Int, to end: Int, html: Bool) {
        var i = start
        while i < end {
            let c = u[i]
            if c == A.less {
                if matches(A.commentOpen, at: i, end: end) {
                    let stop = find(A.commentClose, from: i + 4, end: end).map { $0 + 3 } ?? end
                    emit(i, stop, .comment)
                    i = stop
                    continue
                }
                if matches(A.cdataOpen, at: i, end: end) {
                    let stop = find(A.cdataClose, from: i, end: end).map { $0 + 3 } ?? end
                    emit(i, stop, .string)
                    i = stop
                    continue
                }
                if at(i + 1) == A.bang || at(i + 1) == A.question {
                    let stop = find([A.greater], from: i, end: end).map { $0 + 1 } ?? end
                    emit(i, stop, .attribute)
                    i = stop
                    continue
                }
                let closing = at(i + 1) == A.slash
                var cursor = i + (closing ? 2 : 1)
                guard isLetter(at(cursor)) else {
                    i += 1
                    continue
                }
                let nameStart = cursor
                while cursor < end,
                    isIdent(u[cursor]) || u[cursor] == A.minus || u[cursor] == A.colon
                        || u[cursor] == A.dot
                {
                    cursor += 1
                }
                emit(nameStart, cursor, .keyword)
                let tagName = word(nameStart, cursor).lowercased()
                var selfClosing = false
                while cursor < end, u[cursor] != A.greater {
                    let d = u[cursor]
                    if isIdentStart(d) || d == A.at || d == A.colon {
                        let attributeStart = cursor
                        cursor += 1
                        while cursor < end, isIdent(u[cursor]) || [A.minus, A.colon, A.dot].contains(u[cursor]) {
                            cursor += 1
                        }
                        emit(attributeStart, cursor, .attribute)
                    } else if d == A.quote || d == A.apostrophe {
                        let stop = scanString(from: cursor, quote: [d], multiline: true, escapes: false, end: end)
                        emit(cursor, stop, .string)
                        cursor = stop
                    } else if d == A.equals {
                        cursor += 1
                        if cursor < end, u[cursor] != A.quote, u[cursor] != A.apostrophe, !isSpace(u[cursor]) {
                            let valueStart = cursor
                            while cursor < end, !isSpace(u[cursor]), u[cursor] != A.greater, u[cursor] != A.newline {
                                cursor += 1
                            }
                            emit(valueStart, cursor, .string)
                        }
                    } else {
                        if d == A.slash { selfClosing = true }
                        cursor += 1
                    }
                }
                if cursor < end { cursor += 1 }
                i = cursor
                // <script> と <style> の中は JavaScript・CSS として色付けする
                if html, !closing, !selfClosing, tagName == "script" || tagName == "style" {
                    var contentEnd = i
                    let closeTag = Array(("</" + tagName).utf16)
                    while contentEnd < end, !matchesIgnoringCase(closeTag, at: contentEnd, end: end) { contentEnd += 1 }
                    if tagName == "script" {
                        lexCLike(Spec.of(.javascript), from: i, to: contentEnd)
                    } else {
                        lexCSS(from: i, to: contentEnd)
                    }
                    i = contentEnd
                }
                continue
            }
            if c == A.ampersand {
                var cursor = i + 1
                while cursor < end, cursor < i + 12, isIdent(u[cursor]) || u[cursor] == A.hash { cursor += 1 }
                if cursor > i + 1, at(cursor) == A.semicolon {
                    emit(i, cursor + 1, .number)
                    i = cursor + 1
                    continue
                }
            }
            i += 1
        }
    }

    // MARK: CSS

    mutating func lexCSS(from start: Int, to end: Int) {
        var i = start
        var inValue = false
        var statementStart = true
        while i < end {
            let c = u[i]
            if isSpace(c) || c == A.newline {
                i += 1
                continue
            }
            if matches(A.blockCommentOpen, at: i, end: end) {
                let stop = find(A.blockCommentClose, from: i + 2, end: end).map { $0 + 2 } ?? end
                emit(i, stop, .comment)
                i = stop
                continue
            }
            if c == A.quote || c == A.apostrophe {
                let stop = scanString(from: i, quote: [c], multiline: false, escapes: true, end: end)
                emit(i, stop, .string)
                i = stop
                continue
            }
            if c == A.braceOpen || c == A.braceClose || c == A.semicolon {
                inValue = false
                statementStart = true
                i += 1
                continue
            }
            if c == A.at, isLetter(at(i + 1)) {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
                emit(i, cursor, .keyword)
                i = cursor
                statementStart = false
                continue
            }
            if inValue {
                if c == A.hash, isHex(at(i + 1)) {
                    var cursor = i + 1
                    while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                    emit(i, cursor, .number)
                    i = cursor
                } else if isDigit(c) || ((c == A.dot || c == A.minus) && (isDigit(at(i + 1)) || at(i + 1) == A.dot)) {
                    var cursor = i + 1
                    while cursor < end, isIdent(u[cursor]) || u[cursor] == A.dot || u[cursor] == A.percent {
                        cursor += 1
                    }
                    emit(i, cursor, .number)
                    i = cursor
                } else if c == A.bang, isLetter(at(i + 1)) {
                    var cursor = i + 1
                    while cursor < end, isLetter(u[cursor]) { cursor += 1 }
                    emit(i, cursor, .keyword)
                    i = cursor
                } else if isIdentStart(c) || c == A.minus {
                    var cursor = i + 1
                    while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
                    if at(cursor) == A.parenOpen { emit(i, cursor, .function) }
                    i = cursor
                } else {
                    i += 1
                }
                continue
            }
            // 文の頭の名前は、{ より先に : があればプロパティ
            if statementStart, isIdentStart(c) || c == A.minus, isCSSProperty(from: i, end: end) {
                var cursor = i
                while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
                emit(i, cursor, .attribute)
                while cursor < end, u[cursor] != A.colon { cursor += 1 }
                i = cursor + 1
                inValue = true
                statementStart = false
                continue
            }
            statementStart = false
            // セレクタ
            if c == A.dot || c == A.hash, isIdentStart(at(i + 1)) || at(i + 1) == A.minus {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
                emit(i, cursor, .type)
                i = cursor
            } else if c == A.colon {
                var cursor = i + 1
                if at(cursor) == A.colon { cursor += 1 }
                while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
                emit(i, cursor, .attribute)
                i = cursor
            } else if c == A.bracketOpen {
                let stop = find([A.bracketClose], from: i, end: lineEnd(from: i, end: end)).map { $0 + 1 } ?? i + 1
                emit(i, stop, .attribute)
                i = stop
            } else if isIdentStart(c) {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
                emit(i, cursor, .keyword)
                i = cursor
            } else {
                i += 1
            }
        }
    }

    /// 名前の後ろに ; } より先に「: 」があり、{ がその前に来ないか（a:hover { はセレクタ）
    func isCSSProperty(from start: Int, end: Int) -> Bool {
        var cursor = start
        while cursor < end, isIdent(u[cursor]) || u[cursor] == A.minus { cursor += 1 }
        while cursor < end, isSpace(u[cursor]) { cursor += 1 }
        guard cursor < end, u[cursor] == A.colon, at(cursor + 1) != A.colon else { return false }
        while cursor < end {
            let c = u[cursor]
            if c == A.braceOpen { return false }
            if c == A.semicolon || c == A.braceClose || c == A.newline { return true }
            cursor += 1
        }
        return true
    }

    // MARK: JSON

    mutating func lexJSON(from start: Int, to end: Int) {
        var i = start
        while i < end {
            let c = u[i]
            if c == A.quote {
                let stop = scanString(from: i, quote: [c], multiline: false, escapes: true, end: end)
                var cursor = stop
                while cursor < end, isSpace(u[cursor]) || u[cursor] == A.newline { cursor += 1 }
                emit(i, stop, cursor < end && u[cursor] == A.colon ? .attribute : .string)
                i = stop
                continue
            }
            if matches(A.lineComment, at: i, end: end) {
                let stop = lineEnd(from: i, end: end)
                emit(i, stop, .comment)
                i = stop
                continue
            }
            if isDigit(c) || (c == A.minus && isDigit(at(i + 1))) {
                let stop = scanNumber(from: c == A.minus ? i + 1 : i, end: end)
                emit(i, stop, .number)
                i = stop
                continue
            }
            if isIdentStart(c) {
                var cursor = i + 1
                while cursor < end, isIdent(u[cursor]) { cursor += 1 }
                let name = word(i, cursor)
                if name == "true" || name == "false" || name == "null" { emit(i, cursor, .keyword) }
                i = cursor
                continue
            }
            i += 1
        }
    }

    // MARK: YAML（行ごと）

    mutating func lexYAML(from start: Int, to end: Int) {
        var i = start
        var blockIndent: Int?
        while i < end {
            let stop = lineEnd(from: i, end: end)
            var cursor = i
            while cursor < stop, u[cursor] == A.space { cursor += 1 }
            let indent = cursor - i
            let isBlank = cursor >= stop || (cursor + 1 == stop && u[cursor] == A.cr)
            if let block = blockIndent {
                if isBlank {
                    i = stop + 1
                    continue
                }
                if indent > block {
                    emit(cursor, trimmedEnd(cursor, stop), .string)
                    i = stop + 1
                    continue
                }
                blockIndent = nil
            }
            if !isBlank {
                if u[cursor] == A.hash {
                    emit(cursor, stop, .comment)
                } else if matches(A.yamlDocStart, at: cursor, end: stop) || matches(A.yamlDocEnd, at: cursor, end: stop)
                {
                    emit(cursor, cursor + 3, .keyword)
                    lexYAMLValue(from: cursor + 3, to: stop)
                } else {
                    // - の並び（入れ子の「- - 」も）
                    while cursor < stop, u[cursor] == A.minus, cursor + 1 == stop || u[cursor + 1] == A.space {
                        cursor += 1
                        while cursor < stop, u[cursor] == A.space { cursor += 1 }
                    }
                    var valueStart = cursor
                    if let keyEnd = yamlKeyEnd(from: cursor, end: stop) {
                        emit(cursor, keyEnd, .attribute)
                        valueStart = keyEnd + 1
                    }
                    if lexYAMLValue(from: valueStart, to: stop) { blockIndent = indent }
                }
            }
            i = stop + 1
        }
    }

    /// `key:` の key の終わり（: の位置）。key でなければ nil
    func yamlKeyEnd(from start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
        let first = u[start]
        if first == A.quote || first == A.apostrophe {
            let stop = scanString(from: start, quote: [first], multiline: false, escapes: first == A.quote, end: end)
            return stop < end && u[stop] == A.colon && (stop + 1 == end || isSpace(at(stop + 1))) ? stop : nil
        }
        guard !A.yamlIndicators.contains(first) else { return nil }
        var cursor = start
        while cursor < end {
            let c = u[cursor]
            if c == A.colon, cursor + 1 == end || isSpace(u[cursor + 1]) || u[cursor + 1] == A.cr { return cursor }
            if c == A.hash, cursor > start, isSpace(u[cursor - 1]) { return nil }
            cursor += 1
        }
        return nil
    }

    /// 値の色付け。ブロックの文字列（| と >）が始まったら true
    @discardableResult
    mutating func lexYAMLValue(from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end, isSpace(u[i]) { i += 1 }
        guard i < end else { return false }
        // &anchor・*alias・!tag
        while i < end, u[i] == A.ampersand || u[i] == A.asterisk || u[i] == A.bang {
            var cursor = i + 1
            while cursor < end, !isSpace(u[cursor]) { cursor += 1 }
            emit(i, cursor, .type)
            i = cursor
            while i < end, isSpace(u[i]) { i += 1 }
        }
        guard i < end else { return false }
        let c = u[i]
        if c == A.hash {
            emit(i, end, .comment)
            return false
        }
        if c == A.pipe || c == A.greater {
            var cursor = i + 1
            while cursor < end, u[cursor] == A.minus || u[cursor] == A.plus || isDigit(u[cursor]) { cursor += 1 }
            emit(i, cursor, .keyword)
            if let comment = find([A.hash], from: cursor, end: end) { emit(comment, end, .comment) }
            return true
        }
        if c == A.bracketOpen || c == A.braceOpen {
            lexJSON(from: i, to: end)
            return false
        }
        if c == A.quote || c == A.apostrophe {
            let stop = scanString(from: i, quote: [c], multiline: false, escapes: c == A.quote, end: end)
            emit(i, stop, .string)
            if let comment = find(A.spaceHash, from: stop, end: end) { emit(comment + 1, end, .comment) }
            return false
        }
        // そのままの値: 後ろの「 #」からはコメント
        var valueEnd = end
        var commentStart: Int?
        if let comment = find(A.spaceHash, from: i, end: end) {
            valueEnd = comment
            commentStart = comment + 1
        }
        valueEnd = trimmedEnd(i, valueEnd)
        let value = word(i, valueEnd)
        let kind: SyntaxTokenKind
        if A.yamlConstants.contains(value.lowercased()) {
            kind = .keyword
        } else if value.range(
            of: #"^[-+]?(\d[\d_]*(\.\d+)?([eE][-+]?\d+)?|0x[0-9a-fA-F]+|\.inf|\.nan)$"#, options: .regularExpression)
            != nil
        {
            kind = .number
        } else {
            kind = .string
        }
        emit(i, valueEnd, kind)
        if let commentStart { emit(commentStart, end, .comment) }
        return false
    }

    func trimmedEnd(_ start: Int, _ end: Int) -> Int {
        var cursor = end
        while cursor > start, isSpace(u[cursor - 1]) { cursor -= 1 }
        return cursor
    }
}

// MARK: - 言語ごとの設定

private struct Spec {
    var lineComments: [[UInt16]] = []
    var blockComment: ([UInt16], [UInt16])?
    var quotes: Set<UInt16> = [A.quote, A.apostrophe]
    var multilineQuotes: Set<UInt16> = []
    var tripleQuotes: [[UInt16]] = []
    var stringPrefixes: Set<UInt16> = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    var functionWords: Set<String> = []
    var capitalizedTypes = true
    var caseInsensitive = false
    var attributeSigils: Set<UInt16> = []
    /// C のプリプロセッサ（行頭の #include）
    var preprocessor = false
    /// Swift の #if・#available・#"…"#
    var hashAttributes = false
    var rustAttributes = false
    var rustLifetimes = false
    var macroBang = false
    var dollarInIdentifiers = false
    var rubySymbols = false

    static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    static let cComments: ([[UInt16]], ([UInt16], [UInt16])) = (
        [A.lineComment], (A.blockCommentOpen, A.blockCommentClose)
    )

    /// 言語不明: 文字列（" と `）・数・// と /* */ のコメントだけ
    static let generic: Spec = {
        var spec = Spec()
        (spec.lineComments, spec.blockComment) = cComments
        spec.quotes = [A.quote, A.backtick]
        spec.capitalizedTypes = false
        return spec
    }()

    static func of(_ language: CodeLanguage) -> Spec {
        specs[language] ?? generic
    }

    static let specs: [CodeLanguage: Spec] = {
        var result: [CodeLanguage: Spec] = [:]

        var swift = Spec()
        (swift.lineComments, swift.blockComment) = cComments
        swift.quotes = [A.quote]
        swift.tripleQuotes = [A.tripleQuote]
        swift.hashAttributes = true
        swift.attributeSigils = [A.at]
        swift.keywords = words(
            "struct class enum protocol extension func var let if else guard return for in while switch case default import some any private public internal fileprivate static self Self init deinit true false nil try await async throws where inout typealias associatedtype mutating nonmutating override final open lazy weak unowned convenience required indirect defer repeat break continue fallthrough is as rethrows subscript operator actor nonisolated isolated do catch throw super consuming borrowing macro"
        )
        result[.swift] = swift

        var javascript = Spec()
        (javascript.lineComments, javascript.blockComment) = cComments
        javascript.quotes = [A.quote, A.apostrophe, A.backtick]
        javascript.multilineQuotes = [A.backtick]
        javascript.attributeSigils = [A.at]
        javascript.dollarInIdentifiers = true
        javascript.keywords = words(
            "const let var function return if else for of in while do switch case default break continue import export from as new class extends async await try catch finally throw true false null undefined this typeof instanceof void delete yield static get set super"
        )
        result[.javascript] = javascript

        var typescript = javascript
        typescript.keywords.formUnion(
            words(
                "type interface implements enum declare namespace abstract readonly private public protected keyof infer is satisfies"
            ))
        typescript.types = words("string number boolean any unknown never object symbol bigint")
        result[.typescript] = typescript

        var python = Spec()
        python.lineComments = [[A.hash]]
        python.tripleQuotes = [A.tripleQuote, A.tripleApostrophe]
        python.stringPrefixes = Set("rRbBfFuU".utf16)
        python.attributeSigils = [A.at]
        python.keywords = words(
            "def class return if elif else for in while import from as with try except finally raise True False None and or not lambda yield async await pass is global nonlocal del assert break continue match case"
        )
        python.types = words("str bool int float dict list tuple set bytes object complex frozenset")
        result[.python] = python

        var go = Spec()
        (go.lineComments, go.blockComment) = cComments
        go.quotes = [A.quote, A.apostrophe, A.backtick]
        go.multilineQuotes = [A.backtick]
        go.keywords = words(
            "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota"
        )
        go.types = words(
            "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 string bool byte rune error any"
        )
        result[.go] = go

        var rust = Spec()
        (rust.lineComments, rust.blockComment) = cComments
        rust.rustAttributes = true
        rust.rustLifetimes = true
        rust.macroBang = true
        rust.keywords = words(
            "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
        )
        rust.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        result[.rust] = rust

        var c = Spec()
        (c.lineComments, c.blockComment) = cComments
        c.preprocessor = true
        c.keywords = words(
            "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL"
        )
        c.types = words(
            "size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t wchar_t")
        result[.c] = c

        var cpp = c
        cpp.keywords.formUnion(
            words(
                "class namespace template typename public private protected virtual override final new delete this nullptr using operator friend constexpr noexcept static_cast dynamic_cast reinterpret_cast const_cast try catch throw explicit mutable decltype"
            ))
        cpp.types.formUnion(words("string vector map"))
        result[.cpp] = cpp

        var java = Spec()
        (java.lineComments, java.blockComment) = cComments
        java.tripleQuotes = [A.tripleQuote]
        java.attributeSigils = [A.at]
        java.keywords = words(
            "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var record yield sealed permits"
        )
        result[.java] = java

        var kotlin = Spec()
        (kotlin.lineComments, kotlin.blockComment) = cComments
        kotlin.tripleQuotes = [A.tripleQuote]
        kotlin.attributeSigils = [A.at]
        kotlin.keywords = words(
            "package import class interface fun val var if else when for while do return break continue object companion data sealed enum open abstract override private protected public internal in out is as try catch finally throw this super null true false init constructor by suspend inline reified typealias lateinit operator infix vararg where"
        )
        result[.kotlin] = kotlin

        var ruby = Spec()
        ruby.lineComments = [[A.hash]]
        ruby.quotes = [A.quote, A.apostrophe, A.backtick]
        ruby.attributeSigils = [A.at, A.dollar]
        ruby.rubySymbols = true
        ruby.keywords = words(
            "def end if elsif else unless while until for in do return class module self nil true false and or not then yield begin rescue ensure raise case when super next break redo retry lambda proc alias defined? undef private protected public"
        )
        ruby.functionWords = words(
            "puts print p require require_relative include extend attr_accessor attr_reader attr_writer raise")
        result[.ruby] = ruby

        var sql = Spec()
        sql.lineComments = [A.sqlComment]
        sql.blockComment = (A.blockCommentOpen, A.blockCommentClose)
        sql.quotes = [A.apostrophe, A.quote, A.backtick]
        sql.capitalizedTypes = false
        sql.caseInsensitive = true
        sql.keywords = words(
            "SELECT FROM WHERE AND OR NOT IN IS NULL AS ON JOIN LEFT RIGHT INNER OUTER FULL CROSS GROUP BY ORDER HAVING LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX VIEW UNIQUE PRIMARY KEY FOREIGN REFERENCES DROP ALTER ADD COLUMN DEFAULT CONSTRAINT CHECK DISTINCT UNION ALL CASE WHEN THEN ELSE END EXISTS BETWEEN LIKE ASC DESC WITH IF RETURNING TRUE FALSE BEGIN COMMIT ROLLBACK TRANSACTION TRIGGER CASCADE AUTOINCREMENT EXPLAIN PRAGMA REPLACE CONFLICT DO NOTHING OVER PARTITION ROWS ILIKE GLOB COLLATE"
        )
        sql.types = words(
            "INT INTEGER BIGINT SMALLINT TINYINT TEXT VARCHAR CHAR NCHAR NVARCHAR REAL FLOAT DOUBLE NUMERIC DECIMAL BLOB BOOLEAN BOOL DATE TIME DATETIME TIMESTAMP TIMESTAMPTZ SERIAL BIGSERIAL JSON JSONB UUID BYTEA INTERVAL"
        )
        result[.sql] = sql

        return result
    }()
}

// MARK: - 文字（ASCII）

private enum A {
    static let newline = ascii("\n")
    static let cr = ascii("\r")
    static let space = ascii(" ")
    static let tab = ascii("\t")
    static let quote = ascii("\"")
    static let apostrophe = ascii("'")
    static let backtick = ascii("`")
    static let backslash = ascii("\\")
    static let slash = ascii("/")
    static let asterisk = ascii("*")
    static let hash = ascii("#")
    static let at = ascii("@")
    static let dollar = ascii("$")
    static let dot = ascii(".")
    static let colon = ascii(":")
    static let semicolon = ascii(";")
    static let underscore = ascii("_")
    static let minus = ascii("-")
    static let plus = ascii("+")
    static let equals = ascii("=")
    static let percent = ascii("%")
    static let bang = ascii("!")
    static let question = ascii("?")
    static let pipe = ascii("|")
    static let ampersand = ascii("&")
    static let less = ascii("<")
    static let greater = ascii(">")
    static let parenOpen = ascii("(")
    static let parenClose = ascii(")")
    static let bracketOpen = ascii("[")
    static let bracketClose = ascii("]")
    static let braceOpen = ascii("{")
    static let braceClose = ascii("}")
    static let zero = ascii("0")
    static let x = ascii("x")
    static let upperX = ascii("X")
    static let b = ascii("b")
    static let o = ascii("o")
    static let e = ascii("e")
    static let upperE = ascii("E")

    static let lineComment = Array("//".utf16)
    static let sqlComment = Array("--".utf16)
    static let blockCommentOpen = Array("/*".utf16)
    static let blockCommentClose = Array("*/".utf16)
    static let tripleQuote = Array("\"\"\"".utf16)
    static let tripleApostrophe = Array("'''".utf16)
    static let fence = Array("```".utf16)
    static let commentOpen = Array("<!--".utf16)
    static let commentClose = Array("-->".utf16)
    static let cdataOpen = Array("<![CDATA[".utf16)
    static let cdataClose = Array("]]>".utf16)
    static let yamlDocStart = Array("---".utf16)
    static let yamlDocEnd = Array("...".utf16)
    static let spaceHash = Array(" #".utf16)

    /// $? $# $@ $$ $! $* $-
    static let shellSpecialVariables: Set<UInt16> = Set("?#@$!*-".utf16)
    /// 語を切る記号（リダイレクトと閉じかっこ）
    static let shellStops: Set<UInt16> = Set("<>){}".utf16)
    /// YAML の値の頭に来ると key にならない記号
    static let yamlIndicators: Set<UInt16> = Set("[{&*!|>%@`".utf16)
    static let yamlConstants: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]

    static func ascii(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
}

@inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
@inline(__always) private func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
@inline(__always) private func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
@inline(__always) private func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || c == 95 }
@inline(__always) private func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
@inline(__always) private func isHex(_ c: UInt16) -> Bool {
    isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
}
@inline(__always) private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }
@inline(__always) private func lower(_ c: UInt16) -> UInt16 { isUpper(c) ? c + 32 : c }

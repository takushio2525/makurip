import Foundation

/// コマンドの行頭のプロンプト（`$ `・`% `・`user@host:~$ ` など）を見つけて外す（純粋関数）。
///
/// 壊さないことを最優先にする。迷う行は外さない。
///
/// - 外す: 行頭の `$ `・`% `・`❯ `・`➜ `、PS1（`user@host:~$ `・`[user@host dir]$ `・`user@host dir % `・
///   `bash-3.2$ `。前に `(venv) ` が付いていてもよい）、続き行の `> `（前の行が `\`・`|`・`&&`・`||` で終わるか、
///   引用符・ヒアドキュメントが閉じていないときだけ）、root の `# `（全部の行が `# コマンド` のときだけ）
/// - 外さない: プロンプトのない行（コマンドの出力）、行の途中の `$`（`$VAR`・`$(...)`・jQuery）、
///   `#` のコメント（ほかにプロンプトの行があるとき・`#` の後ろがコマンドに見えないとき）、行頭の空白の後ろの記号
///
/// 位置は UTF-16 で数える（`NSRange` にそのまま使える）。
public enum ShellPrompt {
    public struct Analysis: Sendable, Equatable {
        /// 元の文字列
        public let text: String
        /// 外すプロンプトの範囲（UTF-16。行頭から）。外すものがなければ空
        public let promptRanges: [NSRange]
        /// コマンドの行（プロンプトの行と、その続きの行）の範囲（UTF-16。改行を含まない）。
        /// プロンプトがあるとき、ここに入らない行はコマンドの出力（色付けしない）
        public let commandLineRanges: [NSRange]

        public var hasPrompt: Bool { !promptRanges.isEmpty }

        /// プロンプトを外した文字列（外すものがなければ元のまま）
        public var stripped: String {
            guard hasPrompt else { return text }
            let source = text as NSString
            var result = ""
            var cursor = 0
            for range in promptRanges {
                result += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
                cursor = range.location + range.length
            }
            result += source.substring(from: cursor)
            return result
        }
    }

    /// 文字列全体を見て、外すプロンプトを決める
    public static func analyze(_ text: String) -> Analysis {
        let lines = splitLines(text)
        var lengths = lines.map { explicitPromptLength($0.content) }
        let hasExplicit = lengths.contains { $0 != nil }

        if !hasExplicit {
            // root の「# 」: ほかのプロンプトがなく、空でない行がすべて「# コマンド」のときだけ外す
            // （1 行でもコメントらしい行があれば、全部コメントとみなす）
            let nonEmpty = lines.indices.filter { !lines[$0].content.trimmingCharacters(in: .whitespaces).isEmpty }
            if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ isRootCommandLine(lines[$0].content) }) {
                for index in nonEmpty { lengths[index] = 2 }
            }
        }

        // 続き行の「> 」（前の行のコマンドが閉じていないときだけ）
        var pending = ""
        var heredoc: String?
        var isCommandLine = [Bool](repeating: false, count: lines.count)
        for index in lines.indices {
            let content = lines[index].content
            if let length = lengths[index] {
                isCommandLine[index] = true
                pending = String(content.utf16.dropFirst(length)) ?? ""
                heredoc = heredocDelimiter(in: pending)
                continue
            }
            let isOpen = heredoc != nil || isUnfinished(pending)
            if isOpen, let length = continuationPromptLength(content) {
                lengths[index] = length
                // ヒアドキュメントの中身はデータ（コマンドの行にしない）
                isCommandLine[index] = heredoc == nil
                let body = String(content.utf16.dropFirst(length)) ?? ""
                if let delimiter = heredoc {
                    if body.trimmingCharacters(in: .whitespaces) == delimiter {
                        heredoc = nil
                        pending = ""
                    }
                } else {
                    pending += "\n" + body
                    heredoc = heredocDelimiter(in: body)
                }
                continue
            }
            // 「> 」のない続きの行（文書から写した `docker run \` の次の行など）。外すものはない
            if isOpen, heredoc == nil, !content.trimmingCharacters(in: .whitespaces).isEmpty {
                isCommandLine[index] = true
                pending += "\n" + content
                continue
            }
            // プロンプトのない行（出力・コメント）で、続きの状態は切れる
            pending = ""
            heredoc = nil
        }

        let ranges = lines.indices.compactMap { index -> NSRange? in
            guard let length = lengths[index], length > 0 else { return nil }
            return NSRange(location: lines[index].start, length: length)
        }
        let commandLines = lines.indices.filter { isCommandLine[$0] }.map {
            NSRange(location: lines[$0].start, length: lines[$0].content.utf16.count)
        }
        return Analysis(text: text, promptRanges: ranges, commandLineRanges: commandLines)
    }

    /// プロンプトを外した文字列（外すものがなければ元のまま）
    public static func strip(_ text: String) -> String {
        analyze(text).stripped
    }

    // MARK: 1 行のプロンプト

    /// 単純な記号のプロンプト（行頭のみ。後ろに空白か行末）
    static let simplePrompts: [String] = ["$", "%", "❯", "➜"]

    /// PS1 の形（user@host を含む・bash-3.2$）。後ろは空白か行末
    static let ps1Patterns: [NSRegularExpression] = [
        // Debian・Ubuntu: user@host:~/dir$ （root は #）
        #"^(?:\([\w.-]+\) )?[\w.-]+@[\w.-]+:[^\s$#%]*[$#](?: |$)"#,
        // RHEL・CentOS: [user@host dir]$
        #"^(?:\([\w.-]+\) )?\[[\w.-]+@[\w.-]+ [^\]\n]+\][$#](?: |$)"#,
        // macOS の zsh: user@host ~ %
        #"^(?:\([\w.-]+\) )?[\w.-]+@[\w.-]+ \S+ [%#$](?: |$)"#,
        // bash-3.2$ ・sh-5.1#
        #"^(?:\([\w.-]+\) )?(?:ba|z|k|da)?sh-\d+(?:\.\d+)*[$#](?: |$)"#,
        // oh-my-zsh（robbyrussell）: ➜  dir git:(main) ✗
        #"^➜  \S+ (?:git:\([^)\s]*\) )?(?:✗ )?"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// 行頭のはっきりしたプロンプトの長さ（UTF-16）。root の「# 」と続き行の「> 」は文脈で決めるのでここでは見ない
    public static func explicitPromptLength(_ line: String) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        for pattern in ps1Patterns {
            if let match = pattern.firstMatch(in: line, range: range), match.range.length > 0 {
                return match.range.length
            }
        }
        // oh-my-zsh の形（➜ の後ろに空白 2 つ）で PS1 に当たらなかったものは、どこまでがプロンプトか分からないので外さない
        if line.hasPrefix("➜  ") { return nil }
        for symbol in simplePrompts where line.hasPrefix(symbol) {
            let rest = line.dropFirst(symbol.count)
            if rest.isEmpty { return symbol.utf16.count }
            if rest.first == " " { return symbol.utf16.count + 1 }
        }
        return nil
    }

    /// 「# コマンド」の行か（root のプロンプトの候補）。`#` の後ろがコマンドに見えなければコメント
    static func isRootCommandLine(_ line: String) -> Bool {
        guard line.hasPrefix("# ") else { return false }
        let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return false }
        return TextHeuristics.looksLikeCommandLine(rest)
    }

    /// 続き行のプロンプト（bash の「> 」、zsh の「quote> 」「pipe pipe> 」など）
    static let continuationPattern = try! NSRegularExpression(pattern: #"^(?:[a-z]+ )*[a-z]*>(?: |$)"#)

    static func continuationPromptLength(_ line: String) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = continuationPattern.firstMatch(in: line, range: range) else { return nil }
        return match.range.length
    }

    // MARK: コマンドが閉じているか

    /// 次の行に続くコマンドか（行末の `\`・`|`・`&&`・`||`、閉じていない引用符）
    static func isUnfinished(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasSuffix("\\") || trimmed.hasSuffix("|") || trimmed.hasSuffix("&&") { return true }
        return hasOpenQuote(command)
    }

    /// 引用符が閉じていないか（' の中では \ を数えない。" の中と外では \ の次の 1 文字を飛ばす）
    static func hasOpenQuote(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#" {
                // 引用符の外の # から後ろはコメント（中の引用符を数えない）
                break
            }
        }
        return quote != nil
    }

    static let heredocPattern = try! NSRegularExpression(pattern: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#)

    /// ヒアドキュメントの終わりの印（`<<EOF` の EOF）
    static func heredocDelimiter(in command: String) -> String? {
        let range = NSRange(location: 0, length: (command as NSString).length)
        guard let match = heredocPattern.firstMatch(in: command, range: range),
            let delimiter = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[delimiter])
    }

    // MARK: 行に分ける

    struct LineSlice {
        /// 行の始まり（UTF-16）
        let start: Int
        /// 改行を除いた中身（行末の \r も除く）
        let content: String
    }

    /// \n で分ける（Swift の Character では \r\n が 1 文字になり \n で分けられないので、Unicode スカラーで分ける）
    static func splitLines(_ text: String) -> [LineSlice] {
        var result: [LineSlice] = []
        var start = 0
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var scalars = String.UnicodeScalarView(line)
            let length = String(scalars).utf16.count
            if scalars.last == "\r" { scalars.removeLast() }
            result.append(LineSlice(start: start, content: String(scalars)))
            start += length + 1
        }
        return result
    }
}

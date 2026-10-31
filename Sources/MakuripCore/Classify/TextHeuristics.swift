import Foundation

/// 平文から URL・コマンド・コード・色を見分ける経験則（純粋関数）。
///
/// どれも「それらしさ」の判定で、確実ではない。見分けられない例は `.agent/conventions.md` の
/// 「判定の限界」に書いてある。判定を変えたら `KindClassifierTests` の入力例も足すこと。
public enum TextHeuristics {
    /// 長い文字列は先頭だけ見る（数 MB のログで重くしない）
    static let inspectLimit = 4000

    // MARK: URL

    static let urlSchemes: Set<String> = ["http", "https", "ftp", "ftps", "ssh", "git", "ws", "wss", "file", "mailto"]

    /// 1 行で空白を含まない URL か
    public static func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096,
            !trimmed.contains(where: { $0.isWhitespace })
        else { return false }
        if trimmed.lowercased().hasPrefix("www."), trimmed.contains(".") {
            return trimmed.count > 5
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), urlSchemes.contains(scheme)
        else { return false }
        if scheme == "mailto" { return trimmed.count > "mailto:".count }
        if scheme == "file" { return trimmed.hasPrefix("file://") }
        return url.host?.isEmpty == false
    }

    /// ファイルのパスらしいか（`/Users/...`・`~/...`）。画像に付いてくる平文の判定に使う
    public static func isFilePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        return (trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")) && !trimmed.contains("  ")
    }

    // MARK: 色

    /// `#RGB` / `#RRGGBB` / `#RRGGBBAA` / `rgb(...)` / `rgba(...)` / `hsl(...)` の 1 語だけか
    public static func isColorLiteral(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.contains("\n") else { return false }
        if trimmed.hasPrefix("#") {
            let hex = trimmed.dropFirst()
            return [3, 4, 6, 8].contains(hex.count) && hex.allSatisfy(\.isHexDigit)
        }
        for prefix in ["rgb(", "rgba(", "hsl(", "hsla("] where trimmed.hasPrefix(prefix) && trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst(prefix.count).dropLast()
            return inner.allSatisfy { $0.isNumber || ", .%/".contains($0) || $0 == "d" || $0 == "e" || $0 == "g" }
        }
        return false
    }

    // MARK: コマンド

    /// シェルのプロンプト記号（行頭の「$ 」「% 」「❯ 」）
    static let promptPrefixes = ["$ ", "% ", "❯ ", "➜ "]

    /// よく使う CLI の名前（先頭の語がこれならコマンドらしい）
    static let knownCommands: Set<String> = [
        "git", "gh", "brew", "npm", "npx", "yarn", "pnpm", "bun", "deno", "node", "python", "python3", "pip",
        "pip3", "conda", "uv", "poetry", "pytest", "ruby", "gem", "bundle", "rails", "go", "cargo", "rustup",
        "rustc", "swift", "swiftc", "xcodebuild", "xcrun", "xcode-select", "pod", "make", "cmake", "ninja",
        "docker", "docker-compose", "kubectl", "helm", "terraform", "aws", "gcloud", "az", "firebase", "vercel",
        "wrangler", "ssh", "scp", "rsync", "curl", "wget", "cd", "ls", "ll", "la", "pwd", "mkdir", "rmdir", "rm",
        "cp", "mv", "ln", "touch", "cat", "less", "more", "head", "tail", "grep", "rg", "egrep", "find", "fd",
        "sed", "awk", "sort", "uniq", "wc", "xargs", "tar", "zip", "unzip", "gzip", "chmod", "chown", "sudo",
        "echo", "printf", "export", "source", "env", "which", "whereis", "open", "defaults", "launchctl",
        "killall", "kill", "ps", "top", "htop", "df", "du", "diskutil", "hdiutil", "codesign", "security",
        "plutil", "pbcopy", "pbpaste", "say", "tmux", "screen", "vim", "nvim", "nano", "code", "claude",
        "ollama", "jq", "yq", "ffmpeg", "sips", "mdfind", "softwareupdate", "networksetup", "ping", "dig",
        "nslookup", "traceroute", "ifconfig", "netstat", "lsof", "history", "alias", "set", "unset",
        "pio", "platformio", "arduino-cli", "esptool.py", "idf.py", "java", "javac", "mvn", "gradle",
        "./gradlew", "flutter", "dart", "expo", "eas", "ruff", "black", "mypy", "eslint", "prettier", "tsc",
    ]

    /// シェルのコマンド（1〜数行）らしいか
    public static func isCommand(_ text: String) -> Bool {
        let lines = nonEmptyLines(text)
        guard !lines.isEmpty, lines.count <= 12 else { return false }

        // 行頭がプロンプト記号の行があれば、ほぼ確実にコマンド（端末からのコピー）
        if let first = lines.first, promptPrefixes.contains(where: { first.hasPrefix($0) }) {
            return true
        }

        var continuing = false
        for line in lines {
            let isContinuation = continuing
            continuing = line.hasSuffix("\\") || line.hasSuffix("&&") || line.hasSuffix("|") || line.hasSuffix("||")
            if isContinuation { continue }
            guard looksLikeCommandLine(line) else { return false }
        }
        return true
    }

    static func looksLikeCommandLine(_ line: String) -> Bool {
        // 引用符の外に日本語の地の文があるなら文章（「git について」など）
        if containsCJK(removingQuoted(line)) { return false }
        // 行末が ; { } で終わるのはコードの書き方
        if line.hasSuffix(";") || line.hasSuffix("{") || line.hasSuffix("}") { return false }
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // 先頭の環境変数の代入（FOO=bar cmd）と sudo を読み飛ばす
        while let first = tokens.first, first.contains("="), !first.hasPrefix("="), !first.hasPrefix("-"),
            first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
        {
            tokens.removeFirst()
        }
        if tokens.first == "sudo" { tokens.removeFirst() }
        guard let head = tokens.first else { return false }
        if knownCommands.contains(head) { return true }
        // ./script.sh や ~/bin/tool のような実行
        if head.hasPrefix("./") || head.hasPrefix("~/") { return tokens.count <= 20 }
        return false
    }

    // MARK: コード

    static let codeKeywords: [String] = [
        "func ", "def ", "class ", "struct ", "enum ", "protocol ", "extension ", "interface ", "import ",
        "from ", "return ", "let ", "var ", "const ", "function ", "public ", "private ", "protected ",
        "static ", "async ", "await ", "fn ", "impl ", "use ", "pub ", "mod ", "package ", "#include",
        "#import", "#define", "#if", "@interface", "@implementation", "export ", "module ", "require(",
        "if (", "if(", "for (", "for(", "while (", "while(", "switch ", "case ", "else", "elif ", "try ",
        "catch", "except", "guard ", "lambda ", "yield ", "SELECT ", "INSERT ", "UPDATE ", "DELETE ",
        "CREATE ", "ALTER ", "DROP ", "WITH ", "@", "type ", "namespace ", "template<", "void ", "int ",
        "char ", "float ", "double ", "bool ", "auto ", "unsigned ", "println", "print(", "console.",
    ]

    /// プログラムのコードらしいか（行ごとの「コードらしさ」の割合で決める）
    public static func isCode(_ text: String) -> Bool {
        let sample = String(text.prefix(inspectLimit))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // ``` で始まり ``` で終わる 1 塊はコード。途中にだけ ``` がある Markdown 文書は文章扱い
        if trimmed.hasPrefix("```") {
            return trimmed.hasSuffix("```") && trimmed.count > 6
        }
        if trimmed.contains("```") { return false }

        // JSON（オブジェクト・配列）として読めるならコード
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
            let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return true
        }

        // 日本語の地の文が多いなら文章
        let cjkRatio = Double(trimmed.unicodeScalars.filter(isCJKScalar).count) / Double(trimmed.unicodeScalars.count)
        if cjkRatio > 0.3 { return false }

        let lines = nonEmptyLines(sample)
        let scores = lines.map(codeSignalCount)
        if lines.count == 1 {
            // 1 行は強い手がかりが 2 つ以上あるときだけ（`let x = foo();` など）
            return scores[0] >= 2
        }
        let codeLines = scores.filter { $0 >= 1 }.count
        let indented = sample.split(separator: "\n").filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let ratio = Double(codeLines) / Double(lines.count)
        return ratio >= 0.5 || (ratio >= 0.3 && indented >= 2)
    }

    /// 1 行の中の「コードらしさ」の手がかりの数
    static func codeSignalCount(_ line: String) -> Int {
        var score = 0
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if codeKeywords.contains(where: { trimmed.hasPrefix($0) }) { score += 1 }
        if let last = trimmed.last, ";{}".contains(last) { score += 1 }
        if trimmed.hasSuffix(":") && !containsCJK(trimmed) && trimmed.contains("(") { score += 1 }
        for op in ["==", "!=", "=>", "->", "::", "&&", "||", "+=", "-=", ":=", "</", "/>"] where trimmed.contains(op) {
            score += 1
            break
        }
        if trimmed.range(of: #"[A-Za-z_][A-Za-z0-9_\.]*\([^()]*\)"#, options: .regularExpression) != nil {
            score += 1
        }
        if trimmed.range(of: #"^\s*(//|#!|/\*|\*/|--\s)"#, options: .regularExpression) != nil { score += 1 }
        if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_\.\[\]]*\s*=\s*\S"#, options: .regularExpression) != nil {
            score += 1
        }
        return score
    }

    // MARK: 共通

    static func nonEmptyLines(_ text: String) -> [String] {
        String(text.prefix(inspectLimit))
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// '…' と "…" の中身を取り除く（引用符の外だけを見たいとき用）
    static func removingQuoted(_ line: String) -> String {
        var result = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    /// ひらがな・カタカナ・漢字・全角記号
    static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: true
        default: false
        }
    }
}

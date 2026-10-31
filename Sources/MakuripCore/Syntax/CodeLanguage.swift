import Foundation

/// コードの言語（色付けとプレビューの見出しに使う）。判定は `CodeLanguageDetector`、色付けは `SyntaxHighlighter`
public enum CodeLanguage: String, CaseIterable, Sendable, Codable {
    case swift
    case javascript
    case typescript
    case python
    case shell
    case json
    case html
    case xml
    case css
    case go
    case rust
    case c
    case cpp
    case java
    case kotlin
    case ruby
    case sql
    case yaml

    /// 画面に出す名前（試作の LANG と同じ書き方。シェルだけ日本語）
    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .shell: "シェル"
        case .json: "JSON"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .go: "Go"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .sql: "SQL"
        case .yaml: "YAML"
        }
    }

    /// Markdown のコードブロック（```swift）の言語名から引く。知らない名前は nil
    public init?(fenceTag: String) {
        let tag = fenceTag.trimmingCharacters(in: .whitespaces).lowercased()
        guard let language = Self.fenceTags[tag] else { return nil }
        self = language
    }

    static let fenceTags: [String: CodeLanguage] = [
        "swift": .swift,
        "js": .javascript, "javascript": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "node": .javascript,
        "ts": .typescript, "typescript": .typescript, "tsx": .typescript,
        "py": .python, "python": .python, "python3": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "shell": .shell, "console": .shell, "shellsession": .shell,
        "terminal": .shell, "fish": .shell,
        "json": .json, "jsonc": .json, "json5": .json,
        "html": .html, "htm": .html, "vue": .html, "svelte": .html,
        "xml": .xml, "plist": .xml, "svg": .xml,
        "css": .css, "scss": .css, "less": .css,
        "go": .go, "golang": .go,
        "rs": .rust, "rust": .rust,
        "c": .c, "h": .c,
        "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "objc": .c, "objective-c": .c,
        "java": .java,
        "kt": .kotlin, "kotlin": .kotlin, "kts": .kotlin,
        "rb": .ruby, "ruby": .ruby,
        "sql": .sql, "sqlite": .sql, "postgresql": .sql, "mysql": .sql,
        "yaml": .yaml, "yml": .yaml,
    ]
}

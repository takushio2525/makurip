import Foundation
import Testing

@testable import MakuripCore

/// 色付けの字句解析。入力はすべて自作の短いコード
@Suite("コードの色付け（字句解析）")
struct SyntaxHighlighterTests {
    /// 区間の文字列 → 種類（同じ文字列が何度も出るときは最後のもの）
    func kinds(_ text: String, _ language: CodeLanguage?) -> [String: SyntaxTokenKind] {
        let source = text as NSString
        var result: [String: SyntaxTokenKind] = [:]
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            result[source.substring(with: token.range)] = token.kind
        }
        return result
    }

    @Test("Swift: キーワード・型・文字列・コメント・数・属性・関数")
    func swift() {
        let code = """
            #if DEBUG
            @MainActor struct Row: View {
                // 相対時刻
                let count = 42
                var body: some View { Text("label").lineLimit(1) }
            }
            #endif
            """
        let k = kinds(code, .swift)
        #expect(k["#if"] == .attribute)
        #expect(k["@MainActor"] == .attribute)
        #expect(k["struct"] == .keyword)
        #expect(k["Row"] == .type)
        #expect(k["View"] == .type)
        #expect(k["// 相対時刻"] == .comment)
        #expect(k["42"] == .number)
        #expect(k["\"label\""] == .string)
        #expect(k["Text"] == .type)
        #expect(k["lineLimit"] == .function)
        #expect(k["count"] == nil)
    }

    @Test("Python: 3 重の引用符・接頭辞付きの文字列・デコレータ・# のコメント")
    func python() {
        let code = """
            @dataclass
            class Clip:
                \"\"\"履歴 1 件\"\"\"
                pattern = re.compile(r"(sk|tok)-[0-9]+")  # 秘密っぽい
                def ok(self) -> bool:
                    return True
            """
        let k = kinds(code, .python)
        #expect(k["@dataclass"] == .attribute)
        #expect(k["class"] == .keyword)
        #expect(k["\"\"\"履歴 1 件\"\"\""] == .string)
        #expect(k["r\"(sk|tok)-[0-9]+\""] == .string)
        #expect(k["# 秘密っぽい"] == .comment)
        #expect(k["bool"] == .type)
        #expect(k["True"] == .keyword)
        #expect(k["compile"] == .function)
    }

    @Test("シェル: コマンドの位置・フラグ・変数・文字列・コメント・キーワード")
    func shell() {
        let code = """
            sudo apt install -y --no-install-recommends curl
            if [ -n "$HOME" ]; then echo ${USER} | grep -q a#b; fi  # 終わり
            head -n 20 file
            """
        let k = kinds(code, .shell)
        #expect(k["sudo"] == .function)
        #expect(k["apt"] == .function)
        #expect(k["install"] == nil)
        #expect(k["-y"] == .flag)
        #expect(k["--no-install-recommends"] == .flag)
        #expect(k["if"] == .keyword)
        #expect(k["\"$HOME\""] == .string)
        #expect(k["${USER}"] == .attribute)
        #expect(k["echo"] == .function)
        #expect(k["grep"] == .function)
        #expect(k["a#b"] == nil)
        #expect(k["# 終わり"] == .comment)
        #expect(k["20"] == .number)
    }

    @Test("JSON: key と値の文字列を分ける")
    func json() {
        let k = kinds(#"{"name": "makurip", "count": -12.5e3, "ok": true, "none": null}"#, .json)
        #expect(k["\"name\""] == .attribute)
        #expect(k["\"makurip\""] == .string)
        #expect(k["-12.5e3"] == .number)
        #expect(k["true"] == .keyword)
        #expect(k["null"] == .keyword)
    }

    @Test("HTML: タグ・属性・値・コメント・中の script と style")
    func html() {
        let code = """
            <!-- カード -->
            <div class="card" data-id=12>
              <script>const x = 1;</script>
              <style>.a { color: red; }</style>
              &amp;
            </div>
            """
        let k = kinds(code, .html)
        #expect(k["<!-- カード -->"] == .comment)
        #expect(k["div"] == .keyword)
        #expect(k["class"] == .attribute)
        #expect(k["\"card\""] == .string)
        #expect(k["12"] == .string)
        #expect(k["const"] == .keyword)
        #expect(k[".a"] == .type)
        #expect(k["color"] == .attribute)
        #expect(k["&amp;"] == .number)
    }

    @Test("CSS: セレクタ・プロパティ・値の数と色・@ の規則・関数")
    func css() {
        let code = """
            @media (max-width: 600px) {
              .card:hover, #main > a { padding: 9px 1.5em; color: #0a84ff !important; background: rgb(0, 0, 0); }
            }
            """
        let k = kinds(code, .css)
        #expect(k["@media"] == .keyword)
        #expect(k[".card"] == .type)
        #expect(k[":hover"] == .attribute)
        #expect(k["#main"] == .type)
        #expect(k["a"] == .keyword)
        #expect(k["padding"] == .attribute)
        #expect(k["9px"] == .number)
        #expect(k["1.5em"] == .number)
        #expect(k["#0a84ff"] == .number)
        #expect(k["!important"] == .keyword)
        #expect(k["rgb"] == .function)
    }

    @Test("YAML: key・値・数・真偽・コメント・並び・ブロックの文字列")
    func yaml() {
        let code = """
            name: build  # 名前
            retries: 3
            enabled: true
            steps:
              - run: make check
              - "quoted"
            script: |
              echo one
              echo two
            after: x
            """
        let k = kinds(code, .yaml)
        #expect(k["name"] == .attribute)
        #expect(k["build"] == .string)
        #expect(k["# 名前"] == .comment)
        #expect(k["3"] == .number)
        #expect(k["true"] == .keyword)
        #expect(k["run"] == .attribute)
        #expect(k["make check"] == .string)
        #expect(k["\"quoted\""] == .string)
        #expect(k["|"] == .keyword)
        #expect(k["echo one"] == .string)
        #expect(k["after"] == .attribute)
    }

    @Test("SQL: 大文字小文字を問わないキーワード・型・関数・文字列・コメント")
    func sql() {
        let code = "select COUNT(*) from clip where kind = 'code' -- 数える\nCREATE TABLE t (id INTEGER);"
        let k = kinds(code, .sql)
        #expect(k["select"] == .keyword)
        #expect(k["from"] == .keyword)
        #expect(k["COUNT"] == .function)
        #expect(k["'code'"] == .string)
        #expect(k["-- 数える"] == .comment)
        #expect(k["INTEGER"] == .type)
        #expect(k["clip"] == nil)
    }

    @Test("Rust・C・Go: マクロ・ライフタイム・#[...]・#include <...>・`…` の文字列")
    func otherLanguages() {
        let rust = kinds("#[derive(Debug)]\nfn get<'a>(s: &'a str) -> char { println!(\"x\"); 'y' }", .rust)
        #expect(rust["#[derive(Debug)]"] == .attribute)
        #expect(rust["'a"] == .type)
        #expect(rust["str"] == .type)
        #expect(rust["println!"] == .function)
        #expect(rust["'y'"] == .string)
        let c = kinds("#include <stdio.h>\n#define MAX 10\nint main(void) { return 0x1F; }", .c)
        #expect(c["#include"] == .attribute)
        #expect(c["<stdio.h>"] == .string)
        #expect(c["#define"] == .attribute)
        #expect(c["0x1F"] == .number)
        #expect(c["main"] == .function)
        let go = kinds("s := `raw\nline`\nvar n int = 3", .go)
        #expect(go["`raw\nline`"] == .string)
        #expect(go["int"] == .type)
    }

    @Test("Markdown のコードブロック: 囲みの行はコメント、中は言語で")
    func fence() {
        let code = "```swift\nlet a = 1\n```"
        let k = kinds(code, .swift)
        #expect(k["```swift"] == .comment)
        #expect(k["```"] == .comment)
        #expect(k["let"] == .keyword)
    }

    @Test("言語が分からないとき: 文字列・数・コメントだけ（キーワードは付けない）")
    func unknownLanguage() {
        let k = kinds("let x = \"a\" // c\nreturn 5", nil)
        #expect(k["\"a\""] == .string)
        #expect(k["// c"] == .comment)
        #expect(k["5"] == .number)
        #expect(k["let"] == nil)
        #expect(k["return"] == nil)
    }

    @Test("閉じない文字列・コメントは行末か最後で止まる（落ちない）")
    func unterminated() {
        #expect(kinds("let s = \"abc\nlet t = 1", .swift)["\"abc"] == .string)
        #expect(kinds("/* never closed\nlet a", .swift)["/* never closed\nlet a"] == .comment)
        #expect(kinds("echo 'oops\nls", .shell)["'oops"] == .string)
        #expect(SyntaxHighlighter.tokens(in: "", language: .swift).isEmpty)
        #expect(SyntaxHighlighter.tokens(in: "x", language: .swift).isEmpty)
        #expect(SyntaxHighlighter.tokens(in: "1", language: .swift).count == 1)
        #expect(SyntaxHighlighter.tokens(in: "\"", language: .json).count == 1)
    }

    @Test("区間は重ならず、順に並び、文字列の中に収まる（全言語・全角と絵文字の混じった入力）")
    func tokensAreWellFormed() {
        let inputs =
            CodeLanguageDetectorTests.samples.map(\.1) + [
                "let 名前 = \"マクリップ📋\" // 絵文字 🎉\nprint(名前)",
                "<p title='日本語'>本文 &amp; 📁</p>",
                "key: 値 # コメント\n- \"引用\"",
                String(repeating: "x", count: 5000),
                "\"" + String(repeating: "長", count: 3000),
            ]
        for input in inputs {
            let length = (input as NSString).length
            for language in CodeLanguage.allCases + [nil] {
                let tokens = SyntaxHighlighter.tokens(in: input, language: language)
                var cursor = 0
                for token in tokens {
                    #expect(token.length > 0)
                    #expect(token.location >= cursor, "\(String(describing: language)) で重なり")
                    cursor = token.location + token.length
                    // 区切りがサロゲートペアの間に来ない
                    #expect(NSString(string: input).substring(with: token.range).utf16.count == token.length)
                }
                #expect(cursor <= length)
            }
        }
    }

    @Test("数百行のコードでも速い（1 回なめるだけ）")
    func speed() {
        let unit = """
            struct Row: View {
                let item: ClipItem // 履歴 1 件
                var body: some View { Text("label \\(item.id)").padding(.horizontal, 12) }
            }

            """
        let code = String(repeating: unit, count: 100)  // 500 行
        let start = Date()
        let tokens = SyntaxHighlighter.tokens(in: code, language: .swift)
        let elapsed = Date().timeIntervalSince(start) * 1000
        #expect(tokens.count > 1000)
        #expect(elapsed < 500, "500 行で \(elapsed) ms")
    }
}

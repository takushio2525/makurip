import Foundation
import Testing

@testable import MakuripCore

/// 言語の判定。入力はすべて自作の短いコード
@Suite("コードの言語の判定")
struct CodeLanguageDetectorTests {
    static let samples: [(CodeLanguage, String)] = [
        (
            .swift,
            """
            struct HistoryRow: View {
                let item: ClipItem
                @Binding var isSelected: Bool

                var body: some View {
                    Text(item.title).lineLimit(1)
                }
            }
            """
        ),
        (
            .swift,
            """
            guard let url = URL(string: text) else { return nil }
            let host = url.host ?? ""
            """
        ),
        (
            .javascript,
            """
            const express = require("express");
            const app = express();
            app.get("/", (req, res) => {
              console.log("hello");
              res.send("ok");
            });
            """
        ),
        (
            .typescript,
            """
            export function relativeTime(date: Date, now = new Date()): string {
              const min = Math.round((now.getTime() - date.getTime()) / 60000);
              if (min < 1) return "たった今";
              return `${min}分前`;
            }
            """
        ),
        (
            .typescript,
            """
            interface User {
              id: number;
              name: string;
            }
            type Handler = (user: User) => void;
            """
        ),
        (
            .python,
            """
            import re

            SECRET = re.compile(r"(sk|tok)-test-[A-Za-z0-9]{16,}")

            def looks_secret(text: str) -> bool:
                \"\"\"API キーらしい文字列かどうか\"\"\"
                return bool(SECRET.search(text))
            """
        ),
        (
            .shell,
            """
            #!/bin/zsh
            # 公証の結果を待ってから zip を作る
            xcrun notarytool submit "$APP_ZIP" --wait
            ditto -c -k --keepParent "build/Makurip.app" "dist/Makurip.zip"
            """
        ),
        (
            .shell,
            """
            for f in *.txt; do
              echo "$f" | grep -q sample && rm "$f"
            done
            """
        ),
        (.json, #"{"name": "makurip", "version": 1, "tags": ["clip", "mac"], "ok": true}"#),
        (
            .json,
            """
            [
              {"id": 1, "kind": "code"},
              {"id": 2, "kind": "command"}
            ]
            """
        ),
        (
            .html,
            """
            <div class="card">
              <p>履歴の<b>カード</b></p>
              <button onclick="paste()">貼る</button>
            </div>
            """
        ),
        (.html, "<!DOCTYPE html>\n<html><head><title>x</title></head><body></body></html>"),
        (.xml, "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict><key>a</key><true/></dict></plist>"),
        (
            .css,
            """
            .card {
              padding: 9px 11px;
              border-radius: 13px;
            }
            .card:hover { color: var(--accent); }
            """
        ),
        (
            .go,
            """
            package main

            import "fmt"

            func main() {
            \tname := "makurip"
            \tfmt.Println(name)
            }
            """
        ),
        (
            .rust,
            """
            use std::collections::HashMap;

            fn main() {
                let mut counts = HashMap::new();
                counts.insert("clip", 1);
                println!("{:?}", counts);
            }
            """
        ),
        (
            .c,
            """
            #include <stdio.h>

            int main(void) {
                printf("hello\\n");
                return 0;
            }
            """
        ),
        (
            .cpp,
            """
            #include <iostream>
            #include <vector>

            int main() {
                std::vector<int> v{1, 2, 3};
                std::cout << v.size() << std::endl;
            }
            """
        ),
        (
            .java,
            """
            public class Main {
                public static void main(String[] args) {
                    System.out.println("hello");
                }
            }
            """
        ),
        (
            .kotlin,
            """
            data class Clip(val id: Int, val text: String)

            fun main() {
                val clip = Clip(1, "hello")
                println(clip.text)
            }
            """
        ),
        (
            .ruby,
            """
            class Clip
              attr_reader :text

              def initialize(text)
                @text = text
              end
            end
            """
        ),
        (.sql, "SELECT id, kind FROM clip WHERE pinned = 1 ORDER BY last_used_at DESC;"),
        (
            .sql,
            """
            CREATE TABLE clip (
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL
            );
            """
        ),
        (
            .yaml,
            """
            name: build
            on:
              push:
                branches: [main]
            jobs:
              test:
                runs-on: macos-14
                steps:
                  - uses: actions/checkout@v4
                  - run: make check
            """
        ),
    ]

    @Test("各言語の代表例", arguments: samples.indices)
    func representative(_ index: Int) {
        let (expected, code) = Self.samples[index]
        #expect(CodeLanguageDetector.detect(code) == expected, "\(expected) の例 \(index)")
    }

    @Test("JSON と JavaScript のオブジェクト（引用符のない key は JSON ではない）")
    func jsonVersusJavaScript() {
        #expect(CodeLanguageDetector.detect(#"{"port": 8080, "host": "localhost"}"#) == .json)
        let js = """
            const config = {
              port: 8080,
              host: "localhost",
            };
            module.exports = config;
            """
        #expect(CodeLanguageDetector.detect(js) == .javascript)
        // 引用符のない key は JSON にしない
        #expect(CodeLanguageDetector.detect("{ a: 1, b: [2] }") != .json)
    }

    @Test("シェルと Python（# のコメントと for はどちらにもある）")
    func shellVersusPython() {
        let shell = """
            # 画像を縮める
            for f in *.png; do
              sips -Z 800 "$f"
            done
            """
        let python = """
            # 画像を数える
            for name in names:
                if name.endswith(".png"):
                    print(name)
            """
        #expect(CodeLanguageDetector.detect(shell) == .shell)
        #expect(CodeLanguageDetector.detect(python) == .python)
    }

    @Test("文章の中の短いコードや手がかりの少ない断片は決めない")
    func tooLittleEvidence() {
        #expect(CodeLanguageDetector.detect("x = 1") == nil)
        #expect(CodeLanguageDetector.detect("Use the map function instead of a for loop.") == nil)
        #expect(CodeLanguageDetector.detect("const を使うと再代入できない") == nil)
        #expect(CodeLanguageDetector.detect("Note: this is important\nTODO: fix later") == nil)
        #expect(CodeLanguageDetector.detect("Select the best option from the list") == nil)
        #expect(CodeLanguageDetector.detect("") == nil)
        #expect(CodeLanguageDetector.detect("   \n  ") == nil)
    }

    @Test("Markdown のコードブロックの言語名と shebang を優先する")
    func fenceAndShebang() {
        #expect(CodeLanguageDetector.detect("```python\nx = 1\n```") == .python)
        #expect(CodeLanguageDetector.detect("```ts\nlet a = 1\n```") == .typescript)
        #expect(CodeLanguageDetector.detect("```\nlet a = 1\n```") == nil)
        #expect(CodeLanguageDetector.detect("#!/usr/bin/env python3\nprint(1)") == .python)
        #expect(CodeLanguageDetector.detect("#!/usr/bin/env node\nfoo()") == .javascript)
        #expect(CodeLanguageDetector.detect("#!/bin/bash\necho hi") == .shell)
    }

    @Test("紛らわしい組（Swift と Kotlin、Go と Swift、C と C++、JS と TS）")
    func confusingPairs() {
        #expect(
            CodeLanguageDetector.detect("fun greet(name: String) {\n    val text = \"hi\"\n    println(text)\n}")
                == .kotlin)
        #expect(
            CodeLanguageDetector.detect("func greet(name: String) -> String {\n    return \"hi \\(name)\"\n}") == .swift
        )
        #expect(
            CodeLanguageDetector.detect(
                "func (s *Server) Start() error {\n\tif err != nil {\n\t\treturn err\n\t}\n\treturn nil\n}")
                == .go)
        #expect(CodeLanguageDetector.detect("#include <stdio.h>\nint main() { printf(\"x\"); return 0; }") == .c)
        #expect(CodeLanguageDetector.detect("#include <iostream>\nint main() { std::cout << 1; }") == .cpp)
        #expect(CodeLanguageDetector.detect("const add = (a, b) => a + b;\nconsole.log(add(1, 2));") == .javascript)
        #expect(
            CodeLanguageDetector.detect("const add = (a: number, b: number): number => a + b;\nconsole.log(add(1, 2));")
                == .typescript)
    }

    @Test("全角の混じったコード・とても長い 1 行・長い文字列でも決まる")
    func edgeCases() {
        #expect(CodeLanguageDetector.detect("let 名前 = \"マクリップ\"\nguard let x = Int(\"1\") else { return }") == .swift)
        let longLine =
            "const values = [" + (0..<3000).map(String.init).joined(separator: ", ") + "];\nconsole.log(values);"
        #expect(CodeLanguageDetector.detect(longLine) == .javascript)
        let manyLines = String(repeating: "def f(x):\n    return x\n\n", count: 2000)
        #expect(CodeLanguageDetector.detect(manyLines) == .python)
        // 途中で切った長い JSON（先頭の形で決める）
        let longJSON = "[" + (0..<2000).map { "{\"id\": \($0)}" }.joined(separator: ",") + "]"
        #expect(CodeLanguageDetector.detect(longJSON) == .json)
    }

    @Test("コードブロックの言語名の別名")
    func fenceTags() {
        #expect(CodeLanguageDetector.detect("```bash\nls\n```") == .shell)
        #expect(CodeLanguageDetector.detect("```yml\na: 1\n```") == .yaml)
        #expect(CodeLanguageDetector.detect("```c++\nint x;\n```") == .cpp)
        #expect(CodeLanguage(fenceTag: "unknown-lang") == nil)
        #expect(CodeLanguage.shell.displayName == "シェル")
    }
}

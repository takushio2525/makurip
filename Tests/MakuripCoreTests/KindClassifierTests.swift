import Foundation
import Testing

@testable import MakuripCore

@Suite("種類の判定")
struct KindClassifierTests {
    @Test(
        "テキスト",
        arguments: [
            "こんにちは。今日は晴れです。",
            "Hello, world",
            "明日の 10 時に打ち合わせ",
            "git について調べた",
            "def という単語の意味",
            "Makurip は履歴をまくる",
            "1. 牛乳\n2. 卵\n3. パン",
        ])
    func plainText(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) == .text)
    }

    @Test("リッチテキスト（RTF・HTML の型がある文章）")
    func richText() {
        #expect(KindClassifier.classify(Fixtures.rtf) == .richText)
        let html = Fixtures.text("太字の文章です", extra: [(PasteboardTypes.html, Fixtures.htmlBytes)])
        #expect(KindClassifier.classify(html) == .richText)
        // 平文なしで RTF だけ
        #expect(KindClassifier.classify(Fixtures.item([(PasteboardTypes.rtf, Fixtures.rtfBytes)])) == .richText)
        // Office のように文章 + プレビュー画像が載っていても、文章があればリッチテキスト
        let office = Fixtures.text(
            "四半期の売上は前年比で伸びた",
            extra: [(PasteboardTypes.rtf, Fixtures.rtfBytes), (PasteboardTypes.png, Fixtures.pngBytes)])
        #expect(KindClassifier.classify(office) == .richText)
    }

    @Test("画像")
    func image() {
        #expect(KindClassifier.classify(Fixtures.png) == .image)
        #expect(KindClassifier.classify(Fixtures.item([(PasteboardTypes.tiff, Fixtures.tiffBytes)])) == .image)
        // PDF だけ（プレビューの選択範囲のコピー）も画像として扱う
        #expect(KindClassifier.classify(Fixtures.item([(PasteboardTypes.pdf, Data("%PDF".utf8))])) == .image)
        // ブラウザの「画像をコピー」: 画像 + 画像の URL の平文
        let browser = Fixtures.text("https://example.com/a.png", extra: [(PasteboardTypes.tiff, Fixtures.tiffBytes)])
        #expect(KindClassifier.classify(browser) == .image)
        // Chrome の「画像をコピー」: 画像 + <img> の HTML（平文なし）
        let chrome = Fixtures.item([
            (PasteboardTypes.png, Fixtures.pngBytes), (PasteboardTypes.html, Data("<img src=x>".utf8)),
        ])
        #expect(KindClassifier.classify(chrome) == .image)
    }

    @Test("ファイル（Finder のコピーはアイコン画像と名前の平文も載る）")
    func file() {
        #expect(KindClassifier.classify(Fixtures.finderFile) == .file)
        let multiple = Fixtures.items([
            [(PasteboardTypes.fileURL, Data("file:///tmp/a.txt".utf8))],
            [(PasteboardTypes.fileURL, Data("file:///tmp/b.txt".utf8))],
        ])
        #expect(KindClassifier.classify(multiple) == .file)
    }

    @Test(
        "URL",
        arguments: [
            "https://github.com/takushio2525/makurip",
            "http://localhost:3000/path?q=1",
            "www.apple.com",
            "mailto:test@example.com",
            "  https://example.com/  \n",
        ])
    func url(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) == .url)
    }

    @Test("URL の型だけ（平文なし）")
    func urlTypeOnly() {
        #expect(KindClassifier.classify(Fixtures.item([(PasteboardTypes.url, Data("https://a.example".utf8))])) == .url)
    }

    @Test("URL ではないもの", arguments: ["https://", "see https://example.com for details", "example", "ftp:"])
    func notURL(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) != .url)
    }

    @Test("色")
    func color() {
        #expect(KindClassifier.classify(Fixtures.color) == .color)
        for literal in ["#FF8800", "#fff", "#11223344", "rgb(255, 128, 0)", "rgba(0,0,0,0.5)", "hsl(120, 50%, 50%)"] {
            #expect(KindClassifier.classify(Fixtures.text(literal)) == .color, "\(literal)")
        }
        #expect(KindClassifier.classify(Fixtures.text("#hashtag")) != .color)
    }

    @Test(
        "コマンド",
        arguments: [
            "$ brew install xcodegen",
            "git status",
            "sudo launchctl kickstart -k gui/501/com.example",
            "npm run dev",
            "cd ~/dev/makurip && swift build",
            "FOO=bar make test",
            "./scripts/build-app.sh --install",
            "docker run --rm -it \\\n  -v $(pwd):/work \\\n  ubuntu bash",
            "git commit -m \"[機能追加] 日本語のメッセージ\"",
            "% ls -la",
            "pip install -r requirements.txt\npython main.py",
            // PS1・oh-my-zsh・root の「# 」（フェーズ3）
            "user@host:~/app$ make build",
            "sample@MacBook-Pro ~ % brew update",
            "[user@host app]$ ls",
            "➜  makurip git:(main) ✗ make check",
            "# apt update\n# apt install -y nginx",
            "$ npm run build\n> makurip@1.0.0 build\n> vite build",
        ])
    func command(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) == .command)
    }

    @Test(
        "コマンドではないもの（見出し・コメントだけ・プロンプトだけ）",
        arguments: ["# Makurip の使い方", "# Install\nRun the script.", "$", "% ", "# install deps\n# run tests"])
    func notCommand(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) != .command)
    }

    @Test(
        "コード",
        arguments: [
            "func greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}",
            "def add(a, b):\n    return a + b\n\nprint(add(1, 2))",
            "const x = foo();",
            "import Foundation\nlet value = 42\nprint(value)",
            "#include <stdio.h>\nint main(void) {\n  printf(\"hi\");\n  return 0;\n}",
            "{\"name\": \"makurip\", \"version\": 1}",
            "[1, 2, 3]",
            "SELECT id, name FROM users WHERE id = 1;",
            "```swift\nlet a = 1\n```",
            "if (a == b) {\n  doSomething();\n}",
            // SQL・YAML・HTML（フェーズ3。言語の判定へ渡すため）
            "select * from users;",
            "UPDATE clip SET pinned = 1 WHERE id = 'x'",
            "name: build\non:\n  push:\n    branches: [main]",
            "- uses: actions/checkout@v4\n- run: make check",
            "<div class=\"card\">\n  <p>本文</p>\n</div>",
            "<?xml version=\"1.0\"?>\n<plist><dict/></plist>",
            "title: こんにちは、世界\nbody:\n  text: 履歴をまくる",
        ])
    func code(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) == .code)
    }

    @Test(
        "コードではないもの（SQL や YAML に似た英文・日本語の「項目: 値」）",
        arguments: [
            "Select the best option from the list", "Note: this is important\nTODO: fix later",
            "名前: 太郎\n場所: 会議室", "Update the table by Friday",
        ])
    func notCode(_ input: String) {
        #expect(KindClassifier.classify(Fixtures.text(input)) != .code)
    }

    @Test("コードを含む Markdown 文書は文章として扱う（限界として明記）")
    func markdownWithFence() {
        let markdown = "手順は次のとおりです。\n\n```bash\nmake test\n```\n\n以上です。"
        #expect(KindClassifier.classify(Fixtures.text(markdown)) == .text)
    }

    @Test("その他（アプリ独自の型だけ）")
    func other() {
        let custom = Fixtures.item([("com.example.private-format", Data([1, 2, 3]))])
        #expect(KindClassifier.classify(custom) == .other)
        #expect(KindClassifier.classify(PasteboardSnapshot(items: [])) == .other)
        // 空白だけの平文
        #expect(KindClassifier.classify(Fixtures.text("   \n ")) == .other)
    }

    @Test("UTF-16 の平文も読める")
    func utf16() {
        let data = "git status".data(using: .utf16)!
        let snapshot = Fixtures.item([(PasteboardTypes.utf16ExternalPlainText, data)])
        #expect(KindClassifier.classify(snapshot) == .command)
    }
}

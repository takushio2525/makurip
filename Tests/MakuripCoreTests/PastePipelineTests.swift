import AppKit
import Foundation
import Testing

@testable import MakuripCore

/// 貼り付けのときに書き戻す中身。保存した履歴は変えず、コマンドのときだけ文字の型からプロンプトを外す
@Suite("貼り付けの中身（プロンプトを外す）")
@MainActor
struct PastePipelineTests {
    static let command = "$ brew install swiftlint\n$ swiftlint --fix"
    static let stripped = "brew install swiftlint\nswiftlint --fix"
    static let rtf = Data(#"{\rtf1\ansi {\b $ brew install swiftlint}}"#.utf8)
    static let html = Data("<pre>$ brew install swiftlint</pre>".utf8)
    static let custom = ("com.example.terminal.private", Data([1, 2, 3]))

    /// ターミナルのコピーに近い形（平文・UTF-16・RTF・HTML・独自の型）
    static func terminalCopy() -> PasteboardSnapshot {
        Fixtures.item([
            (PasteboardTypes.utf8PlainText, Data(command.utf8)),
            (PasteboardTypes.utf16ExternalPlainText, Data([0xFF, 0xFE]) + command.data(using: .utf16LittleEndian)!),
            (PasteboardTypes.rtf, rtf),
            (PasteboardTypes.html, html),
            custom,
        ])
    }

    func text(_ snapshot: PasteboardSnapshot, _ type: String) -> String? {
        guard let data = snapshot.firstData(for: type) else { return nil }
        return PastePipeline.TextEncoding(type: type, data: data)?.decode(data)
    }

    @Test("ふつうに貼る: 文字の型だけ外れ、RTF・HTML・独自の型と並びは元のまま")
    func normal() {
        let stored = Self.terminalCopy()
        let prepared = PastePipeline.prepare(stored, kind: .command, mode: .normal)
        #expect(text(prepared, PasteboardTypes.utf8PlainText) == Self.stripped)
        #expect(text(prepared, PasteboardTypes.utf16ExternalPlainText) == Self.stripped)
        // UTF-16 の BOM（FF FE）を保つ
        #expect(prepared.firstData(for: PasteboardTypes.utf16ExternalPlainText)?.prefix(2) == Data([0xFF, 0xFE]))
        #expect(prepared.firstData(for: PasteboardTypes.rtf) == Self.rtf)
        #expect(prepared.firstData(for: PasteboardTypes.html) == Self.html)
        #expect(prepared.firstData(for: Self.custom.0) == Self.custom.1)
        #expect(prepared.allTypes == stored.allTypes)
        // 元の履歴は変わらない（値型の写し）
        #expect(text(stored, PasteboardTypes.utf8PlainText) == Self.command)
    }

    @Test("コピーだけ: ふつうと同じく外す")
    func copyOnly() {
        let prepared = PastePipeline.prepare(Self.terminalCopy(), kind: .command, mode: .copyOnly)
        #expect(text(prepared, PasteboardTypes.utf8PlainText) == Self.stripped)
    }

    @Test("プレーンテキストで貼る: 文字の型だけにし、プロンプトは外さない（元のまま貼る逃げ道）")
    func plainText() {
        let prepared = PastePipeline.prepare(Self.terminalCopy(), kind: .command, mode: .plainText)
        #expect(prepared.allTypes == [PasteboardTypes.utf8PlainText, PasteboardTypes.utf16ExternalPlainText])
        #expect(text(prepared, PasteboardTypes.utf8PlainText) == Self.command)
    }

    @Test("コマンド以外（コード・テキスト・種類が分からない）は 1 バイトも変えない")
    func otherKinds() {
        let stored = Self.terminalCopy()
        for kind in [ClipKind.code, .text, .richText, nil] {
            #expect(PastePipeline.prepare(stored, kind: kind, mode: .normal) == stored)
        }
    }

    @Test("プロンプトのないコマンドはそのまま（バイト列も同じ）")
    func noPrompt() {
        let stored = Fixtures.text("git status\nnpm test", extra: [(PasteboardTypes.rtf, Self.rtf)])
        #expect(PastePipeline.prepare(stored, kind: .command, mode: .normal) == stored)
    }

    @Test("複数の項目・BOM のない UTF-16・ビッグエンディアンの BOM")
    func encodingsAndItems() {
        let stored = Fixtures.items([
            [(PasteboardTypes.utf16PlainText, "$ ls".data(using: .utf16LittleEndian)!)],
            [(PasteboardTypes.utf16ExternalPlainText, Data([0xFE, 0xFF]) + "% pwd".data(using: .utf16BigEndian)!)],
        ])
        let prepared = PastePipeline.strippingPrompts(stored)
        #expect(prepared.items[0].data(for: PasteboardTypes.utf16PlainText) == "ls".data(using: .utf16LittleEndian))
        #expect(
            prepared.items[1].data(for: PasteboardTypes.utf16ExternalPlainText)
                == Data([0xFE, 0xFF]) + "pwd".data(using: .utf16BigEndian)!)
    }

    @Test("名前付きペーストボードに書いて読み直すと、文字は外れていて、ほかの型は元のまま")
    func roundTripThroughPasteboard() {
        let board = PrivatePasteboard()
        let prepared = PastePipeline.prepare(Self.terminalCopy(), kind: .command, mode: .normal)
        PasteboardWriter.write(prepared, to: board.pasteboard)

        #expect(board.pasteboard.string(forType: .string) == Self.stripped)
        guard case .snapshot(let read, _) = PasteboardReader.read(board.pasteboard, maxRepresentationBytes: 1 << 20)
        else {
            Issue.record("除外された")
            return
        }
        #expect(text(read, PasteboardTypes.utf8PlainText) == Self.stripped)
        #expect(read.firstData(for: PasteboardTypes.rtf) == Self.rtf)
        #expect(read.firstData(for: PasteboardTypes.html) == Self.html)
        #expect(read.firstData(for: Self.custom.0) == Self.custom.1)
    }
}

/// 一覧から貼るときの宛先（#27）。Makurip 自身の窓から一覧を開いたら、前に使った別のアプリを宛先にしない
@Suite("貼り付けの宛先")
struct PasteTargetTests {
    let own: pid_t = 500

    @Test("前面がほかのアプリなら、そのアプリが宛先")
    func otherApp() {
        #expect(PasteTarget.pid(frontmost: 700, own: own) == 700)
    }

    @Test("前面が Makurip 自身（定型文の窓・設定画面）なら宛先なし（前に使ったアプリへ ⌘V を送らない）")
    func ownWindow() {
        #expect(PasteTarget.pid(frontmost: own, own: own) == nil)
    }

    @Test("前面のアプリが分からないときも宛先なし")
    func unknown() {
        #expect(PasteTarget.pid(frontmost: nil, own: own) == nil)
    }
}

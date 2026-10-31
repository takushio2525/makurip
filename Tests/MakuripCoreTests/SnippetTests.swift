import AppKit
import Foundation
import Testing

@testable import MakuripCore

/// 定型文の登録・編集・削除・並べ替えと検証（`SnippetCollection`）
@Suite("定型文の登録・編集")
struct SnippetCollectionTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)

    @Test("足すと末尾に入り、位置を指定すればそこに入る")
    func add() throws {
        var list = SnippetCollection()
        let a = try list.add(SnippetDraft(name: "あいさつ", abbreviation: ";aisatsu", body: "いつもお世話に"), now: t0)
        let b = try list.add(SnippetDraft(name: "日付", body: "{{日付}}"), now: t0)
        let c = try list.add(SnippetDraft(name: "先頭", body: "x"), at: 0, now: t0)
        #expect(list.snippets.map(\.id) == [c.id, a.id, b.id])
        #expect(a.createdAt == t0 && a.updatedAt == t0)
        #expect(a.abbreviation == ";aisatsu")
        // 範囲の外の位置は端に寄せる
        let d = try list.add(SnippetDraft(body: "末尾"), at: 99, now: t0)
        #expect(list.snippets.last?.id == d.id)
    }

    @Test("同じ名前の定型文を何件でも登録できる（id で見分ける）")
    func duplicateNames() throws {
        var list = SnippetCollection()
        let a = try list.add(SnippetDraft(name: "返信", body: "了解しました"), now: t0)
        let b = try list.add(SnippetDraft(name: "返信", body: "承知しました"), now: t0)
        #expect(a.id != b.id)
        #expect(list.snippets.filter { $0.name == "返信" }.count == 2)
    }

    @Test("書き換えると更新時刻が進み、中身が同じなら何も変えない")
    func update() throws {
        var list = SnippetCollection()
        let a = try list.add(SnippetDraft(name: "a", body: "1"), now: t0)
        let same = try list.update(id: a.id, with: SnippetDraft(name: "a", body: "1"), now: t1)
        #expect(same.updatedAt == t0)
        let changed = try list.update(id: a.id, with: SnippetDraft(name: "b", abbreviation: ";b", body: "2"), now: t1)
        #expect(changed.name == "b" && changed.abbreviation == ";b" && changed.body == "2")
        #expect(changed.createdAt == t0 && changed.updatedAt == t1)
        #expect(list.snippet(id: a.id) == changed)
    }

    @Test("消す・ない id は理由付きで拒否する")
    func remove() throws {
        var list = SnippetCollection()
        let a = try list.add(SnippetDraft(body: "1"), now: t0)
        let b = try list.add(SnippetDraft(body: "2"), now: t0)
        try list.remove(id: a.id)
        #expect(list.snippets.map(\.id) == [b.id])
        #expect(throws: SnippetError.self) { try list.remove(id: a.id) }
        #expect(throws: SnippetError.self) { try list.update(id: a.id, with: SnippetDraft(body: "x"), now: t1) }
        #expect(throws: SnippetError.self) { try list.move(id: a.id, to: 0) }
    }

    @Test("並べ替え: 位置へ動かす・1 つずつ上下・端では動かない")
    func move() throws {
        var list = SnippetCollection()
        let ids = try (0..<4).map { try list.add(SnippetDraft(body: "\($0)"), now: t0).id }
        try list.move(id: ids[3], to: 0)
        #expect(list.snippets.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
        #expect(try list.move(id: ids[3], by: -1) == false)
        #expect(try list.move(id: ids[3], by: 1))
        #expect(list.snippets.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
        #expect(try list.move(id: ids[2], by: 1) == false)
        try list.move(id: ids[0], to: 99)
        #expect(list.snippets.last?.id == ids[0])
    }

    @Test("本文が空・空白と改行だけ・長すぎるものは拒否する")
    func rejectsBadBody() {
        for body in ["", "   ", "\n\n\t"] {
            #expect(throws: SnippetError(.body, "本文が空。貼りたい文を書く")) {
                try SnippetCollection.normalize(SnippetDraft(name: "x", body: body)).get()
            }
        }
        let long = String(repeating: "あ", count: SnippetCollection.maxBodyLength + 1)
        let result = SnippetCollection.normalize(SnippetDraft(body: long))
        guard case .failure(let error) = result else {
            Issue.record("長すぎる本文が通った")
            return
        }
        #expect(error.field == .body)
        // ちょうど上限なら通る
        let limit = String(repeating: "a", count: SnippetCollection.maxBodyLength)
        #expect((try? SnippetCollection.normalize(SnippetDraft(body: limit)).get()) != nil)
    }

    @Test("名前が空なら本文の最初の空でない行から作る（長ければ切る）。改行は空白にする")
    func derivesName() throws {
        let a = try SnippetCollection.normalize(SnippetDraft(body: "\n\n  ## 概要\n本文")).get()
        #expect(a.name == "## 概要")
        let long = String(repeating: "長", count: 60)
        let b = try SnippetCollection.normalize(SnippetDraft(body: long)).get()
        #expect(b.name == String(repeating: "長", count: 40) + "…")
        let c = try SnippetCollection.normalize(SnippetDraft(name: " 1 行目\n2 行目 ", body: "x")).get()
        #expect(c.name == "1 行目 2 行目")
        // 本文の末尾の改行はそのまま残す（意図した改行として貼る）
        let d = try SnippetCollection.normalize(SnippetDraft(name: "n", body: "末尾に改行\n")).get()
        #expect(d.body == "末尾に改行\n")
    }

    @Test("略語は前後の空白を除き、途中の空白・改行と長すぎるものは拒否する")
    func abbreviation() throws {
        #expect(
            try SnippetCollection.normalize(SnippetDraft(abbreviation: "  ;date ", body: "x")).get().abbreviation
                == ";date")
        #expect(throws: SnippetError.self) {
            try SnippetCollection.normalize(SnippetDraft(abbreviation: "; date", body: "x")).get()
        }
        #expect(throws: SnippetError.self) {
            try SnippetCollection.normalize(
                SnippetDraft(abbreviation: String(repeating: "a", count: 33), body: "x")
            ).get()
        }
        #expect(throws: SnippetError.self) {
            try SnippetCollection.normalize(SnippetDraft(name: String(repeating: "n", count: 101), body: "x")).get()
        }
    }

    @Test("数百件でも足せて、上限を超えたら理由付きで拒否する")
    func manySnippets() throws {
        var list = SnippetCollection()
        for i in 0..<500 { try list.add(SnippetDraft(name: "定型文 \(i)", body: "本文 \(i)"), now: t0) }
        #expect(list.count == 500)
        var full = SnippetCollection(
            (0..<SnippetCollection.maxCount).map {
                Snippet(id: UUID(), name: "\($0)", abbreviation: "", body: "b", createdAt: t0, updatedAt: t0)
            })
        #expect(throws: SnippetError.self) { try full.add(SnippetDraft(body: "もう 1 件"), now: t0) }
    }

    @Test("検索の対象は名前・略語・本文と「定型文」（ローマ字・かなでも引ける）")
    func searchHaystack() {
        let snippet = Snippet(
            id: UUID(), name: "あいさつ（社外）", abbreviation: ";aisatsu", body: "いつもお世話になっております。", createdAt: t0,
            updatedAt: t0)
        let haystack = snippet.searchHaystack
        #expect(SearchText.parse("aisatsu").matches(normalized: haystack))
        #expect(SearchText.parse("アイサツ").matches(normalized: haystack))
        #expect(SearchText.parse("itsumo").matches(normalized: haystack))
        #expect(SearchText.parse("定型文").matches(normalized: haystack))
        #expect(!SearchText.parse("zzzz").matches(normalized: haystack))
    }
}

/// 差し込みの置き換え（`SnippetTemplate`）。試作の 4 つ（日付・クリップボード・言語・カーソル）
@Suite("定型文の置き換え")
struct SnippetTemplateTests {
    /// 2026-10-31 15:30（日本時間）
    let now = Date(timeIntervalSince1970: 1_793_428_200)
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func expand(
        _ body: String, clipboard: String? = nil, language: CodeLanguage? = nil, format: SnippetDateFormat = .slash
    )
        -> SnippetTemplate.Expansion
    {
        SnippetTemplate.expand(
            body,
            context: .init(
                now: now, timeZone: tokyo, dateFormat: format, clipboardText: clipboard, language: language))
    }

    @Test("試作の定型文 6 件が試作どおりに置き換わる")
    func prototypeSnippets() {
        #expect(expand("{{日付}}").text == "2026/10/31")
        #expect(
            expand("いつもお世話になっております。\n{{カーソル}}\nよろしくお願いいたします。").text
                == "いつもお世話になっております。\n\nよろしくお願いいたします。")
        #expect(
            expand("```{{言語}}\n{{クリップボード}}\n```", clipboard: "let x = 1", language: .swift).text
                == "```swift\nlet x = 1\n```")
        #expect(
            expand("次のコードをレビューしてください。\n\n{{クリップボード}}", clipboard: "print(1)").text
                == "次のコードをレビューしてください。\n\nprint(1)")
        #expect(expand("承知しました。").text == "承知しました。")
    }

    @Test("日付の書き方 3 つ。月と日は 2 桁（和暦の設定でも西暦）")
    func dateFormats() {
        let jan5 = Date(timeIntervalSince1970: 1_799_074_800)  // 2027-01-05 00:00 JST
        #expect(SnippetDateFormat.slash.format(jan5, timeZone: tokyo) == "2027/01/05")
        #expect(SnippetDateFormat.hyphen.format(jan5, timeZone: tokyo) == "2027-01-05")
        #expect(SnippetDateFormat.japanese.format(jan5, timeZone: tokyo) == "2027年1月5日")
        #expect(expand("{{日付}}", format: .hyphen).text == "2026-10-31")
        #expect(expand("{{日付}}", format: .japanese).text == "2026年10月31日")
    }

    @Test("日付は貼った時刻のその場所の日付（日付が変わる直前・直後）")
    func dateBoundary() {
        let beforeMidnight = Date(timeIntervalSince1970: 1_793_458_799)  // 2026-10-31 23:59:59 JST
        let afterMidnight = beforeMidnight.addingTimeInterval(1)
        #expect(SnippetDateFormat.slash.format(beforeMidnight, timeZone: tokyo) == "2026/10/31")
        #expect(SnippetDateFormat.slash.format(afterMidnight, timeZone: tokyo) == "2026/11/01")
        // 同じ瞬間でも UTC ではまだ 31 日の昼
        #expect(SnippetDateFormat.slash.format(afterMidnight, timeZone: TimeZone(identifier: "UTC")!) == "2026/10/31")
    }

    @Test("履歴が空ならクリップボードは空・言語が決まらなければ言語も空")
    func emptyClipboard() {
        #expect(expand("[{{クリップボード}}]").text == "[]")
        #expect(expand("```{{言語}}\n```").text == "```\n```")
    }

    @Test("カーソル: 文字としては消し、そこから末尾までの長さ（UTF-16）を返す。2 つ目からは消すだけ")
    func cursor() {
        let a = expand("前{{カーソル}}後ろ")
        #expect(a.text == "前後ろ")
        #expect(a.cursorOffsetFromEnd == 2)
        let b = expand("{{カーソル}}😀あ{{カーソル}}い")
        #expect(b.text == "😀あい")
        #expect(b.cursorOffsetFromEnd == "😀あい".utf16.count)
        #expect(expand("末尾{{カーソル}}").cursorOffsetFromEnd == 0)
        #expect(expand("なし").cursorOffsetFromEnd == nil)
        // 差し込みの後ろの長さは置き換えた後の文字で数える
        #expect(expand("{{カーソル}}{{日付}}").cursorOffsetFromEnd == "2026/10/31".utf16.count)
    }

    @Test("壊れた記法・知らない名前・改行入りは書いたとおりに残す")
    func brokenSyntax() {
        #expect(expand("{{日付").text == "{{日付")
        #expect(expand("日付}}").text == "日付}}")
        #expect(expand("{{名前}}さん").text == "{{名前}}さん")
        #expect(expand("{{}}").text == "{{}}")
        #expect(expand("{{日\n付}}").text == "{{日\n付}}")
        #expect(expand("{日付}").text == "{日付}")
        #expect(expand("{{{日付}}}").text == "{2026/10/31}")
        #expect(expand("{{{{日付}}").text == "{{2026/10/31")
        #expect(expand("{{名前}} {{日付}}").text == "{{名前}} 2026/10/31")
    }

    @Test("中の前後の空白（全角も）は無視する")
    func spacesInside() {
        #expect(expand("{{ 日付 }}").text == "2026/10/31")
        #expect(expand("{{\u{3000}日付\u{3000}}}").text == "2026/10/31")
    }

    @Test("差し込みの一覧と、文字と差し込みへの分け方（画面の札に使う）")
    func segments() {
        #expect(
            SnippetTemplate.segments("a{{日付}}b{{x}}") == [
                .text("a"), .placeholder(.date), .text("b{{x}}"),
            ])
        #expect(SnippetTemplate.placeholders(in: "{{日付}}{{カーソル}}{{日付}}") == [.date, .cursor])
        #expect(SnippetTemplate.segments("") == [])
    }

    @Test("とても長い本文（10 万文字・差し込み多数）でもすぐ終わる")
    func longBody() {
        let body = String(repeating: "あいうえお{{日付}}\n", count: 8000)
        let start = Date()
        let result = expand(body)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(result.text.contains("{{") == false)
        #expect(result.text.components(separatedBy: "2026/10/31").count - 1 == 8000)
    }
}

/// 差し込みに使う履歴の選び方と、貼る中身・文字カーソルの位置（`SnippetClipboard` / `SnippetPaste`）
@Suite("定型文の貼り付け")
struct SnippetPasteTests {
    func item(_ kind: ClipKind, flags: Set<ClipFlag> = []) -> ClipItem {
        ClipItem(
            id: UUID(), contentHash: UUID().uuidString, kind: kind, copyMethod: .keyboard, source: nil, sourceURL: nil,
            createdAt: Date(), lastUsedAt: Date(), copyCount: 1, isPinned: false, flags: flags, previewText: "x",
            totalBytes: 1, pasteboardItemCount: 1)
    }

    @Test("新しい順で最初の、文字として差し込める・秘密っぽくない項目を使う")
    func source() {
        let image = item(.image)
        let secret = item(.text, flags: [.secretLikely])
        let file = item(.file)
        let code = item(.code)
        let text = item(.text)
        #expect(SnippetClipboard.source(in: [image, secret, file, code, text])?.id == code.id)
        #expect(SnippetClipboard.source(in: [image, file]) == nil)
        #expect(SnippetClipboard.source(in: []) == nil)
    }

    @Test("言語: コードは中身から、コマンドはシェル、文章は空")
    func language() {
        #expect(
            SnippetClipboard.language(
                of: "import SwiftUI\nstruct A: View {\n  var body: some View { Text(\"a\") }\n}", kind: .code) == .swift
        )
        #expect(SnippetClipboard.language(of: "npm run build", kind: .command) == .shell)
        #expect(SnippetClipboard.language(of: "こんにちは", kind: .text) == nil)
    }

    @Test("貼る中身は文字の型だけ。名前付きペーストボードに書いて読み直すと置き換え済みの文字")
    @MainActor
    func writesPlainText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("makurip.test.snippet.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let expansion = SnippetTemplate.expand(
            "```{{言語}}\n{{クリップボード}}\n```\n{{日付}}",
            context: .init(
                now: Date(timeIntervalSince1970: 1_793_428_200), timeZone: TimeZone(identifier: "Asia/Tokyo")!,
                clipboardText: "print(1)", language: .python))
        PasteboardWriter.write(SnippetPaste.snapshot(for: expansion.text), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "```python\nprint(1)\n```\n2026/10/31")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.types?.contains(.rtf) == false)
    }

    @Test("文字カーソル: 貼った文字のちょうど後ろにあるときだけ、差し込みの位置へ動かす")
    func cursorTarget() {
        let before = TextProbe(
            selection: AXTextRange(location: 10, length: 0), characterCount: 20, selectionSettable: true)
        let after = TextProbe(
            selection: AXTextRange(location: 18, length: 0), characterCount: 28, selectionSettable: true)
        #expect(
            SnippetPaste.cursorTarget(before: before, after: after, insertedLength: 8, offsetFromEnd: 3)
                == AXTextRange(location: 15, length: 0))
        // 選択していた文字を置き換えたとき（前の選択の先頭から数える）
        let selected = TextProbe(
            selection: AXTextRange(location: 10, length: 5), characterCount: 20, selectionSettable: true)
        #expect(
            SnippetPaste.cursorTarget(before: selected, after: after, insertedLength: 8, offsetFromEnd: 3)
                == AXTextRange(location: 15, length: 0))
        // 長さが変わった（改行の変換・自動の字下げ）・読めない・書けない・カーソルなし・末尾なら動かさない
        let moved = TextProbe(
            selection: AXTextRange(location: 19, length: 0), characterCount: 29, selectionSettable: true)
        #expect(SnippetPaste.cursorTarget(before: before, after: moved, insertedLength: 8, offsetFromEnd: 3) == nil)
        #expect(SnippetPaste.cursorTarget(before: nil, after: after, insertedLength: 8, offsetFromEnd: 3) == nil)
        #expect(SnippetPaste.cursorTarget(before: before, after: nil, insertedLength: 8, offsetFromEnd: 3) == nil)
        let readOnly = TextProbe(selection: after.selection, characterCount: 28, selectionSettable: false)
        #expect(SnippetPaste.cursorTarget(before: before, after: readOnly, insertedLength: 8, offsetFromEnd: 3) == nil)
        #expect(SnippetPaste.cursorTarget(before: before, after: after, insertedLength: 8, offsetFromEnd: nil) == nil)
        #expect(SnippetPaste.cursorTarget(before: before, after: after, insertedLength: 8, offsetFromEnd: 0) == nil)
        let selectingAfter = TextProbe(
            selection: AXTextRange(location: 18, length: 2), characterCount: 28, selectionSettable: true)
        #expect(
            SnippetPaste.cursorTarget(before: before, after: selectingAfter, insertedLength: 8, offsetFromEnd: 3) == nil
        )
    }
}

/// 設定の「日付の書き方」（`snippetDateFormat`）。画面・CLI・ファイルが同じ検証を通る
@Suite("定型文の設定")
struct SnippetSettingsTests {
    @Test("既定は 2026/10/31 の形。3 つの値（ラベルでも）だけ通り、ほかは理由付きで拒否する")
    func dateFormat() throws {
        #expect(AppSettings.default.snippetDateFormat == .slash)
        #expect(SettingsSchema.defaultValue(SettingID.snippetDateFormat) == .string("slash"))
        let hyphen = try SettingsSchema.applying(
            .string("hyphen"), to: SettingID.snippetDateFormat, in: .default, keyConflicts: .reject
        ).get()
        #expect(hyphen.settings.snippetDateFormat == .hyphen)
        let byLabel = try SettingsSchema.applying(
            .string("2026年10月31日"), to: SettingID.snippetDateFormat, in: .default, keyConflicts: .reject
        ).get()
        #expect(byLabel.settings.snippetDateFormat == .japanese)
        guard
            case .failure(let error) = SettingsSchema.applying(
                .string("yyyy.MM.dd"), to: SettingID.snippetDateFormat, in: .default, keyConflicts: .reject)
        else {
            Issue.record("知らない書き方が通った")
            return
        }
        #expect(error.message.contains("slash"))
        // ファイルには既定と違うときだけ書き、読み直すと同じ
        let data = SettingsFile.encode(hyphen.settings)
        #expect(String(decoding: data, as: UTF8.self).contains("\"snippetDateFormat\" : \"hyphen\""))
        #expect(SettingsFile.decode(data).settings.snippetDateFormat == .hyphen)
        #expect(!String(decoding: SettingsFile.encode(.default), as: UTF8.self).contains("snippetDateFormat"))
    }

    @Test("定型文のキー（⌘S・⌘⇧S）は既定でほかと重ならず、キーの決まりに通る")
    func keys() {
        let keymap = Keymap.default
        #expect(keymap.primary(.snippets)?.displayString == "⌘S")
        #expect(keymap.primary(.editSnippet)?.displayString == "⇧⌘S")
        #expect(keymap.conflicts(involving: .snippets).isEmpty)
        #expect(keymap.conflicts(involving: .editSnippet).isEmpty)
        for action in [KeyAction.snippets, .editSnippet] {
            #expect(action.scope == .panel)
            for combo in action.defaultCombos { #expect(KeyRules.problem(with: combo, for: action) == nil) }
        }
        #expect(keymap.action(for: KeyStroke(keyCode: 1, modifiers: .command))?.action == .snippets)
        #expect(keymap.action(for: KeyStroke(keyCode: 1, modifiers: [.command, .shift]))?.action == .editSnippet)
    }
}

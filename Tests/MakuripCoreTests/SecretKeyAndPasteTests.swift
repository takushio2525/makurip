import AppKit
import Foundation
import Testing

@testable import MakuripCore

@Suite("隠した内容の表示のキー（押している間だけ効く）")
struct RevealKeyTests {
    @Test("既定は ⌥ を押している間。ほかの修飾キーが一緒でも効き、キーを押しても操作としては引かない")
    func defaultHold() {
        let map = Keymap.default
        #expect(map.combos(for: .reveal) == [KeyCombo(.hold, .option)])
        #expect(map.primary(.reveal)?.displayString == "⌥")
        #expect(map.isHeld(.reveal, modifiers: .option))
        #expect(map.isHeld(.reveal, modifiers: [.option, .shift]))
        #expect(!map.isHeld(.reveal, modifiers: []))
        #expect(!map.isHeld(.reveal, modifiers: .command))
        // ⌥ と一緒に押したキー（⌥V など）は、表示の操作として引かない
        #expect(map.action(for: KeyStroke(keyCode: 9, modifiers: .option))?.action != .reveal)
        #expect(map.conflicts().isEmpty)
    }

    @Test("文字表現: ⌥・alt・option・⌘ を読み、⌥ と書く。修飾キー 2 つは押している間のキーにできない")
    func text() throws {
        for text in ["⌥", "alt", "Option", "opt"] {
            #expect(try KeyComboText.parse(text).get() == KeyCombo(.hold, .option), "\(text)")
        }
        #expect(try KeyComboText.parse("⌘").get() == KeyCombo(.hold, .command))
        #expect(KeyComboText.format(KeyCombo(.hold, .option)) == "⌥")
        #expect(KeyComboText.parse("⌥⌘") == .failure(.missingKey))
    }

    @Test("決まり: 表示の操作は修飾キー 1 つだけ。ほかの操作に修飾キーだけのキーは使えない")
    func rules() {
        #expect(KeyRules.problem(with: KeyCombo(.hold, .option), for: .reveal) == nil)
        #expect(KeyRules.problem(with: KeyCombo(.hold, .shift), for: .reveal) == nil)
        #expect(KeyRules.problem(with: KeyCombo(.code(9), .option), for: .reveal) != nil)
        #expect(KeyRules.problem(with: KeyCombo(.hold, .option), for: .paste) != nil)
        #expect(KeyRules.problem(with: KeyCombo(.hold, .option), for: .openHistory) != nil)
    }

    @Test("CLI と同じ検証: keys.reveal に ⌘ を入れられ、⌘C は入れられない")
    func schema() throws {
        let id = SettingID.keys(.reveal)
        let change = try SettingsSchema.applying(.string("cmd"), to: id, in: .default, keyConflicts: .reject).get()
        #expect(change.settings.keymap.combos(for: .reveal) == [KeyCombo(.hold, .command)])
        #expect(change.value == .array([.string("⌘")]))
        let rejected = SettingsSchema.applying(.string("⌘C"), to: id, in: .default, keyConflicts: .reject)
        #expect((try? rejected.get()) == nil)
    }
}

@Suite("秘密を貼るときの印")
struct SecretPasteTests {
    @Test("秘密は ConcealedType の印を足して書く（ほかのクリップボード履歴アプリに記録させない）。中身と並びは元のまま")
    func concealedMarker() {
        let stored = Fixtures.text("value", extra: [(PasteboardTypes.rtf, Fixtures.rtfBytes)])
        for mode in [PasteMode.normal, .plainText, .copyOnly] {
            let prepared = PastePipeline.prepare(stored, kind: .text, mode: mode, secret: true)
            #expect(prepared.allTypes.last == PasteboardMarkers.concealed)
            #expect(prepared.firstData(for: PasteboardTypes.utf8PlainText) == Data("value".utf8))
        }
        let normal = PastePipeline.prepare(stored, kind: .text, mode: .normal)
        #expect(!normal.allTypes.contains(PasteboardMarkers.concealed))
        // 候補窓の長さの数え方は変わらない（印は空のデータ）
        let candidate = PastePipeline.candidatePaste(stored, kind: .text, secret: true)
        #expect(candidate.content.textLength == 5)
    }

    @Test("印を付けて書いたものは、Makurip 自身も新しい履歴にしない")
    func ownWriteIsExcluded() {
        let prepared = PastePipeline.prepare(Fixtures.text("value"), kind: .text, mode: .normal, secret: true)
        #expect(PasteboardMarkers.containsExcludedMarker(prepared.allTypes))
    }
}

/// 定型文の秘密（#29 L3）。AI の口の一覧と同じく本文か名前で判定し、貼るときは ConcealedType を足す
@Suite("定型文の秘密")
struct SnippetSecretTests {
    func snippet(name: String = "", abbreviation: String = "", body: String) -> Snippet {
        Snippet(
            id: UUID(), name: name, abbreviation: abbreviation, body: body, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("秘密の本文の定型文を貼るときは ConcealedType を足す。ふつうの本文には足さない")
    func pasteMarksConcealed() {
        let secret = SnippetPaste.snapshot(for: "トークン: " + FakeSecret.github)
        #expect(secret.allTypes.contains(PasteboardMarkers.concealed))
        #expect(secret.items.count == 1)
        #expect(secret.items[0].representations.first?.type == PasteboardTypes.utf8PlainText, "文字の型は先頭のまま")
        let plain = SnippetPaste.snapshot(for: "いつもお世話になっております。")
        #expect(!plain.allTypes.contains(PasteboardMarkers.concealed))
        #expect(plain.allTypes == [PasteboardTypes.utf8PlainText])
    }

    @Test("秘密っぽいかは本文か名前で決める（AI の口の一覧と同じ）。伏せ字の写しに本当の値は入らない")
    func detectionAndMask() {
        #expect(!snippet(name: "あいさつ", body: "いつもお世話になっております。").isSecretLikely)
        let byBody = snippet(name: "GitHub", abbreviation: ";gh", body: "token: " + FakeSecret.github)
        #expect(byBody.isSecretLikely)
        let byName = snippet(name: FakeSecret.github, body: "ふつうの本文")
        #expect(byName.isSecretLikely)
        for item in [byBody, byName] {
            let masked = item.masked
            #expect(![masked.name, masked.abbreviation, masked.body].joined().contains(FakeSecret.github))
            #expect(masked.id == item.id)
        }
        #expect(byBody.masked.name == "GitHub" && byBody.masked.abbreviation == ";gh", "秘密でない名前・略語はそのまま")
        #expect(byBody.masked.body.hasPrefix("token: "))
    }

    @Test("秘密の定型文の検索の文字列: 本当の値では引けず、見えている接頭辞・名前・「秘密」で引ける")
    func searchHaystack() {
        let item = snippet(name: "GitHub", body: "token: " + FakeSecret.github)
        let haystack = item.maskedSearchHaystack
        let hidden = String(FakeSecret.github.dropFirst(6).prefix(12))
        #expect(!SearchText.parse(hidden).matches(normalized: haystack))
        for query in ["ghp_", "github", "秘密", "ひみつ", "himitsu", "定型文"] {
            #expect(SearchText.parse(query).matches(normalized: haystack), "\(query) で引けない")
        }
    }
}

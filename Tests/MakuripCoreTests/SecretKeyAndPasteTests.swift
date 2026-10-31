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

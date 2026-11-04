import Foundation
import Testing

@testable import MakuripCore

/// 一覧のカードの右クリックのメニュー（#38）。並び・出し分け・キーの表記。中身は自作の架空の文字だけ
@Suite("カードの右クリックのメニュー")
struct CardMenuModelTests {
    func item(
        _ kind: ClipKind, preview: String? = "架空の文字", sourceURL: String? = nil, pinned: Bool = false,
        secret: Bool = false
    ) -> ClipItem {
        ClipItem(
            id: UUID(), contentHash: "h", kind: kind, copyMethod: .keyboard, source: nil, sourceURL: sourceURL,
            createdAt: Date(), lastUsedAt: Date(), copyCount: 1, isPinned: pinned,
            flags: secret ? [.secretLikely] : [], previewText: preview, totalBytes: 10, pasteboardItemCount: 1)
    }

    func actions(_ entries: [CardMenuModel.Entry]) -> [KeyAction] {
        entries.compactMap { if case .item(let item) = $0 { item.action } else { nil } }
    }

    func titles(_ entries: [CardMenuModel.Entry]) -> [String] {
        entries.compactMap { if case .item(let item) = $0 { item.title } else { nil } }
    }

    /// 区切りを「|」にした並び（区切りの位置も確かめる）
    func layout(_ entries: [CardMenuModel.Entry]) -> String {
        entries.map { if case .item(let item) = $0 { item.action.rawValue } else { "|" } }.joined(separator: " ")
    }

    @Test("文字とページのある項目: 貼る 3 つ → 項目の操作 → 削除の順に、区切りを挟んで並ぶ")
    func fullOrder() {
        let entries = CardMenuModel.entries(for: item(.richText, sourceURL: "https://example.com/page"))
        #expect(
            layout(entries) == "paste pastePlain copyOnly | pin editSnippet look source | delete")
        #expect(
            titles(entries) == [
                "貼り付け", "文字だけで貼り付け", "クリップボードにコピー", "ピン留め", "定型文に登録…", "プレビュー", "コピー元のページを開く",
                "履歴から削除",
            ])
    }

    @Test("どの項目にも、貼り付け・クリップボードにコピー・ピン留め・プレビュー・削除は出る")
    func alwaysPresent() {
        for kind in ClipKind.allCases {
            for secret in [false, true] {
                let shown = Set(actions(CardMenuModel.entries(for: item(kind, secret: secret))))
                #expect(shown.isSuperset(of: [.paste, .copyOnly, .togglePin, .preview, .delete]), "\(kind)")
            }
        }
    }

    @Test("文字の有無: 画像とファイルには「文字だけで貼り付け」と「定型文に登録」を出さない")
    func textOnlyItems() {
        for kind in [ClipKind.image, .file] {
            let shown = actions(CardMenuModel.entries(for: item(kind, preview: kind == .file ? "架空.pdf" : nil)))
            #expect(!shown.contains(.pastePlain), "\(kind)")
            #expect(!shown.contains(.editSnippet), "\(kind)")
        }
        for kind in [ClipKind.text, .richText, .code, .command, .url, .color] {
            let shown = actions(CardMenuModel.entries(for: item(kind)))
            #expect(shown.contains(.pastePlain), "\(kind)")
            #expect(shown.contains(.editSnippet), "\(kind)")
        }
        // 一覧用の平文が無い項目（読めない型だけの「その他」など）も文字を持たない扱い
        #expect(!actions(CardMenuModel.entries(for: item(.other, preview: nil))).contains(.pastePlain))
    }

    @Test("ページの有無: コピー元のページか、http(s) の URL の項目のときだけ「コピー元のページを開く」を出す")
    func sourcePage() {
        #expect(
            actions(CardMenuModel.entries(for: item(.text, sourceURL: "https://example.com/a"))).contains(.openSource))
        #expect(actions(CardMenuModel.entries(for: item(.url, preview: "https://example.org/b"))).contains(.openSource))
        #expect(!actions(CardMenuModel.entries(for: item(.text))).contains(.openSource))
        #expect(!actions(CardMenuModel.entries(for: item(.url, preview: "ftp://example.org/c"))).contains(.openSource))
        #expect(!actions(CardMenuModel.entries(for: item(.image, preview: nil))).contains(.openSource))
        // 秘密の URL の項目の一覧用の平文は伏せ字なので、ページとして使わない（コピー元のページがあればそちらは出す）
        #expect(
            !actions(CardMenuModel.entries(for: item(.url, preview: "https://example.org/x", secret: true))).contains(
                .openSource))
        #expect(
            actions(
                CardMenuModel.entries(
                    for: item(.url, preview: "https://example.org/x", sourceURL: "https://example.com/s", secret: true))
            ).contains(.openSource))
    }

    @Test("開けるページ: コピー元のページを先に、なければ URL の項目そのもの（前後の空白は外す）")
    func openablePageURL() {
        #expect(
            item(.url, preview: "  https://example.org/b\n").openablePageURL?.absoluteString == "https://example.org/b")
        #expect(
            item(.url, preview: "https://example.org/b", sourceURL: "https://example.com/a").openablePageURL?
                .absoluteString == "https://example.com/a")
        #expect(item(.text, preview: "https://example.org/b").openablePageURL == nil)
        #expect(item(.text, sourceURL: "file:///tmp/a").openablePageURL == nil)
    }

    @Test("ピン留めの状態で「ピン留め」と「ピン留めを外す」を出し分ける（どちらも同じ操作）")
    func pinTitle() {
        func pinItem(_ pinned: Bool) -> CardMenuModel.Item? {
            CardMenuModel.entries(for: item(.text, pinned: pinned)).compactMap {
                if case .item(let item) = $0, item.action == .togglePin { item } else { nil }
            }.first
        }
        #expect(pinItem(false)?.title == "ピン留め")
        #expect(pinItem(true)?.title == "ピン留めを外す")
    }

    @Test("秘密の項目: 定型文に登録は出さない（#25）。貼り付け・文字だけ・コピーは出す（印は貼るときに付ける）")
    func secretItem() {
        let shown = actions(CardMenuModel.entries(for: item(.text, secret: true)))
        #expect(!shown.contains(.editSnippet))
        #expect(Array(shown.prefix(3)) == [.paste, .pastePlain, .copyOnly])
    }

    @Test("プレビューを開いているときは「プレビューを閉じる」")
    func previewTitle() {
        #expect(titles(CardMenuModel.entries(for: item(.text), previewOpen: true)).contains("プレビューを閉じる"))
        #expect(titles(CardMenuModel.snippetEntries(previewOpen: true)).contains("プレビューを閉じる"))
    }

    @Test("定型文のメニュー: 貼り付け・コピー → 編集・プレビュー。文字だけ・ピン留め・ページ・削除は無い")
    func snippetMenu() {
        #expect(layout(CardMenuModel.snippetEntries()) == "paste copyOnly | editSnippet look")
        #expect(titles(CardMenuModel.snippetEntries()) == ["貼り付け", "クリップボードにコピー", "編集…", "プレビュー"])
    }

    @Test("メニューの項目はどれも一覧の範囲のキーマップの操作（キーで同じことができる）")
    func everyItemIsPanelAction() {
        let all =
            CardMenuModel.entries(for: item(.text, sourceURL: "https://example.com")) + CardMenuModel.snippetEntries()
        for action in actions(all) {
            #expect(action.scope == .panel, "\(action)")
            #expect(!action.usesDigits && !action.holdsModifier, "\(action)")
        }
    }

    @Test("メニューのキーの表記: 英字は小文字、↩・⌫・esc・矢印・F キーは AppKit の決まりの文字")
    func menuKeyEquivalent() {
        #expect(KeyCombo(.code(KeyCodes.returnKey)).menuKeyEquivalent == "\r")
        #expect(KeyCombo(.code(KeyCodes.keypadEnter)).menuKeyEquivalent == "\r")
        #expect(KeyCombo(.code(KeyCodes.delete), .command).menuKeyEquivalent == "\u{8}")
        #expect(KeyCombo(.code(KeyCodes.escape)).menuKeyEquivalent == "\u{1B}")
        #expect(KeyCombo(.code(KeyCodes.tab)).menuKeyEquivalent == "\t")
        #expect(KeyCombo(.code(KeyCodes.space)).menuKeyEquivalent == " ")
        #expect(KeyCombo(.code(KeyCodes.upArrow)).menuKeyEquivalent == "\u{F700}")
        #expect(KeyCombo(.code(122)).menuKeyEquivalent == "\u{F704}")  // F1
        #expect(KeyCombo(.code(90)).menuKeyEquivalent == "\u{F717}")  // F20
        #expect(KeyCombo(.code(35), .command).menuKeyEquivalent == "p")  // ⌘P
        #expect(KeyCombo(.code(1), [.command, .shift]).menuKeyEquivalent == "s")  // ⇧⌘S は修飾キーで ⇧
        #expect(KeyCombo(.code(43), .command).menuKeyEquivalent == ",")
        #expect(KeyCombo(.digits, .command).menuKeyEquivalent == nil)
        #expect(KeyCombo(.hold, .option).menuKeyEquivalent == nil)
    }

    @Test("メニューのキーの表記は、仮想キーコードに戻せる（検証の状態出力で使う）")
    func menuKeyRoundTrip() {
        for code in KeyCodes.names.keys where code != KeyCodes.keypadEnter {
            guard let key = KeyCombo(.code(code)).menuKeyEquivalent else { continue }
            #expect(KeyCodes.code(forMenuKeyEquivalent: key) == code, "\(code)")
        }
    }

    @Test("既定のキーマップでは、メニューの項目すべてにキーを添えられる")
    func defaultKeysShown() {
        let all =
            CardMenuModel.entries(for: item(.text, sourceURL: "https://example.com")) + CardMenuModel.snippetEntries()
        for action in actions(all) {
            #expect(Keymap.default.primary(action)?.menuKeyEquivalent != nil, "\(action)")
        }
    }
}

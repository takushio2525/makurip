import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// パネルのキー操作（ビューモデルを直接駆動する。窓は作らない）
@MainActor
@Suite("パネルのキー操作")
struct HistoryPanelModelTests {
    /// 記録係つきのモデル
    final class Recorder {
        var pasted: [(UUID, PasteMode)] = []
        var closed = 0
        var opened: [URL] = []
        var previewEvents: [Bool] = []
    }

    let history: FakeHistory
    let model: HistoryPanelModel
    let recorder = Recorder()

    init() {
        history = SampleHistory.make()
        model = HistoryPanelModel(actions: history)
        model.clock = { SampleHistory.now }
        let recorder = recorder
        model.effects = HistoryPanelModel.Effects(
            paste: { recorder.pasted.append(($0, $1)) },
            close: { recorder.closed += 1 },
            openURL: { recorder.opened.append($0) },
            previewChanged: { recorder.previewEvents.append($0) })
        model.open()
    }

    @discardableResult
    func press(_ code: UInt16, _ modifiers: HotKey.Modifiers = [], composing: Bool = false) -> Bool {
        model.handle(KeyStroke(keyCode: code, modifiers: modifiers), isComposing: composing)
    }

    static let keyK: UInt16 = 40
    static let keyE: UInt16 = 14
    static let keyP: UInt16 = 35
    static let keyN: UInt16 = 45
    static let keyY: UInt16 = 16
    static let keyO: UInt16 = 31

    @Test("開いた瞬間: 最新が選ばれ、絞り込みなし・検索欄は空")
    func openState() {
        #expect(model.selectedIndex == 0)
        #expect(model.selected?.id == history.items[0].id)
        #expect(model.items.count == history.items.count)
        #expect(model.query.isEmpty)
        #expect(model.kind == nil && model.method == .all && model.app == nil && !model.pinnedOnly)
        #expect(model.focusRequest > 0)
    }

    @Test("↑↓ と ⌃N/⌃P で移動し、端で止まる")
    func moveSelection() {
        #expect(press(KeyCodes.downArrow))
        #expect(model.selectedIndex == 1)
        #expect(press(Self.keyN, .control))
        #expect(model.selectedIndex == 2)
        #expect(press(Self.keyP, .control))
        #expect(model.selectedIndex == 1)
        press(KeyCodes.upArrow)
        press(KeyCodes.upArrow)
        #expect(model.selectedIndex == 0)
        for _ in 0..<100 { press(KeyCodes.downArrow) }
        #expect(model.selectedIndex == model.items.count - 1)
    }

    @Test("Enter で選んだ項目を貼る。⇧Enter はプレーン、⌘Enter はコピーだけ")
    func paste() {
        press(KeyCodes.downArrow)
        #expect(press(KeyCodes.returnKey))
        #expect(recorder.pasted.last?.0 == history.items[1].id)
        #expect(recorder.pasted.last?.1 == .normal)
        press(KeyCodes.keypadEnter)
        #expect(recorder.pasted.count == 2)
        press(KeyCodes.returnKey, .shift)
        #expect(recorder.pasted.last?.1 == .plainText)
        press(KeyCodes.returnKey, .command)
        #expect(recorder.pasted.last?.1 == .copyOnly)
    }

    @Test("Esc: 検索語があれば消し、なければ閉じる")
    func escape() {
        model.query = "git"
        #expect(press(KeyCodes.escape))
        #expect(model.query.isEmpty)
        #expect(recorder.closed == 0)
        press(KeyCodes.escape)
        #expect(recorder.closed == 1)
    }

    @Test("⌘1〜9 でその番号の項目をすぐ貼る（なければ何もしない）")
    func quickPaste() {
        #expect(press(KeyCodes.digitCodes[2], .command))
        #expect(recorder.pasted.last?.0 == history.items[2].id)
        #expect(model.selectedIndex == 2)
        model.setKind(.color)  // 2 件だけ
        press(KeyCodes.digitCodes[8], .command)
        #expect(recorder.pasted.count == 1)
        // ⌘ なしの数字は検索欄へ流す
        #expect(!press(KeyCodes.digitCodes[0]))
    }

    @Test("Tab / ⇧Tab で種類を切り替える（端で一周）")
    func kindTabs() {
        #expect(press(KeyCodes.tab))
        #expect(model.kind == .text)
        #expect(model.items.allSatisfy { $0.kind == .text })
        press(KeyCodes.tab)
        #expect(model.kind == .richText)
        press(KeyCodes.tab, .shift)
        press(KeyCodes.tab, .shift)
        #expect(model.kind == nil)
        press(KeyCodes.tab, .shift)
        #expect(model.kind == .color)
        #expect(model.items.count == 2)
        #expect(model.selectedIndex == 0)
    }

    @Test("⌘K でコピー方法を すべて → キー操作 → ボタンなど → すべて と切り替える")
    func cycleMethod() {
        #expect(press(Self.keyK, .command))
        #expect(model.method == .keyboard)
        #expect(model.items.allSatisfy { $0.copyMethod == .keyboard })
        press(Self.keyK, .command)
        #expect(model.method == .other)
        #expect(model.items.allSatisfy { $0.copyMethod == .other })
        #expect(!model.items.isEmpty)
        press(Self.keyK, .command)
        #expect(model.method == .all)
        #expect(model.items.count == history.items.count)
    }

    @Test("⌘E でアプリを選ぶ（ひらがなで探し、↓ と Enter で決める。Esc と ⌘E で閉じる）")
    func chooseApp() {
        #expect(press(Self.keyE, .command))
        #expect(model.isPickerOpen)
        #expect(model.shownPickerOptions.first?.key == nil)
        model.pickerQuery = "めーる"
        #expect(model.shownPickerOptions.map(\.name) == ["メール"])
        press(KeyCodes.returnKey)
        #expect(!model.isPickerOpen)
        #expect(model.app == "com.example.mail")
        #expect(model.items.count == 1)
        #expect(recorder.pasted.isEmpty)  // 選択の Enter で貼らない
        // ローマ字でも引ける。↓ で選んで決める
        press(Self.keyE, .command)
        model.pickerQuery = "ta-minaru"
        #expect(model.shownPickerOptions.map(\.name) == ["ターミナル"])
        press(KeyCodes.escape)
        #expect(!model.isPickerOpen)
        #expect(model.app == "com.example.mail")
        // 開き直すと今のアプリが選ばれている。↑ で 1 つ上へ動く
        press(Self.keyE, .command)
        let current = model.pickerSelection
        #expect(model.shownPickerOptions[current].key == "com.example.mail")
        press(KeyCodes.upArrow)
        #expect(model.pickerSelection == current - 1)
        // 「すべて」で探して決めると絞り込みが外れる
        model.pickerQuery = "すべて"
        #expect(model.pickerSelection == 0)
        press(KeyCodes.returnKey)
        #expect(model.app == nil)
        press(Self.keyE, .command)
        press(Self.keyE, .command)
        #expect(!model.isPickerOpen)
        // 開いている間のほかの操作は食べる（裏の一覧が動かない）
        press(Self.keyE, .command)
        let kind = model.kind
        #expect(press(KeyCodes.tab))
        #expect(model.kind == kind)
    }

    @Test("⌘⇧P でピン留めだけを表示する（もう一度で戻る）")
    func pinnedOnly() {
        #expect(press(Self.keyP, [.command, .shift]))
        #expect(model.pinnedOnly)
        #expect(model.items.count == 4)
        #expect(model.items.allSatisfy { $0.isPinned })
        press(Self.keyP, [.command, .shift])
        #expect(!model.pinnedOnly)
    }

    @Test("⌘P で選んだ項目をピン留め・外す")
    func togglePin() {
        let id = model.selected!.id
        #expect(!model.selected!.isPinned)
        #expect(press(Self.keyP, .command))
        #expect(history.items.first { $0.id == id }?.isPinned == true)
        #expect(model.selected?.id == id)
        #expect(model.selected?.isPinned == true)
        press(Self.keyP, .command)
        #expect(model.selected?.isPinned == false)
    }

    @Test("⌘Y で大きいプレビューを出す・閉じる。選択を動かしても出たまま")
    func preview() {
        #expect(press(Self.keyY, .command))
        #expect(model.isPreviewOpen)
        press(KeyCodes.downArrow)
        #expect(model.isPreviewOpen)
        press(Self.keyY, .command)
        #expect(!model.isPreviewOpen)
        #expect(recorder.previewEvents == [true, false])
        // 開き直すと閉じた状態から
        press(Self.keyY, .command)
        model.open()
        #expect(!model.isPreviewOpen)
    }

    @Test("⌘⌫ で削除し、同じ位置の次の項目を選ぶ")
    func delete() {
        press(KeyCodes.downArrow)
        let next = history.items[2].id
        #expect(press(KeyCodes.delete, .command))
        #expect(history.items.count == SampleHistory.entries.count - 1)
        #expect(model.selected?.id == next)
    }

    @Test("⌘O でコピー元のページを開く（ない項目は揺らすだけ）")
    func openSource() {
        press(Self.keyO, .command)
        #expect(recorder.opened.map(\.host) == ["chat.example.ai"])
        press(KeyCodes.downArrow)
        let shakes = model.shakeCount
        press(Self.keyO, .command)
        #expect(recorder.opened.count == 1)
        #expect(model.shakeCount == shakes + 1)
    }

    @Test("日本語入力の変換中は Enter・↑↓・Tab・Esc を横取りしない")
    func composing() {
        #expect(!press(KeyCodes.returnKey, composing: true))
        #expect(!press(KeyCodes.downArrow, composing: true))
        #expect(!press(KeyCodes.tab, composing: true))
        #expect(!press(KeyCodes.escape, composing: true))
        #expect(recorder.pasted.isEmpty)
        #expect(model.selectedIndex == 0)
        #expect(model.kind == nil)
        #expect(recorder.closed == 0)
    }

    @Test("文字のキーは処理せず検索欄へ流す")
    func letters() {
        #expect(!press(Self.keyK))
        #expect(!press(KeyCodes.delete))
        #expect(!press(0, .command))  // ⌘A は検索欄の全選択
    }

    @Test("検索: ローマ字で半角カナを引き、選択は先頭に戻る。0 件で貼ろうとすると揺れる")
    func search() {
        press(KeyCodes.downArrow)
        model.query = "depuroi"
        #expect(model.items.count == 1)
        #expect(model.selectedIndex == 0)
        model.query = "kopi"
        #expect(model.items.contains { $0.previewText?.contains("コピー") == true })
        model.query = "存在しない語"
        #expect(model.items.isEmpty)
        let shakes = model.shakeCount
        press(KeyCodes.returnKey)
        #expect(recorder.pasted.isEmpty)
        #expect(model.shakeCount == shakes + 1)
    }

    @Test("絞り込みを全部かけた状態（種類 × コピー方法 × アプリ × ピン留め × 検索）。開き直すと外れる")
    func allFilters() {
        model.setKind(.command)
        model.setMethod(.keyboard)
        model.setApp("com.example.terminal")
        model.togglePinnedOnly()
        model.query = "npm"
        #expect(model.items.count == 1)
        #expect(model.kindCounts[nil] == 1)
        model.query = "git"
        #expect(model.items.isEmpty)
        model.open()
        #expect(model.items.count == history.items.count)
        #expect(
            model.kind == nil && model.method == .all && model.app == nil && !model.pinnedOnly && model.query.isEmpty)
    }

    @Test("取り込みで読み直しても、選んでいた項目を選んだまま")
    func reloadKeepsSelection() {
        press(KeyCodes.downArrow)
        let id = model.selected!.id
        history.items.insert(makeItem(.text, "新しくコピーした"), at: 0)
        model.reload()
        #expect(model.selected?.id == id)
        #expect(model.selectedIndex == 2)
    }

    @Test("日付の見出し（今日・昨日・それ以前）を挟む")
    func groups() {
        let headers = model.rows.compactMap { row -> String? in
            if case .header(let group) = row { return group.rawValue }
            return nil
        }
        #expect(headers == ["今日", "昨日", "それ以前"])
        #expect(model.rows.count == model.items.count + 3)
    }

    @Test("検証用の状態に中身を入れない（行数・選択・絞り込みだけ）")
    func debugState() {
        model.query = "probe"
        let state = model.debugState
        #expect(state["rowCount"] == "0")
        #expect(state["query"] == "probe")
        #expect(state["loadedCount"] == String(history.items.count))
        #expect(Set(state.keys).isSuperset(of: ["query", "rowCount", "loadedCount", "selectedIndex", "selectedKind"]))
        for value in state.values {
            #expect(!history.items.contains { item in item.previewText.map { $0 == value } ?? false })
        }
    }

    @Test("履歴が 0 件でも開ける（貼ろうとすると揺れるだけ）")
    func emptyHistory() {
        let empty = HistoryPanelModel(actions: FakeHistory())
        empty.open()
        #expect(empty.items.isEmpty)
        #expect(empty.selected == nil)
        #expect(empty.handle(KeyStroke(keyCode: KeyCodes.downArrow)))
        #expect(empty.handle(KeyStroke(keyCode: KeyCodes.returnKey)))
        #expect(empty.shakeCount == 1)
        #expect(EmptyStateView.content(for: empty).title == "まだ履歴がありません")
    }
}

func makeItem(_ kind: ClipKind, _ text: String) -> ClipItem {
    let date = SampleHistory.now
    return ClipItem(
        id: UUID(), contentHash: UUID().uuidString, kind: kind, copyMethod: .keyboard,
        source: SourceApp(bundleID: "com.example.new", name: "New"), sourceURL: nil, createdAt: date,
        lastUsedAt: date, copyCount: 1, isPinned: false, flags: [], previewText: text, totalBytes: 10,
        pasteboardItemCount: 1)
}

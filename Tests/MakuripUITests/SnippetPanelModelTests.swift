import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// パネルの定型文の一覧（⌘S）のキー操作。ビューモデルを直接駆動する（窓は作らない）
@MainActor
@Suite("パネルの定型文")
struct SnippetPanelModelTests {
    final class Recorder {
        var pastedSnippets: [(UUID, PasteMode)] = []
        var pastedItems: [(UUID, PasteMode)] = []
        var editRequests: [SnippetEditRequest] = []
        var closed = 0
        var opened: [URL] = []
    }

    let history: FakeHistory
    let model: HistoryPanelModel
    let recorder = Recorder()

    init() {
        history = SampleHistory.make()
        history.snippetList = SampleHistory.snippets
        model = HistoryPanelModel(actions: history)
        model.clock = { SampleHistory.now }
        let recorder = recorder
        model.effects = HistoryPanelModel.Effects(
            paste: { recorder.pastedItems.append(($0, $1)) },
            close: { recorder.closed += 1 },
            openURL: { recorder.opened.append($0) },
            pasteSnippet: { recorder.pastedSnippets.append(($0, $1)) },
            editSnippet: { recorder.editRequests.append($0) })
        model.open()
    }

    @discardableResult
    func press(_ code: UInt16, _ modifiers: HotKey.Modifiers = [], composing: Bool = false) -> Bool {
        model.handle(KeyStroke(keyCode: code, modifiers: modifiers), isComposing: composing)
    }

    static let keyS: UInt16 = 1
    static let keyK: UInt16 = 40
    static let keyE: UInt16 = 14
    static let keyP: UInt16 = 35
    static let keyY: UInt16 = 16
    static let keyO: UInt16 = 31

    func toSnippets() {
        #expect(press(Self.keyS, .command))
        #expect(model.showsSnippets)
    }

    @Test("⌘S で定型文の一覧に切り替わり、もう一度で履歴に戻る。開き直すと履歴から")
    func toggle() {
        model.select(3)
        toSnippets()
        #expect(model.rowCount == 6)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedSnippet?.name == "あいさつ（社外）")
        #expect(model.selected == nil)
        #expect(press(Self.keyS, .command))
        #expect(!model.showsSnippets)
        #expect(model.rowCount == history.items.count)
        #expect(model.selected?.id == history.items[0].id)
        toSnippets()
        model.open()
        #expect(!model.showsSnippets)
    }

    @Test("メニューの「定型文の一覧を開く」は定型文の表示で開く。ふつうに開き直せば履歴から（#35）")
    func openFromMenu() {
        model.select(3)
        model.open(snippets: true)
        #expect(model.showsSnippets)
        #expect(model.rowCount == 6)
        #expect(model.selectedIndex == 0)
        #expect(model.selectedSnippet?.name == "あいさつ（社外）")
        #expect(press(Self.keyS, .command))
        #expect(!model.showsSnippets)
        model.open(snippets: true)
        model.open()
        #expect(!model.showsSnippets)
        #expect(model.rowCount == history.items.count)
    }

    @Test("↑↓ は定型文の数で止まり、Enter で選んだ定型文を貼る（⇧↩・⌘↩ も）")
    func moveAndPaste() {
        toSnippets()
        for _ in 0..<20 { press(KeyCodes.downArrow) }
        #expect(model.selectedIndex == 5)
        press(KeyCodes.upArrow)
        #expect(press(KeyCodes.returnKey))
        #expect(recorder.pastedSnippets.last?.0 == SampleHistory.snippets[4].id)
        #expect(recorder.pastedSnippets.last?.1 == .normal)
        press(KeyCodes.returnKey, .shift)
        #expect(recorder.pastedSnippets.last?.1 == .plainText)
        press(KeyCodes.returnKey, .command)
        #expect(recorder.pastedSnippets.last?.1 == .copyOnly)
        // 履歴の貼り付けは呼ばない
        #expect(recorder.pastedItems.isEmpty)
    }

    @Test("⌘1〜9 で番号の定型文をすぐ貼る。数より大きい番号は何もしない")
    func quickPaste() {
        toSnippets()
        #expect(press(KeyCodes.digitCodes[1], .command))
        #expect(recorder.pastedSnippets.map(\.0) == [SampleHistory.snippets[1].id])
        #expect(model.selectedIndex == 1)
        #expect(press(KeyCodes.digitCodes[8], .command))
        #expect(recorder.pastedSnippets.count == 1)
    }

    @Test("種類・コピー方法・アプリの絞り込み、ピン留めと削除は効かない（試作と同じ）")
    func disabledActions() {
        toSnippets()
        let before = history.items
        #expect(press(KeyCodes.tab))
        #expect(press(KeyCodes.tab, .shift))
        #expect(press(Self.keyK, .command))
        #expect(press(Self.keyE, .command))
        #expect(press(Self.keyP, .command))
        #expect(press(KeyCodes.delete, .command))
        #expect(model.kind == nil && model.method == .all && !model.isPickerOpen)
        #expect(history.items == before)
        #expect(model.showsSnippets && model.rowCount == 6)
        // マウスで押しても同じ
        model.setKind(.code)
        model.setMethod(.keyboard)
        model.openPicker()
        #expect(model.kind == nil && model.method == .all && !model.isPickerOpen)
        // ⌘O（コピー元のページ）は無いので揺らす
        let shakes = model.shakeCount
        press(Self.keyO, .command)
        #expect(model.shakeCount == shakes + 1)
        #expect(recorder.opened.isEmpty)
    }

    @Test("履歴の絞り込みは定型文の間も保ち、履歴に戻ると効いている")
    func keepsHistoryFilter() {
        model.setKind(.code)
        let codeCount = model.items.count
        toSnippets()
        #expect(model.rowCount == 6)
        press(Self.keyS, .command)
        #expect(model.kind == .code && model.items.count == codeCount)
    }

    @Test("⌘⇧P を定型文の一覧で押すと、履歴のピン留めだけの表示へ移る。ピン留めから ⌘S で定型文へ")
    func pinnedScope() {
        toSnippets()
        press(Self.keyP, [.command, .shift])
        #expect(!model.showsSnippets && model.pinnedOnly)
        toSnippets()
        #expect(!model.pinnedOnly)
    }

    @Test("検索は名前・略語・本文に効き（ローマ字・かなでも）、履歴に戻っても検索語は残る")
    func search() {
        toSnippets()
        model.query = "rebyu-"
        #expect(model.snippetItems.map(\.name) == ["AI にレビューを頼む"])
        model.query = ";pr"
        #expect(model.snippetItems.map(\.name) == ["PR の説明テンプレート"])
        // 漢字は読みで引けない（検索の限界）。「定型文」の字なら全件に当たる
        model.query = "定型文"
        #expect(model.rowCount == 6)
        model.query = "rebyu-"
        press(Self.keyS, .command)
        #expect(model.query == "rebyu-" && !model.showsSnippets)
        press(Self.keyS, .command)
        #expect(model.snippetItems.count == 1)
        model.query = "zzzz"
        #expect(model.rowCount == 0)
        let shakes = model.shakeCount
        press(KeyCodes.returnKey)
        #expect(model.shakeCount == shakes + 1)
        #expect(recorder.pastedSnippets.isEmpty)
        #expect(EmptyStateView.content(for: model).title == "「zzzz」は見つかりませんでした")
        // esc は検索を消し、もう一度で閉じる
        press(KeyCodes.escape)
        #expect(model.query.isEmpty && model.rowCount == 6 && recorder.closed == 0)
        press(KeyCodes.escape)
        #expect(recorder.closed == 1)
    }

    @Test("⌘⇧S: 定型文の一覧では選んだものを編集、履歴の一覧では選んだ項目から作る")
    func editRequests() {
        model.select(2)
        #expect(press(Self.keyS, [.command, .shift]))
        #expect(recorder.editRequests.last == .fromHistory(history.items[2].id))
        toSnippets()
        press(KeyCodes.downArrow)
        press(Self.keyS, [.command, .shift])
        #expect(recorder.editRequests.last == .edit(SampleHistory.snippets[1].id))
    }

    @Test("定型文が 0 件: 空の案内に「新しい定型文」のキー、⌘⇧S で新しい下書き、Enter は揺らす")
    func emptySnippets() {
        history.snippetList = []
        model.open()
        toSnippets()
        #expect(model.rowCount == 0)
        let content = EmptyStateView.content(for: model)
        #expect(content.title == "定型文はまだありません")
        #expect(content.hint?.0 == .editSnippet)
        let shakes = model.shakeCount
        press(KeyCodes.returnKey)
        #expect(model.shakeCount == shakes + 1)
        press(Self.keyS, [.command, .shift])
        #expect(recorder.editRequests.last == .new(body: ""))
    }

    @Test("履歴が空の案内には、試作どおり「定型文を見る」のキーを出す")
    func emptyHistoryHint() {
        let empty = FakeHistory()
        let model = HistoryPanelModel(actions: empty)
        model.open()
        #expect(EmptyStateView.content(for: model).hint?.0 == .snippets)
    }

    @Test("定型文が変わったら読み直し、選んでいたものを選んだままにする")
    func reloadKeepsSelection() {
        toSnippets()
        model.select(3)
        let selected = model.selectedSnippet?.id
        var list = SampleHistory.snippets
        list.insert(
            Snippet(
                id: UUID(), name: "新しい", abbreviation: "", body: "x", createdAt: SampleHistory.now,
                updatedAt: SampleHistory.now), at: 0)
        history.snippetList = list
        model.reloadSnippets()
        #expect(model.rowCount == 7)
        #expect(model.selectedSnippet?.id == selected)
        // 選んでいたものが消えたら、同じ位置のものを選ぶ
        history.snippetList = list.filter { $0.id != selected }
        model.reloadSnippets()
        #expect(model.selectedIndex == 4)
    }

    @Test("⌘Y のプレビューは定型文にも出る。日付の説明は設定の書き方")
    func preview() {
        toSnippets()
        press(Self.keyY, .command)
        #expect(model.isPreviewOpen)
        #expect(DisplayText.snippetNote(now: model.now, format: model.snippetDateFormat).contains("2026/10/31"))
        history.dateFormat = .japanese
        #expect(DisplayText.snippetNote(now: model.now, format: model.snippetDateFormat).contains("2026年10月31日"))
        #expect(DisplayText.snippetInfo(SampleHistory.snippets[1]) == "定型文 · 略語 ;date")
    }

    @Test("変換中は何も横取りしない（⌘S も）")
    func composing() {
        #expect(!press(Self.keyS, .command, composing: true))
        #expect(!model.showsSnippets)
    }

    @Test("数百件でも検索がすぐ終わる")
    func manySnippets() {
        history.snippetList = (0..<800).map {
            Snippet(
                id: UUID(), name: "定型文 \($0)", abbreviation: ";s\($0)", body: "本文 \($0)\n{{日付}}",
                createdAt: SampleHistory.now, updatedAt: SampleHistory.now)
        }
        model.open()
        toSnippets()
        let start = Date()
        model.query = "s79"
        model.query = "s799"
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(model.snippetItems.map(\.name) == ["定型文 799"])
    }
}

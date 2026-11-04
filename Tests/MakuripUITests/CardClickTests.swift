import AppKit
import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// カードの左クリック（押したカードの上で離すと貼る）と右クリックのメニュー（#38）。
/// ビューモデルと NSMenu・NSView を直接動かす（窓は作らない）。中身は自作の架空データ（`SampleHistory`）
@MainActor
@Suite("カードのクリックと右クリックのメニュー")
struct CardClickTests {
    final class Recorder {
        var pasted: [(UUID, PasteMode)] = []
        var pastedSnippets: [(UUID, PasteMode)] = []
        var opened: [URL] = []
        var previewEvents: [Bool] = []
        var editRequests: [SnippetEditRequest] = []
    }

    let history: FakeHistory
    let model: HistoryPanelModel
    let recorder = Recorder()

    init() {
        history = SampleHistory.make(entries: SampleHistory.secretEntries)
        history.snippetList = SampleHistory.snippets
        model = HistoryPanelModel(actions: history)
        model.clock = { SampleHistory.now }
        let recorder = recorder
        model.effects = HistoryPanelModel.Effects(
            paste: { recorder.pasted.append(($0, $1)) },
            openURL: { recorder.opened.append($0) },
            previewChanged: { recorder.previewEvents.append($0) },
            pasteSnippet: { recorder.pastedSnippets.append(($0, $1)) },
            editSnippet: { recorder.editRequests.append($0) })
        model.open()
    }

    func id(_ index: Int) -> UUID { model.items[index].id }

    func firstIndex(_ where: (ClipItem) -> Bool) -> Int {
        model.items.firstIndex(where: `where`)!
    }

    func actions(_ entries: [CardMenuModel.Entry]?) -> [KeyAction] {
        (entries ?? []).compactMap { if case .item(let item) = $0 { item.action } else { nil } }
    }

    // MARK: 左クリック

    @Test("カードを押して同じカードの上で離すと、その項目を ↩ と同じく貼る")
    func clickPastes() {
        let target = id(4)
        model.pressRow(target)
        #expect(model.selectedIndex == 4)
        #expect(recorder.pasted.isEmpty)  // 押しただけでは貼らない
        model.releaseRow(target, inside: true)
        #expect(recorder.pasted.count == 1)
        #expect(recorder.pasted.last?.0 == target)
        #expect(recorder.pasted.last?.1 == .normal)
        #expect(model.pressedRowID == nil)
    }

    @Test("押したままカードの外へ出て離すと貼らない（押したカードは選んだまま）")
    func releaseOutside() {
        let target = id(2)
        model.pressRow(target)
        model.releaseRow(target, inside: false)
        #expect(recorder.pasted.isEmpty)
        #expect(model.selectedIndex == 2)
        // 次のクリックは効く（押した状態が残っていない）
        model.pressRow(target)
        model.releaseRow(target, inside: true)
        #expect(recorder.pasted.map(\.0) == [target])
    }

    @Test("押していないのに離した・別のカードで押していた・右クリックを挟んだときは貼らない")
    func releaseWithoutPress() {
        model.releaseRow(id(1), inside: true)
        model.pressRow(id(1))
        model.releaseRow(id(3), inside: true)
        // ⌃ を押しながらのクリック: 押してからメニューを出したら、離しても貼らない
        model.pressRow(id(5))
        _ = model.menuEntries(forRow: id(5))
        model.releaseRow(id(5), inside: true)
        #expect(recorder.pasted.isEmpty)
    }

    @Test("押している間に履歴が増えて並びがずれても、押したカードの項目を貼る")
    func clickSurvivesReload() {
        let target = id(3)
        model.pressRow(target)
        history.items.insert(history.items[10], at: 0)
        history.items[0].id = UUID()
        model.reload()
        model.releaseRow(target, inside: true)
        #expect(recorder.pasted.map(\.0) == [target])
    }

    @Test("定型文の一覧（⌘S）でも、カードを押して離すとその定型文を貼る")
    func clickSnippet() {
        model.toggleSnippets()
        let snippet = model.snippetItems[2].id
        model.pressRow(snippet)
        model.releaseRow(snippet, inside: false)
        #expect(recorder.pastedSnippets.isEmpty)
        model.pressRow(snippet)
        model.releaseRow(snippet, inside: true)
        #expect(recorder.pastedSnippets.map(\.0) == [snippet])
        #expect(recorder.pastedSnippets.last?.1 == .normal)
        #expect(recorder.pasted.isEmpty)
    }

    // MARK: 右クリックのメニュー

    @Test("右クリックしたカードを選び、その項目の状態でメニューを出し分ける")
    func menuSelectsAndAdapts() {
        let command = firstIndex { $0.kind == .command && $0.sourceURL != nil && !$0.isSecretLikely }
        let image = firstIndex { $0.kind == .image && $0.sourceURL == nil }
        let pinnedURL = firstIndex { $0.kind == .url && $0.isPinned }
        let file = firstIndex { $0.kind == .file }

        let commandMenu = actions(model.menuEntries(forRow: id(command)))
        #expect(model.selectedIndex == command)
        #expect(
            commandMenu == [.paste, .pastePlain, .copyOnly, .togglePin, .editSnippet, .preview, .openSource, .delete])

        let imageMenu = actions(model.menuEntries(forRow: id(image)))
        #expect(model.selectedIndex == image)
        #expect(imageMenu == [.paste, .copyOnly, .togglePin, .preview, .delete])

        let fileMenu = actions(model.menuEntries(forRow: id(file)))
        #expect(!fileMenu.contains(.pastePlain) && !fileMenu.contains(.editSnippet) && !fileMenu.contains(.openSource))

        let urlEntries = model.menuEntries(forRow: id(pinnedURL)) ?? []
        #expect(actions(urlEntries).contains(.openSource))
        #expect(urlEntries.contains(.item(CardMenuModel.Item(action: .togglePin, title: "ピン留めを外す"))))
    }

    @Test("メニューの各項目は、そのキーを押したのと同じ処理を右クリックしたカードに行う")
    func menuActionsWork() {
        let text = firstIndex { $0.kind == .text && !$0.isSecretLikely }
        let target = id(text)
        for (action, mode) in [(KeyAction.paste, PasteMode.normal), (.pastePlain, .plainText), (.copyOnly, .copyOnly)] {
            model.select(0)
            model.performMenuAction(action, onRow: target)
            #expect(recorder.pasted.last?.0 == target)
            #expect(recorder.pasted.last?.1 == mode)
        }

        model.performMenuAction(.editSnippet, onRow: target)
        #expect(recorder.editRequests == [.fromHistory(target)])

        model.performMenuAction(.preview, onRow: target)
        #expect(recorder.previewEvents == [true])
        model.performMenuAction(.preview, onRow: target)
        #expect(recorder.previewEvents == [true, false])

        let wasPinned = history.items.first { $0.id == target }!.isPinned
        model.performMenuAction(.togglePin, onRow: target)
        #expect(history.items.first { $0.id == target }!.isPinned == !wasPinned)

        let page = firstIndex { $0.sourceURL != nil && !$0.isSecretLikely }
        model.performMenuAction(.openSource, onRow: id(page))
        #expect(recorder.opened.map(\.absoluteString) == [model.items[page].sourceURL])

        let count = history.items.count
        model.performMenuAction(.delete, onRow: target)
        #expect(history.items.count == count - 1)
        #expect(!history.items.contains { $0.id == target })
    }

    @Test("メニューを開いている間にカードが消えたら、何もせずに揺らす")
    func menuOnRemovedRow() {
        let target = id(4)
        _ = model.menuEntries(forRow: target)
        history.items.removeAll { $0.id == target }
        model.reload()
        let shakes = model.shakeCount
        model.performMenuAction(.paste, onRow: target)
        #expect(recorder.pasted.isEmpty)
        #expect(model.shakeCount == shakes + 1)
    }

    @Test("メニューを開いている間に履歴が増えて並びがずれても、右クリックしたカードに効く")
    func menuSurvivesReload() {
        let target = id(6)
        _ = model.menuEntries(forRow: target)
        history.items.insert(history.items[12], at: 0)
        history.items[0].id = UUID()
        model.reload()
        model.performMenuAction(.copyOnly, onRow: target)
        #expect(recorder.pasted.map(\.0) == [target])
    }

    @Test("秘密の項目: 定型文に登録は出さない。クリップボードにコピー・貼り付けは、ほかの項目と同じ貼り方で本体へ渡す（印は本体が付ける）")
    func secretMenu() {
        let secret = firstIndex { $0.isSecretLikely && $0.kind == .text }
        let target = id(secret)
        let shown = actions(model.menuEntries(forRow: target))
        #expect(!shown.contains(.editSnippet))
        #expect(shown.contains(.copyOnly) && shown.contains(.paste))
        model.performMenuAction(.copyOnly, onRow: target)
        #expect(recorder.pasted.last?.0 == target)
        #expect(recorder.pasted.last?.1 == .copyOnly)
        // キーで頼んでも定型文の窓は開かない（メニューに出さないのと同じ決まり。#25）
        model.performMenuAction(.editSnippet, onRow: target)
        #expect(recorder.editRequests.isEmpty)
    }

    @Test("定型文のカードのメニュー: 貼り付け・コピー・編集・プレビューが、その定型文に効く")
    func snippetMenu() {
        model.toggleSnippets()
        let snippet = model.snippetItems[3].id
        #expect(actions(model.menuEntries(forRow: snippet)) == [.paste, .copyOnly, .editSnippet, .preview])
        #expect(model.selectedIndex == 3)
        model.performMenuAction(.copyOnly, onRow: snippet)
        #expect(recorder.pastedSnippets.last?.0 == snippet)
        #expect(recorder.pastedSnippets.last?.1 == .copyOnly)
        model.performMenuAction(.paste, onRow: snippet)
        #expect(recorder.pastedSnippets.last?.1 == .normal)
        model.performMenuAction(.editSnippet, onRow: snippet)
        #expect(recorder.editRequests == [.edit(snippet)])
        #expect(recorder.pasted.isEmpty)
    }

    // MARK: NSMenu に写す

    @Test("NSMenu の文言とキーは、並びとキーマップの先頭の割り当てから出る")
    func nsMenuKeysFromKeymap() {
        let entries = model.menuEntries(forRow: id(firstIndex { $0.kind == .command && $0.sourceURL != nil }))!
        let menu = CardMenus.menu(entries, keymap: .default) { _ in }
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(menu.items.filter(\.isSeparatorItem).count == 2)
        #expect(
            items.map { "\($0.title)[\(CardMenus.keyText($0))]" } == [
                "貼り付け[↩]", "文字だけで貼り付け[⇧↩]", "クリップボードにコピー[⌘↩]", "ピン留め[⌘P]", "定型文に登録…[⇧⌘S]", "プレビュー[⌘Y]",
                "コピー元のページを開く[⌘O]", "履歴から削除[⌘⌫]",
            ])
        let copy = items[2]
        #expect(copy.keyEquivalent == "\r")
        #expect(copy.keyEquivalentModifierMask == [.command])
        #expect(items[4].keyEquivalent == "s")
        #expect(items[4].keyEquivalentModifierMask == [.command, .shift])
        #expect(items.filter { !$0.isEnabled }.isEmpty)
    }

    @Test("キーを付け替えるとメニューの表示も変わる。キーを外した操作には何も添えない")
    func nsMenuFollowsKeymap() {
        var keymap = Keymap.default
        keymap.set([KeyCombo(.code(8), [.command, .option])], for: .copyOnly)  // ⌥⌘C
        keymap.set([KeyCombo(.code(KeyCodes.delete), [.command, .shift])], for: .delete)
        keymap.set([], for: .preview)
        let menu = CardMenus.menu(CardMenuModel.entries(for: model.items[0]), keymap: keymap) { _ in }
        let keys = Dictionary(
            uniqueKeysWithValues: menu.items.compactMap { $0 as? CardMenuItem }.map {
                ($0.keyAction, CardMenus.keyText($0))
            }
        )
        #expect(keys[.copyOnly] == "⌥⌘C")
        #expect(keys[.delete] == "⇧⌘⌫")
        #expect(keys[.preview] == "")
        #expect(keys[.paste] == "↩")
    }

    @Test("NSMenu の項目を選ぶと、その操作が渡る")
    func nsMenuChoose() {
        var chosen: [KeyAction] = []
        let menu = CardMenus.menu(CardMenuModel.snippetEntries(), keymap: .default) { chosen.append($0) }
        let index = menu.items.firstIndex { ($0 as? CardMenuItem)?.keyAction == .copyOnly }!
        menu.performActionForItem(at: index)
        #expect(chosen == [.copyOnly])
    }

    @Test("CardMenus.make はカードを選び、選んだ項目をビューモデルへ渡すメニューを作る")
    func menusMake() {
        let menus = CardMenus()
        let target = id(4)
        let menu = menus.make(model: model, rowID: target)!
        #expect(model.selectedIndex == 4)
        #expect(menu.delegate === menus)
        let index = menu.items.firstIndex { ($0 as? CardMenuItem)?.keyAction == .copyOnly }!
        model.select(0)
        menu.performActionForItem(at: index)
        #expect(recorder.pasted.last?.0 == target)
        #expect(recorder.pasted.last?.1 == .copyOnly)
        #expect(menus.make(model: model, rowID: UUID()) == nil)  // 無いカードには出さない
    }

    // MARK: カードの上の NSView

    func event(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("NSView: 左のボタンを押すと press、離した位置がカードの中か外かを release に渡す。⌃ を押しながらは貼らない")
    func mouseView() {
        let view = CardMouseView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let row = UUID()
        var log: [String] = []
        var menuRequests = 0
        view.rowID = row
        view.onPress = { log.append("press \($0 == row)") }
        view.onRelease = { log.append("release \($0 == row) inside=\($1)") }
        view.makeMenu = { _ in
            menuRequests += 1
            return nil
        }
        #expect(view.acceptsFirstMouse(for: nil))

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 150, y: 40)))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 150, y: 40)))
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 150, y: 40)))
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 150, y: -30)))
        #expect(log == ["press true", "release true inside=true", "press true", "release true inside=false"])

        log.removeAll()
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 10, y: 10), flags: .control))
        #expect(log.isEmpty)
        #expect(menuRequests == 1)
        _ = view.menu(for: event(.rightMouseDown, at: NSPoint(x: 10, y: 10)))
        #expect(menuRequests == 2)
    }
}

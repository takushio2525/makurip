import AppKit
import MakuripCore
import SwiftUI

/// カードの上に重ねて、マウスの左クリックと右クリックを受ける（#38）。
///
/// SwiftUI のタップでは「どこで離したか」と「どのカードを右クリックしたか」を取れないので、透明な NSView で受ける。
/// 押す・離す・メニューの中身はビューモデル（`HistoryPanelModel`）が決め、ここは出来事を渡すだけにする
struct CardMouseArea: NSViewRepresentable {
    let rowID: UUID
    let model: HistoryPanelModel
    let menus: CardMenus

    func makeNSView(context: Context) -> CardMouseView {
        let view = CardMouseView()
        update(view)
        return view
    }

    func updateNSView(_ view: CardMouseView, context: Context) {
        update(view)
    }

    private func update(_ view: CardMouseView) {
        view.rowID = rowID
        view.onPress = { [model] id in model.pressRow(id) }
        view.onRelease = { [model] id, inside in model.releaseRow(id, inside: inside) }
        view.makeMenu = { [model, menus] id in menus.make(model: model, rowID: id) }
    }
}

/// カード 1 枚ぶんの透明な NSView。左のボタンは押したカードの上で離したときだけ貼る（`releaseRow` の inside）。
/// 右クリックと、⌃ を押しながらのクリック（macOS の決まりで右クリックと同じ）はメニューを出し、貼らない。
/// スクロールは受けずに外側（一覧のスクロール）へ流す（NSView の既定のまま）
final class CardMouseView: NSView {
    var rowID: UUID?
    var onPress: (UUID) -> Void = { _ in }
    var onRelease: (UUID, Bool) -> Void = { _, _ in }
    var makeMenu: (UUID) -> NSMenu? = { _ in nil }

    // パネルは前面のアプリを奪わない窓なので、最初のクリックから受ける
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let rowID else { return }
        if event.modifierFlags.contains(.control) {
            if let menu = makeMenu(rowID) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        onPress(rowID)
    }

    override func mouseUp(with event: NSEvent) {
        guard let rowID else { return }
        onRelease(rowID, bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        rowID.flatMap(makeMenu)
    }
}

/// 右クリックのメニューを作る（`CardMenuModel` の並びを NSMenu に写す）。開いている間のメニューを覚えておき、
/// 検証の状態出力と検証用の遠隔操作（項目を選ぶ・閉じる）に使う。パネル 1 つにつき 1 つ（`PanelController` が持つ）
@MainActor
final class CardMenus: NSObject, NSMenuDelegate {
    private(set) weak var openMenu: NSMenu?
    /// 開いているメニューのカード（履歴か定型文の ID）
    private(set) var openRowID: UUID?
    /// 開いた回数（検証用）
    private(set) var openCount = 0
    /// 直近にメニューを作ったカード（検証用。閉じても残す）
    private(set) var lastRowID: UUID?

    func make(model: HistoryPanelModel, rowID: UUID) -> NSMenu? {
        guard let entries = model.menuEntries(forRow: rowID) else { return nil }
        let menu = Self.menu(entries, keymap: model.keymap) { [weak model] action in
            model?.performMenuAction(action, onRow: rowID)
        }
        menu.delegate = self
        openRowID = rowID
        lastRowID = rowID
        return menu
    }

    /// 並びを NSMenu に写す。右に添えるキーは、いまのキーマップの先頭の割り当て（メニューに書けないキーは添えない）
    static func menu(
        _ entries: [CardMenuModel.Entry], keymap: Keymap, choose: @escaping @MainActor (KeyAction) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let menuItem = CardMenuItem(title: item.title, keyAction: item.action) { choose(item.action) }
                if let combo = keymap.primary(item.action), let key = combo.menuKeyEquivalent {
                    menuItem.keyEquivalent = key
                    menuItem.keyEquivalentModifierMask = Self.modifierFlags(combo.modifiers)
                }
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    static func modifierFlags(_ modifiers: HotKey.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        openCount += 1
    }

    func menuDidClose(_ menu: NSMenu) {
        guard openMenu === menu else { return }
        openMenu = nil
        openRowID = nil
    }

    /// 検証用: 開いているメニューの項目を、その操作で選ぶ（メニューを閉じてから、選んだときと同じく項目の処理を送る）。
    /// メニューを開いている間は遠隔操作が届かないので、`PanelController` がメニューの中でも回るタイマーから呼ぶ
    @discardableResult
    func choose(_ action: KeyAction) -> Bool {
        guard let menu = openMenu,
            let index = menu.items.firstIndex(where: { ($0 as? CardMenuItem)?.keyAction == action })
        else { return false }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
        return true
    }

    /// 検証用: 開いているメニューを、何も選ばずに閉じる
    func dismiss() {
        openMenu?.cancelTracking()
    }

    /// 検証用の状態（項目の操作 ID・文言・キーの表記だけ。中身は入れない）
    var debugState: [String: String] {
        let items = (openMenu?.items ?? []).map { item -> String in
            guard let card = item as? CardMenuItem else { return "-" }
            return "\(card.keyAction.rawValue)=\(card.title)(\(Self.keyText(card)))"
        }
        return [
            "menuOpen": String(openMenu != nil),
            "menuOpenCount": String(openCount),
            "menuItems": items.joined(separator: "|"),
        ]
    }

    /// メニューに出ているキーの表記（検証用。⌃⌥⇧⌘ + キー）
    static func keyText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let key = item.keyEquivalent
        if let code = KeyCodes.code(forMenuKeyEquivalent: key), let name = KeyCodes.names[code] { return text + name }
        return text + key.uppercased()
    }
}

/// 右クリックのメニューの 1 項目（選ぶとキーマップの操作を 1 つ行う）
final class CardMenuItem: NSMenuItem {
    let keyAction: KeyAction
    private let handler: @MainActor () -> Void

    init(title: String, keyAction: KeyAction, handler: @escaping @MainActor () -> Void) {
        self.keyAction = keyAction
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    // メニューの項目の処理は AppKit がメインスレッドで送る
    @MainActor @objc private func fire(_ sender: Any?) {
        handler()
    }
}

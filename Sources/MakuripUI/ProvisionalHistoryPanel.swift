import AppKit
import MakuripCore
import SwiftUI

/// 一覧 UI の入口。フェーズ2で本番 UI に差し替えるときは、このターゲット（`Sources/MakuripUI/`）を丸ごと
/// 置き換え、同じ名前の `HistoryUIFactory.make(actions:)` を用意する。
public enum HistoryUIFactory {
    @MainActor
    public static func make(actions: HistoryActions) -> HistoryPresenting {
        ProvisionalHistoryPanel(actions: actions)
    }
}

/// 仮の一覧（フェーズ1）。新しい順に並べ、文字を打てば絞り込み、↑↓ で移動、Enter で貼り付け、Esc で閉じる
@MainActor
final class ProvisionalHistoryPanel: NSObject, HistoryPresenting, NSWindowDelegate {
    private let panel: KeyablePanel
    private let model = HistoryListModel()
    private weak var actions: HistoryActions?
    private var keyMonitor: Any?
    /// 一覧に読み込む最大件数（仮。フェーズ2で遅延読み込みにする）
    private let loadLimit = 500

    init(actions: HistoryActions) {
        self.actions = actions
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: HistoryListView(model: model, onPaste: { [weak self] id in self?.paste(id) }))
    }

    var isVisible: Bool { panel.isVisible }

    var debugState: [String: String] {
        [
            "query": model.query,
            "rowCount": String(model.filtered.count),
            "loadedCount": String(model.allItems.count),
            "selectedIndex": String(model.selectedIndex),
            "selectedKind": model.selected?.kind.rawValue ?? "",
            "windowNumber": String(panel.windowNumber),
        ]
    }

    func show() {
        model.query = ""
        reload()
        model.selectedIndex = 0
        placeOnActiveScreen()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    func historyDidChange() {
        if panel.isVisible { reload() }
    }

    // ほかをクリックしてキーウィンドウでなくなったら閉じる（フォーカスは奪い返さない）
    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { hide() }
    }

    private func reload() {
        model.setItems(actions?.historyItems(limit: loadLimit) ?? [])
    }

    private func paste(_ id: UUID) {
        hide()
        actions?.paste(itemID: id)
    }

    private func cancel() {
        hide()
        actions?.historyDidClose()
    }

    private func placeOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.1))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, windowNumber == self.panel.windowNumber else { return false }
                return self.handleKey(keyCode)
            }
            return consumed ? nil : event
        }
    }

    /// ↑↓ Enter Esc を処理したら true（文字の入力は絞り込み欄へ流す）
    private func handleKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125:  // ↓
            model.moveSelection(by: 1)
        case 126:  // ↑
            model.moveSelection(by: -1)
        case 36, 76:  // Return / テンキーの Enter
            if let item = model.selected { paste(item.id) }
        case 53:  // Esc
            cancel()
        default:
            return false
        }
        return true
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// タイトルバーを隠してもキーウィンドウになれるパネル
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

import AppKit
import MakuripCore
import SwiftUI

/// 定型文の窓の入口（本体は `SnippetController` と、本体に聞くことの `SnippetEditorEnvironment` を渡す）
public enum SnippetEditorUIFactory {
    @MainActor
    public static func make(controller: SnippetController, environment: SnippetEditorEnvironment)
        -> SnippetEditorPresenting
    {
        SnippetEditorWindowController(controller: controller, environment: environment)
    }
}

/// 定型文の窓。設定の窓と同じく、ふつうの窓（Makurip を前面にする。複数行の本文と日本語入力を落ち着いて打てるように）。
///
/// キーは窓のローカル監視で受ける（メインメニューがないため）。決まったキーで、キーマップには載せない（設定の窓と同じ）:
/// ⌘N 新規・⌘S 保存・⌥⌘↑↓ 並べ替え・esc 取り消す／閉じる・⌘W 閉じる。入力欄の外では ↑↓ で選び、⌘⌫ で削除
@MainActor
final class SnippetEditorWindowController: NSObject, SnippetEditorPresenting, NSWindowDelegate {
    let model: SnippetEditorModel
    private let window: NSWindow
    private var keyMonitor: Any?

    init(controller: SnippetController, environment: SnippetEditorEnvironment) {
        model = SnippetEditorModel(controller: controller, environment: environment)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SnippetEditorCSS.width, height: SnippetEditorCSS.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Makurip 定型文"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: SnippetEditorCSS.width, height: 460)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SnippetEditorView(model: model))
        window.center()
        window.setFrameAutosaveName("MakuripSnippets")
        model.effects = SnippetEditorModel.Effects(
            close: { [weak self] in self?.close() },
            confirmDelete: { [weak self] name, answer in self?.confirmDelete(name, answer: answer) })
    }

    var isVisible: Bool { window.isVisible }

    func show(_ request: SnippetEditRequest) {
        model.open(request)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.windowWillClose()
        removeKeyMonitor()
    }

    // MARK: キー

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.windowNumber == self.window.windowNumber else { return false }
                // 日本語入力の変換中は、esc・↑↓ などを入力欄に任せる
                if let text = self.window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
                return self.handle(PanelController.keyPress(event))
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 処理したら true
    func handle(_ press: KeyStroke) -> Bool {
        let editing = window.firstResponder is NSTextView
        switch (press.modifiers, press.keyCode) {
        case (.command, 45):  // ⌘N
            model.beginNew()
        case (.command, 1):  // ⌘S
            model.save()
        case (.command, 13):  // ⌘W
            close()
        case ([.option, .command], KeyCodes.upArrow):
            model.moveSelected(by: -1)
        case ([.option, .command], KeyCodes.downArrow):
            model.moveSelected(by: 1)
        case ([], KeyCodes.escape):
            model.cancel()
        case ([], KeyCodes.upArrow) where !editing:
            model.selectNeighbor(-1)
        case ([], KeyCodes.downArrow) where !editing:
            model.selectNeighbor(1)
        case (.command, KeyCodes.delete) where !editing:
            model.deleteSelected()
        default:
            return performEditCommand(press)
        }
        return true
    }

    /// メインメニューがないので、入力欄の ⌘A・⌘C・⌘V・⌘X・⌘Z・⌘⇧Z をここで送る
    private func performEditCommand(_ press: KeyStroke) -> Bool {
        let selector: Selector?
        if press.modifiers == .command {
            switch press.keyCode {
            case 0: selector = #selector(NSText.selectAll(_:))
            case 8: selector = #selector(NSText.copy(_:))
            case 9: selector = #selector(NSText.paste(_:))
            case 7: selector = #selector(NSText.cut(_:))
            case 6: selector = Selector(("undo:"))
            default: selector = nil
            }
        } else if press.modifiers == [.command, .shift], press.keyCode == 6 {
            selector = Selector(("redo:"))
        } else {
            selector = nil
        }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: window)
    }

    // MARK: 削除の確かめ

    private func confirmDelete(_ name: String, answer: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "「\(name)」を削除しますか？"
        alert.informativeText = "この操作は取り消せません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
        }
    }
}

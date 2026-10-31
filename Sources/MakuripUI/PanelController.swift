import AppKit
import MakuripCore
import SwiftUI

/// 一覧 UI の入口。UI を差し替えるときは、このターゲット（`Sources/MakuripUI/`）を丸ごと置き換え、
/// 同じ名前の `HistoryUIFactory.make(actions:)` を用意する。
public enum HistoryUIFactory {
    @MainActor
    public static func make(actions: HistoryActions) -> HistoryPresenting {
        PanelController(actions: actions)
    }
}

/// 案 B のパネルの窓。文字カーソルの下に出し、元のアプリを前面から外さずにキーを受け取る。
///
/// - 窓は nonactivating な NSPanel。Makurip を前面のアプリにしないので、貼り付けのあと元のアプリへ確実に戻せる
/// - キーは窓の中のローカル監視で受け、`HistoryPanelModel.handle` に渡す（キーマップで操作を引く）。
///   日本語入力の変換中（フィールドエディタの `hasMarkedText`）は何も横取りしない
/// - ⌘Y のプレビューは子ウインドウ（パネルと一緒に動く）。右に入らなければ左に出す
@MainActor
final class PanelController: NSObject, HistoryPresenting, NSWindowDelegate {
    private let panel: KeyablePanel
    private var peek: PeekPanel?
    let model: HistoryPanelModel
    private let loader: ClipContentLoader
    private weak var actions: HistoryActions?
    private var keyMonitor: Any?
    /// 直近に出した位置の手がかりの種類（検証用。座標は出さない）
    private var lastAnchorKind = ""

    init(actions: HistoryActions) {
        self.actions = actions
        model = HistoryPanelModel(actions: actions)
        loader = ClipContentLoader(actions: actions)
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: HistoryPanelView.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let host = NSHostingView(rootView: HistoryPanelView(model: model, loader: loader))
        host.frame = NSRect(origin: .zero, size: HistoryPanelView.size)
        panel.contentView = host

        model.effects = HistoryPanelModel.Effects(
            paste: { [weak self] id, mode in self?.paste(id, mode: mode) },
            close: { [weak self] in self?.cancel() },
            openURL: { [weak self] url in
                self?.hide()
                NSWorkspace.shared.open(url)
            },
            previewChanged: { [weak self] open in self?.setPeekVisible(open) }
        )
    }

    // MARK: HistoryPresenting

    var isVisible: Bool { panel.isVisible }

    var debugState: [String: String] {
        var state = model.debugState
        state["windowNumber"] = String(panel.windowNumber)
        state["anchor"] = lastAnchorKind
        return state
    }

    func show() {
        show(selecting: nil)
    }

    func show(selecting itemID: UUID?) {
        let front = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // 窓を出す前に、前面のアプリの文字カーソルを取る（出した後だと焦点がパネルに移る）
        let anchor = locateAnchor(pid: front?.processIdentifier == ownPID ? nil : front?.processIdentifier)
        model.open(selecting: itemID)
        place(anchor: anchor)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        model.quickModifierHeld = false
        setPeekVisible(false)
        panel.orderOut(nil)
    }

    func historyDidChange() {
        if panel.isVisible { model.reload() }
    }

    // ほかをクリックしてキーウィンドウでなくなったら閉じる（フォーカスは奪い返さない）
    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { hide() }
    }

    // MARK: 操作の結果

    private func paste(_ id: UUID, mode: PasteMode) {
        hide()
        actions?.paste(itemID: id, mode: mode)
    }

    private func cancel() {
        hide()
        actions?.historyDidClose()
    }

    // MARK: 位置

    /// 文字カーソル → 入力欄の枠 → マウスの位置、の順に手がかりを取る（`PanelPlacement` の説明）
    private func locateAnchor(pid: pid_t?) -> PanelAnchor {
        // 検証では起動引数 `-MakuripPanelScreen <画面名>` で出す画面を固定する（E2E が仮想ディスプレイに出すため）
        if UserDefaults.standard.string(forKey: "MakuripPanelScreen") != nil {
            lastAnchorKind = "screen"
            return .none
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let pid, let found = InsertionPointLocator.locate(pid: pid) {
            switch found {
            case .caret(let rect):
                lastAnchorKind = "caret"
                return .caret(PanelPlacement.appKitRect(fromAX: rect, primaryScreenHeight: primaryHeight))
            case .field(let rect):
                lastAnchorKind = "field"
                return .field(PanelPlacement.appKitRect(fromAX: rect, primaryScreenHeight: primaryHeight))
            }
        }
        lastAnchorKind = "mouse"
        return .mouse(NSEvent.mouseLocation)
    }

    private func place(anchor: PanelAnchor) {
        let preferred = UserDefaults.standard.string(forKey: "MakuripPanelScreen")
        let screens: [CGRect]
        if let preferred, let screen = NSScreen.screens.first(where: { $0.localizedName == preferred }) {
            screens = [screen.visibleFrame]
        } else {
            screens = NSScreen.screens.map(\.visibleFrame)
        }
        let frame = PanelPlacement.frame(
            size: HistoryPanelView.size, anchor: anchor, screens: screens, mouse: NSEvent.mouseLocation)
        panel.setFrame(frame, display: false)
    }

    // MARK: ⌘Y のプレビュー

    private func setPeekVisible(_ visible: Bool) {
        if visible, panel.isVisible {
            let peek = self.peek ?? makePeek()
            self.peek = peek
            let frame = PanelPlacement.peekFrame(
                panel: panel.frame, width: PeekView.width, screens: NSScreen.screens.map(\.visibleFrame))
            peek.setFrame(frame, display: false)
            if peek.parent == nil { panel.addChildWindow(peek, ordered: .above) }
            peek.orderFront(nil)
            peek.invalidateShadow()
        } else if let peek {
            panel.removeChildWindow(peek)
            peek.orderOut(nil)
        }
    }

    private func makePeek() -> PeekPanel {
        let peek = PeekPanel(
            contentRect: NSRect(x: 0, y: 0, width: PeekView.width, height: HistoryPanelView.size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        peek.isFloatingPanel = true
        peek.level = .floating
        peek.isReleasedWhenClosed = false
        peek.hidesOnDeactivate = false
        peek.isOpaque = false
        peek.backgroundColor = .clear
        peek.hasShadow = true
        peek.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        peek.contentView = NSHostingView(rootView: PeekView(model: model, loader: loader))
        return peek
    }

    // MARK: キー

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.windowNumber == self.panel.windowNumber else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 処理したら true（false のキーは検索欄へ流す）
    private func handle(_ event: NSEvent) -> Bool {
        let press = Self.keyPress(event)
        if event.type == .flagsChanged {
            let quick = model.keymap.primary(.quickPaste)?.modifiers ?? .command
            model.quickModifierHeld = !quick.isEmpty && press.modifiers.isSuperset(of: quick)
            return false
        }
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        if model.handle(press, isComposing: composing) { return true }
        return !composing && performEditCommand(press)
    }

    /// メインメニューのない常駐アプリなので、検索欄の ⌘A・⌘C・⌘V・⌘X・⌘Z をここで送る
    private func performEditCommand(_ press: KeyStroke) -> Bool {
        let selector: Selector?
        if press.modifiers == .command {
            switch press.keyCode {
            case 0: selector = #selector(NSText.selectAll(_:))  // A
            case 8: selector = #selector(NSText.copy(_:))  // C
            case 9: selector = #selector(NSText.paste(_:))  // V
            case 7: selector = #selector(NSText.cut(_:))  // X
            case 6: selector = Selector(("undo:"))  // Z
            default: selector = nil
            }
        } else if press.modifiers == [.command, .shift], press.keyCode == 6 {
            selector = Selector(("redo:"))
        } else {
            selector = nil
        }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: panel)
    }

    static func keyPress(_ event: NSEvent) -> KeyStroke {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: HotKey.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return KeyStroke(keyCode: event.keyCode, modifiers: modifiers)
    }
}

/// 枠なしでもキーウィンドウになれるパネル（検索欄に文字を打つため）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// ⌘Y のプレビュー。キーは受けない（キーはパネルが受ける）
final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

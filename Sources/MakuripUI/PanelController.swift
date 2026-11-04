import AppKit
import MakuripCore
import SwiftUI

/// 一覧 UI の入口。UI を差し替えるときは、このターゲット（`Sources/MakuripUI/`）を丸ごと置き換え、
/// 同じ名前の `HistoryUIFactory.make(actions:keymap:)` を用意する。
public enum HistoryUIFactory {
    @MainActor
    public static func make(actions: HistoryActions, keymap: Keymap = .default) -> HistoryPresenting {
        PanelController(actions: actions, keymap: keymap)
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
    /// カードの右クリックのメニュー（#38）
    private let menus = CardMenus()
    private weak var actions: HistoryActions?
    private var keyMonitor: Any?
    /// 出したときにキーの焦点を取るか（検証用。隔離した E2E だけが false にする）
    private var takesKeyFocus = true
    /// 検証用のスクロールが当たったビューの型の名前（検証用）
    private var lastScrollHit = ""
    /// 直近に出した位置の手がかりの種類（検証用。座標は出さない）
    private var lastAnchorKind = ""

    init(actions: HistoryActions, keymap: Keymap) {
        self.actions = actions
        model = HistoryPanelModel(actions: actions, keymap: keymap)
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
        let host = NSHostingView(rootView: HistoryPanelView(model: model, loader: loader, menus: menus))
        host.frame = NSRect(origin: .zero, size: HistoryPanelView.size)
        panel.contentView = host

        model.effects = HistoryPanelModel.Effects(
            paste: { [weak self] id, mode in self?.paste(id, mode: mode) },
            close: { [weak self] in self?.cancel() },
            openURL: { [weak self] url in
                self?.hide()
                NSWorkspace.shared.open(url)
            },
            previewChanged: { [weak self] open in self?.setPeekVisible(open) },
            openSettings: { [weak self] in
                self?.hide()
                self?.actions?.openSettings()
            },
            pasteSnippet: { [weak self] id, mode in
                self?.hide()
                self?.actions?.pasteSnippet(id: id, mode: mode)
            },
            editSnippet: { [weak self] request in
                self?.hide()
                self?.actions?.openSnippetEditor(request)
            }
        )
    }

    // MARK: HistoryPresenting

    var isVisible: Bool { panel.isVisible }

    var debugState: [String: String] {
        var state = model.debugState
        state["windowNumber"] = String(panel.windowNumber)
        state["anchor"] = lastAnchorKind
        state.merge(menus.debugState) { _, new in new }
        state["firstVisibleRow"] = firstVisibleRow().map { String($0 + 1) } ?? ""
        state["listScrollY"] = listScrollY().map { String($0) } ?? ""
        state["lastScrollHit"] = lastScrollHit
        state["menuLastRow"] = menus.lastRowID.flatMap(model.rowIndex(of:)).map { String($0 + 1) } ?? ""
        state["panelKey"] = String(panel.isKeyWindow)
        state["takesKeyFocus"] = String(takesKeyFocus)
        return state
    }

    func show() {
        show(selecting: nil)
    }

    func show(selecting itemID: UUID?) {
        present { $0.open(selecting: itemID) }
    }

    func showSnippets() {
        present { $0.open(snippets: true) }
    }

    private func present(_ open: (HistoryPanelModel) -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // 窓を出す前に、前面のアプリの文字カーソルを取る（出した後だと焦点がパネルに移る）
        let anchor = locateAnchor(pid: front?.processIdentifier == ownPID ? nil : front?.processIdentifier)
        open(model)
        place(anchor: anchor)
        panel.alphaValue = 0
        if takesKeyFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
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
        // 隠した内容は必ず隠した状態へ戻し、読んだ秘密の中身もメモリから捨てる
        model.revealHeld = false
        model.revealPressed = false
        loader.purgeSecrets()
        setPeekVisible(false)
        panel.orderOut(nil)
    }

    func historyDidChange() {
        if panel.isVisible { model.reload() }
    }

    func keymapDidChange(_ keymap: Keymap) {
        model.keymap = keymap
    }

    func snippetsDidChange() {
        if panel.isVisible { model.reloadSnippets() }
    }

    // MARK: 検証用の操作（#38）

    func debugPerform(_ request: HistoryDebugRequest) {
        if case .takesKeyFocus(let takes) = request {
            takesKeyFocus = takes
            panel.allowsKey = takes
            return
        }
        guard panel.isVisible else { return }
        switch request {
        case .click(let row, _), .rightClick(let row, _, _), .scroll(let row):
            whenCardVisible(row: row, attempts: 5) { [weak self] in self?.performDebugMouse(request) }
        case .takesKeyFocus:
            break
        }
    }

    /// カードの真ん中が見えていれば、すぐ `body` を呼ぶ。見えていなければ選んで見える位置まで送り、少し待って確かめ直す
    private func whenCardVisible(row: Int, attempts: Int, _ body: @escaping @MainActor () -> Void) {
        if cardView(row: row) != nil || attempts == 0 {
            body()
            return
        }
        model.select(row - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.whenCardVisible(row: row, attempts: attempts - 1, body) }
        }
    }

    private func performDebugMouse(_ request: HistoryDebugRequest) {
        switch request {
        case .click(let row, let releaseInside):
            guard let view = cardView(row: row) else { return }
            let card = view.convert(view.bounds, to: nil)
            let center = NSPoint(x: card.midX, y: card.midY)
            // 外で離すときは、カードの下端よりさらに下（パネルの中の別の場所）で離す
            let release = releaseInside ? center : NSPoint(x: card.midX, y: card.minY - 40)
            panel.sendEvent(mouseEvent(.leftMouseDown, at: center))
            panel.sendEvent(mouseEvent(.leftMouseUp, at: release))
        case .rightClick(let row, let choose, let hold):
            guard let view = cardView(row: row) else { return }
            let card = view.convert(view.bounds, to: nil)
            let event = mouseEvent(.rightMouseDown, at: NSPoint(x: card.midX, y: card.midY))
            // メニューを開いている間は分散通知が届かないので、選ぶ・閉じるのはメニューの中でも回るタイマーで行う
            let timer = Timer(timeInterval: hold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let choose { self.menus.choose(choose) } else { self.menus.dismiss() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            // メニューは閉じるまで戻らないので、遠隔操作の受け取りを先に終わらせてから出す
            DispatchQueue.main.async { [panel] in panel.sendEvent(event) }
        case .scroll(let row):
            guard let view = cardView(row: row), let content = panel.contentView else { return }
            let card = view.convert(view.bounds, to: nil)
            let center = NSPoint(x: card.midX, y: card.midY)
            guard
                let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -400, wheel2: 0, wheel3: 0),
                let event = NSEvent(cgEvent: cgEvent)
            else { return }
            // 合成したスクロールは窓の中の位置が当てにならず、sendEvent では届かない。AppKit と同じく位置で当たるビューを探し、
            // そこへ渡す（カードに重ねた NSView が受けて、一覧のスクロールまで流すかを確かめる）
            let hit = content.hitTest(content.superview?.convert(center, from: nil) ?? center)
            lastScrollHit = hit.map { String(describing: type(of: $0)) } ?? ""
            hit?.scrollWheel(with: event)
        case .takesKeyFocus:
            break
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// 上から `row` 番目（1 始まり）のカードの上の NSView。真ん中が見えていなければ nil（押しても別のところに当たるため）
    private func cardView(row: Int) -> CardMouseView? {
        let ids = model.showsSnippets ? model.snippetItems.map(\.id) : model.items.map(\.id)
        guard ids.indices.contains(row - 1) else { return nil }
        let id = ids[row - 1]
        return cardViews().first {
            $0.rowID == id && !$0.isHiddenOrHasHiddenAncestor
                && $0.visibleRect.contains(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY))
        }
    }

    private func cardViews() -> [CardMouseView] {
        var found: [CardMouseView] = []
        var stack: [NSView] = panel.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let card = view as? CardMouseView { found.append(card) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// 見えているいちばん上のカードの番号（0 始まり。スクロールの検証用）
    private func firstVisibleRow() -> Int? {
        guard panel.isVisible else { return nil }
        let visible = Set(
            cardViews().filter { !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }.compactMap(\.rowID))
        let ids = model.showsSnippets ? model.snippetItems.map(\.id) : model.items.map(\.id)
        return ids.firstIndex { visible.contains($0) }
    }

    /// カードの一覧のスクロールの位置（pt。スクロールの検証用。少ない件数では見えているいちばん上のカードが変わらないので位置で比べる）
    private func listScrollY() -> Int? {
        guard panel.isVisible, let scroll = cardViews().first?.enclosingScrollView else { return nil }
        return Int(scroll.contentView.bounds.origin.y.rounded())
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
            model.revealHeld = model.keymap.isHeld(.reveal, modifiers: press.modifiers)
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

/// 枠なしでもキーウィンドウになれるパネル（検索欄に文字を打つため）。`allowsKey` を false にするのは隔離した E2E だけ
final class KeyablePanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// ⌘Y のプレビュー。キーは受けない（キーはパネルが受ける）
final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

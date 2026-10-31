import AppKit
import MakuripCore
import SwiftUI

/// 候補窓の入口（本体は `CandidateCoordinator` に渡す）
public enum CandidateUIFactory {
    @MainActor
    public static func make(actions: HistoryActions, keymap: Keymap = .default) -> CandidatePresenting {
        CandidatePanelController(actions: actions, keymap: keymap)
    }
}

/// 候補窓の窓。**キーの焦点を取らない**（予測変換と同じく、入力は前面のアプリに残したまま窓だけを出す）。
/// キーは窓ではなく横取りのタップ（本体）が受ける。案 B のパネル（検索欄に打つので焦点を取る）とは窓を分けてある。
///
/// 位置は始めた時点の文字カーソルで決めて固定し、選んでいる行がカーソルの行の高さに来るよう窓を上下させる
/// （`PanelPlacement.frame(... side: .beside(rowOffset:))`）。画面の端では押し戻すので、そのときだけ行がずれる
@MainActor
final class CandidatePanelController: NSObject, CandidatePresenting, NSWindowDelegate {
    private let window: CandidateWindow
    let model: CandidateViewModel
    private let loader: ClipContentLoader
    private var anchor = PanelAnchor.none
    /// 直近に出した位置の手がかりの種類（検証用。座標は出さない）
    private var lastAnchorKind = ""
    var onEvent: ((CandidatePresenterEvent) -> Void)?

    init(actions: HistoryActions, keymap: Keymap) {
        model = CandidateViewModel(keymap: keymap)
        loader = ClipContentLoader(actions: actions)
        window = CandidateWindow(
            contentRect: NSRect(x: 0, y: 0, width: CandidateLayout.width, height: 292),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.delegate = self
        let host = FirstMouseHostingView(rootView: CandidateView(model: model, loader: loader))
        // 窓の大きさと位置はこちらで決める（中身に合わせて勝手に伸び縮みさせない）
        host.sizingOptions = []
        window.contentView = host
        model.onClick = { [weak self] index in self?.onEvent?(.clicked(index)) }
        model.onDoubleClick = { [weak self] index in self?.onEvent?(.doubleClicked(index)) }
    }

    // MARK: CandidatePresenting

    var isVisible: Bool { window.isVisible }

    var debugState: [String: String] {
        ["candidateAnchor": lastAnchorKind, "candidateFirstRow": String(model.firstVisibleRow)]
    }

    func present(_ state: CandidateViewState) {
        if model.state?.sessionID != state.sessionID || !window.isVisible {
            anchor = locateAnchor(pid: state.target?.pid)
        }
        model.update(state)
        let frame = PanelPlacement.frame(
            size: model.windowSize, anchor: anchor, screens: screens(), side: .beside(rowOffset: model.rowOffset),
            mouse: NSEvent.mouseLocation)
        window.setFrame(frame, display: true)
        if !window.isVisible {
            window.orderFrontRegardless()
            window.invalidateShadow()
        }
    }

    func dismiss() {
        window.orderOut(nil)
        // 読んだ秘密の中身はメモリから捨てる
        loader.purgeSecrets()
    }

    func keymapDidChange(_ keymap: Keymap) {
        model.keymap = keymap
    }

    func bump() {
        model.bump()
    }

    func contains(screenPoint: CGPoint) -> Bool {
        guard window.isVisible else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return window.frame.contains(CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y))
    }

    // 何かの理由で窓が閉じられたら、本体に知らせて横取りを外させる
    func windowWillClose(_ notification: Notification) {
        onEvent?(.closed)
    }

    // MARK: 位置

    /// 文字カーソル → 入力欄の枠 → マウスの位置、の順に手がかりを取る（案 B のパネルと同じ）
    private func locateAnchor(pid: pid_t?) -> PanelAnchor {
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

    private func screens() -> [CGRect] {
        if let preferred = UserDefaults.standard.string(forKey: "MakuripPanelScreen"),
            let screen = NSScreen.screens.first(where: { $0.localizedName == preferred })
        {
            return [screen.visibleFrame]
        }
        return NSScreen.screens.map(\.visibleFrame)
    }
}

/// キーの焦点を取らない窓（前面のアプリの入力欄に焦点を残す）
final class CandidateWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 前面でないアプリの窓でも、最初のクリックで行を選べるようにする
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

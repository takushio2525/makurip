import CoreGraphics
import Foundation
import Testing

@testable import MakuripCore

@Suite("候補窓の並びと位置")
struct CandidateSessionTests {
    static func items(_ count: Int) -> [ClipItem] {
        (0..<count).map { CandidateFixtures.item(.text, minutesAgo: Double($0), .text("項目\($0)")) }
    }

    @Test("ターミナル式: 最新がいちばん下、↑ で古いほう、↓ で新しいほう")
    func terminalOrder() {
        var session = CandidateSession(items: Self.items(3), order: .terminal)
        #expect(session.visualOrder == [2, 1, 0])
        #expect(session.selectedVisualRow == 2)
        do {
            let moved = session.move(.up)
            #expect(moved)
        }
        #expect(session.index == 1)
        #expect(session.selectedVisualRow == 1)
        do {
            let moved = session.move(.up)
            #expect(moved)
        }
        do {
            let moved = session.move(.up)
            #expect(!moved, "いちばん古い履歴より上はない")
        }
        #expect(session.index == 2)
        do {
            let moved = session.move(.down)
            #expect(moved)
        }
        #expect(session.index == 1)
    }

    @Test("予測変換式: 最新がいちばん上、↓ で古いほう")
    func imeOrder() {
        var session = CandidateSession(items: Self.items(3), order: .ime)
        #expect(session.visualOrder == [0, 1, 2])
        #expect(session.selectedVisualRow == 0)
        do {
            let moved = session.move(.up)
            #expect(!moved)
        }
        do {
            let moved = session.move(.down)
            #expect(moved)
        }
        #expect(session.index == 1)
        #expect(session.index(ofVisualRow: 2) == 2)
    }

    @Test("0 件・1 件ではどちらにも動かない")
    func emptyAndSingle() {
        var empty = CandidateSession(items: [], order: .terminal)
        #expect(empty.selected == nil)
        do {
            let moved = empty.move(.up)
            #expect(!moved)
        }
        do {
            let moved = empty.move(.down)
            #expect(!moved)
        }
        var single = CandidateSession(items: Self.items(1), order: .terminal)
        do {
            let moved = single.move(.up)
            #expect(!moved)
        }
        do {
            let moved = single.move(.down)
            #expect(!moved)
        }
        #expect(single.selected != nil)
    }

    @Test("寸法は試作と同じ（8 行で 291.5pt。注記は 1 行ぶん）")
    func heights() {
        #expect(CandidateLayout.windowHeight(rowCount: 25, hasNote: false) == 291.5)
        #expect(CandidateLayout.windowHeight(rowCount: 8, hasNote: false) == 291.5)
        #expect(CandidateLayout.windowHeight(rowCount: 1, hasNote: false) == 6 + 30 + 32.5 + 6)
        #expect(CandidateLayout.windowHeight(rowCount: 0, hasNote: false) == 6 + 50 + 32.5 + 6)
        #expect(CandidateLayout.windowHeight(rowCount: 3, hasNote: true) == 6 + 92 + 37.25 + 32.5 + 6)
    }

    @Test("見えている 8 行は、選んでいる行が見えるところまで上から送る（試作と同じ。8 行目より下ならいちばん下の行）")
    func visibleWindow() {
        // ターミナル式・25 件: 最新（いちばん下の行 24）→ 17〜24 が見え、選んだ行はいちばん下
        #expect(CandidateLayout.firstVisibleRow(selectedRow: 24, rowCount: 25) == 17)
        // ↑ でたどっても選んだ行はいちばん下のまま（窓は動かず一覧が流れる）
        #expect(CandidateLayout.firstVisibleRow(selectedRow: 21, rowCount: 25) == 14)
        #expect(CandidateLayout.firstVisibleRow(selectedRow: 7, rowCount: 25) == 0)
        // 上の 8 行の中では、選んだ行が上へ動く
        #expect(CandidateLayout.firstVisibleRow(selectedRow: 3, rowCount: 25) == 0)
        // 行が少なければ全部見える
        #expect(CandidateLayout.firstVisibleRow(selectedRow: 2, rowCount: 3) == 0)
        #expect(CandidateLayout.firstVisibleRow(selectedRow: 0, rowCount: 0) == 0)
    }

    @Test("行の中心までの距離（窓の上端から）")
    func rowOffsets() {
        #expect(CandidateLayout.rowOffset(visibleRow: 0) == 21)
        #expect(CandidateLayout.rowOffset(visibleRow: 7) == CGFloat(238))  // 6 + 7 × 31 + 15
        #expect(CandidateLayout.emptyRowOffset == 31)
    }
}

@Suite("候補窓を出す位置（カーソルの右・選んでいる行をカーソルの行にそろえる）")
struct CandidatePlacementTests {
    let screen = CGRect(x: 0, y: 80, width: 1440, height: 795)
    let caret = CGRect(x: 300, y: 500, width: 2, height: 18)

    func frame(visibleRow: Int, rows: Int = 25, caret: CGRect? = nil) -> CGRect {
        let size = CGSize(
            width: CandidateLayout.width, height: CandidateLayout.windowHeight(rowCount: rows, hasNote: false))
        return PanelPlacement.frame(
            size: size, anchor: .caret(caret ?? self.caret), screens: [screen],
            side: .beside(rowOffset: CandidateLayout.rowOffset(visibleRow: visibleRow)))
    }

    /// 窓の中の `visibleRow` 行目の中心（AppKit の座標）
    func rowCenterY(_ frame: CGRect, _ visibleRow: Int) -> CGFloat {
        frame.maxY - CandidateLayout.rowOffset(visibleRow: visibleRow)
    }

    @Test("選んでいる行の中心が、文字カーソルの行の中心と同じ高さになる（どの行を選んでいても）", arguments: [0, 3, 7])
    func alignsSelectedRow(visibleRow: Int) {
        let frame = frame(visibleRow: visibleRow)
        #expect(rowCenterY(frame, visibleRow) == caret.midY)
        #expect(frame.minX == caret.maxX + PanelPlacement.gap, "カーソルの右に出す")
    }

    @Test("↑ で選んでいる行が上へ動くと、窓が下がってその行がカーソルの高さに来る")
    func windowFollowsSelection() {
        let bottom = frame(visibleRow: 7)
        let above = frame(visibleRow: 6)
        #expect(above.minY == bottom.minY - 31)
    }

    @Test("画面の右端: 入らなければカーソルの左に出す")
    func rightEdgeFlipsLeft() {
        let nearRight = CGRect(x: 1300, y: 500, width: 2, height: 18)
        let frame = frame(visibleRow: 7, caret: nearRight)
        #expect(frame.maxX == nearRight.minX - PanelPlacement.gap)
        #expect(rowCenterY(frame, 7) == nearRight.midY)
    }

    @Test("画面の下端・上端: はみ出さないよう押し戻す（そのときは行がずれてよい）")
    func clampedAtEdges() {
        // ターミナル式で最新（いちばん下の行）を選ぶと窓は上へ伸びる。カーソルが画面の上のほうだと上にはみ出すので押し下げる
        let nearTop = CGRect(x: 300, y: 820, width: 2, height: 18)
        let top = frame(visibleRow: 7, caret: nearTop)
        #expect(top.maxY <= screen.maxY - PanelPlacement.gap)
        #expect(rowCenterY(top, 7) < nearTop.midY)
        // 予測変換式で最新（いちばん上の行）を選ぶと窓は下へ伸びる。画面の下のほうなら押し上げる
        let nearBottom = CGRect(x: 300, y: 100, width: 2, height: 18)
        let bottom = frame(visibleRow: 0, caret: nearBottom)
        #expect(bottom.minY >= screen.minY + PanelPlacement.screenMargin)
        #expect(rowCenterY(bottom, 0) > nearBottom.midY)
    }
}

@Suite("差し替え方式・変換中の判定・呼び出しキーの振り分け")
struct CandidateDecisionTests {
    let settable = TextProbe(
        selection: AXTextRange(location: 4, length: 0), characterCount: 10, selectionSettable: true)

    @Test("始めるときの方式")
    func initialMethod() {
        func method(
            _ timing: PasteTiming = .immediate, _ composing: ComposingState = .idle, override: ReplaceMethod? = nil,
            probe: TextProbe?, failed: Set<ReplaceMethod> = []
        ) -> ReplaceMethod {
            ReplacePlanner.initialMethod(
                timing: timing, composing: composing, override: override, probe: probe, failed: failed)
        }
        var notSettable = settable
        notSettable.selectionSettable = false
        var selected = settable
        selected.selection.length = 3

        #expect(method(probe: settable) == .selectRange)
        #expect(method(probe: notSettable) == .undo)
        #expect(method(probe: selected) == .undo, "始めに選択があれば ⌘Z（選択していた文字を戻せる）")
        #expect(method(probe: nil) == .deferred, "入力欄を読めなければ仮に貼らない")
        #expect(method(.onCommit, probe: settable) == .deferred)
        #expect(method(.immediate, .composing, probe: settable) == .deferred)
        #expect(method(.immediate, .unknown, probe: settable) == .deferred)
        #expect(method(probe: settable, failed: [.selectRange]) == .undo)
        #expect(method(probe: settable, failed: [.selectRange, .undo]) == .deferred)
        #expect(method(probe: notSettable, failed: [.undo]) == .deferred)
        #expect(method(override: .undo, probe: nil) == .undo, "決め打ちなら読めなくても ⌘Z")
        #expect(method(override: .selectRange, probe: nil) == .deferred)
        #expect(method(.onCommit, override: .undo, probe: settable) == .deferred)
    }

    @Test("貼った範囲を測る・選び直せるか・⌘Z で戻ったか")
    func rangeHelpers() {
        let after = TextProbe(
            selection: AXTextRange(location: 14, length: 0), characterCount: 20, selectionSettable: true)
        #expect(
            ReplacePlanner.pastedRange(before: settable, after: after, replacing: nil)
                == AXTextRange(location: 4, length: 10))
        #expect(
            ReplacePlanner.pastedRange(before: settable, after: after, replacing: AXTextRange(location: 2, length: 5))
                == AXTextRange(location: 2, length: 12))
        #expect(ReplacePlanner.pastedRange(before: settable, after: settable, replacing: nil) == nil)

        #expect(ReplacePlanner.canReselect(measured: AXTextRange(location: 4, length: 10), expectedLength: 10))
        #expect(!ReplacePlanner.canReselect(measured: AXTextRange(location: 4, length: 1), expectedLength: nil))
        #expect(!ReplacePlanner.canReselect(measured: AXTextRange(location: 4, length: 9), expectedLength: 10))
        #expect(!ReplacePlanner.canReselect(measured: nil, expectedLength: 10))

        #expect(ReplacePlanner.isRestored(settable, baseline: settable))
        #expect(!ReplacePlanner.isRestored(after, baseline: settable))
        var countOnly = settable
        countOnly.characterCount = 11
        #expect(!ReplacePlanner.isRestored(countOnly, baseline: settable))
    }

    @Test("変換中の判定: AX が答えればそれを信じ、読めなければ入力ソースで安全側に倒す")
    func composingDecision() {
        #expect(ComposingState.decide(markedTextLength: 2, inputMethodActive: true) == .composing)
        #expect(ComposingState.decide(markedTextLength: 0, inputMethodActive: true) == .idle)
        #expect(ComposingState.decide(markedTextLength: nil, inputMethodActive: true) == .unknown)
        #expect(ComposingState.decide(markedTextLength: nil, inputMethodActive: false) == .idle)
    }

    @Test("⌃⌘V の 3 つの動きと ⌃⌥⌘V の振り分け")
    func hotKeyRoutes() {
        func route(
            _ key: HotKeyRouter.Key, _ mode: HotKeyMode, candidate: Bool = false, list: Bool = false
        ) -> HotKeyRouter.Route {
            HotKeyRouter.route(key, mode: mode, candidateActive: candidate, listVisible: list)
        }
        #expect(route(.open, .pasteOnly) == .pasteLatest)
        #expect(route(.open, .candidate) == .startCandidate)
        #expect(route(.open, .list) == .openList)
        for mode in HotKeyMode.allCases {
            #expect(route(.openList, mode) == .openList, "一覧を開くキーは動きに関係なく一覧")
            #expect(route(.open, mode, candidate: true) == .expandCandidate, "候補窓が出ていれば広げる")
            #expect(route(.openList, mode, candidate: true) == .expandCandidate)
            #expect(route(.open, mode, list: true) == .closeList)
            #expect(route(.openList, mode, list: true) == .closeList)
        }
    }
}

@Suite("候補窓の設定と、確定まで貼らないアプリ")
struct CandidateSettingsTests {
    @Test("既定: すぐ貼って候補窓・ターミナル式・10 秒")
    func defaults() {
        let settings = CandidateSettings.default
        #expect(settings.hotKeyMode == .candidate)
        #expect(settings.order == .terminal)
        #expect(settings.idleTimeout == 10)
        #expect(HotKeyMode.allCases.map(\.rawValue) == ["paste", "candidate", "list"], "ID は試作の hotkeyMode と同じ")
        #expect(CandidateOrder.allCases.map(\.rawValue) == ["terminal", "ime"])
    }

    @Test("ターミナルとチャットは確定まで貼らない（大文字・小文字を区別しない）。上書きが優先")
    func timingPerApp() {
        var settings = CandidateSettings.default
        for id in [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            "dev.takushio.tako", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "jp.naver.line.mac",
            "com.apple.MobileSMS", "com.microsoft.teams2", "com.openai.codex", "com.openai.chat",
            "com.anthropic.claudefordesktop",
        ] {
            #expect(settings.timing(for: id) == .onCommit, "\(id)")
        }
        #expect(settings.timing(for: "COM.APPLE.TERMINAL") == .onCommit)
        #expect(settings.timing(for: "com.apple.TextEdit") == .immediate)
        #expect(settings.timing(for: nil) == .immediate)
        settings.pasteTiming = ["com.apple.Terminal": .immediate, "com.apple.TextEdit": .onCommit]
        #expect(settings.timing(for: "com.apple.Terminal") == .immediate)
        #expect(settings.timing(for: "com.apple.TextEdit") == .onCommit)
    }

    @Test("既定の一覧に重なりがなく、ターミナルとチャットの両方がある")
    func appList() {
        let ids = DeferredPasteApps.all.map { $0.bundleID.lowercased() }
        #expect(Set(ids).count == ids.count)
        #expect(DeferredPasteApps.terminals.allSatisfy { $0.category == .terminal })
        #expect(DeferredPasteApps.chats.allSatisfy { $0.category == .chat })
        #expect(DeferredPasteApps.category(of: "com.apple.MobileSMS") == .chat)
        #expect(DeferredPasteApps.category(of: "com.googlecode.iterm2") == .terminal)
    }

}

/// タップに届いたイベントの読み取り（CGEvent はメモリの中で作るだけで、どこにも送らない）
@Suite("横取りのタップの入力")
struct KeyTapInputTests {
    func key(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }

    @Test("キーと修飾キー（矢印に付くテンキー・fn の印は見ない）")
    func keys() throws {
        let up = try key(CGKeyCode(KeyCodes.upArrow), flags: [.maskNumericPad, .maskSecondaryFn])
        #expect(KeyTapInput.make(type: .keyDown, event: up) == .event(.keyDown(KeyStroke(keyCode: KeyCodes.upArrow))))
        let expand = try key(9, flags: [.maskControl, .maskCommand, .maskAlphaShift])
        #expect(
            KeyTapInput.make(type: .keyDown, event: expand)
                == .event(.keyDown(KeyStroke(keyCode: 9, modifiers: [.control, .command]))))
        let tabUp = try key(CGKeyCode(KeyCodes.tab), down: false)
        #expect(KeyTapInput.make(type: .keyUp, event: tabUp) == .event(.keyUp(keyCode: KeyCodes.tab)))
    }

    @Test("Makurip が送ったキーは印で見分けて素通し・タップが止められたら disabled")
    func syntheticAndDisabled() throws {
        let paste = try key(9, flags: .maskCommand)
        paste.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.userData)
        #expect(KeyTapInput.make(type: .keyDown, event: paste) == .synthetic)
        let any = try key(0)
        #expect(KeyTapInput.make(type: .tapDisabledByTimeout, event: any) == .disabled)
        #expect(KeyTapInput.make(type: .tapDisabledByUserInput, event: any) == .disabled)
        #expect(KeyTapInput.make(type: .flagsChanged, event: any) == .ignored)
    }

    @Test("マウスのクリックは位置を渡す")
    func mouse() throws {
        let click = try #require(
            CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 120, y: 340),
                mouseButton: .left))
        #expect(KeyTapInput.make(type: .leftMouseDown, event: click) == .event(.mouseDown(CGPoint(x: 120, y: 340))))
    }
}

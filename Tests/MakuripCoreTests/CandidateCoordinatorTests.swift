import CoreGraphics
import Foundation
import Testing

@testable import MakuripCore

/// 候補窓の流れ一式（偽のアプリの入力欄で、仮貼り → 差し替え → 確定・取り消しを確かめる）
@MainActor
struct CandidateHarness {
    let host: FakeCandidateHost
    let tap = FakeTap()
    let presenter = FakePresenter()
    let scheduler = FakeScheduler()
    let coordinator: CandidateCoordinator

    static let threeTexts: [(ClipKind, FakeContent)] = [
        (.text, .text("最新")), (.command, .text("git status")), (.code, .text("let x = 1")),
    ]

    init(
        items: [(ClipKind, FakeContent)] = Self.threeTexts, editor: FakeEditor = FakeEditor("メモ："),
        bundleID: String? = "com.example.editor", settings: CandidateSettings = .default
    ) {
        host = FakeCandidateHost(items: items, editor: editor, bundleID: bundleID)
        coordinator = CandidateCoordinator(
            host: host, presenter: presenter, tap: tap, scheduler: scheduler, settings: settings)
    }

    var editor: FakeEditor { host.editor }
    func id(_ index: Int) -> UUID { host.items[index].id }

    /// 窓も横取りも残っていない
    func expectClosed(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!coordinator.isActive, sourceLocation: sourceLocation)
        #expect(!tap.isActive, sourceLocation: sourceLocation)
        #expect(!presenter.isVisible, sourceLocation: sourceLocation)
        #expect(scheduler.pendingCount == 0, "無操作の時計が残っている", sourceLocation: sourceLocation)
        // 閉じた後のキーは前面のアプリへ素通し
        #expect(tap.press(KeyCodes.upArrow) == .pass, sourceLocation: sourceLocation)
        #expect(
            coordinator.handle(.keyDown(KeyStroke(keyCode: KeyCodes.escape))) == .pass,
            sourceLocation: sourceLocation)
    }
}

@MainActor
@Suite("候補窓の流れ")
struct CandidateCoordinatorTests {
    // MARK: 仮に貼る・差し替える・確定・取り消し

    @Test("⌃⌘V ですぐ最新を仮に貼り、窓を出して横取りを始める")
    func startPastesNewest() async {
        let h = CandidateHarness()
        #expect(h.coordinator.start() == .started)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：最新")
        #expect(h.tap.isActive)
        #expect(h.presenter.isVisible)
        #expect(h.coordinator.method == .selectRange)
        #expect(h.host.stashCount == 1)
        #expect(h.presenter.last?.selectedIndex == 0)
        #expect(h.presenter.last?.note == nil)
    }

    @Test("↑ で古い履歴に差し替え（範囲を選び直して貼る）、Tab で確定する。確定した項目を先頭へ")
    func replaceAndCommitWithTab() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.press(KeyCodes.upArrow) == .consume)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")
        #expect(h.tap.press(KeyCodes.upArrow) == .consume)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：let x = 1")
        #expect(!h.host.sent.contains(.undo), "範囲を選び直せるアプリでは ⌘Z を使わない")
        // 端ではそれ以上動かず、窓を揺らす
        #expect(h.tap.press(KeyCodes.upArrow) == .consume)
        #expect(h.presenter.bumps == 1)
        // ↓ で 1 つ新しい履歴に戻る
        h.tap.press(KeyCodes.downArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")

        #expect(h.tap.press(KeyCodes.tab) == .consume)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.editor.string == "メモ：git status")
        #expect(h.host.used == [h.id(1)])
        #expect(h.host.restoreCount == 0, "確定した項目をクリップボードに残す")
        #expect(h.editor.pasteboard == .text("git status"))
        #expect(h.coordinator.lastEndReason == .commitKey)
    }

    @Test("Enter でも確定する。改行は入れない")
    func commitWithEnter() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        #expect(h.tap.press(KeyCodes.returnKey) == .consume)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.editor.string == "メモ：git status")
        #expect(!h.editor.string.contains("\n"))
        #expect(h.host.used == [h.id(1)])
    }

    @Test("Esc で貼る前とまったく同じ状態に戻す（文書・選択・クリップボード）")
    func cancelRestoresEverything() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.press(KeyCodes.escape) == .consume)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.editor.string == "メモ：")
        #expect(h.editor.selection == AXTextRange(location: 3, length: 0))
        #expect(h.editor.pasteboard == .text("元のクリップボード"))
        #expect(h.host.restoreCount == 1)
        #expect(h.host.used.isEmpty)
    }

    @Test("広げる: 仮に貼ったものを戻し、選んでいた項目を選んだ状態で一覧を開く")
    func expandOpensListWithSelection() async {
        var settings = CandidateSettings.default
        settings.order = .terminal
        let h = CandidateHarness(settings: settings)
        // 広げるキーを全体のキーと別にすれば、タップで受けて広げる
        h.coordinator.keymap.set([KeyCombo(.code(37), .command)], for: .candidateExpand)  // ⌘L
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.press(37, .command) == .consume)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.editor.string == "メモ：")
        #expect(h.host.openedLists == [h.id(1)])
        #expect(h.editor.pasteboard == .text("元のクリップボード"))
    }

    @Test("⌃⌘V（全体のキー）はタップでは受けず、Carbon のホットキーに任せる（広げるのは本体が route で決める）")
    func globalKeyPassesThrough() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.press(9, [.control, .command]) == .pass)
        #expect(h.tap.press(9, [.control, .option, .command]) == .pass)
        #expect(h.coordinator.isActive, "全体のキーでは閉じない（route が広げる）")
        h.coordinator.expand()
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.host.openedLists == [h.id(0)])
    }

    @Test("選択範囲を書けないアプリは ⌘Z で差し替える（戻ったことを AX で確かめてから貼る）")
    func undoMethod() async {
        let editor = FakeEditor("メモ：")
        editor.settable = false
        let h = CandidateHarness(editor: editor)
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .undo)
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.host.sent == [.paste, .undo, .paste])
        #expect(h.editor.string == "メモ：git status")
        h.tap.press(KeyCodes.escape)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：")
        #expect(h.host.sent.last == .undo)
    }

    @Test("始めに文字を選んでいたら ⌘Z で差し替え、取り消すと選んでいた文字が戻る")
    func selectionAtStartUsesUndo() async {
        let editor = FakeEditor("メモ：置き換える語", selection: AXTextRange(location: 3, length: 6))
        let h = CandidateHarness(editor: editor)
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .undo)
        #expect(h.editor.string == "メモ：最新")
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")
        h.tap.press(KeyCodes.escape)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：置き換える語")
        #expect(h.editor.selection == AXTextRange(location: 3, length: 6))
    }

    @Test("画像（長さが文字数と合わない）は ⌘Z で外し、その前の文字は範囲を選び直して差し替える")
    func imageCandidate() async {
        let h = CandidateHarness(items: [(.text, .text("最新")), (.image, .image), (.command, .text("git status"))])
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：\u{FFFC}")
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")
        #expect(h.host.sent.contains(.undo))
        h.tap.press(KeyCodes.escape)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：")
    }

    @Test("画像を受け付けない入力欄: 貼れなかった画像は仮貼りなしのまま、次の文字は普通に差し替える")
    func imageRejected() async {
        let editor = FakeEditor("メモ：")
        editor.acceptsImages = false
        let h = CandidateHarness(
            items: [(.text, .text("最新")), (.image, .image), (.command, .text("git status"))], editor: editor)
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        // 範囲を選び直した上に貼ろうとしたが何も変わらない（前の中身が選ばれたまま）
        #expect(h.editor.string == "メモ：最新")
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")
        h.tap.press(KeyCodes.tab)
        await h.coordinator.waitUntilIdle()
        #expect(h.host.used == [h.id(2)])
    }

    @Test("範囲を選び直せなかったら ⌘Z に切り替え、そのアプリは次から ⌘Z で始める")
    func selectRangeFailureFallsBackToUndo() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.host.selectAllowed = false
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")
        #expect(h.coordinator.method == .undo)
        h.tap.press(KeyCodes.tab)
        await h.coordinator.waitUntilIdle()

        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .undo)
        #expect(h.editor.string == "メモ：git status最新")
    }

    @Test("⌘Z で戻らないアプリ: ⌘⇧Z で打ち消し、貼ってあるもので閉じる。次からは確定まで貼らない")
    func undoFailureDegrades() async {
        let editor = FakeEditor("メモ：")
        editor.settable = false
        editor.undoWorks = false
        let h = CandidateHarness(editor: editor)
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.coordinator.lastEndReason == .replaceFailed)
        #expect(h.host.sent == [.paste, .undo, .redo])
        #expect(h.editor.string == "メモ：最新")
        #expect(h.host.used == [h.id(0)])

        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .deferred)
        #expect(h.coordinator.note == .replaceUnavailable)
        #expect(h.editor.string == "メモ：最新", "仮に貼らない")
    }

    // MARK: 確定まで貼らないアプリ・変換中

    @Test("ターミナル・チャット: ↑↓ の間は貼らず、Tab で初めて貼る")
    func deferredAppPastesOnCommit() async {
        let h = CandidateHarness(bundleID: "com.apple.Terminal")
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .deferred)
        #expect(h.presenter.last?.note == .deferredApp)
        #expect(h.editor.string == "メモ：")
        #expect(h.host.stashCount == 0)
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        #expect(h.host.sent.isEmpty)
        #expect(h.presenter.last?.selectedIndex == 1)
        h.tap.press(KeyCodes.tab)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.host.sent == [.paste])
        #expect(h.editor.string == "メモ：git status")
        #expect(h.host.used == [h.id(1)])
    }

    @Test("確定まで貼らないアプリで Esc・ほかのキーなら何も貼らない")
    func deferredAppCancel() async {
        let h = CandidateHarness(bundleID: "com.tinyspeck.slackmacgap")
        h.coordinator.start()
        h.tap.press(KeyCodes.upArrow)
        h.tap.press(KeyCodes.escape)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.host.sent.isEmpty)
        #expect(h.host.used.isEmpty)

        h.coordinator.start()
        #expect(h.tap.press(0) == .pass)  // A は前面のアプリへ
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.host.sent.isEmpty)
        #expect(h.editor.string == "メモ：")
    }

    @Test("アプリごとの上書き: ターミナルでもすぐ貼る・普段のアプリでも確定まで貼らない")
    func perAppOverride() async {
        var settings = CandidateSettings.default
        settings.pasteTiming = ["com.apple.Terminal": .immediate, "com.example.editor": .onCommit]
        let terminal = CandidateHarness(bundleID: "com.apple.Terminal", settings: settings)
        terminal.coordinator.start()
        await terminal.coordinator.waitUntilIdle()
        #expect(terminal.editor.string == "メモ：最新")
        let editor = CandidateHarness(settings: settings)
        editor.coordinator.start()
        await editor.coordinator.waitUntilIdle()
        #expect(editor.editor.string == "メモ：")
        #expect(editor.coordinator.note == .deferredApp)
    }

    @Test("変換中に始めたら仮に貼らず、変換中のキーは横取りしない。変換が終われば ↑↓ を受ける")
    func composingAtStart() async {
        let editor = FakeEditor("メモ：")
        editor.markedTextLength = 2
        let h = CandidateHarness(editor: editor)
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .deferred)
        #expect(h.coordinator.note == .composing)
        #expect(h.editor.string == "メモ：")
        #expect(h.tap.press(KeyCodes.upArrow) == .pass)
        #expect(h.tap.press(KeyCodes.returnKey) == .pass, "確定の Enter は日本語入力へ")
        #expect(h.coordinator.isActive)
        #expect(h.coordinator.session.index == 0)
        editor.markedTextLength = 0
        #expect(h.tap.press(KeyCodes.upArrow) == .consume)
        #expect(h.coordinator.session.index == 1)
        h.tap.press(KeyCodes.tab)
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：git status")
    }

    @Test("変換中か判定できない（AX で読めず日本語入力）ときは仮に貼らず、キーは受ける")
    func composingUnknown() async {
        let editor = FakeEditor("メモ：")
        editor.readable = false
        editor.inputMethodActive = true
        let h = CandidateHarness(editor: editor)
        h.coordinator.start()
        #expect(h.coordinator.note == .undetermined)
        #expect(h.tap.press(KeyCodes.upArrow) == .consume)
        await h.coordinator.waitUntilIdle()
        #expect(h.host.sent.isEmpty)
    }

    @Test("入力欄を AX で読めないアプリでは仮に貼らない（⌘Z を確かめずに送らない）")
    func unreadableField() async {
        let editor = FakeEditor("メモ：")
        editor.readable = false
        let h = CandidateHarness(editor: editor)
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.method == .deferred)
        #expect(h.coordinator.note == .unreadable)
        #expect(h.host.sent.isEmpty)
    }

    // MARK: 0 件・始められないとき

    @Test("履歴 0 件: 窓は出す（閉じる・一覧のヒント）。↑ は揺らすだけ、Tab で閉じる")
    func emptyHistory() async {
        let h = CandidateHarness(items: [])
        #expect(h.coordinator.start() == .started)
        #expect(h.presenter.last?.items.isEmpty == true)
        #expect(h.tap.press(KeyCodes.upArrow) == .consume)
        #expect(h.presenter.bumps == 1)
        h.tap.press(KeyCodes.tab)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.host.sent.isEmpty)
        #expect(h.host.used.isEmpty)
    }

    @Test("履歴 1 件: ↑↓ はどちらも端")
    func singleItem() async {
        let h = CandidateHarness(items: [(.text, .text("だけ"))])
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.upArrow)
        h.tap.press(KeyCodes.downArrow)
        #expect(h.presenter.bumps == 2)
        #expect(h.editor.string == "メモ：だけ")
    }

    @Test("許可がない・タップを作れない・前面のアプリがない → 横取りせずに一覧を開く")
    func fallBackToList() {
        let noPermission = CandidateHarness()
        noPermission.host.canPostKeys = false
        #expect(noPermission.coordinator.start() == .openedList)
        #expect(noPermission.tap.startCount == 0)
        #expect(noPermission.host.openedLists.count == 1)

        let noTap = CandidateHarness()
        noTap.tap.canStart = false
        #expect(noTap.coordinator.start() == .openedList)
        #expect(!noTap.presenter.isVisible)
        #expect(noTap.host.sent.isEmpty)

        let noTarget = CandidateHarness()
        noTarget.host.target = nil
        #expect(noTarget.coordinator.start() == .openedList)
        #expect(noTarget.tap.startCount == 0)
    }

    @Test("「すぐ貼るだけ」: 最新を 1 回貼って先頭へ。窓も横取りも使わない")
    func pasteLatestOnly() {
        let h = CandidateHarness()
        #expect(h.coordinator.pasteLatest())
        #expect(h.host.sent == [.paste])
        #expect(h.editor.string == "メモ：最新")
        #expect(h.host.used == [h.id(0)])
        #expect(h.tap.startCount == 0)
        #expect(!h.presenter.isVisible)
        #expect(!CandidateHarness(items: []).coordinator.pasteLatest())
    }

    @Test("後始末の途中で ⌃⌘V を押したら、終わってから始める")
    func startQueuedWhileCleaningUp() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        h.tap.press(KeyCodes.escape)
        #expect(h.coordinator.start() == .queued)
        await h.coordinator.waitUntilIdle()
        #expect(h.coordinator.isActive)
        #expect(h.tap.isActive)
        #expect(h.editor.string == "メモ：最新")
    }

    // MARK: クリック

    @Test("窓の中のクリックは選ぶだけ、ダブルクリックで確定、窓の外のクリックで確定")
    func clicks() async {
        let h = CandidateHarness()
        h.coordinator.start()
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.send(.mouseDown(CGPoint(x: 500, y: 400))) == .pass)
        #expect(h.coordinator.isActive)
        h.presenter.onEvent?(.clicked(2))
        await h.coordinator.waitUntilIdle()
        #expect(h.editor.string == "メモ：let x = 1")
        #expect(h.tap.send(.mouseDown(CGPoint(x: 10, y: 10))) == .pass)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.coordinator.lastEndReason == .clickOutside)
        #expect(h.host.used == [h.id(2)])
    }
}

/// 横取りの寿命: 窓を出している間だけ有効で、どの経路でも外れる（最重要）
@MainActor
@Suite("横取りの寿命")
struct CandidateInterceptLifetimeTests {
    enum Path: String, CaseIterable, CustomTestStringConvertible {
        case tab, enter, escape, expand, otherKey, idle, appSwitch, clickOutside, doubleClick, windowClosed
        case tapDisabled, shutdown, environment

        var testDescription: String { rawValue }

        var reason: CandidateCoordinator.EndReason {
            switch self {
            case .tab, .enter: .commitKey
            case .escape: .cancelKey
            case .expand: .expandKey
            case .otherKey: .otherKey
            case .idle: .idle
            case .appSwitch: .appSwitched
            case .clickOutside: .clickOutside
            case .doubleClick: .doubleClick
            case .windowClosed: .windowClosed
            case .tapDisabled: .tapDisabled
            case .shutdown: .shutdown
            case .environment: .environment
            }
        }

        @MainActor
        func run(_ h: CandidateHarness) {
            switch self {
            case .tab: h.tap.press(KeyCodes.tab)
            case .enter: h.tap.press(KeyCodes.returnKey)
            case .escape: h.tap.press(KeyCodes.escape)
            case .expand: h.coordinator.expand()
            case .otherKey: h.tap.press(0)
            case .idle: h.scheduler.fireAll()
            case .appSwitch: h.coordinator.frontmostAppDidChange(pid: 999)
            case .clickOutside: h.tap.send(.mouseDown(CGPoint(x: 1, y: 1)))
            case .doubleClick: h.presenter.onEvent?(.doubleClicked(0))
            case .windowClosed: h.presenter.onEvent?(.closed)
            case .tapDisabled: h.tap.send(.disabled)
            case .shutdown: h.coordinator.shutdown()
            case .environment: h.coordinator.environmentDidChange()
            }
        }
    }

    @Test("どの経路で閉じても、タップ・窓・無操作の時計が残らない", arguments: Path.allCases, [false, true])
    func everyPathReleasesTap(path: Path, deferred: Bool) async {
        let h = CandidateHarness(bundleID: deferred ? "com.apple.Terminal" : "com.example.editor")
        #expect(h.coordinator.start() == .started)
        await h.coordinator.waitUntilIdle()
        #expect(h.tap.isActive)
        #expect(h.scheduler.pendingCount == 1)
        h.tap.press(KeyCodes.upArrow)
        await h.coordinator.waitUntilIdle()
        path.run(h)
        // 横取りは後始末を待たずにその場で外れる
        #expect(!h.tap.isActive)
        #expect(!h.presenter.isVisible)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.coordinator.lastEndReason == path.reason)
    }

    @Test("同じアプリの中での切り替え通知・窓の中のクリックでは閉じない")
    func samePidKeepsSession() async {
        let h = CandidateHarness()
        h.coordinator.start()
        h.coordinator.frontmostAppDidChange(pid: 4242)
        h.tap.send(.mouseDown(CGPoint(x: 450, y: 350)))
        #expect(h.coordinator.isActive)
        #expect(h.tap.isActive)
    }

    @Test("無操作の時計はキーのたびに掛け直す（古い時計は止める）")
    func idleTimerRearms() async {
        let h = CandidateHarness()
        h.coordinator.start()
        h.tap.press(KeyCodes.upArrow)
        h.tap.press(KeyCodes.downArrow)
        #expect(h.scheduler.pendingCount == 1)
        #expect(h.scheduler.scheduled.allSatisfy { $0.seconds == CandidateSettings.default.idleTimeout })
        h.scheduler.fireAll()
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.coordinator.lastEndReason == .idle)
    }

    @Test("食べたキーの keyUp も食べ、ほかの keyUp は渡す")
    func keyUpPairs() async {
        let h = CandidateHarness()
        h.coordinator.start()
        h.tap.press(KeyCodes.upArrow)
        #expect(h.tap.send(.keyUp(keyCode: KeyCodes.upArrow)) == .consume)
        #expect(h.tap.send(.keyUp(keyCode: KeyCodes.upArrow)) == .pass)
        #expect(h.tap.send(.keyUp(keyCode: 0)) == .pass)
    }

    @Test("閉じた後に古いタップから届いたものは何もしない")
    func lateEventsAreIgnored() async {
        let h = CandidateHarness()
        h.coordinator.start()
        h.coordinator.cancel()
        #expect(h.coordinator.handle(.keyDown(KeyStroke(keyCode: KeyCodes.tab))) == .pass)
        #expect(h.coordinator.handle(.mouseDown(.zero)) == .pass)
        #expect(h.coordinator.handle(.disabled) == .pass)
        await h.coordinator.waitUntilIdle()
        h.expectClosed()
        #expect(h.coordinator.lastEndReason == .cancelKey)
    }
}

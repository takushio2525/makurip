import CoreGraphics
import Foundation

@testable import MakuripCore

/// ペーストボードに載せる中身（テスト用の自作データだけ）
enum FakeContent: Equatable {
    case text(String)
    /// 入力欄には 1 文字の添付として入る
    case image
}

/// 前面のアプリの入力欄の代わり。文字（UTF-16）・選択・取り消しの履歴を持ち、⌘V・⌘Z・⌘⇧Z・⌫ を本物のように処理する
@MainActor
final class FakeEditor {
    var text: [UInt16]
    var selection: AXTextRange
    private(set) var undoStack: [(text: [UInt16], selection: AXTextRange)] = []
    private var redoStack: [(text: [UInt16], selection: AXTextRange)] = []
    var pasteboard: FakeContent? = .text("元のクリップボード")

    /// AX で選択範囲と文字数を読めるか
    var readable = true
    /// AX で選択範囲を書けるか
    var settable = true
    /// ⌘Z が効くか
    var undoWorks = true
    /// 画像を受け付けるか
    var acceptsImages = true
    /// 未確定の文字の長さ（AX で読めない入力欄は nil）
    var markedTextLength: Int? = 0
    /// 入力ソースが日本語入力のかなモードなど
    var inputMethodActive = false

    init(_ string: String, selection: AXTextRange? = nil) {
        text = Array(string.utf16)
        self.selection = selection ?? AXTextRange(location: text.count, length: 0)
    }

    var string: String { String(utf16CodeUnits: text, count: text.count) }

    func paste() {
        let insert: [UInt16]
        switch pasteboard {
        case .text(let string): insert = Array(string.utf16)
        case .image:
            guard acceptsImages else { return }
            insert = [0xFFFC]
        case nil: return
        }
        record()
        text.replaceSubrange(selection.location..<(selection.location + selection.length), with: insert)
        selection = AXTextRange(location: selection.location + insert.count, length: 0)
    }

    func undo() {
        guard undoWorks, let last = undoStack.popLast() else { return }
        redoStack.append((text, selection))
        (text, selection) = (last.text, last.selection)
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        undoStack.append((text, selection))
        (text, selection) = (last.text, last.selection)
    }

    func deleteBackward() {
        if selection.length > 0 {
            record()
            text.removeSubrange(selection.location..<(selection.location + selection.length))
            selection.length = 0
        } else if selection.location > 0 {
            record()
            text.remove(at: selection.location - 1)
            selection.location -= 1
        }
    }

    private func record() {
        undoStack.append((text, selection))
        redoStack = []
    }
}

/// 本体の代わり。送ったキー・先頭へ移した項目・一覧を開いた回数を記録する
@MainActor
final class FakeCandidateHost: CandidateHost {
    var items: [ClipItem]
    var contents: [UUID: FakeContent]
    let editor: FakeEditor
    var target: CandidateTarget?
    var canPostKeys = true
    /// 選択範囲の書き換えを途中から拒むアプリ（範囲の選び直しが効かない）
    var selectAllowed = true
    private var stash: FakeContent??
    private(set) var sent: [SyntheticKey] = []
    private(set) var used: [UUID] = []
    private(set) var openedLists: [UUID?] = []
    private(set) var restoreCount = 0
    private(set) var stashCount = 0

    init(items: [(ClipKind, FakeContent)], editor: FakeEditor, bundleID: String? = "com.example.editor") {
        var list: [ClipItem] = []
        var contents: [UUID: FakeContent] = [:]
        for (offset, entry) in items.enumerated() {
            let item = CandidateFixtures.item(entry.0, minutesAgo: Double(offset), entry.1)
            list.append(item)
            contents[item.id] = entry.1
        }
        self.items = list
        self.contents = contents
        self.editor = editor
        target = CandidateTarget(pid: 4242, bundleID: bundleID)
    }

    func candidateItems() -> [ClipItem] { items }
    func candidateTarget() -> CandidateTarget? { target }

    func composingState(of target: CandidateTarget) -> ComposingState {
        .decide(
            markedTextLength: editor.readable ? editor.markedTextLength : nil,
            inputMethodActive: editor.inputMethodActive)
    }

    func probeText(of target: CandidateTarget) -> TextProbe? {
        guard editor.readable else { return nil }
        return TextProbe(
            selection: editor.selection, characterCount: editor.text.count, selectionSettable: editor.settable)
    }

    func selectText(_ range: AXTextRange, in target: CandidateTarget) -> Bool {
        guard editor.readable, editor.settable, selectAllowed else { return false }
        editor.selection = range
        return true
    }

    func stashPasteboard() {
        stash = .some(editor.pasteboard)
        stashCount += 1
    }

    func restorePasteboard() {
        guard let stash else { return }
        editor.pasteboard = stash
        self.stash = nil
        restoreCount += 1
    }

    func discardPasteboardStash() { stash = nil }

    func writePasteboard(itemID: UUID) -> PastedContent? {
        guard let content = contents[itemID] else { return nil }
        editor.pasteboard = content
        switch content {
        case .text(let string): return PastedContent(textLength: string.utf16.count)
        case .image: return PastedContent(textLength: nil)
        }
    }

    func send(_ key: SyntheticKey, to target: CandidateTarget) {
        sent.append(key)
        switch key {
        case .paste: editor.paste()
        case .undo: editor.undo()
        case .redo: editor.redo()
        case .deleteBackward: editor.deleteBackward()
        }
    }

    func markUsed(itemID: UUID) { used.append(itemID) }
    func openList(selecting itemID: UUID?) { openedLists.append(itemID) }
    func pause(milliseconds: Int) async { await Task.yield() }
}

/// キーの横取りの代わり。止めたら handler を手放す（止めた後に押したキーは素通し）
@MainActor
final class FakeTap: KeyEventTapping {
    private(set) var isActive = false
    var canStart = true
    private var handler: ((KeyTapEvent) -> KeyTapDecision)?
    private(set) var startCount = 0

    func start(_ handler: @escaping @MainActor (KeyTapEvent) -> KeyTapDecision) -> Bool {
        guard canStart else { return false }
        self.handler = handler
        isActive = true
        startCount += 1
        return true
    }

    func stop() {
        isActive = false
        handler = nil
    }

    @discardableResult
    func send(_ event: KeyTapEvent) -> KeyTapDecision {
        handler?(event) ?? .pass
    }

    @discardableResult
    func press(_ keyCode: UInt16, _ modifiers: HotKey.Modifiers = []) -> KeyTapDecision {
        send(.keyDown(KeyStroke(keyCode: keyCode, modifiers: modifiers)))
    }
}

@MainActor
final class FakePresenter: CandidatePresenting {
    private(set) var isVisible = false
    var onEvent: ((CandidatePresenterEvent) -> Void)?
    private(set) var states: [CandidateViewState] = []
    private(set) var bumps = 0
    /// 窓の枠（CoreGraphics の座標）
    var frame = CGRect(x: 400, y: 300, width: 372, height: 292)

    var last: CandidateViewState? { states.last }

    func present(_ state: CandidateViewState) {
        states.append(state)
        isVisible = true
    }

    func dismiss() { isVisible = false }
    func bump() { bumps += 1 }
    func contains(screenPoint: CGPoint) -> Bool { isVisible && frame.contains(screenPoint) }
}

/// 時間を手で進める
@MainActor
final class FakeScheduler: CandidateScheduling {
    final class Pending: CandidateCancellable {
        var action: (@MainActor () -> Void)?
        let seconds: TimeInterval
        init(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            self.seconds = seconds
            self.action = action
        }
        func cancel() { action = nil }
    }

    private(set) var scheduled: [Pending] = []

    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CandidateCancellable {
        let pending = Pending(seconds, action)
        scheduled.append(pending)
        return pending
    }

    var pendingCount: Int { scheduled.filter { $0.action != nil }.count }

    /// 予約された処理をすべて実行する（時間がたったことにする）
    func fireAll() {
        let pending = scheduled
        scheduled = []
        for item in pending { item.action?() }
    }
}

enum CandidateFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ kind: ClipKind, minutesAgo: Double, _ content: FakeContent) -> ClipItem {
        let date = now.addingTimeInterval(-minutesAgo * 60)
        var preview: String?
        if case .text(let string) = content { preview = string }
        return ClipItem(
            id: UUID(), contentHash: UUID().uuidString, kind: kind, copyMethod: .keyboard,
            source: SourceApp(bundleID: "com.example.source", name: "Source"), sourceURL: nil, createdAt: date,
            lastUsedAt: date, copyCount: 1, isPinned: false, flags: [], previewText: preview, totalBytes: 10,
            pasteboardItemCount: 1)
    }
}

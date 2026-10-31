import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MakuripCore

/// 候補窓（`CandidateCoordinator`）が本体に頼むことの実装。AX・入力ソース・ペーストボード・pid 宛てのキー・ストア。
///
/// ペーストボードへの書き込みはすべて `acknowledgeOwnWrite` に渡し、新しい履歴にしない。
/// 取り消し用の控え（貼る前のペーストボード）はメモリの中だけで持ち、保存も記録もしない
@MainActor
final class CandidateBridge: CandidateHost {
    private unowned let app: AppController
    private var stash: PasteboardSnapshot?
    /// 控えるペーストボードの上限（大きい画像などで止まらないように）。超えたら控えず、取り消してもそのままにする
    static let stashLimit = 256 * 1024 * 1024

    init(app: AppController) {
        self.app = app
    }

    func candidateItems() -> [ClipItem] {
        (try? app.store?.items(limit: 100_000)) ?? []
    }

    func candidateTarget() -> CandidateTarget? {
        // 検証では貼り付けの宛先を pid で固定できる（`--debug-control` の setPasteTarget）
        if let pid = app.pasteTargetOverride, let running = NSRunningApplication(processIdentifier: pid) {
            return CandidateTarget(pid: pid, bundleID: running.bundleIdentifier)
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return CandidateTarget(pid: front.processIdentifier, bundleID: front.bundleIdentifier)
    }

    var canPostKeys: Bool { AXIsProcessTrusted() }

    func composingState(of target: CandidateTarget) -> ComposingState {
        .decide(
            markedTextLength: FocusedText.markedTextLength(pid: target.pid),
            inputMethodActive: InputSource.isInputMethodActive())
    }

    func probeText(of target: CandidateTarget) -> TextProbe? {
        FocusedText.probe(pid: target.pid)
    }

    func selectText(_ range: AXTextRange, in target: CandidateTarget) -> Bool {
        FocusedText.select(range, pid: target.pid)
    }

    func stashPasteboard() {
        stash = PasteboardStash.read(app.pasteboard, maxTotalBytes: Self.stashLimit)
    }

    func restorePasteboard() {
        guard let stash else { return }
        self.stash = nil
        let changeCount = PasteboardWriter.write(stash, to: app.pasteboard)
        app.monitor?.acknowledgeOwnWrite(changeCount: changeCount)
    }

    func discardPasteboardStash() {
        stash = nil
    }

    func writePasteboard(itemID: UUID) -> PastedContent? {
        guard let store = app.store, let stored = try? store.snapshot(id: itemID),
            let item = try? store.item(id: itemID)
        else { return nil }
        // 一覧から貼るときと同じく、コマンドはプロンプトを外す。差し替えで選び直す長さも外した後の文字で数える
        let (snapshot, content) = PastePipeline.candidatePaste(stored, kind: item.kind, secret: item.isSecretLikely)
        let changeCount = PasteboardWriter.write(snapshot, to: app.pasteboard)
        app.monitor?.acknowledgeOwnWrite(changeCount: changeCount)
        return content
    }

    func send(_ key: SyntheticKey, to target: CandidateTarget) {
        Paster.post(key, to: target.pid)
    }

    func markUsed(itemID: UUID) {
        try? app.store?.touch(id: itemID)
        app.history?.historyDidChange()
    }

    func openList(selecting itemID: UUID?) {
        app.openList(selecting: itemID)
    }

    func pause(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// いまの入力ソース（Carbon の TIS）
enum InputSource {
    /// 英字以外の入力方式か（日本語入力のかなモードなど。英字モード `*.Roman` と、ふつうの配列は false）
    static func isInputMethodActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            property(source, kTISPropertyInputSourceType) == (kTISTypeKeyboardInputMode as String)
        else { return false }
        return !(property(source, kTISPropertyInputModeID) ?? "").contains("Roman")
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

/// 一定時間後の処理（何も押さないまま時間がたったら候補窓を閉じる）
@MainActor
final class MainScheduler: CandidateScheduling {
    private final class Pending: CandidateCancellable {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CandidateCancellable {
        Pending(
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                action()
            })
    }
}

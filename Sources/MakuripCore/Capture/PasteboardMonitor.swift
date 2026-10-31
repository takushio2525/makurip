import AppKit

/// ペーストボードの変化を監視し、取り込んでストアへ保存する。
///
/// NSPasteboard には変化の通知がないので、`changeCount` を一定間隔で見る（Maccy・Clipy と同じ方式）。
/// 間隔のあいだに複数回コピーされると、最後の 1 回だけが取り込まれる（限界。`.agent/conventions.md`）。
/// ⌘C を見たら（`noteCopyShortcut`）すぐ追加で見に行くので、キー操作のコピーは取りこぼしにくい。
@MainActor
public final class PasteboardMonitor {
    public enum Event: Sendable, Hashable {
        case saved(ClipStore.SaveResult, kind: ClipKind, method: CopyMethod, typeCount: Int, bytes: Int)
        case skipped(SkipReason)
        case failed(String)
    }

    public struct Environment {
        public var now: @MainActor () -> Date
        public var frontmostApp: @MainActor () -> SourceApp?
        /// ⌘C のキー監視が効いているか（効いていなければコピー方法は「不明」）
        public var keyMonitorActive: @MainActor () -> Bool

        public init(
            now: @escaping @MainActor () -> Date,
            frontmostApp: @escaping @MainActor () -> SourceApp?,
            keyMonitorActive: @escaping @MainActor () -> Bool
        ) {
            self.now = now
            self.frontmostApp = frontmostApp
            self.keyMonitorActive = keyMonitorActive
        }
    }

    public let pasteboard: NSPasteboard
    public let interval: TimeInterval
    private let store: ClipStore
    /// 上限（設定で変わる。型 1 つ・1 件の大きさの上限は内部の定数のまま）
    public var limits: Limits
    /// 記録しないアプリ（小文字のバンドル ID）。前面にあるときのコピーはデータを読まずに捨てる
    public var excludedApps: Set<String> = []
    private let environment: Environment
    private var timer: Timer?
    private var lastChangeCount: Int
    private var pendingShortcut: CopyShortcutSignal?
    /// 変化を見つけてから、書き込みが落ち着くのを待っているもの
    private var pendingChange: PendingChange?
    /// 変化を見つけてから読むまで待つ時間。0 ならその場で読む（単体テスト用）
    public let settleDelay: TimeInterval
    static let maxSettleAttempts = 5
    public private(set) var isPaused = false
    /// 取り込みの結果（ログ・UI の再読み込み用）。中身は含まない
    public var onEvent: ((Event) -> Void)?

    public init(
        pasteboard: NSPasteboard, store: ClipStore, limits: Limits, environment: Environment,
        interval: TimeInterval = 0.25, settleDelay: TimeInterval = 0.08
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.limits = limits
        self.environment = environment
        self.interval = interval
        self.settleDelay = settleDelay
        // 起動した時点でペーストボードに載っているものは取り込まない（起動後の変化だけを記録する）
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        stop()
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.poll() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 一時停止中の変化は、再開したあとも取り込まない（再開時点の changeCount から数え直す）
    public func setPaused(_ paused: Bool) {
        isPaused = paused
        lastChangeCount = pasteboard.changeCount
    }

    /// キー監視が ⌘C / ⌘X を見た。少し待ってから何度か見に行く（書き込みの遅いアプリのため）
    public func noteCopyShortcut(_ signal: CopyShortcutSignal) {
        pendingShortcut = signal
        for delay in [0.05, 0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { _ = self?.poll() }
            }
        }
    }

    /// Makurip 自身が書き戻した変化を、新しい履歴として拾わないようにする
    public func acknowledgeOwnWrite(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// 変化があれば取り込む。
    ///
    /// 書き手は clearContents のあと writeObjects で項目を足すが、changeCount が増えるのは clearContents のときだけ。
    /// その途中で読むと項目が欠けたまま取り込んでしまう（残りは二度と見えない）。なので変化を見つけたら型の並びを
    /// 控え、`settleDelay` 待って並びが変わっていないことを確かめてから読む。変わっていればもう一度待つ。
    ///
    /// 戻り値: その場で取り込んだ（`settleDelay` が 0 の）ときの結果。待つときや変化がないときは nil で、
    /// 結果は `onEvent` に届く
    @discardableResult
    public func poll() -> Event? {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current
        let now = environment.now()
        let signal = pendingShortcut
        pendingShortcut = nil

        if isPaused {
            pendingChange = nil
            return emit(.skipped(.paused))
        }
        guard settleDelay > 0 else { return emit(capture(at: now, signal: signal)) }
        pendingChange = PendingChange(
            changeCount: current, detectedAt: now, signal: signal, typeSignature: typeSignature(), attempts: 0)
        scheduleSettle()
        return nil
    }

    private struct PendingChange {
        var changeCount: Int
        var detectedAt: Date
        var signal: CopyShortcutSignal?
        var typeSignature: [[String]]
        var attempts: Int
    }

    private func scheduleSettle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    private func settle() {
        guard var change = pendingChange else { return }
        // 待っている間に次のコピーが来た・書き戻した・一時停止したなら、この変化は捨てる（新しい方は次の poll が拾う）
        guard pasteboard.changeCount == change.changeCount, !isPaused else {
            pendingChange = nil
            return
        }
        let signature = typeSignature()
        if signature != change.typeSignature, change.attempts < Self.maxSettleAttempts {
            change.typeSignature = signature
            change.attempts += 1
            pendingChange = change
            scheduleSettle()
            return
        }
        pendingChange = nil
        emit(capture(at: change.detectedAt, signal: change.signal))
    }

    /// 項目ごとの型名の並び（データは読まない）
    private func typeSignature() -> [[String]] {
        (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
    }

    @discardableResult
    private func emit(_ event: Event) -> Event {
        onEvent?(event)
        return event
    }

    private func capture(at now: Date, signal: CopyShortcutSignal?) -> Event {
        let method = CopyMethodClassifier.classify(
            changeDetectedAt: now, lastShortcutAt: signal?.at, keyMonitorActive: environment.keyMonitorActive())
        // キー操作なら、押した瞬間の前面アプリの方が正確
        let app = (method == .keyboard ? signal?.frontmostApp : nil) ?? environment.frontmostApp()
        if let bundleID = app?.bundleID?.lowercased(), excludedApps.contains(bundleID) {
            return .skipped(.excludedApp)
        }
        // AI の口が保存してから置いたもの（もう一度取り込むと、コピー元が前面のアプリに書き換わる）
        if (pasteboard.types ?? []).contains(NSPasteboard.PasteboardType(PasteboardMarkers.savedByMakuripAI)) {
            return .skipped(.savedByAI)
        }
        switch PasteboardReader.read(pasteboard, maxRepresentationBytes: limits.maxRepresentationBytes) {
        case .excluded:
            return .skipped(.excludedMarker)
        case .snapshot(let snapshot, let dropped):
            let context = CapturePipeline.Context(
                now: now, frontmostApp: app, copyMethod: method, droppedWhileReading: dropped)
            switch CapturePipeline.process(snapshot, context: context, limits: limits) {
            case .skip(let reason):
                return .skipped(reason)
            case .accept(let clip):
                do {
                    let result = try store.save(clip)
                    return .saved(
                        result, kind: clip.kind, method: clip.copyMethod,
                        typeCount: clip.snapshot.items.reduce(0) { $0 + $1.representations.count },
                        bytes: clip.snapshot.totalBytes)
                } catch {
                    return .failed(String(describing: error))
                }
            }
        }
    }
}

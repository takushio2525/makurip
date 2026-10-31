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
    private let limits: Limits
    private let environment: Environment
    private var timer: Timer?
    private var lastChangeCount: Int
    private var pendingShortcut: CopyShortcutSignal?
    public private(set) var isPaused = false
    /// 取り込みの結果（ログ・UI の再読み込み用）。中身は含まない
    public var onEvent: ((Event) -> Void)?

    public init(
        pasteboard: NSPasteboard, store: ClipStore, limits: Limits, environment: Environment,
        interval: TimeInterval = 0.25
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.limits = limits
        self.environment = environment
        self.interval = interval
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

    /// 変化があれば取り込む。変化がなければ nil
    @discardableResult
    public func poll() -> Event? {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current
        let now = environment.now()
        let signal = pendingShortcut
        pendingShortcut = nil

        let event = capture(at: now, signal: signal)
        onEvent?(event)
        return event
    }

    private func capture(at now: Date, signal: CopyShortcutSignal?) -> Event {
        if isPaused { return .skipped(.paused) }
        switch PasteboardReader.read(pasteboard, maxRepresentationBytes: limits.maxRepresentationBytes) {
        case .excluded:
            return .skipped(.excludedMarker)
        case .snapshot(let snapshot, let dropped):
            let method = CopyMethodClassifier.classify(
                changeDetectedAt: now, lastShortcutAt: signal?.at, keyMonitorActive: environment.keyMonitorActive())
            // キー操作なら、押した瞬間の前面アプリの方が正確
            let app = (method == .keyboard ? signal?.frontmostApp : nil) ?? environment.frontmostApp()
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

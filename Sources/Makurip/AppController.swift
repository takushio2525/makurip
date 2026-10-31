import AppKit
import ApplicationServices
import MakuripCore
import MakuripUI

/// アプリ本体。監視・保存・ホットキー・メニュー・一覧 UI・候補窓・貼り付けをつなぐ。
///
/// 一覧 UI とは `HistoryPresenting` / `HistoryActions` だけでやりとりする（フェーズ2で UI を差し替えても、ここは変えない）。
/// 候補窓は `CandidateCoordinator` に任せ、前面のアプリへの操作は `CandidateBridge` を通す。
@MainActor
final class AppController: NSObject, NSApplicationDelegate, HistoryActions {
    let options: LaunchOptions
    let dataDirectory: URL
    /// 既定以外のデータフォルダ（検証用）を使っているか
    let isolated: Bool
    let pasteboard: NSPasteboard
    let limits = Limits.default

    private var instanceLock: InstanceLock?
    private(set) var store: ClipStore?
    private(set) var monitor: PasteboardMonitor?
    private(set) var detector: CopyShortcutDetector?
    let hotKeys = HotKeyCenter()
    private let paster = Paster()
    let keymap = Keymap.default
    private(set) var history: HistoryPresenting?
    private(set) var candidate: CandidateCoordinator?
    private let keyTap = KeyEventTap()
    private var environmentObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusMenu: StatusMenuController?
    private var debugControl: DebugControl?

    /// 一覧を開いたときに前面にいたアプリ（貼り付けの宛先）
    private var previousApp: NSRunningApplication?
    /// 検証用: 貼り付けの宛先を pid で固定する（`--debug-control` のときだけ使う）
    var pasteTargetOverride: pid_t?
    private(set) var lastPasteOutcome: String?

    init(options: LaunchOptions, dataDirectory: URL, isolated: Bool) {
        self.options = options
        self.dataDirectory = dataDirectory
        self.isolated = isolated
        if let name = options.pasteboardName {
            pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        } else {
            pasteboard = .general
        }
    }

    // MARK: 起動・終了

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lock = InstanceLock(directory: dataDirectory) else {
            Log.app.error("同じデータフォルダを使うインスタンスが既に動いているので終了する")
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock

        let store: ClipStore
        do {
            store = try ClipStore(directory: dataDirectory, limits: limits)
            try store.removeOrphanBlobs()
            try store.enforceLimits()
        } catch {
            Log.app.error("履歴を開けなかった: \(String(describing: error), privacy: .public)")
            NSApp.terminate(nil)
            return
        }
        self.store = store

        let detector = CopyShortcutDetector { [weak self] signal in
            self?.monitor?.noteCopyShortcut(signal)
        }
        self.detector = detector

        let monitor = PasteboardMonitor(
            pasteboard: pasteboard, store: store, limits: limits,
            environment: .init(
                now: { Date() },
                frontmostApp: {
                    NSWorkspace.shared.frontmostApplication.map {
                        SourceApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
                    }
                },
                keyMonitorActive: { [weak detector] in detector?.isActive ?? false }
            ))
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        self.monitor = monitor

        history = HistoryUIFactory.make(actions: self)
        let candidate = CandidateCoordinator(
            host: CandidateBridge(app: self), presenter: CandidateUIFactory.make(actions: self, keymap: keymap),
            tap: keyTap, scheduler: MainScheduler(), keymap: keymap, settings: .load(from: .standard))
        candidate.onEvent = { event in Self.log(event) }
        self.candidate = candidate
        observeEnvironment()
        statusMenu = StatusMenuController(controller: self)

        detector.start()
        monitor.start()
        // 呼び出しキーはキーマップ（全操作の ID・既定キー・説明の一覧）から引く。フェーズ4で付け替えられる
        let openKey = keymap.primary(.openHistory)?.hotKey ?? .defaultOpenHistory
        hotKeys.register(openKey, for: .openHistory) { [weak self] in self?.hotKeyPressed(.open) }
        let listKey = keymap.primary(.openList)?.hotKey ?? .defaultOpenList
        hotKeys.register(listKey, for: .openList) { [weak self] in self?.hotKeyPressed(.openList) }

        if options.debugControl {
            if isolated {
                debugControl = DebugControl(controller: self)
            } else {
                Log.app.error("--debug-control は --data-dir と一緒のときだけ有効（既定のデータフォルダでは受け付けない）")
            }
        }
        Log.app.info(
            "起動 version=\(AppIdentity.version, privacy: .public) isolated=\(self.isolated) pasteboard=\(self.options.pasteboardName == nil ? "general" : "named", privacy: .public)"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 横取りを残さない（落ちたときは OS がタップを消す）
        candidate?.shutdown()
        monitor?.stop()
        detector?.stop()
        hotKeys.unregister(.openHistory)
        hotKeys.unregister(.openList)
        for (center, observer) in environmentObservers { center.removeObserver(observer) }
    }

    // MARK: 操作（メニュー・ホットキー・検証用の遠隔操作から呼ぶ）

    /// ⌃⌘V・⌃⌥⌘V。動き（すぐ貼るだけ／すぐ貼って候補窓／一覧を開く）は設定の `hotkeyMode`（`.agent/api.md`）
    func hotKeyPressed(_ key: HotKeyRouter.Key) {
        guard let candidate, let history else { return }
        // 設定画面（#4）ができるまでは UserDefaults を押すたびに読む（defaults write ですぐ切り替えられる）
        candidate.settings = CandidateSettings.load(from: .standard)
        let route = HotKeyRouter.route(
            key, mode: candidate.settings.hotKeyMode, candidateActive: candidate.isActive,
            listVisible: history.isVisible)
        switch route {
        case .expandCandidate:
            candidate.expand()
        case .closeList:
            history.hide()
            historyDidClose()
        case .openList:
            openList(selecting: nil)
        case .startCandidate:
            candidate.start()
        case .pasteLatest:
            // 許可がない・履歴がないときは一覧を開く（許可の案内と空の案内が出る）
            if !candidate.pasteLatest() { openList(selecting: nil) }
        }
    }

    func toggleHistory() {
        guard let history else { return }
        if history.isVisible {
            history.hide()
            historyDidClose()
            return
        }
        openList(selecting: nil)
    }

    /// 一覧を開く。候補窓から広げたときは、候補窓で選んでいた項目を選んだ状態で
    func openList(selecting itemID: UUID?) {
        guard let history, !history.isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        history.show(selecting: itemID)
    }

    /// 候補窓を閉じるきっかけ（前面のアプリの切り替え・スペース・スリープ・画面の構成）を見張る
    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        let activated = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated { self?.candidate?.frontmostAppDidChange(pid: pid) }
        }
        environmentObservers.append((workspace, activated))
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in workspaceNames {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.candidate?.environmentDidChange() }
            }
            environmentObservers.append((workspace, observer))
        }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.candidate?.environmentDidChange() }
        }
        environmentObservers.append((NotificationCenter.default, screens))
    }

    /// 候補窓の出来事をログに残す（メタデータだけ）
    private static func log(_ event: CandidateCoordinator.Event) {
        switch event {
        case .started(let method, let composing, let count):
            Log.paste.info(
                "候補窓 開始 method=\(method.rawValue, privacy: .public) composing=\(composing.rawValue, privacy: .public) items=\(count)"
            )
        case .fellBackToList(let reason):
            Log.paste.info("候補窓を出せないので一覧を開く reason=\(reason, privacy: .public)")
        case .pasted(let method, let changed):
            Log.paste.info("候補窓 仮に貼った method=\(method.rawValue, privacy: .public) changed=\(changed)")
        case .methodFailed(let method, let bundleID):
            Log.paste.error(
                "候補窓 差し替えの方式が効かない method=\(method.rawValue, privacy: .public) app=\(bundleID ?? "-", privacy: .public)"
            )
        case .ended(let reason, let method, let kept):
            Log.paste.info(
                "候補窓 終了 reason=\(reason.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) kept=\(kept)"
            )
        }
    }

    var isPaused: Bool { monitor?.isPaused ?? false }

    func setPaused(_ paused: Bool) {
        monitor?.setPaused(paused)
        Log.capture.info("記録を\(paused ? "一時停止" : "再開", privacy: .public)")
    }

    func clearHistory() {
        guard let store else { return }
        let removed = (try? store.clearUnpinned()) ?? 0
        Log.capture.info("履歴を消去 count=\(removed)")
        history?.historyDidChange()
    }

    var itemCount: Int { (try? store?.count()) ?? 0 }

    // MARK: HistoryActions

    func historyItems(limit: Int) -> [ClipItem] {
        (try? store?.items(limit: limit)) ?? []
    }

    func paste(itemID: UUID) {
        paste(itemID: itemID, mode: .normal)
    }

    func paste(itemID: UUID, mode: PasteMode) {
        guard let store, let monitor, let stored = try? store.snapshot(id: itemID) else { return }
        // 全項目・全型をペーストボードへ戻す（プレーンテキストのときは文字の型だけ）。
        // この変化は新しい履歴にせず、先頭へ移すだけにする
        let snapshot = mode == .plainText ? (stored.plainTextOnly() ?? stored) : stored
        let changeCount = PasteboardWriter.write(snapshot, to: pasteboard)
        monitor.acknowledgeOwnWrite(changeCount: changeCount)
        try? store.touch(id: itemID)
        history?.historyDidChange()

        if mode == .copyOnly {
            // 貼らずにコピーだけ。元いたアプリへフォーカスを返す
            lastPasteOutcome = "copied"
            Log.paste.info("コピーだけ types=\(snapshot.allTypes.count) items=\(snapshot.items.count)")
            historyDidClose()
            debugControl?.writeStatus()
            return
        }
        let target = pasteTargetOverride.flatMap(NSRunningApplication.init(processIdentifier:)) ?? previousApp
        Task { @MainActor in
            let outcome = await paster.paste(into: target)
            lastPasteOutcome = outcome.rawValue
            Log.paste.info(
                "貼り付け outcome=\(outcome.rawValue, privacy: .public) mode=\(mode.rawValue, privacy: .public) types=\(snapshot.allTypes.count) items=\(snapshot.items.count)"
            )
            if outcome == .noPermission { statusMenu?.flashPermissionNeeded() }
            debugControl?.writeStatus()
        }
    }

    func setPinned(_ pinned: Bool, itemID: UUID) {
        do {
            try store?.setPinned(pinned, id: itemID)
            Log.capture.info("ピン留め pinned=\(pinned)")
        } catch {
            Log.capture.error("ピン留めに失敗: \(String(describing: error), privacy: .public)")
        }
    }

    func delete(itemID: UUID) {
        do {
            try store?.delete(id: itemID)
            Log.capture.info("履歴から 1 件削除")
        } catch {
            Log.capture.error("削除に失敗: \(String(describing: error), privacy: .public)")
        }
    }

    func representationInfos(itemID: UUID) -> [RepresentationInfo] {
        (try? store?.representationInfos(id: itemID)) ?? []
    }

    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data? {
        try? store?.data(id: itemID, itemIndex: itemIndex, type: type)
    }

    func historyDidClose() {
        // 貼らずに閉じたら、元いたアプリへフォーカスを返す
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }

    // MARK: 取り込みの結果

    private func handle(_ event: PasteboardMonitor.Event) {
        switch event {
        case .saved(let result, let kind, let method, let typeCount, let bytes):
            let action =
                switch result {
                case .inserted: "inserted"
                case .movedToTop: "movedToTop"
                }
            Log.capture.info(
                "保存 \(action, privacy: .public) kind=\(kind.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) types=\(typeCount) bytes=\(bytes)"
            )
            history?.historyDidChange()
        case .skipped(let reason):
            Log.capture.info("取り込まない reason=\(reason.rawValue, privacy: .public)")
        case .failed(let message):
            Log.capture.error("保存に失敗: \(message, privacy: .public)")
        }
    }

    // MARK: アクセシビリティ

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

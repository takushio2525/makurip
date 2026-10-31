import AppKit
import ApplicationServices
import MakuripCore
import MakuripUI
import ServiceManagement

/// アプリ本体。監視・保存・ホットキー・メニュー・一覧 UI・候補窓・貼り付けをつなぐ。
///
/// 一覧 UI とは `HistoryPresenting` / `HistoryActions` だけでやりとりする（フェーズ2で UI を差し替えても、ここは変えない）。
/// 候補窓は `CandidateCoordinator` に任せ、前面のアプリへの操作は `CandidateBridge` を通す。
/// 設定は `SettingsController` が設定ファイルを見張り、変わった部分だけを `SettingsApplier` がここ（`SettingsApplying`）へ渡す。
@MainActor
final class AppController: NSObject, NSApplicationDelegate, HistoryActions, SettingsApplying {
    let options: LaunchOptions
    let dataDirectory: URL
    /// 既定以外のデータフォルダ（検証用）を使っているか
    let isolated: Bool
    let pasteboard: NSPasteboard

    private var instanceLock: InstanceLock?
    private(set) var store: ClipStore?
    private(set) var monitor: PasteboardMonitor?
    private(set) var detector: CopyShortcutDetector?
    let hotKeys = HotKeyCenter()
    private let paster = Paster()
    /// いまのキーの割り当て（設定から。メニューの表示にも使う）
    private(set) var keymap = Keymap.default
    private(set) var settings: SettingsController?
    private var settingsWindow: SettingsPresenting?
    /// 設定のどこからでも効くキー（記録中は外し、終わったら付け直す）
    private var globalKeys: (open: HotKey?, openList: HotKey?) = (nil, nil)
    private var recordingKeys = false
    /// 直近の呼び出しキーの振り分け（検証の状態出力用）
    private(set) var lastHotKeyRoute: String?
    private(set) var history: HistoryPresenting?
    private(set) var candidate: CandidateCoordinator?
    private let keyTap = KeyEventTap()
    private var environmentObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusMenu: StatusMenuController?
    private var debugControl: DebugControl?

    /// 秘密（確度の高いもの）を自動で消すまでの秒数（設定の secretAutoDeleteMinutes）と、次に消す時刻のタイマー
    private var secretRetention = AppSettings.default.secretRetention
    private var secretSweepTimer: Timer?
    /// 直近に自動で消した件数（検証の状態出力用）
    private(set) var secretsAutoDeleted = 0

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

        // 設定（既定のデータフォルダのときだけ、UserDefaults の時代の候補窓の設定を引き継ぐ）
        let file = SettingsFile(directory: dataDirectory)
        if !isolated {
            do {
                let imported = try SettingsMigration.migrateIfNeeded(
                    file: file, defaults: .standard, domainName: AppIdentity.bundleID)
                if !imported.isEmpty {
                    Log.app.info("UserDefaults の設定を引き継いだ ids=\(imported.joined(separator: ","), privacy: .public)")
                }
            } catch {
                Log.app.error("設定の引き継ぎに失敗: \(String(describing: error), privacy: .public)")
            }
        }
        let settings = SettingsController(file: file)
        self.settings = settings
        for issue in settings.issues {
            Log.app.error("設定ファイルの項目を使わない id=\(issue.id, privacy: .public)")
        }
        keymap = settings.settings.keymap

        let store: ClipStore
        do {
            store = try ClipStore(directory: dataDirectory, limits: settings.settings.limits)
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
            pasteboard: pasteboard, store: store, limits: settings.settings.limits,
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

        history = HistoryUIFactory.make(actions: self, keymap: keymap)
        let candidate = CandidateCoordinator(
            host: CandidateBridge(app: self), presenter: CandidateUIFactory.make(actions: self, keymap: keymap),
            tap: keyTap, scheduler: MainScheduler(), keymap: keymap, settings: settings.settings.candidate)
        candidate.onEvent = { event in Self.log(event) }
        self.candidate = candidate
        observeEnvironment()
        statusMenu = StatusMenuController(controller: self)

        detector.start()
        monitor.start()
        // 呼び出しキー（キーマップの open・openList）の登録・上限・候補窓の設定をここで当てる。
        // 以後は設定ファイルが変わるたびに、変わった部分だけを当て直す（CLI・AI・設定画面のどこから変えても同じ）
        SettingsApplier.apply(settings.settings, previous: nil, to: self)
        settings.observe { [weak self] new, old in
            guard let self else { return }
            SettingsApplier.apply(new, previous: old, to: self)
            self.debugControl?.writeStatus()
        }
        settings.startWatching()
        rescanSecretsIfNeeded(store: store)

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
        secretSweepTimer?.invalidate()
        monitor?.stop()
        detector?.stop()
        settings?.stopWatching()
        hotKeys.unregister(.openHistory)
        hotKeys.unregister(.openList)
        for (center, observer) in environmentObservers { center.removeObserver(observer) }
    }

    // MARK: 操作（メニュー・ホットキー・検証用の遠隔操作から呼ぶ）

    /// ⌃⌘V・⌃⌥⌘V。動き（すぐ貼るだけ／すぐ貼って候補窓／一覧を開く）は設定の `hotkeyMode`（`.agent/api.md`）
    func hotKeyPressed(_ key: HotKeyRouter.Key) {
        guard let candidate, let history else { return }
        let route = HotKeyRouter.route(
            key, mode: candidate.settings.hotKeyMode, candidateActive: candidate.isActive,
            listVisible: history.isVisible)
        lastHotKeyRoute = String(describing: route)
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

    /// いま呼び出しキーを押したら何をするか（押さずに計算する。検証の状態出力用）
    func previewRoute(_ key: HotKeyRouter.Key) -> String? {
        guard let candidate, let history else { return nil }
        return String(
            describing: HotKeyRouter.route(
                key, mode: candidate.settings.hotKeyMode, candidateActive: candidate.isActive,
                listVisible: history.isVisible))
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
        store.scrubDeletedData()
        Log.capture.info("履歴を消去 count=\(removed)")
        history?.historyDidChange()
        scheduleSecretSweep()
    }

    // MARK: 秘密の自動消去・当て直し

    /// 判定の版が上がったとき（初めて入れたときを含む）、既存の履歴に 1 回だけ判定を当て直す（裏のスレッドで）
    private func rescanSecretsIfNeeded(store: ClipStore) {
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { try? SecretRescan.runIfNeeded(store: store) }.value
            guard let self, let found else { return }
            Log.capture.info("既存の履歴に秘密の判定を当て直した found=\(found)")
            self.history?.historyDidChange()
            self.scheduleSecretSweep()
            self.debugControl?.writeStatus()
        }
    }

    /// 時間が来た秘密を消し、次に消す時刻にタイマーを掛け直す（起動・取り込み・設定の変更・タイマーのたびに呼ぶ）
    func scheduleSecretSweep(now: Date = Date()) {
        secretSweepTimer?.invalidate()
        secretSweepTimer = nil
        guard let store, let secrets = try? store.items(flagged: .secretKnownFormat) else { return }
        let expired = SecretExpiry.expired(secrets, now: now, retention: secretRetention)
        if !expired.isEmpty {
            do {
                try store.delete(ids: expired)
                store.scrubDeletedData()
                secretsAutoDeleted += expired.count
                Log.capture.info("秘密を自動で消した count=\(expired.count)")
                history?.historyDidChange()
            } catch {
                Log.capture.error("秘密の自動消去に失敗: \(String(describing: error), privacy: .public)")
            }
        }
        let remaining = secrets.filter { !expired.contains($0.id) }
        guard let next = SecretExpiry.nextDeadline(remaining, now: now, retention: secretRetention) else { return }
        // 時刻で掛けるタイマー（スリープの間に時間が来たら、起きたときに動く）
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleSecretSweep()
                self?.debugControl?.writeStatus()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        secretSweepTimer = timer
    }

    /// 検証の状態出力用（件数と時刻だけ。中身は出さない）
    var secretStatus: [String: Any] {
        let secrets = (try? store?.items(flagged: .secretLikely)) ?? []
        return [
            "count": secrets.count,
            "knownFormat": secrets.filter { $0.flags.contains(.secretKnownFormat) }.count,
            "autoDeleted": secretsAutoDeleted,
            "retentionSeconds": Int(secretRetention),
            "nextSweepAt": secretSweepTimer.map { ISO8601DateFormatter().string(from: $0.fireDate) } ?? "",
        ]
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
        // 全項目・全型をペーストボードへ戻す（プレーンテキストのときは文字の型だけ。コマンドはプロンプトを外す。
        // 秘密は ConcealedType の印を足す）。この変化は新しい履歴にせず、先頭へ移すだけにする
        let item = try? store.item(id: itemID)
        let snapshot = PastePipeline.prepare(
            stored, kind: item?.kind, mode: mode, secret: item?.isSecretLikely ?? false)
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
            let secret = (try? store?.item(id: itemID))?.isSecretLikely ?? false
            try store?.delete(id: itemID)
            // 秘密は消したデータを WAL からも追い出す
            if secret { store?.scrubDeletedData() }
            Log.capture.info("履歴から 1 件削除 secret=\(secret)")
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

    func openSettings() {
        if history?.isVisible == true {
            history?.hide()
        }
        if settingsWindow == nil, let settings {
            settingsWindow = SettingsUIFactory.make(
                controller: settings,
                environment: SettingsEnvironment(
                    appName: { Self.appName(bundleID: $0) },
                    hotKeyRegistered: { [weak self] action in self?.isRegistered(action) },
                    launchAtLoginNote: { [weak self] in self?.launchAtLoginNote },
                    recordingDidChange: { [weak self] recording in self?.setRecordingKeys(recording) }))
        }
        settingsWindow?.show()
    }

    var isSettingsVisible: Bool { settingsWindow?.isVisible ?? false }

    // MARK: SettingsApplying（設定ファイルが変わったら、変わった部分だけ当て直す）

    func applyLimits(_ limits: Limits) {
        monitor?.limits = limits
        do {
            let removed = try store?.setLimits(limits) ?? []
            Log.capture.info(
                "上限を変えた maxItems=\(limits.maxItems) maxTotalBytes=\(limits.maxTotalBytes) removed=\(removed.count)")
            if !removed.isEmpty { history?.historyDidChange() }
        } catch {
            Log.capture.error("上限の当て直しに失敗: \(String(describing: error), privacy: .public)")
        }
    }

    func applyExcludedApps(_ bundleIDs: Set<String>) {
        monitor?.excludedApps = bundleIDs
        Log.capture.info("記録しないアプリ count=\(bundleIDs.count)")
    }

    func applyGlobalKeys(open: HotKey?, openList: HotKey?) {
        globalKeys = (open, openList)
        if !recordingKeys { registerGlobalKeys() }
    }

    func applyKeymap(_ keymap: Keymap) {
        self.keymap = keymap
        history?.keymapDidChange(keymap)
        candidate?.keymap = keymap
    }

    func applyCandidateSettings(_ settings: CandidateSettings) {
        candidate?.settings = settings
        Log.app.info(
            "候補窓の設定 hotkeyMode=\(settings.hotKeyMode.rawValue, privacy: .public) order=\(settings.order.rawValue, privacy: .public)"
        )
    }

    func applySecretRetention(_ retention: TimeInterval) {
        secretRetention = retention
        Log.capture.info("秘密を自動で消すまで seconds=\(Int(retention))")
        // 短くしたら、時間を過ぎたものをその場で消す
        scheduleSecretSweep()
    }

    func applyLaunchAtLogin(_ enabled: Bool) {
        // 検証用に隔離したインスタンスは、本物のログイン項目に触らない
        guard !isolated else {
            Log.app.info("検証用のフォルダなので、ログイン時の起動は登録しない enabled=\(enabled)")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("ログイン時の起動 enabled=\(enabled)")
        } catch {
            Log.app.error("ログイン時の起動を変えられなかった: \(String(describing: error), privacy: .public)")
        }
        settingsWindow?.environmentDidChange()
    }

    private func registerGlobalKeys() {
        hotKeys.unregister(.openHistory)
        hotKeys.unregister(.openList)
        if let open = globalKeys.open {
            hotKeys.register(open, for: .openHistory) { [weak self] in self?.hotKeyPressed(.open) }
        }
        if let openList = globalKeys.openList {
            hotKeys.register(openList, for: .openList) { [weak self] in self?.hotKeyPressed(.openList) }
        }
        settingsWindow?.environmentDidChange()
    }

    /// キーを記録している間は、どこからでも効くキーを外す（⌃⌘V などを記録できるように。Carbon が先に食べてしまうため）
    private func setRecordingKeys(_ recording: Bool) {
        recordingKeys = recording
        if recording {
            hotKeys.unregister(.openHistory)
            hotKeys.unregister(.openList)
        } else {
            registerGlobalKeys()
        }
    }

    private func isRegistered(_ action: KeyAction) -> Bool? {
        guard !recordingKeys else { return nil }
        switch action {
        case .openHistory: return globalKeys.open.map { _ in hotKeys.registered[.openHistory] != nil }
        case .openList: return globalKeys.openList.map { _ in hotKeys.registered[.openList] != nil }
        default: return nil
        }
    }

    private var launchAtLoginNote: String? {
        if isolated { return "検証用のフォルダで動いているので、ログイン項目には登録しません。" }
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "システム設定の「一般 → ログイン項目」で許可が要ります。"
        default: return nil
        }
    }

    /// バンドル ID のアプリの表示名（入っていなければ nil）
    static func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
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
            // 秘密かどうかは印だけを見る（中身は読まない・書かない）
            let flags = (try? store?.item(id: result.id))?.flags ?? []
            let secret =
                flags.contains(.secretKnownFormat) ? "high" : flags.contains(.secretLikely) ? "medium" : "none"
            Log.capture.info(
                "保存 \(action, privacy: .public) kind=\(kind.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) types=\(typeCount) bytes=\(bytes) secret=\(secret, privacy: .public)"
            )
            history?.historyDidChange()
            if flags.contains(.secretKnownFormat) { scheduleSecretSweep() }
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

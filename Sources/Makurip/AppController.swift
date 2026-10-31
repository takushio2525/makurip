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
    /// 定型文（データフォルダの snippets.json。履歴とは別）
    private(set) var snippetStore: SnippetController?
    private var snippetEditor: SnippetEditorPresenting?
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

        let snippetStore = SnippetController(file: SnippetFile(directory: dataDirectory))
        self.snippetStore = snippetStore
        if !snippetStore.issues.isEmpty {
            Log.app.error("定型文のファイルに読めない項目がある count=\(snippetStore.issues.count)")
        }

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
        // 定型文の窓・ファイルの書き換え（AI の口・手）で変わったら、開いている一覧を読み直す
        snippetStore.observe { [weak self] _ in
            self?.history?.snippetsDidChange()
            self?.debugControl?.writeStatus()
        }
        snippetStore.startWatching()

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
        settings?.stopWatching()
        snippetStore?.stopWatching()
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
        // 全項目・全型をペーストボードへ戻す（プレーンテキストのときは文字の型だけ。コマンドはプロンプトを外す）。
        // この変化は新しい履歴にせず、先頭へ移すだけにする
        let snapshot = PastePipeline.prepare(stored, kind: (try? store.item(id: itemID))?.kind, mode: mode)
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

    // MARK: 定型文（#7）

    func snippets() -> [Snippet] {
        snippetStore?.snippets ?? []
    }

    func snippetDateFormat() -> SnippetDateFormat {
        settings?.settings.snippetDateFormat ?? .default
    }

    /// 差し込みを置き換えて書き戻し、元いたアプリへ貼る。書き戻しは新しい履歴にしない（履歴の貼り付けと同じ）。
    /// `{{カーソル}}` があれば、貼った後に文字カーソルをそこへ動かす（AX で確かめられるときだけ）
    func pasteSnippet(id: UUID, mode: PasteMode) {
        guard let monitor, let snippet = snippetStore?.collection.snippet(id: id) else { return }
        let expansion = SnippetTemplate.expand(snippet.body, context: snippetContext(for: snippet.body))
        let snapshot = SnippetPaste.snapshot(for: expansion.text)
        let changeCount = PasteboardWriter.write(snapshot, to: pasteboard)
        monitor.acknowledgeOwnWrite(changeCount: changeCount)
        lastSnippetPaste = (expansion.text.utf16.count, expansion.cursorOffsetFromEnd)

        if mode == .copyOnly {
            lastPasteOutcome = "copied"
            Log.paste.info("定型文をコピーだけ length=\(expansion.text.utf16.count)")
            historyDidClose()
            debugControl?.writeStatus()
            return
        }
        let target = pasteTargetOverride.flatMap(NSRunningApplication.init(processIdentifier:)) ?? previousApp
        Task { @MainActor in
            // 貼る前の入力欄（一覧は前面を奪わないので、宛先のアプリの入力欄のまま）
            let before = target.flatMap { FocusedText.probe(pid: $0.processIdentifier) }
            let outcome = await paster.paste(into: target)
            lastPasteOutcome = outcome.rawValue
            var cursorMoved = false
            if outcome == .pasted, let target, expansion.cursorOffsetFromEnd ?? 0 > 0 {
                cursorMoved = await moveCursor(
                    pid: target.processIdentifier, before: before, insertedLength: expansion.text.utf16.count,
                    offsetFromEnd: expansion.cursorOffsetFromEnd)
            }
            Log.paste.info(
                "定型文を貼り付け outcome=\(outcome.rawValue, privacy: .public) mode=\(mode.rawValue, privacy: .public) length=\(expansion.text.utf16.count) cursorMoved=\(cursorMoved)"
            )
            if outcome == .noPermission { statusMenu?.flashPermissionNeeded() }
            debugControl?.writeStatus()
        }
    }

    /// 直近に貼った定型文の長さと、カーソルの位置（検証の状態出力用。中身は持たない）
    private(set) var lastSnippetPaste: (length: Int, cursorOffsetFromEnd: Int?)?

    /// 差し込みに使う値。{{クリップボード}}・{{言語}} があるときだけ履歴を読む（秘密っぽい項目と、文字でない項目は飛ばす）
    private func snippetContext(for body: String) -> SnippetTemplate.Context {
        var context = SnippetTemplate.Context(now: Date(), dateFormat: snippetDateFormat())
        let used = SnippetTemplate.placeholders(in: body)
        guard used.contains(.clipboard) || used.contains(.language), let store,
            let items = try? store.items(limit: 200)
        else { return context }
        for item in SnippetClipboard.candidates(in: items).prefix(20) {
            guard let snapshot = try? store.snapshot(id: item.id), let text = KindClassifier.plainText(of: snapshot)
            else { continue }
            context.clipboardText = text
            context.language = SnippetClipboard.language(of: text, kind: item.kind)
            break
        }
        return context
    }

    /// 貼った文字の後ろに文字カーソルが来るのを待ってから、{{カーソル}} の位置へ動かす（最大 0.6 秒。合わなければ動かさない）
    private func moveCursor(pid: pid_t, before: TextProbe?, insertedLength: Int, offsetFromEnd: Int?) async -> Bool {
        guard let before else { return false }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            let after = FocusedText.probe(pid: pid)
            if let range = SnippetPaste.cursorTarget(
                before: before, after: after, insertedLength: insertedLength, offsetFromEnd: offsetFromEnd)
            {
                return FocusedText.select(range, pid: pid)
            }
            // まだ貼られていない（カーソルが動いていない）ときだけ待ち続ける
            if let after, after.selection != before.selection { return false }
        }
        return false
    }

    /// 定型文の窓を開く。履歴から作るときは、その項目の文字を本文の下書きにする
    func openSnippetEditor(_ request: SnippetEditRequest) {
        guard let snippetStore else { return }
        if history?.isVisible == true { history?.hide() }
        if snippetEditor == nil {
            snippetEditor = SnippetEditorUIFactory.make(
                controller: snippetStore,
                environment: SnippetEditorEnvironment(dateFormat: { [weak self] in
                    self?.snippetDateFormat() ?? .default
                }))
        }
        var resolved = request
        if case .fromHistory(let itemID) = request {
            let text = (try? store?.snapshot(id: itemID)).flatMap { $0 }.flatMap(KindClassifier.plainText(of:))
            resolved = .new(body: text ?? "")
        }
        snippetEditor?.show(resolved)
    }

    var isSnippetEditorVisible: Bool { snippetEditor?.isVisible ?? false }

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

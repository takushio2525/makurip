import AppKit
import CoreServices
import MakuripCore

/// アプリ内アップデート（#43）。自動の確認（起動したときと 1 日 1 回）・手での確認・「この版は知らせない」・
/// 入れ替えと起動し直しを受け持つ。確かめと入れ替えの本体は Core の `Updater`（`--update` の CLI と同じもの）。
///
/// 外へ送るのは GitHub への版の問い合わせとダウンロードだけ。AI の口（MCP・`--ai`）からは呼べない
@MainActor
final class UpdateController {
    let updater: Updater
    let running: AppVersion?
    /// 置き換える .app（動いているバンドル）
    let appURL: URL
    let dataDirectory: URL
    /// 起動し直すときに渡す起動引数（隔離したインスタンスは同じデータフォルダ・配信元で起き直す）
    let relaunchArguments: [String]

    private(set) var phase: UpdateStatus.Phase = .idle
    private(set) var state: UpdateState
    private(set) var autoCheck = false
    private var timer: Timer?
    private var launchCheck: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// 状態が変わった（設定画面の描き直し・検証の状態出力）
    var onChange: () -> Void = {}

    /// 1 日 1 回
    static let interval: TimeInterval = 24 * 60 * 60
    /// 起動してから最初に確かめるまで（起動を重くしない）
    static let launchDelay: TimeInterval = 5

    init(options: LaunchOptions, dataDirectory: URL, isolated: Bool) {
        let (source, ignored) = UpdateSource.resolve(override: options.updateFeed, isolated: isolated)
        if ignored {
            Log.app.error("--update-feed は --data-dir と一緒のときだけ有効（GitHub の Release を見る）")
        }
        let policy = UpdatePolicy.resolve(
            isolated: isolated, source: source, allowUnnotarized: options.allowUnnotarizedUpdate)
        updater = Updater(
            source: source, policy: policy,
            transport: URLSessionUpdateTransport(userAgent: "Makurip/\(AppIdentity.version)"),
            stateFile: UpdateStateFile(directory: dataDirectory))
        running = AppVersion(AppIdentity.version)
        appURL = Bundle.main.bundleURL
        self.dataDirectory = dataDirectory
        relaunchArguments = options.relaunchArguments
        state = updater.stateFile.load()
        observeInstalledSignal()
        Log.app.info(
            "アップデート feed=\(source.overridden ? "overridden" : "github", privacy: .public) notarization=\(policy.requireNotarization)"
        )
    }

    // MARK: 状態

    var status: UpdateStatus {
        var blocked: String?
        do {
            try Updater.checkLocation(appURL)
        } catch {
            blocked = (error as? UpdateFailure)?.message
        }
        return UpdateStatus(
            currentVersion: running?.description ?? AppIdentity.version, phase: phase,
            availability: running.map { state.availability(current: $0) } ?? .upToDate,
            lastCheckedAt: state.lastCheckedAt, lastCheckError: phase == .idle ? state.lastError : nil,
            autoCheck: autoCheck, blockedReason: blocked)
    }

    var settingsEnvironment: UpdateEnvironment {
        UpdateEnvironment(
            status: { [weak self] in self?.status ?? UpdateStatus(currentVersion: AppIdentity.version) },
            check: { [weak self] in self?.check(presentResult: false) },
            install: { [weak self] in self?.install(presentFailure: true) },
            skip: { [weak self] in self?.skip() })
    }

    /// 検証の状態出力用（版と結果だけ）
    var debugState: [String: Any] {
        let status = status
        var phaseText: String
        switch phase {
        case .idle: phaseText = "idle"
        case .checking: phaseText = "checking"
        case .installing(let step): phaseText = "installing:\(step.rawValue)"
        case .failed: phaseText = "failed"
        }
        return [
            "currentVersion": status.currentVersion,
            "phase": phaseText,
            "availability": status.availability.code,
            "latestVersion": state.latest?.version.description ?? "",
            "skippedVersion": state.skippedVersion ?? "",
            "lastCheckedAt": state.lastCheckedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "lastError": phase.failureReason ?? state.lastError ?? "",
            "autoCheck": autoCheck,
            "timerActive": timer != nil,
            "feedOverridden": updater.source.overridden,
            "notarizationRequired": updater.policy.requireNotarization,
            "installable": status.blockedReason == nil,
        ]
    }

    // MARK: 自動の確認

    /// 設定の autoUpdateCheck（起動したときにも呼ばれる）。オンなら少し後に確かめて 1 日 1 回の時計を掛け、オフなら止める
    func setAutoCheck(_ enabled: Bool) {
        autoCheck = enabled
        timer?.invalidate()
        timer = nil
        launchCheck?.cancel()
        launchCheck = nil
        if enabled {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.check(presentResult: false) }
            }
            launchCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay, execute: work)
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(presentResult: false) }
            }
            timer.tolerance = 60 * 60
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        Log.app.info("アップデートの自動の確認 enabled=\(enabled)")
        onChange()
    }

    // MARK: 確かめる

    /// 確かめる。`presentResult` のときは結果を窓で出す（メニューの「アップデートを確認…」）
    func check(presentResult: Bool) {
        guard let running, !status.isBusy else { return }
        phase = .checking
        onChange()
        let updater = updater
        Task { [weak self] in
            let result = await updater.check(running: running)
            guard let self else { return }
            self.phase = .idle
            self.state = updater.stateFile.load()
            switch result {
            case .success(let availability):
                Log.app.info(
                    "アップデートを確かめた result=\(availability.code, privacy: .public) latest=\(availability.release?.version.description ?? "-", privacy: .public)"
                )
            case .failure(let failure):
                Log.app.error("アップデートを確かめられなかった error=\(failure.code, privacy: .public)")
            }
            self.onChange()
            if presentResult { self.presentCheckResult(result) }
        }
    }

    /// 「この版は知らせない」
    func skip() {
        guard let latest = state.latest else { return }
        state = updater.stateFile.update { $0.skippedVersion = latest.version.description }
        if case .failed = phase { phase = .idle }
        Log.app.info("この版は知らせない version=\(latest.version.description, privacy: .public)")
        onChange()
    }

    // MARK: 入れ替える

    /// 見つけた最新の版に入れ替えて起動し直す。失敗したら今の版のまま理由を出す（`presentFailure` なら窓でも）
    func install(presentFailure: Bool) {
        guard let running, let release = state.latest, release.version > running, !status.isBusy else { return }
        phase = .installing(.download)
        onChange()
        let updater = updater
        let appURL = appURL
        // 進んだ段をメニューと設定画面に出す（入れ替えは裏のスレッドで進む）
        let report: @Sendable (Updater.Step) -> Void = { [weak self] step in
            let controller = self
            Task { @MainActor in
                guard let controller, case .installing = controller.phase else { return }
                controller.phase = .installing(step)
                controller.onChange()
            }
        }
        Task { [weak self] in
            let failure: UpdateFailure? = await Task.detached {
                do {
                    try await updater.install(release, replacing: appURL, running: running, progress: report)
                    return nil
                } catch {
                    return error as? UpdateFailure ?? .replaceFailed("不明")
                }
            }.value
            guard let self else { return }
            if let failure {
                self.phase = .failed(failure.message)
                self.state = updater.stateFile.update { $0.lastError = failure.message }
                Log.app.error("アップデートできなかった error=\(failure.code, privacy: .public)")
                self.onChange()
                if presentFailure { self.presentInstallFailure(failure) }
                return
            }
            Log.app.info("アップデートした version=\(release.version.description, privacy: .public)。起動し直す")
            self.state = updater.stateFile.update {
                $0.lastError = nil
                $0.skippedVersion = nil
            }
            LSRegisterURL(appURL as CFURL, true)
            self.relaunch()
        }
    }

    /// 自分が終わるのを待ってから、同じ場所の .app を同じ起動引数で開き直す小さな sh を残して終了する。
    /// 開き直すときは前面に出さない（-g。使っているアプリからフォーカスを奪わない）
    func relaunch() {
        let script = """
            pid="$1"; app="$2"; shift 2
            i=0
            while /bin/kill -0 "$pid" 2>/dev/null; do
              i=$((i+1)); [ "$i" -gt 600 ] && exit 1
              /bin/sleep 0.1
            done
            if [ "$#" -gt 0 ]; then exec /usr/bin/open -n -g "$app" --args "$@"; else exec /usr/bin/open -n -g "$app"; fi
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments =
            ["-c", script, "makurip-relaunch", String(ProcessInfo.processInfo.processIdentifier), appURL.path]
            + relaunchArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.error("起動し直す手配ができなかった: \(String(describing: error), privacy: .public)")
            phase = .failed("入れ替えたが、起動し直せなかった。Makurip を開き直してください")
            onChange()
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: --update apply（別のプロセス）が入れ替えた

    /// `UpdateInstalledSignal` を受けたら、ディスクの .app の版が動いている版と違うときだけ起動し直す
    private func observeInstalledSignal() {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: UpdateInstalledSignal.name, object: HistoryChangeSignal.object(for: dataDirectory), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installedElsewhere() }
        }
        observers.append(observer)
    }

    private func installedElsewhere() {
        let onDisk =
            NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))?[
                "CFBundleShortVersionString"] as? String
        guard let onDisk, let version = AppVersion(onDisk), version != running, !status.isBusy else {
            Log.app.info("入れ替えの知らせを受けたが、ディスクの版が同じなので起動し直さない")
            return
        }
        Log.app.info("ほかのプロセスが v\(onDisk, privacy: .public) に入れ替えたので起動し直す")
        state = updater.stateFile.load()
        relaunch()
    }

    // MARK: 窓（メニューから手で操作したときだけ。検証の遠隔操作では出さない）

    private func presentCheckResult(_ result: Result<UpdateAvailability, UpdateFailure>) {
        NSApp.activate()
        let alert = NSAlert()
        switch result {
        case .failure(let failure):
            alert.messageText = "アップデートを確かめられませんでした"
            alert.informativeText = failure.message
            alert.alertStyle = .warning
            alert.runModal()
        case .success(.upToDate):
            alert.messageText = "Makurip は最新です"
            alert.informativeText = "v\(running?.description ?? AppIdentity.version) が最新の版です。"
            alert.runModal()
        case .success(.available(let release)), .success(.skipped(let release)):
            alert.messageText = "新しい版 v\(release.version) があります"
            if let blocked = status.blockedReason {
                alert.informativeText = "今は v\(running?.description ?? "?") です。\(blocked)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            alert.informativeText = "今は v\(running?.description ?? "?") です。アップデートすると、Makurip を起動し直します。"
            alert.addButton(withTitle: "アップデートして再起動")
            alert.addButton(withTitle: "この版は知らせない")
            alert.addButton(withTitle: "あとで")
            switch alert.runModal() {
            case .alertFirstButtonReturn: install(presentFailure: true)
            case .alertSecondButtonReturn: skip()
            default: break
            }
        }
    }

    private func presentInstallFailure(_ failure: UpdateFailure) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "アップデートできませんでした"
        alert.informativeText = failure.message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension UpdateStatus.Phase {
    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

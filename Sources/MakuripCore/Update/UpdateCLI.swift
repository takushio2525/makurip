import Foundation

/// `Makurip [--data-dir DIR] --update status|check|apply [--json]` の本体。並びは tako の `tako update` と同じ。
///
/// - `status`: 今の版・置き場所・自動の確認・最後に確かめた結果（問い合わせない）
/// - `check`: GitHub の Release に新しい版があるかを確かめる（入れ替えない）
/// - `apply`: 新しい版があれば、落として確かめ、今の .app を置き換える。同じデータフォルダで Makurip が動いていれば、
///   起動し直してもらう（`UpdateInstalledSignal`）
///
/// AI の口（MCP・`--ai`）からは呼べない（道具に足さない。`UpdateAIExclusionTests` が守る）
public struct UpdateCLI: Sendable {
    public typealias Output = SettingsCLI.Output

    public struct Environment: Sendable {
        /// 動いている版（Info.plist から。読めなければ nil）
        public var running: AppVersion?
        /// 置き換える .app（実行ファイルを含むバンドル）
        public var appURL: URL
        /// 設定の「アップデートを自動で確認」
        public var autoCheck: Bool
        /// 使い方に出すコマンド
        public var command: String
        /// 同じデータフォルダで Makurip（アプリ）が動いているか
        public var appRunning: @Sendable () -> Bool
        /// 入れ替えたことを、動いている Makurip に知らせる（起動し直してもらう）
        public var notifyInstalled: @Sendable () -> Void
        /// 進み具合（標準エラーに 1 行ずつ）
        public var progress: @Sendable (String) -> Void
        /// `--update-feed` を付けたが、隔離していない（`--data-dir` なし）ので使わなかった
        public var ignoredOverride: Bool

        public init(
            running: AppVersion?, appURL: URL, autoCheck: Bool, command: String = "Makurip --update",
            appRunning: @escaping @Sendable () -> Bool = { false },
            notifyInstalled: @escaping @Sendable () -> Void = {},
            progress: @escaping @Sendable (String) -> Void = { _ in }, ignoredOverride: Bool = false
        ) {
            self.running = running
            self.appURL = appURL
            self.autoCheck = autoCheck
            self.command = command
            self.appRunning = appRunning
            self.notifyInstalled = notifyInstalled
            self.progress = progress
            self.ignoredOverride = ignoredOverride
        }
    }

    public let updater: Updater
    public let environment: Environment

    public init(updater: Updater, environment: Environment) {
        self.updater = updater
        self.environment = environment
    }

    public func run(_ arguments: [String]) async -> Output {
        var args = arguments
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        guard let verb = args.first, args.count == 1 else {
            return Output(stderr: usageText, exitCode: SettingsCLI.ExitCode.usage)
        }
        switch verb {
        case "help", "-h", "--help": return Output(stdout: usageText)
        case "status": return status(json: json)
        case "check", "apply":
            if environment.ignoredOverride {
                return Output(
                    stderr:
                        "--update-feed は --data-dir と一緒のときだけ効く。付けないまま確かめると本物の配信元を見て、本物の Makurip を置き換えうるので止めた\n",
                    exitCode: SettingsCLI.ExitCode.usage)
            }
            guard let running = environment.running else {
                return Output(stderr: "今の版を読めない（Info.plist）\n", exitCode: SettingsCLI.ExitCode.io)
            }
            return verb == "check"
                ? await check(running: running, json: json) : await apply(running: running, json: json)
        default:
            return Output(stderr: "知らない命令: \(verb)\n\n" + usageText, exitCode: SettingsCLI.ExitCode.usage)
        }
    }

    public var usageText: String {
        """
        使い方: \(environment.command) <命令> [--json]

          status   今の版・置き場所・自動の確認・最後に確かめた結果（問い合わせない）
          check    GitHub の Release に新しい版があるかを確かめる（入れ替えない）
          apply    新しい版があれば、落として確かめ（sha256・署名・公証）、今の Makurip.app を置き換える。
                   Makurip が動いていれば起動し直す

          --json   機械が読む形で出す

        終了コード: 0 成功（新しい版がないときも）・1 使い方の誤り・2 確かめに通らないので入れ替えなかった・3 通信やファイルの失敗。
        どこで止まっても、今の版のまま。

        """
    }

    // MARK: status

    private func status(json: Bool) -> Output {
        let state = updater.stateFile.load()
        let running = environment.running
        let availability = running.map { state.availability(current: $0) }
        var blocked: UpdateFailure?
        do {
            try Updater.checkLocation(environment.appURL)
        } catch {
            blocked = error as? UpdateFailure
        }
        let warning =
            environment.ignoredOverride ? "注意: --update-feed は --data-dir と一緒のときだけ効く（今は GitHub を見る）\n" : ""
        if json {
            var root: [String: JSONValue] = [
                "currentVersion": running.map { .string($0.description) } ?? .null,
                "appPath": .string(environment.appURL.path),
                "installable": .bool(blocked == nil),
                "autoCheck": .bool(environment.autoCheck),
                "feed": .string(updater.source.overridden ? "overridden" : "github"),
                "notarizationRequired": .bool(updater.policy.requireNotarization),
                "lastCheckedAt": state.lastCheckedAt.map { .string(Self.iso($0)) } ?? .null,
                "latestVersion": state.latest.map { .string($0.version.description) } ?? .null,
                "skippedVersion": state.skippedVersion.map(JSONValue.string) ?? .null,
                "lastError": state.lastError.map(JSONValue.string) ?? .null,
            ]
            root["installBlockedReason"] = blocked.map { .string($0.code) } ?? .null
            root["available"] = .bool(availability?.isAvailable ?? false)
            return Output(stdout: SettingsCLI.pretty(.object(root)), stderr: warning)
        }
        var lines = ["Makurip \(running?.description ?? "（版を読めない）")"]
        lines.append(
            "置き場所: \(environment.appURL.path)（\(blocked.map { "置き換えられない: \($0.message)" } ?? "置き換えられる")）")
        lines.append("自動の確認: \(environment.autoCheck ? "オン（起動したときと 1 日 1 回）" : "オフ")")
        lines.append(
            "配信元: \(updater.source.overridden ? "差し替え（検証用）" : "GitHub の Release（\(UpdateSource.repository)）")"
                + (updater.policy.requireNotarization ? "" : "・公証の確かめを外している（検証用）"))
        lines.append("最後に確かめた: \(state.lastCheckedAt.map(Self.local) ?? "まだ")")
        if let availability { lines.append("結果: \(Self.describe(availability, running: running))") }
        if let error = state.lastError { lines.append("直近の失敗: \(error)") }
        return Output(stdout: lines.joined(separator: "\n") + "\n", stderr: warning)
    }

    // MARK: check

    private func check(running: AppVersion, json: Bool) async -> Output {
        environment.progress("Release を確かめています…")
        switch await updater.check(running: running) {
        case .failure(let failure):
            return failureOutput(failure, json: json)
        case .success(let availability):
            if json {
                return Output(
                    stdout: SettingsCLI.pretty(
                        .object([
                            "result": .string(availability.code), "currentVersion": .string(running.description),
                            "latestVersion": availability.release.map { .string($0.version.description) } ?? .null,
                            "available": .bool(availability.isAvailable),
                        ])))
            }
            var text = Self.describe(availability, running: running) + "\n"
            if availability.release != nil { text += "入れ替えるには: \(environment.command) apply\n" }
            return Output(stdout: text)
        }
    }

    // MARK: apply

    private func apply(running: AppVersion, json: Bool) async -> Output {
        environment.progress("Release を確かめています…")
        let availability: UpdateAvailability
        switch await updater.check(running: running) {
        case .failure(let failure): return failureOutput(failure, json: json)
        case .success(let result): availability = result
        }
        // 手で apply したときは「この版は知らせない」に関係なく入れる（知らせないだけ）
        guard let release = availability.release else {
            if json {
                return Output(
                    stdout: SettingsCLI.pretty(
                        .object(["result": .string("upToDate"), "currentVersion": .string(running.description)])))
            }
            return Output(stdout: "今の版（\(running)）が最新です。\n")
        }
        do {
            let progress = environment.progress
            try await updater.install(release, replacing: environment.appURL, running: running) { step in
                progress("\(step.label)…")
            }
        } catch {
            let failure = error as? UpdateFailure ?? .replaceFailed("不明")
            updater.stateFile.update { $0.lastError = failure.message }
            return failureOutput(failure, json: json)
        }
        let relaunching = environment.appRunning()
        if relaunching { environment.notifyInstalled() }
        if json {
            return Output(
                stdout: SettingsCLI.pretty(
                    .object([
                        "result": .string("installed"), "previousVersion": .string(running.description),
                        "version": .string(release.version.description), "relaunching": .bool(relaunching),
                    ])))
        }
        var text = "v\(release.version) に入れ替えました（前は v\(running)）。\n"
        text +=
            relaunching
            ? "動いている Makurip を起動し直します。\n" : "起動するには: open \(Self.shellQuoted(environment.appURL.path))\n"
        return Output(stdout: text)
    }

    private func failureOutput(_ failure: UpdateFailure, json: Bool) -> Output {
        if json {
            return Output(
                stdout: SettingsCLI.pretty(
                    .object([
                        "result": .string("failed"), "error": .string(failure.code),
                        "message": .string(failure.message),
                    ])), exitCode: failure.exitCode)
        }
        return Output(stderr: failure.message + "\n", exitCode: failure.exitCode)
    }

    static func describe(_ availability: UpdateAvailability, running: AppVersion?) -> String {
        switch availability {
        case .upToDate: "今の版（\(running?.description ?? "?")）が最新です。"
        case .available(let release): "新しい版 v\(release.version) があります（今は v\(running?.description ?? "?")）。"
        case .skipped(let release): "新しい版 v\(release.version) があります（「この版は知らせない」にしています）。"
        }
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func local(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }

    static func shellQuoted(_ text: String) -> String {
        text.contains(where: { $0 == " " || $0 == "'" })
            ? "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'" : text
    }
}

extension UpdateAvailability {
    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// 機械向けの名前
    public var code: String {
        switch self {
        case .upToDate: "upToDate"
        case .available: "available"
        case .skipped: "skipped"
        }
    }
}

/// `--update apply`（別のプロセス）が .app を入れ替えたことを、動いている Makurip に知らせる分散通知。
/// object はデータフォルダの標準化したパス（`HistoryChangeSignal` と同じ）。
/// 受けた側は、ディスクの .app の版が動いている版と違うときだけ起動し直す（誰が送っても、入れ替わっていなければ何もしない）
public enum UpdateInstalledSignal {
    public static let name = Notification.Name("com.takushio2525.makurip.updateInstalled")

    public static func post(directory: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: HistoryChangeSignal.object(for: directory), userInfo: nil, deliverImmediately: true)
    }
}

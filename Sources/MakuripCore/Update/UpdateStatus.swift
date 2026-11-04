import Foundation

/// メニューバーのメニューと設定画面に出す、アップデートの状態（本体の `UpdateController` が作る）。
/// 文言はここにまとめ、メニューと設定画面で同じ言い方にする
public struct UpdateStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// 確かめている
        case checking
        /// 入れ替えている（どの段か）
        case installing(Updater.Step)
        /// 入れ替えに失敗した（理由。今の版のまま）
        case failed(String)
    }

    public var currentVersion: String
    public var phase: Phase
    public var availability: UpdateAvailability
    public var lastCheckedAt: Date?
    /// 直近の確認の失敗の理由（成功したら nil）
    public var lastCheckError: String?
    public var autoCheck: Bool
    /// 置き換えられない理由（`.app` の外・隔離された場所・書けない）。置き換えられるなら nil
    public var blockedReason: String?

    public init(
        currentVersion: String, phase: Phase = .idle, availability: UpdateAvailability = .upToDate,
        lastCheckedAt: Date? = nil, lastCheckError: String? = nil, autoCheck: Bool = true, blockedReason: String? = nil
    ) {
        self.currentVersion = currentVersion
        self.phase = phase
        self.availability = availability
        self.lastCheckedAt = lastCheckedAt
        self.lastCheckError = lastCheckError
        self.autoCheck = autoCheck
        self.blockedReason = blockedReason
    }

    /// 知らせる新しい版（「この版は知らせない」にした版は nil）
    public var announced: UpdateRelease? {
        if case .available(let release) = availability { return release }
        return nil
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .installing: true
        case .idle, .failed: false
        }
    }

    /// 「アップデートして再起動」を出すか（知らせる新しい版があり、置き換えられ、進んでいないとき）
    public var offersInstall: Bool { announced != nil && blockedReason == nil && !isBusy }

    /// メニューの先頭の 1 行（知らせることがなければ nil）
    public var menuHeadline: String? {
        switch phase {
        case .installing(let step): return "アップデートしています…（\(step.label)）"
        // 理由は長いので、メニューには出さず設定画面と窓で出す（メニューが横に広がりすぎないように）
        case .failed: return "アップデートできませんでした（今の版のままです。理由は設定画面）"
        case .idle, .checking:
            guard let release = announced else { return nil }
            return "新しい版 v\(release.version) があります（今は v\(currentVersion)）"
        }
    }

    /// 設定画面の状態の 1 行
    public var summary: String {
        switch phase {
        case .checking: return "確かめています…"
        case .installing(let step): return "アップデートしています…（\(step.label)）"
        case .failed(let reason): return "アップデートできませんでした: \(reason)"
        case .idle:
            switch availability {
            case .available(let release): return "新しい版 v\(release.version) があります。"
            case .skipped(let release): return "新しい版 v\(release.version) は「この版は知らせない」にしています。"
            case .upToDate:
                if let error = lastCheckError { return error }
                guard let date = lastCheckedAt else { return "まだ確かめていません。" }
                return "最新です（\(Self.format(date)) に確かめました）。"
            }
        }
    }

    /// 状態の 1 行を注意の色で出すか
    public var summaryIsWarning: Bool {
        if case .failed = phase { return true }
        if case .idle = phase, availability == .upToDate, lastCheckError != nil { return true }
        return false
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d H:mm"
        return formatter.string(from: date)
    }
}

/// 設定画面の「アップデート」の行が本体に聞くこと・頼むこと（`SettingsEnvironment.update`）
public struct UpdateEnvironment {
    public var status: @MainActor () -> UpdateStatus
    /// 「確認」（手での確認）
    public var check: @MainActor () -> Void
    /// 「アップデートして再起動」
    public var install: @MainActor () -> Void
    /// 「この版は知らせない」
    public var skip: @MainActor () -> Void

    public init(
        status: @escaping @MainActor () -> UpdateStatus, check: @escaping @MainActor () -> Void,
        install: @escaping @MainActor () -> Void, skip: @escaping @MainActor () -> Void
    ) {
        self.status = status
        self.check = check
        self.install = install
        self.skip = skip
    }
}

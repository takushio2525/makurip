import Foundation

/// 設定の値（型の付いた形）。保存・検証・説明は `SettingsSchema`、ファイルは `SettingsFile`。
///
/// 既定値の正本は、上限が `Limits.default`、候補窓が `CandidateSettings.default`、キーが `KeyAction.defaultCombos`。
/// ここはそれを 1 つにまとめるだけで、既定値を二重に持たない
public struct AppSettings: Hashable, Sendable {
    public var hotKeyMode: HotKeyMode
    public var candidateOrder: CandidateOrder
    public var launchAtLogin: Bool
    /// 保存する件数の上限（ピン留めは数えない）
    public var maxItems: Int
    /// 全履歴の容量の上限（MB。1 MB = 1024 × 1024 バイト）
    public var maxTotalMegabytes: Int
    /// 秘密（確度の高いもの）を、最後に使ってから自動で消すまでの分数（`SecretExpiry`）
    public var secretAutoDeleteMinutes: Int
    /// 記録しないアプリ（バンドル ID。このアプリが前面にあるときのコピーは保存しない）
    public var excludedApps: [String]
    /// アプリごとの候補窓の貼り方（既定の一覧 `DeferredPasteApps` より優先）
    public var pasteTiming: [String: PasteTiming]
    /// アプリごとの差し替え方式の決め打ち
    public var replaceMethod: [String: ReplaceMethod]
    /// 候補窓を何も押さないまま閉じるまでの秒数
    public var idleTimeout: Double
    public var keymap: Keymap

    public init() {
        let candidate = CandidateSettings.default
        hotKeyMode = candidate.hotKeyMode
        candidateOrder = candidate.order
        launchAtLogin = false
        maxItems = Limits.default.maxItems
        maxTotalMegabytes = Limits.default.maxTotalBytes / Self.megabyte
        secretAutoDeleteMinutes = SecretExpiry.defaultMinutes
        excludedApps = []
        pasteTiming = candidate.pasteTiming
        replaceMethod = candidate.replaceMethod
        idleTimeout = candidate.idleTimeout
        keymap = .default
    }

    public static let `default` = AppSettings()
    static let megabyte = 1024 * 1024

    /// ストアと監視に渡す上限（件数と容量だけを設定から。ほかは内部の定数）
    public var limits: Limits {
        var limits = Limits.default
        limits.maxItems = maxItems
        limits.maxTotalBytes = maxTotalMegabytes * Self.megabyte
        return limits
    }

    public var candidate: CandidateSettings {
        CandidateSettings(
            hotKeyMode: hotKeyMode, order: candidateOrder, pasteTiming: pasteTiming, replaceMethod: replaceMethod,
            idleTimeout: idleTimeout)
    }

    /// どこからでも効くキー（Carbon に登録する形）。未設定なら nil
    public func globalHotKey(_ action: KeyAction) -> HotKey? {
        keymap.primary(action)?.hotKey
    }

    /// 秘密を自動で消すまでの秒数
    public var secretRetention: TimeInterval { TimeInterval(secretAutoDeleteMinutes) * 60 }

    /// 記録しないアプリ（大文字・小文字を区別しない比較用）
    public var excludedAppSet: Set<String> { Set(excludedApps.map { $0.lowercased() }) }
}

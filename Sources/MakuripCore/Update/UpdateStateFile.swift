import Foundation

/// アップデートの覚え書き（最後に確かめた時刻・見つけた最新の Release・「この版は知らせない」）。
///
/// 設定（`settings.json`）ではなく、データフォルダの `update-state.json` に置く。設定は人と AI が書き換える場所で、
/// ここはアプリと `--update` の CLI が書く内部の状態だから（秘密の判定の版を設定に置かないのと同じ）
public struct UpdateState: Codable, Equatable, Sendable {
    public var lastCheckedAt: Date?
    /// 直近の確認で見つけた、入れられる最新の Release（今の版より古くても覚える）
    public var latest: UpdateRelease?
    /// 「この版は知らせない」を選んだ版（`X.Y.Z`）
    public var skippedVersion: String?
    /// 直近の確認・アップデートが失敗した理由（成功したら消す）
    public var lastError: String?

    public init(
        lastCheckedAt: Date? = nil, latest: UpdateRelease? = nil, skippedVersion: String? = nil,
        lastError: String? = nil
    ) {
        self.lastCheckedAt = lastCheckedAt
        self.latest = latest
        self.skippedVersion = skippedVersion
        self.lastError = lastError
    }

    public func availability(current: AppVersion) -> UpdateAvailability {
        UpdateAvailability.of(current: current, latest: latest, skippedVersion: skippedVersion)
    }
}

public struct UpdateStateFile: Sendable {
    public static let fileName = "update-state.json"
    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// 読めない・壊れているときは空の状態（次に確かめれば書き直す）
    public func load() -> UpdateState {
        guard let data = try? Data(contentsOf: url) else { return UpdateState() }
        return Self.decode(data) ?? UpdateState()
    }

    public func save(_ state: UpdateState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(state).write(to: url, options: .atomic)
    }

    /// 読み込みの中で変えて書く
    @discardableResult
    public func update(_ change: (inout UpdateState) -> Void) -> UpdateState {
        var state = load()
        change(&state)
        try? save(state)
        return state
    }

    static func decode(_ data: Data) -> UpdateState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateState.self, from: data)
    }

    static func encode(_ state: UpdateState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state)
    }
}

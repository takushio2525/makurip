import Foundation

/// AI が行った操作の記録 1 件。**メタデータだけ**（道具の名前・結果・件数・種類）。履歴の中身・ID は入れない
public struct AIActivityEntry: Codable, Sendable, Hashable {
    public enum Channel: String, Codable, Sendable {
        case mcp
        case cli
    }

    public enum Outcome: String, Codable, Sendable {
        /// 行った
        case ok
        /// AI の口がオフだったので断った
        case refused
        /// 入力が検証に通らなかった
        case rejected
        /// DB を開けない等で行えなかった
        case failed
    }

    public var at: Date
    public var channel: Channel
    /// MCP の相手の名前（`initialize` の clientInfo.name。短く切って制御文字を除いたもの）
    public var client: String?
    public var tool: String
    public var outcome: Outcome
    /// 「テキストを 1 件追加した」など。件数・種類・設定の ID と値だけ
    public var summary: String

    public init(at: Date, channel: Channel, client: String?, tool: String, outcome: Outcome, summary: String) {
        self.at = at
        self.channel = channel
        self.client = client
        self.tool = tool
        self.outcome = outcome
        self.summary = summary
    }
}

/// AI の操作の記録（データフォルダの `ai-activity.jsonl`。1 行 1 件の JSON）。設定画面の「AI の口」と `--ai log` で見る。
///
/// MCP のプロセス・CLI・アプリが同じファイルを触るので、書くたびにファイルの `flock` を取り、末尾に足す。
/// `maxEntries` を超えたら古いものから捨てる（その場で切り詰める。同じファイルを開いて待っている書き手の行を失わないように）
public struct AIActivityLog: Sendable {
    public static let fileName = "ai-activity.jsonl"
    public static let maxEntries = 500
    /// この大きさを超えたら切り詰める（1 行はおよそ 200 バイト）
    static let trimThresholdBytes = 160 * 1024

    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// 1 件足す。書けなくても操作そのものは止めない（記録は補助）。
    /// データフォルダがまだない（一度も起動していない）ときは書かない（記録のためだけにフォルダを作らない）
    public func append(_ entry: AIActivityEntry) {
        guard var line = try? Self.encoder.encode(entry),
            FileManager.default.fileExists(atPath: directory.path)
        else { return }
        line.append(0x0A)
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        line.withUnsafeBytes { buffer in _ = write(fd, buffer.baseAddress, buffer.count) }
        var info = stat()
        if fstat(fd, &info) == 0, Int(info.st_size) > Self.trimThresholdBytes {
            trim(fd)
        }
    }

    /// 新しい順に最大 `limit` 件
    public func recent(limit: Int) -> [AIActivityEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: 0x0A)
        var result: [AIActivityEntry] = []
        for line in lines.reversed() {
            if result.count >= limit { break }
            if let entry = try? Self.decoder.decode(AIActivityEntry.self, from: Data(line)) { result.append(entry) }
        }
        return result
    }

    /// 最後の `maxEntries` 行だけを残す（ロックを持ったまま、同じファイルの中で書き直す）
    private func trim(_ fd: Int32) {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A).suffix(Self.maxEntries)
        var kept = Data()
        for line in lines {
            kept.append(contentsOf: line)
            kept.append(0x0A)
        }
        guard ftruncate(fd, 0) == 0 else { return }
        // O_APPEND なので、切り詰めた後の末尾（先頭）から書かれる
        kept.withUnsafeBytes { buffer in _ = write(fd, buffer.baseAddress, buffer.count) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

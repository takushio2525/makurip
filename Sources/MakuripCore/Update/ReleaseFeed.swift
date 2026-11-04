import Foundation

/// Release の添付ファイル 1 つ
public struct ReleaseAsset: Equatable, Sendable, Codable {
    public let name: String
    public let url: URL
    /// Release に書かれた大きさ（バイト）
    public let size: Int?
    /// GitHub が添付ファイルに付ける sha256（`sha256:<16 進>` の 16 進の部分・小文字）。古い Release には無い
    public let sha256: String?

    public init(name: String, url: URL, size: Int?, sha256: String?) {
        self.name = name
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

/// 入れられる Release 1 つ（版・zip・sha256 のファイルがそろっているもの）
public struct UpdateRelease: Equatable, Sendable, Codable {
    public let version: AppVersion
    public let tag: String
    /// Release のページ（人が読む）
    public let pageURL: URL?
    public let publishedAt: Date?
    /// `Makurip-X.Y.Z.zip`（公証して staple した .app を ditto で固めたもの）
    public let archive: ReleaseAsset
    /// `Makurip-X.Y.Z.zip.sha256`（`shasum -a 256` の 1 行）
    public let checksum: ReleaseAsset

    public init(
        version: AppVersion, tag: String, pageURL: URL?, publishedAt: Date?, archive: ReleaseAsset,
        checksum: ReleaseAsset
    ) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.archive = archive
        self.checksum = checksum
    }
}

/// GitHub Releases の一覧（`GET /repos/{owner}/{repo}/releases`）の読み取りと、入れる Release の選び方。
///
/// 配布物の決まり（#41・#43）: tag は `vX.Y.Z`、添付は `Makurip-X.Y.Z.zip` と `Makurip-X.Y.Z.zip.sha256`。
/// draft・prerelease・tag の形が違うもの・添付がそろわないものは選ばない
public enum ReleaseFeed {
    public static func archiveName(_ version: AppVersion) -> String { "Makurip-\(version).zip" }
    public static func checksumName(_ version: AppVersion) -> String { archiveName(version) + ".sha256" }

    private struct RawRelease: Decodable {
        let tagName: String?
        let draft: Bool?
        let prerelease: Bool?
        let htmlURL: String?
        let publishedAt: String?
        let assets: [RawAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct RawAsset: Decodable {
        let name: String?
        let size: Int?
        let downloadURL: String?
        let digest: String?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
            case digest, state
        }
    }

    /// 一覧（配列）か 1 件（`/releases/latest` の形）を読み、入れられる Release を新しい版の順に返す。
    /// JSON として読めない・形が違うときは `feedUnreadable`
    public static func parse(_ data: Data) throws -> [UpdateRelease] {
        let decoder = JSONDecoder()
        let raws: [RawRelease]
        if let list = try? decoder.decode([RawRelease].self, from: data) {
            raws = list
        } else if let single = try? decoder.decode(RawRelease.self, from: data), single.tagName != nil {
            raws = [single]
        } else {
            throw UpdateFailure.feedUnreadable
        }
        let releases = raws.compactMap(release)
        return releases.sorted { $0.version > $1.version }
    }

    /// 入れられる中でいちばん新しい Release
    public static func latest(in data: Data) throws -> UpdateRelease? {
        try parse(data).first
    }

    private static func release(_ raw: RawRelease) -> UpdateRelease? {
        // 下書きと prerelease は配らない（GitHub の印で決める）
        guard raw.draft != true, raw.prerelease != true, let tag = raw.tagName,
            let version = AppVersion(tag), tag == version.tag
        else { return nil }
        let assets = raw.assets ?? []
        guard let archive = asset(named: archiveName(version), in: assets),
            let checksum = asset(named: checksumName(version), in: assets)
        else { return nil }
        return UpdateRelease(
            version: version, tag: tag, pageURL: raw.htmlURL.flatMap(URL.init(string:)),
            publishedAt: raw.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }, archive: archive,
            checksum: checksum)
    }

    private static func asset(named name: String, in assets: [RawAsset]) -> ReleaseAsset? {
        let matches = assets.filter { $0.name == name }
        // 同じ名前が 2 つあるのは壊れた Release（GitHub は許さないが、差し替えた配信元では起きうる）
        guard matches.count == 1, let raw = matches.first, raw.state == nil || raw.state == "uploaded",
            let text = raw.downloadURL, let url = URL(string: text), url.scheme != nil
        else { return nil }
        return ReleaseAsset(name: name, url: url, size: raw.size, sha256: digestHex(raw.digest))
    }

    /// `sha256:<64 桁の 16 進>` の 16 進の部分（小文字）。ほかの形は nil
    static func digestHex(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        return UpdateChecksum.normalizedHex(String(digest.dropFirst("sha256:".count)))
    }
}

/// 確かめた結果（いまの版・「この版は知らせない」と比べて）
public enum UpdateAvailability: Equatable, Sendable {
    /// 今の版が最新（Release がまだ無いときも）
    case upToDate
    /// 新しい版がある
    case available(UpdateRelease)
    /// 新しい版はあるが、「この版は知らせない」を選んだ版
    case skipped(UpdateRelease)

    public static func of(current: AppVersion, latest: UpdateRelease?, skippedVersion: String?) -> UpdateAvailability {
        guard let latest, latest.version > current else { return .upToDate }
        if let skippedVersion, AppVersion(skippedVersion) == latest.version { return .skipped(latest) }
        return .available(latest)
    }

    public var release: UpdateRelease? {
        switch self {
        case .upToDate: nil
        case .available(let release), .skipped(let release): release
        }
    }
}

import Foundation

/// どこに版を問い合わせるか（配信元）。本番は GitHub の Release だけ。
///
/// 差し替え（`--update-feed`）は、検証用の遠隔操作（`--debug-control`）と同じく、`--data-dir` で隔離したときだけ効く。
/// 本物の GitHub に試験用の Release を出さずに、古い版から新しい版への更新を試すため
public struct UpdateSource: Equatable, Sendable {
    public static let repository = "takushio2525/makurip"
    public static let production = UpdateSource(
        feedURL: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!, overridden: false)

    public let feedURL: URL
    /// 差し替えた配信元か
    public let overridden: Bool

    /// 起動引数から決める。隔離していない（`--data-dir` なし）なら差し替えは使わず、`ignoredOverride` を true にする
    public static func resolve(override: String?, isolated: Bool) -> (source: UpdateSource, ignoredOverride: Bool) {
        guard let override, !override.isEmpty else { return (.production, false) }
        guard isolated, let url = overrideURL(override) else { return (.production, true) }
        return (UpdateSource(feedURL: url, overridden: true), false)
    }

    /// 差し替えの URL（`file://`・`http(s)://`。スキームのないものはファイルのパスとして読む）
    static func overrideURL(_ text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            ["file", "http", "https"].contains(scheme)
        {
            return url
        }
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }

    /// 落としてよい URL か。本番は GitHub の、このリポジトリの Release のダウンロードの場所（https）だけ。
    /// 差し替えた配信元では `file://` と `http(s)://` を許す（隔離したときだけ）
    public func allowsDownload(from url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if overridden { return scheme == "file" || scheme == "http" || scheme == "https" }
        return scheme == "https" && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/\(Self.repository)/releases/download/") && url.user == nil && url.password == nil
    }
}

/// 新しい版をどこまで確かめるか。**本番はいつも全部**（署名・同じバンドル ID・同じチーム ID・同じ designated requirement・公証）。
///
/// 公証の確かめだけは、試験のために外せる。外れるのは、隔離（`--data-dir`）・配信元の差し替え（`--update-feed`）・
/// `--update-allow-unnotarized` の 3 つがそろったときだけ（`UpdatePolicyTests` が守る）。署名・チーム・要件は外せない
public struct UpdatePolicy: Equatable, Sendable {
    public let requireNotarization: Bool

    public static let production = UpdatePolicy(requireNotarization: true)

    public static func resolve(isolated: Bool, source: UpdateSource, allowUnnotarized: Bool) -> UpdatePolicy {
        guard isolated, source.overridden, allowUnnotarized else { return .production }
        return UpdatePolicy(requireNotarization: false)
    }
}

import Foundation

/// 保存済み項目のメタデータだけの書き出し（検証用）。**中身（平文・データ）は入れない**。
///
/// 入れるもの: 種類・コピー方法・コピー元アプリ・時刻・回数・印・型名とバイト数・保存場所。
/// コピー元ページの URL はクエリに秘密が入りうるので、ホスト名だけにする。
///
/// AI の口の門の外（シェルを使えるエージェントなら、口がオフでも実行できる）なので、**中身を推せる値も入れない**:
/// - 内容のハッシュは入れない（短い秘密は、推した値のハッシュと照らし合わせて当てられる。#23）
/// - 秘密の項目（`secretLikely`）は大きさ（全体・型ごとのバイト数）を入れず `size: "hidden"` にする（AI の口の一覧と同じ）
public struct MetadataDump: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public struct Representation: Codable, Sendable, Hashable {
            public var type: String
            /// 秘密の項目では入れない（nil）
            public var bytes: Int?
            /// "inline"（DB の中）か "file"（blobs/）
            public var storage: String
        }

        public var id: String
        public var kind: String
        public var copyMethod: String
        public var sourceBundleID: String?
        public var sourceName: String?
        public var sourceURLHost: String?
        public var createdAt: String
        public var lastUsedAt: String
        public var copyCount: Int
        public var pinned: Bool
        public var flags: [String]
        /// 秘密の項目では入れない（nil）
        public var totalBytes: Int?
        /// 秘密の項目だけ "hidden"（大きさを伏せたしるし）
        public var size: String?
        /// 項目ごとの型の一覧
        public var pasteboardItems: [[Representation]]
    }

    public var schemaVersion: Int
    public var itemCount: Int
    public var items: [Entry]

    /// DB がまだないとき（一度も起動していないデータフォルダ）
    public static let empty = MetadataDump(schemaVersion: ClipStore.schemaVersion, itemCount: 0, items: [])

    public static func make(from store: ClipStore) throws -> MetadataDump {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = try store.items().map { item in
            let infos = try store.representationInfos(id: item.id)
            let grouped = Dictionary(grouping: infos, by: \.itemIndex)
            // 秘密の項目は長さで候補を絞れるので、大きさを伏せる（伏せ字が元の長さを隠すのと同じ）
            let hideSize = item.isSecretLikely
            return Entry(
                id: item.id.uuidString,
                kind: item.kind.rawValue,
                copyMethod: item.copyMethod.rawValue,
                sourceBundleID: item.source?.bundleID,
                sourceName: item.source?.name,
                sourceURLHost: item.sourceURL.flatMap { URL(string: $0)?.host },
                createdAt: formatter.string(from: item.createdAt),
                lastUsedAt: formatter.string(from: item.lastUsedAt),
                copyCount: item.copyCount,
                pinned: item.isPinned,
                flags: item.flags.map(\.rawValue).sorted(),
                totalBytes: hideSize ? nil : item.totalBytes,
                size: hideSize ? "hidden" : nil,
                pasteboardItems: grouped.keys.sorted().map { index in
                    (grouped[index] ?? []).map {
                        Entry.Representation(
                            type: $0.type, bytes: hideSize ? nil : $0.byteCount,
                            storage: $0.storedInFile ? "file" : "inline")
                    }
                }
            )
        }
        return MetadataDump(schemaVersion: ClipStore.schemaVersion, itemCount: entries.count, items: entries)
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

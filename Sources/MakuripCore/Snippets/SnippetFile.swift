import Foundation

/// 定型文のファイル（`<データフォルダ>/snippets.json`）。アプリと（#6 の）AI の口が同じコードで読み書きする。
///
/// ```json
/// {
///   "formatVersion" : 1,
///   "snippets" : [
///     { "abbr" : ";date", "body" : "{{日付}}", "createdAt" : "2026-10-31T06:30:00Z",
///       "id" : "…", "name" : "今日の日付", "updatedAt" : "2026-10-31T06:30:00Z" }
///   ]
/// }
/// ```
///
/// - 履歴（`history.sqlite`）とは別のファイルなので、履歴の上限・消去・作り直しでは消えない
/// - 並びはファイルの順 = 一覧の順
/// - 読めない項目（本文がない・長すぎる・形が違う）は飛ばして `issues` に理由を残す。ほかの項目は使う。
///   JSON として読めないファイルは 0 件で動く。どちらの場合も、次に書くときに `snippets.broken.json` へ退避してから書き直す
/// - id がない・壊れている・重なっている項目には新しい id を振る（中身は残す）
public struct SnippetFile: Sendable {
    public static let fileName = "snippets.json"
    public static let brokenFileName = "snippets.broken.json"
    public static let formatVersion = 1

    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    public struct Contents: Sendable, Equatable {
        public var collection: SnippetCollection
        /// 読めなかった項目の理由（何番目か・なぜか）
        public var issues: [String]
        public var exists: Bool
        /// JSON として読めなかった
        public var broken: Bool

        /// 書き直すと失われるものがある（読めなかったファイル・飛ばした項目）。書く前に退避する
        public var needsBackup: Bool { broken || !issues.isEmpty }

        public static let empty = Contents(collection: SnippetCollection(), issues: [], exists: false, broken: false)
    }

    public func load(now: Date = Date()) -> Contents {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return Self.decode(data, now: now)
    }

    /// 読み込みの本体（純粋関数）。日時がない項目は `now` にする
    public static func decode(_ data: Data, now: Date) -> Contents {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), let object = root.objectValue,
            let entries = (object["snippets"] ?? .array([])).arrayValue
        else {
            return Contents(
                collection: SnippetCollection(), issues: ["\(fileName) を JSON として読めないので、定型文は 0 件で動いている"],
                exists: true, broken: true)
        }
        var issues: [String] = []
        if let version = object["formatVersion"]?.intValue, version > formatVersion {
            issues.append("新しい版（\(version)）のファイル。知っている項目だけを使う")
        }
        var snippets: [Snippet] = []
        var ids = Set<UUID>()
        for (offset, entry) in entries.enumerated() {
            let position = "\(offset + 1) 件目"
            guard let fields = entry.objectValue else {
                issues.append("\(position): 形が違うので使わない")
                continue
            }
            guard let body = fields["body"]?.stringValue else {
                issues.append("\(position): 本文（body）がないので使わない")
                continue
            }
            let draft = SnippetDraft(
                name: fields["name"]?.stringValue ?? "", abbreviation: fields["abbr"]?.stringValue ?? "", body: body)
            let value: SnippetDraft
            switch SnippetCollection.normalize(draft) {
            case .success(let normalized): value = normalized
            case .failure(let error):
                issues.append("\(position): \(error.message)。使わない")
                continue
            }
            guard snippets.count < SnippetCollection.maxCount else {
                issues.append("\(position) より後: \(SnippetCollection.maxCount) 件を超えたので使わない")
                break
            }
            var id = fields["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
            if ids.contains(id) { id = UUID() }
            ids.insert(id)
            let created = fields["createdAt"]?.stringValue.flatMap(parseDate) ?? now
            let updated = fields["updatedAt"]?.stringValue.flatMap(parseDate) ?? created
            snippets.append(
                Snippet(
                    id: id, name: value.name, abbreviation: value.abbreviation, body: value.body, createdAt: created,
                    updatedAt: updated))
        }
        return Contents(collection: SnippetCollection(snippets), issues: issues, exists: true, broken: false)
    }

    /// 書く本体（純粋関数）
    public static func encode(_ collection: SnippetCollection) -> Data {
        let entries: [JSONValue] = collection.snippets.map { snippet in
            .object([
                "id": .string(snippet.id.uuidString), "name": .string(snippet.name),
                "abbr": .string(snippet.abbreviation), "body": .string(snippet.body),
                "createdAt": .string(formatDate(snippet.createdAt)),
                "updatedAt": .string(formatDate(snippet.updatedAt)),
            ])
        }
        let root: JSONValue = .object(["formatVersion": .int(formatVersion), "snippets": .array(entries)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(root)) ?? Data()) + Data("\n".utf8)
    }

    /// 書く（同じフォルダの一時ファイルに書いてから置き換える。読む側が書きかけを見ない）
    public func save(_ collection: SnippetCollection, backingUp: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if backingUp, FileManager.default.fileExists(atPath: url.path) {
            let backup = directory.appendingPathComponent(Self.brokenFileName)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try Self.encode(collection).write(to: url, options: .atomic)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

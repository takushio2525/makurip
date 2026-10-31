import Foundation

/// 履歴の永続化。データフォルダの中に SQLite（メタデータと小さいデータ）と `blobs/`（大きいデータ）を置く。
///
/// ```
/// <データフォルダ>/
///   history.sqlite            メタデータ・小さいデータ（WAL）
///   blobs/<履歴ID>/<項目>-<順>.bin   inlineThresholdBytes を超えるデータ
/// ```
///
/// スキーマは `.agent/api.md` の「DB スキーマ」。版を上げるときは `migrate()` に手順を足す。
/// すべての操作はロックで直列化するので、どのスレッドから呼んでもよい。
public final class ClipStore: @unchecked Sendable {
    public enum SaveResult: Sendable, Hashable {
        /// 新しい履歴として入れた
        case inserted(UUID)
        /// 同じ内容が既にあったので先頭へ移した（件数は増えない）
        case movedToTop(UUID)

        public var id: UUID {
            switch self {
            case .inserted(let id), .movedToTop(let id): id
            }
        }
    }

    public static let schemaVersion = 1
    public static let databaseFileName = "history.sqlite"
    public static let blobDirectoryName = "blobs"

    public let directory: URL
    public let limits: Limits
    private let database: SQLiteDatabase
    private let lock = NSLock()
    private let fileManager = FileManager.default

    private var blobRoot: URL { directory.appendingPathComponent(Self.blobDirectoryName, isDirectory: true) }

    public init(directory: URL, limits: Limits = .default) throws {
        self.directory = directory
        self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(Self.blobDirectoryName, isDirectory: true),
            withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent(Self.databaseFileName).path)
        try database.execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    private func migrate() throws {
        let version = try database.userVersion()
        if version < 1 {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS clip (
                  id TEXT PRIMARY KEY,
                  content_hash TEXT NOT NULL UNIQUE,
                  kind TEXT NOT NULL,
                  copy_method TEXT NOT NULL,
                  source_bundle_id TEXT,
                  source_name TEXT,
                  source_url TEXT,
                  created_at REAL NOT NULL,
                  last_used_at REAL NOT NULL,
                  copy_count INTEGER NOT NULL DEFAULT 1,
                  pinned INTEGER NOT NULL DEFAULT 0,
                  flags TEXT NOT NULL DEFAULT '[]',
                  preview_text TEXT,
                  total_bytes INTEGER NOT NULL,
                  item_count INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS clip_last_used ON clip(last_used_at DESC);
                CREATE TABLE IF NOT EXISTS representation (
                  clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
                  item_index INTEGER NOT NULL,
                  position INTEGER NOT NULL,
                  type TEXT NOT NULL,
                  byte_count INTEGER NOT NULL,
                  inline_data BLOB,
                  blob_file TEXT,
                  PRIMARY KEY (clip_id, item_index, position)
                );
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: 書く

    /// 取り込んだ 1 件を保存する。同じ内容（`contentHash` が同じ）が既にあれば、増やさず先頭へ移す
    @discardableResult
    public func save(_ clip: CapturedClip) throws -> SaveResult {
        try withLock {
            let result: SaveResult
            if let existing = try existingID(forHash: clip.contentHash) {
                try moveExistingToTop(existing, with: clip)
                result = .movedToTop(existing)
            } else {
                let id = UUID()
                try insert(clip, id: id)
                result = .inserted(id)
            }
            try enforceLimitsLocked()
            return result
        }
    }

    /// Makurip から貼り付けたときに先頭へ移す（コピー元・コピー方法・回数は変えない）
    public func touch(id: UUID, at date: Date = Date()) throws {
        try withLock {
            try database.prepare("UPDATE clip SET last_used_at = ? WHERE id = ?")
                .bind(.double(date.timeIntervalSince1970), .text(id.uuidString)).run()
        }
    }

    public func setPinned(_ pinned: Bool, id: UUID) throws {
        try withLock {
            try database.prepare("UPDATE clip SET pinned = ? WHERE id = ?")
                .bind(.int(pinned ? 1 : 0), .text(id.uuidString)).run()
            try enforceLimitsLocked()
        }
    }

    public func setFlags(_ flags: Set<ClipFlag>, id: UUID) throws {
        try withLock {
            try database.prepare("UPDATE clip SET flags = ? WHERE id = ?")
                .bind(.text(Self.encodeFlags(flags)), .text(id.uuidString)).run()
        }
    }

    public func delete(id: UUID) throws {
        try withLock { try deleteLocked([id]) }
    }

    /// ピン留め以外を全部消す。消した件数を返す
    @discardableResult
    public func clearUnpinned() throws -> Int {
        try withLock {
            let ids = try queryIDs("SELECT id FROM clip WHERE pinned = 0")
            try deleteLocked(ids)
            return ids.count
        }
    }

    /// 件数・容量の上限を超えていれば、古い順（ピン留めを除く）に消す。消した ID を返す
    @discardableResult
    public func enforceLimits() throws -> [UUID] {
        try withLock { try enforceLimitsLocked() }
    }

    /// DB にない履歴の `blobs/` フォルダ（保存の途中で落ちた残り）を消す。消した数を返す
    @discardableResult
    public func removeOrphanBlobs() throws -> Int {
        try withLock {
            let known = Set(try queryIDs("SELECT id FROM clip").map(\.uuidString))
            let folders = (try? fileManager.contentsOfDirectory(atPath: blobRoot.path)) ?? []
            var removed = 0
            for name in folders where !known.contains(name) {
                try? fileManager.removeItem(at: blobRoot.appendingPathComponent(name, isDirectory: true))
                removed += 1
            }
            return removed
        }
    }

    // MARK: 読む

    /// 新しい順（最後に使った順）
    public func items(limit: Int? = nil) throws -> [ClipItem] {
        try withLock {
            let statement = try database.prepare(
                "SELECT \(Self.itemColumns) FROM clip ORDER BY last_used_at DESC LIMIT ?")
            try statement.bind(.int(limit ?? -1))
            var result: [ClipItem] = []
            while try statement.step() { result.append(Self.item(from: statement)) }
            return result
        }
    }

    public func item(id: UUID) throws -> ClipItem? {
        try withLock {
            let statement = try database.prepare("SELECT \(Self.itemColumns) FROM clip WHERE id = ?")
            try statement.bind(.text(id.uuidString))
            return try statement.step() ? Self.item(from: statement) : nil
        }
    }

    public func count() throws -> Int {
        try withLock {
            let statement = try database.prepare("SELECT COUNT(*) FROM clip")
            return try statement.step() ? statement.int(0) : 0
        }
    }

    /// 保存した全項目・全型のデータ（貼り直し用）
    public func snapshot(id: UUID) throws -> PasteboardSnapshot? {
        try withLock {
            let statement = try database.prepare(
                """
                SELECT item_index, type, inline_data, blob_file FROM representation
                WHERE clip_id = ? ORDER BY item_index, position
                """)
            try statement.bind(.text(id.uuidString))
            var items: [Int: [PasteboardRepresentation]] = [:]
            var found = false
            while try statement.step() {
                found = true
                let itemIndex = statement.int(0)
                let type = statement.text(1) ?? ""
                let data: Data
                if let file = statement.text(3) {
                    data = try Data(contentsOf: blobRoot.appendingPathComponent(file))
                } else {
                    data = statement.blob(2) ?? Data()
                }
                items[itemIndex, default: []].append(PasteboardRepresentation(type: type, data: data))
            }
            guard found else { return nil }
            return PasteboardSnapshot(
                items: items.keys.sorted().map { PasteboardItemSnapshot(representations: items[$0] ?? []) })
        }
    }

    /// 型 1 つのデータ（一覧のサムネイル・プレビュー用。全型を読む `snapshot(id:)` より軽い）
    public func data(id: UUID, itemIndex: Int, type: String) throws -> Data? {
        try withLock {
            let statement = try database.prepare(
                """
                SELECT inline_data, blob_file FROM representation
                WHERE clip_id = ? AND item_index = ? AND type = ? ORDER BY position LIMIT 1
                """)
            try statement.bind(.text(id.uuidString), .int(itemIndex), .text(type))
            guard try statement.step() else { return nil }
            if let file = statement.text(1) {
                return try Data(contentsOf: blobRoot.appendingPathComponent(file))
            }
            return statement.blob(0) ?? Data()
        }
    }

    /// 保存した型の一覧（中身なし）
    public func representationInfos(id: UUID) throws -> [RepresentationInfo] {
        try withLock {
            let statement = try database.prepare(
                """
                SELECT item_index, type, byte_count, blob_file IS NOT NULL FROM representation
                WHERE clip_id = ? ORDER BY item_index, position
                """)
            try statement.bind(.text(id.uuidString))
            var result: [RepresentationInfo] = []
            while try statement.step() {
                result.append(
                    RepresentationInfo(
                        itemIndex: statement.int(0), type: statement.text(1) ?? "", byteCount: statement.int(2),
                        storedInFile: statement.int(3) != 0))
            }
            return result
        }
    }

    // MARK: 内部

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func existingID(forHash hash: String) throws -> UUID? {
        let statement = try database.prepare("SELECT id FROM clip WHERE content_hash = ?")
        try statement.bind(.text(hash))
        guard try statement.step(), let text = statement.text(0) else { return nil }
        return UUID(uuidString: text)
    }

    private func moveExistingToTop(_ id: UUID, with clip: CapturedClip) throws {
        let current = try database.prepare("SELECT flags FROM clip WHERE id = ?")
        try current.bind(.text(id.uuidString))
        let oldFlags = try current.step() ? Self.decodeFlags(current.text(0)) : []
        try database.prepare(
            """
            UPDATE clip SET last_used_at = ?, copy_count = copy_count + 1, copy_method = ?,
              source_bundle_id = ?, source_name = ?, source_url = COALESCE(?, source_url), flags = ?
            WHERE id = ?
            """
        ).bind(
            .double(clip.capturedAt.timeIntervalSince1970), .text(clip.copyMethod.rawValue),
            clip.source?.bundleID.map(SQLiteValue.text), clip.source?.name.map(SQLiteValue.text),
            clip.sourceURL.map(SQLiteValue.text), .text(Self.encodeFlags(oldFlags.union(clip.flags))),
            .text(id.uuidString)
        ).run()
    }

    private func insert(_ clip: CapturedClip, id: UUID) throws {
        let folder = blobRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        // 大きいデータは先にファイルへ書く。DB への書き込みが失敗したら消す（消し損ねは removeOrphanBlobs が拾う）
        var blobFiles: [String: String] = [:]
        do {
            for (itemIndex, item) in clip.snapshot.items.enumerated() {
                for (position, rep) in item.representations.enumerated()
                where rep.data.count > limits.inlineThresholdBytes {
                    if blobFiles.isEmpty {
                        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    }
                    let relative = "\(id.uuidString)/\(itemIndex)-\(position).bin"
                    try rep.data.write(to: blobRoot.appendingPathComponent(relative), options: .atomic)
                    blobFiles["\(itemIndex)-\(position)"] = relative
                }
            }
            try database.transaction {
                try database.prepare(
                    """
                    INSERT INTO clip (id, content_hash, kind, copy_method, source_bundle_id, source_name, source_url,
                      created_at, last_used_at, copy_count, pinned, flags, preview_text, total_bytes, item_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, ?, ?)
                    """
                ).bind(
                    .text(id.uuidString), .text(clip.contentHash), .text(clip.kind.rawValue),
                    .text(clip.copyMethod.rawValue), clip.source?.bundleID.map(SQLiteValue.text),
                    clip.source?.name.map(SQLiteValue.text), clip.sourceURL.map(SQLiteValue.text),
                    .double(clip.capturedAt.timeIntervalSince1970), .double(clip.capturedAt.timeIntervalSince1970),
                    .text(Self.encodeFlags(clip.flags)), clip.previewText.map(SQLiteValue.text),
                    .int(clip.snapshot.totalBytes), .int(clip.snapshot.items.count)
                ).run()
                let insertRep = try database.prepare(
                    """
                    INSERT INTO representation (clip_id, item_index, position, type, byte_count, inline_data, blob_file)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """)
                for (itemIndex, item) in clip.snapshot.items.enumerated() {
                    for (position, rep) in item.representations.enumerated() {
                        let file = blobFiles["\(itemIndex)-\(position)"]
                        try insertRep.bind(
                            .text(id.uuidString), .int(itemIndex), .int(position), .text(rep.type),
                            .int(rep.data.count), file == nil ? .blob(rep.data) : nil, file.map(SQLiteValue.text)
                        ).run()
                    }
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    @discardableResult
    private func enforceLimitsLocked() throws -> [UUID] {
        let statement = try database.prepare(
            "SELECT id, total_bytes FROM clip WHERE pinned = 0 ORDER BY last_used_at ASC")
        var rows: [(UUID, Int)] = []
        while try statement.step() {
            if let text = statement.text(0), let id = UUID(uuidString: text) { rows.append((id, statement.int(1))) }
        }
        var count = rows.count
        var bytes = rows.reduce(0) { $0 + $1.1 }
        var victims: [UUID] = []
        for (id, size) in rows where count > limits.maxItems || bytes > limits.maxTotalBytes {
            victims.append(id)
            count -= 1
            bytes -= size
        }
        if !victims.isEmpty { try deleteLocked(victims) }
        return victims
    }

    private func deleteLocked(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            let statement = try database.prepare("DELETE FROM clip WHERE id = ?")
            for id in ids { try statement.bind(.text(id.uuidString)).run() }
        }
        for id in ids {
            try? fileManager.removeItem(at: blobRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }

    private func queryIDs(_ sql: String) throws -> [UUID] {
        let statement = try database.prepare(sql)
        var ids: [UUID] = []
        while try statement.step() {
            if let text = statement.text(0), let id = UUID(uuidString: text) { ids.append(id) }
        }
        return ids
    }

    static let itemColumns = """
        id, content_hash, kind, copy_method, source_bundle_id, source_name, source_url, created_at, last_used_at,
        copy_count, pinned, flags, preview_text, total_bytes, item_count
        """

    static func item(from s: SQLiteStatement) -> ClipItem {
        let bundleID = s.text(4)
        let name = s.text(5)
        return ClipItem(
            id: UUID(uuidString: s.text(0) ?? "") ?? UUID(),
            contentHash: s.text(1) ?? "",
            kind: ClipKind(storedValue: s.text(2) ?? ""),
            copyMethod: CopyMethod(storedValue: s.text(3) ?? ""),
            source: (bundleID == nil && name == nil) ? nil : SourceApp(bundleID: bundleID, name: name),
            sourceURL: s.text(6),
            createdAt: Date(timeIntervalSince1970: s.double(7)),
            lastUsedAt: Date(timeIntervalSince1970: s.double(8)),
            copyCount: s.int(9),
            isPinned: s.int(10) != 0,
            flags: decodeFlags(s.text(11)),
            previewText: s.text(12),
            totalBytes: s.int(13),
            pasteboardItemCount: s.int(14)
        )
    }

    static func encodeFlags(_ flags: Set<ClipFlag>) -> String {
        let data = (try? JSONEncoder().encode(flags.map(\.rawValue).sorted())) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeFlags(_ text: String?) -> Set<ClipFlag> {
        guard let data = text?.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(values.map(ClipFlag.init(rawValue:)))
    }
}

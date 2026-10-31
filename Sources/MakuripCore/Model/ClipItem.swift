import Foundation

/// コピーした瞬間に前面にあったアプリ
public struct SourceApp: Codable, Hashable, Sendable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// 取り込みが決まった 1 件（まだ保存前）。`CapturePipeline` が作り、`ClipStore.save` が受け取る
public struct CapturedClip: Sendable, Hashable {
    public var snapshot: PasteboardSnapshot
    public var contentHash: String
    public var kind: ClipKind
    public var copyMethod: CopyMethod
    public var source: SourceApp?
    public var sourceURL: String?
    public var capturedAt: Date
    public var flags: Set<ClipFlag>
    /// 一覧・絞り込み用の短い平文（先頭 `Limits.previewCharacterLimit` 文字まで）。画像などは nil
    public var previewText: String?

    public init(
        snapshot: PasteboardSnapshot, contentHash: String, kind: ClipKind, copyMethod: CopyMethod,
        source: SourceApp?, sourceURL: String?, capturedAt: Date, flags: Set<ClipFlag>, previewText: String?
    ) {
        self.snapshot = snapshot
        self.contentHash = contentHash
        self.kind = kind
        self.copyMethod = copyMethod
        self.source = source
        self.sourceURL = sourceURL
        self.capturedAt = capturedAt
        self.flags = flags
        self.previewText = previewText
    }
}

/// 保存済みの履歴 1 件のメタデータ（データ本体は含まない。本体は `ClipStore.snapshot(id:)` で読む）
public struct ClipItem: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var contentHash: String
    public var kind: ClipKind
    public var copyMethod: CopyMethod
    public var source: SourceApp?
    public var sourceURL: String?
    /// 初めて取り込んだ時刻
    public var createdAt: Date
    /// 最後に使った時刻（取り込み直し・Makurip からの貼り付けで更新）。一覧の並びのキー
    public var lastUsedAt: Date
    /// アプリからコピーされた回数（同じ内容のコピーで増える。Makurip からの貼り付けでは増えない）
    public var copyCount: Int
    public var isPinned: Bool
    public var flags: Set<ClipFlag>
    public var previewText: String?
    public var totalBytes: Int
    /// ペーストボードの項目数（Finder で 3 ファイルをコピーすると 3）
    public var pasteboardItemCount: Int

    public init(
        id: UUID, contentHash: String, kind: ClipKind, copyMethod: CopyMethod, source: SourceApp?,
        sourceURL: String?, createdAt: Date, lastUsedAt: Date, copyCount: Int, isPinned: Bool,
        flags: Set<ClipFlag>, previewText: String?, totalBytes: Int, pasteboardItemCount: Int
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.copyMethod = copyMethod
        self.source = source
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.copyCount = copyCount
        self.isPinned = isPinned
        self.flags = flags
        self.previewText = previewText
        self.totalBytes = totalBytes
        self.pasteboardItemCount = pasteboardItemCount
    }

    /// 秘密っぽい（一覧・候補窓ではマスクし、`previewText` も伏せ字で入っている）
    public var isSecretLikely: Bool { flags.contains(.secretLikely) }
}

/// 保存済みの型 1 つの情報（中身なし）。メタデータの書き出しと、後のプレビューの出し分けに使う
public struct RepresentationInfo: Sendable, Hashable, Codable {
    public var itemIndex: Int
    public var type: String
    public var byteCount: Int
    /// true ならディスク上の別ファイル（`blobs/`）、false なら DB の中
    public var storedInFile: Bool

    public init(itemIndex: Int, type: String, byteCount: Int, storedInFile: Bool) {
        self.itemIndex = itemIndex
        self.type = type
        self.byteCount = byteCount
        self.storedInFile = storedInFile
    }
}

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// AI の口の道具が返す誤り。`message` はそのまま AI とユーザーに見せてよい文（中身は入れない）
public struct AIToolError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        /// AI の口がオフ
        case aiAccessDisabled
        /// 入力が検証に通らない
        case invalidArguments
        /// 知らない道具
        case unknownTool
        /// 設定の値が検証に通らない（#4 と同じ検証）
        case settingsRejected
        /// DB・設定ファイルを読み書きできない
        case unavailable
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let disabled = AIToolError(.aiAccessDisabled, AIAccess.disabledMessage)

    public static func invalid(_ message: String) -> AIToolError { AIToolError(.invalidArguments, message) }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// 履歴に足すもの（AI から）
public struct AIAddRequest: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// 画像のファイル（絶対パスか ~ から）。中身をそのままの形式で入れる
        case image(path: String)
        /// ファイルの参照（Finder でコピーしたのと同じ形。中身は読まない）
        case files([String])
    }

    public var content: Content
    /// クリップボードにも置く（既定はしない）
    public var copyToClipboard: Bool
    /// ピン留めする（既定はしない）
    public var pin: Bool

    public init(content: Content, copyToClipboard: Bool = false, pin: Bool = false) {
        self.content = content
        self.copyToClipboard = copyToClipboard
        self.pin = pin
    }
}

/// 秘密での絞り込み
public enum AISecretFilter: String, Sendable, CaseIterable {
    /// 秘密っぽいものすべて（確度「高」と「中」）
    case any
    /// 確度「高」（既知の形式。自動消去の対象）
    case high
    /// 確度「中」だけ（形式から外れるランダムな文字列）
    case medium
    /// 秘密でないもの
    case none

    func matches(_ flags: Set<ClipFlag>) -> Bool {
        switch self {
        case .any: flags.contains(.secretLikely)
        case .high: flags.contains(.secretKnownFormat)
        case .medium: flags.contains(.secretLikely) && !flags.contains(.secretKnownFormat)
        case .none: !flags.contains(.secretLikely)
        }
    }
}

/// 履歴の絞り込み（一覧・条件での削除）。時刻は「最後にコピー・使った時刻」（一覧の並びと同じ）で見る
public struct AIHistoryFilter: Sendable, Equatable {
    public var ids: [UUID]?
    public var kind: ClipKind?
    public var secret: AISecretFilter?
    public var addedByAI: Bool?
    public var pinned: Bool?
    /// 最後に使ってからこの分数以内
    public var withinMinutes: Int?
    /// 最後に使ってからこの分数より前
    public var olderThanMinutes: Int?
    /// コピー元アプリ（バンドル ID か名前。大文字・小文字を区別せず、名前は部分一致）
    public var sourceApp: String?

    public init(
        ids: [UUID]? = nil, kind: ClipKind? = nil, secret: AISecretFilter? = nil, addedByAI: Bool? = nil,
        pinned: Bool? = nil, withinMinutes: Int? = nil, olderThanMinutes: Int? = nil, sourceApp: String? = nil
    ) {
        self.ids = ids
        self.kind = kind
        self.secret = secret
        self.addedByAI = addedByAI
        self.pinned = pinned
        self.withinMinutes = withinMinutes
        self.olderThanMinutes = olderThanMinutes
        self.sourceApp = sourceApp
    }

    /// 削除の条件として何か 1 つでも指定したか（条件なしで全部を消さないため）
    public var hasCondition: Bool {
        ids != nil || kind != nil || secret != nil || addedByAI != nil || withinMinutes != nil
            || olderThanMinutes != nil || sourceApp != nil
    }

    public func matches(_ item: ClipItem, now: Date) -> Bool {
        if let ids, !ids.contains(item.id) { return false }
        if let kind, item.kind != kind { return false }
        if let secret, !secret.matches(item.flags) { return false }
        if let addedByAI, item.flags.contains(.addedByAI) != addedByAI { return false }
        if let pinned, item.isPinned != pinned { return false }
        let age = now.timeIntervalSince(item.lastUsedAt)
        if let withinMinutes, age > Double(withinMinutes) * 60 { return false }
        if let olderThanMinutes, age <= Double(olderThanMinutes) * 60 { return false }
        if let sourceApp {
            let wanted = sourceApp.lowercased()
            let bundleID = item.source?.bundleID?.lowercased()
            let name = item.source?.name?.lowercased()
            guard bundleID == wanted || (name?.contains(wanted) ?? false) else { return false }
        }
        return true
    }
}

/// AI の口の本体。MCP（`MCPServer`）と `--ai` の CLI（`AICLI`）が `AITools` を通してこれを使う。
///
/// - 履歴の道具はどれも、まず AI の口がオンかを確かめる（オフなら `AIToolError.disabled`。DB も作らない）
/// - **中身は返さない**。返すのは形式の情報（種類・時刻・コピー元アプリ・型名・大きさ・言語・印）だけ。
///   一覧用の平文・コピー元ページの URL（ホスト名だけは返す）・ファイル名とパス・内容のハッシュは返さない。
///   秘密の項目は大きさ（長さ）も返さない（伏せ字が元の長さを隠すのと同じ）
/// - 判定（種類・言語・秘密の形式）はこのプロセスの中で中身を読んで行い、結果の名前だけを返す
/// - 書いたら `historyDidChange` で動いている Makurip に知らせる（一覧の読み直し・秘密の自動消去の掛け直し）
@MainActor
public final class AIGateway {
    public struct Environment {
        public var now: () -> Date
        /// クリップボードに置くときのペーストボード（nil なら置けない）
        public var pasteboard: () -> NSPasteboard?
        /// 同じデータフォルダで Makurip が動いているか
        public var appRunning: () -> Bool
        /// 履歴を書いたあとに呼ぶ（動いている Makurip に知らせる）
        public var historyDidChange: () -> Void

        public init(
            now: @escaping () -> Date = { Date() }, pasteboard: @escaping () -> NSPasteboard? = { nil },
            appRunning: @escaping () -> Bool = { false }, historyDidChange: @escaping () -> Void = {}
        ) {
            self.now = now
            self.pasteboard = pasteboard
            self.appRunning = appRunning
            self.historyDidChange = historyDidChange
        }
    }

    /// 一覧で返す件数の上限
    public static let maxListLimit = 200
    public static let defaultListLimit = 20
    /// 一度に足せるファイルの数
    public static let maxFiles = 100
    /// 文字数・行数を数える平文の大きさの上限（これより大きいものはバイト数だけ）
    static let countableTextBytes = 1024 * 1024

    public let directory: URL
    /// 検証用に隔離したデータフォルダか（状態に出す）
    public let isolated: Bool
    private let environment: Environment
    private var openedStore: ClipStore?

    public init(directory: URL, isolated: Bool = false, environment: Environment = Environment()) {
        self.directory = directory
        self.isolated = isolated
        self.environment = environment
    }

    // MARK: オン・オフ

    /// AI の口がオンか（DB がなければオフ。DB を作らない）
    public var isEnabled: Bool {
        guard let store = existingStore() else { return false }
        return AIAccess.isEnabled(store: store)
    }

    /// AI の口をオフにする（CLI の `--ai disable`。オンにする口は設定画面にしかない）
    public func disable() throws {
        guard let store = existingStore() else { return }
        try AIAccess.setEnabled(false, store: store, now: environment.now())
    }

    private func existingStore() -> ClipStore? {
        if let openedStore { return openedStore }
        let database = directory.appendingPathComponent(ClipStore.databaseFileName)
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        openedStore = try? ClipStore(directory: directory, limits: currentLimits())
        return openedStore
    }

    /// オンのときだけストアを返す（毎回 DB の値を読む。オンからオフに切り替えた直後の呼び出しも断る）
    private func requireStore() throws -> ClipStore {
        guard let store = existingStore(), AIAccess.isEnabled(store: store) else { throw AIToolError.disabled }
        return store
    }

    /// 上限は設定ファイルの値（アプリと同じ。既定の値で保存すると、上限を上げた人の履歴を消してしまう）
    private func currentLimits() -> Limits {
        SettingsFile(directory: directory).load().settings.limits
    }

    // MARK: 状態

    public func status() -> JSONValue {
        let enabled = isEnabled
        let running = environment.appRunning()
        var object: [String: JSONValue] = [
            "aiAccess": .string(enabled ? "on" : "off"),
            "appRunning": .bool(running),
            "isolatedDataDirectory": .bool(isolated),
            "historyTools": .string(enabled ? "使える" : "使えない（AI の口がオフ）"),
            "settingsTools": .string("使える（設定に秘密は入っていない）"),
        ]
        if enabled, let store = existingStore(), let items = try? store.items() {
            object["itemCount"] = .int(items.count)
            object["secretCount"] = .int(items.filter(\.isSecretLikely).count)
            object["addedByAICount"] = .int(items.filter { $0.flags.contains(.addedByAI) }.count)
        }
        var message =
            enabled
            ? "AI の口はオンです。履歴への追加・形式の一覧・秘密の削除・条件での削除ができます（中身は見られません）。"
            : AIAccess.disabledMessage
        if !running {
            message += "Makurip が動いていません（このデータフォルダで）。追加したものは、次に起動したときに一覧に出ます。"
        }
        object["message"] = .string(message)
        return .object(object)
    }

    // MARK: 追加

    public struct AddResult: Sendable, Equatable {
        public var id: UUID
        /// 同じ内容が既にあって先頭へ移した
        public var movedToTop: Bool
        public var kind: ClipKind
        public var flags: Set<ClipFlag>
        public var pinned: Bool
        public var copiedToClipboard: Bool
        public var appRunning: Bool
    }

    public func add(_ request: AIAddRequest, client: String?) throws -> AddResult {
        let store = try requireStore()
        let limits = currentLimits()
        let snapshot = try Self.snapshot(for: request.content, limits: limits)
        let context = CapturePipeline.Context(
            now: environment.now(), frontmostApp: SourceApp(bundleID: nil, name: AIClientName.sourceName(client)),
            copyMethod: .other)
        var clip: CapturedClip
        switch CapturePipeline.process(snapshot, context: context, limits: limits) {
        case .accept(let accepted): clip = accepted
        case .skip(.tooLarge):
            throw AIToolError.invalid("大きすぎるので入れられません（型 1 つは \(limits.maxRepresentationBytes / 1_048_576) MB まで）。")
        case .skip:
            throw AIToolError.invalid("入れるものが空です。")
        }
        clip.flags.insert(.addedByAI)
        let result: ClipStore.SaveResult
        do {
            try store.setLimits(limits)
            result = try store.save(clip)
            if request.pin { try store.setPinned(true, id: result.id) }
        } catch {
            throw AIToolError(.unavailable, "履歴に書けませんでした（\(Self.errorKind(error))）。")
        }
        var copied = false
        if request.copyToClipboard, let pasteboard = environment.pasteboard() {
            let prepared = PastePipeline.prepare(
                clip.snapshot, kind: clip.kind, mode: .normal, secret: clip.flags.contains(.secretLikely))
            PasteboardWriter.write(Self.markedAsSaved(prepared), to: pasteboard)
            copied = true
        }
        environment.historyDidChange()
        let stored = try? store.item(id: result.id)
        let movedToTop: Bool
        if case .movedToTop = result { movedToTop = true } else { movedToTop = false }
        return AddResult(
            id: result.id, movedToTop: movedToTop,
            kind: stored?.kind ?? clip.kind, flags: stored?.flags ?? clip.flags,
            pinned: stored?.isPinned ?? request.pin, copiedToClipboard: copied, appRunning: environment.appRunning())
    }

    /// 足すもののスナップショット（大きさ・パス・画像の形式を確かめる）
    static func snapshot(for content: AIAddRequest.Content, limits: Limits) throws -> PasteboardSnapshot {
        switch content {
        case .text(let text):
            guard !text.isEmpty else { throw AIToolError.invalid("text が空です。") }
            let data = Data(text.utf8)
            guard data.count <= limits.maxRepresentationBytes else {
                let size = String(format: "%.1f", Double(data.count) / 1_048_576)
                throw AIToolError.invalid(
                    "text が大きすぎます（\(size) MB。\(limits.maxRepresentationBytes / 1_048_576) MB まで）。")
            }
            return PasteboardSnapshot(items: [
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentation(type: PasteboardTypes.utf8PlainText, data: data)
                ])
            ])
        case .image(let path):
            let url = try existingFile(path, argument: "imagePath", allowDirectory: false)
            let type = UTType(filenameExtension: url.pathExtension.lowercased())?.identifier ?? ""
            guard PasteboardTypes.imageTypes.contains(type) || type == PasteboardTypes.pdf else {
                throw AIToolError.invalid("imagePath は画像のファイル（png・jpeg・tiff・gif・heic・webp・bmp・pdf）にしてください。")
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= limits.maxRepresentationBytes else {
                throw AIToolError.invalid("画像が大きすぎます（\(limits.maxRepresentationBytes / 1_048_576) MB まで）。")
            }
            guard let data = try? Data(contentsOf: url), isReadableImage(data, type: type) else {
                throw AIToolError.invalid("imagePath のファイルを画像として読めませんでした。")
            }
            return PasteboardSnapshot(items: [
                PasteboardItemSnapshot(representations: [PasteboardRepresentation(type: type, data: data)])
            ])
        case .files(let paths):
            guard !paths.isEmpty else { throw AIToolError.invalid("filePaths が空です。") }
            guard paths.count <= maxFiles else { throw AIToolError.invalid("filePaths は \(maxFiles) 個までです。") }
            let items = try paths.map { path -> PasteboardItemSnapshot in
                let url = try existingFile(path, argument: "filePaths", allowDirectory: true)
                // Finder でコピーしたときと同じ形（ファイルの URL と名前の平文）。中身は読まない
                return PasteboardItemSnapshot(representations: [
                    PasteboardRepresentation(type: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8)),
                    PasteboardRepresentation(
                        type: PasteboardTypes.utf8PlainText, data: Data(url.lastPathComponent.utf8)),
                ])
            }
            return PasteboardSnapshot(items: items)
        }
    }

    /// 絶対パス（か ~ から）で、あるファイル。誤りの文にはパスを入れない（名前に秘密が入りうるため）
    static func existingFile(_ path: String, argument: String, allowDirectory: Bool) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw AIToolError.invalid("\(argument) は絶対パス（/ か ~ で始まる）で書いてください。") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AIToolError.invalid("\(argument) のファイルが見つかりません。")
        }
        if isDirectory.boolValue, !allowDirectory { throw AIToolError.invalid("\(argument) はフォルダでなくファイルにしてください。") }
        return url
    }

    static func isReadableImage(_ data: Data, type: String) -> Bool {
        if type == PasteboardTypes.pdf { return data.starts(with: Data("%PDF-".utf8)) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// クリップボードに置くとき、動いている Makurip がもう一度取り込まないための印を足す（保存はこちらで済ませてある）
    static func markedAsSaved(_ snapshot: PasteboardSnapshot) -> PasteboardSnapshot {
        guard !snapshot.items.isEmpty else { return snapshot }
        var result = snapshot
        result.items[0].representations.append(
            PasteboardRepresentation(type: PasteboardMarkers.savedByMakuripAI, data: Data()))
        return result
    }

    // MARK: 形式の一覧

    public struct ListResult: Sendable, Equatable {
        /// 履歴の全件数
        public var total: Int
        /// 条件に合った件数
        public var matched: Int
        /// 返した分（新しい順）
        public var items: [JSONValue]
    }

    public func list(_ filter: AIHistoryFilter, limit: Int) throws -> ListResult {
        let store = try requireStore()
        let now = environment.now()
        let all: [ClipItem]
        do { all = try store.items() } catch { throw AIToolError(.unavailable, "履歴を読めませんでした。") }
        let matched = all.filter { filter.matches($0, now: now) }
        return ListResult(
            total: all.count, matched: matched.count, items: matched.prefix(limit).map { describe($0, store: store) })
    }

    /// 1 件の形式の情報。**中身・一覧用の平文・URL（ホスト名を除く）・ファイル名・ハッシュは入れない**
    func describe(_ item: ClipItem, store: ClipStore) -> JSONValue {
        let infos = (try? store.representationInfos(id: item.id)) ?? []
        var types: [String] = []
        for info in infos where !types.contains(info.type) { types.append(info.type) }
        var object: [String: JSONValue] = [
            "id": .string(item.id.uuidString),
            "kind": .string(item.kind.rawValue),
            "kindLabel": .string(item.kind.label),
            "createdAt": .string(Self.iso(item.createdAt)),
            "lastUsedAt": .string(Self.iso(item.lastUsedAt)),
            "copyCount": .int(item.copyCount),
            "copyMethod": .string(item.copyMethod.rawValue),
            "pinned": .bool(item.isPinned),
            "addedByAI": .bool(item.flags.contains(.addedByAI)),
            "truncated": .bool(item.flags.contains(.truncated)),
            "pasteboardItems": .int(item.pasteboardItemCount),
            "types": .array(types.map(JSONValue.string)),
        ]
        if let source = item.source {
            var app: [String: JSONValue] = [:]
            if let bundleID = source.bundleID { app["bundleID"] = .string(bundleID) }
            if let name = source.name { app["name"] = .string(name) }
            object["sourceApp"] = .object(app)
        }
        // コピー元ページはホスト名だけ（パス・クエリにトークンが入りうるため。`--dump-metadata` と同じ）
        if let host = item.sourceURL.flatMap({ URL(string: $0)?.host }) { object["sourcePageHost"] = .string(host) }
        if let language = Self.language(of: item) {
            object["language"] = .string(language.rawValue)
            object["languageLabel"] = .string(language.displayName)
        }
        if item.isSecretLikely {
            // 形式の名前だけ（中身はこのプロセスの中で判定に使うだけ）。大きさ・長さは返さない
            let kinds =
                (try? store.snapshot(id: item.id, types: SecretScanner.textTypes)).flatMap(SecretScanner.assess)?.kinds
                ?? []
            object["secret"] = .object([
                "level": .string(item.flags.contains(.secretKnownFormat) ? "high" : "medium"),
                "formats": .array(
                    kinds.sorted { $0.rawValue < $1.rawValue }.map {
                        .object(["id": .string($0.rawValue), "label": .string($0.reason)])
                    }),
                "autoDelete": .bool(item.flags.contains(.secretKnownFormat) && !item.isPinned),
            ])
            object["size"] = .string("hidden")
        } else {
            object["totalBytes"] = .int(item.totalBytes)
            if let counts = textCounts(item, infos: infos, store: store) {
                object["characters"] = .int(counts.characters)
                object["lines"] = .int(counts.lines)
            }
        }
        return .object(object)
    }

    /// コードの言語（コマンドはシェル）。一覧用の平文から決める（返すのは名前だけ）
    static func language(of item: ClipItem) -> CodeLanguage? {
        switch item.kind {
        case .command: .shell
        case .code: item.previewText.flatMap(CodeLanguageDetector.detect)
        default: nil
        }
    }

    /// 平文の文字数と行数（1 MB 以下の平文があるときだけ）
    private func textCounts(_ item: ClipItem, infos: [RepresentationInfo], store: ClipStore) -> (
        characters: Int, lines: Int
    )? {
        guard [.text, .richText, .code, .command, .url, .color].contains(item.kind),
            let info = infos.first(where: { $0.type == PasteboardTypes.utf8PlainText }),
            info.byteCount <= Self.countableTextBytes,
            let data = try? store.data(id: item.id, itemIndex: info.itemIndex, type: info.type),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (text.count, lines)
    }

    // MARK: 削除

    public struct DeleteResult: Sendable, Equatable {
        /// 消した件数（`dryRun` なら消すはずの件数）
        public var count: Int
        public var dryRun: Bool
    }

    /// 秘密っぽいものを消す。`confidence` が `.high` なら確度「高」だけ、`.any` なら「中」も
    public func deleteSecrets(
        confidence: AISecretFilter, withinMinutes: Int?, includePinned: Bool, dryRun: Bool
    ) throws -> DeleteResult {
        let filter = AIHistoryFilter(
            secret: confidence, pinned: includePinned ? nil : false, withinMinutes: withinMinutes)
        return try delete(matching: filter, dryRun: dryRun)
    }

    /// 条件に合うものを消す（条件が 1 つもなければ断る）。ピン留めは `includePinned` のときだけ
    public func delete(_ filter: AIHistoryFilter, includePinned: Bool, dryRun: Bool) throws -> DeleteResult {
        guard filter.hasCondition else {
            throw AIToolError.invalid(
                "消す条件を 1 つ以上指定してください（ids・kind・secret・addedByAI・withinMinutes・olderThanMinutes・sourceApp）。")
        }
        var filter = filter
        if !includePinned { filter.pinned = false }
        return try delete(matching: filter, dryRun: dryRun)
    }

    private func delete(matching filter: AIHistoryFilter, dryRun: Bool) throws -> DeleteResult {
        let store = try requireStore()
        let now = environment.now()
        do {
            let ids = try store.items().filter { filter.matches($0, now: now) }.map(\.id)
            guard !dryRun, !ids.isEmpty else { return DeleteResult(count: ids.count, dryRun: dryRun) }
            try store.delete(ids: ids)
            // 消したデータを WAL からも追い出す（秘密を含みうるため、いつも行う）
            store.scrubDeletedData()
            environment.historyDidChange()
            return DeleteResult(count: ids.count, dryRun: false)
        } catch {
            throw AIToolError(.unavailable, "履歴を消せませんでした（\(Self.errorKind(error))）。")
        }
    }

    // MARK: 補助

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// 誤りの種類だけ（SQLite の文などは中身を含みうるので、型の名前にとどめる）
    static func errorKind(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}

/// MCP の相手の名前（clientInfo.name）の扱い。画面と記録に出すので、短く切って制御文字を除く
public enum AIClientName {
    public static let maxLength = 40

    public static func sanitized(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maxLength))
    }

    /// 一覧の「コピー元アプリ」に出す名前（AI が足したと分かる形。コピー元アプリでの絞り込みにも使える）
    public static func sourceName(_ client: String?) -> String {
        sanitized(client).map { "AI（\($0)）" } ?? "AI"
    }
}

import Foundation
import Testing

@testable import MakuripCore

/// テストごとに一時フォルダを作り、終わったら消す（既定のデータフォルダには触らない）
final class TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makurip-tests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func makeClip(
    _ snapshot: PasteboardSnapshot, at seconds: TimeInterval, method: CopyMethod = .other,
    app: String = "com.example.app"
) -> CapturedClip {
    let context = CapturePipeline.Context(
        now: Date(timeIntervalSince1970: seconds), frontmostApp: SourceApp(bundleID: app, name: "App"),
        copyMethod: method)
    guard case .accept(let clip) = CapturePipeline.process(snapshot, context: context, limits: .default) else {
        fatalError("テスト用の入力が取り込まれなかった")
    }
    return clip
}

@Suite("履歴の保存")
struct ClipStoreTests {
    @Test("保存して新しい順に読める")
    func saveAndList() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let a = try store.save(makeClip(Fixtures.text("first"), at: 10))
        let b = try store.save(makeClip(Fixtures.png, at: 20))
        #expect(a == .inserted(a.id))
        #expect(try store.items().map(\.id) == [b.id, a.id])
        #expect(try store.item(id: b.id)?.kind == .image)
    }

    @Test("同じ内容は重複させず先頭へ移す（回数・コピー方法・コピー元は新しい方）")
    func dedupMovesToTop() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let first = try store.save(makeClip(Fixtures.text("same"), at: 10, method: .other, app: "com.example.a"))
        _ = try store.save(makeClip(Fixtures.text("other"), at: 20))
        let again = try store.save(makeClip(Fixtures.text("same"), at: 30, method: .keyboard, app: "com.example.b"))

        #expect(again == .movedToTop(first.id))
        #expect(try store.count() == 2)
        let top = try #require(try store.items().first)
        #expect(top.id == first.id)
        #expect(top.copyCount == 2)
        #expect(top.copyMethod == .keyboard)
        #expect(top.source?.bundleID == "com.example.b")
        #expect(top.createdAt == Date(timeIntervalSince1970: 10))
        #expect(top.lastUsedAt == Date(timeIntervalSince1970: 30))
    }

    @Test("Makurip から貼った（touch）ときは先頭へ移すだけで、回数もコピー元も変えない")
    func touch() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let a = try store.save(makeClip(Fixtures.text("a"), at: 10))
        _ = try store.save(makeClip(Fixtures.text("b"), at: 20))
        try store.touch(id: a.id, at: Date(timeIntervalSince1970: 30))
        let top = try #require(try store.items().first)
        #expect(top.id == a.id)
        #expect(top.copyCount == 1)
        #expect(top.source?.bundleID == "com.example.app")
        #expect(try store.count() == 2)
    }

    @Test("全項目・全型を元どおりに読み戻せる（大きいデータは別ファイル）")
    func snapshotRoundTrip() throws {
        let dir = TemporaryDirectory()
        var limits = Limits.default
        limits.inlineThresholdBytes = 16
        let store = try ClipStore(directory: dir.url, limits: limits)
        let big = Data((0..<1000).map { UInt8($0 % 251) })
        let snapshot = Fixtures.items([
            [(PasteboardTypes.utf8PlainText, Data("small".utf8)), ("com.example.custom", big)],
            [
                (PasteboardTypes.png, Fixtures.pngBytes),
                ("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", Data()),
            ],
        ])
        let saved = try store.save(makeClip(snapshot, at: 10))
        #expect(try store.snapshot(id: saved.id) == snapshot)

        let infos = try store.representationInfos(id: saved.id)
        #expect(infos.map(\.type) == snapshot.items.flatMap(\.types))
        #expect(infos.first { $0.type == "com.example.custom" }?.storedInFile == true)
        #expect(infos.first { $0.type == PasteboardTypes.utf8PlainText }?.storedInFile == false)
        let blobFolder = dir.url.appendingPathComponent("blobs/\(saved.id.uuidString)")
        #expect(FileManager.default.fileExists(atPath: blobFolder.path))
    }

    @Test("開き直しても残る")
    func persistence() throws {
        let dir = TemporaryDirectory()
        let id: UUID
        do {
            let store = try ClipStore(directory: dir.url)
            id = try store.save(makeClip(Fixtures.rtf, at: 10)).id
            try store.setPinned(true, id: id)
            try store.setFlags([.secretLikely, ClipFlag(rawValue: "futureFlag")], id: id)
        }
        let reopened = try ClipStore(directory: dir.url)
        let item = try #require(try reopened.item(id: id))
        #expect(item.kind == .richText)
        #expect(item.isPinned)
        #expect(item.flags == [.secretLikely, ClipFlag(rawValue: "futureFlag")])
        #expect(try reopened.snapshot(id: id) == Fixtures.rtf)
    }

    @Test("件数の上限を超えたら古い順に消す。ピン留めは消さない")
    func itemLimit() throws {
        let dir = TemporaryDirectory()
        var limits = Limits.default
        limits.maxItems = 3
        limits.inlineThresholdBytes = 1
        let store = try ClipStore(directory: dir.url, limits: limits)
        let oldest = try store.save(makeClip(Fixtures.text("0"), at: 0))
        try store.setPinned(true, id: oldest.id)
        var ids: [UUID] = []
        for i in 1...5 { ids.append(try store.save(makeClip(Fixtures.text("item \(i)"), at: Double(i))).id) }
        let remaining = try store.items().map(\.id)
        #expect(remaining == [ids[4], ids[3], ids[2], oldest.id])
        // 消した履歴の blobs も消えている
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("blobs/\(ids[0])").path))
    }

    @Test("容量の上限を超えたら古い順に消す")
    func byteLimit() throws {
        let dir = TemporaryDirectory()
        var limits = Limits.default
        limits.maxTotalBytes = 25
        let store = try ClipStore(directory: dir.url, limits: limits)
        let a = try store.save(makeClip(Fixtures.text(String(repeating: "a", count: 10)), at: 1))
        let b = try store.save(makeClip(Fixtures.text(String(repeating: "b", count: 10)), at: 2))
        let c = try store.save(makeClip(Fixtures.text(String(repeating: "c", count: 10)), at: 3))
        #expect(try store.items().map(\.id) == [c.id, b.id])
        #expect(try store.item(id: a.id) == nil)
    }

    @Test("ピン留め以外を消去")
    func clear() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let pinned = try store.save(makeClip(Fixtures.text("keep"), at: 1))
        try store.setPinned(true, id: pinned.id)
        _ = try store.save(makeClip(Fixtures.text("drop1"), at: 2))
        _ = try store.save(makeClip(Fixtures.text("drop2"), at: 3))
        #expect(try store.clearUnpinned() == 2)
        #expect(try store.items().map(\.id) == [pinned.id])
    }

    @Test("DB にない blobs フォルダ（保存途中で落ちた残り）を消す")
    func orphanBlobs() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let orphan = dir.url.appendingPathComponent("blobs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(try store.removeOrphanBlobs() == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("メタデータの書き出しに中身（平文・データ）を入れない")
    func dumpHasNoContent() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let marker = "do-not-leak-\(UUID().uuidString)"
        let withURL = Fixtures.text(
            marker, extra: [(PasteboardTypes.chromiumSourceURL, Data("https://example.com/p?token=\(marker)".utf8))])
        _ = try store.save(makeClip(withURL, at: 1))
        let json = try MetadataDump.make(from: store).jsonString()
        #expect(!json.contains(marker))
        #expect(json.contains("\"sourceURLHost\" : \"example.com\""))
        #expect(json.contains(PasteboardTypes.utf8PlainText))
    }

    @Test("データフォルダの決め方: 引数 → 環境変数 → 既定。既定と同じ場所を明示しても隔離扱いにしない")
    func resolveDataDirectory() {
        let bundleID = "com.example.makurip-tests"
        let fallback = DataDirectory.defaultURL(bundleID: bundleID)
        let byArgument = DataDirectory.resolve(argument: "/tmp/makurip-a", environment: [:], bundleID: bundleID)
        #expect(byArgument.url.path == "/tmp/makurip-a")
        #expect(byArgument.isolated)
        let byEnvironment = DataDirectory.resolve(
            argument: nil, environment: ["MAKURIP_DATA_DIR": "/tmp/makurip-b"], bundleID: bundleID)
        #expect(byEnvironment.url.path == "/tmp/makurip-b")
        #expect(byEnvironment.isolated)
        let byDefault = DataDirectory.resolve(argument: nil, environment: [:], bundleID: bundleID)
        #expect(byDefault.url.path == fallback.path)
        #expect(!byDefault.isolated)
        let explicitDefault = DataDirectory.resolve(argument: fallback.path + "/", environment: [:], bundleID: bundleID)
        #expect(!explicitDefault.isolated)
    }

    @Test("同じデータフォルダのロックは 1 つしか取れない")
    func instanceLock() throws {
        let dir = TemporaryDirectory()
        let first = InstanceLock(directory: dir.url)
        #expect(first != nil)
        #expect(InstanceLock(directory: dir.url) == nil)
        _ = first
    }
}

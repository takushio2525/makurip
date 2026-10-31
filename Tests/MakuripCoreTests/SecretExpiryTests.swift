import Foundation
import Testing

@testable import MakuripCore

@Suite("秘密の自動消去のタイミング")
struct SecretExpiryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let retention: TimeInterval = 10 * 60

    func item(minutesAgo: Double, flags: Set<ClipFlag>, pinned: Bool = false) -> ClipItem {
        let date = Self.now.addingTimeInterval(-minutesAgo * 60)
        return ClipItem(
            id: UUID(), contentHash: UUID().uuidString, kind: .text, copyMethod: .other, source: nil, sourceURL: nil,
            createdAt: date, lastUsedAt: date, copyCount: 1, isPinned: pinned, flags: flags, previewText: "••••",
            totalBytes: 10, pasteboardItemCount: 1)
    }

    @Test("最後に使ってから決めた時間が来たら消す（ちょうどの時刻を含む）")
    func expiresAfterRetention() {
        let high: Set<ClipFlag> = [.secretLikely, .secretKnownFormat]
        let old = item(minutesAgo: 11, flags: high)
        let exact = item(minutesAgo: 10, flags: high)
        let fresh = item(minutesAgo: 9, flags: high)
        let expired = SecretExpiry.expired([old, exact, fresh], now: Self.now, retention: Self.retention)
        #expect(Set(expired) == [old.id, exact.id])
        // 次に消すのは、まだ時間が来ていないもののうちいちばん早い時刻（1 分後）
        #expect(
            SecretExpiry.nextDeadline([old, exact, fresh], now: Self.now, retention: Self.retention)
                == Self.now.addingTimeInterval(60))
    }

    @Test("確度「中」（ランダムな文字列だけ）・ピン留め・秘密でないものは消さない")
    func notEligible() {
        let medium = item(minutesAgo: 60, flags: [.secretLikely])
        let pinned = item(minutesAgo: 60, flags: [.secretLikely, .secretKnownFormat], pinned: true)
        let normal = item(minutesAgo: 60, flags: [])
        let all = [medium, pinned, normal]
        #expect(SecretExpiry.expired(all, now: Self.now, retention: Self.retention).isEmpty)
        #expect(SecretExpiry.nextDeadline(all, now: Self.now, retention: Self.retention) == nil)
        #expect(all.allSatisfy { !SecretExpiry.isEligible($0) })
    }

    @Test("使うと延びる（最後に使った時刻から数える）")
    func extendedByUse() {
        var secret = item(minutesAgo: 30, flags: [.secretLikely, .secretKnownFormat])
        #expect(SecretExpiry.expired([secret], now: Self.now, retention: Self.retention) == [secret.id])
        secret.lastUsedAt = Self.now.addingTimeInterval(-60)
        #expect(SecretExpiry.expired([secret], now: Self.now, retention: Self.retention).isEmpty)
        #expect(SecretExpiry.deadline(of: secret, retention: Self.retention) == Self.now.addingTimeInterval(9 * 60))
    }

    @Test("時間の設定（既定 10 分・1〜1440 分・「1時間」とも書ける）")
    func setting() throws {
        #expect(AppSettings.default.secretAutoDeleteMinutes == 10)
        #expect(AppSettings.default.secretRetention == 600)
        let item = try #require(SettingsSchema.item(SettingID.secretAutoDelete))
        func validate(_ raw: JSONValue) -> JSONValue? { try? SettingsSchema.validate(raw, for: item).get() }
        #expect(validate(.string("1時間")) == .int(60))
        #expect(validate(.string("90分")) == .int(90))
        #expect(validate(.string("2h")) == .int(120))
        #expect(validate(.int(1)) == .int(1))
        #expect(validate(.int(0)) == nil, "消さない（0）は選べない。残したいものはピン留めする")
        #expect(validate(.int(1441)) == nil)
    }
}

@Suite("秘密の当て直しとストア")
struct SecretStoreTests {
    /// 判定を入れる前の版で保存した 1 件（印なし・平文もそのまま）
    func legacyClip(_ text: String, at seconds: TimeInterval) -> CapturedClip {
        let snapshot = Fixtures.text(text)
        return CapturedClip(
            snapshot: snapshot, contentHash: ContentHasher.hash(snapshot), kind: .text, copyMethod: .other,
            source: nil, sourceURL: nil, capturedAt: Date(timeIntervalSince1970: seconds), flags: [],
            previewText: text)
    }

    @Test("既存の履歴に 1 回だけ当て直す: 印を付け、一覧用の平文を伏せ字にする。2 回目は何もしない")
    func rescanOnce() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let secret = try store.save(legacyClip("GITHUB_TOKEN=\(FakeSecret.github)", at: 10)).id
        let random = try store.save(legacyClip(FakeSecret.randomToken, at: 20)).id
        let normal = try store.save(legacyClip("ふつうのメモ", at: 30)).id
        let image = try store.save(makeClip(Fixtures.png, at: 40)).id
        try store.setPinned(true, id: secret)

        #expect(try SecretRescan.runIfNeeded(store: store) == 2)
        let secretItem = try #require(try store.item(id: secret))
        #expect(secretItem.flags == [.secretLikely, .secretKnownFormat])
        #expect(secretItem.isPinned, "ピン留めはそのまま")
        #expect(secretItem.previewText?.hasPrefix("GITHUB_TOKEN=ghp_••••") == true)
        #expect(secretItem.previewText?.contains(String(FakeSecret.github.dropFirst(4).prefix(10))) == false)
        #expect(try store.item(id: random)?.flags == [.secretLikely])
        #expect(try store.item(id: normal)?.flags == [])
        #expect(try store.item(id: normal)?.previewText == "ふつうのメモ")
        #expect(try store.item(id: image)?.flags == [])
        #expect(try store.metaValue(SecretRescan.metaKey) == String(SecretDetector.version))

        // 2 回目は版が新しいので何もしない（nil）
        #expect(try SecretRescan.runIfNeeded(store: store) == nil)
    }

    @Test("印を足すとき、ほかの印は消さない")
    func addFlagsKeepsOthers() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let id = try store.save(legacyClip("x", at: 10)).id
        try store.setFlags([.truncated], id: id)
        try store.addFlags([.secretLikely], maskedPreview: "••••", id: id)
        #expect(try store.item(id: id)?.flags == [.truncated, .secretLikely])
        #expect(try store.item(id: id)?.previewText == "••••")
    }

    @Test("判定を入れる前の版で保存した同じ中身をもう一度コピーしたら、印を付けて平文も伏せ字に置き換える")
    func recopyMasksLegacy() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let text = "OPENAI_API_KEY=\(FakeSecret.openAIProject)"
        let id = try store.save(legacyClip(text, at: 10)).id
        #expect(try store.item(id: id)?.previewText == text)
        let result = try store.save(makeClip(Fixtures.text(text), at: 20))
        #expect(result == .movedToTop(id))
        let item = try #require(try store.item(id: id))
        #expect(item.isSecretLikely)
        #expect(item.previewText?.contains(String(FakeSecret.openAIProject.dropFirst(8).prefix(12))) == false)
    }

    @Test("印の付いた履歴だけを読む・まとめて消す・消したデータを WAL から追い出す")
    func flaggedAndDelete() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let a = try store.save(makeClip(Fixtures.text("NPM_TOKEN=\(FakeSecret.npm)"), at: 10)).id
        let b = try store.save(makeClip(Fixtures.text(FakeSecret.randomToken), at: 20)).id
        _ = try store.save(makeClip(Fixtures.text("ふつう"), at: 30))
        #expect(try store.items(flagged: .secretLikely).map(\.id) == [b, a])
        #expect(try store.items(flagged: .secretKnownFormat).map(\.id) == [a])
        try store.delete(ids: [a])
        store.scrubDeletedData()
        #expect(try store.item(id: a) == nil)
        #expect(try store.count() == 2)
        // WAL は空になる（消した秘密のページが残らない）
        let wal = dir.url.appendingPathComponent(ClipStore.databaseFileName + "-wal")
        let size = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        #expect(size == 0)
    }

    @Test("型を絞って読む（画像を読まずに文字の型だけ）")
    func snapshotWithTypes() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        let id = try store.save(
            makeClip(Fixtures.text("caption", extra: [(PasteboardTypes.png, Fixtures.pngBytes)]), at: 10)
        ).id
        let snapshot = try #require(try store.snapshot(id: id, types: SecretScanner.textTypes))
        #expect(snapshot.allTypes == [PasteboardTypes.utf8PlainText])
    }

    @Test("版 1 の DB を開くと版 2 に上がり、覚え書きの表ができる（履歴はそのまま）")
    func migratesFromVersion1() throws {
        let dir = TemporaryDirectory()
        do {
            let store = try ClipStore(directory: dir.url)
            _ = try store.save(legacyClip("old", at: 10))
        }
        // 版 1 に戻す（meta の表がない状態）
        do {
            let database = try SQLiteDatabase(path: dir.url.appendingPathComponent(ClipStore.databaseFileName).path)
            try database.execute("DROP TABLE meta; PRAGMA user_version = 1;")
        }
        let store = try ClipStore(directory: dir.url)
        #expect(try store.count() == 1)
        #expect(try store.metaValue(SecretRescan.metaKey) == nil)
        try store.setMetaValue("1", for: SecretRescan.metaKey)
        #expect(try store.metaValue(SecretRescan.metaKey) == "1")
    }
}

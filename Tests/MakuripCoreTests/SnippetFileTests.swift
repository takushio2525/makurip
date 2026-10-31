import Foundation
import Testing

@testable import MakuripCore

/// 定型文のファイル（`snippets.json`）の保存・読み直し・壊れたファイルへの耐性
@Suite("定型文のファイル")
struct SnippetFileTests {
    let now = Date(timeIntervalSince1970: 1_793_428_200)

    func sample() throws -> SnippetCollection {
        var list = SnippetCollection()
        try list.add(
            SnippetDraft(name: "あいさつ（社外）", abbreviation: ";aisatsu", body: "いつもお世話になっております。\n{{カーソル}}\nよろしくお願いいたします。"),
            now: now)
        try list.add(SnippetDraft(name: "今日の日付", abbreviation: ";date", body: "{{日付}}"), now: now)
        try list.add(
            SnippetDraft(name: "コードブロックで囲む", abbreviation: ";code", body: "```{{言語}}\n{{クリップボード}}\n```"), now: now)
        return list
    }

    @Test("書いて読み直すと同じ（順・id・日時・改行・絵文字）")
    func roundTrip() throws {
        let dir = TemporaryDirectory()
        let file = SnippetFile(directory: dir.url)
        var list = try sample()
        try list.add(SnippetDraft(name: "絵文字 😀", body: "タブ\tと \"引用符\" と \\ と /"), now: now)
        try file.save(list)
        let loaded = file.load(now: now.addingTimeInterval(999))
        #expect(loaded.collection == list)
        #expect(loaded.exists && !loaded.broken && loaded.issues.isEmpty)
        // 人と AI が読める形（整形・URL の / をそのまま）
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : 1"))
        #expect(text.contains("\"abbr\" : \";date\""))
    }

    @Test("ファイルがなければ 0 件（exists は false）")
    func missingFile() {
        let dir = TemporaryDirectory()
        let loaded = SnippetFile(directory: dir.url).load()
        #expect(loaded.collection.isEmpty && !loaded.exists && !loaded.broken)
    }

    @Test("JSON として読めなければ 0 件で動き、次に書くとき snippets.broken.json に退避する")
    func brokenFile() throws {
        let dir = TemporaryDirectory()
        let file = SnippetFile(directory: dir.url)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data("{ \"snippets\": [ { \"body\": ".utf8).write(to: file.url)
        let loaded = file.load()
        #expect(loaded.broken && loaded.collection.isEmpty && loaded.needsBackup)
        #expect(loaded.issues.count == 1)
        for garbage in ["", "[]", "null", "\"text\"", "{\"snippets\": 3}"] {
            #expect(SnippetFile.decode(Data(garbage.utf8), now: now).broken, "\(garbage)")
        }
    }

    @Test("読めない項目だけ飛ばして理由を残し、ほかは使う。id の重なり・欠けには新しい id")
    func skipsBadEntries() throws {
        let good = UUID()
        let json = """
            {
              "formatVersion": 9,
              "extra": true,
              "snippets": [
                { "id": "\(good.uuidString)", "name": "良い", "body": "本文", "createdAt": "2026-10-30T00:00:00Z" },
                { "name": "本文なし" },
                "文字列",
                { "name": "空白だけ", "body": "  \\n " },
                { "id": "\(good.uuidString)", "name": "同じ id", "body": "二つ目" },
                { "id": "壊れた id", "body": "名前なし\\n2 行目", "abbr": "; 空白" },
                { "id": "壊れた id", "body": "名前なし\\n2 行目", "abbr": ";ok", "unknown": 1 }
              ]
            }
            """
        let loaded = SnippetFile.decode(Data(json.utf8), now: now)
        #expect(!loaded.broken)
        #expect(loaded.collection.snippets.map(\.name) == ["良い", "同じ id", "名前なし"])
        #expect(loaded.collection.snippets[0].id == good)
        #expect(loaded.collection.snippets[1].id != good)
        #expect(loaded.collection.snippets[0].createdAt == ISO8601DateFormatter().date(from: "2026-10-30T00:00:00Z"))
        // 日時がないものは読んだ時刻
        #expect(loaded.collection.snippets[2].createdAt == now)
        // 新しい版・本文なし・形が違う・空白だけ・略語に空白の 5 つ
        #expect(loaded.issues.count == 5)
        #expect(loaded.needsBackup)
    }

    @Test("数百件・とても長い本文・複数行でも書いて読める")
    func manyAndLong() throws {
        let dir = TemporaryDirectory()
        let file = SnippetFile(directory: dir.url)
        var list = SnippetCollection()
        for i in 0..<300 { try list.add(SnippetDraft(name: "定型文 \(i)", body: "1 行目 \(i)\n2 行目\n3 行目"), now: now) }
        try list.add(SnippetDraft(name: "長い", body: String(repeating: "長い文。\n", count: 20_000)), now: now)
        try file.save(list)
        #expect(file.load().collection == list)
    }
}

/// 動いているアプリの定型文（`SnippetController`）: 変更の書き込み・知らせ・ファイルの変化の読み直し
@MainActor
@Suite("定型文の読み直し", .serialized)
struct SnippetControllerTests {
    @Test("足す・書き換える・消す・並べ替えるとファイルに書き、知らせる")
    func writesAndNotifies() throws {
        let dir = TemporaryDirectory()
        let controller = SnippetController(file: SnippetFile(directory: dir.url))
        var notified = 0
        controller.observe { _ in notified += 1 }
        let a = try controller.add(SnippetDraft(name: "a", body: "1"))
        let b = try controller.add(SnippetDraft(name: "b", body: "2"))
        try controller.update(id: a.id, with: SnippetDraft(name: "a2", body: "1"))
        #expect(try controller.move(id: b.id, by: -1))
        #expect(notified == 4)
        // 同じ中身・端での並べ替えは書かず、知らせない
        try controller.update(id: a.id, with: SnippetDraft(name: "a2", body: "1"))
        #expect(try controller.move(id: b.id, by: -1) == false)
        #expect(notified == 4)
        try controller.remove(id: a.id)
        #expect(notified == 5)
        let reread = SnippetFile(directory: dir.url).load()
        #expect(reread.collection.snippets.map(\.name) == ["b"])
        // 検証に通らない値はファイルを変えずに理由を返す
        #expect(throws: SnippetError.self) { try controller.add(SnippetDraft(name: "空", body: " ")) }
        #expect(SnippetFile(directory: dir.url).load().collection.count == 1)
    }

    @Test("ほかのプロセス（AI の口・手）がファイルを書き換えたら、監視で読み直して知らせる")
    func reloadsOnExternalChange() async throws {
        let dir = TemporaryDirectory()
        let file = SnippetFile(directory: dir.url)
        let controller = SnippetController(file: file)
        controller.startWatching()
        defer { controller.stopWatching() }
        var latest: [String] = []
        controller.observe { latest = $0.snippets.map(\.name) }
        var outside = SnippetCollection()
        try outside.add(SnippetDraft(name: "外から", body: "x"), now: Date())
        try file.save(outside)
        #expect(await waitUntil { latest == ["外から"] })
        #expect(controller.reloadCount == 1)
        // 置き換えでなく、その場で書き換えても拾う
        try outside.add(SnippetDraft(name: "その場で", body: "y"), now: Date())
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: SnippetFile.encode(outside))
        try handle.close()
        #expect(await waitUntil { latest == ["外から", "その場で"] })
    }

    @Test("壊れたファイルのまま足すと、元のファイルを退避してから書く")
    func backsUpBrokenFile() throws {
        let dir = TemporaryDirectory()
        let file = SnippetFile(directory: dir.url)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let controller = SnippetController(file: file)
        #expect(controller.snippets.isEmpty && controller.issues.count == 1)
        try controller.add(SnippetDraft(name: "新しい", body: "x"))
        let backup = dir.url.appendingPathComponent(SnippetFile.brokenFileName)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
        #expect(file.load().collection.snippets.map(\.name) == ["新しい"])
        #expect(controller.issues.isEmpty)
    }
}

/// 定型文は履歴の上限・消去・削除で消えない（別のファイルに持つ）
@Suite("定型文と履歴の分離")
struct SnippetHistorySeparationTests {
    @Test("同じデータフォルダで、履歴の上限・消去・削除・作り直しをしても定型文はそのまま")
    @MainActor
    func survivesHistoryOperations() throws {
        let dir = TemporaryDirectory()
        let controller = SnippetController(file: SnippetFile(directory: dir.url))
        try controller.add(SnippetDraft(name: "残る", abbreviation: ";keep", body: "{{日付}}"))
        let before = try Data(contentsOf: controller.file.url)

        var limits = Limits.default
        limits.maxItems = 10
        let store = try ClipStore(directory: dir.url, limits: limits)
        for i in 0..<30 { try store.save(makeClip(Fixtures.text("item \(i)"), at: TimeInterval(i))) }
        #expect(try store.count() == 10)
        limits.maxItems = 10
        _ = try store.setLimits(limits)
        _ = try store.enforceLimits()
        let first = try #require(try store.items().first)
        try store.delete(id: first.id)
        #expect(try store.clearUnpinned() > 0)
        try store.removeOrphanBlobs()
        #expect(try store.count() == 0)

        #expect(try Data(contentsOf: controller.file.url) == before)
        #expect(SnippetFile(directory: dir.url).load().collection.snippets.map(\.name) == ["残る"])
        #expect(controller.reload() == false)
        #expect(controller.snippets.map(\.name) == ["残る"])
    }
}

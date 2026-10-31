import AppKit
import Foundation
import Testing

@testable import MakuripCore

// 結合レビューで見つかった「出口」の穴（#23・#24・#26・#29 の L1・L2・L6）の回帰テスト。
// どれも、中身を推せる値（長さ・ハッシュ・あるかないか）が AI の口の外や応答から分かってしまう形、
// または AI の口の門の外で履歴を減らせる形を、直す前のコードで落ちるように書いてある。

/// JSON の中のすべての数（入れ子も）
func allNumbers(_ value: JSONValue) -> [Double] {
    switch value {
    case .number(let number): [number]
    case .object(let object): object.values.flatMap(allNumbers)
    case .array(let array): array.flatMap(allNumbers)
    default: []
    }
}

/// 推す側（AI）が手元で作れる「同じ内容か」のハッシュ。公開のコード（`ContentHasher`）と同じ作り方で、平文 1 つの形
func guessedHash(_ text: String) -> String {
    ContentHasher.hash(Fixtures.text(text))
}

/// 短い秘密（確度「高」になるパスワードの代入）。値は短い語なので、長さとハッシュがあれば推して当てられる
enum GuessableSecret {
    static let right = "DB_PASSWORD=" + "hunter" + "42"
    static let wrong = "DB_PASSWORD=" + "hunter" + "43"

    /// Chrome のコピーボタン（`navigator.clipboard.writeText`）の形。ページの URL は付随情報としてハッシュから外れる
    static var copyButton: PasteboardSnapshot {
        Fixtures.text(right, extra: [(PasteboardTypes.chromiumSourceURL, Data("https://console.example.com/db".utf8))])
    }
}

@Suite("秘密の出口: --dump-metadata（#23）")
struct MetadataDumpLeakTests {
    @Test("秘密の項目は大きさ・長さを出さず、内容のハッシュはどの項目にも出さない（推した値と照らせない）")
    func noLengthOrHash() throws {
        let dir = TemporaryDirectory()
        let store = try ClipStore(directory: dir.url)
        try store.save(makeClip(GuessableSecret.copyButton, at: 1_800_000_000, app: "com.google.Chrome"))
        try store.save(makeClip(Fixtures.text("ふつうのメモ"), at: 1_800_000_060))
        let items = try store.items()
        let secret = try #require(items.first { $0.isSecretLikely })
        #expect(secret.flags.contains(.secretKnownFormat))

        let json = try MetadataDump.make(from: store).jsonString()
        // 推した値のハッシュ（正しい推し）も、保存してあるハッシュも、先頭の一部すら出ない
        for hash in [guessedHash(GuessableSecret.right)] + items.map(\.contentHash) {
            #expect(!json.contains(String(hash.prefix(8))))
        }
        let dump = try #require(JSONValue.parse(json))
        let entries = dump.objectValue?["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry["contentHashPrefix"] == nil)
        }

        let secretEntry = try #require(entries.first { $0["id"] == .string(secret.id.uuidString) })
        // 秘密の項目: 大きさは伏せる（AI の口の list_history と同じ size: "hidden"）
        #expect(secretEntry["totalBytes"] == nil)
        #expect(secretEntry["size"] == .string("hidden"))
        #expect(!allKeys(.object(secretEntry)).contains("bytes"))
        let length = Double(Data(GuessableSecret.right.utf8).count)
        #expect(!allNumbers(.object(secretEntry)).contains(length))
        #expect(!allNumbers(.object(secretEntry)).contains(Double(GuessableSecret.right.count)))
        // 型名は出す（E2E が型の並びを見る）
        let types =
            secretEntry["pasteboardItems"]?.arrayValue?.flatMap { $0.arrayValue ?? [] }
            .compactMap { $0.objectValue?["type"]?.stringValue } ?? []
        #expect(types.contains(PasteboardTypes.utf8PlainText))

        // 秘密でない項目は今までどおり大きさを出す（E2E が使う）
        let plain = try #require(entries.first { $0["id"] != .string(secret.id.uuidString) })
        #expect(plain["totalBytes"] == .number(Double(Data("ふつうのメモ".utf8).count)))
        #expect(plain["size"] == nil)
        let plainBytes =
            plain["pasteboardItems"]?.arrayValue?.flatMap { $0.arrayValue ?? [] }
            .compactMap { $0.objectValue?["bytes"] } ?? []
        #expect(plainBytes == [.number(Double(Data("ふつうのメモ".utf8).count))])
        // 中身は出ない
        #expect(!json.contains("hunter"))
        #expect(!json.contains("ふつうのメモ"))
    }
}

@Suite("AI の口: 推した値で、あるかないかが分からない（#24）")
@MainActor
struct AIGuessOracleTests {
    @Test("当たりの推しも外れの推しも同じ応答（inserted と新しい id）で、人の項目は書き換えない")
    func sameAnswerForRightAndWrongGuess() throws {
        let ai = try AIHarness()
        let human = try ai.seed(GuessableSecret.copyButton, app: "com.google.Chrome")

        let wrong = try ai.ok(AITools.Name.add, ["text": .string(GuessableSecret.wrong)])
        let right = try ai.ok(AITools.Name.add, ["text": .string(GuessableSecret.right)])
        #expect(wrong.objectValue?["result"] == .string("inserted"))
        #expect(right.objectValue?["result"] == .string("inserted"))
        #expect(right.objectValue?["id"] != .string(human.uuidString))
        // id と文（中身なし）を除けば、まったく同じ形
        func shape(_ value: JSONValue) -> [String: JSONValue] {
            (value.objectValue ?? [:]).filter { $0.key != "id" }
        }
        #expect(shape(wrong) == shape(right))
        #expect(try ai.store.count() == 3)

        // 人の項目のコピー元・印・回数は変わらない（後の delete_history {addedByAI: true} で消えない）
        let item = try #require(try ai.store.item(id: human))
        #expect(item.source?.bundleID == "com.google.Chrome")
        #expect(!item.flags.contains(.addedByAI))
        #expect(item.copyCount == 1)
        // 一覧からも分からない（人の項目の回数・並びは変わらない）
        let listed = try ai.ok(AITools.Name.list, ["secret": .string("high"), "addedByAI": .bool(false)])
        let entries = listed.objectValue?["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
        #expect(entries.count == 1)
        #expect(entries.first?["copyCount"] == .number(1))
        let dryRun = try ai.ok(AITools.Name.delete, ["addedByAI": .bool(true), "dryRun": .bool(true)])
        #expect(dryRun.objectValue?["wouldDelete"] == .number(2))
    }

    @Test("AI が足したもの同士は合流する。人が同じものをコピーしても AI の項目には合流しない")
    func separateSpaces() throws {
        let ai = try AIHarness()
        let first = try ai.ok(AITools.Name.add, ["text": .string("npm run build")])
        let again = try ai.ok(AITools.Name.add, ["text": .string("npm run build")])
        #expect(again.objectValue?["result"] == .string("movedToTop"))
        #expect(again.objectValue?["id"] == first.objectValue?["id"])
        #expect(try ai.store.count() == 1)

        // 人のコピー（動いているアプリの取り込み）は別の項目になり、AI の印もコピー元も付かない
        let human = try ai.store.save(
            makeClip(Fixtures.text("npm run build"), at: 1_800_000_100, app: "com.apple.Terminal"))
        #expect(human.id.uuidString != first.objectValue?["id"]?.stringValue)
        let item = try #require(try ai.store.item(id: human.id))
        #expect(!item.flags.contains(.addedByAI))
        #expect(item.source?.bundleID == "com.apple.Terminal")
        #expect(try ai.store.count() == 2)
    }
}

@Suite("AI の口: オフのとき、設定の道具で履歴を減らせない（#26）")
@MainActor
struct AISettingsGateTests {
    @Test("オフなら settings_set・settings_reset は断り、設定ファイルも履歴も変わらない（読むだけの道具は使える）")
    func writesNeedAccess() throws {
        let ai = try AIHarness(enabled: false)
        for index in 0..<30 { try ai.seed(Fixtures.text("項目 \(index)"), secondsAgo: Double(3000 - index)) }
        for (name, arguments): (String, [String: JSONValue]) in [
            (AITools.Name.settingsSet, ["id": .string("maxItems"), "value": .number(10)]),
            (AITools.Name.settingsSet, ["id": .string("maxTotalMB"), "value": .number(100)]),
            (
                AITools.Name.settingsSet,
                ["id": .string("excludedApps"), "operation": .string("remove"), "value": .string("com.example.vault")]
            ),
            (AITools.Name.settingsSet, ["id": .string("secretAutoDeleteMinutes"), "value": .number(1440)]),
            (AITools.Name.settingsReset, ["all": .bool(true)]),
            (AITools.Name.settingsReset, ["ids": .array([.string("excludedApps")])]),
        ] {
            #expect(ai.error(name, arguments)?.code == .aiAccessDisabled, "\(name) \(arguments)")
        }
        #expect(!SettingsFile(directory: ai.dir.url).load().exists)
        // 動いているアプリと同じ当て方（設定ファイルの上限をストアに当てる）をしても消えない
        try ai.store.setLimits(SettingsFile(directory: ai.dir.url).load().settings.limits)
        #expect(try ai.store.count() == 30)
        #expect(ai.log.filter { $0.outcome == .refused }.count == 6)
        // 読むだけの道具はオフでも使える
        #expect(throws: Never.self) { try ai.ok(AITools.Name.settingsSchema) }
        #expect(throws: Never.self) { try ai.ok(AITools.Name.settingsList) }
        #expect(throws: Never.self) { try ai.ok(AITools.Name.settingsGet, ["id": .string("maxItems")]) }
    }

    @Test("道具の定義: 書く設定の道具は門の内側で destructiveHint、読む道具は門の外で readOnly")
    func definitions() throws {
        for name in [AITools.Name.settingsSet, AITools.Name.settingsReset] {
            let tool = try #require(AITools.tool(named: name))
            #expect(tool.needsAccess, "\(name)")
            #expect(tool.destructive, "\(name)")
            #expect(!tool.readOnly, "\(name)")
            #expect(tool.json.objectValue?["annotations"]?.objectValue?["destructiveHint"] == .bool(true))
            #expect(tool.description.contains("履歴") && tool.description.contains("消え"), "\(name)")
            #expect(!tool.description.contains("オフでも使える"), "\(name)")
        }
        for name in [AITools.Name.settingsSchema, AITools.Name.settingsList, AITools.Name.settingsGet] {
            let tool = try #require(AITools.tool(named: name))
            #expect(!tool.needsAccess, "\(name)")
            #expect(tool.readOnly, "\(name)")
        }
    }

    @Test("オンなら書ける（上限を下げると、動いているアプリが超えた分を消す）")
    func writesWhenOn() throws {
        let ai = try AIHarness()
        for index in 0..<30 { try ai.seed(Fixtures.text("項目 \(index)"), secondsAgo: Double(3000 - index)) }
        _ = try ai.ok(AITools.Name.settingsSet, ["id": .string("maxItems"), "value": .number(10)])
        try ai.store.setLimits(SettingsFile(directory: ai.dir.url).load().settings.limits)
        #expect(try ai.store.count() == 10)
    }
}

@Suite("データフォルダの隔離の判定（#29 L1）")
struct DataDirectoryAliasTests {
    static let bundleID = "com.example.makurip-tests"

    /// 既定のデータフォルダを別名（大文字小文字違い・/System/Volumes/Data の別名）で指しても、隔離とみなさない。
    /// フォルダの中は開かない（`stat` で同じ場所かを見るだけ。テスト用のバンドル ID のフォルダは作らない）
    @Test("既定のフォルダの別名は隔離ではない（引数・環境変数とも）")
    func aliasesOfDefault() throws {
        let fallback = DataDirectory.defaultURL(bundleID: Self.bundleID).standardizedFileURL
        let support = fallback.deletingLastPathComponent()
        var aliases: [String] = [fallback.path.uppercased(), fallback.path.lowercased()]
        let firmlink = "/System/Volumes/Data" + fallback.path
        if FileManager.default.fileExists(atPath: "/System/Volumes/Data" + support.path) { aliases.append(firmlink) }
        // 大文字小文字を区別するボリュームでは、別名にならないので確かめない
        let caseInsensitive = FileManager.default.fileExists(atPath: support.path.uppercased())
        for alias in aliases where caseInsensitive || alias == firmlink {
            #expect(
                !DataDirectory.resolve(argument: alias, environment: [:], bundleID: Self.bundleID).isolated, "\(alias)")
            #expect(
                !DataDirectory.resolve(argument: nil, environment: ["MAKURIP_DATA_DIR": alias], bundleID: Self.bundleID)
                    .isolated, "\(alias)")
        }
        // 別の場所は隔離
        #expect(
            DataDirectory.resolve(argument: fallback.path + "-other", environment: [:], bundleID: Self.bundleID)
                .isolated)
        #expect(DataDirectory.resolve(argument: "/tmp/makurip-a", environment: [:], bundleID: Self.bundleID).isolated)
    }

    @Test("あるフォルダは同じ inode かで見る（シンボリックリンク・大文字小文字違い）。別のフォルダは隔離")
    func existingFolders() throws {
        let dir = TemporaryDirectory()
        let real = dir.url.appendingPathComponent("Support/com.example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let other = dir.url.appendingPathComponent("Support/com.example.other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(DataDirectory.sameLocation(link, real))
        #expect(DataDirectory.sameLocation(URL(fileURLWithPath: real.path + "/"), real))
        #expect(!DataDirectory.sameLocation(other, real))
        let upper = URL(fileURLWithPath: dir.url.path + "/SUPPORT/COM.EXAMPLE.APP")
        if FileManager.default.fileExists(atPath: upper.path) {
            #expect(DataDirectory.sameLocation(upper, real))
        }
        // まだないフォルダ: いちばん近いある祖先の同じ場所と、残りの名前（大文字小文字を無視）で比べる
        let missing = dir.url.appendingPathComponent("Support/com.example.new")
        #expect(DataDirectory.sameLocation(URL(fileURLWithPath: dir.url.path + "/Support/COM.Example.NEW"), missing))
        #expect(!DataDirectory.sameLocation(dir.url.appendingPathComponent("Support/com.example.new2"), missing))
        #expect(!DataDirectory.sameLocation(real, missing))
    }
}

@Suite("AI の口: 定型文の大きさ（#29 L2）")
@MainActor
struct AISnippetSizeTests {
    @Test("秘密っぽい定型文は文字数・行数を返さず size: hidden（履歴と同じ）。ふつうの定型文は返す")
    func secretSnippetHidesSize() throws {
        let ai = try AIHarness()
        let added = try ai.ok(AITools.Name.addSnippet, ["body": .string(FakeSecret.github), "name": .string("鍵")])
        _ = try ai.ok(AITools.Name.addSnippet, ["body": .string("よろしくお願いします\n{{日付}}"), "name": .string("挨拶")])
        for object in [added.objectValue ?? [:]] {
            #expect(object["characters"] == nil)
            #expect(object["lines"] == nil)
            #expect(object["size"] == .string("hidden"))
        }
        let list = try ai.ok(AITools.Name.listSnippets)
        let items = list.objectValue?["items"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let secret = try #require(items.first { $0["secretLikely"] == .bool(true) })
        #expect(secret["characters"] == nil)
        #expect(secret["lines"] == nil)
        #expect(secret["size"] == .string("hidden"))
        #expect(!allNumbers(.object(secret)).contains(Double(FakeSecret.github.count)))
        let plain = try #require(items.first { $0["secretLikely"] == .bool(false) })
        #expect(plain["characters"] == .number(Double("よろしくお願いします\n{{日付}}".count)))
        #expect(plain["lines"] == .number(2))
        #expect(plain["size"] == nil)
    }
}

@Suite("書く前に読み直す（#29 L6）", .serialized)
@MainActor
struct WriteAfterReloadTests {
    @Test("設定: 外（CLI・AI の口）が書いた直後、読み直しが届く前に画面から別の項目を変えても、外の変更は消えない")
    func settingsKeepsExternalChange() throws {
        let dir = TemporaryDirectory()
        let controller = SettingsController(file: SettingsFile(directory: dir.url))
        // 監視は付けない（読み直しが届く前、と、データフォルダを動かして見張りが外れたとき、と同じ）
        #expect(SettingsCLI(file: SettingsFile(directory: dir.url)).run(["set", "maxItems", "200"]).exitCode == 0)
        try controller.set(SettingID.candidateOrder, .string("ime"))
        let saved = SettingsFile(directory: dir.url).load().settings
        #expect(saved.maxItems == 200)
        #expect(saved.candidate.order == .ime)
        #expect(controller.settings.maxItems == 200)

        #expect(SettingsCLI(file: SettingsFile(directory: dir.url)).run(["set", "maxItems", "300"]).exitCode == 0)
        try controller.reset(SettingID.candidateOrder)
        #expect(SettingsFile(directory: dir.url).load().settings.maxItems == 300)
    }

    @Test("定型文: 外で足した直後、読み直しが届く前に窓から足しても、外で足したものは消えない")
    func snippetsKeepExternalChange() throws {
        let dir = TemporaryDirectory()
        let file = SnippetFile(directory: dir.url)
        let controller = SnippetController(file: file)
        try controller.add(SnippetDraft(name: "窓から 1", body: "a"))
        var outside = file.load().collection
        try outside.add(SnippetDraft(name: "外から", body: "x"), now: Date())
        try file.save(outside)
        try controller.add(SnippetDraft(name: "窓から 2", body: "b"))
        #expect(file.load().collection.snippets.map(\.name) == ["窓から 1", "外から", "窓から 2"])
        #expect(controller.snippets.map(\.name) == ["窓から 1", "外から", "窓から 2"])

        // 外で消したものを、窓が手元の古い値で書き戻さない
        var removed = file.load().collection
        let outsideID = try #require(removed.snippets.first { $0.name == "外から" }?.id)
        _ = try removed.remove(id: outsideID)
        try file.save(removed)
        let first = try #require(controller.snippets.first)
        try controller.move(id: first.id, to: 1)
        #expect(file.load().collection.snippets.map(\.name) == ["窓から 2", "窓から 1"])
    }
}

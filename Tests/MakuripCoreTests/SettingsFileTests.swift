import Foundation
import Testing

@testable import MakuripCore

@Suite("設定ファイル")
struct SettingsFileTests {
    func write(_ text: String, to file: SettingsFile) throws {
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    @Test("ファイルがなければすべて既定")
    func missing() {
        let dir = TemporaryDirectory()
        let contents = SettingsFile(directory: dir.url).load()
        #expect(contents == .empty)
        #expect(contents.settings == .default)
    }

    @Test("書いて読むと同じ。既定と同じ値は書かない")
    func roundTrip() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        var settings = AppSettings.default
        settings.hotKeyMode = .pasteOnly
        settings.maxItems = 200
        settings.keymap.set([KeyCombo(.code(9), .option)], for: .openHistory)
        settings.pasteTiming = ["com.tinyspeck.slackmacgap": .onCommit]
        try file.save(settings)
        #expect(file.load().settings == settings)
        #expect(file.load().issues.isEmpty)

        let root = try #require(JSONValue.parse(String(decoding: try Data(contentsOf: file.url), as: UTF8.self)))
        let values = try #require(root.objectValue?["settings"]?.objectValue)
        #expect(Set(values.keys) == ["hotkeyMode", "maxItems", "keys.open", "candPasteTiming"])
        #expect(values["keys.open"] == .array([.string("⌥V")]))
        #expect(root.objectValue?["formatVersion"] == .int(1))

        try file.save(.default)
        let empty = try #require(JSONValue.parse(String(decoding: try Data(contentsOf: file.url), as: UTF8.self)))
        #expect(empty.objectValue?["settings"] == .object([:]))
    }

    @Test("知らない項目は使わずに残す（書き戻しても消えない）")
    func unknownKeysArePreserved() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        try write(#"{"formatVersion": 1, "settings": {"futureThing": {"a": [1, 2]}, "maxItems": 300}}"#, to: file)
        let contents = file.load()
        #expect(contents.settings.maxItems == 300)
        #expect(contents.unknown == ["futureThing": .object(["a": .array([.int(1), .int(2)])])])
        #expect(contents.issues.map(\.id) == ["futureThing"])

        var settings = contents.settings
        settings.maxItems = 400
        try file.save(settings, unknown: contents.unknown)
        let again = file.load()
        #expect(again.settings.maxItems == 400)
        #expect(again.unknown == contents.unknown)
    }

    @Test("検証に通らない値は既定に戻し、理由を残す（ほかの項目は使う）")
    func invalidValues() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        try write(
            #"{"settings": {"maxItems": -5, "hotkeyMode": "list", "keys.open": ["V"], "excludedApps": "Slack"}}"#,
            to: file)
        let contents = file.load()
        #expect(contents.settings.hotKeyMode == .list)
        #expect(contents.settings.maxItems == AppSettings.default.maxItems)
        #expect(contents.settings.keymap.primary(.openHistory)?.displayString == "⌃⌘V")
        #expect(contents.settings.excludedApps.isEmpty)
        #expect(Set(contents.issues.map(\.id)) == ["maxItems", "keys.open", "excludedApps"])
        #expect(contents.issues.allSatisfy { $0.message.hasSuffix("既定の値を使っている") })
        #expect(!contents.broken)
    }

    @Test("手で壊したファイル: 既定で動き、次に書くときに退避してから書き直す")
    func brokenFile() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        for broken in ["{\"settings\": {\"maxItems\": 2", "", "[1, 2]", "{\"settings\": 3}", "\u{FFFE}garbage"] {
            try write(broken, to: file)
            let contents = file.load()
            #expect(contents.broken, "\(broken)")
            #expect(contents.settings == .default)
            #expect(contents.issues.first?.id == SettingsFile.fileName)
        }
        try write("{\"settings\": {\"maxItems\": 2", to: file)
        var settings = AppSettings.default
        settings.maxItems = 50
        try file.save(settings, backingUpBroken: true)
        let backup = dir.url.appendingPathComponent(SettingsFile.brokenFileName)
        #expect(String(decoding: try Data(contentsOf: backup), as: UTF8.self) == "{\"settings\": {\"maxItems\": 2")
        #expect(file.load().settings.maxItems == 50)
        #expect(!file.load().broken)
    }

    @Test("新しい版のファイルは、知っている項目だけ使う")
    func newerFormat() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        try write(#"{"formatVersion": 9, "settings": {"candOrder": "ime"}}"#, to: file)
        let contents = file.load()
        #expect(contents.settings.candidateOrder == .ime)
        #expect(contents.issues.count == 1)
    }

    @Test("ファイルの中の重なったキーはそのまま読む（画面と list に出す）")
    func conflictsInFile() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        try write(#"{"settings": {"keys.method": ["⌘E"]}}"#, to: file)
        let contents = file.load()
        #expect(contents.issues.isEmpty)
        #expect(contents.settings.keymap.conflicts().count == 1)
    }
}

@Suite("UserDefaults からの引き継ぎ")
struct SettingsMigrationTests {
    /// テストごとに別の UserDefaults（本物のアプリの設定には触らない）
    func makeDefaults() throws -> (UserDefaults, String) {
        let name = "makurip-test-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("候補窓の 5 つを写し、写した値は UserDefaults から消す。壊れた値は写さない")
    func migrates() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("list", forKey: CandidateSettings.Key.hotKeyMode)
        defaults.set("ime", forKey: CandidateSettings.Key.order)
        defaults.set(["com.apple.Terminal": "immediate", "x": "bogus"], forKey: CandidateSettings.Key.pasteTiming)
        defaults.set(["com.example.app": "undo"], forKey: CandidateSettings.Key.replaceMethod)
        defaults.set(0.5, forKey: CandidateSettings.Key.idleTimeout)  // 範囲外
        defaults.set("keep", forKey: "unrelated")

        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        let imported = try SettingsMigration.migrateIfNeeded(file: file, defaults: defaults, domainName: name)
        #expect(Set(imported) == ["hotkeyMode", "candOrder", "candPasteTiming", "candReplaceMethod"])
        let settings = file.load().settings
        #expect(settings.hotKeyMode == .list)
        #expect(settings.candidateOrder == .ime)
        #expect(settings.pasteTiming == ["com.apple.Terminal": .immediate])  // 壊れた組だけ捨てる
        #expect(settings.replaceMethod == ["com.example.app": .undo])
        #expect(settings.idleTimeout == 10)
        for key in SettingsMigration.legacyKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.string(forKey: "unrelated") == "keep")

        // 2 回目は何もしない（ファイルがある）
        defaults.set("paste", forKey: CandidateSettings.Key.hotKeyMode)
        #expect(try SettingsMigration.migrateIfNeeded(file: file, defaults: defaults, domainName: name).isEmpty)
        #expect(file.load().settings.hotKeyMode == .list)
    }

    // 登録ドメイン（register(defaults:)）はプロセス全体で共有されて並列のテストに漏れるので、ここでは使わない。
    // 起動引数の値を引き継がないのは persistentDomain(forName:) だけを読むことで守っている
    @Test("引き継ぐ値がなければファイルを作らない")
    func nothingToMigrate() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "unrelated")
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        #expect(try SettingsMigration.migrateIfNeeded(file: file, defaults: defaults, domainName: name).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}

import Foundation
import Testing

@testable import MakuripCore

@Suite("設定の CLI")
struct SettingsCLITests {
    func cli(_ dir: TemporaryDirectory, apps: Set<String>? = nil) -> SettingsCLI {
        SettingsCLI(
            file: SettingsFile(directory: dir.url),
            command: "/Applications/Makurip.app/Contents/MacOS/Makurip --settings",
            appName: apps.map { known in { known.contains($0) ? $0 : nil } })
    }

    func json(_ output: SettingsCLI.Output) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(output.stdout)?.objectValue)
    }

    @Test("schema --json: 案内・全項目（型・既定値・いまの値・選択肢・範囲・例のコマンド）")
    func schemaJSON() throws {
        let dir = TemporaryDirectory()
        let output = cli(dir).run(["schema", "--json"])
        #expect(output.exitCode == 0)
        let root = try json(output)
        #expect(root["guide"]?.arrayValue?.count ?? 0 >= 4)
        let array = try #require(root["items"]?.arrayValue)
        let items = array.compactMap(\.objectValue)
        #expect(items.count == SettingsSchema.items.count)
        let mode = try #require(items.first { $0["id"] == .string("hotkeyMode") })
        #expect(mode["type"] == .string("choice"))
        #expect(mode["default"] == .string("candidate"))
        #expect(mode["choices"]?.arrayValue?.count == 3)
        let example = try #require(mode["examples"]?.arrayValue?.first?.objectValue)
        #expect(
            example["command"]
                == .string("/Applications/Makurip.app/Contents/MacOS/Makurip --settings set hotkeyMode paste"))
        let items200 = try #require(items.first { $0["id"] == .string("maxItems") })
        #expect(items200["min"] == .int(10) && items200["max"] == .int(20_000) && items200["unit"] == .string("件"))
        let timing = try #require(items.first { $0["id"] == .string("candPasteTiming") })
        #expect(timing["builtIn"]?.arrayValue?.count == DeferredPasteApps.all.count)
        #expect(
            timing["examples"]?.arrayValue?.first?.objectValue?["command"]
                == .string(
                    "/Applications/Makurip.app/Contents/MacOS/Makurip --settings add candPasteTiming com.tinyspeck.slackmacgap=onCommit"
                ))
        let open = try #require(items.first { $0["id"] == .string("keys.open") })
        #expect(open["keyScope"] == .string("global") && open["section"] == .string("keys"))
    }

    @Test("schema（人が読む形）: 案内・キーの書き方・例は短い名前")
    func schemaText() {
        let dir = TemporaryDirectory()
        let text = cli(dir).run(["schema"]).stdout
        #expect(text.hasPrefix("Makurip（クリップボード履歴アプリ）の設定項目の一覧。"))
        #expect(text.contains("例: 「候補窓は出さないで」→ Makurip --settings set hotkeyMode paste"))
        #expect(text.contains("## キー割り当て・候補窓"))
    }

    @Test("set → get → list。既定から変えた項目に印")
    func setGetList() throws {
        let dir = TemporaryDirectory()
        let tool = cli(dir)
        let set = tool.run(["set", "hotkeyMode", "paste"])
        #expect(set.exitCode == 0)
        #expect(set.stdout.hasPrefix("hotkeyMode（呼び出しキー（⌃⌘V）の動き）を「paste（すぐ貼るだけ）」にしました。"))
        #expect(tool.run(["get", "hotkeyMode"]).stdout == "paste\n")
        #expect(tool.run(["get", "keys.prev"]).stdout == "↑ ⌃P\n")
        #expect(tool.run(["get", "keys.prev", "--json"]).stdout == "[\"↑\",\"⌃P\"]\n")
        let list = tool.run(["list"]).stdout
        #expect(list.contains("* hotkeyMode = paste"))
        #expect(list.contains("  candOrder = terminal"))
        let listJSON = try json(tool.run(["list", "--json"]))
        #expect(listJSON["changed"] == .array([.string("hotkeyMode")]))
        #expect(listJSON["values"]?.objectValue?["maxItems"] == .int(1000))
    }

    @Test("検証に通らない値は理由付きで拒否し（終了コード 2）、ファイルを変えない")
    func rejects() throws {
        let dir = TemporaryDirectory()
        let tool = cli(dir)
        for args in [
            ["set", "maxItems", "5"], ["set", "hotkeyMode", "popup"], ["set", "keys.open", "V"],
            ["set", "keys.method", "⌘E"], ["add", "excludedApps", "Slack"], ["set", "nope", "1"],
            ["add", "candPasteTiming", "com.tinyspeck.slackmacgap"], ["add", "hotkeyMode", "paste"],
            ["set", "hotkeyMode", "paste", "list"], ["set", "excludedApps", "[broken"],
        ] {
            let output = tool.run(args)
            #expect(output.exitCode == SettingsCLI.ExitCode.rejected, "\(args)")
            #expect(output.stderr.hasPrefix("変えられない") || output.stderr.hasPrefix("そういう設定項目はない"), "\(args)")
            #expect(output.stdout.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: SettingsFile(directory: dir.url).url.path))
        #expect(tool.run(["set", "hotkeymod", "x"]).stderr.contains("近いもの: hotkeyMode"))
    }

    @Test("--take-over で重なった操作から外して付け替える")
    func takeOver() {
        let dir = TemporaryDirectory()
        let output = cli(dir).run(["set", "keys.method", "⌘E", "--take-over"])
        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("重なっていた「コピー元アプリを選ぶ」からは外しました。"))
        #expect(cli(dir).run(["get", "keys.app"]).stdout == "\n")
    }

    @Test("add / remove: アプリの並び・アプリごとの値・キー。見つからないアプリは注意を出す（拒否はしない）")
    func addRemove() throws {
        let dir = TemporaryDirectory()
        let tool = cli(dir, apps: ["com.apple.Safari"])
        let added = tool.run(["add", "excludedApps", "com.apple.Safari"])
        #expect(added.exitCode == 0 && added.stderr.isEmpty)
        let missing = tool.run(["add", "excludedApps", "com.example.notinstalled"])
        #expect(missing.exitCode == 0)
        #expect(missing.stderr.contains("com.example.notinstalled はこの Mac に見つからない"))
        #expect(tool.run(["get", "excludedApps"]).stdout == "com.apple.Safari com.example.notinstalled\n")
        #expect(tool.run(["remove", "excludedApps", "COM.EXAMPLE.NOTINSTALLED"]).exitCode == 0)
        #expect(tool.run(["get", "excludedApps"]).stdout == "com.apple.Safari\n")

        #expect(tool.run(["add", "candPasteTiming", "com.apple.Terminal=immediate"]).exitCode == 0)
        #expect(tool.run(["add", "candPasteTiming", "com.example.chat=onCommit"]).exitCode == 0)
        #expect(
            tool.run(["get", "candPasteTiming"]).stdout == "com.apple.Terminal=immediate com.example.chat=onCommit\n")
        #expect(tool.run(["remove", "candPasteTiming", "com.apple.Terminal"]).exitCode == 0)
        #expect(tool.run(["get", "candPasteTiming"]).stdout == "com.example.chat=onCommit\n")

        #expect(tool.run(["add", "keys.paste", "⌃↩"]).exitCode == 0)
        #expect(tool.run(["get", "keys.paste"]).stdout == "↩ ⌃↩\n")
        #expect(tool.run(["remove", "keys.paste", "ctrl+return"]).exitCode == 0)
        #expect(tool.run(["get", "keys.paste"]).stdout == "↩\n")
        // どこからでも効くキーは 1 つだけ
        #expect(tool.run(["add", "keys.open", "⌥V"]).exitCode == SettingsCLI.ExitCode.rejected)
    }

    @Test("none で空にする・JSON で渡す・reset で戻す")
    func noneJSONReset() {
        let dir = TemporaryDirectory()
        let tool = cli(dir)
        #expect(tool.run(["set", "keys.openList", "none"]).exitCode == 0)
        #expect(tool.run(["get", "keys.openList"]).stdout == "\n")
        #expect(tool.run(["list"]).stdout.contains("* keys.openList = （なし）"))
        #expect(tool.run(["set", "candPasteTiming", #"{"com.apple.Terminal":"immediate"}"#]).exitCode == 0)
        #expect(tool.run(["set", "maxTotalMB", "2GB"]).exitCode == 0)
        #expect(tool.run(["get", "maxTotalMB"]).stdout == "2048\n")
        #expect(tool.run(["reset", "keys.openList", "maxTotalMB"]).exitCode == 0)
        #expect(tool.run(["get", "keys.openList"]).stdout == "⌃⌥⌘V\n")
        #expect(tool.run(["get", "maxTotalMB"]).stdout == "1024\n")
        #expect(tool.run(["reset", "--all"]).exitCode == 0)
        #expect(SettingsFile(directory: dir.url).load().settings == .default)
    }

    @Test("使い方の誤りは終了コード 1。help と path")
    func usage() {
        let dir = TemporaryDirectory()
        let tool = cli(dir)
        #expect(tool.run([]).exitCode == SettingsCLI.ExitCode.usage)
        #expect(tool.run(["frobnicate"]).exitCode == SettingsCLI.ExitCode.usage)
        #expect(tool.run(["get"]).exitCode == SettingsCLI.ExitCode.usage)
        #expect(tool.run(["set", "maxItems"]).exitCode == SettingsCLI.ExitCode.usage)
        #expect(tool.run(["reset"]).exitCode == SettingsCLI.ExitCode.usage)
        #expect(tool.run(["help"]).stdout.contains("schema"))
        #expect(tool.run(["path"]).stdout == SettingsFile(directory: dir.url).url.path + "\n")
    }

    @Test("壊れた設定ファイル: list に理由を出し、set で退避してから書き直す。知らない項目は残す")
    func brokenAndUnknown() throws {
        let dir = TemporaryDirectory()
        let file = SettingsFile(directory: dir.url)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        let tool = cli(dir)
        #expect(tool.run(["list"]).stdout.contains("JSON として読めない"))
        #expect(tool.run(["set", "candOrder", "ime"]).exitCode == 0)
        #expect(
            FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(SettingsFile.brokenFileName).path))
        #expect(file.load().settings.candidateOrder == .ime)

        try Data(#"{"settings": {"futureThing": true}}"#.utf8).write(to: file.url)
        #expect(tool.run(["set", "maxItems", "300"]).exitCode == 0)
        #expect(file.load().unknown == ["futureThing": .bool(true)])
    }
}

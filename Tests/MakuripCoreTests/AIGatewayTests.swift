import AppKit
import Foundation
import Testing

@testable import MakuripCore

/// AI の口の試験台（一時フォルダの DB・名前付きペーストボード・決まった時刻）。既定のデータフォルダと一般ペーストボードには触らない
@MainActor
final class AIHarness {
    let dir = TemporaryDirectory()
    let store: ClipStore
    let board = PrivatePasteboard()
    let tools: AITools
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var historyChanges = 0
    private(set) var activityChanges = 0

    init(enabled: Bool = true, client: String? = "test-client") throws {
        store = try ClipStore(directory: dir.url)
        if enabled { try AIAccess.setEnabled(true, store: store) }
        // 弱い参照（強いと循環して、一時フォルダとペーストボードが片付かない）
        weak var harness: AIHarness?
        let gateway = AIGateway(
            directory: dir.url, isolated: true,
            environment: AIGateway.Environment(
                now: { harness?.now ?? Date() }, pasteboard: { harness?.board.pasteboard },
                appRunning: { false }, historyDidChange: { harness?.historyChanges += 1 }))
        tools = AITools(
            gateway: gateway, settingsCLI: SettingsCLI(file: SettingsFile(directory: dir.url)),
            log: AIActivityLog(directory: dir.url), channel: .mcp, client: client,
            now: { harness?.now ?? Date() }, activityDidChange: { harness?.activityChanges += 1 })
        harness = self
    }

    func call(_ name: String, _ arguments: [String: JSONValue] = [:]) -> Result<AITools.Output, AIToolError> {
        tools.call(name, arguments: arguments)
    }

    func ok(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        try call(name, arguments).get().structured
    }

    func error(_ name: String, _ arguments: [String: JSONValue] = [:]) -> AIToolError? {
        if case .failure(let error) = call(name, arguments) { return error }
        return nil
    }

    /// 履歴に入れる（`secondsAgo` 秒前に使ったもの）
    @discardableResult
    func seed(_ snapshot: PasteboardSnapshot, secondsAgo: TimeInterval = 60, app: String = "com.example.app") throws
        -> UUID
    {
        try store.save(makeClip(snapshot, at: now.timeIntervalSince1970 - secondsAgo, app: app)).id
    }

    var log: [AIActivityEntry] { AIActivityLog(directory: dir.url).recent(limit: 100) }
}

private func string(_ text: String) -> JSONValue { .string(text) }

/// JSON に出てくるすべてのキー（入れ子も）
func allKeys(_ value: JSONValue) -> Set<String> {
    switch value {
    case .object(let object): Set(object.keys).union(object.values.flatMap(allKeys))
    case .array(let array): Set(array.flatMap(allKeys))
    default: []
    }
}

/// 一意な目印（漏れの検査で出力から探す）
let marker = "MKLEAK" + String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: "")

@Suite("AI の口: 入力の検証")
@MainActor
struct AIToolInputTests {
    @Test("add_to_history は text・imagePath・filePaths のどれか 1 つだけ。知らない引数・型の誤りは断る")
    func addArguments() throws {
        let ai = try AIHarness()
        #expect(ai.error(AITools.Name.add)?.code == .invalidArguments)
        #expect(
            ai.error(AITools.Name.add, ["text": string("a"), "imagePath": string("/tmp/x.png")])?.code
                == .invalidArguments)
        let unknown = ai.error(AITools.Name.add, ["text": string("a"), "txt": string("b")])
        #expect(unknown?.code == .invalidArguments)
        #expect(unknown?.message.contains("txt") == true)
        #expect(ai.error(AITools.Name.add, ["text": .number(1)])?.code == .invalidArguments)
        #expect(
            ai.error(AITools.Name.add, ["text": string("a"), "copyToClipboard": string("yes")])?.code
                == .invalidArguments)
        #expect(ai.error(AITools.Name.add, ["text": string("")])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.add, ["filePaths": .array([])])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.add, ["filePaths": .array([.number(1)])])?.code == .invalidArguments)
        // null は指定なしと同じ
        #expect(throws: Never.self) { try ai.ok(AITools.Name.add, ["text": string("ok"), "pin": .null]) }
    }

    @Test("パスは絶対パスで、あるファイルだけ。誤りの文にパス（名前に秘密が入りうる）を入れない")
    func addPaths() throws {
        let ai = try AIHarness()
        let relative = ai.error(AITools.Name.add, ["imagePath": string("images/\(marker).png")])
        #expect(relative?.code == .invalidArguments)
        let missing = ai.error(AITools.Name.add, ["filePaths": .array([string("/nonexistent/\(marker).txt")])])
        #expect(missing?.code == .invalidArguments)
        #expect(missing?.message.contains(marker) == false)
        let notImage = ai.dir.url.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: notImage)
        #expect(ai.error(AITools.Name.add, ["imagePath": string(notImage.path)])?.code == .invalidArguments)
        let fakePNG = ai.dir.url.appendingPathComponent("broken.png")
        try Data("not a png".utf8).write(to: fakePNG)
        #expect(ai.error(AITools.Name.add, ["imagePath": string(fakePNG.path)])?.code == .invalidArguments)
    }

    @Test("大きすぎる文字は入れない（型 1 つの上限）")
    func tooLarge() throws {
        var limits = Limits.default
        limits.maxRepresentationBytes = 1024
        #expect(throws: AIToolError.self) {
            try AIGateway.snapshot(for: .text(String(repeating: "a", count: 1025)), limits: limits)
        }
        #expect(throws: Never.self) {
            try AIGateway.snapshot(for: .text(String(repeating: "a", count: 1024)), limits: limits)
        }
    }

    @Test("list_history の件数・種類・秘密・期間の範囲")
    func listArguments() throws {
        let ai = try AIHarness()
        for bad: [String: JSONValue] in [
            ["limit": .int(0)], ["limit": .int(201)], ["limit": string("abc")], ["limit": .number(2.5)],
            ["kind": string("photo")], ["secret": string("low")], ["withinMinutes": .int(-1)],
            ["olderThanMinutes": .int(0)], ["sourceApp": string(" ")], ["pinned": string("maybe")], ["id": string("x")],
        ] {
            #expect(ai.error(AITools.Name.list, bad)?.code == .invalidArguments, "\(bad)")
        }
        // 数の文字（CLI から来る形）は受け付ける
        #expect(throws: Never.self) { try ai.ok(AITools.Name.list, ["limit": string("5"), "kind": string("code")]) }
    }

    @Test("delete_history は条件が 1 つ以上要る。ids は UUID の並び")
    func deleteArguments() throws {
        let ai = try AIHarness()
        #expect(ai.error(AITools.Name.delete)?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.delete, ["dryRun": .bool(true)])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.delete, ["includePinned": .bool(true)])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.delete, ["ids": .array([])])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.delete, ["ids": .array([string("not-a-uuid")])])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.deleteSecrets, ["confidence": string("medium")])?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.deleteSecrets, ["kind": string("text")])?.code == .invalidArguments)
    }

    @Test("設定の道具の引数")
    func settingsArguments() throws {
        let ai = try AIHarness()
        #expect(ai.error(AITools.Name.settingsSet, ["id": string("hotkeyMode")])?.code == .invalidArguments)
        #expect(
            ai.error(
                AITools.Name.settingsSet,
                ["id": string("hotkeyMode"), "value": string("paste"), "operation": string("toggle")])?
                .code == .invalidArguments)
        #expect(
            ai.error(
                AITools.Name.settingsSet,
                ["id": string("excludedApps"), "value": .array([]), "operation": string("add")])?.code
                == .invalidArguments)
        #expect(ai.error(AITools.Name.settingsReset)?.code == .invalidArguments)
        #expect(
            ai.error(AITools.Name.settingsReset, ["ids": .array([string("maxItems")]), "all": .bool(true)])?.code
                == .invalidArguments)
        #expect(ai.error(AITools.Name.settingsGet)?.code == .invalidArguments)
        #expect(ai.error(AITools.Name.settingsSchema, ["x": .bool(true)])?.code == .invalidArguments)
    }

    @Test("知らない道具")
    func unknownTool() throws {
        let ai = try AIHarness()
        #expect(ai.error("read_history")?.code == .unknownTool)
    }

    @Test("CLI のフラグは同じ引数になる。知らないフラグ・値のないフラグは使い方の誤り")
    func cliFlags() throws {
        let ai = try AIHarness()
        let cli = AICLI(tools: ai.tools)
        #expect(cli.run(["list", "--limitt", "3"]).exitCode == AICLI.ExitCode.usage)
        #expect(cli.run(["list", "--limit"]).exitCode == AICLI.ExitCode.usage)
        #expect(cli.run(["list", "--limit", "0"]).exitCode == AICLI.ExitCode.rejected)
        #expect(cli.run(["frobnicate"]).exitCode == AICLI.ExitCode.usage)
        #expect(cli.run(["delete"]).exitCode == AICLI.ExitCode.rejected)
        let parsed = try AICLI.parse(
            ["--file", "/a", "--file", "/b", "--copy", "--not-ai-added"],
            flags: AICLI.commands["add"]!.flags.merging(["--not-ai-added": .off("addedByAI")]) { $1 }, stdin: { nil }
        ).get()
        #expect(parsed["filePaths"] == .array([string("/a"), string("/b")]))
        #expect(parsed["copyToClipboard"] == .bool(true))
        #expect(parsed["addedByAI"] == .bool(false))
    }
}

@Suite("AI の口: オンとオフ")
@MainActor
struct AIAccessTests {
    static let historyTools = AITools.tools.filter(\.needsAccess).map(\.name)

    @Test("既定はオフ。オフのとき履歴と定型文の道具はすべて断り、断ったことを記録する")
    func offRefusesEverything() throws {
        let ai = try AIHarness(enabled: false)
        try ai.seed(Fixtures.text("before"))
        #expect(!ai.tools.gateway.isEnabled)
        for name in Self.historyTools {
            let error = ai.error(name, ["text": string("x")])
            #expect(error?.code == .aiAccessDisabled, "\(name)")
            #expect(error?.message.contains("設定画面") == true)
        }
        #expect(try ai.store.count() == 1)
        #expect(ai.log.count == Self.historyTools.count)
        #expect(ai.log.allSatisfy { $0.outcome == .refused })
        // 状態と設定の道具はオフでも使える
        let status = try ai.ok(AITools.Name.status)
        #expect(status.objectValue?["aiAccess"] == string("off"))
        #expect(throws: Never.self) { try ai.ok(AITools.Name.settingsGet, ["id": string("hotkeyMode")]) }
    }

    @Test("CLI・MCP の道具・設定の CLI のどれからも、AI の口をオンにできない")
    func cannotEnableFromAI() throws {
        let ai = try AIHarness(enabled: false)
        let cli = AICLI(tools: ai.tools)
        for verb in ["enable", "on"] {
            let output = cli.run([verb])
            #expect(output.exitCode == AICLI.ExitCode.rejected)
            #expect(output.stderr.contains("設定画面からだけ"))
        }
        for id in ["aiAccess", "AIAccess", "ai.access", "mcp", "ai"] {
            #expect(
                ai.error(AITools.Name.settingsSet, ["id": string(id), "value": .bool(true)])?.code == .settingsRejected)
            #expect(ai.error(AITools.Name.settingsGet, ["id": string(id)])?.code == .settingsRejected)
            #expect(ai.error(AITools.Name.settingsReset, ["ids": .array([string(id)])])?.code == .settingsRejected)
            let settings = SettingsCLI(file: SettingsFile(directory: ai.dir.url)).run(["set", id, "true"])
            #expect(settings.exitCode == SettingsCLI.ExitCode.rejected)
            #expect(settings.stderr.contains("設定画面からだけ"))
        }
        // 設定ファイルに書いても効かない（スキーマにない項目は読み飛ばす）
        try Data(#"{"formatVersion":1,"settings":{"aiAccess":true}}"#.utf8)
            .write(to: SettingsFile(directory: ai.dir.url).url)
        // オンにする道具はない。どの道具に「オンにして」と言っても変わらない
        #expect(!AITools.tools.contains { $0.name.contains("enable") || $0.name.contains("access") })
        for tool in AITools.tools {
            _ = ai.call(tool.name, ["enabled": .bool(true), "aiAccess": .bool(true)])
        }
        #expect(!ai.tools.gateway.isEnabled)
        #expect(!AIAccess.isEnabled(store: ai.store))
    }

    @Test("オンからオフに切り替えた直後の呼び出しは断る（毎回 DB の値を読む）")
    func offRightAfterOn() throws {
        let ai = try AIHarness()
        #expect(throws: Never.self) { try ai.ok(AITools.Name.add, ["text": string("first")]) }
        #expect(AICLI(tools: ai.tools).run(["disable"]).exitCode == AICLI.ExitCode.ok)
        #expect(ai.error(AITools.Name.add, ["text": string("second")])?.code == .aiAccessDisabled)
        #expect(ai.error(AITools.Name.list)?.code == .aiAccessDisabled)
        // 設定画面からもう一度オンにすると使える
        try AIAccess.setEnabled(true, store: ai.store)
        #expect(throws: Never.self) { try ai.ok(AITools.Name.list) }
    }

    @Test("DB のないデータフォルダはオフで、DB も記録も作らない")
    func noDatabase() throws {
        let dir = TemporaryDirectory()
        let gateway = AIGateway(directory: dir.url)
        let tools = AITools(
            gateway: gateway, settingsCLI: SettingsCLI(file: SettingsFile(directory: dir.url)),
            log: AIActivityLog(directory: dir.url), channel: .cli)
        #expect(!gateway.isEnabled)
        #expect(!AIAccess.isEnabled(directory: dir.url))
        if case .failure(let error) = tools.call(AITools.Name.add, arguments: ["text": .string("x")]) {
            #expect(error.code == .aiAccessDisabled)
        } else {
            Issue.record("オフなのに追加できた")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.url.path))
    }

    @Test("動いているアプリの判定は instance.lock で見る")
    func appPresence() throws {
        let dir = TemporaryDirectory()
        #expect(!AppPresence.isRunning(directory: dir.url))
        var lock = InstanceLock(directory: dir.url)
        #expect(lock != nil)
        #expect(AppPresence.isRunning(directory: dir.url))
        lock = nil
        #expect(!AppPresence.isRunning(directory: dir.url))
        // 確かめている間にアプリが起動しても、少し待ってロックを取れる
        #expect(InstanceLock(directory: dir.url) != nil)
    }
}

@Suite("AI の口: 履歴への追加")
@MainActor
struct AIAddTests {
    @Test("文字を足すと、種類を判定し、AI の印とコピー元（AI と相手の名前）を付ける。結果に中身は入れない")
    func addText() throws {
        let ai = try AIHarness()
        let command = "git status --short # \(marker)"
        let result = try ai.ok(AITools.Name.add, ["text": string(command)])
        let object = result.objectValue ?? [:]
        #expect(object["kind"] == string("command"))
        #expect(object["result"] == string("inserted"))
        #expect(object["secret"] == string("none"))
        #expect(object["copiedToClipboard"] == .bool(false))
        #expect(!result.compactText.contains(marker))
        let item = try #require(try ai.store.items().first)
        #expect(item.flags.contains(.addedByAI))
        #expect(item.source?.name == "AI（test-client）")
        #expect(item.source?.bundleID == nil)
        #expect(item.copyMethod == .other)
        #expect(ai.historyChanges == 1)
        #expect(ai.board.pasteboard.pasteboardItems?.isEmpty ?? true)
        // 同じ内容をもう一度足すと、増やさず先頭へ
        let again = try ai.ok(AITools.Name.add, ["text": string(command), "pin": .bool(true)])
        #expect(again.objectValue?["result"] == string("movedToTop"))
        #expect(again.objectValue?["pinned"] == .bool(true))
        #expect(try ai.store.count() == 1)
    }

    @Test("クリップボードにも置くと、取り込み済みの印を付ける（動いている Makurip がもう一度取り込まない）")
    func copyToClipboard() throws {
        let ai = try AIHarness()
        let result = try ai.ok(AITools.Name.add, ["text": string("echo hello"), "copyToClipboard": .bool(true)])
        #expect(result.objectValue?["copiedToClipboard"] == .bool(true))
        let types = (ai.board.pasteboard.types ?? []).map(\.rawValue)
        #expect(types.contains(PasteboardTypes.utf8PlainText))
        #expect(types.contains(PasteboardMarkers.savedByMakuripAI))
        #expect(!types.contains(PasteboardMarkers.concealed))

        // 監視は印を見て取り込まない
        let monitor = PasteboardMonitor(
            pasteboard: ai.board.pasteboard, store: ai.store, limits: .default,
            environment: .init(now: { Date() }, frontmostApp: { nil }, keyMonitorActive: { false }), settleDelay: 0)
        ai.board.write([
            [(PasteboardTypes.utf8PlainText, Data("x".utf8)), (PasteboardMarkers.savedByMakuripAI, Data())]
        ])
        #expect(monitor.poll() == .skipped(.savedByAI))
    }

    @Test("秘密っぽい形式なら印を付けて伏せ字で保存し、クリップボードには ConcealedType を付けて置く")
    func addSecret() throws {
        let ai = try AIHarness()
        let result = try ai.ok(AITools.Name.add, ["text": string(FakeSecret.github), "copyToClipboard": .bool(true)])
        #expect(result.objectValue?["secret"] == string("high"))
        #expect(!result.compactText.contains(FakeSecret.github))
        let item = try #require(try ai.store.items().first)
        #expect(item.flags.isSuperset(of: [.secretLikely, .secretKnownFormat, .addedByAI]))
        #expect(item.previewText?.contains("•") == true)
        #expect(item.previewText?.contains(FakeSecret.github) == false)
        #expect((ai.board.pasteboard.types ?? []).map(\.rawValue).contains(PasteboardMarkers.concealed))
    }

    @Test("画像とファイルも足せる")
    func addImageAndFiles() throws {
        let ai = try AIHarness()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = ai.dir.url.appendingPathComponent("shot.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        #expect(try ai.ok(AITools.Name.add, ["imagePath": string(png.path)]).objectValue?["kind"] == string("image"))
        let files = try ai.ok(AITools.Name.add, ["filePaths": .array([string(png.path), string(ai.dir.url.path)])])
        #expect(files.objectValue?["kind"] == string("file"))
        let id = try #require(files.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(try ai.store.item(id: id)?.pasteboardItemCount == 2)
    }
}

@Suite("AI の口: 形式の一覧（中身を返さない）")
@MainActor
struct AIListTests {
    /// 目印を、文字・URL のクエリ・コピー元ページの URL・ファイル名・RTF・偽の秘密・コードに入れる
    static func seedLeaks(_ ai: AIHarness) throws {
        try ai.seed(Fixtures.text("メモ \(marker) です"), secondsAgo: 70)
        try ai.seed(Fixtures.text("https://example.com/path?q=\(marker)"), secondsAgo: 65)
        try ai.seed(
            Fixtures.text(
                "ページの文 \(marker)",
                extra: [
                    (PasteboardTypes.chromiumSourceURL, Data("https://docs.example.org/a/\(marker)?t=\(marker)".utf8))
                ]),
            secondsAgo: 60)
        let file = ai.dir.url.appendingPathComponent("report-\(marker).txt")
        try Data("x".utf8).write(to: file)
        try ai.seed(
            Fixtures.item([
                (PasteboardTypes.fileURL, Data(file.absoluteString.utf8)),
                (PasteboardTypes.utf8PlainText, Data(file.lastPathComponent.utf8)),
            ]), secondsAgo: 55)
        try ai.seed(Fixtures.item([(PasteboardTypes.rtf, Data(#"{\rtf1\ansi \#(marker)}"#.utf8))]), secondsAgo: 50)
        try ai.seed(Fixtures.text("token: " + "gh" + "p_" + marker + FakeSecret.random(22, seed: 99)), secondsAgo: 45)
        try ai.seed(Fixtures.text("func \(marker)() -> Int {\n    let value = 42\n    return value\n}"), secondsAgo: 40)
    }

    @Test("一覧の出力に、中身・URL のパスとクエリ・ファイル名・ハッシュが入らない")
    func noContentInList() throws {
        let ai = try AIHarness()
        try Self.seedLeaks(ai)
        let result = try ai.ok(AITools.Name.list, ["limit": .int(200)])
        let text = result.compactText
        #expect(result.objectValue?["returned"] == .int(7))
        #expect(!text.contains(marker))
        for item in try ai.store.items() {
            #expect(!text.contains(String(item.contentHash.prefix(12))))
        }
        let keys = allKeys(result)
        for key in [
            "previewText", "preview", "text", "body", "sourceURL", "url", "contentHash", "hash", "path", "fileName",
        ] {
            #expect(!keys.contains(key), "\(key)")
        }
        let items = result.objectValue?["items"]?.arrayValue ?? []
        // コピー元のページはホスト名だけ
        #expect(items.contains { $0.objectValue?["sourcePageHost"] == string("docs.example.org") })
        // コードは言語名だけ
        #expect(items.contains { $0.objectValue?["language"] == string("swift") })
        // 記録にも中身は入らない
        let log = try String(contentsOf: AIActivityLog(directory: ai.dir.url).url, encoding: .utf8)
        #expect(!log.contains(marker))
    }

    @Test("秘密の項目は印と形式の名前だけで、大きさ・長さも返さない")
    func secretItems() throws {
        let ai = try AIHarness()
        try ai.seed(Fixtures.text(FakeSecret.github))
        try ai.seed(Fixtures.text(FakeSecret.randomToken), secondsAgo: 30)
        let items = try ai.ok(AITools.Name.list, ["secret": string("any")]).objectValue?["items"]?.arrayValue ?? []
        #expect(items.count == 2)
        for item in items.compactMap(\.objectValue) {
            #expect(item["totalBytes"] == nil)
            #expect(item["characters"] == nil)
            #expect(item["size"] == string("hidden"))
        }
        let high = items.compactMap(\.objectValue).first { $0["secret"]?.objectValue?["level"] == string("high") }
        let formats = high?["secret"]?.objectValue?["formats"]?.arrayValue?.compactMap { $0.objectValue?["id"] } ?? []
        #expect(formats == [string("githubToken")])
        #expect(!items.map(\.compactText).joined().contains(FakeSecret.github))
    }

    @Test("絞り込み（種類・AI が足したもの・期間・コピー元アプリ・ピン留め）")
    func filters() throws {
        let ai = try AIHarness()
        try ai.seed(Fixtures.png, secondsAgo: 3600 * 3, app: "com.apple.Preview")
        try ai.seed(Fixtures.text("plain note"), secondsAgo: 120)
        _ = try ai.ok(AITools.Name.add, ["text": string("ls -la")])
        func count(_ args: [String: JSONValue]) throws -> Int? {
            try ai.ok(AITools.Name.list, args).objectValue?["matched"]?.intValue
        }
        #expect(try count([:]) == 3)
        #expect(try count(["kind": string("image")]) == 1)
        #expect(try count(["addedByAI": .bool(true)]) == 1)
        #expect(try count(["addedByAI": .bool(false)]) == 2)
        #expect(try count(["withinMinutes": .int(10)]) == 2)
        #expect(try count(["olderThanMinutes": .int(60)]) == 1)
        #expect(try count(["sourceApp": string("com.apple.preview")]) == 1)
        #expect(try count(["sourceApp": string("AI")]) == 1)
        #expect(try count(["pinned": .bool(true)]) == 0)
        let text = try ai.ok(AITools.Name.list, ["kind": string("text")]).objectValue?["items"]?.arrayValue?.first
        #expect(text?.objectValue?["characters"] == .int(10))
        #expect(text?.objectValue?["lines"] == .int(1))
    }
}

@Suite("AI の口: 削除")
@MainActor
struct AIDeleteTests {
    @Test("秘密の削除は確度で絞れ、件数だけを返す。ピン留めは includePinned のときだけ")
    func deleteSecrets() throws {
        let ai = try AIHarness()
        try ai.seed(Fixtures.text(FakeSecret.github), secondsAgo: 10)
        let pinned = try ai.seed(Fixtures.text(FakeSecret.openAITest), secondsAgo: 20)
        try ai.store.setPinned(true, id: pinned)
        try ai.seed(Fixtures.text(FakeSecret.awsAccessKey), secondsAgo: 3600)
        try ai.seed(Fixtures.text(FakeSecret.randomToken), secondsAgo: 30)
        try ai.seed(Fixtures.text("ふつうのメモ"), secondsAgo: 40)

        let dry = try ai.ok(AITools.Name.deleteSecrets, ["dryRun": .bool(true)])
        #expect(dry.objectValue?["wouldDelete"] == .int(2))
        #expect(try ai.store.count() == 5)

        let recent = try ai.ok(AITools.Name.deleteSecrets, ["withinMinutes": .int(30)])
        #expect(recent.objectValue?["deleted"] == .int(1))
        #expect(recent.objectValue?.keys.sorted() == ["deleted", "message"])
        #expect(ai.historyChanges == 1)

        #expect(try ai.ok(AITools.Name.deleteSecrets).objectValue?["deleted"] == .int(1))
        #expect(try ai.ok(AITools.Name.deleteSecrets, ["confidence": string("any")]).objectValue?["deleted"] == .int(1))
        #expect(
            try ai.ok(AITools.Name.deleteSecrets, ["includePinned": .bool(true)]).objectValue?["deleted"] == .int(1))
        let left = try ai.store.items()
        #expect(left.count == 1)
        #expect(left.allSatisfy { !$0.isSecretLikely })
        #expect(ai.log.first?.summary.contains("1 件") == true)
    }

    @Test("条件での削除（種類・AI が足したもの・期間・id）。dryRun は消さない")
    func deleteByCondition() throws {
        let ai = try AIHarness()
        let image = try ai.seed(Fixtures.png, secondsAgo: 7200)
        try ai.seed(Fixtures.text("keep me"), secondsAgo: 60)
        let pinnedImage = try ai.seed(Fixtures.item([(PasteboardTypes.tiff, Fixtures.tiffBytes)]), secondsAgo: 30)
        try ai.store.setPinned(true, id: pinnedImage)
        _ = try ai.ok(AITools.Name.add, ["text": string("npm test")])
        _ = try ai.ok(AITools.Name.add, ["text": string("make check")])

        #expect(
            try ai.ok(AITools.Name.delete, ["addedByAI": .bool(true), "dryRun": .bool(true)]).objectValue?[
                "wouldDelete"] == .int(2))
        #expect(try ai.ok(AITools.Name.delete, ["addedByAI": .bool(true)]).objectValue?["deleted"] == .int(2))
        #expect(try ai.ok(AITools.Name.delete, ["kind": string("image")]).objectValue?["deleted"] == .int(1))
        #expect(try ai.store.item(id: image) == nil)
        #expect(try ai.store.item(id: pinnedImage) != nil)
        #expect(try ai.ok(AITools.Name.delete, ["olderThanMinutes": .int(5)]).objectValue?["deleted"] == .int(0))
        #expect(
            try ai.ok(
                AITools.Name.delete, ["ids": .array([string(pinnedImage.uuidString)]), "includePinned": .bool(true)]
            )
            .objectValue?["deleted"] == .int(1))
        #expect(try ai.store.count() == 1)
    }
}

@Suite("AI の口: 設定（#4 と同じ検証）")
@MainActor
struct AISettingsToolTests {
    @Test("検証に通らない値は、設定の CLI と同じ理由で拒否する")
    func sameValidationAsCLI() throws {
        let ai = try AIHarness(enabled: false)
        let cli = SettingsCLI(file: SettingsFile(directory: ai.dir.url))
        for (id, value, args) in [
            ("maxItems", JSONValue.int(5), ["5"]), ("keys.open", string("V"), ["V"]),
            ("hotkeyMode", string("sometimes"), ["sometimes"]), ("secretAutoDeleteMinutes", .int(0), ["0"]),
            ("keys.method", string("⌘E"), ["⌘E"]),
        ] {
            let error = ai.error(AITools.Name.settingsSet, ["id": string(id), "value": value])
            let expected = cli.run(["set", id] + args).stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(error?.code == .settingsRejected, "\(id)")
            #expect(error?.message == expected, "\(id)")
        }
        #expect(SettingsFile(directory: ai.dir.url).load().exists == false)
    }

    @Test("頼みの例（候補窓は出さないで・呼び出しを ⌥V に・Safari は残さないで）が通り、設定ファイルに書く")
    func examples() throws {
        let ai = try AIHarness(enabled: false)
        _ = try ai.ok(AITools.Name.settingsSet, ["id": string("hotkeyMode"), "value": string("paste")])
        let keys = try ai.ok(AITools.Name.settingsSet, ["id": string("keys.open"), "value": string("⌥V")])
        #expect(keys.objectValue?["value"] == .array([string("⌥V")]))
        _ = try ai.ok(
            AITools.Name.settingsSet,
            ["id": string("excludedApps"), "operation": string("add"), "value": string("com.apple.Safari")])
        _ = try ai.ok(AITools.Name.settingsSet, ["id": string("maxItems"), "value": .int(200)])
        let settings = SettingsFile(directory: ai.dir.url).load().settings
        #expect(settings.candidate.hotKeyMode == .pasteOnly)
        #expect(settings.excludedApps == ["com.apple.Safari"])
        #expect(settings.limits.maxItems == 200)
        #expect(try ai.ok(AITools.Name.settingsGet, ["id": string("maxItems")]).objectValue?["value"] == .int(200))
        let list = try ai.ok(AITools.Name.settingsList)
        #expect(list.objectValue?["changed"]?.arrayValue?.contains(string("hotkeyMode")) == true)
        _ = try ai.ok(AITools.Name.settingsReset, ["ids": .array([string("maxItems")])])
        #expect(SettingsFile(directory: ai.dir.url).load().settings.limits.maxItems == Limits.default.maxItems)
        let schema = try ai.ok(AITools.Name.settingsSchema)
        #expect(schema.objectValue?["items"]?.arrayValue?.isEmpty == false)
        #expect(!schema.compactText.contains("aiAccess"))
        // 書いた設定は記録に残る（読んだだけのものは残さない）
        #expect(ai.log.map(\.tool).filter { $0 == AITools.Name.settingsSet }.count == 4)
        #expect(!ai.log.contains { $0.tool == AITools.Name.settingsGet })
    }
}

@Suite("AI の口: 定型文")
@MainActor
struct AISnippetToolTests {
    @Test("登録・一覧（本文は返さない）・削除。オフなら断る")
    func snippets() throws {
        let ai = try AIHarness()
        let added = try ai.ok(
            AITools.Name.addSnippet, ["body": string("よろしくお願いします \(marker)\n{{日付}}"), "abbreviation": string(";yr")])
        let id = try #require(added.objectValue?["id"]?.stringValue)
        #expect(added.objectValue?["placeholders"] == .array([string("日付")]))
        _ = try ai.ok(AITools.Name.addSnippet, ["body": string(FakeSecret.github), "name": string(FakeSecret.github)])
        _ = try ai.ok(AITools.Name.addSnippet, ["body": string("ありがとうございました"), "name": string("お礼")])
        let list = try ai.ok(AITools.Name.listSnippets)
        #expect(list.objectValue?["total"] == .int(3))
        // 名前を付けなかったもの（名前が本文の 1 行目）は名前も返さない
        #expect(!list.compactText.contains(marker))
        #expect(!list.compactText.contains(FakeSecret.github))
        #expect(!allKeys(list).contains("body"))
        let names = list.objectValue?["items"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        #expect(names == ["お礼"])
        let flags = list.objectValue?["items"]?.arrayValue?.map { $0.objectValue?["secretLikely"] } ?? []
        #expect(flags == [.bool(false), .bool(true), .bool(false)])
        #expect(SnippetFile(directory: ai.dir.url).load().collection.count == 3)
        #expect(ai.error(AITools.Name.addSnippet, ["body": string("   ")])?.code == .invalidArguments)
        #expect(
            ai.error(AITools.Name.addSnippet, ["body": string("a"), "abbreviation": string("a b")])?.code
                == .invalidArguments)
        #expect(
            try ai.ok(AITools.Name.deleteSnippets, ["ids": .array([string(id)])]).objectValue?["deleted"] == .int(1))
        #expect(
            try ai.ok(AITools.Name.deleteSnippets, ["ids": .array([string(id)])]).objectValue?["deleted"] == .int(0))
        try AIAccess.setEnabled(false, store: ai.store)
        #expect(ai.error(AITools.Name.listSnippets)?.code == .aiAccessDisabled)
    }
}

@Suite("AI の口: 操作の記録")
struct AIActivityLogTests {
    @Test("新しい順に読め、上限を超えたら古いものから捨てる")
    func appendAndTrim() throws {
        let dir = TemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let log = AIActivityLog(directory: dir.url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(AIActivityLog.maxEntries + 300) {
            log.append(
                AIActivityEntry(
                    at: start.addingTimeInterval(Double(index)), channel: .mcp, client: "c", tool: "t\(index)",
                    outcome: .ok, summary: String(repeating: "あ", count: 40)))
        }
        let recent = log.recent(limit: 3)
        #expect(recent.map(\.tool) == ["t799", "t798", "t797"])
        let all = log.recent(limit: 10_000)
        #expect(all.count <= AIActivityLog.maxEntries + 300)
        #expect(all.count >= AIActivityLog.maxEntries)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("相手の名前は短く切り、制御文字を除く")
    func clientName() {
        #expect(AIClientName.sanitized("claude-code\n\u{1B}[31m") == "claude-code[31m")
        #expect(AIClientName.sanitized(String(repeating: "x", count: 100))?.count == AIClientName.maxLength)
        #expect(AIClientName.sanitized("  ") == nil)
        #expect(AIClientName.sourceName(nil) == "AI")
    }
}

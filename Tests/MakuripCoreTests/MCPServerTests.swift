import Foundation
import Testing

@testable import MakuripCore

@Suite("MCP のサーバー（JSON-RPC）")
@MainActor
struct MCPServerTests {
    static func request(_ id: Int, _ method: String, _ params: [String: JSONValue]? = nil) -> String {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method)]
        if let params { object["params"] = .object(params) }
        return JSONValue.object(object).compactText
    }

    static func call(_ id: Int, _ tool: String, _ arguments: [String: JSONValue] = [:]) -> String {
        request(id, "tools/call", ["name": .string(tool), "arguments": .object(arguments)])
    }

    static func parse(_ line: String?) throws -> [String: JSONValue] {
        let line = try #require(line)
        #expect(!line.contains("\n"), "応答は 1 行")
        return try #require(JSONValue.parse(line)?.objectValue)
    }

    @Test("initialize は相手の版で答え、相手の名前を覚える。知らない版ならいちばん新しい版")
    func initialize() throws {
        let ai = try AIHarness(client: nil)
        let server = MCPServer(tools: ai.tools, version: "0.0.0")
        let response = try Self.parse(
            server.handle(
                Self.request(
                    1, "initialize",
                    [
                        "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                        "clientInfo": .object(["name": .string("claude-code"), "version": .string("2")]),
                    ])))
        let result = try #require(response["result"]?.objectValue)
        #expect(response["id"] == .int(1))
        #expect(result["protocolVersion"] == .string("2025-06-18"))
        #expect(result["serverInfo"]?.objectValue?["name"] == .string("makurip"))
        #expect(result["capabilities"]?.objectValue?["tools"] != nil)
        #expect(result["instructions"]?.stringValue?.isEmpty == false)
        #expect(server.clientName == "claude-code")
        // 相手の名前は「コピー元アプリ」と記録に出る
        _ = server.handle(Self.call(2, AITools.Name.add, ["text": .string("make test")]))
        #expect(try ai.store.items().first?.source?.name == "AI（claude-code）")
        #expect(ai.log.first?.client == "claude-code")

        let other = MCPServer(tools: ai.tools, version: "0.0.0")
        let old = try Self.parse(
            other.handle(Self.request(3, "initialize", ["protocolVersion": .string("1999-01-01")])))
        #expect(old["result"]?.objectValue?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
    }

    @Test("通知には応えない。ping・tools/list に応える")
    func basics() throws {
        let ai = try AIHarness()
        let server = MCPServer(tools: ai.tools, version: "0")
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        #expect(try Self.parse(server.handle(Self.request(1, "ping")))["result"] == .object([:]))
        let list = try Self.parse(server.handle(Self.request(2, "tools/list")))
        let tools = list["result"]?.objectValue?["tools"]?.arrayValue ?? []
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names == AITools.tools.map(\.name))
        for tool in tools.compactMap(\.objectValue) {
            #expect(tool["inputSchema"]?.objectValue?["type"] == .string("object"))
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        // 文字の id も使える
        let ping = try Self.parse(server.handle(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#))
        #expect(ping["id"] == .string("abc"))
        // 相手からの応答は読み捨てる
        #expect(server.handle(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
    }

    @Test("壊れた JSON・形の誤り・知らない method・知らない道具は JSON-RPC の誤りで返す")
    func errors() throws {
        let ai = try AIHarness()
        let server = MCPServer(tools: ai.tools, version: "0")
        func code(_ line: String) throws -> Int? {
            try Self.parse(server.handle(line))["error"]?.objectValue?["code"]?.intValue
        }
        #expect(try code("{not json") == MCPServer.ErrorCode.parse)
        #expect(try code("") == MCPServer.ErrorCode.parse)
        #expect(try code("42") == MCPServer.ErrorCode.invalidRequest)
        #expect(try code("[]") == MCPServer.ErrorCode.invalidRequest)
        #expect(try code(#"{"jsonrpc":"2.0","id":1}"#) == MCPServer.ErrorCode.invalidRequest)
        #expect(try code(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#) == MCPServer.ErrorCode.invalidRequest)
        #expect(try code(Self.request(1, "resources/list")) == MCPServer.ErrorCode.methodNotFound)
        #expect(try code(Self.request(2, "tools/call", [:])) == MCPServer.ErrorCode.invalidParams)
        #expect(try code(Self.call(3, "read_clipboard_contents")) == MCPServer.ErrorCode.invalidParams)
        #expect(
            try code(Self.request(4, "tools/call", ["name": .string("status"), "arguments": .array([])]))
                == MCPServer.ErrorCode.invalidParams)
    }

    @Test("道具の失敗（オフ・入力の誤り）は isError の結果で返し、理由の文を入れる")
    func toolFailures() throws {
        let ai = try AIHarness(enabled: false)
        let server = MCPServer(tools: ai.tools, version: "0")
        let refused = try Self.parse(server.handle(Self.call(1, AITools.Name.list)))
        let result = try #require(refused["result"]?.objectValue)
        #expect(result["isError"] == .bool(true))
        #expect(result["structuredContent"]?.objectValue?["error"] == .string("aiAccessDisabled"))
        let text = result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(text.contains("設定画面"))

        try AIAccess.setEnabled(true, store: ai.store)
        let invalid = try Self.parse(server.handle(Self.call(2, AITools.Name.add, ["text": .number(3)])))
        #expect(invalid["result"]?.objectValue?["isError"] == .bool(true))
        let ok = try Self.parse(server.handle(Self.call(3, AITools.Name.add, ["text": .string("ls")])))
        #expect(ok["result"]?.objectValue?["isError"] == .bool(false))
        #expect(ok["result"]?.objectValue?["structuredContent"]?.objectValue?["kind"] == .string("command"))
    }

    @Test("まとめて送った要求には、まとめて答える（通知の分は入れない）")
    func batch() throws {
        let ai = try AIHarness()
        let server = MCPServer(tools: ai.tools, version: "0")
        let line =
            "[" + Self.request(1, "ping") + "," + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + ","
            + Self.request(2, "tools/list") + "]"
        let response = try #require(server.handle(line))
        let responses = try #require(JSONValue.parse(response)?.arrayValue)
        #expect(responses.compactMap { $0.objectValue?["id"] } == [.int(1), .int(2)])
    }

    @Test("全道具を呼んだ応答に、履歴の中身（目印）が 1 つも入らない")
    func noLeakThroughAnyTool() throws {
        let ai = try AIHarness()
        try AIListTests.seedLeaks(ai)
        let server = MCPServer(tools: ai.tools, version: "0")
        var responses: [String] = []
        func send(_ line: String) { if let response = server.handle(line) { responses.append(response) } }
        send(Self.request(1, "initialize", ["protocolVersion": .string("2025-06-18")]))
        send(Self.request(2, "tools/list"))
        var id = 3
        let calls: [(String, [String: JSONValue])] = [
            (AITools.Name.status, [:]),
            (AITools.Name.list, ["limit": .int(200)]),
            (AITools.Name.list, ["secret": .string("any")]),
            (AITools.Name.list, ["kind": .string("file")]),
            (AITools.Name.add, ["text": .string("echo added-by-test")]),
            (AITools.Name.deleteSecrets, ["dryRun": .bool(true)]),
            (AITools.Name.delete, ["kind": .string("url"), "dryRun": .bool(true)]),
            (AITools.Name.addSnippet, ["body": .string("定型文の本文"), "name": .string("名前")]),
            (AITools.Name.listSnippets, [:]),
            (AITools.Name.settingsSchema, [:]),
            (AITools.Name.settingsList, [:]),
            (AITools.Name.settingsGet, ["id": .string("hotkeyMode")]),
            (AITools.Name.settingsSet, ["id": .string("candOrder"), "value": .string("ime")]),
            (AITools.Name.settingsReset, ["ids": .array([.string("candOrder")])]),
            (AITools.Name.deleteSecrets, [:]),
            (AITools.Name.delete, ["kind": .string("richText")]),
            (AITools.Name.list, [:]),
        ]
        for (tool, arguments) in calls {
            send(Self.call(id, tool, arguments))
            id += 1
        }
        #expect(responses.count == calls.count + 2)
        let joined = responses.joined(separator: "\n")
        #expect(!joined.contains(marker), "応答に目印が入った")
        // 道具はどれも成功している（漏れの検査が、誤りで素通りしていない）
        let failures = responses.compactMap { JSONValue.parse($0)?.objectValue?["result"]?.objectValue?["isError"] }
            .filter { $0 == .bool(true) }
        #expect(failures.isEmpty)
        #expect(try ai.store.count() == 6)
    }
}

@Suite("MCP の行の読み取り")
struct MCPLineReaderTests {
    func lines(_ text: String, max: Int) throws -> [MCPLineReader.Line] {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        let reader = MCPLineReader(handle: pipe.fileHandleForReading, maxLineBytes: max, chunkSize: 4)
        var result: [MCPLineReader.Line] = []
        while let line = reader.next() { result.append(line) }
        return result
    }

    @Test("改行で区切る。最後の行に改行がなくても 1 行。上限を超えた行は捨てて tooLarge にし、次の行から続ける")
    func splitting() throws {
        let line: (String) -> MCPLineReader.Line = { .line(Data($0.utf8)) }
        #expect(try lines("a\nbb\nccc", max: 100) == [line("a"), line("bb"), line("ccc")])
        #expect(
            try lines("short\n" + String(repeating: "x", count: 50) + "\nok\n", max: 10) == [
                line("short"), .tooLarge, line("ok"),
            ])
        #expect(try lines(String(repeating: "y", count: 30), max: 10) == [.tooLarge])
        #expect(try lines("", max: 10).isEmpty)
    }
}

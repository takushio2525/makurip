import Foundation

/// MCP（Model Context Protocol）のサーバー。標準入出力で、1 行 1 件の JSON-RPC 2.0 を受けて返す（MCP の stdio の決まり）。
///
/// 扱うのは道具（tools）だけ: `initialize`・`notifications/initialized`・`ping`・`tools/list`・`tools/call`。
/// 道具の中身は `AITools`（`--ai` の CLI と同じ）。外部の SDK は使わない（`.agent/architecture.md` の「技術選定（フェーズ6）」）。
///
/// - 標準出力には JSON-RPC の応答だけを書く（ログを混ぜない）
/// - 道具の失敗（AI の口がオフ・入力の誤り）は、JSON-RPC の誤りでなく `isError: true` の結果で返す（AI が読んで直せるように）。
///   知らない道具・引数の形の誤りは JSON-RPC の誤り（-32602）
@MainActor
public final class MCPServer {
    /// 応じられる版（新しい順）。相手が言った版があればそれで、なければいちばん新しい版で答える
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// 1 件の要求の大きさの上限（追加できる文字の上限 50 MB を JSON にしても入る大きさ）
    public static let maxMessageBytes = 128 * 1024 * 1024
    public static let serverName = "makurip"

    public enum ErrorCode {
        public static let parse = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
    }

    public let tools: AITools
    public let version: String
    /// 相手の名前（initialize の clientInfo.name）
    public private(set) var clientName: String?
    public private(set) var negotiatedVersion: String?

    public init(tools: AITools, version: String) {
        self.tools = tools
        self.version = version
    }

    // MARK: 読み書きの繰り返し

    /// 標準入力が閉じるまで読み、応答を書く
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        let reader = MCPLineReader(handle: input, maxLineBytes: Self.maxMessageBytes)
        while let line = reader.next() {
            let response: String?
            switch line {
            case .line(let data):
                // 空の行は読み飛ばす
                if data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
                response = handle(data)
            case .tooLarge:
                response = Self.encode(
                    Self.error(
                        id: .null, code: ErrorCode.invalidRequest,
                        message: "要求が大きすぎます（\(Self.maxMessageBytes / 1_048_576) MB まで）。"))
            }
            if let response {
                output.write(Data((response + "\n").utf8))
            }
        }
    }

    // MARK: 1 件ずつ

    /// 1 行の要求（JSON）に対する 1 行の応答。通知（id のないもの）には応答しない（nil）
    public func handle(_ line: String) -> String? {
        handle(Data(line.utf8))
    }

    public func handle(_ data: Data) -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return Self.encode(Self.error(id: .null, code: ErrorCode.parse, message: "JSON として読めません。"))
        }
        if case .array(let batch) = message {
            // 2025-03-26 の版で使える、まとめて送る形
            guard !batch.isEmpty else {
                return Self.encode(Self.error(id: .null, code: ErrorCode.invalidRequest, message: "空の配列です。"))
            }
            let responses = batch.compactMap(respond)
            return responses.isEmpty ? nil : Self.encode(.array(responses))
        }
        return respond(message).map(Self.encode)
    }

    private func respond(_ message: JSONValue) -> JSONValue? {
        guard let object = message.objectValue else {
            return Self.error(id: .null, code: ErrorCode.invalidRequest, message: "要求は JSON のオブジェクトにしてください。")
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // 相手からの応答（こちらは要求を送らないので、来ても読み捨てる）
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.error(id: id ?? .null, code: ErrorCode.invalidRequest, message: "method がありません。")
        }
        if let id, !Self.isValidID(id) {
            return Self.error(id: .null, code: ErrorCode.invalidRequest, message: "id は文字列か数にしてください。")
        }
        let params = object["params"]?.objectValue ?? [:]
        // id のないものは通知（notifications/initialized など。応答しない）
        guard let id else { return nil }
        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(AITools.tools.map(\.json))]))
        case "tools/call":
            return callTool(id: id, params: params)
        default:
            return Self.error(id: id, code: ErrorCode.methodNotFound, message: "知らない method: \(method)")
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version =
            requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        negotiatedVersion = version
        clientName = AIClientName.sanitized(params["clientInfo"]?.objectValue?["name"]?.stringValue)
        tools.client = clientName
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(Self.serverName), "title": .string("Makurip（クリップボード履歴）"),
                "version": .string(self.version),
            ]),
            "instructions": .string(Self.instructions),
        ])
    }

    private func callTool(id: JSONValue, params: [String: JSONValue]) -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            return Self.error(id: id, code: ErrorCode.invalidParams, message: "params.name（道具の名前）がありません。")
        }
        guard AITools.tool(named: name) != nil else {
            return Self.error(
                id: id, code: ErrorCode.invalidParams,
                message: "知らない道具: \(name)。使える道具: \(AITools.tools.map(\.name).joined(separator: "・"))")
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let object)?: arguments = object
        default:
            return Self.error(id: id, code: ErrorCode.invalidParams, message: "params.arguments は JSON のオブジェクトにしてください。")
        }
        switch tools.call(name, arguments: arguments) {
        case .success(let output):
            return Self.result(
                id: id,
                .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(output.structured.compactText)])
                    ]),
                    "structuredContent": output.structured,
                    "isError": .bool(false),
                ]))
        case .failure(let error):
            let structured: JSONValue = .object([
                "error": .string(error.code.rawValue), "message": .string(error.message),
            ])
            return Self.result(
                id: id,
                .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(error.message)])]),
                    "structuredContent": structured,
                    "isError": .bool(true),
                ]))
        }
    }

    // MARK: JSON-RPC の形

    static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .number: true
        default: false
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ])
    }

    /// 1 行の JSON（改行を含めない。文字の中の改行は \n に書く）
    static func encode(_ value: JSONValue) -> String {
        value.compactText
    }

    /// initialize で AI に渡す案内
    static let instructions = """
        Makurip は Mac のクリップボード履歴アプリ。この MCP では、履歴の中身を見ずに次のことができる。
        - 履歴への追加（add_to_history。「このコマンドを履歴に入れておいて」）と定型文の登録（add_snippet）
        - 形式の情報だけの一覧（list_history。id・時刻・種類・コピー元アプリ・型名・大きさ・言語・秘密の印。中身・URL・ファイル名は返さない）
        - 秘密っぽいもの（API キー・トークン・秘密鍵など。Makurip が形式だけで判定）を消す（delete_secrets。「さっきの API キーを消して」→ withinMinutes: 30）
        - 条件での削除（delete_history。dryRun で先に数えられる）
        - 設定の読み書き（settings_schema を読んで、頼みに合う項目を settings_set で変える。「候補窓は出さないで」→ hotkeyMode を paste）
        履歴と定型文の道具は、ユーザーが Makurip の設定画面で「AI の口」をオンにしたときだけ使える。オフなら道具がそう答えるので、ユーザーにオンにするよう頼む（AI からはオンにできない）。設定の道具はいつでも使える。
        消す道具は元に戻せない。消す範囲に迷ったら dryRun: true で数え、ユーザーに確かめる。
        """
}

/// 標準入力から 1 行ずつ読む（改行まで）。上限を超えた行は捨てて `tooLarge` を返す（メモリを使い果たさないため）
public final class MCPLineReader {
    public enum Line: Equatable {
        case line(Data)
        case tooLarge
    }

    private let handle: FileHandle
    private let maxLineBytes: Int
    private let chunkSize: Int
    private var buffer = Data()
    /// `buffer` の先頭からここまでは改行がないと分かっている（長い行で毎回頭から探さないため）
    private var scanned = 0
    private var discarding = false
    private var finished = false

    public init(handle: FileHandle, maxLineBytes: Int, chunkSize: Int = 64 * 1024) {
        self.handle = handle
        self.maxLineBytes = maxLineBytes
        self.chunkSize = chunkSize
    }

    /// 次の行。読み終わったら nil（最後の行に改行がなくても 1 行として返す）
    public func next() -> Line? {
        while true {
            let start = buffer.startIndex + scanned
            if let newline = buffer[start...].firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                scanned = 0
                if discarding {
                    discarding = false
                    return .tooLarge
                }
                return .line(line)
            }
            scanned = buffer.count
            if buffer.count > maxLineBytes {
                // 改行が来るまで捨て続ける
                discarding = true
                buffer.removeAll(keepingCapacity: true)
                scanned = 0
            }
            if finished {
                guard !buffer.isEmpty || discarding else { return nil }
                let last: Line = discarding ? .tooLarge : .line(buffer)
                buffer.removeAll()
                scanned = 0
                discarding = false
                return last
            }
            if let chunk = readAvailable() {
                buffer.append(chunk)
            } else {
                finished = true
            }
        }
    }

    /// 届いている分だけ読む（なければ届くまで待つ）。閉じたら nil。
    /// `FileHandle.read(upToCount:)` はパイプでは大きさがそろうか閉じるまで戻らないので使わない
    /// （相手が入力を開いたまま 1 行ずつ送って応答を待つと、互いに待ち続けてしまう）
    private func readAvailable() -> Data? {
        var bytes = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = bytes.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, chunkSize) }
            if count > 0 { return Data(bytes[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }
}

import Foundation

/// AI の口の道具の一覧と、引数の検証・実行。MCP（`MCPServer`）と `--ai` の CLI（`AICLI`）は、どちらもここを通す
/// （同じ引数を同じ検証にかけ、同じ JSON を返す）。
///
/// - 履歴の道具（`add_to_history`・`list_history`・`delete_secrets`・`delete_history`）・定型文の道具と、
///   設定を変える道具（`settings_set`・`settings_reset`）は AI の口がオンのときだけ使える。設定を変えると、上限を下げて
///   履歴を消したり、記録しないアプリを外したり、秘密の自動消去を遅らせたりできるため（#26）
/// - 設定を読む道具（`settings_schema`・`settings_list`・`settings_get`）はオフでも使える（設定に秘密は入っていない）。
///   中身は #4 の設定の CLI（`SettingsCLI`）で、検証も出力も同じ。AI の口のオン・オフはここからは変えられない
/// - **AI の口をオンにする道具はない**（設定画面からだけ。`AIAccess`）
/// - 行ったこと（メタデータだけ）を `AIActivityLog` に残す
@MainActor
public final class AITools {
    public struct Tool: Sendable {
        public let name: String
        public let title: String
        public let description: String
        public let inputSchema: JSONValue
        /// 履歴・定型文を触るか、履歴を減らしうる（AI の口がオンのときだけ使える）
        public let needsAccess: Bool
        /// 何も変えない
        public let readOnly: Bool
        /// 消す
        public let destructive: Bool
        /// 行ったことを記録に残す（読むだけの設定の道具と状態は残さない）
        public let logged: Bool

        /// MCP の tools/list の 1 件
        public var json: JSONValue {
            .object([
                "name": .string(name), "title": .string(title), "description": .string(description),
                "inputSchema": inputSchema,
                "annotations": .object([
                    "title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                    "idempotentHint": .bool(readOnly), "openWorldHint": .bool(false),
                ]),
            ])
        }
    }

    /// 成功したときの結果（`structured` は MCP の structuredContent と `--json` の出力。`summary` は人が読む 1 行）
    public struct Output: Sendable, Equatable {
        public var structured: JSONValue
        public var summary: String
    }

    public enum Name {
        public static let status = "status"
        public static let add = "add_to_history"
        public static let list = "list_history"
        public static let deleteSecrets = "delete_secrets"
        public static let delete = "delete_history"
        public static let settingsSchema = "settings_schema"
        public static let settingsList = "settings_list"
        public static let settingsGet = "settings_get"
        public static let settingsSet = "settings_set"
        public static let settingsReset = "settings_reset"
        public static let addSnippet = "add_snippet"
        public static let listSnippets = "list_snippets"
        public static let deleteSnippets = "delete_snippets"
    }

    public let gateway: AIGateway
    public let settingsCLI: SettingsCLI
    public let log: AIActivityLog?
    public let channel: AIActivityEntry.Channel
    /// MCP の相手の名前（`initialize` で決まる。記録と「コピー元アプリ」に出す）
    public var client: String? {
        didSet { client = AIClientName.sanitized(client) }
    }
    private let now: () -> Date
    /// 記録を足したあとに呼ぶ（動いている Makurip の設定画面に知らせる）
    private let activityDidChange: () -> Void

    public init(
        gateway: AIGateway, settingsCLI: SettingsCLI, log: AIActivityLog?, channel: AIActivityEntry.Channel,
        client: String? = nil, now: @escaping () -> Date = { Date() }, activityDidChange: @escaping () -> Void = {}
    ) {
        self.gateway = gateway
        self.settingsCLI = settingsCLI
        self.log = log
        self.channel = channel
        self.client = AIClientName.sanitized(client)
        self.now = now
        self.activityDidChange = activityDidChange
    }

    public static func tool(named name: String) -> Tool? { tools.first { $0.name == name } }

    // MARK: 呼ぶ

    public func call(_ name: String, arguments: [String: JSONValue]) -> Result<Output, AIToolError> {
        guard let tool = Self.tool(named: name) else {
            return .failure(
                AIToolError(.unknownTool, "知らない道具: \(name)。使える道具: \(Self.tools.map(\.name).joined(separator: "・"))"))
        }
        let result: Result<Output, AIToolError>
        do {
            if tool.needsAccess, !gateway.isEnabled { throw AIToolError.disabled }
            result = .success(try perform(tool.name, Arguments(arguments, tool: tool)))
        } catch let error as AIToolError {
            result = .failure(error)
        } catch {
            result = .failure(AIToolError(.unavailable, "行えませんでした（\(AIGateway.errorKind(error))）。"))
        }
        record(tool, result)
        return result
    }

    private func perform(_ name: String, _ args: Arguments) throws -> Output {
        switch name {
        case Name.status:
            try args.only([])
            let status = gateway.status()
            return Output(structured: status, summary: status.objectValue?["message"]?.stringValue ?? "")
        case Name.add: return try add(Self.parseAdd(args))
        case Name.list:
            let (filter, limit) = try Self.parseList(args)
            return try list(filter, limit: limit)
        case Name.deleteSecrets:
            let request = try Self.parseDeleteSecrets(args)
            let result = try gateway.deleteSecrets(
                confidence: request.confidence, withinMinutes: request.withinMinutes,
                includePinned: request.includePinned, dryRun: request.dryRun)
            let what = request.confidence == .high ? "秘密っぽいもの（確度「高」）" : "秘密っぽいもの（確度「高」と「中」）"
            return deleted(result, what: what)
        case Name.delete:
            let request = try Self.parseDelete(args)
            let result = try gateway.delete(
                request.filter, includePinned: request.includePinned, dryRun: request.dryRun)
            return deleted(result, what: "条件に合うもの")
        case Name.settingsSchema:
            try args.only([])
            var schema = try settings(["schema"])
            if case .object(var object) = schema {
                object["mcpNote"] = .string(
                    "MCP では settings_set に id と value を渡して変える（examples の command は同じ操作の CLI の形）。AI の口のオン・オフはここにない（設定画面からだけ）。"
                )
                schema = .object(object)
            }
            return Output(structured: schema, summary: "設定項目の一覧")
        case Name.settingsList:
            try args.only([])
            return Output(structured: try settings(["list"]), summary: "いまの設定")
        case Name.settingsGet:
            try args.only(["id"])
            let id = try args.requiredString("id")
            try Self.refuseGate(id)
            let value = try settings(["get", id])
            return Output(
                structured: .object(["id": .string(id), "value": value]), summary: "\(id) = \(value.compactText)")
        case Name.settingsSet:
            return try settingsSet(args)
        case Name.settingsReset:
            return try settingsReset(args)
        case Name.addSnippet: return try addSnippet(args)
        case Name.listSnippets: return try listSnippets(args)
        case Name.deleteSnippets: return try deleteSnippets(args)
        default:
            throw AIToolError(.unknownTool, "知らない道具: \(name)")
        }
    }

    // MARK: 履歴の道具

    private func add(_ request: AIAddRequest) throws -> Output {
        let result = try gateway.add(request, client: client)
        let secret =
            result.flags.contains(.secretKnownFormat)
            ? "high" : result.flags.contains(.secretLikely) ? "medium" : "none"
        var parts = [result.movedToTop ? "AI が前に足した同じ内容を先頭へ移しました" : "\(result.kind.label)を履歴に追加しました"]
        if result.pinned { parts.append("ピン留めしました") }
        if result.copiedToClipboard { parts.append("クリップボードにも置きました") }
        if secret != "none" {
            parts.append(
                "秘密っぽい形式なので一覧では伏せ字になります" + (secret == "high" ? "（ピン留めしなければ、時間が来ると自動で消えます）" : ""))
        }
        if !result.appRunning { parts.append("Makurip が動いていないので、次に起動したときに一覧に出ます") }
        let message = parts.joined(separator: "。") + "。"
        let structured: JSONValue = .object([
            "id": .string(result.id.uuidString),
            "result": .string(result.movedToTop ? "movedToTop" : "inserted"),
            "kind": .string(result.kind.rawValue), "kindLabel": .string(result.kind.label),
            "secret": .string(secret), "addedByAI": .bool(true), "pinned": .bool(result.pinned),
            "copiedToClipboard": .bool(result.copiedToClipboard), "appRunning": .bool(result.appRunning),
            "message": .string(message),
        ])
        return Output(structured: structured, summary: message)
    }

    private func list(_ filter: AIHistoryFilter, limit: Int) throws -> Output {
        let result = try gateway.list(filter, limit: limit)
        let message =
            "\(result.total) 件中、条件に合う \(result.matched) 件のうち新しい順に \(result.items.count) 件の形式の情報を返しました（中身は返しません）。"
        let structured: JSONValue = .object([
            "total": .int(result.total), "matched": .int(result.matched), "returned": .int(result.items.count),
            "items": .array(result.items), "message": .string(message),
        ])
        return Output(structured: structured, summary: message)
    }

    private func deleted(_ result: AIGateway.DeleteResult, what: String) -> Output {
        let message =
            result.dryRun
            ? "\(what)は \(result.count) 件です（dryRun なので消していません）。"
            : "\(what)を \(result.count) 件消しました。"
        let structured: JSONValue =
            result.dryRun
            ? .object(["dryRun": .bool(true), "wouldDelete": .int(result.count), "message": .string(message)])
            : .object(["deleted": .int(result.count), "message": .string(message)])
        return Output(structured: structured, summary: message)
    }

    // MARK: 設定の道具（#4 の CLI をそのまま通す）

    private func settingsSet(_ args: Arguments) throws -> Output {
        try args.only(["id", "value", "operation", "takeOver"])
        let id = try args.requiredString("id")
        try Self.refuseGate(id)
        guard let value = args.values["value"] else { throw AIToolError.invalid("value がありません。") }
        let operation = try args.string("operation") ?? "set"
        let takeOver = try args.bool("takeOver") ?? false
        var cli: [String]
        switch operation {
        case "set": cli = ["set", id] + Self.cliArguments(value)
        case "add", "remove":
            guard let text = value.stringValue else {
                throw AIToolError.invalid(
                    "operation が \(operation) のとき、value は文字列 1 つにしてください（例: com.apple.Safari・com.apple.Terminal=onCommit）。"
                )
            }
            cli = [operation, id, text]
        default:
            throw AIToolError.invalid("operation は set・add・remove のどれかにしてください。")
        }
        if takeOver { cli.append("--take-over") }
        let result = try settings(cli)
        let shown = result.objectValue?["value"]?.compactText ?? value.compactText
        return Output(structured: result, summary: "設定 \(id) を \(shown) にしました。")
    }

    private func settingsReset(_ args: Arguments) throws -> Output {
        try args.only(["ids", "all"])
        let ids = try args.stringArray("ids") ?? []
        let all = try args.bool("all") ?? false
        guard all != !ids.isEmpty else { throw AIToolError.invalid("ids（戻す項目の ID の並び）か all: true のどちらか一方を指定してください。") }
        for id in ids { try Self.refuseGate(id) }
        let result = try settings(all ? ["reset", "--all"] : ["reset"] + ids)
        return Output(
            structured: result, summary: all ? "すべての設定を既定に戻しました。" : "設定 \(ids.joined(separator: "・")) を既定に戻しました。")
    }

    /// 設定の CLI を `--json` で動かし、出力の JSON を返す。拒否されたら CLI の理由の文をそのまま返す
    private func settings(_ arguments: [String]) throws -> JSONValue {
        let output = settingsCLI.run(arguments + ["--json"])
        guard output.exitCode == SettingsCLI.ExitCode.ok else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            switch output.exitCode {
            case SettingsCLI.ExitCode.rejected: throw AIToolError(.settingsRejected, message)
            case SettingsCLI.ExitCode.io: throw AIToolError(.unavailable, message)
            default: throw AIToolError.invalid(message)
            }
        }
        guard let value = JSONValue.parse(output.stdout) else {
            throw AIToolError(.unavailable, "設定の CLI の出力を読めませんでした。")
        }
        return value
    }

    /// MCP の value（JSON）を設定の CLI の引数にする。並び・対応表は JSON の文字のまま渡す（CLI が JSON として読む）
    static func cliArguments(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .number(let number): [SettingsSchema.format(number)]
        case .bool(let flag): [flag ? "true" : "false"]
        case .null: ["none"]
        case .array, .object: [value.compactText]
        }
    }

    static func refuseGate(_ id: String) throws {
        if AIAccess.looksLikeGateID(id) { throw AIToolError(.settingsRejected, AIAccess.enableRefusedMessage) }
    }

    // MARK: 記録

    private func record(_ tool: Tool, _ result: Result<Output, AIToolError>) {
        guard let log else { return }
        let entry: AIActivityEntry
        switch result {
        case .success(let output):
            guard tool.logged else { return }
            entry = AIActivityEntry(
                at: now(), channel: channel, client: client, tool: tool.name, outcome: .ok, summary: output.summary)
        case .failure(let error):
            let refused = error.code == .aiAccessDisabled
            guard tool.logged || refused else { return }
            entry = AIActivityEntry(
                at: now(), channel: channel, client: client, tool: tool.name, outcome: refused ? .refused : .rejected,
                summary: refused ? "AI の口がオフなので断りました。" : error.message)
        }
        log.append(entry)
        activityDidChange()
    }
}

// MARK: - 引数の検証（純粋関数。MCP の arguments と CLI のフラグの両方がここを通る）

extension AITools {
    /// 道具の引数（JSON のオブジェクト）。知らない名前は誤りにする（AI の綴りの誤りを黙って無視しないため）
    struct Arguments {
        let values: [String: JSONValue]
        let tool: String

        init(_ values: [String: JSONValue], tool: Tool) {
            // null は「指定なし」と同じに扱う
            self.values = values.filter { $0.value != .null }
            self.tool = tool.name
        }

        func only(_ allowed: Set<String>) throws {
            let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
            guard unknown.isEmpty else {
                let hint = allowed.isEmpty ? "引数はありません" : "使える引数: \(allowed.sorted().joined(separator: "・"))"
                throw AIToolError.invalid("\(tool) に知らない引数があります: \(unknown.joined(separator: "・"))（\(hint)）。")
            }
        }

        func string(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            guard let text = value.stringValue else { throw AIToolError.invalid("\(key) は文字列にしてください。") }
            return text
        }

        func requiredString(_ key: String) throws -> String {
            guard let text = try string(key), !text.isEmpty else { throw AIToolError.invalid("\(key) がありません。") }
            return text
        }

        func bool(_ key: String) throws -> Bool? {
            guard let value = values[key] else { return nil }
            if let flag = value.boolValue { return flag }
            switch value.stringValue?.lowercased() {
            case "true": return true
            case "false": return false
            default: throw AIToolError.invalid("\(key) は true か false にしてください。")
            }
        }

        func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
            guard let value = values[key] else { return nil }
            guard let number = value.intValue ?? value.stringValue.flatMap({ Int($0) }), range.contains(number) else {
                throw AIToolError.invalid("\(key) は \(range.lowerBound)〜\(range.upperBound) の整数にしてください。")
            }
            return number
        }

        func stringArray(_ key: String) throws -> [String]? {
            guard let value = values[key] else { return nil }
            guard let array = value.arrayValue else { throw AIToolError.invalid("\(key) は文字列の並び（配列）にしてください。") }
            return try array.map { element in
                guard let text = element.stringValue else { throw AIToolError.invalid("\(key) の要素は文字列にしてください。") }
                return text
            }
        }

        func choice<T: RawRepresentable>(_ key: String, _ allowed: [T]) throws -> T? where T.RawValue == String {
            guard let text = try string(key) else { return nil }
            guard let found = allowed.first(where: { $0.rawValue == text }) else {
                throw AIToolError.invalid("\(key) は \(allowed.map(\.rawValue).joined(separator: "・")) のどれかにしてください。")
            }
            return found
        }
    }

    /// 期間（分）の範囲（1 分〜1 年）
    static let minutesRange = 1...525_600

    static func parseAdd(_ args: Arguments) throws -> AIAddRequest {
        try args.only(["text", "imagePath", "filePaths", "copyToClipboard", "pin"])
        let text = try args.string("text")
        let image = try args.string("imagePath")
        let files = try args.stringArray("filePaths")
        let given = [text != nil, image != nil, files != nil].filter { $0 }.count
        guard given == 1 else { throw AIToolError.invalid("text・imagePath・filePaths のどれか 1 つだけを指定してください。") }
        let content: AIAddRequest.Content =
            if let text { .text(text) } else if let image { .image(path: image) } else { .files(files ?? []) }
        return AIAddRequest(
            content: content, copyToClipboard: try args.bool("copyToClipboard") ?? false,
            pin: try args.bool("pin") ?? false)
    }

    static func parseFilter(_ args: Arguments) throws -> AIHistoryFilter {
        var filter = AIHistoryFilter()
        filter.kind = try args.choice("kind", ClipKind.allCases)
        filter.secret = try args.choice("secret", AISecretFilter.allCases)
        filter.addedByAI = try args.bool("addedByAI")
        filter.withinMinutes = try args.int("withinMinutes", in: minutesRange)
        filter.olderThanMinutes = try args.int("olderThanMinutes", in: minutesRange)
        if let app = try args.string("sourceApp") {
            guard !app.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AIToolError.invalid("sourceApp が空です。")
            }
            filter.sourceApp = app
        }
        return filter
    }

    static func parseList(_ args: Arguments) throws -> (AIHistoryFilter, Int) {
        try args.only([
            "limit", "kind", "secret", "addedByAI", "pinned", "withinMinutes", "olderThanMinutes", "sourceApp",
        ])
        var filter = try parseFilter(args)
        filter.pinned = try args.bool("pinned")
        let limit = try args.int("limit", in: 1...AIGateway.maxListLimit) ?? AIGateway.defaultListLimit
        return (filter, limit)
    }

    struct DeleteSecretsRequest: Equatable {
        var confidence: AISecretFilter
        var withinMinutes: Int?
        var includePinned: Bool
        var dryRun: Bool
    }

    static func parseDeleteSecrets(_ args: Arguments) throws -> DeleteSecretsRequest {
        try args.only(["confidence", "withinMinutes", "includePinned", "dryRun"])
        return DeleteSecretsRequest(
            confidence: try args.choice("confidence", [AISecretFilter.high, .any]) ?? .high,
            withinMinutes: try args.int("withinMinutes", in: minutesRange),
            includePinned: try args.bool("includePinned") ?? false, dryRun: try args.bool("dryRun") ?? false)
    }

    struct DeleteRequest: Equatable {
        var filter: AIHistoryFilter
        var includePinned: Bool
        var dryRun: Bool
    }

    static func parseDelete(_ args: Arguments) throws -> DeleteRequest {
        try args.only([
            "ids", "kind", "secret", "addedByAI", "withinMinutes", "olderThanMinutes", "sourceApp", "includePinned",
            "dryRun",
        ])
        var filter = try parseFilter(args)
        if let ids = try args.stringArray("ids") {
            guard !ids.isEmpty else { throw AIToolError.invalid("ids が空です。") }
            guard ids.count <= 1000 else { throw AIToolError.invalid("ids は 1000 個までです。") }
            filter.ids = try ids.map { text in
                guard let id = UUID(uuidString: text) else {
                    throw AIToolError.invalid("ids の要素は list_history が返した id（UUID）にしてください。")
                }
                return id
            }
        }
        guard filter.hasCondition else {
            throw AIToolError.invalid(
                "消す条件を 1 つ以上指定してください（ids・kind・secret・addedByAI・withinMinutes・olderThanMinutes・sourceApp）。")
        }
        return DeleteRequest(
            filter: filter, includePinned: try args.bool("includePinned") ?? false,
            dryRun: try args.bool("dryRun") ?? false)
    }
}

// MARK: - 道具の一覧（MCP の tools/list。説明は AI が読んで使い分けられるように書く）

extension AITools {
    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }

    static func property(_ type: String, _ description: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["type": .string(type), "description": .string(description)]) { $1 })
    }

    static func enumProperty(_ values: [String], _ description: String) -> JSONValue {
        property("string", description, extra: ["enum": .array(values.map(JSONValue.string))])
    }

    static let kindDescription =
        "種類: " + ClipKind.allCases.map { "\($0.rawValue)（\($0.label)）" }.joined(separator: "・")

    static let secretDescription =
        "秘密での絞り込み: any（秘密っぽいものすべて）・high（確度「高」= 既知の形式の API キー・トークン・秘密鍵・パスワードの代入など）・medium（確度「中」= ランダムな文字列だけ）・none（秘密でないもの）"

    static let filterProperties: [String: JSONValue] = [
        "kind": enumProperty(ClipKind.allCases.map(\.rawValue), kindDescription),
        "secret": enumProperty(AISecretFilter.allCases.map(\.rawValue), secretDescription),
        "addedByAI": property("boolean", "true なら AI が追加したものだけ、false ならそれ以外（AI の追加は、人がコピーした同じ内容とは別の項目になる）"),
        "withinMinutes": property(
            "integer", "最後にコピー・使ってからこの分数以内のもの（「さっきの」なら 10〜30 くらい）",
            extra: ["minimum": .int(1), "maximum": .int(525_600)]),
        "olderThanMinutes": property(
            "integer", "最後にコピー・使ってからこの分数より前のもの", extra: ["minimum": .int(1), "maximum": .int(525_600)]),
        "sourceApp": property("string", "コピー元アプリ（バンドル ID か名前の一部。AI が追加したものの名前は「AI（…）」）"),
    ]

    static let historyTools: [Tool] = [
        Tool(
            name: Name.status, title: "Makurip の AI の口の状態",
            description:
                "Makurip（Mac のクリップボード履歴アプリ）の AI の口がオンか、アプリが動いているか。履歴の道具はオンのときだけ使える。オンにできるのはユーザーだけ（Makurip の設定画面）。オフなら、その旨をユーザーに伝える。",
            inputSchema: schema([:]), needsAccess: false, readOnly: true, destructive: false, logged: false),
        Tool(
            name: Name.add, title: "履歴に追加",
            description:
                "Makurip のクリップボード履歴に 1 件追加する（例:「このコマンドを履歴に入れておいて」）。text・imagePath（画像ファイルの絶対パス）・filePaths（ファイルの参照。Finder でコピーしたのと同じ形）のどれか 1 つ。種類（コード・コマンド・URL など）と秘密っぽいかは Makurip が形式から判定する。秘密っぽい形式なら一覧で伏せ字になり、確度「高」は時間が来ると自動で消える。copyToClipboard: true でクリップボードにも置く（既定は置かない）。人がコピーした項目に同じ内容があっても合流せず、別の項目として足す（AI が前に足した同じ内容なら先頭へ移す）。返すのは id と形式の情報だけ。AI の口がオンのときだけ使える。",
            inputSchema: schema([
                "text": property("string", "履歴に入れる文字（50 MB まで）"),
                "imagePath": property("string", "画像ファイルの絶対パス（png・jpeg・tiff・gif・heic・webp・bmp・pdf）"),
                "filePaths": property(
                    "array", "ファイル・フォルダの絶対パスの並び（100 個まで。中身は読まず、参照を入れる）",
                    extra: ["items": .object(["type": .string("string")])]),
                "copyToClipboard": property("boolean", "クリップボードにも置く（既定 false）"),
                "pin": property("boolean", "ピン留めする（既定 false。ピン留めは上限や自動消去で消えない）"),
            ]), needsAccess: true, readOnly: false, destructive: false, logged: true),
        Tool(
            name: Name.list, title: "履歴の形式の一覧",
            description:
                "Makurip の履歴を新しい順に、形式の情報だけで返す（id・時刻・種類・コピー元アプリ・コピー方法・型名・大きさ・言語・ピン留め・秘密の印と形式名）。中身・プレビュー・コピー元の URL（ホスト名だけは返す）・ファイル名・パスは返さない。秘密っぽいものは大きさも返さない。消す前に、どれを消すかを決めるのに使う。AI の口がオンのときだけ使える。",
            inputSchema: schema(
                filterProperties.merging([
                    "limit": property(
                        "integer", "返す件数（既定 20・最大 200）", extra: ["minimum": .int(1), "maximum": .int(200)]),
                    "pinned": property("boolean", "true ならピン留めだけ、false ならピン留め以外"),
                ]) { $1 }), needsAccess: true, readOnly: true, destructive: false, logged: true),
        Tool(
            name: Name.deleteSecrets, title: "秘密っぽいものを消す",
            description:
                "Makurip の履歴から、API キー・トークン・秘密鍵・パスワードなど秘密っぽいもの（Makurip が形式だけで判定したもの）を消す（例:「さっきの API キーを履歴から消して」→ withinMinutes: 30）。confidence: high（既定。既知の形式だけ）か any（ランダムな文字列も）。ピン留めは includePinned: true のときだけ消す。dryRun: true なら数えるだけ。返すのは件数だけ。消したものは元に戻せない。システムのクリップボードそのものは消さない。AI の口がオンのときだけ使える。",
            inputSchema: schema([
                "confidence": enumProperty(["high", "any"], "high（既定）: 確度「高」だけ。any: 確度「中」（ランダムな文字列）も"),
                "withinMinutes": filterProperties["withinMinutes"] ?? .null,
                "includePinned": property("boolean", "ピン留めした秘密も消す（既定 false）"),
                "dryRun": property("boolean", "消さずに件数だけ返す（既定 false）"),
            ]), needsAccess: true, readOnly: false, destructive: true, logged: true),
        Tool(
            name: Name.delete, title: "条件で履歴を消す",
            description:
                "Makurip の履歴から、条件に合うものを消す（例:「AI が入れたものを消して」→ addedByAI: true、「1 時間以内の画像を消して」→ kind: image, withinMinutes: 60）。条件（ids・kind・secret・addedByAI・withinMinutes・olderThanMinutes・sourceApp）は 1 つ以上必要で、すべてに合うものを消す。ids は list_history が返した id。ピン留めは includePinned: true のときだけ消す。dryRun: true なら数えるだけ。返すのは件数だけ。消したものは元に戻せないので、迷ったら dryRun で数えてユーザーに確かめる。AI の口がオンのときだけ使える。",
            inputSchema: schema(
                filterProperties.merging([
                    "ids": property(
                        "array", "消す項目の id（list_history の id）の並び",
                        extra: ["items": .object(["type": .string("string")])]),
                    "includePinned": property("boolean", "ピン留めしたものも消す（既定 false）"),
                    "dryRun": property("boolean", "消さずに件数だけ返す（既定 false）"),
                ]) { $1 }), needsAccess: true, readOnly: false, destructive: true, logged: true),
    ]

    /// 一覧の順（tools/list）: 状態 → 履歴 → 定型文 → 設定
    public static let tools: [Tool] = historyTools + snippetTools + settingsTools

    static let settingsTools: [Tool] = [
        Tool(
            name: Name.settingsSchema, title: "設定項目の一覧",
            description:
                "Makurip の設定項目の一覧（ID・型・既定値・いまの値・取りうる値・説明・頼みの例）。「候補窓は出さないで」のような頼みを、label・description・examples から項目と値に結びつけるときにまず読む。設定に秘密は入っていない。AI の口がオフでも読める（変える settings_set・settings_reset はオンのときだけ）。",
            inputSchema: schema([:]), needsAccess: false, readOnly: true, destructive: false, logged: false),
        Tool(
            name: Name.settingsList, title: "いまの設定",
            description: "Makurip のいまの設定の値（changed は既定から変えた項目）・キーの重なり・設定ファイルの読めなかった項目。AI の口がオフでも読める。",
            inputSchema: schema([:]), needsAccess: false, readOnly: true, destructive: false, logged: false),
        Tool(
            name: Name.settingsGet, title: "設定の値",
            description: "Makurip の設定 1 つの値。AI の口がオフでも読める。",
            inputSchema: schema(
                ["id": property("string", "設定項目の ID（settings_schema の id。例: hotkeyMode・keys.open）")], required: ["id"]),
            needsAccess: false, readOnly: true, destructive: false, logged: false),
        Tool(
            name: Name.settingsSet, title: "設定を変える",
            description:
                "Makurip の設定を変える（例:「候補窓は出さないで」→ id: hotkeyMode, value: paste。「呼び出しを ⌥V にして」→ id: keys.open, value: ⌥V。「Safari のコピーは残さないで」→ id: excludedApps, operation: add, value: com.apple.Safari）。設定画面と同じ検証を通し、通らなければ理由を返すので、理由を読んで値を直すかユーザーに確かめる。動いている Makurip にすぐ効く。上限（maxItems・maxTotalMB）を下げると、超えた分の履歴（ピン留め以外）がすぐに消え、元に戻せない。記録しないアプリ（excludedApps）から外すとそのアプリのコピーも記録され、secretAutoDeleteMinutes を延ばすと秘密が長く残る。こうした変更は、ユーザーが頼んだときだけ行う。AI の口のオン・オフはここでは変えられない（設定画面からだけ）。AI の口がオンのときだけ使える。",
            inputSchema: schema(
                [
                    "id": property("string", "設定項目の ID（settings_schema の id）"),
                    "value": .object([
                        "description": .string(
                            "値。選択肢・数・true/false は文字か数、キーは「⌥V」のような文字か文字の並び、並び・アプリごとの項目は配列・オブジェクト。operation が add・remove のときは文字 1 つ（例: com.apple.Terminal=onCommit）。null で空にする"
                        )
                    ]),
                    "operation": enumProperty(
                        ["set", "add", "remove"], "set（既定。置き換える）・add・remove（並び・アプリごとの項目・キーに 1 つ足す / 外す）"),
                    "takeOver": property("boolean", "キーが他の操作と重なったら、その操作から外して付け替える（既定 false = 拒否する）"),
                ], required: ["id", "value"]), needsAccess: true, readOnly: false, destructive: true, logged: true),
        Tool(
            name: Name.settingsReset, title: "設定を既定に戻す",
            description:
                "Makurip の設定を既定に戻す。ids（項目の ID の並び）か all: true のどちらか。上限を既定より上げていた項目を戻すと、超えた分の履歴（ピン留め以外）がすぐに消え、元に戻せない。記録しないアプリの一覧も既定に戻る。ユーザーが頼んだときだけ行う。AI の口がオンのときだけ使える。",
            inputSchema: schema([
                "ids": property("array", "既定に戻す項目の ID の並び", extra: ["items": .object(["type": .string("string")])]),
                "all": property("boolean", "すべての設定を既定に戻す"),
            ]), needsAccess: true, readOnly: false, destructive: true, logged: true),
    ]
}

import Foundation

/// AI の口の CLI（`Makurip --ai <命令> ...`）。MCP と同じ道具（`AITools`）を、フラグを同じ引数に組み直して呼ぶ
/// （検証も出力の JSON も MCP と同じ）。設定は #4 の `--settings` をそのまま使う。
///
/// AI の口をオンにする命令はない（設定画面からだけ）。`disable` でオフにはできる
@MainActor
public struct AICLI {
    public typealias Output = SettingsCLI.Output

    public enum ExitCode {
        public static let ok: Int32 = 0
        public static let usage: Int32 = 1
        /// 入力・設定の値が検証に通らない
        public static let rejected: Int32 = 2
        /// DB・ファイルを読み書きできない
        public static let unavailable: Int32 = 3
        /// AI の口がオフ
        public static let disabled: Int32 = 4
    }

    public let tools: AITools
    /// 使い方に出すコマンド
    public let command: String
    /// `--stdin` で読む標準入力
    public let readStandardInput: () -> String?

    public init(tools: AITools, command: String = "Makurip --ai", readStandardInput: @escaping () -> String? = { nil })
    {
        self.tools = tools
        self.command = command
        self.readStandardInput = readStandardInput
    }

    /// フラグの形
    enum Flag {
        /// 値を 1 つとる（文字のまま渡す。数は道具の側で読む）
        case value(String)
        /// 値を何度でもとる（並び）
        case list(String)
        /// 付ければ true
        case on(String)
        /// 付ければ false
        case off(String)
        /// 標準入力を読んで文字にする
        case stdin(String)
    }

    /// 命令 → 道具の名前とフラグ
    static let commands: [String: (tool: String, flags: [String: Flag])] = {
        let filter: [String: Flag] = [
            "--kind": .value("kind"), "--secret": .value("secret"), "--ai-added": .on("addedByAI"),
            "--not-ai-added": .off("addedByAI"), "--within": .value("withinMinutes"),
            "--older-than": .value("olderThanMinutes"), "--app": .value("sourceApp"),
        ]
        return [
            "status": (AITools.Name.status, [:]),
            "add": (
                AITools.Name.add,
                [
                    "--text": .value("text"), "--stdin": .stdin("text"), "--image": .value("imagePath"),
                    "--file": .list("filePaths"), "--copy": .on("copyToClipboard"), "--pin": .on("pin"),
                ]
            ),
            "list": (
                AITools.Name.list,
                filter.merging(["--limit": .value("limit"), "--pinned": .on("pinned"), "--unpinned": .off("pinned")]) {
                    $1
                }
            ),
            "delete-secrets": (
                AITools.Name.deleteSecrets,
                [
                    "--confidence": .value("confidence"), "--within": .value("withinMinutes"),
                    "--include-pinned": .on("includePinned"), "--dry-run": .on("dryRun"),
                ]
            ),
            "delete": (
                AITools.Name.delete,
                filter.merging([
                    "--id": .list("ids"), "--include-pinned": .on("includePinned"), "--dry-run": .on("dryRun"),
                ]) { $1 }
            ),
            "snippet-add": (
                AITools.Name.addSnippet,
                [
                    "--body": .value("body"), "--stdin": .stdin("body"), "--name": .value("name"),
                    "--abbr": .value("abbreviation"),
                ]
            ),
            "snippets": (AITools.Name.listSnippets, ["--limit": .value("limit")]),
            "snippet-delete": (AITools.Name.deleteSnippets, ["--id": .list("ids")]),
        ]
    }()

    public func run(_ arguments: [String]) -> Output {
        var args = arguments
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        guard let verb = args.first else { return Output(stderr: usageText, exitCode: ExitCode.usage) }
        let rest = Array(args.dropFirst())
        switch verb {
        case "help", "-h", "--help": return Output(stdout: usageText)
        case "enable", "on":
            return Output(stderr: AIAccess.enableRefusedMessage + "\n", exitCode: ExitCode.rejected)
        case "disable", "off":
            guard rest.isEmpty else { return Output(stderr: "使い方: \(command) disable\n", exitCode: ExitCode.usage) }
            do {
                try tools.gateway.disable()
            } catch {
                return Output(stderr: "オフにできませんでした（DB に書けない）。\n", exitCode: ExitCode.unavailable)
            }
            return Output(stdout: json ? #"{"aiAccess":"off"}"# + "\n" : "AI の口をオフにしました。もう一度オンにするのは設定画面からです。\n")
        case "log":
            return log(rest, json: json)
        default:
            guard let entry = Self.commands[verb] else {
                return Output(stderr: "知らない命令: \(verb)\n\n" + usageText, exitCode: ExitCode.usage)
            }
            let parsed: [String: JSONValue]
            switch Self.parse(rest, flags: entry.flags, stdin: readStandardInput) {
            case .success(let value): parsed = value
            case .failure(let error): return Output(stderr: error.message + "\n", exitCode: ExitCode.usage)
            }
            return render(verb, tools.call(entry.tool, arguments: parsed), json: json)
        }
    }

    /// フラグを道具の引数（JSON）にする。知らないフラグ・値のないフラグは使い方の誤り
    static func parse(_ args: [String], flags: [String: Flag], stdin: () -> String?) -> Result<
        [String: JSONValue], CLIUsageError
    > {
        var result: [String: JSONValue] = [:]
        var index = 0
        while index < args.count {
            let name = args[index]
            guard let flag = flags[name] else {
                let known = flags.keys.sorted().joined(separator: " ")
                return .failure(CLIUsageError("知らない引数: \(name)（使える: \(known.isEmpty ? "なし" : known)）"))
            }
            switch flag {
            case .value(let key), .list(let key):
                guard index + 1 < args.count else { return .failure(CLIUsageError("\(name) の値がない")) }
                let value = args[index + 1]
                index += 1
                if case .list = flag {
                    result[key] = .array((result[key]?.arrayValue ?? []) + [.string(value)])
                } else {
                    result[key] = .string(value)
                }
            case .on(let key): result[key] = .bool(true)
            case .off(let key): result[key] = .bool(false)
            case .stdin(let key):
                guard let text = stdin() else { return .failure(CLIUsageError("標準入力を読めない")) }
                result[key] = .string(text)
            }
            index += 1
        }
        return .success(result)
    }

    struct CLIUsageError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func render(_ verb: String, _ result: Result<AITools.Output, AIToolError>, json: Bool) -> Output {
        switch result {
        case .success(let output):
            if json { return Output(stdout: SettingsCLI.pretty(output.structured)) }
            var lines = [output.summary]
            if verb == "list" || verb == "snippets" {
                lines += (output.structured.objectValue?["items"]?.arrayValue ?? []).map {
                    verb == "list" ? Self.historyLine($0) : Self.snippetLine($0)
                }
            }
            if verb == "status" {
                let object = output.structured.objectValue ?? [:]
                lines =
                    [
                        "AI の口: \(object["aiAccess"]?.stringValue == "on" ? "オン" : "オフ")",
                        "Makurip: \(object["appRunning"]?.boolValue == true ? "動いている" : "動いていない")",
                    ] + (object["itemCount"]?.intValue.map { ["履歴: \($0) 件"] } ?? []) + [output.summary]
            }
            return Output(stdout: lines.joined(separator: "\n") + "\n")
        case .failure(let error):
            let code: Int32 =
                switch error.code {
                case .aiAccessDisabled: ExitCode.disabled
                case .invalidArguments, .settingsRejected: ExitCode.rejected
                case .unknownTool: ExitCode.usage
                case .unavailable: ExitCode.unavailable
                }
            if json {
                let body: JSONValue = .object([
                    "error": .string(error.code.rawValue), "message": .string(error.message),
                ])
                return Output(stdout: SettingsCLI.pretty(body), stderr: error.message + "\n", exitCode: code)
            }
            return Output(stderr: error.message + "\n", exitCode: code)
        }
    }

    /// 一覧の 1 行（形式の情報だけ）
    static func historyLine(_ item: JSONValue) -> String {
        let object = item.objectValue ?? [:]
        var marks: [String] = []
        if object["addedByAI"]?.boolValue == true { marks.append("AI") }
        if object["pinned"]?.boolValue == true { marks.append("ピン") }
        if let level = object["secret"]?.objectValue?["level"]?.stringValue {
            marks.append(level == "high" ? "秘密:高" : "秘密:中")
        }
        let size =
            object["totalBytes"]?.intValue.map { "\($0) B" }
            ?? (object["size"]?.stringValue == "hidden" ? "大きさは伏せる" : "")
        let app =
            object["sourceApp"]?.objectValue?["name"]?.stringValue ?? object["sourceApp"]?.objectValue?["bundleID"]?
            .stringValue ?? "-"
        let language = object["languageLabel"]?.stringValue.map { "（\($0)）" } ?? ""
        return [
            object["id"]?.stringValue ?? "", object["lastUsedAt"]?.stringValue ?? "",
            (object["kindLabel"]?.stringValue ?? "") + language, app, size, marks.map { "[\($0)]" }.joined(),
        ].joined(separator: "  ")
    }

    static func snippetLine(_ item: JSONValue) -> String {
        let object = item.objectValue ?? [:]
        let abbreviation = object["abbreviation"]?.stringValue.map { "（\($0)）" } ?? ""
        return [
            object["id"]?.stringValue ?? "", (object["name"]?.stringValue ?? "（名前なし）") + abbreviation,
            "\(object["characters"]?.intValue ?? 0) 文字",
        ].joined(separator: "  ")
    }

    private func log(_ args: [String], json: Bool) -> Output {
        var limit = 20
        if !args.isEmpty {
            guard args.count == 2, args[0] == "--limit", let value = Int(args[1]),
                (1...AIActivityLog.maxEntries).contains(value)
            else {
                return Output(
                    stderr: "使い方: \(command) log [--limit 1〜\(AIActivityLog.maxEntries)]\n", exitCode: ExitCode.usage)
            }
            limit = value
        }
        let entries = tools.log?.recent(limit: limit) ?? []
        if json {
            let data = (try? AIActivityLog.encoder.encode(entries)).flatMap {
                JSONValue.parse(String(decoding: $0, as: UTF8.self))
            }
            return Output(stdout: SettingsCLI.pretty(data ?? .array([])))
        }
        guard !entries.isEmpty else { return Output(stdout: "AI の操作の記録はまだありません。\n") }
        let formatter = ISO8601DateFormatter()
        let lines = entries.map { entry in
            let who = [entry.channel.rawValue, entry.client].compactMap { $0 }.joined(separator: "・")
            return
                "\(formatter.string(from: entry.at))  \(who)  \(entry.tool)  \(entry.outcome.rawValue)  \(entry.summary)"
        }
        return Output(stdout: lines.joined(separator: "\n") + "\n")
    }

    public var usageText: String {
        """
        使い方: \(command) <命令> [--json]

        履歴と定型文の命令は、設定画面で「AI の口」をオンにしたときだけ使える（オンにする命令はない）。中身は出さない。
          status                         オンか・Makurip が動いているか
          add --text 文字 | --stdin | --image パス | --file パス...  [--copy] [--pin]
                                         履歴に 1 件足す（--copy でクリップボードにも置く）
          list [--limit N] [--kind 種類] [--secret any|high|medium|none] [--ai-added] [--pinned]
               [--within 分] [--older-than 分] [--app 名前]
                                         形式の情報の一覧（新しい順。中身・URL・ファイル名は出さない）
          delete-secrets [--confidence high|any] [--within 分] [--include-pinned] [--dry-run]
                                         秘密っぽいものを消す（件数だけ出す）
          delete [--id ID]... [--kind 種類] [--secret …] [--ai-added] [--within 分] [--older-than 分] [--app 名前]
                 [--include-pinned] [--dry-run]
                                         条件に合うものを消す（条件は 1 つ以上）
          snippet-add --body 文字 | --stdin  [--name 名前] [--abbr 略語]
                                         定型文を登録する
          snippets [--limit N]           定型文の名前と形式の一覧（本文は出さない）
          snippet-delete --id ID...      定型文を消す
          log [--limit N]                AI が行った操作の記録（メタデータだけ）
          disable                        AI の口をオフにする

        設定は Makurip --settings（AI の口のオン・オフに関係なく使える）。MCP は Makurip --mcp。
        終了コード: 0 成功・1 使い方の誤り・2 検証に通らない・3 読み書きできない・4 AI の口がオフ

        """
    }
}

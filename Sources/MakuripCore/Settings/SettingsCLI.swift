import Foundation

/// 設定の CLI（`Makurip --settings ...`）の本体。読み書きは `SettingsFile`、検証は `SettingsSchema` で、設定画面と同じ関数を通す。
///
/// 動いている Makurip は設定ファイルの変化を見て読み直すので、ここで書けばすぐに効く（別のプロセスに知らせる必要はない）。
/// 出力に履歴の中身は出さない（設定だけを扱う）
public struct SettingsCLI {
    public struct Output: Equatable, Sendable {
        public var stdout = ""
        public var stderr = ""
        public var exitCode: Int32 = 0
    }

    public enum ExitCode {
        public static let ok: Int32 = 0
        public static let usage: Int32 = 1
        /// 検証に通らなかった（理由は標準エラー）
        public static let rejected: Int32 = 2
        public static let io: Int32 = 3
    }

    public let file: SettingsFile
    /// そのまま実行できるコマンド（実行ファイルの完全なパス。`--json` の例のコマンドに使う）
    public let command: String
    /// 人が読む出力の例に使う短い名前（完全なパスは冒頭に 1 回だけ出す）
    public static let shortCommand = "Makurip --settings"
    /// バンドル ID のアプリが入っていれば名前（見つからなければ注意を出す）。nil なら見ない
    public let appName: ((String) -> String?)?

    public init(file: SettingsFile, command: String = "Makurip --settings", appName: ((String) -> String?)? = nil) {
        self.file = file
        self.command = command
        self.appName = appName
    }

    public func run(_ arguments: [String]) -> Output {
        var args = arguments
        let json = take("--json", from: &args)
        let takeOver = take("--take-over", from: &args)
        let all = take("--all", from: &args)
        guard let verb = args.first else { return usage(code: ExitCode.usage) }
        let rest = Array(args.dropFirst())
        switch verb {
        case "help", "-h", "--help": return usage(code: ExitCode.ok)
        case "schema": return schema(json: json)
        case "list": return list(json: json)
        case "path": return Output(stdout: file.url.path + "\n")
        case "get": return get(rest, json: json)
        case "set": return set(rest, takeOver: takeOver, json: json)
        case "add": return edit(rest, adding: true, takeOver: takeOver, json: json)
        case "remove": return edit(rest, adding: false, takeOver: takeOver, json: json)
        case "reset": return reset(rest, all: all, json: json)
        default:
            return Output(stderr: "知らない命令: \(verb)\n\n" + usageText, exitCode: ExitCode.usage)
        }
    }

    private func take(_ flag: String, from args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    // MARK: 使い方

    public var usageText: String {
        """
        使い方: \(command) <命令> [--json]

          schema            設定項目の一覧（ID・型・既定値・取りうる値・説明・頼みの例）。AI はまずこれを読む
          list              いまの値（* は既定から変えた項目）・キーの重なり・読めなかった項目
          get <ID>          1 つの値
          set <ID> <値>...  値を変える。キーは複数を空白で区切る（例: set keys.prev ↑ ⌃P）。none で空にする
          add <ID> <値>     並び・アプリごとの項目に 1 つ足す（例: add candPasteTiming com.tinyspeck.slackmacgap=onCommit）
          remove <ID> <値>  並び・アプリごとの項目から 1 つ外す（例: remove excludedApps com.apple.Safari）
          reset <ID>...     既定に戻す（--all ですべて）
          path              設定ファイルの場所

          --json            機械が読む形で出す
          --take-over       キーが他の操作と重なったら、その操作から外して付け替える（ないときは拒否する）

        検証に通らない値は、理由を付けて拒否する（終了コード 2）。動いている Makurip はファイルの変化を見て、すぐに反映する。

        """
    }

    private func usage(code: Int32) -> Output {
        code == ExitCode.ok ? Output(stdout: usageText) : Output(stderr: usageText, exitCode: code)
    }

    // MARK: schema・list・get

    /// AI 向けの案内（`schema` の先頭）
    public var guide: [String] {
        [
            "Makurip（クリップボード履歴アプリ）の設定項目の一覧。人と AI エージェントが読んで、自然言語の頼みから項目と値を選ぶためのもの。",
            "1. 頼みに当たる項目を label・description・examples から選ぶ。キーの割り当ては keys.<操作 ID>（例: keys.open は呼び出しキー）。",
            "2. 変える: \(command) set <ID> <値>。並び・アプリごとの項目は add / remove。examples の command はそのまま実行できる。",
            "3. 検証に通らない値は理由付きで拒否される（終了コード 2）。理由を読んで値を直すか、ユーザーに確かめる。",
            "4. 動いている Makurip は設定ファイルの変化を見て、すぐに反映する（再起動は要らない）。いまの値は \(command) list で見る。",
            "設定に秘密は入っていない。履歴の中身はこの CLI では見られない。設定ファイルは直接書き換えず、この CLI を使う（検証を通すため）。",
        ]
    }

    private func schema(json: Bool) -> Output {
        let settings = file.load().settings
        if json {
            let root: JSONValue = .object([
                "guide": .array(guide.map(JSONValue.string)),
                "command": .string(command),
                "settingsFile": .string(file.url.path),
                "keyFormat": .string(Self.keyFormat),
                "items": .array(SettingsSchema.items.map { itemJSON($0, settings: settings) }),
            ])
            return Output(stdout: Self.pretty(root))
        }
        var lines =
            guide + [
                "", "キーの書き方: \(Self.keyFormat)", "設定ファイル: \(file.url.path)",
                "下の例の「\(Self.shortCommand)」は、このコマンドのこと: \(command)",
            ]
        var group = ""
        for item in SettingsSchema.items {
            let heading = item.section == .keys ? "キー割り当て・\(item.group)" : item.group
            if heading != group {
                group = heading
                lines += ["", "## \(heading)"]
            }
            lines += itemText(item, settings: settings)
        }
        return Output(stdout: lines.joined(separator: "\n") + "\n")
    }

    static let keyFormat =
        "⌃⌘V・⌥V・⇧↩・esc・⌘1–9 のように書く。修飾キーは ⌃⌥⇧⌘ の記号か ctrl+・opt+・shift+・cmd+（例: ctrl+cmd+v）。特殊キーは ↩ ⇥ esc space ⌫ ↑ ↓ ← → F1〜F20"

    private func itemJSON(_ item: SettingItem, settings: AppSettings) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id), "section": .string(item.section.rawValue), "group": .string(item.group),
            "label": .string(item.label), "description": .string(item.summary), "type": .string(item.kind.typeName),
            "default": SettingsSchema.defaultValue(item.id) ?? .null,
            "current": SettingsSchema.value(item.id, in: settings) ?? .null,
            "advanced": .bool(item.advanced), "shownInSettingsWindow": .bool(item.shownInWindow),
        ]
        if !item.choices.isEmpty {
            object["choices"] = .array(
                item.choices.map {
                    .object([
                        "value": .string($0.value), "label": .string($0.label), "description": .string($0.summary),
                    ])
                })
        }
        switch item.kind {
        case .integer(let min, let max, let step, let unit):
            object["min"] = .int(min)
            object["max"] = .int(max)
            object["step"] = .int(step)
            object["unit"] = .string(unit)
        case .number(let min, let max, let step, let unit):
            object["min"] = .number(min)
            object["max"] = .number(max)
            object["step"] = .number(step)
            object["unit"] = .string(unit)
        case .keys(let action):
            object["keyScope"] = .string(action.scope.rawValue)
        default:
            break
        }
        if !item.builtIn.isEmpty {
            object["builtIn"] = .array(
                item.builtIn.map {
                    .object(["bundleID": .string($0.bundleID), "name": .string($0.name), "value": .string($0.value)])
                })
        }
        if !item.examples.isEmpty {
            object["examples"] = .array(
                item.examples.map { example in
                    var entry: [String: JSONValue] = [
                        "request": .string(example.request), "value": example.value,
                        "command": .string(exampleCommand(item, example.value)),
                    ]
                    if let note = example.note { entry["note"] = .string(note) }
                    return .object(entry)
                })
        }
        return .object(object)
    }

    private func itemText(_ item: SettingItem, settings: AppSettings) -> [String] {
        var lines = ["", "\(item.id) — \(item.label)\(item.advanced ? "（詳細）" : "")"]
        lines.append("  説明: \(item.summary)")
        let defaultText = SettingsSchema.defaultValue(item.id).map { cliText($0, item) } ?? ""
        let currentText = SettingsSchema.value(item.id, in: settings).map { cliText($0, item) } ?? ""
        lines.append(
            "  型: \(Self.typeText(item.kind))　既定: \(defaultText.isEmpty ? "（なし）" : defaultText)　いま: \(currentText.isEmpty ? "（なし）" : currentText)"
        )
        for choice in item.choices {
            lines.append("  - \(choice.value)（\(choice.label)）: \(choice.summary)")
        }
        if !item.builtIn.isEmpty {
            lines.append(
                "  既定で \(item.builtIn.first?.value ?? "") のアプリ: "
                    + item.builtIn.map { "\($0.name)=\($0.bundleID)" }.joined(separator: "・"))
        }
        for example in item.examples {
            let note = example.note.map { "（\($0)）" } ?? ""
            lines.append("  例: 「\(example.request)」→ \(exampleCommand(item, example.value, short: true))\(note)")
        }
        return lines
    }

    static func typeText(_ kind: SettingItem.Kind) -> String {
        switch kind {
        case .choice: "選択肢"
        case .toggle: "オン・オフ（true / false）"
        case .integer(let min, let max, _, let unit): "整数 \(min)〜\(max) \(unit)"
        case .number(let min, let max, _, let unit):
            "数 \(SettingsSchema.format(min))〜\(SettingsSchema.format(max)) \(unit)"
        case .appList: "バンドル ID の並び（add / remove で 1 つずつ）"
        case .appMap: "バンドル ID ごとの値（add <バンドル ID>=<値> / remove <バンドル ID>）"
        case .keys(let action):
            switch action.scope {
            case .global: "キー（どこからでも効く。1 つだけ）"
            case .panel: "キー（一覧の中。複数可）"
            case .candidate: "キー（候補窓の中。複数可）"
            }
        }
    }

    /// 頼みの例をそのまま実行できるコマンドにする（`short` は人が読む出力用の短い名前）
    private func exampleCommand(_ item: SettingItem, _ value: JSONValue, short: Bool = false) -> String {
        let command = short ? Self.shortCommand : command
        switch item.kind {
        case .appList:
            return (value.arrayValue ?? []).compactMap(\.stringValue).map { "\(command) add \(item.id) \($0)" }
                .joined(separator: " && ")
        case .appMap:
            return (value.objectValue ?? [:]).sorted { $0.key < $1.key }
                .map { "\(command) add \(item.id) \($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: " && ")
        default:
            return "\(command) set \(item.id) \(cliText(value, item))"
        }
    }

    private func list(json: Bool) -> Output {
        let contents = file.load()
        let conflicts = contents.settings.keymap.conflicts()
        if json {
            var values: [String: JSONValue] = [:]
            var changed: [JSONValue] = []
            for item in SettingsSchema.items {
                let value = SettingsSchema.value(item.id, in: contents.settings) ?? .null
                values[item.id] = value
                if value != SettingsSchema.defaultValue(item.id) { changed.append(.string(item.id)) }
            }
            let root: JSONValue = .object([
                "settingsFile": .string(file.url.path),
                "values": .object(values),
                "changed": .array(changed),
                "conflicts": .array(
                    conflicts.map {
                        .object([
                            "combo": .string($0.combo.displayString),
                            "ids": .array([.string(SettingID.keys($0.first)), .string(SettingID.keys($0.second))]),
                        ])
                    }),
                "issues": .array(
                    contents.issues.map { .object(["id": .string($0.id), "message": .string($0.message)]) }),
            ])
            return Output(stdout: Self.pretty(root))
        }
        var lines = ["設定ファイル: \(file.url.path)\(contents.exists ? "" : "（まだない。すべて既定）")", "（* は既定から変えた項目）"]
        var group = ""
        for item in SettingsSchema.items {
            let heading = item.section == .keys ? "キー割り当て・\(item.group)" : item.group
            if heading != group {
                group = heading
                lines += ["", "[\(heading)]"]
            }
            let value = SettingsSchema.value(item.id, in: contents.settings) ?? .null
            let mark = value != SettingsSchema.defaultValue(item.id) ? "*" : " "
            let text = cliText(value, item)
            lines.append("\(mark) \(item.id) = \(text.isEmpty ? "（なし）" : text)　\(item.label(in: contents.settings))")
        }
        if !conflicts.isEmpty {
            lines += ["", "キーの重なり（どちらかを変える）:"]
            lines += conflicts.map {
                "  \($0.combo.displayString): \(SettingID.keys($0.first))（\($0.first.label)）と \(SettingID.keys($0.second))（\($0.second.label)）"
            }
        }
        if !contents.issues.isEmpty {
            lines += ["", "設定ファイルの読めなかった項目:"]
            lines += contents.issues.map { "  \($0.id): \($0.message)" }
        }
        return Output(stdout: lines.joined(separator: "\n") + "\n")
    }

    private func get(_ args: [String], json: Bool) -> Output {
        guard args.count == 1 else { return Output(stderr: "使い方: \(command) get <ID>\n", exitCode: ExitCode.usage) }
        guard let item = SettingsSchema.item(args[0]) else { return unknownItem(args[0]) }
        let value = SettingsSchema.value(item.id, in: file.load().settings) ?? .null
        return Output(stdout: (json ? value.compactText : cliText(value, item)) + "\n")
    }

    // MARK: set・add・remove・reset

    private func set(_ args: [String], takeOver: Bool, json: Bool) -> Output {
        guard let id = args.first else {
            return Output(stderr: "使い方: \(command) set <ID> <値>...\n", exitCode: ExitCode.usage)
        }
        guard let item = SettingsSchema.item(id) else { return unknownItem(id) }
        let values = Array(args.dropFirst())
        guard !values.isEmpty else {
            return Output(stderr: "\(id) の値がない（空にするなら none）\n", exitCode: ExitCode.usage)
        }
        switch Self.cliValue(values, for: item) {
        case .success(let raw): return write(item, raw, takeOver: takeOver, json: json)
        case .failure(let error): return rejected(error)
        }
    }

    private func edit(_ args: [String], adding: Bool, takeOver: Bool, json: Bool) -> Output {
        let verb = adding ? "add" : "remove"
        guard args.count == 2 else {
            return Output(stderr: "使い方: \(command) \(verb) <ID> <値>\n", exitCode: ExitCode.usage)
        }
        guard let item = SettingsSchema.item(args[0]) else { return unknownItem(args[0]) }
        let current = SettingsSchema.value(item.id, in: file.load().settings) ?? .null
        let argument = args[1]
        let raw: JSONValue
        switch item.kind {
        case .appList:
            let list = (current.arrayValue ?? []).filter { $0.stringValue?.lowercased() != argument.lowercased() }
            raw = .array(adding ? list + [.string(argument)] : list)
        case .appMap:
            var map = current.objectValue ?? [:]
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard let bundleID = parts.first else {
                return rejected(SettingsError(id: item.id, message: "バンドル ID がない"))
            }
            if let key = map.keys.first(where: { $0.lowercased() == bundleID.lowercased() }) { map[key] = nil }
            if adding {
                guard parts.count == 2 else {
                    return rejected(
                        SettingsError(
                            id: item.id,
                            message: "「バンドル ID=値」で書く（例: com.apple.Terminal=\(item.choices.first?.value ?? "")）"))
                }
                map[bundleID] = .string(parts[1])
            }
            raw = .object(map)
        case .keys:
            let list = (current.arrayValue ?? []).filter { existing in
                guard case .success(let new) = KeyComboText.parse(argument),
                    case .success(let old) = KeyComboText.parse(existing.stringValue ?? "")
                else { return true }
                return old != new
            }
            raw = .array(adding ? list + [.string(argument)] : list)
        default:
            return rejected(SettingsError(id: item.id, message: "\(verb) は並び・アプリごとの項目・キーだけで使える（ほかは set）"))
        }
        return write(item, raw, takeOver: takeOver, json: json)
    }

    private func reset(_ args: [String], all: Bool, json: Bool) -> Output {
        let contents = file.load()
        var settings = contents.settings
        if all {
            settings = .default
        } else {
            guard !args.isEmpty else {
                return Output(stderr: "使い方: \(command) reset <ID>... か reset --all\n", exitCode: ExitCode.usage)
            }
            for id in args {
                guard SettingsSchema.item(id) != nil, let value = SettingsSchema.defaultValue(id) else {
                    return unknownItem(id)
                }
                if case .success(let change) = SettingsSchema.applying(
                    value, to: id, in: settings, keyConflicts: .allow)
                {
                    settings = change.settings
                }
            }
        }
        do {
            try file.save(settings, unknown: contents.unknown, backingUpBroken: contents.broken)
        } catch {
            return Output(stderr: "設定ファイルに書けなかった: \(error)\n", exitCode: ExitCode.io)
        }
        let what = all ? "すべての設定" : args.joined(separator: "・")
        if json {
            return Output(
                stdout: JSONValue.object(["reset": .array((all ? [] : args).map(JSONValue.string))]).compactText + "\n")
        }
        return Output(stdout: "\(what)を既定に戻しました。\(Self.liveNote)\n")
    }

    static let liveNote = "動いている Makurip は、設定ファイルの変化を見てすぐに反映します。"

    private func write(_ item: SettingItem, _ raw: JSONValue, takeOver: Bool, json: Bool) -> Output {
        let contents = file.load()
        let change: SettingChange
        switch SettingsSchema.applying(
            raw, to: item.id, in: contents.settings, keyConflicts: takeOver ? .takeOver : .reject)
        {
        case .success(let result): change = result
        case .failure(let error): return rejected(error)
        }
        do {
            try file.save(change.settings, unknown: contents.unknown, backingUpBroken: contents.broken)
        } catch {
            return Output(stderr: "設定ファイルに書けなかった: \(error)\n", exitCode: ExitCode.io)
        }
        var warnings: [String] = []
        if let appName {
            let ids: [String] =
                switch item.kind {
                case .appList: change.value.arrayValue?.compactMap(\.stringValue) ?? []
                case .appMap: change.value.objectValue.map { Array($0.keys) } ?? []
                default: []
                }
            for id in ids.sorted() where appName(id) == nil {
                warnings.append("注意: \(id) はこの Mac に見つからない（入れたら効く。綴りを確かめる）")
            }
        }
        if json {
            let root: JSONValue = .object([
                "id": .string(item.id), "value": change.value,
                "movedFrom": .array(change.movedFrom.map { .string(SettingID.keys($0)) }),
                "warnings": .array(warnings.map(JSONValue.string)),
            ])
            return Output(stdout: root.compactText + "\n", stderr: warnings.map { $0 + "\n" }.joined())
        }
        let text = humanText(change.value, item)
        var message = "\(item.id)（\(item.label(in: change.settings))）を「\(text.isEmpty ? "なし" : text)」にしました。"
        if !change.movedFrom.isEmpty {
            message += "重なっていた「" + change.movedFrom.map(\.label).joined(separator: "」「") + "」からは外しました。"
        }
        return Output(
            stdout: message + Self.liveNote + "\n", stderr: warnings.map { $0 + "\n" }.joined())
    }

    private func rejected(_ error: SettingsError) -> Output {
        Output(stderr: "変えられない（\(error.id)）: \(error.message)\n", exitCode: ExitCode.rejected)
    }

    private func unknownItem(_ id: String) -> Output {
        let near = SettingsSchema.items.map(\.id).filter {
            $0.lowercased().contains(id.lowercased()) || id.lowercased().contains($0.lowercased())
        }
        let hint = near.isEmpty ? "" : "（近いもの: \(near.prefix(5).joined(separator: "・"))）"
        return Output(
            stderr: "そういう設定項目はない: \(id)\(hint)。一覧は \(command) schema\n", exitCode: ExitCode.rejected)
    }

    // MARK: 値の文字表現

    /// CLI の引数を値にする（`[...]`・`{...}` なら JSON として読む）
    static func cliValue(_ values: [String], for item: SettingItem) -> Result<JSONValue, SettingsError> {
        if values.count == 1, let first = values[0].first, first == "[" || first == "{" {
            guard let parsed = JSONValue.parse(values[0]) else {
                return .failure(SettingsError(id: item.id, message: "JSON として読めない: \(values[0])"))
            }
            return .success(parsed)
        }
        let isNone = values.count == 1 && ["none", "", "なし"].contains(values[0].lowercased())
        switch item.kind {
        case .choice, .toggle, .integer, .number:
            guard values.count == 1 else {
                return .failure(SettingsError(id: item.id, message: "値は 1 つだけ（いま: \(values.joined(separator: " "))）"))
            }
            return .success(.string(values[0]))
        case .appList, .keys:
            return .success(.array(isNone ? [] : values.map(JSONValue.string)))
        case .appMap:
            if isNone { return .success(.object([:])) }
            var object: [String: JSONValue] = [:]
            for value in values {
                let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    return .failure(SettingsError(id: item.id, message: "「バンドル ID=値」で書く（いま: \(value)）"))
                }
                object[parts[0]] = .string(parts[1])
            }
            return .success(.object(object))
        }
    }

    /// CLI にそのまま渡せる形（get・list・例のコマンド）
    func cliText(_ value: JSONValue, _ item: SettingItem) -> String {
        switch item.kind {
        case .appList, .keys:
            return (value.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " ")
        case .appMap:
            return (value.objectValue ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: " ")
        case .toggle:
            return value.boolValue.map { $0 ? "true" : "false" } ?? value.compactText
        case .integer, .number:
            return value.doubleValue.map(SettingsSchema.format) ?? value.compactText
        case .choice:
            return value.stringValue ?? value.compactText
        }
    }

    /// 人が読む形（set の結果）
    func humanText(_ value: JSONValue, _ item: SettingItem) -> String {
        switch item.kind {
        case .choice(let choices):
            let raw = value.stringValue ?? ""
            return choices.first { $0.value == raw }.map { "\(raw)（\($0.label)）" } ?? raw
        case .toggle:
            return value.boolValue == true ? "オン" : "オフ"
        case .integer(_, _, _, let unit), .number(_, _, _, let unit):
            return "\(cliText(value, item)) \(unit)"
        case .keys:
            let text = cliText(value, item)
            return text.isEmpty ? "未設定" : text
        default:
            return cliText(value, item)
        }
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null") + "\n"
    }
}

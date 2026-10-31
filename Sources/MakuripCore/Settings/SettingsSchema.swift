import Foundation

/// 設定項目 1 つの説明。設定画面・CLI（`--settings schema`）・AI（#6 の MCP）が同じものを読む。
///
/// 説明文（`summary`）と頼みの例（`examples`）は「人と AI が読んで、どの頼みに当たるか分かる」ように書く。
/// 秘密は入らない（設定は AI が読み書きしてよい）。プライバシーを守る振る舞い（ConcealedType 等を保存しない）は項目にしない
public struct SettingItem: Sendable, Identifiable {
    public enum Section: String, Sendable, Codable {
        /// 動き（呼び出しキーの動き・上限・アプリごとの扱いなど）
        case behavior
        /// キー割り当て（`keys.<操作 ID>`）
        case keys
    }

    public enum Kind: Sendable, Equatable {
        /// 決まった値から 1 つ（文字列）
        case choice([SettingChoice])
        /// オン・オフ
        case toggle
        case integer(min: Int, max: Int, step: Int, unit: String)
        case number(min: Double, max: Double, step: Double, unit: String)
        /// アプリのバンドル ID の並び
        case appList
        /// アプリのバンドル ID → 決まった値
        case appMap([SettingChoice])
        /// 操作のキー（`KeyCombo` の並び）
        case keys(KeyAction)

        /// スキーマの JSON に出す型の名前
        public var typeName: String {
            switch self {
            case .choice: "choice"
            case .toggle: "bool"
            case .integer: "integer"
            case .number: "number"
            case .appList: "bundleIDList"
            case .appMap: "bundleIDMap"
            case .keys: "keys"
            }
        }
    }

    /// 自然言語の頼みと、それに当たる値の例
    public struct Example: Sendable, Equatable {
        public let request: String
        public let value: JSONValue
        /// 補足（すでに既定でそうなっている、など）
        public let note: String?

        public init(_ request: String, _ value: JSONValue, note: String? = nil) {
            self.request = request
            self.value = value
            self.note = note
        }
    }

    /// 項目に書いていなくても効く既定（確定まで貼らないアプリの一覧）
    public struct BuiltInEntry: Sendable, Equatable {
        public let bundleID: String
        public let name: String
        public let value: String
    }

    public let id: String
    public let section: Section
    /// 設定画面のまとまり（「動き」「履歴」・キーは操作のまとまり）
    public let group: String
    public let label: String
    public let summary: String
    public let kind: Kind
    public let examples: [Example]
    /// 「詳細」扱い（ふつうは触らなくてよい）
    public let advanced: Bool
    /// 設定画面に出すか（false は CLI と AI だけで変える）
    public let shownInWindow: Bool
    public let builtIn: [BuiltInEntry]

    init(
        id: String, section: Section = .behavior, group: String, label: String, summary: String, kind: Kind,
        examples: [Example] = [], advanced: Bool = false, shownInWindow: Bool = true, builtIn: [BuiltInEntry] = []
    ) {
        self.id = id
        self.section = section
        self.group = group
        self.label = label
        self.summary = summary
        self.kind = kind
        self.examples = examples
        self.advanced = advanced
        self.shownInWindow = shownInWindow
        self.builtIn = builtIn
    }

    /// 画面に出す名前（呼び出しキーの動きは、いまのキーを入れる。試作と同じ「呼び出しキー（⌃⌘V）の動き」）
    public func label(in settings: AppSettings) -> String {
        guard id == SettingID.hotKeyMode else { return label }
        let key = settings.keymap.primary(.openHistory)?.displayString ?? "未設定"
        return "呼び出しキー（\(key)）の動き"
    }

    public var keyAction: KeyAction? {
        if case .keys(let action) = kind { return action }
        return nil
    }

    public var choices: [SettingChoice] {
        switch kind {
        case .choice(let choices), .appMap(let choices): choices
        default: []
        }
    }
}

public struct SettingChoice: Sendable, Equatable {
    public let value: String
    public let label: String
    public let summary: String

    public init(_ value: String, _ label: String, _ summary: String) {
        self.value = value
        self.label = label
        self.summary = summary
    }
}

/// 項目の ID。候補窓の 5 つは UserDefaults の時代のキー（`CandidateSettings.Key`）と同じ名前にしてある
public enum SettingID {
    public static let hotKeyMode = CandidateSettings.Key.hotKeyMode
    public static let candidateOrder = CandidateSettings.Key.order
    public static let launchAtLogin = "launchAtLogin"
    public static let maxItems = "maxItems"
    public static let maxTotalMegabytes = "maxTotalMB"
    public static let excludedApps = "excludedApps"
    public static let pasteTiming = CandidateSettings.Key.pasteTiming
    public static let idleTimeout = CandidateSettings.Key.idleTimeout
    public static let replaceMethod = CandidateSettings.Key.replaceMethod
    public static let snippetDateFormat = "snippetDateFormat"
    public static let keyPrefix = "keys."

    public static func keys(_ action: KeyAction) -> String { keyPrefix + action.rawValue }
}

/// 検証に通らなかった理由（人と AI が読んで直せる文）
public struct SettingsError: Error, Equatable, Sendable, CustomStringConvertible {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }

    public var description: String { "\(id): \(message)" }
}

/// キーが他の操作と重なったときの扱い
public enum KeyConflictPolicy: Sendable {
    /// 拒否する（CLI の既定。どちらを外すかは人か AI が決める）
    case reject
    /// 重なった操作から外して付け替える（設定画面の記録。試作と同じ）
    case takeOver
    /// そのまま入れる（ファイルから読むとき。重なりは画面と `list` に出す）
    case allow
}

/// 値を入れた結果
public struct SettingChange: Sendable {
    public var settings: AppSettings
    /// 正規化した値（ファイルに書く形）
    public var value: JSONValue
    /// キーを付け替えたときに外した操作
    public var movedFrom: [KeyAction]
}

/// 設定項目の一覧（スキーマ）と、値の読み書き・検証。**検証はここの 1 か所だけ**で行い、画面・CLI・ファイルの読み込みが同じ関数を通す
public enum SettingsSchema {
    public static let behaviorGroups = ["動き", "履歴", "定型文", "アプリごと", "詳細"]

    public static let items: [SettingItem] = behaviorItems + KeyAction.allCases.map(keyItem)

    private static let byID: [String: SettingItem] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    public static func item(_ id: String) -> SettingItem? { byID[id] }

    static let pasteTimingChoices = [
        SettingChoice("immediate", "すぐ貼る", "↑↓ で選んでいる間も、文書に仮に貼って差し替える。"),
        SettingChoice("onCommit", "確定まで貼らない", "↑↓ の間は候補窓で見せるだけにし、確定（Tab・Enter）したときに初めて貼る。"),
    ]

    static let behaviorItems: [SettingItem] = [
        SettingItem(
            id: SettingID.hotKeyMode, group: "動き", label: "呼び出しキーの動き",
            summary: "履歴を呼び出すキーを押したときに何をするか。貼り付けのときに窓（候補窓・一覧）を出すかどうかも、これで決まる。",
            kind: .choice(HotKeyMode.allCases.map { SettingChoice($0.rawValue, $0.label, $0.summary) }),
            examples: [
                .init("候補窓は出さないで", .string("paste")),
                .init("貼り付けのときに UI を出さないで", .string("paste")),
                .init("⌃⌘V で一覧を開くようにして", .string("list")),
                .init("貼ったあと予測変換みたいな窓を出して", .string("candidate")),
            ]),
        SettingItem(
            id: SettingID.candidateOrder, group: "動き", label: "候補窓の並び",
            summary: "候補窓で、古い履歴を上と下のどちらに並べるか。",
            kind: .choice([
                SettingChoice("terminal", CandidateOrder.terminal.label, "最新がいちばん下。↑ で 1 つ古い履歴に貼り替える。"),
                SettingChoice("ime", CandidateOrder.ime.label, "最新がいちばん上。↓ で 1 つ古い履歴に貼り替える。"),
            ]),
            examples: [
                .init("候補窓の並びを予測変換みたいに", .string("ime")),
                .init("候補窓は新しいものを上に", .string("ime")),
                .init("ターミナルみたいに ↑ で古いほうへ", .string("terminal")),
            ]),
        SettingItem(
            id: SettingID.launchAtLogin, group: "動き", label: "ログイン時に起動",
            summary: "Mac にログインしたときに Makurip を自動で起動する。",
            kind: .toggle,
            examples: [.init("Mac を起動したら自動で立ち上げて", .bool(true))]),
        SettingItem(
            id: SettingID.maxItems, group: "履歴", label: "保存する件数の上限",
            summary: "履歴を何件まで残すか。超えたら古い順に消す（ピン留めは数えず、消さない）。下げると、超えた分をすぐに消す。",
            kind: .integer(min: 10, max: 20_000, step: 100, unit: "件"),
            examples: [.init("履歴は 200 件まで", .int(200)), .init("履歴をもっと残して（5000 件）", .int(5000))]),
        SettingItem(
            id: SettingID.maxTotalMegabytes, group: "履歴", label: "容量の上限",
            summary: "履歴全体（画像・ファイルを含む）の大きさの上限。超えたら古い順に消す（ピン留めは数えない）。単位は MB（1 GB = 1024 MB）。「2GB」のようにも書ける。",
            kind: .integer(min: 100, max: 20_480, step: 256, unit: "MB"),
            examples: [.init("履歴の容量は 2GB まで", .int(2048))]),
        SettingItem(
            id: SettingID.excludedApps, group: "履歴", label: "記録しないアプリ",
            summary:
                "このアプリを使っているときのコピーは、履歴に残さない。値はアプリのバンドル ID（例: com.apple.Safari）。パスワードを扱うアプリが付ける印（ConcealedType）の付いたコピーは、ここに入れなくても残さない。",
            kind: .appList,
            examples: [.init("Safari でコピーしたものは残さないで", .array([.string("com.apple.Safari")]))]),
        SettingItem(
            id: SettingID.snippetDateFormat, group: "定型文", label: "日付の書き方",
            summary: "定型文の {{日付}} を貼るときに入れる、今日の日付の書き方。",
            kind: .choice(
                SnippetDateFormat.allCases.map { SettingChoice($0.rawValue, $0.label, Self.dateFormatSummary($0)) }),
            examples: [
                .init("定型文の日付をハイフン区切りにして", .string("hyphen")),
                .init("日付は「2026年10月31日」のように", .string("japanese")),
            ]),
        SettingItem(
            id: SettingID.pasteTiming, group: "アプリごと", label: "確定まで貼らないアプリ",
            summary:
                "候補窓を出したとき、すぐ仮に貼るか、確定（Tab・Enter）するまで貼らないかをアプリごとに決める。ターミナルとチャット（Slack・Discord・LINE・メッセージなど）は、何も書かなくても確定まで貼らない。ここに書いたものはその既定より優先する。",
            kind: .appMap(pasteTimingChoices),
            examples: [
                .init(
                    "Slack では確定するまで貼らないで", .object(["com.tinyspeck.slackmacgap": .string("onCommit")]),
                    note: "Slack は既定でも確定まで貼らない（builtIn）。明示しておくと既定が変わっても保たれる"),
                .init("ターミナルでもすぐ貼って", .object(["com.apple.Terminal": .string("immediate")])),
            ],
            builtIn: DeferredPasteApps.all.map { .init(bundleID: $0.bundleID, name: $0.name, value: "onCommit") }),
        SettingItem(
            id: SettingID.idleTimeout, group: "詳細", label: "候補窓を自動で閉じるまで",
            summary: "候補窓を出したまま何も押さないとき、この秒数で確定して閉じる（キーの横取りを残さないため）。",
            kind: .number(min: 2, max: 120, step: 1, unit: "秒"),
            examples: [.init("候補窓をもう少し長く出しておいて（30 秒）", .number(30))], advanced: true),
        SettingItem(
            id: SettingID.replaceMethod, group: "詳細", label: "差し替え方式の決め打ち",
            summary: "候補窓で ↑↓ したときの差し替え方を、アプリごとに決め打ちする。ふつうは自動で決まるので空でよい（うまく差し替わらないアプリの手直し用）。",
            kind: .appMap([
                SettingChoice("selectRange", "範囲を選び直す", "貼った範囲を選び直して、その上に貼る。"),
                SettingChoice("undo", "⌘Z で戻す", "⌘Z で貼る前に戻してから貼る（入力欄を読めなくても使う）。"),
                SettingChoice("deferred", "確定まで貼らない", "仮に貼らず、確定したときに初めて貼る。"),
            ]),
            examples: [.init("VS Code では ⌘Z で差し替えて", .object(["com.microsoft.VSCode": .string("undo")]))],
            advanced: true, shownInWindow: false),
    ]

    static func dateFormatSummary(_ format: SnippetDateFormat) -> String {
        switch format {
        case .slash: "年/月/日（月と日は 2 桁）。"
        case .hyphen: "年-月-日（月と日は 2 桁）。"
        case .japanese: "○年○月○日。"
        }
    }

    /// キーの項目。説明は試作の文のまま（効く範囲は CLI の型・JSON の keyScope で別に出す）
    static func keyItem(_ action: KeyAction) -> SettingItem {
        SettingItem(
            id: SettingID.keys(action), section: .keys, group: action.group, label: action.label,
            summary: action.summary, kind: .keys(action), examples: keyExamples[action] ?? [])
    }

    static let keyExamples: [KeyAction: [SettingItem.Example]] = [
        .openHistory: [.init("呼び出しを ⌥V にして", .array([.string("⌥V")]))],
        .openList: [.init("一覧を開くキーを ⌃⌥⌘L に", .array([.string("⌃⌥⌘L")]))],
        .candidateCommit: [.init("候補窓は Enter だけで確定", .array([.string("↩")]))],
        .delete: [.init("履歴の削除は ⌥⌫ にして", .array([.string("⌥⌫")]))],
    ]

    // MARK: 値の読み書き

    /// いまの値（ファイルに書く形）
    public static func value(_ id: String, in settings: AppSettings) -> JSONValue? {
        guard let item = item(id) else { return nil }
        switch item.kind {
        case .keys(let action):
            return .array(settings.keymap.combos(for: action).map { .string(KeyComboText.format($0)) })
        default:
            break
        }
        switch id {
        case SettingID.hotKeyMode: return .string(settings.hotKeyMode.rawValue)
        case SettingID.candidateOrder: return .string(settings.candidateOrder.rawValue)
        case SettingID.launchAtLogin: return .bool(settings.launchAtLogin)
        case SettingID.maxItems: return .int(settings.maxItems)
        case SettingID.maxTotalMegabytes: return .int(settings.maxTotalMegabytes)
        case SettingID.excludedApps: return .array(settings.excludedApps.map(JSONValue.string))
        case SettingID.pasteTiming: return .object(settings.pasteTiming.mapValues { .string($0.rawValue) })
        case SettingID.idleTimeout: return .number(settings.idleTimeout)
        case SettingID.replaceMethod: return .object(settings.replaceMethod.mapValues { .string($0.rawValue) })
        case SettingID.snippetDateFormat: return .string(settings.snippetDateFormat.rawValue)
        default: return nil
        }
    }

    public static func defaultValue(_ id: String) -> JSONValue? { value(id, in: .default) }

    /// 検証済みの値を入れる（`validate` を通した値だけを渡す）
    static func assign(_ value: JSONValue, to id: String, in settings: inout AppSettings) {
        guard let item = item(id) else { return }
        if case .keys(let action) = item.kind {
            let combos = (value.arrayValue ?? []).compactMap {
                $0.stringValue.flatMap { try? KeyComboText.parse($0).get() }
            }
            settings.keymap.set(combos, for: action)
            return
        }
        let strings = value.arrayValue?.compactMap(\.stringValue) ?? []
        let map = value.objectValue?.compactMapValues(\.stringValue) ?? [:]
        switch id {
        case SettingID.hotKeyMode: settings.hotKeyMode = value.stringValue.flatMap(HotKeyMode.init) ?? .candidate
        case SettingID.candidateOrder:
            settings.candidateOrder = value.stringValue.flatMap(CandidateOrder.init) ?? .terminal
        case SettingID.launchAtLogin: settings.launchAtLogin = value.boolValue ?? false
        case SettingID.maxItems: settings.maxItems = value.intValue ?? AppSettings.default.maxItems
        case SettingID.maxTotalMegabytes:
            settings.maxTotalMegabytes = value.intValue ?? AppSettings.default.maxTotalMegabytes
        case SettingID.excludedApps: settings.excludedApps = strings
        case SettingID.pasteTiming: settings.pasteTiming = map.compactMapValues(PasteTiming.init)
        case SettingID.idleTimeout: settings.idleTimeout = value.doubleValue ?? AppSettings.default.idleTimeout
        case SettingID.replaceMethod: settings.replaceMethod = map.compactMapValues(ReplaceMethod.init)
        case SettingID.snippetDateFormat:
            settings.snippetDateFormat = value.stringValue.flatMap(SnippetDateFormat.init) ?? .default
        default: break
        }
    }

    /// 値を検証して入れた設定を返す。キーの重なりは `keyConflicts` に従う
    public static func applying(
        _ raw: JSONValue, to id: String, in settings: AppSettings, keyConflicts: KeyConflictPolicy
    ) -> Result<SettingChange, SettingsError> {
        guard let item = item(id) else {
            return .failure(SettingsError(id: id, message: "そういう設定項目はない（一覧は --settings schema）"))
        }
        let value: JSONValue
        switch validate(raw, for: item) {
        case .success(let normalized): value = normalized
        case .failure(let error): return .failure(error)
        }
        var next = settings
        assign(value, to: id, in: &next)
        var moved: [KeyAction] = []
        if case .keys(let action) = item.kind {
            let conflicts = next.keymap.conflicts(involving: action)
            switch keyConflicts {
            case .allow:
                break
            case .reject:
                if let conflict = conflicts.first {
                    let other = conflict.first == action ? conflict.second : conflict.first
                    return .failure(
                        SettingsError(
                            id: id,
                            message:
                                "\(conflict.combo.displayString) は「\(other.label)」（\(SettingID.keys(other))）と重なる。そちらを先に変えるか、--take-over を付けて付け替える"
                        ))
                }
            case .takeOver:
                let mine = next.keymap.combos(for: action)
                for other in KeyAction.allCases
                where other != action && Keymap.scopesInteract(other.scope, action.scope) {
                    let kept = next.keymap.combos(for: other).filter { combo in !mine.contains { $0.overlaps(combo) } }
                    if kept.count != next.keymap.combos(for: other).count {
                        next.keymap.set(kept, for: other)
                        moved.append(other)
                    }
                }
            }
        }
        return .success(SettingChange(settings: next, value: value, movedFrom: moved))
    }

    // MARK: 検証

    /// 値の型・範囲・形を確かめ、ファイルに書く形にそろえる（キーの重なりはここでは見ない）
    public static func validate(_ raw: JSONValue, for item: SettingItem) -> Result<JSONValue, SettingsError> {
        func fail(_ message: String) -> Result<JSONValue, SettingsError> {
            .failure(SettingsError(id: item.id, message: message))
        }
        switch item.kind {
        case .choice(let choices):
            guard let text = raw.stringValue, let choice = matchChoice(text, in: choices) else {
                return fail("値は \(choiceList(choices)) のどれか（いま: \(raw.compactText)）")
            }
            return .success(.string(choice.value))
        case .toggle:
            guard let bool = parseBool(raw) else { return fail("値は true か false（いま: \(raw.compactText)）") }
            return .success(.bool(bool))
        case .integer(let min, let max, _, let unit):
            guard let number = parseNumber(raw, unit: unit), let int = JSONValue.exactInt(number) else {
                return fail("値は \(min)〜\(max) の整数（単位は \(unit)。いま: \(raw.compactText)）")
            }
            guard (min...max).contains(int) else {
                return fail("値は \(min)〜\(max) の整数（単位は \(unit)。いま: \(int)）")
            }
            return .success(.int(int))
        case .number(let min, let max, _, let unit):
            guard let number = parseNumber(raw, unit: unit), (min...max).contains(number) else {
                return fail("値は \(format(min))〜\(format(max)) の数（単位は \(unit)。いま: \(raw.compactText)）")
            }
            return .success(.number(number))
        case .appList:
            let values = raw.arrayValue ?? (raw.stringValue.map { [.string($0)] } ?? [])
            guard raw.arrayValue != nil || raw.stringValue != nil else {
                return fail("値はバンドル ID の並び（例: [\"com.apple.Safari\"]。いま: \(raw.compactText)）")
            }
            var seen = Set<String>()
            var result: [JSONValue] = []
            for value in values {
                guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces) else {
                    return fail("バンドル ID は文字列で書く（いま: \(value.compactText)）")
                }
                if let problem = bundleIDProblem(text) { return fail(problem) }
                if seen.insert(text.lowercased()).inserted { result.append(.string(text)) }
            }
            return .success(.array(result))
        case .appMap(let choices):
            guard let object = raw.objectValue else {
                return fail(
                    "値は「バンドル ID → 値」の組（例: {\"com.apple.Terminal\": \"\(choices[0].value)\"}。いま: \(raw.compactText)）")
            }
            var result: [String: JSONValue] = [:]
            for (key, value) in object {
                let bundleID = key.trimmingCharacters(in: .whitespaces)
                if let problem = bundleIDProblem(bundleID) { return fail(problem) }
                guard let text = value.stringValue, let choice = matchChoice(text, in: choices) else {
                    return fail("\(bundleID) の値は \(choiceList(choices)) のどれか（いま: \(value.compactText)）")
                }
                result[bundleID] = .string(choice.value)
            }
            return .success(.object(result))
        case .keys(let action):
            let values = raw.arrayValue ?? (raw.stringValue.map { [.string($0)] } ?? [])
            guard raw.arrayValue != nil || raw.stringValue != nil else {
                return fail("値はキーの並び（例: [\"⌃⌘V\"]。空の並びで未設定。いま: \(raw.compactText)）")
            }
            var combos: [KeyCombo] = []
            for value in values {
                guard let text = value.stringValue else { return fail("キーは文字列で書く（いま: \(value.compactText)）") }
                let combo: KeyCombo
                switch KeyComboText.parse(text) {
                case .success(let parsed): combo = parsed
                case .failure(let error): return fail(error.message)
                }
                if let problem = KeyRules.problem(with: combo, for: action) {
                    return fail("\(combo.displayString): \(problem)")
                }
                if !combos.contains(combo) { combos.append(combo) }
            }
            if action.scope == .global, combos.count > 1 {
                return fail("どこからでも効くキーは 1 つだけ割り当てられる")
            }
            return .success(.array(combos.map { .string(KeyComboText.format($0)) }))
        }
    }

    static func matchChoice(_ text: String, in choices: [SettingChoice]) -> SettingChoice? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return choices.first { $0.value == trimmed }
            ?? choices.first { $0.value.lowercased() == trimmed.lowercased() || $0.label == trimmed }
    }

    static func choiceList(_ choices: [SettingChoice]) -> String {
        choices.map { "\($0.value)（\($0.label)）" }.joined(separator: "・")
    }

    static func parseBool(_ raw: JSONValue) -> Bool? {
        switch raw {
        case .bool(let value): return value
        case .number(let value) where value == 0 || value == 1: return value == 1
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "on", "yes", "1", "する", "オン", "はい": return true
            case "false", "off", "no", "0", "しない", "オフ", "いいえ": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// 数（文字列なら単位も読む: 「200件」「2GB」「512 MB」「15秒」「15s」）
    static func parseNumber(_ raw: JSONValue, unit: String) -> Double? {
        if let number = raw.doubleValue { return number }
        guard var text = raw.stringValue?.precomposedStringWithCompatibilityMapping else { return nil }
        text = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        var factor = 1.0
        let lower = text.lowercased()
        let suffixes: [(String, Double)] =
            switch unit {
            case "MB": [("gb", 1024), ("g", 1024), ("mb", 1), ("m", 1)]
            case "秒": [("秒", 1), ("sec", 1), ("s", 1)]
            default: [(unit.lowercased(), 1)]
            }
        for (suffix, value) in suffixes where lower.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            factor = value
            break
        }
        return Double(text).map { $0 * factor }
    }

    public static func format(_ value: Double) -> String {
        JSONValue.exactInt(value).map(String.init) ?? String(value)
    }

    /// バンドル ID の形（逆ドメイン名）。存在するかは見ない（入れる前のアプリも書けるように。CLI は見つからなければ注意を出す）
    static func bundleIDProblem(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if text.isEmpty || text.count > 255 || text.unicodeScalars.contains(where: { !allowed.contains($0) })
            || parts.count < 2 || parts.contains(where: \.isEmpty)
        {
            return
                "「\(text)」はバンドル ID の形ではない。バンドル ID（例: com.tinyspeck.slackmacgap）で書く。アプリ名から調べるには osascript -e 'id of app \"アプリ名\"'"
        }
        return nil
    }
}

/// キーの組み合わせとして使えるかの決まり（範囲ごと）。理由は人と AI が読んで直せる文で返す
public enum KeyRules {
    static let strong: HotKey.Modifiers = [.command, .control, .option]

    /// どこからでも効くキーとして使うと、macOS の操作を奪うもの
    static let reservedGlobal: [(KeyCombo, String)] = [
        (KeyCombo(.code(6), [.command, .shift]), "やり直す（⌘⇧Z）"),
        (KeyCombo(.code(20), [.command, .shift]), "スクリーンショット（⌘⇧3）"),
        (KeyCombo(.code(21), [.command, .shift]), "スクリーンショット（⌘⇧4）"),
        (KeyCombo(.code(23), [.command, .shift]), "スクリーンショット（⌘⇧5）"),
        (KeyCombo(.code(22), [.command, .shift]), "スクリーンショット（⌘⇧6）"),
        (KeyCombo(.code(12), [.control, .command]), "画面のロック（⌃⌘Q）"),
        (KeyCombo(.code(3), [.control, .command]), "フルスクリーン（⌃⌘F）"),
        (KeyCombo(.code(KeyCodes.space), [.control, .command]), "絵文字と記号（⌃⌘space）"),
        (KeyCombo(.code(KeyCodes.space), .control), "入力ソースの切り替え（⌃space）"),
        (KeyCombo(.code(KeyCodes.space), [.control, .option]), "入力ソースの切り替え（⌃⌥space）"),
        (KeyCombo(.code(KeyCodes.escape), [.option, .command]), "強制終了（⌥⌘esc）"),
    ]

    /// 一覧の検索欄の編集に使うキー（パネルが自分で送っている）
    static let searchField: [KeyCombo] =
        [0, 8, 9, 7, 6].map { KeyCombo(.code($0), .command) }
        + [KeyCombo(.code(6), [.command, .shift])]

    /// 使えなければ理由、使えれば nil
    public static func problem(with combo: KeyCombo, for action: KeyAction) -> String? {
        let hasStrong = !combo.modifiers.intersection(strong).isEmpty
        if action.usesDigits {
            guard combo.key == .digits else { return "番号の操作は「修飾キー + 1〜9」で割り当てる（例: ⌘1–9）" }
            return hasStrong ? nil : "数字と一緒に ⌘・⌃・⌥ のどれかを使う"
        }
        guard case .code(let code) = combo.key else {
            return "1〜9 の範囲は「番号の項目をすぐ貼り付け」（keys.quick）だけで使える"
        }
        switch action.scope {
        case .global:
            if !KeyCodes.isFunctionKey(code) {
                if combo.modifiers.subtracting(.shift).isEmpty {
                    return "修飾キーなし（⇧ だけも）では、どのアプリで打っても横取りしてしまう。⌃・⌥・⌘ と組み合わせる（例: ⌃⌘V・⌥V）"
                }
                if combo.modifiers == .command {
                    return "⌘ だけの組み合わせは、アプリの標準の操作（⌘C・⌘V など）を奪う。⌃・⌥・⇧ のどれかを足す"
                }
            }
            if let reserved = reservedGlobal.first(where: { $0.0.overlaps(combo) }) {
                return "macOS の操作「\(reserved.1)」と同じなので使えない"
            }
        case .panel, .candidate:
            if KeyCodes.typesCharacter(code), !hasStrong {
                return "文字を打つキーを修飾キーなし（⇧ だけも）で割り当てると、検索欄や文書に文字が打てなくなる。⌘・⌃・⌥ と組み合わせる"
            }
            if action.scope == .panel, searchField.contains(where: { $0.overlaps(combo) }) {
                return "一覧の検索欄の編集（⌘A・⌘C・⌘V・⌘X・⌘Z）に使うので割り当てられない"
            }
        }
        return nil
    }
}

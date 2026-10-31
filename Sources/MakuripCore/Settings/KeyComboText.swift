import Foundation

/// キーの組み合わせの文字表現（設定ファイル・CLI・AI とのやりとり）。
///
/// 書くときは画面と同じ表記（`⌃⌘V`・`⇧↩`・`esc`・`⌘1–9`）。読むときは次も受け付ける:
/// - 修飾キーの言葉: `ctrl`/`control`・`opt`/`option`/`alt`・`shift`・`cmd`/`command` を `+` でつなぐ（`ctrl+cmd+v`）
/// - キーの別名: `return`/`enter`・`tab`・`escape`・`space`・`delete`/`backspace`・`up`/`down`/`left`/`right`・`f1`〜`f20`・`1-9`
/// - 全角の英数字（NFKC で半角にする）・小文字の英字
/// - 修飾キー 1 つだけ（`⌥`・`alt`・`option`）は「押している間だけ効くキー」（`KeyCombo.Key.hold`。隠した内容の表示に使う）
public enum KeyComboText {
    public enum ParseError: Error, Equatable, Sendable {
        case empty
        /// 修飾キーだけで、キーがない
        case missingKey
        case unknownKey(String)

        public var message: String {
            switch self {
            case .empty: "キーが空"
            case .missingKey: "修飾キーだけでキーがない（例: ⌃⌘V）"
            case .unknownKey(let name): "「\(name)」というキーは分からない（例: ⌃⌘V・⇧↩・esc・⌘1–9・ctrl+opt+v）"
            }
        }
    }

    public static func format(_ combo: KeyCombo) -> String { combo.displayString }

    public static func parse(_ text: String) -> Result<KeyCombo, ParseError> {
        var rest = Substring(text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return .failure(.empty) }
        var modifiers: HotKey.Modifiers = []
        while true {
            rest = rest.drop(while: { $0 == " " })
            if let first = rest.first, let modifier = symbolModifiers[first] {
                modifiers.insert(modifier)
                rest = rest.dropFirst()
                continue
            }
            if let (modifier, length) = wordModifier(at: rest) {
                modifiers.insert(modifier)
                rest = rest.dropFirst(length)
                continue
            }
            // 記号の修飾キーとキーの間の「+」（⌘+V）。「+」だけならキーの名前として残す
            if rest.count > 1, rest.first == "+" {
                rest = rest.dropFirst()
                continue
            }
            break
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        if name.isEmpty, holdable(modifiers) { return .success(KeyCombo(.hold, modifiers)) }
        if modifiers.isEmpty, let modifier = wordModifiers.first(where: { $0.0 == name.lowercased() })?.1 {
            return .success(KeyCombo(.hold, modifier))
        }
        guard !name.isEmpty else { return .failure(modifiers.isEmpty ? .empty : .missingKey) }
        guard let key = key(named: name) else { return .failure(.unknownKey(name)) }
        return .success(KeyCombo(key, modifiers))
    }

    /// 押している間だけ効くキーにできるのは、修飾キー 1 つだけ
    public static func holdable(_ modifiers: HotKey.Modifiers) -> Bool {
        [HotKey.Modifiers.control, .option, .shift, .command].filter { modifiers.contains($0) }.count == 1
            && modifiers.subtracting([.control, .option, .shift, .command]).isEmpty
    }

    static let symbolModifiers: [Character: HotKey.Modifiers] = [
        "⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command,
    ]

    static let wordModifiers: [(String, HotKey.Modifiers)] = [
        ("control", .control), ("ctrl", .control), ("option", .option), ("opt", .option), ("alt", .option),
        ("shift", .shift), ("command", .command), ("cmd", .command),
    ]

    /// 「ctrl+」のように、言葉の修飾キーの後ろに「+」が続くときだけ修飾キーとみなす（「c」のキーと区別するため）
    static func wordModifier(at text: Substring) -> (HotKey.Modifiers, Int)? {
        let lower = text.lowercased()
        for (word, modifier) in wordModifiers where lower.hasPrefix(word) {
            let after = lower.dropFirst(word.count).drop(while: { $0 == " " })
            if after.first == "+" {
                return (modifier, text.count - after.count + 1)
            }
        }
        return nil
    }

    static func key(named name: String) -> KeyCombo.Key? {
        if let code = aliasCodes[name.lowercased()] { return .code(code) }
        if digitNames.contains(name.lowercased()) { return .digits }
        let upper = name.uppercased()
        if let code = KeyCodes.names.first(where: { $0.value.uppercased() == upper })?.key { return .code(code) }
        return nil
    }

    static let digitNames: Set<String> = ["1–9", "1-9", "1〜9", "1~9", "digits"]

    static let aliasCodes: [String: UInt16] = [
        "return": KeyCodes.returnKey, "enter": KeyCodes.returnKey, "⏎": KeyCodes.returnKey, "↵": KeyCodes.returnKey,
        "tab": KeyCodes.tab, "escape": KeyCodes.escape, "⎋": KeyCodes.escape, "space": KeyCodes.space,
        "␣": KeyCodes.space, "スペース": KeyCodes.space, "delete": KeyCodes.delete, "backspace": KeyCodes.delete,
        "forwarddelete": 117, "fwddelete": 117, "up": KeyCodes.upArrow, "down": KeyCodes.downArrow,
        "left": KeyCodes.leftArrow, "right": KeyCodes.rightArrow, "pageup": 116, "pagedown": 121, "yen": 93,
        "comma": KeyCodes.comma, "period": 47, "slash": 44, "minus": 27, "equal": 24,
    ]
}

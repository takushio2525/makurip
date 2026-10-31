import Foundation

/// キーの組み合わせ 1 つ。キーは物理キーの位置（仮想キーコード）で持つ（`HotKey` と同じ考え方。JIS 配列でも英字・数字の位置は同じ）
public struct KeyCombo: Codable, Hashable, Sendable {
    public enum Key: Codable, Hashable, Sendable {
        /// 仮想キーコード（`kVK_ANSI_K` = 40 など）
        case code(UInt16)
        /// 数字の 1〜9（「番号の項目をすぐ貼り付け」のように、押した番号で動くもの）
        case digits
    }

    public var key: Key
    public var modifiers: HotKey.Modifiers

    public init(_ key: Key, _ modifiers: HotKey.Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ hotKey: HotKey) {
        self.init(.code(UInt16(hotKey.keyCode)), hotKey.modifiers)
    }

    /// 押されたキーに合えば true。数字のキーなら `digit` に 1〜9 が入る
    public func matches(_ press: KeyStroke) -> (matched: Bool, digit: Int?) {
        guard press.modifiers == modifiers else { return (false, nil) }
        switch key {
        case .code(let code):
            return (KeyCodes.canonical(code) == KeyCodes.canonical(press.keyCode), nil)
        case .digits:
            guard let digit = KeyCodes.digit(of: press.keyCode) else { return (false, nil) }
            return (true, digit)
        }
    }

    /// 2 つの組み合わせが同じキーで発火しうるか（重なりの検出に使う）
    public func overlaps(_ other: KeyCombo) -> Bool {
        guard modifiers == other.modifiers else { return false }
        switch (key, other.key) {
        case (.digits, .digits): return true
        case (.code(let a), .code(let b)): return KeyCodes.canonical(a) == KeyCodes.canonical(b)
        case (.digits, .code(let code)), (.code(let code), .digits): return KeyCodes.digit(of: code) != nil
        }
    }

    /// 画面に出す表記（例: ⌘K・⇧⇥・⌘1–9・esc）。修飾キーは macOS の慣習の順（⌃⌥⇧⌘）
    public var displayString: String { modifierSymbols + keySymbol }

    public var modifierSymbols: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    /// キーの部分の表記。Return は UI 側で記号（SF Symbols の return）に置き換える
    public var keySymbol: String {
        switch key {
        case .digits: "1–9"
        case .code(let code): KeyCodes.names[KeyCodes.canonical(code)] ?? "#\(code)"
        }
    }

    public var isReturn: Bool { key == .code(KeyCodes.returnKey) }

    /// 全体のキー（Carbon のホットキー）として登録するときの形。数字の範囲は登録できないので nil
    public var hotKey: HotKey? {
        guard case .code(let code) = key else { return nil }
        return HotKey(keyCode: UInt32(code), modifiers: modifiers)
    }
}

/// 押されたキー（`NSEvent` から作る。AppKit に依存しないよう値だけを持つ）
public struct KeyStroke: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: HotKey.Modifiers

    public init(keyCode: UInt16, modifiers: HotKey.Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 仮想キーコードの表（US 配列の位置の名前）
public enum KeyCodes {
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let tab: UInt16 = 48
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let space: UInt16 = 49
    public static let comma: UInt16 = 43

    /// F1〜F20 の仮想キーコード（並びは F1, F2, …）。文字を打たないキーなので、修飾キーなしでも割り当てられる
    public static let functionKeyCodes: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// 文字を打たないキー（矢印・↩・⇥・esc・⌫・⌦・home・end・pgup・pgdn・F1〜F20）。それ以外（英字・数字・記号・space）は文字を打つ
    public static let nonCharacterCodes: Set<UInt16> = Set(
        [
            returnKey, keypadEnter, tab, delete, escape, leftArrow, rightArrow, downArrow, upArrow, 117, 115, 119, 116,
            121,
        ]
            + functionKeyCodes)

    /// 文字を打つキーか（修飾キーなしで割り当てると、検索欄や前面のアプリで文字が打てなくなる）
    public static func typesCharacter(_ code: UInt16) -> Bool {
        !nonCharacterCodes.contains(canonical(code))
    }

    public static func isFunctionKey(_ code: UInt16) -> Bool {
        functionKeyCodes.contains(code)
    }

    /// 数字キー 1〜9 の仮想キーコード（並びは 1, 2, …, 9）
    public static let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// テンキーの Enter は Return と同じに扱う（試作も Enter と NumpadEnter を同じにしている）
    public static func canonical(_ code: UInt16) -> UInt16 {
        code == keypadEnter ? returnKey : code
    }

    public static func digit(of code: UInt16) -> Int? {
        digitCodes.firstIndex(of: code).map { $0 + 1 }
    }

    /// 表示名。英字は大文字、特殊キーは試作の表記（esc・⇥・⌫ など）
    public static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "space", 51: "⌫", 53: "esc", 117: "⌦", 115: "home", 119: "end", 116: "pgup",
        121: "pgdn", 123: "←", 124: "→", 125: "↓", 126: "↑", 93: "¥", 94: "_",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]
}

/// キーで呼べる操作の一覧。**全操作はここから定義する**（ID・既定のキー・説明文）。
///
/// 設定スキーマ（`SettingsSchema`）は操作ごとに `keys.<ID>` の項目を作り、設定画面・CLI・AI（MCP）が同じ ID と説明文で付け替える。
/// ID（rawValue）と並びは試作（`makurip-design/ui/shared/core.js` の `Mk.ACTIONS`）と同じにしてある。
/// 秘密の表示の操作はフェーズ5（#5）で足す。`editSnippet` は試作に無い（定型文の窓を開く。#7）。
public enum KeyAction: String, CaseIterable, Sendable, Hashable, Codable {
    case openHistory = "open"
    case openList
    case close
    case previous = "prev"
    case next
    case paste
    case pastePlain
    case copyOnly
    case quickPaste = "quick"
    case kindNext
    case kindPrevious = "kindPrev"
    case cycleMethod = "method"
    case chooseApp = "app"
    case pinnedOnly = "pinned"
    case snippets
    case togglePin = "pin"
    case preview = "look"
    case openSource = "source"
    case delete
    case settings
    case editSnippet
    case candidateUp = "candUp"
    case candidateDown = "candDown"
    case candidateCommit = "candCommit"
    case candidateCancel = "candCancel"
    case candidateExpand = "candExpand"

    /// どこで効くキーか
    public enum Scope: String, Sendable, Codable {
        /// どのアプリからでも効く（Carbon のホットキーとして登録する）
        case global
        /// 一覧（パネル）が開いている間だけ効く
        case panel
        /// 候補窓が出ている間だけ効く（CGEventTap で横取りする）
        case candidate
    }

    public var scope: Scope {
        switch self {
        case .openHistory, .openList: .global
        case .candidateUp, .candidateDown, .candidateCommit, .candidateCancel, .candidateExpand: .candidate
        default: .panel
        }
    }

    /// 設定画面で並べるときのまとまり
    public var group: String {
        switch self {
        case .openHistory, .openList, .close: "呼び出す"
        case .previous, .next, .paste, .pastePlain, .copyOnly, .quickPaste: "選ぶ・貼る"
        case .kindNext, .kindPrevious, .cycleMethod, .chooseApp, .pinnedOnly, .snippets: "絞り込み"
        case .togglePin, .preview, .openSource, .delete, .settings, .editSnippet: "項目の操作"
        case .candidateUp, .candidateDown, .candidateCommit, .candidateCancel, .candidateExpand: "候補窓"
        }
    }

    public var label: String {
        switch self {
        case .openHistory: "履歴を呼び出す（どこからでも）"
        case .openList: "一覧を開く（どこからでも）"
        case .close: "検索を消す／閉じる"
        case .previous: "前の項目"
        case .next: "次の項目"
        case .paste: "貼り付け"
        case .pastePlain: "プレーンテキストで貼り付け"
        case .copyOnly: "コピーだけする（貼り付けない）"
        case .quickPaste: "番号の項目をすぐ貼り付け"
        case .kindNext: "種類：次へ"
        case .kindPrevious: "種類：前へ"
        case .cycleMethod: "コピー方法を切り替え"
        case .chooseApp: "コピー元アプリを選ぶ"
        case .pinnedOnly: "ピン留めだけ表示"
        case .snippets: "定型文を表示"
        case .togglePin: "ピン留めする／外す"
        case .preview: "大きくプレビュー"
        case .openSource: "コピー元のページを開く"
        case .delete: "履歴から削除"
        case .settings: "設定を開く"
        case .editSnippet: "定型文を編集／履歴から登録"
        case .candidateUp: "上の候補へ"
        case .candidateDown: "下の候補へ"
        case .candidateCommit: "確定"
        case .candidateCancel: "取り消し"
        case .candidateExpand: "一覧に広げる"
        }
    }

    /// 設定画面と AI 向けの設定一覧に出す説明文
    public var summary: String {
        switch self {
        case .openHistory:
            "押したときの動きは「呼び出しキーの動き」（すぐ貼るだけ／すぐ貼って候補窓／一覧を開く）で選ぶ。一覧が開いているときに押すと閉じる。"
        case .openList: "呼び出しキーの動きに関係なく、履歴の一覧（パネル）を開く。開いているときに押すと閉じる。"
        case .close: "検索語があれば消し、なければ一覧を閉じる。"
        case .previous: "一覧で 1 つ前の項目を選ぶ。"
        case .next: "一覧で 1 つ次の項目を選ぶ。"
        case .paste: "選んだ項目を、一覧を開く前に使っていたアプリに貼る。"
        case .pastePlain: "太字やリンクなどの書式を外し、文字だけを貼る。コマンドの先頭のプロンプト（「$ 」など）は外さず、そのまま貼る。"
        case .copyOnly: "クリップボードに入れるだけで、貼り付けはしない。"
        case .quickPaste: "一覧の上から 1〜9 番目を、選ばずにそのまま貼る。"
        case .kindNext: "種類の絞り込み（テキスト・画像・コードなど）を次に進める。"
        case .kindPrevious: "種類の絞り込みを 1 つ前に戻す。"
        case .cycleMethod: "コピーの方法で絞る。すべて → キー操作 → ボタンなど の順に切り替わる。"
        case .chooseApp: "コピー元のアプリを一覧から選んで絞る。"
        case .pinnedOnly: "ピン留めした項目だけを表示する。もう一度押すと戻る。"
        case .snippets: "定型文の一覧に切り替える。もう一度押すと履歴に戻る。"
        case .togglePin: "選んだ項目を固定し、古くなっても消えないようにする。"
        case .preview: "選んだ項目を大きく表示する（画像やコードの確認用）。"
        case .openSource: "コピーした元のページ（ブラウザや AI チャット）を開く。"
        case .delete: "選んだ項目を履歴から消す。"
        case .settings: "この設定画面を開く（一覧を閉じてから開く）。"
        case .editSnippet:
            "定型文の一覧では、選んだ定型文を編集する窓を開く（1 件もなければ新しく作る）。履歴の一覧では、選んだ項目の文字から新しい定型文を作る。"
        case .candidateUp: "候補窓で 1 つ上の履歴に貼り替える。ターミナル式の並びでは 1 つ古い履歴になる。"
        case .candidateDown: "候補窓で 1 つ下の履歴に貼り替える。ターミナル式の並びでは 1 つ新しい履歴になる。"
        case .candidateCommit: "貼った中身を確定して候補窓を閉じる。改行や送信はしない。"
        case .candidateCancel: "貼る前の状態に戻して候補窓を閉じる。"
        case .candidateExpand: "仮に貼った中身を戻し、選んでいた項目を選んだ状態で一覧を開く。"
        }
    }

    /// 番号で動く操作か（キーは「修飾キー + 1〜9」で割り当てる）
    public var usesDigits: Bool { self == .quickPaste }

    /// 既定のキー（試作と同じ。先頭のものを画面のヒントに出す）
    public var defaultCombos: [KeyCombo] {
        switch self {
        case .openHistory: [KeyCombo(.defaultOpenHistory)]
        case .openList: [KeyCombo(.defaultOpenList)]
        case .close: [KeyCombo(.code(KeyCodes.escape))]
        case .previous: [KeyCombo(.code(KeyCodes.upArrow)), KeyCombo(.code(35), .control)]  // ↑・⌃P
        case .next: [KeyCombo(.code(KeyCodes.downArrow)), KeyCombo(.code(45), .control)]  // ↓・⌃N
        case .paste: [KeyCombo(.code(KeyCodes.returnKey))]
        case .pastePlain: [KeyCombo(.code(KeyCodes.returnKey), .shift)]
        case .copyOnly: [KeyCombo(.code(KeyCodes.returnKey), .command)]
        case .quickPaste: [KeyCombo(.digits, .command)]
        case .kindNext: [KeyCombo(.code(KeyCodes.tab))]
        case .kindPrevious: [KeyCombo(.code(KeyCodes.tab), .shift)]
        case .cycleMethod: [KeyCombo(.code(40), .command)]  // ⌘K
        case .chooseApp: [KeyCombo(.code(14), .command)]  // ⌘E
        case .pinnedOnly: [KeyCombo(.code(35), [.command, .shift])]  // ⌘⇧P
        case .snippets: [KeyCombo(.code(1), .command)]  // ⌘S
        case .togglePin: [KeyCombo(.code(35), .command)]  // ⌘P
        case .preview: [KeyCombo(.code(16), .command)]  // ⌘Y
        case .openSource: [KeyCombo(.code(31), .command)]  // ⌘O
        case .delete: [KeyCombo(.code(KeyCodes.delete), .command)]  // ⌘⌫
        case .settings: [KeyCombo(.code(KeyCodes.comma), .command)]  // ⌘,
        case .editSnippet: [KeyCombo(.code(1), [.command, .shift])]  // ⌘⇧S
        case .candidateUp: [KeyCombo(.code(KeyCodes.upArrow))]
        case .candidateDown: [KeyCombo(.code(KeyCodes.downArrow))]
        case .candidateCommit: [KeyCombo(.code(KeyCodes.tab)), KeyCombo(.code(KeyCodes.returnKey))]
        case .candidateCancel: [KeyCombo(.code(KeyCodes.escape))]
        // 呼び出しキーをもう一度押すと広げる（試作と同じ。候補窓の範囲なので呼び出しキーとは重ならない扱い）
        case .candidateExpand: [KeyCombo(.defaultOpenHistory)]
        }
    }
}

/// 操作 → キーの割り当て。既定は `KeyAction.defaultCombos`。フェーズ4でユーザーと AI が付け替える
public struct Keymap: Hashable, Sendable {
    public private(set) var bindings: [KeyAction: [KeyCombo]]

    public init(bindings: [KeyAction: [KeyCombo]]) {
        self.bindings = bindings
    }

    public static let `default` = Keymap(
        bindings: Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0, $0.defaultCombos) }))

    public func combos(for action: KeyAction) -> [KeyCombo] {
        bindings[action] ?? []
    }

    /// 画面のヒントに出すキー（先頭の 1 つ）
    public func primary(_ action: KeyAction) -> KeyCombo? {
        combos(for: action).first
    }

    public mutating func set(_ combos: [KeyCombo], for action: KeyAction) {
        bindings[action] = combos
    }

    /// 押されたキーに当たる操作（範囲 `scope` の中だけを見る）。数字のキーなら番号も返す
    public func action(for press: KeyStroke, scope: KeyAction.Scope = .panel) -> (action: KeyAction, digit: Int?)? {
        for action in KeyAction.allCases where action.scope == scope {
            for combo in combos(for: action) {
                let result = combo.matches(press)
                if result.matched { return (action, result.digit) }
            }
        }
        return nil
    }

    /// 重なっているキー（同じキーで 2 つ以上の操作が発火しうる組）。全体のキーとパネルのキーは同じ範囲として見る
    /// （パネルを開いている間もどこからでも効くキーは届くため）。
    /// 候補窓のキーは候補窓が出ている間だけ効くので、候補窓のキーどうしだけを比べる（試作と同じ。
    /// 既定で ⌃⌘V が「呼び出す」と「一覧に広げる」の両方に入っているのはこのため）
    public func conflicts() -> [KeyConflict] {
        var result: [KeyConflict] = []
        let entries = KeyAction.allCases.flatMap { action in combos(for: action).map { (action, $0) } }
        for (i, a) in entries.enumerated() {
            for b in entries[(i + 1)...]
            where a.0 != b.0 && Self.scopesInteract(a.0.scope, b.0.scope) && a.1.overlaps(b.1) {
                result.append(KeyConflict(first: a.0, second: b.0, combo: a.1))
            }
        }
        return result
    }

    /// `action` が関わる重なりだけ
    public func conflicts(involving action: KeyAction) -> [KeyConflict] {
        conflicts().filter { $0.first == action || $0.second == action }
    }

    /// 2 つの範囲のキーが同時に効きうるか
    public static func scopesInteract(_ a: KeyAction.Scope, _ b: KeyAction.Scope) -> Bool {
        (a == .candidate) == (b == .candidate)
    }
}

public struct KeyConflict: Hashable, Sendable {
    public var first: KeyAction
    public var second: KeyAction
    public var combo: KeyCombo
}

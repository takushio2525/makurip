/// グローバルショートカット 1 つ。キーは物理キーの位置（仮想キーコード）で持つ。
///
/// フェーズ4でユーザーが好きなキーを登録できるよう、任意の組み合わせを表せる形にしてある（Codable で設定に保存できる）。
/// 登録そのもの（Carbon `RegisterEventHotKey`）はアプリ側の `HotKeyCenter` が行う。
public struct HotKey: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// 仮想キーコード（`kVK_ANSI_V` = 9 など。キーボード配列に依らない物理位置）
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 履歴を開く既定キー ⌃⌘V（ユーザーが選んだ。Clipy の既定と同じなのでフェーズ4で変えられるようにする）
    public static let defaultOpenHistory = HotKey(keyCode: 9, modifiers: [.control, .command])

    /// 呼び出しキーの動きに関係なく一覧を開く既定キー ⌃⌥⌘V（試作の openList と同じ）
    public static let defaultOpenList = HotKey(keyCode: 9, modifiers: [.control, .option, .command])

    /// メニュー等に出す表記（例: ⌃⌘V）。修飾キーは macOS の慣習の順（⌃⌥⇧⌘）
    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (HotKey.keyNames[keyCode] ?? "#\(keyCode)")
    }

    /// US 配列の物理位置の名前（表示用）。JIS 配列でも英字・数字の位置は同じ
    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O",
        32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

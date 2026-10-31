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

    /// メニュー等に出す表記（例: ⌃⌘V）。修飾キーは macOS の慣習の順（⌃⌥⇧⌘）。キーの名前はキーマップと同じ表（`KeyCodes.names`）
    public var displayString: String { KeyCombo(self).displayString }
}

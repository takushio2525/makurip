/// メニューバーのアイコンを押して開くメニューの項目（並び・文言・右に添えるキー）。
///
/// 本体（`StatusMenuController`）は、ここが返す並びを NSMenu に写すだけにする。
/// Makurip のすべての画面（一覧・定型文の一覧・定型文の窓・設定）と主な操作へメニューから行けることを、ここのテストで守る
public enum StatusMenuModel {
    /// メニューの項目を押したときにすること
    public enum Command: String, CaseIterable, Sendable {
        /// 履歴の一覧を開く（開いていれば閉じる）
        case openList
        /// 一覧を定型文の表示で開く（一覧の ⌘S と同じ表示）
        case openSnippetList
        /// 定型文の窓（登録・編集・並べ替え）
        case editSnippets
        /// 設定画面
        case openSettings
        case togglePause
        case clearHistory
        case requestAccessibility
        case quit
    }

    public struct Item: Equatable, Sendable {
        public let command: Command
        public let title: String
        /// 右に添えるキー（いまのキーマップから引く操作）。nil なら添えない
        public let key: KeyAction?
    }

    public enum Entry: Equatable, Sendable {
        case item(Item)
        /// 押せない 1 行（件数・状態）
        case info(String)
        case separator
    }

    public struct State: Equatable, Sendable {
        public var appName: String
        public var paused: Bool
        public var accessibilityTrusted: Bool
        public var itemCount: Int
        public var isolated: Bool

        public init(appName: String, paused: Bool, accessibilityTrusted: Bool, itemCount: Int, isolated: Bool) {
            self.appName = appName
            self.paused = paused
            self.accessibilityTrusted = accessibilityTrusted
            self.itemCount = itemCount
            self.isolated = isolated
        }
    }

    public static func entries(_ state: State) -> [Entry] {
        func item(_ command: Command, _ title: String, key: KeyAction? = nil) -> Entry {
            .item(Item(command: command, title: title, key: key))
        }
        var entries: [Entry] = [
            // 呼び出しキーは既定で候補窓なので、一覧には一覧を開くキーを添える
            item(.openList, "履歴の一覧を開く", key: .openList),
            item(.openSnippetList, "定型文の一覧を開く", key: .snippets),
            item(.editSnippets, "定型文を編集…", key: .editSnippet),
            item(.openSettings, "設定…", key: .settings),
            .separator,
            item(.togglePause, state.paused ? "記録を再開" : "記録を一時停止"),
            item(.clearHistory, "履歴を消去…"),
            .separator,
        ]
        if !state.accessibilityTrusted {
            entries.append(item(.requestAccessibility, "アクセシビリティを許可…（貼り付けとコピー方法の記録に必要）"))
        }
        var status = "履歴 \(state.itemCount) 件"
        if state.paused { status += "・一時停止中" }
        if state.isolated { status += "・検証用フォルダ" }
        entries.append(.info(status))
        entries.append(.separator)
        entries.append(item(.quit, "\(state.appName) を終了"))
        return entries
    }
}

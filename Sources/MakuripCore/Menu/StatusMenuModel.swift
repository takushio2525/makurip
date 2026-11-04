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
        /// 見つけた新しい版に入れ替えて起動し直す（#43）
        case installUpdate
        /// 見つけた新しい版を知らせないようにする
        case skipUpdate
        /// 手で確かめる（結果は窓で出す）
        case checkForUpdates
        case quit
    }

    public struct Item: Equatable, Sendable {
        public let command: Command
        public let title: String
        /// 右に添えるキー（いまのキーマップから引く操作）。nil なら添えない
        public let key: KeyAction?
        /// 押せるか（確かめている間の「アップデートを確認…」は押せない）
        public let enabled: Bool

        init(command: Command, title: String, key: KeyAction?, enabled: Bool = true) {
            self.command = command
            self.title = title
            self.key = key
            self.enabled = enabled
        }
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
        /// アップデートの状態（nil なら、アップデートの項目を出さない）
        public var update: UpdateStatus?

        public init(
            appName: String, paused: Bool, accessibilityTrusted: Bool, itemCount: Int, isolated: Bool,
            update: UpdateStatus? = nil
        ) {
            self.update = update
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
        var entries: [Entry] = []
        // 新しい版の知らせはメニューの先頭（#43）
        if let update = state.update, let headline = update.menuHeadline {
            entries.append(.info(headline))
            if update.offersInstall { entries.append(item(.installUpdate, "アップデートして再起動")) }
            if update.announced != nil, update.blockedReason != nil, !update.isBusy {
                entries.append(.info("この場所からは入れ替えられません（理由は設定画面）"))
            }
            if update.announced != nil, !update.isBusy { entries.append(item(.skipUpdate, "この版は知らせない")) }
            entries.append(.separator)
        }
        entries += [
            // 呼び出しキーは既定で候補窓なので、一覧には一覧を開くキーを添える
            item(.openList, "履歴の一覧を開く", key: .openList),
            item(.openSnippetList, "定型文の一覧を開く", key: .snippets),
            item(.editSnippets, "定型文を編集…", key: .editSnippet),
            item(.openSettings, "設定…", key: .settings),
        ]
        if let update = state.update {
            let checking = update.phase == .checking
            entries.append(
                .item(
                    Item(
                        command: .checkForUpdates, title: checking ? "アップデートを確かめています…" : "アップデートを確認…", key: nil,
                        enabled: !update.isBusy)))
        }
        entries += [
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

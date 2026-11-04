/// 一覧のカードを右クリックして開くメニューの項目（並び・文言）。#38
///
/// 項目はどれもキーマップの操作（`KeyAction`）そのもので、選ぶと一覧でそのキーを押したのと同じ処理を通す
/// （`HistoryPanelModel.perform`）。右に添えるキーも、いまのキーマップの先頭の割り当てから引く（`StatusMenuModel` と同じ考え方）。
/// UI（`MakuripUI` の `CardMenu`）は、ここが返す並びを NSMenu に写すだけにする。
/// 出し分けは項目のメタデータだけで決める（中身は読まない）
public enum CardMenuModel {
    public struct Item: Equatable, Sendable {
        public let action: KeyAction
        public let title: String

        public init(action: KeyAction, title: String) {
            self.action = action
            self.title = title
        }
    }

    public enum Entry: Equatable, Sendable {
        case item(Item)
        case separator
    }

    /// 履歴のカードのメニュー。
    /// - 文字だけで貼り付け: 文字を持つ項目だけ（`hasText`）
    /// - 定型文に登録: 文字を持ち、秘密っぽくない項目だけ（秘密からは作らない。#25）
    /// - コピー元のページを開く: 開けるページがあるときだけ（`ClipItem.openablePageURL`）
    /// - ピン留め: いまの状態で「ピン留め」と「ピン留めを外す」を出し分ける
    /// - プレビュー: ⌘Y と同じく開け閉めなので、開いているときは「プレビューを閉じる」
    public static func entries(for item: ClipItem, previewOpen: Bool = false) -> [Entry] {
        let text = hasText(item)
        var entries: [Entry] = [.item(Item(action: .paste, title: "貼り付け"))]
        if text { entries.append(.item(Item(action: .pastePlain, title: "文字だけで貼り付け"))) }
        entries.append(.item(Item(action: .copyOnly, title: "クリップボードにコピー")))
        entries.append(.separator)
        entries.append(.item(Item(action: .togglePin, title: item.isPinned ? "ピン留めを外す" : "ピン留め")))
        if text, !item.isSecretLikely { entries.append(.item(Item(action: .editSnippet, title: "定型文に登録…"))) }
        entries.append(.item(previewItem(open: previewOpen)))
        if item.openablePageURL != nil { entries.append(.item(Item(action: .openSource, title: "コピー元のページを開く"))) }
        entries.append(.separator)
        entries.append(.item(Item(action: .delete, title: "履歴から削除")))
        return entries
    }

    /// 定型文のカードのメニュー。定型文は文字だけなので「文字だけで貼り付け」は出さない。
    /// ピン留め・ページ・削除は定型文にない（一覧のキーでも効かない。削除は定型文の窓で行う）
    public static func snippetEntries(previewOpen: Bool = false) -> [Entry] {
        [
            .item(Item(action: .paste, title: "貼り付け")),
            .item(Item(action: .copyOnly, title: "クリップボードにコピー")),
            .separator,
            .item(Item(action: .editSnippet, title: "編集…")),
            .item(previewItem(open: previewOpen)),
        ]
    }

    /// 文字を持つ項目か（「文字だけで貼り付け」「定型文に登録」を出すか）。画像とファイルは持たない扱いにする
    /// （ファイルの一覧用の平文はファイルの名前で、書式を外して貼る文字ではないため）
    public static func hasText(_ item: ClipItem) -> Bool {
        item.kind != .image && item.kind != .file && item.previewText != nil
    }

    private static func previewItem(open: Bool) -> Item {
        Item(action: .preview, title: open ? "プレビューを閉じる" : "プレビュー")
    }
}

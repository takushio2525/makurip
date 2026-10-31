import Foundation

/// 一覧 UI と本体のあいだの約束。`MakuripUI` を丸ごと差し替えるとき、新しい UI はこの 2 つのプロトコルだけを
/// 相手にすればよい（本体のコードは変えなくてよい）。
///
/// 本体（`Makurip` ターゲット）が `HistoryActions` を実装して UI に渡し、UI は `HistoryPresenting` を実装する。
@MainActor
public protocol HistoryPresenting: AnyObject {
    var isVisible: Bool { get }
    /// 一覧を開く（⌃⌘V・メニューから）
    func show()
    func hide()
    /// 履歴が変わった（取り込み・消去）。開いていれば読み直す
    func historyDidChange()
    /// 検証用の状態（絞り込みの語・表示中の行数など。中身は入れない）。実装しなければ空
    var debugState: [String: String] { get }
}

extension HistoryPresenting {
    public var debugState: [String: String] { [:] }
}

/// 貼り付けのしかた
public enum PasteMode: String, Sendable, CaseIterable {
    /// 全型ごと書き戻して ⌘V
    case normal
    /// 文字だけを書き戻して ⌘V（書式を外す。平文の型がなければ全型）
    case plainText
    /// 書き戻すだけで ⌘V は送らない
    case copyOnly
}

@MainActor
public protocol HistoryActions: AnyObject {
    /// 新しい順の履歴（メタデータだけ）
    func historyItems(limit: Int) -> [ClipItem]
    /// 選んだ項目を、元いたアプリへ貼り付ける（UI は先に閉じておく）
    func paste(itemID: UUID)
    /// 貼り方を選んで貼る（UI は先に閉じておく）。既定の実装は `.normal` だけを `paste(itemID:)` に回す
    func paste(itemID: UUID, mode: PasteMode)
    /// UI が閉じた（貼らずに Esc で閉じたときも呼ぶ）
    func historyDidClose()
    /// ピン留めする・外す
    func setPinned(_ pinned: Bool, itemID: UUID)
    /// 履歴から消す
    func delete(itemID: UUID)
    /// 保存した型の一覧（中身なし）。サムネイル・プレビューで読む型を選ぶのに使う
    func representationInfos(itemID: UUID) -> [RepresentationInfo]
    /// 型 1 つのデータ（サムネイル・プレビュー用）。中身は UI の中だけで使い、ログ等に出さない
    func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data?
}

extension HistoryActions {
    public func paste(itemID: UUID, mode: PasteMode) {
        if mode == .normal { paste(itemID: itemID) }
    }
    public func setPinned(_ pinned: Bool, itemID: UUID) {}
    public func delete(itemID: UUID) {}
    public func representationInfos(itemID: UUID) -> [RepresentationInfo] { [] }
    public func representationData(itemID: UUID, itemIndex: Int, type: String) -> Data? { nil }
}

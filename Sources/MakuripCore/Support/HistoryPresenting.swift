import Foundation

/// 一覧 UI と本体のあいだの約束。フェーズ2で `MakuripUI` を丸ごと差し替えるとき、
/// 新しい UI はこの 2 つのプロトコルだけを相手にすればよい（本体のコードは変えなくてよい）。
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

@MainActor
public protocol HistoryActions: AnyObject {
    /// 新しい順の履歴（メタデータだけ）
    func historyItems(limit: Int) -> [ClipItem]
    /// 選んだ項目を、元いたアプリへ貼り付ける（UI は先に閉じておく）
    func paste(itemID: UUID)
    /// UI が閉じた（貼らずに Esc で閉じたときも呼ぶ）
    func historyDidClose()
}

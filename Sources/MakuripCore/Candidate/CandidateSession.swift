import CoreGraphics
import Foundation

/// 候補窓の並びと選択（純粋な値）。履歴の並びは始めた時点で固定し、回している間に取り込みがあっても変えない。
///
/// `index` は新しい順の添字（0 が最新）。画面の上下は並び順（`CandidateOrder`）で決まる:
/// ターミナル式は最新がいちばん下で ↑ が古いほう、予測変換式は最新がいちばん上で ↓ が古いほう
public struct CandidateSession: Equatable, Sendable {
    /// 画面上の向き
    public enum Direction: Sendable {
        case up
        case down
    }

    public let items: [ClipItem]
    public let order: CandidateOrder
    public private(set) var index = 0

    public init(items: [ClipItem], order: CandidateOrder) {
        self.items = items
        self.order = order
    }

    public var isEmpty: Bool { items.isEmpty }
    public var selected: ClipItem? { items.indices.contains(index) ? items[index] : nil }

    /// 画面の上から下への並び（`items` の添字）
    public var visualOrder: [Int] {
        order == .terminal ? Array(items.indices.reversed()) : Array(items.indices)
    }

    /// 画面の上から数えた行の番号
    public func visualRow(ofIndex index: Int) -> Int {
        order == .terminal ? items.count - 1 - index : index
    }

    public func index(ofVisualRow row: Int) -> Int {
        order == .terminal ? items.count - 1 - row : row
    }

    public var selectedVisualRow: Int { visualRow(ofIndex: index) }

    /// 1 つ動かす。端で動けなければ false（窓を揺らす）
    @discardableResult
    public mutating func move(_ direction: Direction) -> Bool {
        let older = (direction == .up) == (order == .terminal)
        return select(index: index + (older ? 1 : -1))
    }

    @discardableResult
    public mutating func select(index newIndex: Int) -> Bool {
        guard items.indices.contains(newIndex) else { return false }
        index = newIndex
        return true
    }
}

/// 候補窓の寸法と、見えている行の範囲（純粋関数）。寸法は試作（`shared/candidate.css`）と同じ。
///
/// 一覧はスクロールの部品を使わず、選んでいる行が見える 8 行を自分で切り出して描く（描画の検証で結果が揺れないように）。
/// 窓の位置は `PanelPlacement.frame(... side: .beside(rowOffset:))` に `rowOffset(visibleRow:)` を渡し、
/// 選んでいる行の中心をカーソルの行の中心にそろえる
public enum CandidateLayout {
    public static let width: CGFloat = 372
    /// 窓の内側の余白（`.mk-cand { padding: 6px }`）
    public static let padding: CGFloat = 6
    public static let rowHeight: CGFloat = 30
    /// 行の間（`.cd-list { gap: 1px }`）
    public static let rowGap: CGFloat = 1
    /// 一度に見せる行（`.cd-list { max-height: calc(31px * 8) }`）
    public static let maxVisibleRows = 8
    /// 履歴が 0 件のときの案内の高さ（`.cd-empty { padding: 16px 10px }` + 1 行）
    public static let emptyHeight: CGFloat = 50
    /// 注記（`.cd-note { margin: 6px 2px 0; padding: 7px 9px }` + 1 行。11.5px × 1.5）
    public static let noteHeight: CGFloat = 6 + 7 + 17.25 + 7
    /// 秘密の注記（同じ形で 2 行。「隠した項目は、確定したときだけ貼ります。⌥ を押している間は中身を表示します。」）
    public static let secretNoteHeight: CGFloat = 6 + 7 + 17.25 * 2 + 7
    /// 下段のキーのヒント（`.cd-foot { margin-top: 6px; padding: 7px 4px 1px; border-top: .5px }` + キー 18px）
    public static let footerHeight: CGFloat = 6 + 0.5 + 7 + 18 + 1

    /// 見えている行の先頭。試作と同じく、毎回いちばん上から選んでいる行が見えるところまで送る
    /// （試作は動かすたびに一覧を描き直して scrollTop 0 から scrollIntoView の nearest で送るため）。
    /// なので選んでいる行が 8 行目より下にあれば、いつも見えている範囲のいちばん下に来る。ターミナル式では
    /// 最新から ↑ でたどる間、窓は動かずに一覧だけが流れ、選んでいる行がカーソルの行にとどまる
    public static func firstVisibleRow(selectedRow: Int, rowCount: Int) -> Int {
        let visible = min(rowCount, maxVisibleRows)
        guard visible > 0 else { return 0 }
        return min(max(0, selectedRow - visible + 1), rowCount - visible)
    }

    public static func visibleRowCount(_ rowCount: Int) -> Int {
        min(rowCount, maxVisibleRows)
    }

    /// 行の部分の高さ
    public static func listHeight(rowCount: Int) -> CGFloat {
        let rows = visibleRowCount(rowCount)
        guard rows > 0 else { return emptyHeight }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
    }

    /// 窓の高さ（8 行で 291.5。試作の実測と同じ）
    public static func windowHeight(rowCount: Int, hasNote: Bool) -> CGFloat {
        windowHeight(rowCount: rowCount, noteHeight: hasNote ? noteHeight : 0)
    }

    /// 注記の高さを渡す形（秘密の注記は 2 行）
    public static func windowHeight(rowCount: Int, noteHeight: CGFloat) -> CGFloat {
        padding * 2 + listHeight(rowCount: rowCount) + noteHeight + footerHeight
    }

    /// 窓の上端から、見えている行のうち `visibleRow` 番目の中心までの距離
    public static func rowOffset(visibleRow: Int) -> CGFloat {
        padding + CGFloat(visibleRow) * (rowHeight + rowGap) + rowHeight / 2
    }

    /// 0 件のときは案内の中心をカーソルの行にそろえる
    public static var emptyRowOffset: CGFloat { padding + emptyHeight / 2 }
}

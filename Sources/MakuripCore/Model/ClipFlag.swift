/// 履歴 1 件に付ける印。後のフェーズで増える前提なので、閉じた enum にせず文字列の開いた集合にしてある。
///
/// DB には JSON 配列（文字列の並び）で入る。知らない値も消さずに読み書きする（新しい版の印を古い版が落とさない）。
public struct ClipFlag: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ClipFlag, rhs: ClipFlag) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// サイズ上限を超えた型を落として保存した（貼り直すと一部の形式が欠ける）
    public static let truncated = ClipFlag(rawValue: "truncated")
    /// 秘密っぽい（API キー等）。判定はフェーズ5で入れる
    public static let secretLikely = ClipFlag(rawValue: "secretLikely")
    /// AI（CLI / MCP）から追加した。フェーズ6で入れる
    public static let addedByAI = ClipFlag(rawValue: "addedByAI")
}

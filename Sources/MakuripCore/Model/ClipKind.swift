/// 履歴 1 件の「何をコピーしたか」。判定は `KindClassifier`（純粋関数）が行う。
///
/// DB には `rawValue` で入る。並び順は絞り込み UI の既定の並びにも使う。
public enum ClipKind: String, Codable, Sendable, CaseIterable, Hashable {
    case text
    case richText
    case image
    case file
    case url
    case color
    case code
    case command
    case other

    /// 一覧・メニューに出す日本語の名前
    public var label: String {
        switch self {
        case .text: "テキスト"
        case .richText: "リッチテキスト"
        case .image: "画像"
        case .file: "ファイル"
        case .url: "URL"
        case .color: "色"
        case .code: "コード"
        case .command: "コマンド"
        case .other: "その他"
        }
    }

    /// 知らない値（新しい版で増えた種類など）を読んだときは `.other` に倒す
    public init(storedValue: String) {
        self = ClipKind(rawValue: storedValue) ?? .other
    }
}

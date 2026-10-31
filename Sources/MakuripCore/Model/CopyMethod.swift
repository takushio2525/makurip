/// 履歴 1 件の「どうコピーしたか」。判定は `CopyMethodClassifier`（純粋関数）が行う。
public enum CopyMethod: String, Codable, Sendable, CaseIterable, Hashable {
    /// ⌘C / ⌘X のキー操作でコピーした
    case keyboard
    /// それ以外（コピーボタン・メニュー・右クリック・アプリが自分で書いた等）
    case other
    /// 判定できなかった（キー監視の権限がない等）。「それ以外」と混ぜない
    case unknown

    public var label: String {
        switch self {
        case .keyboard: "キー操作"
        case .other: "それ以外"
        case .unknown: "不明"
        }
    }

    public init(storedValue: String) {
        self = CopyMethod(rawValue: storedValue) ?? .unknown
    }
}

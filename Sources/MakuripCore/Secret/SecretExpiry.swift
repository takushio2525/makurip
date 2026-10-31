import Foundation

/// 秘密の自動消去の決まり（純粋関数）。
///
/// - 対象は確度の高い秘密（`secretKnownFormat`）だけ。ランダムな文字列だけで判定したもの（確度は中）は、マスクするが消さない
///   （ID やファイル名を誤って秘密と判定しても、勝手に消えないように）
/// - ピン留めしたものは消さない（明示して残したもの。マスクは続ける）
/// - 時間は最後に使ってから（取り込み直し・Makurip からの貼り付けで延びる）。既定は 10 分（`defaultMinutes` の説明）
public enum SecretExpiry {
    /// 既定の時間（分）。パスワード管理アプリが「コピーしたものをクリップボードから消すまで」に使う時間
    /// （1Password は 90 秒、Bitwarden の選択肢は最大 5 分）より長く、キーを数か所に貼る作業（.env と CI の設定など）が
    /// 終わるくらいの長さにした。消えるのは Makurip の履歴だけで、元の場所とシステムのクリップボードには残る
    public static let defaultMinutes = 10
    public static let minimumMinutes = 1
    /// 1 日まで。それより長く残したいものはピン留めする
    public static let maximumMinutes = 1440

    public static func isEligible(_ item: ClipItem) -> Bool {
        item.flags.contains(.secretKnownFormat) && !item.isPinned
    }

    /// 消す時刻（対象でなければ nil）
    public static func deadline(of item: ClipItem, retention: TimeInterval) -> Date? {
        isEligible(item) ? item.lastUsedAt.addingTimeInterval(retention) : nil
    }

    /// 時間が来たもの
    public static func expired(_ items: [ClipItem], now: Date, retention: TimeInterval) -> [UUID] {
        items.filter { item in deadline(of: item, retention: retention).map { $0 <= now } ?? false }.map(\.id)
    }

    /// まだ時間が来ていないもののうち、いちばん早く消す時刻
    public static func nextDeadline(_ items: [ClipItem], now: Date, retention: TimeInterval) -> Date? {
        items.compactMap { deadline(of: $0, retention: retention) }.filter { $0 > now }.min()
    }
}

/// 判定の版が上がったとき（初めて入れたときを含む）、既存の履歴に 1 回だけ判定を当て直す
public enum SecretRescan {
    /// `ClipStore` の meta に、当て直した判定の版を書いておく
    public static let metaKey = "secretScanVersion"

    /// 版が古ければ当て直す。新しく秘密と判定した件数を返す（版が新しければ nil）。
    /// 印は足すだけで外さない（判定を直したときに、前に隠したものが急に見えるようにはしない）
    @discardableResult
    public static func runIfNeeded(store: ClipStore, limits: Limits = .default) throws -> Int? {
        let done = try store.metaValue(metaKey).flatMap(Int.init) ?? 0
        guard done < SecretDetector.version else { return nil }
        var found = 0
        for item in try store.items() {
            guard let snapshot = try store.snapshot(id: item.id, types: SecretScanner.textTypes),
                let assessment = SecretScanner.assess(snapshot)
            else { continue }
            let preview = PreviewText.make(
                for: snapshot, kind: item.kind, limit: limits.previewCharacterLimit, maskSecrets: true)
            try store.addFlags(assessment.flags, maskedPreview: preview, id: item.id)
            found += 1
        }
        try store.setMetaValue(String(SecretDetector.version), for: metaKey)
        return found
    }
}

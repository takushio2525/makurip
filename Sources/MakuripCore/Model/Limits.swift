/// 保存の上限。既定値はここだけに書く。変更の UI はフェーズ4（設定画面）で作る
public struct Limits: Sendable, Codable, Hashable {
    /// 保存する件数の上限（ピン留めは数えない・消さない）
    public var maxItems: Int
    /// 全履歴の合計バイト数の上限（ピン留めは数えない）。超えたら古い順に消す
    public var maxTotalBytes: Int
    /// 型 1 つのデータの上限。超えた型は落とす（他の型は残し、`truncated` の印を付ける）
    public var maxRepresentationBytes: Int
    /// 1 件（1 回のコピー）の合計の上限。超えたら大きい型から落とす
    public var maxClipBytes: Int
    /// これより大きいデータは DB に入れずディスクの別ファイルに置く
    public var inlineThresholdBytes: Int
    /// 一覧・絞り込み用に持つ平文の長さ（文字数）
    public var previewCharacterLimit: Int

    public init(
        maxItems: Int, maxTotalBytes: Int, maxRepresentationBytes: Int, maxClipBytes: Int,
        inlineThresholdBytes: Int, previewCharacterLimit: Int
    ) {
        self.maxItems = maxItems
        self.maxTotalBytes = maxTotalBytes
        self.maxRepresentationBytes = maxRepresentationBytes
        self.maxClipBytes = maxClipBytes
        self.inlineThresholdBytes = inlineThresholdBytes
        self.previewCharacterLimit = previewCharacterLimit
    }

    public static let `default` = Limits(
        maxItems: 1000,
        maxTotalBytes: 1024 * 1024 * 1024,
        maxRepresentationBytes: 50 * 1024 * 1024,
        maxClipBytes: 100 * 1024 * 1024,
        inlineThresholdBytes: 64 * 1024,
        previewCharacterLimit: 1000
    )
}

import CoreGraphics

/// メニューバーの状態の項目（アイコン）の置き場所。
///
/// macOS は新しく作られた状態の項目をいちばん左に置く。ノッチのある内蔵画面でメニューバーが混んでいると、
/// ノッチの裏や左へ押し出されて描かれない（#35）。そこで、保存位置（UserDefaults の
/// `NSStatusItem Preferred Position <保存名>`）がまだ無いときだけ、項目を作る前に `seedPosition` を書いて
/// 「保存位置のない他社アプリの項目の右・システムの項目の左」に置く。
/// 利用者が ⌘ を押しながらドラッグして動かすと macOS がこの鍵を書き換えるので、以後はそちらを使う。
public enum StatusItemPlacement {
    /// 本番の保存名
    public static let autosaveName = "MakuripStatusItem"
    /// 隔離したインスタンスの保存名。UserDefaults はバンドル ID ごとなので `--data-dir` では分かれない。
    /// 名前を分けて、検証で本番の項目の位置を書き換えない
    public static let isolatedAutosaveName = "MakuripStatusItemIsolated"
    /// 種まきする値。値が大きいほど左に並ぶ。システムの項目は 100〜400 台で、500 以上はどれも
    /// 「保存位置のない項目の右・システムの項目の左」に入った（macOS 26 の実測。#35）
    public static let seedPosition: Double = 1000

    public static func autosaveName(isolated: Bool) -> String {
        isolated ? isolatedAutosaveName : autosaveName
    }

    /// AppKit が保存名ごとの位置を読み書きする UserDefaults の鍵
    public static func preferredPositionKey(autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// 項目を作る前に書く値。保存位置がもうある（利用者が動かした・前に種をまいた）なら nil にして触らない
    public static func positionToSeed(saved: Any?) -> Double? {
        saved == nil ? seedPosition : nil
    }

    public enum Visibility: String, Sendable {
        /// ノッチの右の領域に収まっている
        case visible
        /// ノッチにかかっているか、その左にある（macOS はこの項目を描かない）
        case behindNotch
        /// ノッチのない画面・窓がまだない。位置だけでは決められない
        case unknown
    }

    /// 項目の窓が見える位置にあるか。`rightOfNotchWidth` は画面の `auxiliaryTopRightArea` の幅
    /// （ノッチの右端から画面の右端まで。ノッチのない画面は nil）。
    /// 遮蔽状態（`occlusionState`）は画面ロック中に見えている項目でも「見えない」になるので使わない
    public static func visibility(itemFrame: CGRect?, screenFrame: CGRect?, rightOfNotchWidth: CGFloat?) -> Visibility {
        guard let itemFrame, let screenFrame, let width = rightOfNotchWidth, width > 0, !itemFrame.isEmpty else {
            return .unknown
        }
        let visibleMinX = screenFrame.maxX - width
        return itemFrame.minX >= visibleMinX && itemFrame.maxX <= screenFrame.maxX ? .visible : .behindNotch
    }
}

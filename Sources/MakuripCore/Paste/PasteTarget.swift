import Foundation

/// 一覧から貼るときの宛先（純粋関数。#27）
public enum PasteTarget {
    /// 一覧を開いたときの貼り付けの宛先（pid）。前面が Makurip 自身（定型文の窓・設定画面）なら nil（宛先なし）。
    ///
    /// 宛先は一覧を開くたびに決め直し、前に開いたときの宛先を引き継がない。引き継ぐと、自分の窓から ⌃⌘V で一覧を開いて
    /// 貼ったとき、前に使った別のアプリが前面に出て、その入力欄へ ⌘V が飛ぶ。宛先なしのときは貼らずにコピーだけにし、
    /// 閉じても別のアプリへ切り替えない
    public static func pid(frontmost: pid_t?, own: pid_t) -> pid_t? {
        guard let frontmost, frontmost != own else { return nil }
        return frontmost
    }
}

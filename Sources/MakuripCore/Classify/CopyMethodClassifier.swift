import Foundation

/// 「どうコピーしたか」の判定（純粋関数）。
///
/// しくみ: アプリ側のキー監視が ⌘C / ⌘X を見たら時刻を記録し（`CopyShortcutSignal`）、
/// ペーストボードの変化を見つけた時刻との差が `window` 以内ならキー操作、そうでなければそれ以外とする。
/// 1 回の ⌘C は 1 回の変化にしか使わない（使った信号は監視側で捨てる）。
///
/// 限界（`.agent/conventions.md` にも書いてある）:
/// - ⌘C を押したが何もコピーされず、直後（`window` 以内）にボタンでコピーすると「キー操作」になる
/// - ⌘C から `window` より遅れてペーストボードに書くアプリは「それ以外」になる
/// - キー監視が効かない（アクセシビリティ未許可・セキュア入力中）ときは「不明」
/// - 他のプロセスが `postToPid` で送ったキー（自動操作）は監視に見えないので「それ以外」になる
public enum CopyMethodClassifier {
    /// 既定の窓。監視の間隔（0.25 秒）に、書き込みの遅いアプリのための余裕を足したもの
    public static let defaultWindow: TimeInterval = 1.0
    /// 時計の揺れ（信号の時刻が変化の検出より少し後になる）を許す幅
    static let clockTolerance: TimeInterval = 0.05

    public static func classify(
        changeDetectedAt: Date,
        lastShortcutAt: Date?,
        keyMonitorActive: Bool,
        window: TimeInterval = defaultWindow
    ) -> CopyMethod {
        guard keyMonitorActive else { return .unknown }
        guard let shortcut = lastShortcutAt else { return .other }
        let elapsed = changeDetectedAt.timeIntervalSince(shortcut)
        guard elapsed >= -clockTolerance, elapsed <= window else { return .other }
        return .keyboard
    }
}

/// キー監視が見た ⌘C / ⌘X 1 回分
public struct CopyShortcutSignal: Sendable, Hashable {
    public var at: Date
    /// 押した瞬間に前面にあったアプリ（コピー元の記録に使う。変化の検出時より正確）
    public var frontmostApp: SourceApp?

    public init(at: Date, frontmostApp: SourceApp?) {
        self.at = at
        self.frontmostApp = frontmostApp
    }
}

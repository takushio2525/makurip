import Foundation
import Testing

@testable import MakuripCore

@Suite("コピー方法の判定")
struct CopyMethodClassifierTests {
    let detected = Date(timeIntervalSince1970: 1_000_000)

    @Test("⌘C の直後の変化はキー操作")
    func keyboardWithinWindow() {
        for delay in [0.0, 0.02, 0.25, 0.9, 1.0] {
            let method = CopyMethodClassifier.classify(
                changeDetectedAt: detected, lastShortcutAt: detected.addingTimeInterval(-delay), keyMonitorActive: true)
            #expect(method == .keyboard, "delay=\(delay)")
        }
    }

    @Test("⌘C から時間が空いた変化はそれ以外（コピーボタン等）")
    func otherOutsideWindow() {
        for delay in [1.01, 3, 60] {
            let method = CopyMethodClassifier.classify(
                changeDetectedAt: detected, lastShortcutAt: detected.addingTimeInterval(-delay), keyMonitorActive: true)
            #expect(method == .other, "delay=\(delay)")
        }
    }

    @Test("⌘C を見ていない変化はそれ以外")
    func otherWithoutShortcut() {
        #expect(
            CopyMethodClassifier.classify(changeDetectedAt: detected, lastShortcutAt: nil, keyMonitorActive: true)
                == .other)
    }

    @Test("キー監視が効いていないときは不明（それ以外と混ぜない）")
    func unknownWithoutMonitor() {
        #expect(
            CopyMethodClassifier.classify(changeDetectedAt: detected, lastShortcutAt: detected, keyMonitorActive: false)
                == .unknown)
        #expect(
            CopyMethodClassifier.classify(changeDetectedAt: detected, lastShortcutAt: nil, keyMonitorActive: false)
                == .unknown)
    }

    @Test("信号が変化の検出より少しだけ後（時計の揺れ）ならキー操作、大きく後ならそれ以外")
    func futureSignal() {
        #expect(
            CopyMethodClassifier.classify(
                changeDetectedAt: detected, lastShortcutAt: detected.addingTimeInterval(0.03), keyMonitorActive: true)
                == .keyboard)
        #expect(
            CopyMethodClassifier.classify(
                changeDetectedAt: detected, lastShortcutAt: detected.addingTimeInterval(0.5), keyMonitorActive: true)
                == .other)
    }
}

import AppKit
import ApplicationServices
import MakuripCore

/// 元いたアプリへフォーカスを返して ⌘V を送る。
///
/// ⌘V は `CGEvent.postToPid` で**そのアプリの pid に**送る（いま前面にある別の窓に誤って入らないように）。
/// キーイベントを送るにはアクセシビリティの許可が要る。許可がなければ送らず、ペーストボードに載せるだけにする。
@MainActor
final class Paster {
    enum Outcome: String {
        case pasted
        /// 許可がないので ⌘V は送っていない（ペーストボードには載っている）
        case noPermission
        /// 戻す先のアプリがない（終了した等）
        case noTarget
    }

    /// 仮想キーコードの V（US/JIS 配列とも同じ位置）
    private static let keyCodeV: CGKeyCode = 9

    func paste(into target: NSRunningApplication?) async -> Outcome {
        guard AXIsProcessTrusted() else { return .noPermission }
        guard let target, !target.isTerminated else { return .noTarget }

        target.activate()
        // 前面に来るまで少し待つ（最大 0.6 秒）。来なくても宛先は pid なので、そのアプリにだけ届く
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // キーウィンドウが戻るまでの猶予
        try? await Task.sleep(for: .milliseconds(60))
        Self.postCommandV(to: target.processIdentifier)
        return .pasted
    }

    static func postCommandV(to pid: pid_t) {
        post(.paste, to: pid)
    }

    /// pid 宛てにキーを送る（前面のアプリを activate しない。候補窓の仮貼り・差し替え・取り消しもここから送る）。
    /// Makurip が送った印（`SyntheticEventMarker`）を付け、候補窓の横取りが自分のキーを拾わないようにする
    static func post(_ key: SyntheticKey, to pid: pid_t) {
        let (code, flags, character): (CGKeyCode, CGEventFlags, UniChar?) =
            switch key {
            case .paste: (keyCodeV, .maskCommand, 0x76)  // ⌘V（"v"）
            case .undo: (6, .maskCommand, 0x7A)  // ⌘Z（"z"）
            case .redo: (6, [.maskCommand, .maskShift], 0x5A)  // ⌘⇧Z（"Z"）
            case .deleteBackward: (51, [], nil)  // ⌫
            }
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else {
                continue
            }
            event.flags = flags
            if let character { event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [character]) }
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.userData)
            event.postToPid(pid)
        }
    }
}

import AppKit
import ApplicationServices
import MakuripCore

/// 他のアプリで押された ⌘C / ⌘X を見張る（コピー方法の判定用）。
///
/// `NSEvent.addGlobalMonitorForEvents` を使う。キーのイベントを見るにはアクセシビリティの許可が要る
/// （貼り付けの ⌘V 送信にも同じ許可が要るので、ユーザーに頼む許可は 1 つで済む）。
/// 見るだけで横取りはしない。押されたキーの文字は記録しない（⌘C / ⌘X かどうかだけを見る）。
@MainActor
final class CopyShortcutDetector {
    private var monitor: Any?
    private var trustTimer: Timer?
    private let onShortcut: (CopyShortcutSignal) -> Void

    init(onShortcut: @escaping (CopyShortcutSignal) -> Void) {
        self.onShortcut = onShortcut
    }

    /// 許可があってキー監視が効いているか。false の間のコピー方法は「不明」になる
    var isActive: Bool { monitor != nil && AXIsProcessTrusted() }

    func start() {
        installIfTrusted()
        // 起動後に許可された場合に備えて、許可が出るまで数秒おきに見直す（許可が出たら付け直す）
        trustTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfTrusted() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func installIfTrusted() {
        let trusted = AXIsProcessTrusted()
        if trusted, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isCopy = Self.isCopyShortcut(event)
                guard isCopy else { return }
                let now = Date()
                let front = NSWorkspace.shared.frontmostApplication
                let app = front.map { SourceApp(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
                MainActor.assumeIsolated { self?.onShortcut(CopyShortcutSignal(at: now, frontmostApp: app)) }
            }
            Log.app.info("⌘C の監視を開始")
        } else if !trusted, let current = monitor {
            NSEvent.removeMonitor(current)
            monitor = nil
        }
    }

    /// ⌘C / ⌘X か（⇧・⌥ が一緒でもよい。⌃ が一緒のものは別の操作とみなす）
    nonisolated static func isCopyShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !event.isARepeat else { return false }
        // 物理位置（US/JIS 配列の C=8, X=7）か、配列を反映した文字で見る（Dvorak などでも拾う）
        if event.keyCode == 8 || event.keyCode == 7 { return true }
        let character = event.charactersIgnoringModifiers?.lowercased()
        return character == "c" || character == "x"
    }
}

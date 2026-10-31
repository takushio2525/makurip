import AppKit
import MakuripCore

/// 候補窓が出ている間だけ、↑↓・Tab・Enter・Esc を横取りする CGEventTap（能動のタップ。アクセシビリティの許可が要る）。
///
/// 外し忘れると、全アプリで ↑↓・Tab・Enter・Esc が効かなくなる。そこで次のように作ってある（`.agent/conventions.md`）:
/// - 始めるのは `CandidateCoordinator.start` だけ。閉じる経路はすべて `stop()` を呼ぶ（単体テストで全経路を確かめている）
/// - システムに止められたら（応答が遅い `tapDisabledByTimeout`・`tapDisabledByUserInput`）付け直さず、外して候補窓を閉じる
/// - Makurip が落ちたときは、タップはプロセスと一緒に OS が消す（タップの mach port はプロセスに属する）
/// - Makurip が送ったキー（`SyntheticEventMarker` の印付き）は見ずに素通しする
@MainActor
final class KeyEventTap: KeyEventTapping {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((KeyTapEvent) -> KeyTapDecision)?
    private(set) var isActive = false

    func start(_ handler: @escaping @MainActor (KeyTapEvent) -> KeyTapDecision) -> Bool {
        stop()
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: keyEventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        self.handler = handler
        isActive = true
        return true
    }

    func stop() {
        guard let port else { return }
        isActive = false
        handler = nil
        // その場で無効にする（この後のキーは前面のアプリへ素通し）
        CGEvent.tapEnable(tap: port, enable: false)
        let source = self.source
        self.port = nil
        self.source = nil
        // タップの中（確定のキーを受けたとき）から呼ばれることがあるので、片付けは今のイベントを返し終えてから
        DispatchQueue.main.async {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(port)
        }
    }

    /// 食べるなら true
    fileprivate func receive(_ input: KeyTapInput) -> Bool {
        switch input {
        case .disabled:
            let handler = self.handler
            stop()
            _ = handler?(.disabled)
            return false
        case .synthetic, .ignored:
            return false
        case .event(let event):
            guard isActive, let handler else { return false }
            return handler(event) == .consume
        }
    }
}

/// タップの C の入口。run loop は main に付けたので、ここはメインスレッドで呼ばれる
private func keyEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    let input = KeyTapInput.make(type: type, event: event)
    let consume = MainActor.assumeIsolated { tap.receive(input) }
    return consume ? nil : Unmanaged.passUnretained(event)
}

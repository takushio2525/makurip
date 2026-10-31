import CoreGraphics

/// 横取りのタップに届いた CGEvent を、値だけにしたもの（CGEvent はメインアクターへ渡せないので、タップの入口で先に読み取る）
public enum KeyTapInput: Sendable, Equatable {
    /// システムがタップを止めた（応答が遅い・ユーザーの操作で無効）
    case disabled
    /// Makurip が送ったキー（`SyntheticEventMarker` の印付き）。見ずに素通しする
    case synthetic
    case event(KeyTapEvent)
    /// 見ない種類のイベント
    case ignored

    public static func make(type: CGEventType, event: CGEvent) -> KeyTapInput {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return .disabled }
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.userData { return .synthetic }
        switch type {
        case .keyDown: return .event(.keyDown(stroke(event)))
        case .keyUp: return .event(.keyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode))))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .event(.mouseDown(event.location))
        case .flagsChanged: return .event(.flagsChanged(stroke(event).modifiers))
        default: return .ignored
        }
    }

    /// 修飾キーは ⌃⌥⇧⌘ だけを見る（矢印キーに付くテンキー・fn の印や Caps Lock は見ない）
    public static func stroke(_ event: CGEvent) -> KeyStroke {
        var modifiers: HotKey.Modifiers = []
        let flags = event.flags
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return KeyStroke(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers)
    }
}

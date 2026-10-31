import Carbon.HIToolbox
import MakuripCore

/// グローバルショートカットの登録（Carbon `RegisterEventHotKey`）。
///
/// 選んだ理由: Apple 純正・権限が要らない・任意のキー組み合わせを登録できる（フェーズ4のキー割り当てに
/// そのまま使える）・押したキーが前面のアプリに届かない（横取りできる）。比べた代替は `.agent/architecture.md`。
@MainActor
final class HotKeyCenter {
    enum Action: UInt32 {
        case openHistory = 1
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// 登録に成功した組み合わせ（検証の状態出力に使う）
    private(set) var registered: [Action: HotKey] = [:]

    /// 失敗（他のアプリが同じキーを使っている等）なら false
    @discardableResult
    func register(_ hotKey: HotKey, for action: Action, handler: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D4B_5250), id: action.rawValue)  // 'MKRP'
        let status = RegisterEventHotKey(
            hotKey.keyCode, Self.carbonModifiers(hotKey.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.app.error("ホットキーの登録に失敗: \(hotKey.displayString, privacy: .public) status=\(status)")
            return false
        }
        refs[action.rawValue] = ref
        handlers[action.rawValue] = handler
        registered[action] = hotKey
        return true
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
        handlers[action.rawValue] = nil
        registered[action] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let hotKeyID = id.id
                // Carbon のイベントはメインスレッドの run loop で届く
                MainActor.assumeIsolated { center.fire(hotKeyID) }
                return noErr
            }, 1, &spec, context, &eventHandler)
    }

    static func carbonModifiers(_ modifiers: HotKey.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

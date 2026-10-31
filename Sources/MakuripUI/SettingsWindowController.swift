import AppKit
import MakuripCore
import SwiftUI
import UniformTypeIdentifiers

/// 設定画面の入口（本体は `SettingsController` と、本体の状態を聞く `SettingsEnvironment` を渡す）
public enum SettingsUIFactory {
    @MainActor
    public static func make(controller: SettingsController, environment: SettingsEnvironment) -> SettingsPresenting {
        SettingsWindowController(controller: controller, environment: environment)
    }
}

/// 設定窓。ふつうの窓（Makurip を前面にする）。キーは窓のローカル監視で受けて `SettingsModel.handle` に渡す（試作と同じ操作）。
///
/// - 枠は本物の窓（信号機のボタン）。中身を窓の上まで広げ、試作の 44pt のバー（題名）を SwiftUI で描く
/// - 数を打ち込んでいる間は、↩ と esc 以外を入力欄に渡す
/// - キーを記録している間は、本体がどこからでも効くキーを外す（`SettingsEnvironment.recordingDidChange`）
@MainActor
final class SettingsWindowController: NSObject, SettingsPresenting, NSWindowDelegate {
    let model: SettingsModel
    private let window: NSWindow
    private var keyMonitor: Any?

    init(controller: SettingsController, environment: SettingsEnvironment) {
        model = SettingsModel(controller: controller, environment: environment)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsCSS.width, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Makurip 設定"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: SettingsCSS.width, height: 420)
        window.contentMaxSize = NSSize(width: SettingsCSS.width, height: 4000)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.setFrameAutosaveName("MakuripSettings")
        model.effects = SettingsModel.Effects(
            close: { [weak self] in self?.close() },
            pickApp: { [weak self] id in self?.pickApp(for: id) })
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        if !window.isVisible { model.open() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        window.close()
    }

    func environmentDidChange() {
        model.environmentDidChange()
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
        model.cancelEditing()
        removeKeyMonitor()
    }

    // MARK: キー

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.windowNumber == self.window.windowNumber else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let press = PanelController.keyPress(event)
        // 修飾キーの押し離しは、押している間だけ効くキー（隠した内容の表示）を記録している間だけ使う
        if event.type == .flagsChanged {
            if model.recording { model.recordModifier(press.modifiers) }
            return false
        }
        if model.editingID != nil {
            if press.modifiers.isEmpty, press.keyCode == KeyCodes.escape {
                model.cancelEditing()
                return true
            }
            // ↩ は入力欄の onSubmit が受ける。⌘A・⌘C・⌘V などはメインメニューがないのでここで送る
            return performEditCommand(press)
        }
        return model.handle(press)
    }

    private func performEditCommand(_ press: KeyStroke) -> Bool {
        guard press.modifiers == .command else { return false }
        let selector: Selector? =
            switch press.keyCode {
            case 0: #selector(NSText.selectAll(_:))
            case 8: #selector(NSText.copy(_:))
            case 9: #selector(NSText.paste(_:))
            case 7: #selector(NSText.cut(_:))
            default: nil
            }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: window)
    }

    // MARK: アプリを選ぶ

    /// 動いているアプリの一覧から選ぶ。一覧にないものは「その他…」でアプリのファイルを選ぶ
    private func pickApp(for id: String) {
        model.select(id)
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            let item = NSMenuItem(
                title: app.localizedName ?? bundleID, action: #selector(choseApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [id, bundleID]
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "その他…", action: #selector(choseOther(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = id
        menu.addItem(other)
        let point = window.mouseLocationOutsideOfEventStream
        menu.popUp(positioning: nil, at: point, in: window.contentView)
    }

    @objc private func choseApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        model.addApp(pair[0], bundleID: pair[1])
    }

    @objc private func choseOther(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "追加"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else {
                    return
                }
                self?.model.addApp(id, bundleID: bundleID)
            }
        }
    }
}

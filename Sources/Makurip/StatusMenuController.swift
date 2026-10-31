import AppKit
import MakuripCore

/// メニューバーのアイコンとメニュー。アイコンは仮（SF Symbol）。本物は「メモをめくる」イメージでフェーズ2で差し替える
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: AppIdentity.displayName)
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppIdentity.displayName
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// 許可がなく貼り付けられなかったことを、アイコンで短く知らせる
    func flashPermissionNeeded() {
        guard let button = statusItem.button else { return }
        button.appearsDisabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = controller?.isPaused ?? false
    }

    private func rebuild() {
        menu.removeAllItems()
        guard let controller else { return }

        let open = addItem("履歴を開く", action: #selector(openHistory))
        let hotKey = HotKey.defaultOpenHistory
        open.keyEquivalent = "v"
        open.keyEquivalentModifierMask = [.control, .command]
        open.toolTip = hotKey.displayString

        menu.addItem(.separator())
        addItem(controller.isPaused ? "記録を再開" : "記録を一時停止", action: #selector(togglePause))
        addItem("履歴を消去…", action: #selector(clearHistory))

        menu.addItem(.separator())
        if !controller.isAccessibilityTrusted {
            addItem("アクセシビリティを許可…（貼り付けとコピー方法の記録に必要）", action: #selector(requestAccessibility))
        }
        var status = "履歴 \(controller.itemCount) 件"
        if controller.isPaused { status += "・一時停止中" }
        if controller.isolated { status += "・検証用フォルダ" }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())
        let quit = addItem("\(AppIdentity.displayName) を終了", action: #selector(quit))
        quit.keyEquivalent = "q"
        refreshIcon()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openHistory() {
        controller?.toggleHistory()
    }

    @objc private func togglePause() {
        guard let controller else { return }
        controller.setPaused(!controller.isPaused)
        refreshIcon()
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "履歴を消去しますか？"
        alert.informativeText = "ピン留めした項目は残ります。この操作は取り消せません。"
        alert.addButton(withTitle: "消去")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.clearHistory()
        }
    }

    @objc private func requestAccessibility() {
        controller?.requestAccessibility()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

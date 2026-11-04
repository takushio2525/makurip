import AppKit
import MakuripCore

/// メニューバーのアイコンとメニュー。アイコンは案 B「パラパラ」のテンプレート画像（Resources/Assets.xcassets の MenuBarIcon）。
/// 置き場所は `StatusItemPlacement`、メニューの項目の並びは `StatusMenuModel`（どちらも Core の純粋関数）
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var controller: AppController?
    /// 今回の起動で保存位置の種をまいたか（ログ・状態出力用）
    private(set) var seededPosition = false

    init(controller: AppController) {
        self.controller = controller
        // 保存位置がまだ無ければ、作る前に種をまく（混んだメニューバーでノッチの左へ押し出されないように。#35）
        let name = StatusItemPlacement.autosaveName(isolated: controller.isolated)
        let key = StatusItemPlacement.preferredPositionKey(autosaveName: name)
        if let seed = StatusItemPlacement.positionToSeed(saved: UserDefaults.standard.object(forKey: key)) {
            UserDefaults.standard.set(seed, forKey: key)
            seededPosition = true
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = name
        super.init()
        if let button = statusItem.button {
            button.image = Self.makeStatusIcon()
            button.toolTip = AppIdentity.displayName
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuild()
        // 置かれた位置は少し後に決まる。見える位置かをメタデータだけログに残す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.logPlacement() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// .app の Assets.car にある MenuBarIcon（16pt のテンプレート画像。@1x は画素にそろえた専用版）を使う。
    /// .app に入れずに実行したとき（swift run など）は Assets.car がないので、SF Symbol で代える
    private static func makeStatusIcon() -> NSImage? {
        let image =
            NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = AppIdentity.displayName
        return image
    }

    /// 項目がノッチの裏に隠れていないか（検証の状態出力にも使う）
    var visibility: StatusItemPlacement.Visibility {
        let window = statusItem.button?.window
        return StatusItemPlacement.visibility(
            itemFrame: window?.frame, screenFrame: window?.screen?.frame,
            rightOfNotchWidth: window?.screen?.auxiliaryTopRightArea?.width)
    }

    private func logPlacement() {
        let state = visibility
        let x = statusItem.button?.window.map { Int($0.frame.minX) } ?? -1
        if state == .behindNotch {
            Log.app.error(
                "メニューバーの項目がノッチの裏に隠れている x=\(x) seeded=\(self.seededPosition)。⌘ を押しながらドラッグして右へ移すか、もう一度開くと設定が開く"
            )
        } else {
            Log.app.info(
                "メニューバーの項目 visibility=\(state.rawValue, privacy: .public) x=\(x) seeded=\(self.seededPosition)")
        }
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
        let state = StatusMenuModel.State(
            appName: AppIdentity.displayName, paused: controller.isPaused,
            accessibilityTrusted: controller.isAccessibilityTrusted, itemCount: controller.itemCount,
            isolated: controller.isolated, update: controller.updates?.status)
        for entry in StatusMenuModel.entries(state) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .info(let text):
                let line = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            case .item(let model):
                let item = NSMenuItem(title: model.title, action: #selector(performCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model.command.rawValue
                item.isEnabled = model.enabled
                if let action = model.key {
                    Self.setKeyEquivalent(item, controller.keymap.primary(action))
                }
                if model.command == .quit { item.keyEquivalent = "q" }
                menu.addItem(item)
            }
        }
        refreshIcon()
    }

    /// メニューの右に出すキー。1 文字で書けるキー（英字・数字・記号）だけ。それ以外はヒントに表記を出す
    static func setKeyEquivalent(_ item: NSMenuItem, _ combo: KeyCombo?) {
        guard let combo else { return }
        item.toolTip = combo.displayString
        guard case .code = combo.key, combo.keySymbol.count == 1, let scalar = combo.keySymbol.unicodeScalars.first,
            scalar.isASCII
        else { return }
        item.keyEquivalent = combo.keySymbol.lowercased()
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.control) { flags.insert(.control) }
        if combo.modifiers.contains(.option) { flags.insert(.option) }
        if combo.modifiers.contains(.shift) { flags.insert(.shift) }
        if combo.modifiers.contains(.command) { flags.insert(.command) }
        item.keyEquivalentModifierMask = flags
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let controller, let raw = sender.representedObject as? String,
            let command = StatusMenuModel.Command(rawValue: raw)
        else { return }
        switch command {
        case .openList: controller.toggleHistory()
        case .openSnippetList: controller.openSnippetList()
        case .editSnippets: controller.openSnippetEditor(.open)
        case .openSettings: controller.openSettings()
        case .togglePause:
            controller.setPaused(!controller.isPaused)
            refreshIcon()
        case .clearHistory: confirmClearHistory()
        case .requestAccessibility: controller.requestAccessibility()
        case .installUpdate: controller.updates?.install(presentFailure: true)
        case .skipUpdate: controller.updates?.skip()
        case .checkForUpdates: controller.updates?.check(presentResult: true)
        case .quit: NSApp.terminate(nil)
        }
    }

    private func confirmClearHistory() {
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
}

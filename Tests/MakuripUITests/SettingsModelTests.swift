import Foundation
import MakuripCore
import Testing

@testable import MakuripUI

/// 一時フォルダ（設定ファイルを置く。本物のデータフォルダには触らない）
final class SettingsTempDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "makurip-ui-tests-\(UUID().uuidString)", isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// 設定画面のキー操作（モデルを直接駆動する。窓は作らない）
@MainActor
@Suite("設定画面の操作")
struct SettingsModelTests {
    let dir = SettingsTempDirectory()
    let controller: SettingsController
    let model: SettingsModel
    var closed = 0
    final class Box {
        var closed = 0
        var picked: [String] = []
        var recording: [Bool] = []
    }
    let box = Box()

    init() {
        controller = SettingsController(file: SettingsFile(directory: dir.url))
        let box = box
        model = SettingsModel(
            controller: controller,
            environment: SettingsEnvironment(
                appName: { $0 == "com.example.installed" ? "Installed" : nil },
                hotKeyRegistered: { $0 == .openList ? false : true },
                recordingDidChange: { box.recording.append($0) }))
        model.effects = SettingsModel.Effects(close: { box.closed += 1 }, pickApp: { box.picked.append($0) })
        model.open()
    }

    @discardableResult
    func press(_ code: UInt16, _ modifiers: HotKey.Modifiers = []) -> Bool {
        model.handle(KeyStroke(keyCode: code, modifiers: modifiers))
    }

    func select(_ id: String) {
        model.select(id)
    }

    @Test("並び: 動き → 履歴 → 定型文 → アプリごと → 詳細 → キーのまとまり。画面に出さない項目は除く")
    func sections() {
        #expect(
            model.sections.map(\.title) == [
                "動き", "履歴", "定型文", "アプリごと", "詳細", "呼び出す", "選ぶ・貼る", "絞り込み", "項目の操作", "候補窓",
            ])
        #expect(model.rowIDs.first == SettingID.hotKeyMode)
        #expect(!model.rowIDs.contains(SettingID.replaceMethod))
        #expect(model.sections.last?.note == "（候補窓が出ている間だけ効く）")
        #expect(model.rowIDs.count == SettingsSchema.items.count - 1)
    }

    @Test("↑↓ で選び、↩・→ で選択肢を進め、← で戻し、⌫ で初期値。ファイルにも書く")
    func choices() {
        #expect(model.selectedID == SettingID.hotKeyMode)
        press(KeyCodes.returnKey)
        #expect(controller.settings.hotKeyMode == .list)
        #expect(model.message == "「呼び出しキー（⌃⌘V）の動き」を「一覧を開く」にしました。")
        press(KeyCodes.rightArrow)  // 端で回る
        #expect(controller.settings.hotKeyMode == .pasteOnly)
        press(KeyCodes.leftArrow)
        #expect(controller.settings.hotKeyMode == .list)
        press(KeyCodes.delete)
        #expect(controller.settings.hotKeyMode == .candidate)
        #expect(model.message == "「呼び出しキー（⌃⌘V）の動き」を初期値に戻しました。")
        press(KeyCodes.downArrow)
        #expect(model.selectedID == SettingID.candidateOrder)
        #expect(model.message == nil)
        press(KeyCodes.upArrow)
        press(KeyCodes.upArrow)  // 端で止まる
        #expect(model.selectedID == SettingID.hotKeyMode)
        #expect(SettingsFile(directory: dir.url).load().settings.hotKeyMode == .candidate)
    }

    @Test("オン・オフと数（←→ で段ごと・↩ で打ち込み・範囲外は理由を出して打ち込みを続ける）")
    func togglesAndNumbers() {
        select(SettingID.launchAtLogin)
        press(KeyCodes.returnKey)
        #expect(controller.settings.launchAtLogin)
        select(SettingID.maxItems)
        press(KeyCodes.rightArrow)
        #expect(controller.settings.maxItems == 1100)
        press(KeyCodes.leftArrow)
        press(KeyCodes.leftArrow)
        #expect(controller.settings.maxItems == 900)
        press(KeyCodes.returnKey)
        #expect(model.editingID == SettingID.maxItems)
        #expect(model.editText == "900")
        model.editText = "5"
        model.commitEditing()
        #expect(model.editingID == SettingID.maxItems)
        #expect(model.message?.contains("10〜20000") == true)
        model.editText = "200件"
        model.commitEditing()
        #expect(model.editingID == nil)
        #expect(controller.settings.maxItems == 200)
        #expect(model.valueText(SettingID.maxItems) == "200 件")
        // 下限で止まる
        for _ in 0..<5 { press(KeyCodes.leftArrow) }
        #expect(controller.settings.maxItems == 10)
    }

    @Test("キーの記録: ↩ で始め、押したキーにする。重なった操作から外す（試作と同じ）")
    func recordKey() {
        select(SettingID.keys(.cycleMethod))
        press(KeyCodes.returnKey)
        #expect(model.recording)
        #expect(box.recording == [true])
        press(14, .command)  // ⌘E（「コピー元アプリを選ぶ」と重なる）
        #expect(!model.recording)
        #expect(box.recording == [true, false])
        #expect(controller.settings.keymap.primary(.cycleMethod)?.displayString == "⌘E")
        #expect(controller.settings.keymap.combos(for: .chooseApp).isEmpty)
        #expect(model.message == "「コピー方法を切り替え」を ⌘E にしました。重なっていた「コピー元アプリを選ぶ」からは外しました。")
        // 未設定は ⌫ で初期値へ
        select(SettingID.keys(.chooseApp))
        press(KeyCodes.delete)
        #expect(controller.settings.keymap.primary(.chooseApp)?.displayString == "⌘E")
        #expect(model.conflicts(.chooseApp) == [.cycleMethod])
        #expect(model.keyWarning(.chooseApp)?.contains("「コピー方法を切り替え」と重なっています") == true)
    }

    @Test("キーの記録: 使えないキーは理由を出して記録を続ける。esc で取り消す。番号は修飾キー + 数字")
    func recordRules() {
        select(SettingID.keys(.cycleMethod))
        press(KeyCodes.returnKey)
        press(40)  // K（修飾キーなし）
        #expect(model.recording)
        #expect(model.message?.contains("文字を打つキー") == true)
        #expect(controller.settings.keymap.primary(.cycleMethod)?.displayString == "⌘K")
        press(KeyCodes.escape)
        #expect(!model.recording)

        select(SettingID.keys(.quickPaste))
        press(KeyCodes.returnKey)
        press(19)  // 2 だけ
        #expect(model.message == "数字と一緒に ⌘ ⌃ ⌥ のどれかを押してください。")
        press(19, .control)  // ⌃2 → ⌃1–9
        #expect(controller.settings.keymap.primary(.quickPaste)?.displayString == "⌃1–9")

        // どこからでも効くキーは ⌃⌘V なども記録できる（記録の間は本体がホットキーを外す）
        select(SettingID.keys(.openHistory))
        press(KeyCodes.returnKey)
        press(9, .option)
        #expect(controller.settings.keymap.primary(.openHistory)?.displayString == "⌥V")
        // テンキーの Enter は ↩ として記録する
        select(SettingID.keys(.paste))
        press(KeyCodes.returnKey)
        press(KeyCodes.keypadEnter, .control)
        #expect(controller.settings.keymap.primary(.paste)?.displayString == "⌃↩")
    }

    @Test("登録できなかったどこからでも効くキーは注記を出す")
    func registrationWarning() {
        #expect(model.keyWarning(.openList)?.contains("登録できませんでした") == true)
        #expect(model.keyWarning(.openHistory) == nil)
    }

    @Test("アプリ: 記録しないアプリの足し外し。確定まで貼らないアプリは既定の一覧を外すと「すぐ貼る」を書く")
    func apps() {
        select(SettingID.excludedApps)
        press(KeyCodes.returnKey)
        #expect(box.picked == [SettingID.excludedApps])
        model.addApp(SettingID.excludedApps, bundleID: "com.example.installed")
        #expect(controller.settings.excludedApps == ["com.example.installed"])
        #expect(model.appEntries(SettingID.excludedApps).map(\.name) == ["Installed"])
        model.addApp(SettingID.excludedApps, bundleID: "COM.EXAMPLE.INSTALLED")
        #expect(model.message == "「Installed」はもう入っています。")
        model.removeApp(SettingID.excludedApps, bundleID: "com.example.installed")
        #expect(controller.settings.excludedApps.isEmpty)

        let id = SettingID.pasteTiming
        #expect(model.appEntries(id).count == DeferredPasteApps.all.count)
        #expect(model.appEntries(id).first?.name == "ターミナル")
        model.removeApp(id, bundleID: "com.apple.Terminal")
        #expect(controller.settings.pasteTiming == ["com.apple.Terminal": .immediate])
        #expect(!model.appEntries(id).contains { $0.bundleID == "com.apple.Terminal" })
        model.addApp(id, bundleID: "com.apple.Terminal")
        #expect(controller.settings.pasteTiming.isEmpty)
        model.addApp(id, bundleID: "com.example.chat")
        #expect(controller.settings.pasteTiming == ["com.example.chat": .onCommit])
        #expect(model.appEntries(id).last?.bundleID == "com.example.chat")
        model.addApp(id, bundleID: "com.tinyspeck.slackmacgap")
        #expect(model.message == "「Slack」はもう入っています。")
    }

    @Test("esc・⌘W・⌘, で閉じる。すべて初期値に戻す")
    func closeAndResetAll() throws {
        press(KeyCodes.escape)
        press(13, .command)
        press(KeyCodes.comma, .command)
        #expect(box.closed == 3)
        try controller.set(SettingID.maxItems, .int(300))
        model.resetAll()
        #expect(controller.settings == .default)
        #expect(model.message == "すべて初期値に戻しました。")
    }

    @Test("ほかから（CLI で）変わったら画面の値も変わる")
    func followsExternalChanges() throws {
        let cli = SettingsCLI(file: SettingsFile(directory: dir.url))
        #expect(cli.run(["set", "candOrder", "ime"]).exitCode == 0)
        controller.reload()
        #expect(model.settings.candidateOrder == .ime)
        #expect(model.currentChoice(SettingID.candidateOrder)?.label == "予測変換式")
    }
}

@MainActor
@Suite("パネルとキーの付け替え")
struct PanelKeymapTests {
    @Test("付け替えたキーで操作を引き、⌘, で設定を開く")
    func keymapChange() {
        let history = SampleHistory.make()
        let model = HistoryPanelModel(actions: history)
        var openedSettings = 0
        var closed = 0
        model.effects = HistoryPanelModel.Effects(close: { closed += 1 }, openSettings: { openedSettings += 1 })
        model.open()
        #expect(model.handle(KeyStroke(keyCode: KeyCodes.comma, modifiers: .command)))
        #expect(openedSettings == 1)

        var keymap = Keymap.default
        keymap.set([KeyCombo(.code(KeyCodes.escape), .control)], for: .close)
        model.keymap = keymap
        #expect(!model.handle(KeyStroke(keyCode: KeyCodes.escape)))
        #expect(model.handle(KeyStroke(keyCode: KeyCodes.escape, modifiers: .control)))
        #expect(closed == 1)
    }
}

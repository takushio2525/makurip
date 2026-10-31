import Foundation
import MakuripCore
import Observation

/// 設定画面の状態と操作（試作の `Mk.sheet`）。キーはすべて `handle` / `record` を通り、値は `SettingsController` を通して変える。
///
/// 画面（SwiftUI）と窓（`SettingsWindowController`）はこの状態を見るだけにして、操作の結果を単体テストで確かめられるようにしてある
@MainActor
@Observable
final class SettingsModel {
    struct Section: Identifiable {
        let id: String
        let title: String
        /// 見出しの横の注記（候補窓のキーは「候補窓が出ている間だけ効く」）
        let note: String?
        let itemIDs: [String]
    }

    /// アプリの項目に並べる 1 つ
    struct AppEntry: Identifiable, Equatable {
        let bundleID: String
        let name: String
        /// 既定の一覧（確定まで貼らないアプリ）から来たもの
        let builtIn: Bool
        var id: String { bundleID }
    }

    struct Effects {
        var close: () -> Void = {}
        /// アプリを選んで足す（窓が選ぶ画面を出し、選ばれたら `addApp` を呼ぶ）
        var pickApp: (String) -> Void = { _ in }
    }

    @ObservationIgnored let controller: SettingsController
    @ObservationIgnored var environment: SettingsEnvironment
    @ObservationIgnored var effects = Effects()
    @ObservationIgnored private var observer: UUID?

    private(set) var settings: AppSettings
    private(set) var issues: [SettingsError]
    let sections: [Section]
    /// 選べる行（項目の ID）の並び
    let rowIDs: [String]
    private(set) var selection = 0
    private(set) var recording = false {
        didSet {
            if recording != oldValue { environment.recordingDidChange(recording) }
        }
    }
    /// 数を打ち込んでいる項目
    private(set) var editingID: String?
    var editText = ""
    private(set) var message: String?
    /// 選んだ行が見える位置まで送る合図（値が変わるたびに）
    private(set) var scrollRequest = 0
    /// 本体の状態（ホットキーの登録など）が変わったら増やして描き直す
    private(set) var environmentRevision = 0

    init(controller: SettingsController, environment: SettingsEnvironment = SettingsEnvironment()) {
        self.controller = controller
        self.environment = environment
        settings = controller.settings
        issues = controller.issues
        var sections: [Section] = []
        for group in SettingsSchema.behaviorGroups {
            let ids = SettingsSchema.items.filter { $0.section == .behavior && $0.group == group && $0.shownInWindow }
                .map(\.id)
            if !ids.isEmpty { sections.append(Section(id: group, title: group, note: nil, itemIDs: ids)) }
        }
        var keyGroups: [String] = []
        for action in KeyAction.allCases where !keyGroups.contains(action.group) { keyGroups.append(action.group) }
        for group in keyGroups {
            let ids = KeyAction.allCases.filter { $0.group == group }.map(SettingID.keys)
            let note = group == KeyAction.candidateUp.group ? "（候補窓が出ている間だけ効く）" : nil
            sections.append(Section(id: "keys-" + group, title: group, note: note, itemIDs: ids))
        }
        self.sections = sections
        rowIDs = sections.flatMap(\.itemIDs)
        observer = controller.observe { [weak self] new, _ in
            self?.settings = new
            self?.issues = self?.controller.issues ?? []
        }
    }

    func detach() {
        if let observer { controller.removeObserver(observer) }
        observer = nil
    }

    var selectedID: String? { rowIDs.indices.contains(selection) ? rowIDs[selection] : nil }

    func item(_ id: String) -> SettingItem? { SettingsSchema.item(id) }

    func environmentDidChange() { environmentRevision += 1 }

    // MARK: 開く・選ぶ

    /// 開くたびに先頭を選び、記録と入力を止める（試作と同じ）
    func open() {
        selection = 0
        recording = false
        editingID = nil
        message = nil
        settings = controller.settings
        issues = controller.issues
        scrollRequest += 1
    }

    func select(_ id: String) {
        guard let index = rowIDs.firstIndex(of: id) else { return }
        if index != selection {
            recording = false
            editingID = nil
        }
        selection = index
    }

    func move(by delta: Int) {
        selection = min(max(0, selection + delta), rowIDs.count - 1)
        message = nil
        scrollRequest += 1
    }

    // MARK: キー（試作の sheet.onKey）

    /// 処理したら true。記録中のキーは `record` へ回す
    func handle(_ press: KeyStroke) -> Bool {
        if recording {
            record(press)
            return true
        }
        let plain = press.modifiers.isEmpty
        if plain, press.keyCode == KeyCodes.escape { return closeWindow() }
        if press.modifiers == .command, press.keyCode == 13 { return closeWindow() }  // ⌘W
        if let settingsKey = settings.keymap.combos(for: .settings).first(where: { $0.matches(press).matched }),
            !settingsKey.modifiers.isEmpty
        {
            return closeWindow()
        }
        guard plain else { return false }
        switch press.keyCode {
        case KeyCodes.upArrow: move(by: -1)
        case KeyCodes.downArrow: move(by: 1)
        case KeyCodes.returnKey, KeyCodes.keypadEnter: activateSelected()
        case KeyCodes.rightArrow: step(by: 1)
        case KeyCodes.leftArrow: step(by: -1)
        case KeyCodes.delete: resetSelected()
        default: return false
        }
        return true
    }

    private func closeWindow() -> Bool {
        effects.close()
        return true
    }

    /// ↩: 選択肢は次へ、数は打ち込み、アプリは足す、キーは記録
    func activateSelected() {
        guard let id = selectedID, let item = item(id) else { return }
        switch item.kind {
        case .choice, .toggle: step(by: 1)
        case .integer, .number: beginEditing(id)
        case .appList, .appMap: effects.pickApp(id)
        case .keys: startRecording(id)
        }
    }

    /// ←→: 選択肢を 1 つ動かす（端で回る）・数を 1 段動かす（端で止まる）
    func step(by delta: Int) {
        guard let id = selectedID, let item = item(id) else { return }
        switch item.kind {
        case .choice(let choices):
            let current = SettingsSchema.value(id, in: settings)?.stringValue
            let index = choices.firstIndex { $0.value == current } ?? 0
            choose(id, choices[(index + delta + choices.count) % choices.count].value)
        case .toggle:
            choose(id, settings.launchAtLogin ? "false" : "true")
        case .integer(let min, let max, let step, _):
            let current = SettingsSchema.value(id, in: settings)?.intValue ?? min
            // 段の倍数にそろえる（1000 → 1100、950 → 1000）
            let next = delta > 0 ? (current / step + 1) * step : ((current - 1) / step) * step
            setValue(id, .int(Swift.min(Swift.max(next, min), max)))
        case .number(let min, let max, let step, _):
            let current = SettingsSchema.value(id, in: settings)?.doubleValue ?? min
            setValue(id, .number(Swift.min(Swift.max(current + Double(delta) * step, min), max)))
        default:
            break
        }
    }

    // MARK: 値を変える

    /// 選択肢を選ぶ（オン・オフは "true" / "false"）
    func choose(_ id: String, _ value: String) {
        guard let item = item(id) else { return }
        select(id)
        let raw: JSONValue = item.kind == .toggle ? .bool(value == "true") : .string(value)
        guard setValue(id, raw) else { return }
        let label =
            item.kind == .toggle
            ? (value == "true" ? "する" : "しない") : (item.choices.first { $0.value == value }?.label ?? value)
        message = "「\(item.label(in: settings))」を「\(label)」にしました。"
    }

    /// 検証して入れる。通らなければ理由を出して false
    @discardableResult
    func setValue(_ id: String, _ raw: JSONValue, keyConflicts: KeyConflictPolicy = .reject) -> Bool {
        do {
            try controller.set(id, raw, keyConflicts: keyConflicts)
            settings = controller.settings
            if let item = item(id), case .integer = item.kind {
                message = "「\(item.label)」を \(valueText(id)) にしました。"
            } else if let item = item(id), case .number = item.kind {
                message = "「\(item.label)」を \(valueText(id)) にしました。"
            }
            return true
        } catch let error as SettingsError {
            message = error.message
        } catch {
            message = "設定ファイルに書けませんでした。"
        }
        return false
    }

    /// ⌫: 選んでいる項目を既定に戻す
    func resetSelected() {
        guard let id = selectedID, let item = item(id) else { return }
        do {
            try controller.reset(id)
            settings = controller.settings
            message = "「\(item.label(in: settings))」を初期値に戻しました。"
        } catch {
            message = "設定ファイルに書けませんでした。"
        }
    }

    func resetAll() {
        recording = false
        editingID = nil
        do {
            try controller.resetAll()
            settings = controller.settings
            message = "すべて初期値に戻しました。"
        } catch {
            message = "設定ファイルに書けませんでした。"
        }
    }

    // MARK: 数を打ち込む

    func beginEditing(_ id: String) {
        select(id)
        editText = SettingsSchema.value(id, in: settings)?.doubleValue.map(SettingsSchema.format) ?? ""
        editingID = id
        message = nil
    }

    func commitEditing() {
        guard let id = editingID else { return }
        if setValue(id, .string(editText)) { editingID = nil }
    }

    func cancelEditing() {
        editingID = nil
    }

    /// 単位付きの値（「1000 件」）
    func valueText(_ id: String) -> String {
        guard let item = item(id), let value = SettingsSchema.value(id, in: settings)?.doubleValue else { return "" }
        switch item.kind {
        case .integer(_, _, _, let unit), .number(_, _, _, let unit): return "\(SettingsSchema.format(value)) \(unit)"
        default: return SettingsSchema.format(value)
        }
    }

    // MARK: キーを記録する（試作の rec）

    func startRecording(_ id: String) {
        select(id)
        guard item(id)?.keyAction != nil else { return }
        editingID = nil
        message = nil
        recording = true
    }

    func cancelRecording() {
        recording = false
        message = nil
    }

    /// 記録中に押されたキー。esc（修飾キーなし）は記録をやめる。使えないキーは理由を出して記録を続ける
    func record(_ press: KeyStroke) {
        guard let id = selectedID, let action = item(id)?.keyAction else {
            recording = false
            return
        }
        if press.modifiers.isEmpty, press.keyCode == KeyCodes.escape {
            cancelRecording()
            return
        }
        let combo: KeyCombo
        if action.usesDigits {
            guard KeyCodes.digit(of: press.keyCode) != nil,
                !press.modifiers.intersection([.command, .control, .option]).isEmpty
            else {
                message = "数字と一緒に ⌘ ⌃ ⌥ のどれかを押してください。"
                return
            }
            combo = KeyCombo(.digits, press.modifiers)
        } else {
            combo = KeyCombo(.code(KeyCodes.canonical(press.keyCode)), press.modifiers)
        }
        do {
            // 重なったキーは前の割り当てから外す（試作と同じ）
            let moved = try controller.set(id, .array([.string(KeyComboText.format(combo))]), keyConflicts: .takeOver)
            settings = controller.settings
            recording = false
            var text = "「\(action.label)」を \(combo.displayString) にしました。"
            if !moved.isEmpty {
                text += "重なっていた「" + moved.map(\.label).joined(separator: "」「") + "」からは外しました。"
            }
            message = text
        } catch let error as SettingsError {
            message = error.message
        } catch {
            recording = false
            message = "設定ファイルに書けませんでした。"
        }
    }

    // MARK: キーの行の表示

    func combos(_ action: KeyAction) -> [KeyCombo] { settings.keymap.combos(for: action) }

    /// 重なっている相手の操作
    func conflicts(_ action: KeyAction) -> [KeyAction] {
        settings.keymap.conflicts(involving: action).map { $0.first == action ? $0.second : $0.first }
    }

    /// キーの行の注記（重なり・登録の失敗）
    func keyWarning(_ action: KeyAction) -> String? {
        _ = environmentRevision
        let others = conflicts(action)
        if !others.isEmpty {
            return "「" + others.map(\.label).joined(separator: "」「") + "」と重なっています。どちらかを変えてください。"
        }
        if action.scope == .global, !combos(action).isEmpty, environment.hotKeyRegistered(action) == false {
            return "このキーを登録できませんでした。ほかのアプリが使っているかもしれません。"
        }
        return nil
    }

    // MARK: アプリの項目

    func appEntries(_ id: String) -> [AppEntry] {
        switch id {
        case SettingID.excludedApps:
            return settings.excludedApps.map { AppEntry(bundleID: $0, name: appName($0), builtIn: false) }
        case SettingID.pasteTiming:
            let overrides = settings.pasteTiming
            func override(_ bundleID: String) -> PasteTiming? {
                overrides.first { $0.key.lowercased() == bundleID.lowercased() }?.value
            }
            let builtIn = DeferredPasteApps.all.filter { override($0.bundleID) != .immediate }
                .map { AppEntry(bundleID: $0.bundleID, name: appName($0.bundleID), builtIn: true) }
            let added = overrides.filter { $0.value == .onCommit && DeferredPasteApps.category(of: $0.key) == nil }
                .keys.sorted().map { AppEntry(bundleID: $0, name: appName($0), builtIn: false) }
            return builtIn + added
        default:
            return []
        }
    }

    func appName(_ bundleID: String) -> String {
        environment.appName(bundleID)
            ?? DeferredPasteApps.all.first { $0.bundleID.lowercased() == bundleID.lowercased() }?.name ?? bundleID
    }

    func addApp(_ id: String, bundleID: String) {
        select(id)
        let name = appName(bundleID)
        switch id {
        case SettingID.excludedApps:
            if let existing = settings.excludedApps.first(where: { $0.lowercased() == bundleID.lowercased() }) {
                message = "「\(appName(existing))」はもう入っています。"
                return
            }
            if setValue(id, .array((settings.excludedApps + [bundleID]).map(JSONValue.string))) {
                message = "「\(name)」でのコピーを記録しないようにしました。"
            }
        case SettingID.pasteTiming:
            var map = settings.pasteTiming.filter { $0.key.lowercased() != bundleID.lowercased() }
            let isBuiltIn = DeferredPasteApps.category(of: bundleID) != nil
            guard !(isBuiltIn && settings.candidate.timing(for: bundleID) == .onCommit) else {
                message = "「\(name)」はもう入っています。"
                return
            }
            if !isBuiltIn { map[bundleID] = .onCommit }
            if setValue(id, .object(map.mapValues { .string($0.rawValue) })) {
                message = "「\(name)」では、確定したときに貼るようにしました。"
            }
        default:
            break
        }
    }

    func removeApp(_ id: String, bundleID: String) {
        select(id)
        let name = appName(bundleID)
        switch id {
        case SettingID.excludedApps:
            let list = settings.excludedApps.filter { $0.lowercased() != bundleID.lowercased() }
            if setValue(id, .array(list.map(JSONValue.string))) { message = "「\(name)」を外しました。" }
        case SettingID.pasteTiming:
            var map = settings.pasteTiming.filter { $0.key.lowercased() != bundleID.lowercased() }
            // 既定の一覧のアプリは「すぐ貼る」を書いて外す
            if DeferredPasteApps.category(of: bundleID) != nil { map[bundleID] = .immediate }
            if setValue(id, .object(map.mapValues { .string($0.rawValue) })) {
                message = "「\(name)」では、すぐ仮に貼るようにしました。"
            }
        default:
            break
        }
    }

    // MARK: 選択肢の行の表示

    func currentChoice(_ id: String) -> SettingChoice? {
        guard let item = item(id), let value = SettingsSchema.value(id, in: settings)?.stringValue else { return nil }
        return item.choices.first { $0.value == value }
    }

    var debugState: [String: String] {
        [
            "selection": selectedID ?? "", "recording": String(recording), "editing": editingID ?? "",
            "message": message ?? "",
        ]
    }
}

import Foundation
import Testing

@testable import MakuripCore

@Suite("設定スキーマ")
struct SettingsSchemaTests {
    @Test("全項目が ID・名前・説明・既定値を持つ。ID は重ならず、全操作にキーの項目がある")
    func everyItemIsDescribed() {
        let ids = SettingsSchema.items.map(\.id)
        #expect(Set(ids).count == ids.count)
        for item in SettingsSchema.items {
            #expect(!item.label.isEmpty, "\(item.id) に名前がない")
            #expect(item.summary.count >= 10, "\(item.id) の説明が短すぎる")
            #expect(!item.group.isEmpty)
            #expect(SettingsSchema.defaultValue(item.id) != nil, "\(item.id) に既定値がない")
            for choice in item.choices {
                #expect(!choice.label.isEmpty && !choice.summary.isEmpty, "\(item.id) の \(choice.value) に説明がない")
            }
            if item.section == .behavior { #expect(SettingsSchema.behaviorGroups.contains(item.group)) }
        }
        for action in KeyAction.allCases {
            #expect(SettingsSchema.item(SettingID.keys(action))?.keyAction == action)
        }
    }

    @Test("既定値の出どころは Limits・CandidateSettings・キーマップの 1 か所（二重に持たない）")
    func defaultsComeFromOnePlace() {
        let settings = AppSettings.default
        #expect(settings.limits == Limits.default)
        #expect(settings.candidate == CandidateSettings.default)
        #expect(settings.keymap == Keymap.default)
        #expect(SettingsSchema.defaultValue(SettingID.maxItems) == .int(1000))
        #expect(SettingsSchema.defaultValue(SettingID.maxTotalMegabytes) == .int(1024))
        #expect(SettingsSchema.defaultValue(SettingID.hotKeyMode) == .string("candidate"))
        #expect(SettingsSchema.defaultValue(SettingID.keys(.openHistory)) == .array([.string("⌃⌘V")]))
    }

    @Test("頼みの例は、どれもそのまま検証に通る（拒否の決まりで、重なりもない）")
    func examplesAreValid() throws {
        for item in SettingsSchema.items {
            for example in item.examples {
                let result = SettingsSchema.applying(example.value, to: item.id, in: .default, keyConflicts: .reject)
                #expect(throws: Never.self, "\(item.id) の例「\(example.request)」") { try result.get() }
            }
        }
        // ユーザーの頼みに当たる例がある（docs/ai-settings.md の対応表と同じ）
        let requests = SettingsSchema.items.flatMap { item in item.examples.map { ($0.request, item.id) } }
        let lookup = Dictionary(requests, uniquingKeysWith: { first, _ in first })
        #expect(lookup["候補窓は出さないで"] == SettingID.hotKeyMode)
        #expect(lookup["呼び出しを ⌥V にして"] == SettingID.keys(.openHistory))
        #expect(lookup["履歴は 200 件まで"] == SettingID.maxItems)
        #expect(lookup["Slack では確定するまで貼らないで"] == SettingID.pasteTiming)
        #expect(lookup["候補窓の並びを予測変換みたいに"] == SettingID.candidateOrder)
    }

    @Test("既定のキーはすべてキーの決まりに通る")
    func defaultKeysFollowRules() {
        for action in KeyAction.allCases {
            for combo in action.defaultCombos {
                #expect(KeyRules.problem(with: combo, for: action) == nil, "\(action) の \(combo.displayString)")
            }
        }
    }

    @Test("いまの値を読んで書き戻すと同じ（全項目）")
    func valueRoundTrip() throws {
        var settings = AppSettings.default
        settings.hotKeyMode = .list
        settings.excludedApps = ["com.example.secret"]
        settings.pasteTiming = ["com.apple.Terminal": .immediate]
        settings.idleTimeout = 30
        settings.keymap.set([KeyCombo(.code(38), .command)], for: .cycleMethod)
        for item in SettingsSchema.items {
            let value = try #require(SettingsSchema.value(item.id, in: settings))
            let change = try SettingsSchema.applying(value, to: item.id, in: .default, keyConflicts: .allow).get()
            #expect(SettingsSchema.value(item.id, in: change.settings) == value, "\(item.id)")
        }
    }
}

@Suite("設定の検証")
struct SettingsValidationTests {
    func set(_ id: String, _ raw: JSONValue, in settings: AppSettings = .default, policy: KeyConflictPolicy = .reject)
        -> Result<SettingChange, SettingsError>
    {
        SettingsSchema.applying(raw, to: id, in: settings, keyConflicts: policy)
    }

    func message(_ result: Result<SettingChange, SettingsError>) -> String? {
        if case .failure(let error) = result { return error.message }
        return nil
    }

    @Test("選択肢: 値・大文字小文字・画面の名前で選べる。知らない値は選択肢を挙げて拒否する")
    func choices() throws {
        #expect(try set(SettingID.hotKeyMode, .string("paste")).get().settings.hotKeyMode == .pasteOnly)
        #expect(try set(SettingID.hotKeyMode, .string("LIST")).get().settings.hotKeyMode == .list)
        #expect(try set(SettingID.candidateOrder, .string("予測変換式")).get().settings.candidateOrder == .ime)
        let error = try #require(message(set(SettingID.hotKeyMode, .string("popup"))))
        #expect(error.contains("paste（すぐ貼るだけ）") && error.contains("popup"))
        #expect(message(set(SettingID.hotKeyMode, .int(1))) != nil)
    }

    @Test("整数: 範囲・単位付きの文字（200件・2GB）・小数を拒否")
    func integers() throws {
        #expect(try set(SettingID.maxItems, .int(200)).get().settings.maxItems == 200)
        #expect(try set(SettingID.maxItems, .string("200件")).get().settings.maxItems == 200)
        #expect(try set(SettingID.maxItems, .string("1,500")).get().settings.maxItems == 1500)
        #expect(try set(SettingID.maxTotalMegabytes, .string("2GB")).get().settings.maxTotalMegabytes == 2048)
        #expect(
            try set(SettingID.maxTotalMegabytes, .string("512 MB")).get().settings.limits.maxTotalBytes == 512 << 20)
        let tooSmall = try #require(message(set(SettingID.maxItems, .int(5))))
        #expect(tooSmall.contains("10〜20000") && tooSmall.contains("5"))
        #expect(message(set(SettingID.maxItems, .int(20_001))) != nil)
        #expect(message(set(SettingID.maxItems, .number(200.5))) != nil)
        #expect(message(set(SettingID.maxItems, .string("たくさん"))) != nil)
    }

    @Test("数とオン・オフ")
    func numbersAndToggles() throws {
        #expect(try set(SettingID.idleTimeout, .string("15秒")).get().settings.idleTimeout == 15)
        #expect(try set(SettingID.idleTimeout, .number(2.5)).get().settings.idleTimeout == 2.5)
        #expect(message(set(SettingID.idleTimeout, .number(1))) != nil)
        #expect(try set(SettingID.launchAtLogin, .string("オン")).get().settings.launchAtLogin)
        #expect(try set(SettingID.launchAtLogin, .int(1)).get().settings.launchAtLogin)
        #expect(try !set(SettingID.launchAtLogin, .string("false")).get().settings.launchAtLogin)
        #expect(message(set(SettingID.launchAtLogin, .string("たぶん"))) != nil)
    }

    @Test("アプリ: バンドル ID の形を確かめる。アプリ名は調べ方を添えて拒否・重複はまとめる")
    func apps() throws {
        let list = try set(
            SettingID.excludedApps,
            .array([.string("com.apple.Safari"), .string("COM.APPLE.SAFARI"), .string("org.example.app-2")])
        ).get()
        #expect(list.settings.excludedApps == ["com.apple.Safari", "org.example.app-2"])
        #expect(list.settings.excludedAppSet == ["com.apple.safari", "org.example.app-2"])
        #expect(try set(SettingID.excludedApps, .string("com.apple.Safari")).get().settings.excludedApps.count == 1)
        let name = try #require(message(set(SettingID.excludedApps, .array([.string("Slack")]))))
        #expect(name.contains("osascript"))
        #expect(message(set(SettingID.excludedApps, .array([.string("com..example")]))) != nil)
        #expect(message(set(SettingID.excludedApps, .array([.string("com.example/../x")]))) != nil)

        let map = try set(SettingID.pasteTiming, .object(["com.tinyspeck.slackmacgap": .string("確定まで貼らない")]))
            .get()
        #expect(map.settings.pasteTiming == ["com.tinyspeck.slackmacgap": .onCommit])
        #expect(map.settings.candidate.timing(for: "com.tinyspeck.slackmacgap") == .onCommit)
        #expect(message(set(SettingID.pasteTiming, .object(["com.apple.Terminal": .string("later")]))) != nil)
        #expect(message(set(SettingID.pasteTiming, .array([]))) != nil)
    }

    @Test("どこからでも効くキー: 修飾キーなし・⌘ だけ・macOS の操作・2 つ以上は拒否。F キーは修飾キーなしでよい")
    func globalKeyRules() throws {
        let open = SettingID.keys(.openHistory)
        #expect(
            try set(open, .string("⌥V")).get().settings.globalHotKey(.openHistory)
                == HotKey(keyCode: 9, modifiers: .option))
        #expect(
            try set(open, .array([.string("ctrl+opt+cmd+k")])).get().settings.keymap.primary(.openHistory)?
                .displayString == "⌃⌥⌘K")
        #expect(try set(open, .string("⌘⇧V")).get().settings.keymap.primary(.openHistory)?.displayString == "⇧⌘V")
        #expect(try set(open, .string("F13")).get().settings.globalHotKey(.openHistory)?.keyCode == 105)
        #expect(message(set(open, .string("V")))?.contains("修飾キーなし") == true)
        #expect(message(set(open, .string("⇧V")))?.contains("修飾キーなし") == true)
        #expect(message(set(open, .string("⌘C")))?.contains("⌘ だけ") == true)
        #expect(message(set(open, .string("⌃space")))?.contains("入力ソース") == true)
        #expect(message(set(open, .string("⌘⇧4")))?.contains("スクリーンショット") == true)
        #expect(message(set(open, .array([.string("⌥V"), .string("⌥B")])))?.contains("1 つだけ") == true)
        #expect(message(set(open, .string("⌘⌥"))) == "修飾キーだけでキーがない（例: ⌃⌘V）")
        #expect(message(set(open, .string("⌘ほげ")))?.contains("分からない") == true)
    }

    @Test("一覧と候補窓のキー: 文字のキーは ⌘⌃⌥ と一緒に。検索欄の ⌘C 等は使えない。番号は修飾キー + 1〜9")
    func panelKeyRules() throws {
        #expect(message(set(SettingID.keys(.cycleMethod), .string("K")))?.contains("文字") == true)
        #expect(message(set(SettingID.keys(.cycleMethod), .string("⇧K")))?.contains("文字") == true)
        #expect(message(set(SettingID.keys(.cycleMethod), .string("space"))) != nil)
        #expect(message(set(SettingID.keys(.cycleMethod), .string("⌘C")))?.contains("検索欄") == true)
        #expect(try set(SettingID.keys(.cycleMethod), .string("⌃K")).get().settings.keymap.primary(.cycleMethod) != nil)
        #expect(
            try set(SettingID.keys(.close), .string("F2")).get().settings.keymap.primary(.close)?.displayString == "F2")
        #expect(message(set(SettingID.keys(.candidateUp), .string("J")))?.contains("文字") == true)
        #expect(try set(SettingID.keys(.candidateUp), .string("⌃P")).get().settings.keymap.primary(.candidateUp) != nil)
        // 番号の操作
        #expect(
            try set(SettingID.keys(.quickPaste), .string("⌃1-9")).get().settings.keymap.primary(.quickPaste)?
                .displayString == "⌃1–9")
        #expect(message(set(SettingID.keys(.quickPaste), .string("1–9")))?.contains("⌘・⌃・⌥") == true)
        #expect(message(set(SettingID.keys(.quickPaste), .string("⌘K")))?.contains("1〜9") == true)
        #expect(message(set(SettingID.keys(.paste), .string("⌘1–9")))?.contains("keys.quick") == true)
    }

    @Test("空のキーは「未設定」として入る")
    func emptyKeys() throws {
        let change = try set(SettingID.keys(.openHistory), .array([])).get()
        #expect(change.settings.keymap.combos(for: .openHistory).isEmpty)
        #expect(change.settings.globalHotKey(.openHistory) == nil)
        #expect(change.value == .array([]))
    }

    @Test("重なり: 拒否（相手の ID を挙げる）・付け替え（相手から外す）・そのまま（ファイルから読むとき）")
    func conflicts() throws {
        let method = SettingID.keys(.cycleMethod)
        let rejected = try #require(message(set(method, .string("⌘E"))))
        #expect(rejected.contains("keys.app") && rejected.contains("--take-over"))

        let moved = try set(method, .string("⌘E"), policy: .takeOver).get()
        #expect(moved.movedFrom == [.chooseApp])
        #expect(moved.settings.keymap.combos(for: .chooseApp).isEmpty)
        #expect(moved.settings.keymap.conflicts().isEmpty)

        let kept = try set(method, .string("⌘E"), policy: .allow).get()
        #expect(kept.movedFrom.isEmpty)
        #expect(kept.settings.keymap.conflicts(involving: .cycleMethod).map(\.second) == [.chooseApp])

        // 範囲が違えば重ならない（候補窓の ⌃⌘V と呼び出しの ⌃⌘V）。全体と一覧は同じ範囲として見る
        #expect(try set(SettingID.keys(.candidateExpand), .string("⌃⌘V")).get().movedFrom.isEmpty)
        let global = try #require(message(set(SettingID.keys(.openHistory), .string("⇧⌘P"))))
        #expect(global.contains("keys.pinned"))
        // 付け替えで外した相手が複数のキーを持つときは、重なったものだけ外す
        let prev = try set(SettingID.keys(.next), .string("⌃P"), policy: .takeOver).get()
        #expect(prev.settings.keymap.combos(for: .previous).map(\.displayString) == ["↑"])
    }

    @Test("知らない項目は拒否する")
    func unknownItem() {
        #expect(message(set("hotkeymode2", .string("x")))?.contains("schema") == true)
    }
}

@Suite("キーの文字表現")
struct KeyComboTextTests {
    func parse(_ text: String) -> String? {
        try? KeyComboText.parse(text).get().displayString
    }

    @Test("既定のキーは書いて読むと同じ")
    func roundTrip() throws {
        for action in KeyAction.allCases {
            for combo in action.defaultCombos {
                #expect(try KeyComboText.parse(KeyComboText.format(combo)).get() == combo, "\(action)")
            }
        }
    }

    @Test("いろいろな書き方を読む")
    func aliases() {
        #expect(parse("ctrl+cmd+v") == "⌃⌘V")
        #expect(parse("Control + Option + Command + V") == "⌃⌥⌘V")
        #expect(parse("opt+v") == "⌥V")
        #expect(parse("alt+shift+return") == "⌥⇧↩")
        #expect(parse("⌘+,") == "⌘,")
        #expect(parse("⌘,") == "⌘,")
        #expect(parse("shift+tab") == "⇧⇥")
        #expect(parse("escape") == "esc")
        #expect(parse("Esc") == "esc")
        #expect(parse("⌘⌫") == "⌘⌫")
        #expect(parse("cmd+backspace") == "⌘⌫")
        #expect(parse("⌘1-9") == "⌘1–9")
        #expect(parse("⌃⌘Ｖ") == "⌃⌘V")  // 全角
        #expect(parse("c") == "C")  // 「cmd」と取り違えない
        #expect(parse("⌘enter") == "⌘↩")
        #expect(parse("f12") == "F12")
        #expect(parse("⌥space") == "⌥space")
        #expect(parse("⌘¥") == "⌘¥")
    }

    @Test("読めないもの")
    func errors() {
        #expect(throws: KeyComboText.ParseError.empty) { try KeyComboText.parse("  ").get() }
        #expect(throws: KeyComboText.ParseError.missingKey) { try KeyComboText.parse("⌘⇧").get() }
        #expect(throws: KeyComboText.ParseError.unknownKey("ほげ")) { try KeyComboText.parse("⌘ほげ").get() }
    }
}
